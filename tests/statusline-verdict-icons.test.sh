#!/usr/bin/env bash
# Line 2's icon and colour encode the outcome. Getting this table wrong makes a
# rejected review look approved.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
GREEN=$'\033[38;5;78m'
YELLOW=$'\033[38;5;179m'
RED=$'\033[38;5;168m'
GREY=$'\033[38;5;245m'

show() {
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0
}

icon() {
  # icon <status> <verdict|null> <expected icon> <expected colour>
  write_hb "$HB" "status=$1" "verdict=$2"
  show
  assert_file_contains "$OUT" "$3 codex gpt-5.6-sol"
  assert_file_contains "$OUT" "$4"
}

icon "done" APPROVED                 "✓" "$GREEN"
icon "done" IMPLEMENTATION_COMPLETE  "✓" "$GREEN"
icon "done" IMAGE_READY              "✓" "$GREEN"
icon "done" REVISE                   "↺" "$YELLOW"
icon "done" IMPLEMENTATION_PARTIAL   "↺" "$YELLOW"
icon "done" REQUEST_CHANGES          "✗" "$RED"
icon "done" NEEDS_REWORK             "✗" "$RED"
icon "done" IMAGE_BLOCKED            "✗" "$RED"
# A finished turn with no verdict is a success, not an unknown.
icon "done" null                     "✓" "$GREEN"
icon "done" SOMETHING_NEW            "✓" "$GREEN"
icon "failed" null                   "✗" "$RED"
icon "running" null                  "⚙" "$YELLOW"
icon "mystery" null                  "·" "$GREY"

# The verdict text itself is printed once the turn is over…
write_hb "$HB" "status=done" "verdict=NEEDS_REWORK"
show
assert_file_contains "$OUT" "NEEDS_REWORK"

# …but never while it is still running (there is no verdict yet to trust).
write_hb "$HB" "status=running" "verdict=APPROVED" "pid=$$"
show
assert_not_contains "$OUT" "APPROVED"

# The target is shown, shortened, with the plan suffix dropped.
write_hb "$HB" "status=done" "target=docs/plans/test-harness-ci.plan.md"
show
assert_file_contains "$OUT" "test-harness-ci"
assert_not_contains "$OUT" "docs/plans"
assert_not_contains "$OUT" ".plan.md"

# Elapsed time: a finished turn shows its total duration, formatted. The
# timestamps must be recent or the staleness rule would hide line 2 entirely.
NOW="$(date +%s)"
write_hb "$HB" "status=done" "started_at=$((NOW - 125))" "updated_at=$NOW"
show
assert_file_contains "$OUT" "2m5s"
write_hb "$HB" "status=done" "started_at=$((NOW - 42))" "updated_at=$NOW"
show
assert_file_contains "$OUT" "42s"
# A clock that went backwards clamps to 0 instead of printing a negative.
write_hb "$HB" "status=done" "started_at=$((NOW + 1000))" "updated_at=$NOW"
show
assert_file_contains "$OUT" "0s"

# --- what the turn cost, humanized, only once it is over ---------------------
write_hb "$HB" "status=done" "tokens_in=1234" "tokens_out=56"
show
assert_file_contains "$OUT" "1.2k→56"
# k/M with at most one decimal, integer arithmetic only (no bc in bash 3.2).
write_hb "$HB" "status=done" "tokens_in=999" "tokens_out=0"
show
assert_file_contains "$OUT" "999→0"
write_hb "$HB" "status=done" "tokens_in=12345" "tokens_out=1500000"
show
assert_file_contains "$OUT" "12k→1.5M"
# A failed turn spent its tokens too, and says so.
write_hb "$HB" "status=failed" "tokens_in=2048" "tokens_out=16"
show
assert_file_contains "$OUT" "✗ codex gpt-5.6-sol"
assert_file_contains "$OUT" "2k→16"
# 'running' never shows them: the heartbeat carries null by contract, and the
# tokens of a PREVIOUS turn must not be painted onto the current one.
write_hb "$HB" "status=running" "pid=$$" "tokens_in=1234" "tokens_out=56"
show
assert_not_contains "$OUT" "1.2k"
assert_not_contains "$OUT" "→"

# NO_COLOR keeps the icons and drops the escapes.
export NO_COLOR=1
write_hb "$HB" "status=done" "verdict=APPROVED"
show
assert_no_escapes "$OUT"
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
unset NO_COLOR
