#!/usr/bin/env bash
# The status line's hardest contract: never fail, never block. Whatever it is
# fed, it exits 0 — a status line that errors simply disappears from the UI.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

feed() {
  printf '%s' "$1" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0 "stdin: [${1:0:40}]"
  # Per-invocation: $ERR is overwritten by the next case, so a leak that is
  # only checked at the end would be masked by whichever case ran last.
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "stderr for stdin [${1:0:40}]"
}

feed ''
feed 'not json at all'
feed '{'
feed 'null'
feed '[]'
feed '"a string"'
feed '42'
feed '{"model":null}'
feed '{"model":{"display_name":null}}'
feed '{"context_window":{"used_percentage":null}}'
feed '{"cost":{"total_cost_usd":"free"}}'
feed '{"workspace":{"current_dir":"/nonexistent/path/xyz"}}'
feed "$(statusline_payload)"

# Even with nothing usable at all, the model placeholder is printed.
printf '' | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>&1
assert_file_contains "$OUT" "◈ ?"

# --- a broken heartbeat cannot break the line -------------------------------
HB_DIR="$CLAUDE_PROJECT_DIR/.tandem/state"
mkdir -p "$HB_DIR"
PAYLOAD="$(statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR")"

hb_feed() {
  printf '%s' "$1" >"$HB_DIR/current.json"
  printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0 "heartbeat: [${1:0:40}]"
  assert_file_contains "$OUT" "◈ Claude Fable 5"
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "stderr for heartbeat [${1:0:40}]"
}

hb_feed ''
hb_feed 'not json'
hb_feed '{'
hb_feed 'null'
hb_feed '[]'
hb_feed '{}'
hb_feed '{"status":"running"}'
hb_feed '{"status":null,"turn":null,"pid":null,"updated_at":null,"started_at":null}'
hb_feed '{"status":"running","pid":"not-a-number","updated_at":"soon","started_at":"never"}'
hb_feed '{"status":"weird-new-status","updated_at":0,"started_at":0}'
hb_feed '{"status":"running","events":"/nonexistent/events.ndjson","pid":0}'

# Token counts are the newest arithmetic on the line, so every shape that is not
# a plain non-negative integer has to be sanitized BEFORE it reaches an
# arithmetic context — `[ x -gt 0 ]` on a string prints "integer expression
# expected", which is UI noise, and a decimal or a negative would render
# nonsense. In every one of these the whole token segment is simply omitted.
tokens_feed() {
  # tokens_feed <tokens_in json> <tokens_out json>
  hb_feed '{"status":"done","updated_at":'"$(date +%s)"',"started_at":'"$(date +%s)"',"tokens_in":'"$1"',"tokens_out":'"$2"'}'
  assert_not_contains "$OUT" "→"
}
tokens_feed '"lots"' '"few"'
tokens_feed '12.5' '3.7'
tokens_feed '-5' '-1'
# A digits-only STRING is corruption too: the heartbeat writes JSON numbers, so
# a string there means something else produced the file, and one bad half is
# enough to drop the whole segment (half a cost is a misleading cost).
tokens_feed '1234' '"56"'
tokens_feed '"1234"' '56'
tokens_feed 'true' 'false'
tokens_feed '[1234]' '{"a":1}'
tokens_feed '99999999999999999999999' '56'
tokens_feed '1234' 'null'

# The same payload with two honest integers DOES render, so the cases above are
# proving a sanitizer and not an unreachable branch.
hb_feed '{"status":"done","updated_at":'"$(date +%s)"',"started_at":'"$(date +%s)"',"tokens_in":1234,"tokens_out":56}'
assert_file_contains "$OUT" "1.2k→56"

# A heartbeat that is a directory (a botched install) is not a crash either.
rm -f "$HB_DIR/current.json"
mkdir -p "$HB_DIR/current.json"
printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "heartbeat is a directory"
rmdir "$HB_DIR/current.json"

# --- a broken Opus attempt state cannot break the line either ----------------
# The contract is "line 2 is ABSENT", not merely "no crash": a placeholder
# rendered from a half-parsed file would sail through an rc/stderr-only
# assertion. There is no heartbeat left on disk here, so line 2 has exactly one
# possible source.
IMPL_DIR="$CLAUDE_PROJECT_DIR/.tandem/state/implement-claude"
mkdir -p "$IMPL_DIR"

impl_feed() {
  printf '%s' "$1" >"$IMPL_DIR/demo.json"
  printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0 "attempt state: [${1:0:40}]"
  assert_file_contains "$OUT" "◈ Claude Fable 5"
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "stderr for attempt state [${1:0:40}]"
  assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "line count for attempt state [${1:0:40}]"
  assert_not_contains "$OUT" "opus implement"
}

impl_feed ''
impl_feed 'not json'
impl_feed '{'
impl_feed 'null'
impl_feed '[]'
impl_feed '"a string"'
impl_feed '42'
impl_feed '{}'
impl_feed '["running"]'
impl_feed '{"last_sentinel":"IMPLEMENTATION_COMPLETE"}'
# A status that is not a string is corruption, whatever it would coerce to.
impl_feed '{"status":42,"last_sentinel":null}'
impl_feed '{"status":true,"last_sentinel":null}'
impl_feed '{"status":["running"],"last_sentinel":null}'
impl_feed '{"status":{"is":"running"},"last_sentinel":null}'
impl_feed '{"status":null,"last_sentinel":null}'
# …and so is a sentinel that is neither a string nor null.
impl_feed '{"status":"terminal","last_sentinel":7}'
impl_feed '{"status":"terminal","last_sentinel":["IMPLEMENTATION_COMPLETE"]}'
impl_feed '{"status":"terminal","last_sentinel":{"v":"IMPLEMENTATION_COMPLETE"}}'
impl_feed '{"status":"terminal","last_sentinel":false}'
# An unknown status renders nothing rather than a guess.
impl_feed '{"status":"weird-new-status","last_sentinel":null}'

# The same payload with an honest status DOES render, so the cases above are
# proving a sanitizer and not an unreachable branch.
printf '{"status":"running","last_sentinel":null}' >"$IMPL_DIR/demo.json"
printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "honest attempt state"
assert_file_contains "$OUT" "⚒ opus implement"

# An unreadable file is not a crash (skipped when the suite runs as root, where
# the mode is unenforceable and the case would be a no-op).
chmod 000 "$IMPL_DIR/demo.json"
if [ -r "$IMPL_DIR/demo.json" ]; then
  note "running as root: the unreadable-file case cannot be exercised"
else
  printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0 "unreadable attempt state"
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "stderr for an unreadable attempt state"
  assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "line count for an unreadable attempt state"
  assert_not_contains "$OUT" "opus implement"
fi
chmod 644 "$IMPL_DIR/demo.json"

# An attempt state that is a directory (the same botched install) is inert too.
rm -f "$IMPL_DIR/demo.json"
mkdir -p "$IMPL_DIR/demo.json"
printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
RC=$?
assert_rc 0 "attempt state is a directory"
assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "line count with a directory in its place"
assert_not_contains "$OUT" "opus implement"
rmdir "$IMPL_DIR/demo.json"

# Nothing is ever written to stderr: it would surface in the UI as noise.
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr"
