#!/usr/bin/env bash
# A codex failure is reported as the documented exit 1 — never as codex's own
# rc, and never as the "usage" or "dependency" codes.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
KEY="$(tkey demo)"
SD="$(state_dir review)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

export CODEX_STUB_SCENARIO=fail
export CODEX_STUB_EXIT=7

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "codex failure"
assert_file_contains "$ERR" "codex exec failed (exit 7)"
assert_file_contains "$ERR" "codex-stub: forced failure"
assert_file_contains "$ERR" "full logs:"

# No thread is persisted, no last.txt pointer is moved, the turn file exists
# (it is written before the call) and the EXIT guard left 'failed' behind.
assert_no_file "$SD/$KEY.thread"
assert_no_file "$SD/$KEY.last.txt"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "turn counter"
assert_json "$HB" '.status == "failed"'
assert_json "$HB" '.role == "review" and .turn == 1'

# The pre-deletion of the reply file is observable: the stub writes nothing in
# this scenario, so a stale reply could only come from a previous turn.
assert_no_file "$SD/$KEY.t1.reply.txt"

# rc 64 and rc 3 are distinct outcomes and must not degrade into 1.
export CODEX_STUB_EXIT=64
run bash "$SCRIPTS/codex-start.sh" review demo2 "$SANDBOX/p.tpl"
assert_rc 1 "codex exiting 64 is still a codex failure (exit 1)"
assert_file_contains "$ERR" "codex exec failed (exit 64)"

# A codex rc of 1 is still 1 — same code, different reason, same contract.
export CODEX_STUB_EXIT=1
run bash "$SCRIPTS/codex-start.sh" review demo3 "$SANDBOX/p.tpl"
assert_rc 1 "codex exiting 1"
assert_file_contains "$ERR" "codex exec failed (exit 1)"
