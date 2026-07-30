#!/usr/bin/env bash
# check-drift.sh is the weekly smoke's only instrument, so its semantics are
# pinned here: a normal successful capture passes, an event class the capture
# never triggered is ADVISORY (a one-turn read-only smoke must not be
# structurally red), and a silent JSON type change IS drift.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

DRIFT="$TESTS_DIR/fixtures/ndjson/check-drift.sh"
FIX="$TESTS_DIR/fixtures/ndjson"

# --- 1. the fixture streams against themselves: no drift ---------------------
run bash "$DRIFT" "$FIX"/*.ndjson
assert_rc 0 "fixtures vs themselves"
assert_file_contains "$OUT" "no drift."
assert_not_contains "$OUT" "MISSING"

# --- 2. a minimal successful capture (what the weekly one-turn smoke sees) ---
# Required tier present, untriggered classes advisory — exit 0.
MIN="$SANDBOX/minimal.ndjson"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_smoke"}' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' \
  >"$MIN"
run bash "$DRIFT" "$MIN"
assert_rc 0 "minimal successful capture"
assert_file_contains "$OUT" "advisory item.completed|command_execution|item.exit_code:number"
assert_file_contains "$OUT" "advisory turn.failed|-|error.message:string"
assert_not_contains "$OUT" "MISSING"
assert_file_contains "$OUT" "no drift."

# --- 3. number-to-string drift on a required shape is detected ---------------
BAD="$SANDBOX/retyped.ndjson"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_smoke"}' \
  '{"type":"turn.completed","usage":{"input_tokens":"10","output_tokens":2}}' \
  >"$BAD"
run bash "$DRIFT" "$BAD"
assert_rc 1 "retyped usage field"
assert_file_contains "$OUT" "MISSING  turn.completed|-|usage.input_tokens:number"
assert_file_contains "$OUT" "usage.input_tokens:string"
assert_file_contains "$OUT" "drift detected"

# --- 4. a triggered class with the wrong shape is drift, not advisory --------
WRONG="$SANDBOX/wrongshape.ndjson"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_smoke"}' \
  '{"type":"item.completed","item":{"item_type":"command_execution","command":"ls","exit_code":"0","status":"completed"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' \
  >"$WRONG"
run bash "$DRIFT" "$WRONG"
assert_rc 1 "retyped exit_code with the class present"
assert_file_contains "$OUT" "class present, shape wrong"
assert_not_contains "$OUT" "advisory item.completed|command_execution|item.exit_code:number"

# --- 5. a brand-new field the fixtures never saw is reported as NEW ----------
NEWF="$SANDBOX/newfield.ndjson"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thr_smoke","protocol_rev":9}' \
  '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}' \
  >"$NEWF"
run bash "$DRIFT" "$NEWF"
assert_rc 1 "new field"
assert_file_contains "$OUT" "NEW in the captured stream"
assert_file_contains "$OUT" "protocol_rev:number"

# --- usage and dependency errors keep their exact codes ----------------------
run bash "$DRIFT"
assert_rc 64 "no arguments"
