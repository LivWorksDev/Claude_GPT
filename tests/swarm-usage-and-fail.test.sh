#!/usr/bin/env bash
# codex-swarm.sh exit-code contract: 0 ok · 1 codex failure · 3 missing
# dependency · 64 usage error. Retrying a seat overwrites its own files and
# nothing else.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
printf 'seat prompt\n' >"$SANDBOX/seat.txt"
export CODEX_STUB_SCENARIO=ok

usage() {
  run bash "$SCRIPTS/codex-swarm.sh" "$@"
  assert_rc 64 "usage: [$*]"
  assert_file_contains "$ERR" "tandem:"
}

# The arity check is exact — four arguments, no more, no fewer.
usage
usage worker
usage worker run-1
usage worker run-1 seat-a
usage worker run-1 seat-a "$SANDBOX/seat.txt" extra
assert_file_contains "$ERR" "usage: codex-swarm.sh <tier> <run-id> <seat> <prompt-file>"

usage overlord run-1 seat-a "$SANDBOX/seat.txt"
assert_file_contains "$ERR" "unknown tier 'overlord' (expected: judge, worker or scout)"

usage worker run-1 seat-a "$SANDBOX/absent.txt"
assert_file_contains "$ERR" "prompt file not found:"

usage worker "..." seat-a "$SANDBOX/seat.txt"
assert_file_contains "$ERR" "run-id produced an empty state key"

usage worker run-1 "..." "$SANDBOX/seat.txt"
assert_file_contains "$ERR" "seat produced an empty state key"

assert_no_file "$CODEX_STUB_LOG.argv.1"

# --- codex failures ---------------------------------------------------------
export CODEX_STUB_SCENARIO=fail
export CODEX_STUB_EXIT=9
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 seat-a "$SANDBOX/seat.txt"
assert_rc 1 "codex failure is exit 1, not rc 9"
assert_file_contains "$ERR" "codex exec failed (exit 9)"

RUNKEY="$(tkey run-1)"
SEATKEY="$(tkey seat-a)"
UD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUNKEY"
assert_no_file "$UD/$SEATKEY.reply.txt"
assert_file "$UD/$SEATKEY.events.ndjson"
assert_file "$UD/$SEATKEY.events.ndjson.stderr"

export CODEX_STUB_SCENARIO=empty-reply
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 seat-a "$SANDBOX/seat.txt"
assert_rc 1 "empty reply"
assert_file_contains "$ERR" "codex exited 0 but produced no final message"

# A retry of the same seat succeeds and overwrites only that seat.
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_REPLY="retry worked"
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 seat-a "$SANDBOX/seat.txt"
assert_rc 0 "retry"
assert_file_contains "$UD/$SEATKEY.reply.txt" "retry worked"
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, run-1/seat-a) ---"

# --- missing dependency -----------------------------------------------------
MINBIN="$(make_minbin)"
ln -sf "$(command -v jq)" "$MINBIN/jq"
FULL_PATH="$PATH"
export PATH="$MINBIN"
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 seat-a "$SANDBOX/seat.txt"
assert_rc 3 "codex missing"
assert_file_contains "$ERR" "codex CLI not found in PATH"
export PATH="$FULL_PATH"
