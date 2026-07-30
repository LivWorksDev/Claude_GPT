#!/usr/bin/env bash
# Meta-test of the harness itself: a hung case must be reported as TIMEOUT, must
# make the run fail, and must not leave a single descendant alive.
#
# The hung case cannot live in the normal inventory or the suite would never be
# green, so a NESTED runner is pointed at tests/fixtures/hang/ with a short
# TEST_TIMEOUT. THIS test exits 0 when that nested run failed correctly.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

NESTED="$SANDBOX/nested"
mkdir -p "$NESTED"

run env \
  RUNNER_TEMP="$NESTED" \
  TANDEM_TEST_CASES_DIR="$TESTS_DIR/fixtures/hang" \
  TEST_TIMEOUT=3 \
  TESTS_BASH="$TESTS_BASH" \
  "$TESTS_BASH" "$TESTS_DIR/run.sh"

assert_rc 1 "the nested run must fail"
assert_file_contains "$OUT" "TIMEOUT hang-fixture"
assert_file_contains "$OUT" "group kill"
assert_file_contains "$OUT" "0 passed, 1 failed (1 timed out)"
assert_file_contains "$OUT" "sandboxes kept for inspection"
# The watchdog reported a timeout, not an ordinary assertion failure.
assert_not_contains "$OUT" "FAIL hang-fixture"

SB="$(ls -d "$NESTED"/tandem-tests.*/hang-fixture 2>/dev/null)"
[ -n "$SB" ] || fail "the nested runner did not keep the red sandbox"
assert_file "$SB/.timeout"
assert_file "$SB/test.log"

# It really did hang inside codex rather than dying early somewhere else.
assert_file "$SB/stub.argv.1"
assert_file_contains "$SB/stub.argv.1" "--output-last-message"

# Now the point of the whole exercise: the group kill reached the descendants.
# The hung case spawned a background job that writes this marker after 6 s; the
# watchdog fired at 3 s, so it must never appear.
sleep 7
assert_no_file "$SB/descendant-survived"

# And the nested runner itself left nothing of its own behind.
assert_no_file "$SB/.timeout.tmp"
