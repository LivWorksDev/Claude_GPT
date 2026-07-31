#!/usr/bin/env bash
# The semaphore's two dials are validated fail-closed and BEFORE the toolchain:
# under the `version-fail` scenario a bad value still answers 64, which is what
# proves the check precedes need_codex (it would answer 3 otherwise) — the same
# contract, and the same proof, as TANDEM_CODEX_CWD.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
printf 'seat prompt\n' >"$SANDBOX/seat.txt"

export CODEX_STUB_SCENARIO=version-fail

reject() {
  # reject <var-name> <value> — `env VAR=` defines it EMPTY, which is exactly the
  # case a `${VAR:-default}` expansion would have swallowed in silence.
  local name="$1" value="$2"
  run env "$name=$value" bash "$SCRIPTS/codex-swarm.sh" \
    worker run-e seat-e "$SANDBOX/seat.txt"
  assert_rc 64 "$name=[$value]"
  assert_file_contains "$ERR" "$name"
}

reject TANDEM_ULTRA_CONCURRENCY banana
assert_file_contains "$ERR" "must be a positive integer, got 'banana'"
reject TANDEM_ULTRA_CONCURRENCY 0
reject TANDEM_ULTRA_CONCURRENCY -2
reject TANDEM_ULTRA_CONCURRENCY 2.5
reject TANDEM_ULTRA_CONCURRENCY ""
assert_file_contains "$ERR" "TANDEM_ULTRA_CONCURRENCY is set but empty"

reject TANDEM_ULTRA_SLOT_TIMEOUT banana
reject TANDEM_ULTRA_SLOT_TIMEOUT 0
reject TANDEM_ULTRA_SLOT_TIMEOUT ""
assert_file_contains "$ERR" "TANDEM_ULTRA_SLOT_TIMEOUT is set but empty"

# Not one of the rejected runs reached codex.
assert_no_file "$CODEX_STUB_LOG.argv.1"

# --- leading zeros are decimal, not octal ------------------------------------
# `08` and `09` are a fatal arithmetic error to bash unless the value is
# normalized with 10# before any arithmetic touches it. Exit 0 (and the banner's
# eight) is the whole lesson: the seat ran, nothing aborted.
export CODEX_STUB_SCENARIO=ok
run env TANDEM_ULTRA_CONCURRENCY=08 bash "$SCRIPTS/codex-swarm.sh" \
  worker run-e seat-08 "$SANDBOX/seat.txt"
assert_rc 0 "concurrency 08 is eight"
assert_file_contains "$ERR" "concurrency=8"

run env TANDEM_ULTRA_CONCURRENCY=09 TANDEM_ULTRA_SLOT_TIMEOUT=09 \
  bash "$SCRIPTS/codex-swarm.sh" worker run-e seat-09 "$SANDBOX/seat.txt"
assert_rc 0 "concurrency and timeout 09 are nine"
assert_file_contains "$ERR" "concurrency=9"

# --- unset: the default is 4, and it is observable ---------------------------
run bash "$SCRIPTS/codex-swarm.sh" worker run-e seat-d "$SANDBOX/seat.txt"
assert_rc 0 "both dials unset"
assert_file_contains "$ERR" "concurrency=4"
note "TANDEM_ULTRA_CONCURRENCY / TANDEM_ULTRA_SLOT_TIMEOUT — fail-closed, decimal, default 4"
