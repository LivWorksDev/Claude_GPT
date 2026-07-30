#!/usr/bin/env bash
# A finished turn stays on screen for 15 minutes and then stops cluttering the
# prompt. A running turn is never suppressed: it is the one thing worth showing.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
NOW="$(date +%s)"

lines() {
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0
  wc -l <"$OUT" | tr -d ' '
}

# Fresh: two lines.
write_hb "$HB" "status=done" "updated_at=$NOW" "started_at=$((NOW - 10))"
assert_eq "2" "$(lines)" "fresh done heartbeat"

# 899 s old: still inside the window.
write_hb "$HB" "status=done" "updated_at=$((NOW - 899))" "started_at=$((NOW - 910))"
assert_eq "2" "$(lines)" "899s old"

# 901 s old: suppressed, and line 1 is untouched.
write_hb "$HB" "status=done" "updated_at=$((NOW - 901))" "started_at=$((NOW - 910))"
assert_eq "1" "$(lines)" "901s old"
assert_file_contains "$OUT" "◈ Claude Fable 5"
assert_not_contains "$OUT" "codex"

# Failed turns age out the same way.
write_hb "$HB" "status=failed" "updated_at=$((NOW - 5000))"
assert_eq "1" "$(lines)" "old failed heartbeat"

# A running turn is exempt however old the timestamp is — with pid 0 it stays
# 'running' rather than being reinterpreted as orphaned.
write_hb "$HB" "status=running" "pid=0" "updated_at=$((NOW - 99999))" \
  "started_at=$((NOW - 99999))"
assert_eq "2" "$(lines)" "very old running heartbeat"
assert_file_contains "$OUT" "⚙ codex"

# A garbage timestamp is treated as 0, which is more than 900 s ago for any
# finished turn: suppressed, not crashed.
write_hb "$HB" "status=done" "updated_at=0" "started_at=0"
assert_eq "1" "$(lines)" "zero timestamp"

printf '{"status":"done","updated_at":"yesterday","started_at":"before"}\n' >"$HB"
assert_eq "1" "$(lines)" "non-numeric timestamp"

# A timestamp in the future (clock skew) is recent, not stale.
write_hb "$HB" "status=done" "updated_at=$((NOW + 600))" "started_at=$NOW"
assert_eq "2" "$(lines)" "future timestamp"
