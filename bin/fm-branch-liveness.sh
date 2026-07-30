#!/usr/bin/env bash
# fm-branch-liveness.sh - refuse-grade evidence that another LIVE session is
# already working a git branch.
#
# The hazard (data/decisions/concurrent-session-branch-collision.md): firstmate
# inspected a branch, saw a clean tree at a known tip, and dispatched a worker
# onto it while an interactive session in a DIFFERENT directory of the SAME
# repository was still working that same branch. The two overlapped for 31
# minutes, the worker's push was rejected, and it misattributed the cause. A tip
# snapshot is point-in-time; the hazard has duration. So this script does not ask
# "what does the branch look like right now" - it asks "is a session currently
# alive on it".
#
# Usage:
#   fm-branch-liveness.sh --repo <dir> --branch <name> [--exclude <path>]...
#                         [--home <firstmate-home>] [--verbose]
#
#   --repo <dir>      any checkout of the repository the branch belongs to.
#   --branch <name>   the branch the pending work will use.
#   --exclude <path>  a directory whose sessions are the caller's own and never a
#                     collision (repeatable). The path and everything under it is
#                     excluded. --repo itself is always excluded, because the
#                     fleet's own clone is read-only to it and no worker runs
#                     there; --home additionally excludes that home and every
#                     worktree recorded in its state/*.meta.
#   --home <dir>      firstmate home whose state/*.meta records the caller's own
#                     workers. Without it, no ownership exclusions are derived.
#   --state <dir>     the home's state directory, when it is not <home>/state.
#   --projects <dir>  the home's project clones, when they are not <home>/projects.
#   --verbose         also print CLEAR: lines for detectors that found nothing.
#
# Output is one line per finding on stdout:
#   COLLISION: <detector>: <evidence>
#   INCOMPLETE: <detector>: <reason>
#   CLEAR: <detector>            (--verbose only)
#
# Exit codes:
#   0  no live session found on that branch
#   2  usage error
#   3  collision - at least one live session is using the branch
#   4  detection could not complete
#
# FAIL-CLOSED, and which way that cuts. A signal this script cannot read exits 4,
# never 0. Refusing on an unreadable signal is the only direction that preserves
# the guarantee: exit 0 means "checked, and nothing is there", so degrading an
# unreadable signal to 0 would reintroduce exactly the silent all-clear that
# caused the incident. The cost of the strict direction is bounded and visible -
# the caller's documented override is one deliberate flag away - while the cost
# of the lenient direction is another undetected 31-minute overlap. An ABSENT
# signal is different from an unreadable one and is a real answer: no transcript
# root means no agent sessions were ever recorded, and no remote means no remote
# actor, so both are CLEAR rather than INCOMPLETE.
#
# Detectors, all three of which must clear:
#
#   session   Live agent session transcripts (bin/fm-branch-liveness-sessions.mjs).
#             A session counts when its last recorded turn is inside the activity
#             window, its gitBranch equals the target branch, and its cwd resolves
#             into the same REPOSITORY. Repository identity is by git-common-dir
#             or normalized remote URL, never by path equality: the incident was
#             two different directories for one repository.
#   checkout  Local checkouts of the same repository that have the branch checked
#             out AND show current activity - a dirty tree, or an index/HEAD/reflog
#             touched inside the window. A clean, idle, long-abandoned checkout
#             sitting on the branch is not a live session and does not refuse.
#             Its candidate inventory is bounded and stated rather than implied:
#             the target clone's own worktrees, every directory a live session
#             named, and the caller's project clones. An independent clone that no
#             live session has touched is outside it - finding those would mean
#             scanning the filesystem, which this guard does not do.
#   remote    The branch head on the remote is a commit this checkout has never
#             seen. Someone outside this machine pushed it, which is the same
#             hazard arriving over the network. This detector runs ONLY when the
#             branch already exists locally, so ordinary dispatch onto a fresh
#             per-task branch never touches the network.
#
# The caller's own workers are NOT collisions. They live in isolated worktrees of
# the same repository by design, so every worktree recorded in the caller's own
# state/*.meta, the caller's home, and the project clone are excluded before any
# detector reports. Without that, every ordinary dispatch would refuse.
#
# Environment:
#   FM_BRANCH_LIVENESS_WINDOW_MINUTES  activity window (default 60). A session
#                                      quiet longer than this is not live.
#   FM_BRANCH_LIVENESS_SESSION_ROOT    transcript root (default ~/.claude/projects).
#   FM_BRANCH_LIVENESS_REMOTE_TIMEOUT  seconds for the remote probe (default 15).
#   FM_BRANCH_LIVENESS_NOW             epoch-seconds override, for tests.
#
# Known limit, stated rather than hidden: the session detector reads Claude Code
# transcripts. A session under another harness is covered only through the
# checkout and remote detectors, which are harness-agnostic because they read git
# state rather than any tool's private records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_SCANNER="$SCRIPT_DIR/fm-branch-liveness-sessions.mjs"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

REPO=
BRANCH=
HOME_DIR=
STATE_DIR=
PROJECTS_DIR=
VERBOSE=0
EXCLUDES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--branch|--home|--state|--projects|--exclude)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --repo) REPO=$2 ;;
        --branch) BRANCH=$2 ;;
        --home) HOME_DIR=$2 ;;
        --state) STATE_DIR=$2 ;;
        --projects) PROJECTS_DIR=$2 ;;
        --exclude) EXCLUDES+=("$2") ;;
      esac
      shift 2
      ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --branch=*) BRANCH=${1#--branch=}; shift ;;
    --home=*) HOME_DIR=${1#--home=}; shift ;;
    --state=*) STATE_DIR=${1#--state=}; shift ;;
    --projects=*) PROJECTS_DIR=${1#--projects=}; shift ;;
    --exclude=*) EXCLUDES+=("${1#--exclude=}"); shift ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] || { echo "error: --repo <dir> is required" >&2; exit 2; }
[ -n "$BRANCH" ] || { echo "error: --branch <name> is required" >&2; exit 2; }

WINDOW_MINUTES=${FM_BRANCH_LIVENESS_WINDOW_MINUTES:-60}
case "$WINDOW_MINUTES" in
  ''|*[!0-9]*) echo "error: FM_BRANCH_LIVENESS_WINDOW_MINUTES must be a whole number of minutes" >&2; exit 2 ;;
esac
REMOTE_TIMEOUT=${FM_BRANCH_LIVENESS_REMOTE_TIMEOUT:-15}
case "$REMOTE_TIMEOUT" in
  ''|*[!0-9]*) echo "error: FM_BRANCH_LIVENESS_REMOTE_TIMEOUT must be whole seconds" >&2; exit 2 ;;
esac
SESSION_ROOT=${FM_BRANCH_LIVENESS_SESSION_ROOT:-$HOME/.claude/projects}
NOW=${FM_BRANCH_LIVENESS_NOW:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "error: FM_BRANCH_LIVENESS_NOW must be epoch seconds" >&2; exit 2 ;;
esac
SINCE=$((NOW - (WINDOW_MINUTES * 60)))

COLLISIONS=0
INCOMPLETES=0

report_collision() {  # <detector> <evidence>
  printf 'COLLISION: %s: %s\n' "$1" "$2"
  COLLISIONS=$((COLLISIONS + 1))
}

report_incomplete() {  # <detector> <reason>
  printf 'INCOMPLETE: %s: %s\n' "$1" "$2"
  INCOMPLETES=$((INCOMPLETES + 1))
}

report_clear() {  # <detector>
  [ "$VERBOSE" -eq 1 ] || return 0
  printf 'CLEAR: %s\n' "$1"
}

real_dir() {  # <path> -> physical path, or nothing
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || true
}

iso_utc() {  # <epoch> -> UTC timestamp; BSD and GNU date disagree on the flag
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'epoch %s\n' "$1"
}

path_mtime() {  # <path> -> epoch seconds, or nothing
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Bounded foreground run without depending on GNU timeout, which macOS lacks.
# Returns 124 when the command outlived its budget, so a hung network probe
# becomes an INCOMPLETE rather than a wedged dispatch.
run_bounded() {  # <seconds> <command>...
  local secs=$1 out pid waited=0 rc
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/fm-blv.XXXXXX") || return 125
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((secs * 10)) ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
  rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# --- repository identity ----------------------------------------------------
#
# Two directories are the same repository when they share a git-common-dir (one
# clone and its worktrees) or any normalized remote URL (independent clones).
# Path equality is never sufficient - that assumption is what the incident broke.

normalize_url() {  # <url> -> comparable identity
  local url=$1 resolved
  url=${url%/}
  url=${url%.git}
  case "$url" in
    file://*) url=${url#file://} ;;
  esac
  case "$url" in
    /*)
      resolved=$(real_dir "$url")
      [ -n "$resolved" ] && url=$resolved
      ;;
    *://*)
      url=${url#*://}
      url=${url#*@}
      ;;
    *@*:*)
      url=${url#*@}
      url=${url/:/\/}
      ;;
  esac
  printf '%s\n' "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
}

# repo_keys <dir>: print this checkout's identity keys, one per line. Returns 1
# when <dir> is not a git checkout at all.
repo_keys() {
  local dir=$1 common url
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common=$dir/$common ;;
  esac
  common=$(real_dir "$common")
  [ -n "$common" ] && printf 'common:%s\n' "$common"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    printf 'url:%s\n' "$(normalize_url "$url")"
  done < <(git -C "$dir" remote 2>/dev/null | while IFS= read -r r; do
    git -C "$dir" remote get-url "$r" 2>/dev/null
  done)
  return 0
}

TARGET_KEYS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-blv-keys.XXXXXX") || {
  echo "error: cannot create a temporary file" >&2
  exit 4
}
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() { rm -f "$TARGET_KEYS_FILE"; }
trap cleanup EXIT

REPO_REAL=$(real_dir "$REPO")
[ -n "$REPO_REAL" ] || { echo "error: --repo directory cannot be resolved: $REPO" >&2; exit 2; }
if ! repo_keys "$REPO_REAL" >"$TARGET_KEYS_FILE"; then
  echo "error: --repo is not a git checkout: $REPO_REAL" >&2
  exit 2
fi
[ -s "$TARGET_KEYS_FILE" ] || {
  report_incomplete session "the repository at $REPO_REAL exposes no identity (no common dir, no remote); it cannot be compared with other checkouts"
}

same_repo() {  # <dir>
  local dir=$1 key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -Fxq -- "$key" "$TARGET_KEYS_FILE" && return 0
  done < <(repo_keys "$dir" 2>/dev/null)
  return 1
}

# --- ownership exclusions ---------------------------------------------------

EXCLUDE_REAL=()
add_exclude() {  # <path>
  local resolved
  [ -n "$1" ] || return 0
  resolved=$(real_dir "$1")
  [ -n "$resolved" ] || return 0
  EXCLUDE_REAL+=("$resolved")
}

add_exclude "$REPO_REAL"
for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
  add_exclude "$e"
done
if [ -n "$HOME_DIR" ]; then
  add_exclude "$HOME_DIR"
  [ -n "$STATE_DIR" ] || STATE_DIR="$HOME_DIR/state"
  [ -n "$PROJECTS_DIR" ] || PROJECTS_DIR="$HOME_DIR/projects"
fi
if [ -n "$STATE_DIR" ]; then
  for meta in "$STATE_DIR"/*.meta; do
    [ -f "$meta" ] || continue
    while IFS= read -r line; do
      case "$line" in
        worktree=*) add_exclude "${line#worktree=}" ;;
      esac
    done < "$meta"
  done
fi

is_excluded() {  # <path>
  local path=$1 excl
  for excl in ${EXCLUDE_REAL[@]+"${EXCLUDE_REAL[@]}"}; do
    [ "$path" = "$excl" ] && return 0
    case "$path" in
      "$excl"/*) return 0 ;;
    esac
  done
  return 1
}

# --- detector: live agent sessions ------------------------------------------

SESSION_CWDS=()
run_session_detector() {
  local scan rc found=0 kind session epoch branch cwd transcript cwd_real
  if ! command -v node >/dev/null 2>&1; then
    report_incomplete session "node is required to read agent session transcripts and is not installed"
    return
  fi
  if [ ! -f "$SESSION_SCANNER" ]; then
    report_incomplete session "the session scanner is missing at $SESSION_SCANNER"
    return
  fi
  scan=$(node "$SESSION_SCANNER" --root "$SESSION_ROOT" --since-epoch "$SINCE" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    report_incomplete session "the session scan failed (exit $rc): ${scan:-no diagnostic}"
    return
  fi
  while IFS=$'\t' read -r kind session epoch branch cwd transcript; do
    [ -n "$kind" ] || continue
    if [ "$kind" = UNRESOLVED ]; then
      report_incomplete session "a session transcript active in the last ${WINDOW_MINUTES}m exposes no readable location: $session"
      found=1
      continue
    fi
    cwd_real=$(real_dir "$cwd")
    [ -n "$cwd_real" ] || cwd_real=$cwd
    SESSION_CWDS+=("$cwd_real")
    [ "$branch" = "$BRANCH" ] || continue
    is_excluded "$cwd_real" && continue
    same_repo "$cwd_real" || continue
    report_collision session \
      "session $session is live on branch $BRANCH in $cwd_real (last turn $(iso_utc "$epoch"), transcript $transcript)"
    found=1
  done <<< "$scan"
  [ "$found" -eq 0 ] && report_clear session
  return 0
}

# --- detector: local checkouts on the branch --------------------------------

checkout_is_active() {  # <dir> -> 0 when it shows current activity
  local dir=$1 git_dir marker mtime
  # --no-optional-locks keeps this probe strictly read-only: an ordinary status
  # would refresh and rewrite another session's index, both mutating a checkout
  # this script has no business writing and tainting the mtime signal read below.
  if [ -n "$(git --no-optional-locks -C "$dir" status --porcelain 2>/dev/null)" ]; then
    CHECKOUT_ACTIVITY='uncommitted changes'
    return 0
  fi
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  for marker in index HEAD logs/HEAD; do
    mtime=$(path_mtime "$git_dir/$marker")
    [ -n "$mtime" ] || continue
    if [ "$mtime" -ge "$SINCE" ]; then
      CHECKOUT_ACTIVITY="$marker touched in the last ${WINDOW_MINUTES}m"
      return 0
    fi
  done
  return 1
}

run_checkout_detector() {
  local candidates=() seen=() dir dir_real head found=0 c known
  # Worktrees of the target clone, plus every directory a live session named,
  # plus the caller's own project clones. Transcript DIRECTORY names are a lossy
  # encoding of the cwd, so the cwd is taken from the record, never decoded.
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) candidates+=("${line#worktree }") ;;
    esac
  done < <(git -C "$REPO_REAL" worktree list --porcelain 2>/dev/null)
  for c in ${SESSION_CWDS[@]+"${SESSION_CWDS[@]}"}; do
    candidates+=("$c")
  done
  if [ -n "$PROJECTS_DIR" ]; then
    for c in "$PROJECTS_DIR"/*; do
      [ -d "$c" ] && candidates+=("$c")
    done
  fi
  for dir in ${candidates[@]+"${candidates[@]}"}; do
    dir_real=$(real_dir "$dir")
    [ -n "$dir_real" ] || continue
    known=0
    for c in ${seen[@]+"${seen[@]}"}; do
      [ "$c" = "$dir_real" ] && { known=1; break; }
    done
    [ "$known" -eq 1 ] && continue
    seen+=("$dir_real")
    is_excluded "$dir_real" && continue
    head=$(git -C "$dir_real" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    [ "$head" = "$BRANCH" ] || continue
    same_repo "$dir_real" || continue
    CHECKOUT_ACTIVITY=
    checkout_is_active "$dir_real" || continue
    report_collision checkout \
      "the checkout at $dir_real has $BRANCH checked out and shows current activity ($CHECKOUT_ACTIVITY)"
    found=1
  done
  [ "$found" -eq 0 ] && report_clear checkout
  return 0
}

# --- detector: remote head this checkout has never seen ---------------------

local_branch_exists() {
  git -C "$REPO_REAL" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 && return 0
  git -C "$REPO_REAL" for-each-ref --format='%(refname)' "refs/remotes/*/$BRANCH" 2>/dev/null | grep -q . && return 0
  return 1
}

run_remote_detector() {
  local remote out rc sha
  # A branch that does not exist locally is not an existing-branch dispatch;
  # ordinary per-task branches never reach the network from here.
  if ! local_branch_exists; then
    report_clear remote
    return 0
  fi
  remote=$(git -C "$REPO_REAL" config --get "branch.$BRANCH.remote" 2>/dev/null)
  if [ -z "$remote" ]; then
    if git -C "$REPO_REAL" remote 2>/dev/null | grep -qx origin; then
      remote=origin
    else
      remote=$(git -C "$REPO_REAL" remote 2>/dev/null | head -n 1)
    fi
  fi
  if [ -z "$remote" ]; then
    # No remote configured means no remote actor. A real answer, not a gap.
    report_clear remote
    return 0
  fi
  out=$(GIT_TERMINAL_PROMPT=0 run_bounded "$REMOTE_TIMEOUT" \
    git -C "$REPO_REAL" ls-remote --heads "$remote" "refs/heads/$BRANCH")
  rc=$?
  if [ "$rc" -eq 124 ]; then
    report_incomplete remote "reading $remote timed out after ${REMOTE_TIMEOUT}s, so a push by another session cannot be ruled out"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    report_incomplete remote "$remote could not be read (exit $rc), so a push by another session cannot be ruled out"
    return 0
  fi
  sha=$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')
  if [ -z "$sha" ]; then
    report_clear remote
    return 0
  fi
  if git -C "$REPO_REAL" cat-file -e "$sha^{commit}" 2>/dev/null; then
    report_clear remote
    return 0
  fi
  report_collision remote \
    "$remote has $BRANCH at $sha, a commit this checkout has never seen; another session pushed it. Fetch and re-check before dispatching."
  return 0
}

run_session_detector
run_checkout_detector
run_remote_detector

if [ "$COLLISIONS" -gt 0 ]; then
  exit 3
fi
if [ "$INCOMPLETES" -gt 0 ]; then
  exit 4
fi
exit 0
