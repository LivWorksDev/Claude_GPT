#!/usr/bin/env bash
# TANDEM_CODEX_CWD — the optional working-root pin, in all three wrappers.
#
# A valid value becomes a `--cd <DIR>` pair at a fixed position, and the
# directory travels as ONE argv token even when its name contains spaces. An
# invalid or empty value is a usage error (64) — asserted under the
# `version-fail` stub scenario, which is what proves the check runs BEFORE
# need_codex: if it ran after, a broken toolchain would answer 3 instead.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt for {{TARGET}}"
printf 'fully rendered seat prompt\n' >"$SANDBOX/seat.txt"
export CODEX_STUB_SCENARIO=ok

# Spaces on purpose: a value that gets word-split shows up as extra tokens.
WORK="$SANDBOX/work root"
mkdir -p "$WORK"
KEY="$(tkey demo)"
SD="$(state_dir review)"

# --- start: --cd present, positioned, single token ---------------------------
export TANDEM_CODEX_CWD="$WORK"
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "start with a valid TANDEM_CODEX_CWD"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--cd${US}${WORK}${US}--output-last-message${US}$SD/$KEY.t1.reply.txt${US}-"

# --- resume: the pin rides BEFORE the `resume` subcommand --------------------
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume with a valid TANDEM_CODEX_CWD"
assert_argv 2 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--cd${US}${WORK}${US}--output-last-message${US}$SD/$KEY.t2.reply.txt${US}resume${US}thr_stub_1${US}-"

# --- swarm seats take the same pin -------------------------------------------
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 s-1 "$SANDBOX/seat.txt"
assert_rc 0 "swarm with a valid TANDEM_CODEX_CWD"
SEATMSG="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey run-1)/$(tkey s-1).reply.txt"
assert_argv 3 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=high${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--cd${US}${WORK}${US}--output-last-message${US}${SEATMSG}${US}-"

# --- invalid and empty values: exactly 64, even with a broken codex ----------
export CODEX_STUB_SCENARIO=version-fail

export TANDEM_CODEX_CWD="$SANDBOX/does-not-exist"
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "start, non-existent directory"
assert_file_contains "$ERR" "TANDEM_CODEX_CWD is not an existing directory"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "resume, non-existent directory"
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 s-2 "$SANDBOX/seat.txt"
assert_rc 64 "swarm, non-existent directory"

# A file is not a directory.
export TANDEM_CODEX_CWD="$SANDBOX/p.tpl"
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "start, a file instead of a directory"

# Set-but-empty is invalid like any other bad value — never "unset".
export TANDEM_CODEX_CWD=""
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "start, empty value"
assert_file_contains "$ERR" "TANDEM_CODEX_CWD is set but empty"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "resume, empty value"
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 s-2 "$SANDBOX/seat.txt"
assert_rc 64 "swarm, empty value"

# None of the rejected runs reached codex.
assert_no_file "$CODEX_STUB_LOG.argv.4"

# --- unset: the argv is exactly what it was before this feature existed ------
unset TANDEM_CODEX_CWD
export CODEX_STUB_SCENARIO=ok
run bash "$SCRIPTS/codex-start.sh" review plain "$SANDBOX/p.tpl"
assert_rc 0 "start without TANDEM_CODEX_CWD"
PKEY="$(tkey plain)"
assert_argv 4 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}$SD/$PKEY.t1.reply.txt${US}-"
assert_not_contains "$CODEX_STUB_LOG.argv.4" "--cd"
