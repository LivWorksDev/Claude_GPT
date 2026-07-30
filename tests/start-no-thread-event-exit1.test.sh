#!/usr/bin/env bash
# No thread.started in the stream -> exit 1. There is nothing to resume later,
# so a "successful" turn without an id must not be recorded as one.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
SD="$(state_dir review)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

export CODEX_STUB_SCENARIO=no-thread-event
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "no thread.started"
assert_file_contains "$ERR" "could not capture a thread.started event"

KEY="$(tkey demo)"
assert_no_file "$SD/$KEY.thread"
assert_no_file "$SD/$KEY.last.txt"
# The reply itself WAS produced — it just cannot be attached to a thread.
assert_file_contains "$SD/$KEY.t1.reply.txt" "stub reply"
assert_json "$HB" '.status == "failed"'

# A turn with no thread id still cost real quota: exit code unchanged, ledger
# written, 'failed' heartbeat carrying the tokens, footer on stderr.
assert_file "$SD/$KEY.t1.usage.json"
assert_json "$SD/$KEY.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'
assert_file_contains "$ERR" 'USAGE: {"input_tokens":1234,"output_tokens":56}'

# A stream jq cannot slurp (garbage interleaved) lands in the same place: the
# jq error is swallowed and the emptiness check owns the outcome, so a jq exit
# code never leaks past the documented contract.
export CODEX_STUB_SCENARIO=corrupt-ndjson
run bash "$SCRIPTS/codex-start.sh" review demo-corrupt "$SANDBOX/p.tpl"
assert_rc 1 "corrupt NDJSON"
assert_file_contains "$ERR" "could not capture a thread.started event"
assert_no_file "$SD/$(tkey demo-corrupt).thread"
# The milestone filter tolerated the same garbage instead of dying.
assert_file_contains "$OUT" "» thread thr_stub_1"
assert_file_contains "$OUT" "  ✓ ok"
