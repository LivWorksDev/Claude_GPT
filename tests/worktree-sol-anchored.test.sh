#!/usr/bin/env bash
# The worktree anchoring the implement/review skills use: the turn RUNS in the
# linked worktree (`--cd`), while the thread state and the heartbeat stay in the
# MAIN checkout. Those are two different contracts on purpose — mixing them
# (repointing CLAUDE_PROJECT_DIR at the worktree) would make codex-show blind
# from the main checkout and would destroy the thread with the worktree.
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
export CODEX_STUB_THREAD_ID=thr_anchored
# CLAUDE_PROJECT_DIR is NOT touched: only the execution root moves.
export TANDEM_CODEX_CWD="$WT"

run_in "$MAIN" bash "$SCRIPTS/codex-start.sh" implement demo "$SANDBOX/p.tpl"
assert_rc 0

KEY="$(tkey demo)"
SD="$(state_dir implement)"

# The turn is anchored to the worktree…
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}workspace-write${US}-c${US}model_reasoning_effort=high${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=workspace-write${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--cd${US}${WT}${US}--output-last-message${US}$SD/$KEY.t1.reply.txt${US}-"

# …and the durable state is not: nothing at all was written inside the worktree.
assert_file "$SD/$KEY.thread"
assert_eq "thr_anchored" "$(cat "$SD/$KEY.thread")" "thread id in the main checkout"
assert_json "$MAIN/.tandem/state/current.json" '.status == "done" and .role == "implement"'
assert_no_file "$WT/.tandem"

# Delete the worktree and build it again from the same branch: the thread has
# to survive, because it never lived there.
git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1 \
  || fail "git worktree remove failed"
assert_no_file "$WT"
assert_file "$SD/$KEY.thread"

git -C "$MAIN" worktree add -q "$WT" tandem/demo >/dev/null 2>&1 \
  || fail "git worktree add (recreate) failed"

# codex-show from the MAIN checkout still finds the thread…
run_in "$MAIN" bash "$SCRIPTS/codex-show.sh" implement demo
assert_rc 0 "codex-show after recreating the worktree"
assert_file_contains "$OUT" "thread_id: thr_anchored"

# …and resuming from the MAIN checkout continues that same thread, still
# anchored to the recreated worktree.
run_in "$MAIN" bash "$SCRIPTS/codex-resume.sh" implement demo "$SANDBOX/p.tpl"
assert_rc 0 "resume after recreating the worktree"
assert_file_contains "$CODEX_STUB_LOG.argv.2" "resume${US}thr_anchored"
assert_file_contains "$CODEX_STUB_LOG.argv.2" "--cd${US}${WT}"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn incremented"
assert_no_file "$WT/.tandem"
