#!/usr/bin/env bash
# codex exits 0 but writes no final message -> exit 1, nothing persisted.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
KEY="$(tkey demo)"
SD="$(state_dir review)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

export CODEX_STUB_SCENARIO=empty-reply

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "empty reply"
assert_file_contains "$ERR" "codex exited 0 but produced no final message"
assert_no_file "$SD/$KEY.thread"
assert_no_file "$SD/$KEY.last.txt"
assert_no_file "$SD/$KEY.t1.reply.txt"
assert_json "$HB" '.status == "failed"'

# The events NDJSON was still captured — the failure must stay diagnosable.
assert_file_contains "$SD/$KEY.t1.events.ndjson" '"type":"thread.started"'

# A zero-byte reply is empty too ([ -s ], not [ -f ]).
: >"$SANDBOX/empty.txt"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_REPLY_FILE="$SANDBOX/empty.txt"
run bash "$SCRIPTS/codex-start.sh" review demo-zero "$SANDBOX/p.tpl"
assert_rc 1 "zero-byte reply"
assert_file_contains "$ERR" "produced no final message"
assert_no_file "$(state_dir review)/$(tkey demo-zero).thread"
