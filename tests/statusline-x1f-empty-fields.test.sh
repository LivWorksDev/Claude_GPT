#!/usr/bin/env bash
# The \x1f transport. This is the bug that shipped once: @tsv + IFS=$'\t'
# collapses consecutive empty fields (tab is IFS whitespace), so every field
# after an empty one shifts left — with a null verdict the events PATH landed in
# the verdict variable and got painted on screen.
#
# The unit separator does not collapse. These cases prove it on both payloads.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
EVENTS="$SANDBOX/events.ndjson"
cp "$TESTS_DIR/fixtures/ndjson/happy.ndjson" "$EVENTS"

render() {
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" "$@" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  return 0
}

# --- line 2: empty verdict must not shift the events path -------------------
# status running + a live pid so the activity block (which reads .events) runs.
write_hb "$HB" "status=running" "verdict=null" "events=$EVENTS" "pid=$$" \
  "role=review" "effort=xhigh" "sandbox=read-only" "turn=2" "target=demo"
render
assert_rc 0
assert_file_contains "$OUT" "⚙ codex gpt-5.6-sol"
assert_file_contains "$OUT" "review"
assert_file_contains "$OUT" "t2"
assert_file_contains "$OUT" "read-only"
# The events path was read as a PATH (activity rendered), not printed as text.
assert_file_contains "$OUT" "writing reply…"
assert_not_contains "$OUT" "$EVENTS"

# --- several consecutive empty fields ---------------------------------------
# effort, sandbox, target and verdict all empty at once: turn, pid and the
# events path must still line up.
write_hb "$HB" "status=running" "effort=" "sandbox=" "target=" "verdict=null" \
  "events=$EVENTS" "pid=$$" "turn=7"
render
assert_rc 0 "four empty fields"
assert_file_contains "$OUT" "t7"
assert_file_contains "$OUT" "writing reply…"
assert_not_contains "$OUT" "$EVENTS"

# --- an empty events path must not swallow the fields before it -------------
write_hb "$HB" "status=done" "verdict=APPROVED" "events=null" "turn=3"
render
assert_rc 0 "empty events"
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_file_contains "$OUT" "t3"
assert_file_contains "$OUT" "APPROVED"

# --- line 1: an empty effort must not shift the context percentage ----------
render '.effort.level=""'
assert_rc 0 "empty effort"
assert_file_contains "$OUT" "ctx 42% ▓▓▓▓░░░░░░"
assert_file_contains "$OUT" '$1.24'

# …nor must an empty display name shift everything after it.
render '.model.display_name=""' '.model.id=""'
assert_rc 0 "empty model"
assert_file_contains "$OUT" "◈ ?"
assert_file_contains "$OUT" "ctx 42%"

# --- a value containing a literal tab does not split a field ----------------
write_hb "$HB" "status=done" "target=$(printf 'a\tb')" "verdict=APPROVED"
render
assert_rc 0 "tab inside a field"
assert_file_contains "$OUT" "APPROVED"

# --- and the whole thing survives a heartbeat with every field empty ---------
write_hb "$HB" "status=running" "role=" "model=" "effort=" "sandbox=" \
  "target=" "verdict=null" "events=null" "turn=0" "pid=0"
render
assert_rc 0 "everything empty"
assert_file_contains "$OUT" "⚙ codex"
assert_not_contains "$OUT" "t0"
