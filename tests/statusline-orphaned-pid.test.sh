#!/usr/bin/env bash
# A 'running' heartbeat whose process is gone means the turn was SIGKILLed or
# the terminal was closed: show it as orphaned, never as "still working".
#
# The dead pid used here is a child this test spawned and reaped itself — never
# an invented number, which could belong to an unrelated live process on a busy
# machine and make the assertion meaningless.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
GREY=$'\033[38;5;245m'

show() {
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0
}

# A real child, run to completion and reaped: its pid is definitively ours and
# definitively dead.
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
if kill -0 "$DEAD_PID" 2>/dev/null; then fail "pid $DEAD_PID is still alive"; fi

write_hb "$HB" "status=running" "pid=$DEAD_PID"
show
assert_file_contains "$OUT" "⚠ codex gpt-5.6-sol"
assert_file_contains "$OUT" "no process"
assert_file_contains "$OUT" "$GREY"
assert_not_contains "$OUT" "⚙"

# A live pid keeps the running rendering (our own process is certainly alive).
write_hb "$HB" "status=running" "pid=$$"
show
assert_file_contains "$OUT" "⚙ codex gpt-5.6-sol"
assert_not_contains "$OUT" "no process"

# pid 0 means "unknown", not "dead": the check is guarded by > 0.
write_hb "$HB" "status=running" "pid=0"
show
assert_file_contains "$OUT" "⚙ codex gpt-5.6-sol"
assert_not_contains "$OUT" "no process"

# A non-running status is never reinterpreted, whatever the pid says.
write_hb "$HB" "status=done" "pid=$DEAD_PID" "verdict=APPROVED"
show
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_not_contains "$OUT" "no process"

write_hb "$HB" "status=failed" "pid=$DEAD_PID"
show
assert_file_contains "$OUT" "✗ codex gpt-5.6-sol"
assert_not_contains "$OUT" "no process"

# An orphaned turn shows no live activity even with an events file present.
cp "$TESTS_DIR/fixtures/ndjson/happy.ndjson" "$SANDBOX/events.ndjson"
write_hb "$HB" "status=running" "pid=$DEAD_PID" "events=$SANDBOX/events.ndjson"
show
assert_file_contains "$OUT" "no process"
assert_not_contains "$OUT" "writing reply…"
