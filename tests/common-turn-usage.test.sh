#!/usr/bin/env bash
# turn_usage: the token ledger of a turn, read straight from the NDJSON codex
# already wrote. One `turn.completed` (every stream ever observed) must come
# back verbatim; several are summed field by field, because discarding a retry's
# cost is the one unrecoverable error here. Anything else — no such event,
# garbage lines, non-numeric values — degrades to "no usage", never to an error.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

FIX="$SANDBOX/fix"
mkdir -p "$FIX"

tu() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  turn_usage "$1"
)

# --- one turn.completed: the sum IS the object, verbatim ---------------------
# Field names and values are codex's own (a real 0.144.4 stream shape).
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_usage"}' \
  '{"type":"item.completed","item":{"item_type":"command_execution","exit_code":0}}' \
  '{"type":"turn.completed","usage":{"input_tokens":1177125,"cached_input_tokens":1060608,"output_tokens":17038,"reasoning_output_tokens":12649}}' \
  >"$FIX/one.ndjson"

GOT="$(tu "$FIX/one.ndjson")"
printf '%s' "$GOT" >"$SANDBOX/one.json"
WANT="$(jq -c 'select(.type == "turn.completed") | .usage' "$FIX/one.ndjson")"
assert_json "$SANDBOX/one.json" ". == $WANT"
# Byte-for-byte too: the object is emitted compact, on a single line, so it can
# ride in the `USAGE:` footer the skills copy into the round log.
assert_eq '{"input_tokens":1177125,"cached_input_tokens":1060608,"output_tokens":17038,"reasoning_output_tokens":12649}' \
  "$GOT" "single turn.completed is verbatim"
assert_eq "1" "$(tu "$FIX/one.ndjson" | wc -l | tr -d ' ')" "one line of output"

# --- no turn.completed: nothing at all, exit 0 -------------------------------
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_usage"}' \
  '{"type":"turn.failed","error":{"message":"stub forced failure"}}' \
  >"$FIX/none.ndjson"
RCU=0
GOT="$(tu "$FIX/none.ndjson")" || RCU=$?
assert_eq "0" "$RCU" "turn_usage rc without turn.completed"
assert_eq "" "$GOT" "output without turn.completed"

# A turn.completed with no usage object at all is the same case.
printf '%s\n' '{"type":"turn.completed"}' >"$FIX/nousage.ndjson"
assert_eq "" "$(tu "$FIX/nousage.ndjson")" "turn.completed without usage"

# Empty, absent and non-NDJSON files never produce an error either.
: >"$FIX/empty.ndjson"
RCU=0
GOT="$(tu "$FIX/empty.ndjson")" || RCU=$?
assert_eq "0" "$RCU" "turn_usage rc on an empty file"
assert_eq "" "$GOT" "output for an empty file"
RCU=0
GOT="$(tu "$FIX/absent.ndjson")" || RCU=$?
assert_eq "0" "$RCU" "turn_usage rc on a missing file"
assert_eq "" "$GOT" "output for a missing file"

# --- two turn.completed: summed field by field -------------------------------
printf '%s\n' \
  '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":40,"reasoning_output_tokens":30}}' \
  '{"type":"turn.completed","usage":{"input_tokens":234,"cached_input_tokens":400,"output_tokens":16,"reasoning_output_tokens":10}}' \
  >"$FIX/two.ndjson"
assert_eq '{"input_tokens":1234,"cached_input_tokens":1000,"output_tokens":56,"reasoning_output_tokens":40}' \
  "$(tu "$FIX/two.ndjson")" "two turn.completed are summed"

# A field only the second event carries still lands in the sum: a future numeric
# field rides along without touching this code.
printf '%s\n' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' \
  '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1,"future_tokens":7}}' \
  >"$FIX/newfield.ndjson"
assert_eq '{"input_tokens":15,"output_tokens":3,"future_tokens":7}' \
  "$(tu "$FIX/newfield.ndjson")" "a field present in only one event"

# --- malformed lines interleaved are skipped, the valid ones still count -----
printf '%s\n' \
  'not json at all' \
  '{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":40}}' \
  '{"type":"turn.completed","usage":' \
  '' \
  '}{ still garbage' \
  '{"type":"turn.completed","usage":{"input_tokens":234,"output_tokens":16}}' \
  >"$FIX/corrupt.ndjson"
assert_eq '{"input_tokens":1234,"output_tokens":56}' \
  "$(tu "$FIX/corrupt.ndjson")" "garbage lines are skipped"

# Garbage alone is simply no usage.
printf '%s\n' 'not json at all' '{"broken' >"$FIX/allgarbage.ndjson"
RCU=0
GOT="$(tu "$FIX/allgarbage.ndjson")" || RCU=$?
assert_eq "0" "$RCU" "turn_usage rc on pure garbage"
assert_eq "" "$GOT" "output for pure garbage"

# --- non-numeric values are dropped, they never break the sum ----------------
printf '%s\n' \
  '{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":40,"model":"gpt-5.6-sol"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":234,"output_tokens":16,"model":"gpt-5.6-sol","capped":true,"detail":{"a":1}}}' \
  >"$FIX/mixed.ndjson"
assert_eq '{"input_tokens":1234,"output_tokens":56}' \
  "$(tu "$FIX/mixed.ndjson")" "non-numeric usage fields are dropped"

# A usage that is not an object at all is ignored like any other malformed shape.
printf '%s\n' \
  '{"type":"turn.completed","usage":"lots"}' \
  '{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":1}}' \
  >"$FIX/badusage.ndjson"
assert_eq '{"input_tokens":7,"output_tokens":1}' \
  "$(tu "$FIX/badusage.ndjson")" "a non-object usage is ignored"
