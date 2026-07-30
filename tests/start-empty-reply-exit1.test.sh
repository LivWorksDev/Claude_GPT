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

# The turn burned its quota BEFORE the wrapper rejected it: the exit code is
# untouched, but the tokens are accounted for anyway — in the durable ledger,
# in the 'failed' heartbeat and in the footer the FAILED report needs.
assert_file "$SD/$KEY.t1.usage.json"
assert_json "$SD/$KEY.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'
assert_file_contains "$ERR" 'USAGE: {"input_tokens":1234,"output_tokens":56}'

# --- a retry NEVER overwrites the paid attempt's ledger ----------------------
# The failed start above left no thread file, so the retry comes back through
# start — with a monotonic attempt number: t1's usage (the quota the rejected
# attempt burned) must survive, and the retry lands in t2 with its own values.
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_TOKENS_IN=9000
export CODEX_STUB_TOKENS_OUT=77
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "retry after the empty reply"
assert_json "$SD/$KEY.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_file "$SD/$KEY.t2.usage.json"
assert_json "$SD/$KEY.t2.usage.json" '. == {"input_tokens":9000,"output_tokens":77}'
assert_file "$SD/$KEY.t2.reply.txt"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "monotonic attempt number"
unset CODEX_STUB_TOKENS_IN CODEX_STUB_TOKENS_OUT

# A zero-byte reply is empty too ([ -s ], not [ -f ]).
: >"$SANDBOX/empty.txt"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_REPLY_FILE="$SANDBOX/empty.txt"
run bash "$SCRIPTS/codex-start.sh" review demo-zero "$SANDBOX/p.tpl"
assert_rc 1 "zero-byte reply"
assert_file_contains "$ERR" "produced no final message"
assert_no_file "$(state_dir review)/$(tkey demo-zero).thread"
