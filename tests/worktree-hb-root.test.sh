#!/usr/bin/env bash
# A turn launched inside a linked git worktree must stay visible to a status
# line watching the MAIN checkout: the heartbeat goes to the main repo's
# .tandem, while thread state stays where the turn ran.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

MAIN="$CLAUDE_PROJECT_DIR"
WT="$SANDBOX/wt"

make_repo "$MAIN"
printf 'seed\n' >"$MAIN/f.txt"
commit_all "$MAIN"
git -C "$MAIN" worktree add -q -b tandem/demo "$WT" >/dev/null 2>&1 \
  || fail "git worktree add failed"

tpl "$SANDBOX/p.tpl" "work on {{TARGET}}"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_wt
# The stub must snapshot the heartbeat where the script actually writes it —
# the MAIN checkout, not CLAUDE_PROJECT_DIR.
export CODEX_STUB_HB_FILE="$MAIN/.tandem/state/current.json"
export CLAUDE_PROJECT_DIR="$WT"

run_in "$WT" bash "$SCRIPTS/codex-start.sh" implement demo "$SANDBOX/p.tpl"
assert_rc 0

KEY="$(tkey demo)"
MAIN_HB="$MAIN/.tandem/state/current.json"
WT_HB="$WT/.tandem/state/current.json"

# The heartbeat landed in the main checkout, and only there.
assert_file "$MAIN_HB"
assert_no_file "$WT_HB"
assert_json "$MAIN_HB" '.status == "done" and .role == "implement"'
# …and the running snapshot proves it was already there mid-turn.
assert_json "$(stub_hb 1)" '.status == "running"'
assert_json "$(stub_hb 1)" '.events == "'"$WT/.tandem/state/implement/$KEY.t1.events.ndjson"'"'

# Thread state stayed in the worktree, scoped to where the turn ran.
assert_file "$WT/.tandem/state/implement/$KEY.thread"
assert_no_file "$MAIN/.tandem/state/implement/$KEY.thread"
assert_eq "thr_wt" "$(cat "$WT/.tandem/state/implement/$KEY.thread")" "thread id"

# Both trees are gitignored.
assert_eq "*" "$(cat "$WT/.tandem/.gitignore")" "worktree .gitignore"
assert_eq "*" "$(cat "$MAIN/.tandem/.gitignore")" "main checkout .gitignore"

# A status line whose session is the MAIN checkout sees it directly.
statusline_payload ".workspace.project_dir=$MAIN" ".workspace.current_dir=$MAIN" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "status line in the main checkout"
assert_file_contains "$OUT" "codex gpt-5.6-sol"
assert_file_contains "$OUT" "implement"

# A status line whose session is INSIDE the worktree finds it via the reverse
# fallback through the common git dir.
statusline_payload ".workspace.project_dir=$WT" ".workspace.current_dir=$WT" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "status line inside the worktree"
assert_file_contains "$OUT" "codex gpt-5.6-sol"
assert_file_contains "$OUT" "implement"

# In a plain checkout the two roots coincide — no regression for the common case.
export CLAUDE_PROJECT_DIR="$MAIN"
export CODEX_STUB_HB_FILE="$MAIN/.tandem/state/current.json"
run_in "$MAIN" bash "$SCRIPTS/codex-start.sh" review plain "$SANDBOX/p.tpl"
assert_rc 0 "plain checkout"
assert_json "$MAIN_HB" '.role == "review"'
assert_file "$MAIN/.tandem/state/review/$(tkey plain).thread"

# Outside git entirely, the heartbeat falls back to the state root.
NOGIT="$SANDBOX/nogit"
mkdir -p "$NOGIT"
export CLAUDE_PROJECT_DIR="$NOGIT"
export CODEX_STUB_HB_FILE="$NOGIT/.tandem/state/current.json"
run_in "$NOGIT" bash "$SCRIPTS/codex-start.sh" review nogit "$SANDBOX/p.tpl"
assert_rc 0 "outside git"
assert_file "$NOGIT/.tandem/state/current.json"
