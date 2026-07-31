#!/usr/bin/env bash
# Behavior tests for the concurrent-session branch guard.
#
# The incident this guards against (data/decisions/concurrent-session-branch-collision.md):
# firstmate saw a clean tree at a known tip and dispatched a worker onto a branch
# an interactive session in a DIFFERENT directory of the SAME repository was still
# working. The two overlapped 31 minutes and the worker's push was rejected.
#
# Every case below drives the real bin/fm-branch-liveness.sh or the real
# bin/fm-spawn.sh against fixture repositories and a fixture transcript root.
# Nothing here reads firstmate's source: each assertion is on an exit code or on
# the operator-facing evidence the refusal must carry.
#
# The four guarantees the captain named, and where each is proven:
#   genuine collision refused        -> test_collision_across_clones
#   own worktree NOT refused         -> test_own_worker_worktree_is_not_a_collision
#   override works                   -> test_spawn_refuses_and_override_dispatches
#   detection failure fails closed   -> test_unreadable_signals_fail_closed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVENESS="$ROOT/bin/fm-branch-liveness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP=$(fm_test_tmproot fm-branch-liveness)
mkdir -p "$TMP"
# The helper registers its cleanup inside the command substitution's subshell, so
# re-register here; these fixtures are real git repositories and worth removing.
FM_TEST_CLEANUP_DIRS+=("$TMP")
trap fm_test_cleanup EXIT
# Physical path: macOS hands out /var/... temp roots that resolve to /private/var,
# and the guard reports the resolved location every checkout comparison uses.
TMP=$(cd "$TMP" && pwd -P)
fm_git_identity fmtest fmtest@example.invalid
export FM_BACKEND=tmux

BRANCH=story/collide
NOW=1700000000

iso_utc() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# --- fixtures ---------------------------------------------------------------

# make_repo <case>: a bare origin plus two INDEPENDENT clones of it, both with
# <BRANCH>. Two clones of one repository at two paths is the incident's exact
# shape, and the reason repository identity can never be path equality.
#   <case>/origin.git  <case>/clone-a (the fleet's clone)  <case>/clone-b (elsewhere)
make_repo() {
  local case_dir="$TMP/$1" seed
  mkdir -p "$case_dir"
  git init -q --bare "$case_dir/origin.git"
  seed="$case_dir/seed"
  git init -q -b main "$seed"
  printf 'seed\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm initial
  git -C "$seed" checkout -q -b "$BRANCH"
  git -C "$seed" commit -q --allow-empty -m "work on $BRANCH"
  git -C "$seed" push -q "$case_dir/origin.git" main "$BRANCH"
  rm -rf "$seed"
  git clone -q "$case_dir/origin.git" "$case_dir/clone-a"
  git clone -q "$case_dir/origin.git" "$case_dir/clone-b"
  # clone-a stays on main and knows the branch only through origin/<branch>, so
  # its worktrees are free to check the branch out. clone-b is the other session's
  # working copy.
  git -C "$case_dir/clone-b" checkout -q -b "$BRANCH" "origin/$BRANCH"
  printf '%s\n' "$case_dir"
}

# write_transcript <session-root> <session-id> <cwd> <branch> <epoch>
# One Claude-Code-shaped transcript record: the fields the scanner reads are
# cwd, gitBranch, timestamp, and sessionId.
write_transcript() {
  local root=$1 session=$2 cwd=$3 branch=$4 epoch=$5 dir
  dir="$root/$(printf '%s' "$cwd" | tr '/.' '-')"
  mkdir -p "$dir"
  printf '{"type":"custom-title","sessionId":"%s"}\n' "$session" > "$dir/$session.jsonl"
  printf '{"type":"assistant","sessionId":"%s","cwd":"%s","gitBranch":"%s","timestamp":"%s"}\n' \
    "$session" "$cwd" "$branch" "$(iso_utc "$epoch")" >> "$dir/$session.jsonl"
}

# run_liveness <session-root> [args...]
run_liveness() {
  local session_root=$1
  shift
  FM_BRANCH_LIVENESS_SESSION_ROOT="$session_root" \
    FM_BRANCH_LIVENESS_NOW="$NOW" \
    FM_BRANCH_LIVENESS_REMOTE_TIMEOUT=20 \
    "$LIVENESS" "$@" 2>&1
}

# --- 1. a genuine collision is refused, with named evidence -----------------

test_collision_across_clones() {
  local case_dir out status
  case_dir=$(make_repo collision)
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" other-session-id "$case_dir/clone-b" "$BRANCH" "$((NOW - 120))"

  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 3 "$status" "a live session on the branch in another clone must refuse"
  # The refusal has to be actionable on its own: which session, which branch,
  # which directory. "Something is using it" is what we already effectively had.
  assert_contains "$out" "other-session-id" "refusal must name the session"
  assert_contains "$out" "$BRANCH" "refusal must name the branch"
  assert_contains "$out" "$case_dir/clone-b" "refusal must name where that session is working"
  pass "a live session on the branch in a different clone of the same repository refuses"
}

# A session in an unrelated repository on the same branch NAME is not a
# collision: identity is the repository, not the string.
test_same_branch_name_in_another_repository_is_clear() {
  local case_dir other out status
  case_dir=$(make_repo unrelated)
  other="$TMP/unrelated-other"
  fm_git_init_commit "$other"
  git -C "$other" checkout -q -b "$BRANCH"
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" unrelated-session "$other" "$BRANCH" "$((NOW - 60))"

  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 0 "$status" "a same-named branch in an unrelated repository must not refuse"
  pass "the same branch name in an unrelated repository is not a collision"
}

# A session that has been quiet longer than the window is not live. Freshness is
# the record's own timestamp, not the file mtime, which fixture writing makes
# current on purpose here.
test_quiet_session_is_not_live() {
  local case_dir out status
  case_dir=$(make_repo quiet)
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" quiet-session "$case_dir/clone-b" "$BRANCH" "$((NOW - 7200))"

  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 0 "$status" "a session quiet for 2h with a 60m window must not refuse"
  pass "a session quiet beyond the activity window is not treated as live"
}

# --- 2. firstmate's own workers are never a collision -----------------------

test_own_worker_worktree_is_not_a_collision() {
  local case_dir home worktree out status
  case_dir=$(make_repo ownworker)
  worktree="$case_dir/crew-worktree"
  git -C "$case_dir/clone-a" worktree add -q "$worktree" "$BRANCH"
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" own-crew-session "$worktree" "$BRANCH" "$((NOW - 60))"

  # The control run first: with no ownership evidence to exclude it, this fixture
  # IS a refusal. That is what proves the pass below comes from the ownership
  # exclusion and not from the detector quietly seeing nothing.
  home="$case_dir/home"
  mkdir -p "$home/state"
  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH" --home "$home")
  status=$?
  expect_code 3 "$status" "control: without ownership evidence the same fixture must refuse"
  assert_contains "$out" "own-crew-session" "control refusal must name the session"

  # Which directory belongs to the pending work is the caller's answer, not the
  # detector's, so the caller names it. test_task_own_worktree_on_its_branch_dispatches
  # and test_sibling_worker_on_a_declared_branch_refuses prove fm-spawn derives
  # that answer from the right record.
  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH" \
    --home "$home" --exclude "$worktree")
  status=$?
  expect_code 0 "$status" "the caller's own worktree must never read as a collision"
  pass "a worker in the caller's own excluded worktree is not a collision (control refuses)"
}

# The isolated worktrees firstmate's workers live in are worktrees of the SAME
# repository, so the ordinary per-task branch dispatch must stay clear even with
# sibling workers live on their own branches.
test_sibling_workers_on_other_branches_are_clear() {
  local case_dir home sibling out status
  case_dir=$(make_repo siblings)
  sibling="$case_dir/sibling-worktree"
  git -C "$case_dir/clone-a" worktree add -q -b fm/other-task "$sibling" main
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" sibling-session "$sibling" fm/other-task "$((NOW - 30))"
  home="$case_dir/home"
  mkdir -p "$home/state"

  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch fm/new-task --home "$home")
  status=$?
  expect_code 0 "$status" "an ordinary fresh per-task branch must dispatch cleanly"
  pass "sibling workers on their own branches never block an ordinary dispatch"
}

# A transcript record can be larger than the scanner's tail window - real
# archives carry multi-megabyte tool results - and when it is the LAST record the
# window holds nothing but a fragment of it. Reading that as "unreadable" would
# refuse every dispatch, in every repository, for the whole activity window over a
# signal that is perfectly readable.
test_oversized_final_record_resolves() {
  local case_dir dir filler out status
  case_dir=$(make_repo oversized)
  dir="$case_dir/sessions/oversized"
  mkdir -p "$dir"
  filler=$(head -c 1400000 /dev/zero | tr '\0' x)
  {
    printf '{"type":"custom-title","sessionId":"huge-session"}\n'
    printf '{"type":"assistant","sessionId":"huge-session","cwd":"%s","gitBranch":"%s","timestamp":"%s","toolUseResult":"%s"}\n' \
      "$case_dir/clone-b" "$BRANCH" "$(iso_utc "$((NOW - 60))")" "$filler"
  } > "$dir/huge-session.jsonl"

  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 3 "$status" "a final record larger than the tail window must still resolve"
  assert_contains "$out" "huge-session" "the refusal must name the session the oversized record carries"
  assert_not_contains "$out" "no readable location" "a readable transcript must not report as unresolved"
  pass "a final transcript record larger than the tail window resolves instead of failing closed"
}

# --- 3. the local-checkout detector -----------------------------------------

# A checkout on the branch with uncommitted work is live regardless of any
# transcript; a clean, untouched one is not.
test_checkout_activity_decides() {
  local case_dir stray out status old
  case_dir=$(make_repo checkoutdetector)
  stray="$case_dir/stray-worktree"
  git -C "$case_dir/clone-a" worktree add -q "$stray" "$BRANCH"

  printf 'work in progress\n' > "$stray/wip.txt"
  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 3 "$status" "a dirty checkout on the branch must refuse"
  assert_contains "$out" "$stray" "the refusal must name the checkout"
  assert_contains "$out" "uncommitted changes" "the refusal must say why that checkout looks live"

  # Same checkout, clean, and every activity marker pushed outside the window.
  rm -f "$stray/wip.txt"
  old=$((NOW - 86400))
  find "$case_dir/clone-a/.git" "$stray" -exec touch -t "$(date -u -r "$old" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -u -d "@$old" +%Y%m%d%H%M.%S)" {} + 2>/dev/null || true
  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 0 "$status" "a clean, idle checkout on the branch is not a live session"
  pass "the checkout detector refuses on current activity, not on mere branch state"
}

# --- 4. the remote detector -------------------------------------------------

test_remote_head_never_seen_locally_refuses() {
  local case_dir out status
  case_dir=$(make_repo remoteahead)
  git -C "$case_dir/clone-b" commit -q --allow-empty -m "pushed by another session"
  git -C "$case_dir/clone-b" push -q origin "$BRANCH"

  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 3 "$status" "a remote head this checkout has never seen must refuse"
  assert_contains "$out" "never seen" "the refusal must say the commit is unknown locally"

  git -C "$case_dir/clone-a" fetch -q origin
  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 0 "$status" "once fetched, the same remote head is known and clears"
  pass "a remote head the checkout has never seen refuses; fetching it clears"
}

# A branch that does not exist locally is a fresh per-task branch: the guard must
# not reach the network for it at all, so a broken remote cannot block ordinary
# dispatch.
test_fresh_branch_never_touches_the_remote() {
  local case_dir out status
  case_dir=$(make_repo freshbranch)
  git -C "$case_dir/clone-a" remote set-url origin "$TMP/does-not-exist.git"

  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch fm/brand-new)
  status=$?
  expect_code 0 "$status" "a branch that does not exist locally must not probe the remote"
  pass "an ordinary fresh per-task branch never reaches the network"
}

# --- 5. detection that cannot complete fails closed -------------------------

test_unreadable_signals_fail_closed() {
  local case_dir dir out status
  case_dir=$(make_repo failclosed)

  # (a) a transcript active inside the window that exposes no readable location.
  # Silence here would be indistinguishable from "no session", which is exactly
  # the silent all-clear the incident was made of.
  mkdir -p "$case_dir/sessions/opaque"
  printf '{"type":"custom-title","sessionId":"opaque-session"}\n' \
    > "$case_dir/sessions/opaque/opaque-session.jsonl"
  out=$(run_liveness "$case_dir/sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 4 "$status" "an unreadable session transcript must fail closed, not clear"
  assert_contains "$out" "INCOMPLETE" "the incomplete result must be labelled"
  assert_contains "$out" "no readable location" "the incomplete result must say what could not be read"

  # (b) an existing branch whose remote cannot be read at all.
  git -C "$case_dir/clone-a" remote set-url origin "$TMP/definitely-not-a-repo.git"
  out=$(run_liveness "$case_dir/no-sessions" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 4 "$status" "an unreadable remote must fail closed for an existing branch"
  assert_contains "$out" "could not be read" "the incomplete result must name the unreadable remote"

  # (c) an ABSENT transcript root is a real answer, not a gap: no agent sessions
  # were ever recorded on this machine.
  git -C "$case_dir/clone-a" remote remove origin
  dir="$TMP/definitely-absent-session-root"
  out=$(run_liveness "$dir" --repo "$case_dir/clone-a" --branch "$BRANCH")
  status=$?
  expect_code 0 "$status" "an absent transcript root is an answer, not an unreadable signal"
  pass "unreadable signals fail closed; an absent signal stays a real answer"
}

# --- 6. the dispatch path: refusal, evidence, and the explicit override ------

# spawn_home <case-dir> <task-id> <brief-body>: a minimal firstmate home whose
# projects/alpha is the fleet's clone, with a brief in place so the spawn reaches
# the branch guard.
spawn_home() {
  local case_dir=$1 id=$2 body=$3 home
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/projects" "$home/config"
  ln -sfn "$case_dir/clone-a" "$home/projects/alpha"
  printf '%s\n' "$body" > "$home/data/$id/brief.md"
  printf '%s\n' "$home"
}

run_spawn() {  # <session-root> <home> <args...>
  local session_root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_BRANCH_LIVENESS_SESSION_ROOT="$session_root" \
    FM_BRANCH_LIVENESS_NOW="$NOW" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The spawn must stop at the guard, so the fixture never needs a real terminal.
# Past the guard it is expected to fail on the stub session provider - which is
# exactly how the override case proves it got through.
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
echo "fake tmux refuses: $*" >&2
exit 1
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" treehouse

test_spawn_refuses_and_override_dispatches() {
  local case_dir home out status
  case_dir=$(make_repo spawnguard)
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" captain-session "$case_dir/clone-b" "$BRANCH" "$((NOW - 90))"
  home=$(spawn_home "$case_dir" guard-task-a1 "Work the existing branch.")

  out=$(run_spawn "$case_dir/sessions" "$home" guard-task-a1 projects/alpha --harness claude --branch "$BRANCH")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn onto a branch another live session is using must refuse"
  assert_contains "$out" "refusing to spawn guard-task-a1" "the spawn refusal must name the task"
  assert_contains "$out" "captain-session" "the spawn refusal must carry the evidence"
  assert_absent "$home/state/guard-task-a1.meta" "a refused spawn must not record a task"

  out=$(run_spawn "$case_dir/sessions" "$home" guard-task-a1 projects/alpha --harness claude \
    --branch "$BRANCH" --allow-branch-collision)
  assert_contains "$out" "--allow-branch-collision was passed" "the override must announce itself"
  assert_contains "$out" "captain-session" "the override must still print every finding"
  assert_not_contains "$out" "refusing to spawn guard-task-a1" "the override must not still refuse"
  assert_contains "$out" "fake tmux refuses" "the override must let the spawn continue past the guard"
  pass "the dispatch path refuses on a collision and dispatches only under the explicit override"
}

# A brief that sends the worker onto some other branch must not be dispatchable
# without saying which branch, or the guard would silently check fm/<id> instead.
test_undeclared_brief_branch_refuses() {
  local case_dir home out status
  case_dir=$(make_repo undeclared)
  home=$(spawn_home "$case_dir" guard-task-b2 "First action: \`git checkout $BRANCH\` and continue the work.")

  out=$(run_spawn "$case_dir/no-sessions" "$home" guard-task-b2 projects/alpha --harness claude)
  status=$?
  [ "$status" -ne 0 ] || fail "an undeclared existing-branch brief must refuse"
  assert_contains "$out" "instructs a checkout of a branch other than fm/guard-task-b2" \
    "the refusal must explain what it found in the brief"
  assert_contains "$out" "$BRANCH" "the refusal must name the branch the brief points at"
  assert_absent "$home/state/guard-task-b2.meta" "a refused spawn must not record a task"

  # The ordinary brief, which creates its own per-task branch, is unaffected.
  home=$(spawn_home "$case_dir" guard-task-c3 "First action: create your branch: \`git checkout -b fm/guard-task-c3\`")
  out=$(run_spawn "$case_dir/no-sessions" "$home" guard-task-c3 projects/alpha --harness claude)
  assert_not_contains "$out" "instructs a checkout of a branch other than" \
    "the standard per-task-branch brief must not trip the declaration check"
  pass "a brief pointing at another branch refuses until --branch declares it"
}

# The isolated copy a task works in is a worktree of the same repository, on a
# branch named after the task. That copy is the task's own by construction, so a
# respawn - or a worktree taken before the guard ran - must still dispatch.
# Without this, every recovery of an existing task would refuse.
test_task_own_worktree_on_its_branch_dispatches() {
  local case_dir home worktree out
  case_dir=$(make_repo ownbranch)
  home=$(spawn_home "$case_dir" guard-task-d4 "First action: create your branch: \`git checkout -b fm/guard-task-d4\`")
  worktree="$case_dir/task-worktree"
  git -C "$case_dir/clone-a" worktree add -q -b fm/guard-task-d4 "$worktree" main
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" prior-attempt-session "$worktree" fm/guard-task-d4 "$((NOW - 30))"

  out=$(run_spawn "$case_dir/sessions" "$home" guard-task-d4 projects/alpha --harness claude)
  assert_not_contains "$out" "refusing to spawn guard-task-d4" \
    "a task's own worktree on its own branch must not refuse its dispatch"
  assert_contains "$out" "fake tmux refuses" "the spawn must reach the session provider"
  pass "a task's own isolated copy on its own branch never blocks that task's dispatch"
}

# A DIFFERENT task's crewmate is another live session, and on a declared existing
# branch that is exactly the push-rejection collision this guard exists to close.
# The fleet's own records must never clear it: only the record of THIS task does.
test_sibling_worker_on_a_declared_branch_refuses() {
  local case_dir home sibling out status
  case_dir=$(make_repo siblingdeclared)
  home=$(spawn_home "$case_dir" guard-task-e5 "Work the existing branch.")
  sibling="$case_dir/sibling-worker-worktree"
  git -C "$case_dir/clone-a" worktree add -q "$sibling" "$BRANCH"
  fm_write_meta "$home/state/sibling-task-a.meta" \
    "window=firstmate:fm-sibling-task-a" \
    "endpoint_task_id=sibling-task-a" \
    "worktree=$sibling" \
    "project=$case_dir/clone-a" \
    "harness=claude" \
    "kind=ship"
  mkdir -p "$case_dir/sessions"
  write_transcript "$case_dir/sessions" sibling-crew-session "$sibling" "$BRANCH" "$((NOW - 45))"

  out=$(run_spawn "$case_dir/sessions" "$home" guard-task-e5 projects/alpha --harness claude \
    --branch "$BRANCH")
  status=$?
  [ "$status" -ne 0 ] || fail "a sibling crewmate live on the declared branch must refuse"
  assert_contains "$out" "refusing to spawn guard-task-e5" "the refusal must name the refused task"
  assert_contains "$out" "sibling-crew-session" "the refusal must name the sibling's live session"
  assert_contains "$out" "$sibling" "the refusal must name where the sibling worker is working"
  assert_absent "$home/state/guard-task-e5.meta" "a refused spawn must not record a task"

  # The control: the very same worktree, recorded as THIS task's own copy, is a
  # respawn rather than a sibling, and still dispatches.
  rm -f "$home/state/sibling-task-a.meta"
  fm_write_meta "$home/state/guard-task-e5.meta" \
    "window=firstmate:fm-guard-task-e5" \
    "endpoint_task_id=guard-task-e5" \
    "worktree=$sibling" \
    "project=$case_dir/clone-a" \
    "harness=claude" \
    "kind=ship"
  out=$(run_spawn "$case_dir/sessions" "$home" guard-task-e5 projects/alpha --harness claude \
    --branch "$BRANCH")
  assert_not_contains "$out" "refusing to spawn guard-task-e5" \
    "control: the task's own recorded worktree must not refuse its own respawn"
  assert_contains "$out" "fake tmux refuses" "control: the respawn must reach the session provider"
  pass "a sibling task's live worker refuses a declared-branch dispatch (the task's own respawn clears)"
}

# `git checkout -- <path>` and `git checkout HEAD~1 -- <path>` name paths and a
# revision, not a branch. Reading either as a branch declaration would hard-refuse
# the dispatch of any task whose brief explains how to discard or restore a file.
test_pathspec_checkout_in_brief_is_not_a_declaration() {
  local case_dir home out
  case_dir=$(make_repo pathspec)
  home=$(spawn_home "$case_dir" guard-task-f6 \
"First action: create your branch: \`git checkout -b fm/guard-task-f6\`
If an edit goes wrong, discard it with \`git checkout -- src/app/page.tsx\`,
or restore the previous revision with \`git checkout HEAD~1 -- config/schema.sql\`.")

  out=$(run_spawn "$case_dir/no-sessions" "$home" guard-task-f6 projects/alpha --harness claude)
  assert_not_contains "$out" "instructs a checkout of a branch other than" \
    "a pathspec checkout in the brief must not read as an undeclared branch"
  assert_contains "$out" "fake tmux refuses" "the spawn must reach the session provider"
  pass "a brief that discards or restores paths with git checkout is not a branch declaration"
}

test_collision_across_clones
test_same_branch_name_in_another_repository_is_clear
test_quiet_session_is_not_live
test_own_worker_worktree_is_not_a_collision
test_sibling_workers_on_other_branches_are_clear
test_oversized_final_record_resolves
test_checkout_activity_decides
test_remote_head_never_seen_locally_refuses
test_fresh_branch_never_touches_the_remote
test_unreadable_signals_fail_closed
test_spawn_refuses_and_override_dispatches
test_undeclared_brief_branch_refuses
test_task_own_worktree_on_its_branch_dispatches
test_sibling_worker_on_a_declared_branch_refuses
test_pathspec_checkout_in_brief_is_not_a_declaration
