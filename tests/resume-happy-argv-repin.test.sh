#!/usr/bin/env bash
# codex-resume.sh: the resumed turn re-pins model, effort AND the whole policy
# block. The shared options must sit BEFORE the `resume` subcommand, and
# `-c sandbox_mode=` must be present exactly once, right after the effort
# override — otherwise a resumed turn can inherit whatever sandbox lives in the
# user's config.toml.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_resume_1

seed_thread review demo thr_resume_1 1
KEY="$(tkey demo)"
SD="$(state_dir review)"
printf 'OLD REPLY\n' >"$SD/$KEY.last.txt"

run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0

assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}$SD/$KEY.t2.reply.txt${US}resume${US}thr_resume_1${US}-"

# read-only seats keep the native search tool on purpose.
assert_not_contains "$CODEX_STUB_LOG.argv.1" "web_search"

# Exactly one -c sandbox_mode= and it names the pinned sandbox, not a default.
assert_eq "1" "$(tr "$US" '\n' <"$CODEX_STUB_LOG.argv.1" | grep -c '^sandbox_mode=')" \
  "sandbox_mode occurrences"

assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn incremented"
assert_file_contains "$SD/$KEY.t2.reply.txt" "stub reply for ok"
assert_file_contains "$SD/$KEY.last.txt" "stub reply for ok"
assert_file_contains "$(stub_stdin 1)" "continue demo"
assert_file_contains "$ERR" "resuming codex thread thr_resume_1"
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, turn 2) ---"
assert_file_contains "$OUT" "THREAD_ID: thr_resume_1"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
assert_json "$HB" '.status == "done" and .turn == 2 and .role == "review"'

# Whitespace in the thread file is stripped before the id reaches argv.
printf '  thr_resume_1 \n\n' >"$SD/$KEY.thread"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "padded thread file"
assert_argv 2 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}$SD/$KEY.t3.reply.txt${US}resume${US}thr_resume_1${US}-"

# The implement role re-pins workspace-write the same way.
export CODEX_STUB_THREAD_ID=thr_impl_1
seed_thread implement demo thr_impl_1 0
run bash "$SCRIPTS/codex-resume.sh" implement demo "$SANDBOX/p.tpl"
assert_rc 0 "implement resume"
ISD="$(state_dir implement)"
assert_argv 3 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}workspace-write${US}-c${US}model_reasoning_effort=high${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=workspace-write${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--output-last-message${US}$ISD/$KEY.t1.reply.txt${US}resume${US}thr_impl_1${US}-"
