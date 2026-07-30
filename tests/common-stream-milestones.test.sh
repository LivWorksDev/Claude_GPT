#!/usr/bin/env bash
# stream_milestones: one compact line per meaningful event, malformed input
# skipped, and never a SIGPIPE back into codex.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

FIX="$TESTS_DIR/fixtures/ndjson"

milestones() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  stream_milestones <"$1"
)

milestones "$FIX/happy.ndjson" >"$SANDBOX/happy.txt"
assert_file_contains "$SANDBOX/happy.txt" "» thread thr_fixture_happy"
# Whitespace inside a command is collapsed so one exec stays one line.
assert_file_contains "$SANDBOX/happy.txt" "» exec pytest -q tests/"
assert_file_contains "$SANDBOX/happy.txt" "  ✓ ok"
assert_file_contains "$SANDBOX/happy.txt" "  ✗ exit 1"
assert_file_contains "$SANDBOX/happy.txt" "» edit src/models.py"
assert_file_contains "$SANDBOX/happy.txt" "» web search"
assert_file_contains "$SANDBOX/happy.txt" "» turn done — tokens in 18432 · out 911"
# Reasoning and agent_message are not milestones — they would drown the panel.
assert_not_contains "$SANDBOX/happy.txt" "reasoning"
assert_not_contains "$SANDBOX/happy.txt" "agent_message"

# More than three changed paths collapses to "+N more".
milestones "$FIX/file-change-4.ndjson" >"$SANDBOX/files.txt"
assert_file_contains "$SANDBOX/files.txt" "» edit a.py, b.py, c.py +1 more"

# Failure events are surfaced, not swallowed.
milestones "$FIX/turn-failed.ndjson" >"$SANDBOX/failed.txt"
assert_file_contains "$SANDBOX/failed.txt" "✗ turn failed: model returned an unrecoverable error"
assert_file_contains "$SANDBOX/failed.txt" "  ✗ exit 2"

milestones "$FIX/error-event.ndjson" >"$SANDBOX/error.txt"
assert_file_contains "$SANDBOX/error.txt" "✗ stream disconnected before completion"

# Garbage lines are skipped; the valid ones around them still render.
milestones "$FIX/corrupt.ndjson" >"$SANDBOX/corrupt.txt"
assert_file_contains "$SANDBOX/corrupt.txt" "» thread thr_fixture_corrupt"
assert_file_contains "$SANDBOX/corrupt.txt" "  ✓ ok"
assert_not_contains "$SANDBOX/corrupt.txt" "not json"
assert_not_contains "$SANDBOX/corrupt.txt" "parse error"

# turn.completed without usage degrades to "?" instead of printing nothing.
printf '%s\n' '{"type":"turn.completed"}' >"$SANDBOX/nousage.ndjson"
milestones "$SANDBOX/nousage.ndjson" >"$SANDBOX/nousage.txt"
assert_file_contains "$SANDBOX/nousage.txt" "» turn done — tokens in ? · out ?"

# A command_execution with no command still renders.
printf '%s\n' '{"type":"item.started","item":{"item_type":"command_execution"}}' \
  >"$SANDBOX/nocmd.ndjson"
milestones "$SANDBOX/nocmd.ndjson" >"$SANDBOX/nocmd.txt"
assert_file_contains "$SANDBOX/nocmd.txt" "» exec ?"

# Wholly empty input is fine.
: >"$SANDBOX/empty.ndjson"
milestones "$SANDBOX/empty.ndjson" >"$SANDBOX/emptyout.txt"
assert_eq "0" "$(wc -c <"$SANDBOX/emptyout.txt" | tr -d ' ')" "empty input produces no lines"

# Long commands are clipped so one event can never wrap the panel.
LONG="$(printf 'x%.0s' $(seq 1 300))"
printf '{"type":"item.started","item":{"item_type":"command_execution","command":"%s"}}\n' \
  "$LONG" >"$SANDBOX/long.ndjson"
milestones "$SANDBOX/long.ndjson" >"$SANDBOX/long.txt"
assert_eq "» exec $(printf 'x%.0s' $(seq 1 110))" "$(cat "$SANDBOX/long.txt")" \
  "exec line clipped to 110 characters"
