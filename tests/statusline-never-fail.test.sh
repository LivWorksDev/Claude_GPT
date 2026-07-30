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

# Nothing is ever written to stderr: it would surface in the UI as noise.
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr"
