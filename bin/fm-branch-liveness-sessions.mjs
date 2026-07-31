#!/usr/bin/env node
// Read-only scanner over agent session transcripts, used by
// bin/fm-branch-liveness.sh to answer "which directories and branches are live
// agent sessions currently working?".
//
// Claude Code appends one JSON object per line to
// <root>/<encoded-cwd>/<session-id>.jsonl, and its ordinary user/assistant/system
// records carry `cwd`, `gitBranch`, `timestamp`, and `sessionId`. The encoded
// directory name is a lossy transform of the cwd (both `/` and `.` become `-`),
// so it is never decoded here; the authoritative cwd is read from the record.
//
// This file only reports what it can read. It applies no repository identity,
// no ownership exclusion, and no collision policy - all of that belongs to the
// shell caller, which has git.
//
// Usage:
//   fm-branch-liveness-sessions.mjs --root <dir> --since-epoch <seconds>
//
// Output (TSV on stdout, one line per fresh transcript):
//   OK<TAB><session-id><TAB><epoch><TAB><branch><TAB><cwd><TAB><transcript>
//   UNRESOLVED<TAB><transcript>
// `branch` is empty when the session is on a detached HEAD or outside a repo.
// UNRESOLVED marks a transcript that is fresh but exposes no readable cwd
// record; the caller treats it as an incomplete signal, never as "no session".
//
// Freshness uses the record's own `timestamp`, not the file mtime: a transcript
// can be rewritten (compaction, title edits) long after its last real turn, so
// mtime alone would over-report live sessions. mtime is still used as a cheap
// pre-filter because it can only ever be newer than the last appended record.
//
// Exit codes:
//   0  scan completed (zero or more output lines)
//   2  usage error
//   4  scan could not complete; the caller must fail closed

import fs from "node:fs";
import path from "node:path";

const TAIL_BYTES = 1024 * 1024;
const MAX_TAIL_BYTES = 64 * 1024 * 1024;

function die(code, message) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const out = { root: "", sinceEpoch: NaN };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--root") {
      out.root = argv[i + 1] ?? "";
      i += 1;
    } else if (arg === "--since-epoch") {
      out.sinceEpoch = Number(argv[i + 1]);
      i += 1;
    } else {
      die(2, `usage: unexpected argument '${arg}'`);
    }
  }
  if (!out.root) die(2, "usage: --root <dir> is required");
  if (!Number.isFinite(out.sinceEpoch)) die(2, "usage: --since-epoch <seconds> is required");
  return out;
}

// Read the last `length` bytes of an open file. A transcript grows to megabytes,
// and only its final records describe where the session is now.
function readTail(fd, size, length) {
  const start = size - length;
  const buf = Buffer.alloc(length);
  let read = 0;
  while (read < length) {
    const n = fs.readSync(fd, buf, read, length - read, start + read);
    if (n <= 0) break;
    read += n;
  }
  return { text: buf.subarray(0, read).toString("utf8"), truncated: start > 0 };
}

// The last record in the tail that states where the session is. A record
// without `gitBranch` still resolves the transcript: it means the session is not
// on a branch, which is a definite answer, not a missing signal.
function scanTail(text, truncated) {
  const lines = text.split("\n");
  // A truncated read can slice the first line mid-object; it is never the last.
  const first = truncated ? 1 : 0;
  for (let i = lines.length - 1; i >= first; i -= 1) {
    const line = lines[i].trim();
    if (!line) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (!record || typeof record !== "object") continue;
    if (typeof record.cwd !== "string" || !record.cwd) continue;
    if (typeof record.timestamp !== "string" || !record.timestamp) continue;
    const epoch = Math.floor(Date.parse(record.timestamp) / 1000);
    if (!Number.isFinite(epoch)) continue;
    return {
      sessionId: typeof record.sessionId === "string" ? record.sessionId : "",
      epoch,
      branch: typeof record.gitBranch === "string" ? record.gitBranch : "",
      cwd: record.cwd,
    };
  }
  return null;
}

// A single record can be larger than the whole tail window - real transcripts
// carry multi-megabyte tool results - and then the window holds nothing but a
// fragment of it. Reporting that transcript as unreadable would refuse every
// dispatch for the length of the activity window over a signal that is perfectly
// readable, so the window grows until a complete record is found or the whole
// file has been read. The growth is bounded: past MAX_TAIL_BYTES the transcript
// is treated as unresolved, which keeps the fail-closed contract intact for a
// transcript that genuinely exposes no location record.
function lastLocationRecord(file) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    let length = Math.min(size, TAIL_BYTES);
    for (;;) {
      const { text, truncated } = readTail(fd, size, length);
      const record = scanTail(text, truncated);
      if (record) return record;
      if (!truncated || length >= MAX_TAIL_BYTES) return null;
      length = Math.min(size, length * 2, MAX_TAIL_BYTES);
    }
  } finally {
    fs.closeSync(fd);
  }
}

function listDir(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    if (err && err.code === "ENOENT") return null;
    die(4, `incomplete: cannot list ${dir}: ${err && err.message ? err.message : err}`);
  }
  return null;
}

function main() {
  const { root, sinceEpoch } = parseArgs(process.argv.slice(2));
  // An absent transcript root is a definite answer: this machine has recorded no
  // agent sessions at all. Only an unreadable, existing root is incomplete.
  let rootStat;
  try {
    rootStat = fs.statSync(root);
  } catch (err) {
    if (err && err.code === "ENOENT") process.exit(0);
    die(4, `incomplete: cannot stat ${root}: ${err && err.message ? err.message : err}`);
  }
  if (!rootStat.isDirectory()) process.exit(0);

  const projectDirs = listDir(root);
  if (projectDirs === null) process.exit(0);

  const out = [];
  const sinceMs = sinceEpoch * 1000;
  for (const projectEntry of projectDirs) {
    if (!projectEntry.isDirectory()) continue;
    const projectDir = path.join(root, projectEntry.name);
    const files = listDir(projectDir);
    if (files === null) continue;
    for (const fileEntry of files) {
      if (!fileEntry.isFile() || !fileEntry.name.endsWith(".jsonl")) continue;
      const file = path.join(projectDir, fileEntry.name);
      let stat;
      try {
        stat = fs.statSync(file);
      } catch (err) {
        if (err && err.code === "ENOENT") continue;
        die(4, `incomplete: cannot stat ${file}: ${err && err.message ? err.message : err}`);
      }
      if (stat.mtimeMs < sinceMs) continue;
      let record;
      try {
        record = lastLocationRecord(file);
      } catch (err) {
        die(4, `incomplete: cannot read ${file}: ${err && err.message ? err.message : err}`);
      }
      // A cwd or branch carrying a tab or newline cannot survive this TSV, and a
      // value dropped in silence would read downstream as "no session here".
      // Report it as unresolved so the caller fails closed on it instead.
      if (record && /[\t\n\r]/.test(`${record.cwd}${record.branch}`)) record = null;
      if (!record) {
        out.push(`UNRESOLVED\t${file}`);
        continue;
      }
      if (record.epoch < sinceEpoch) continue;
      out.push(
        ["OK", record.sessionId, String(record.epoch), record.branch, record.cwd, file].join("\t"),
      );
    }
  }
  out.sort();
  if (out.length) process.stdout.write(`${out.join("\n")}\n`);
  process.exit(0);
}

main();
