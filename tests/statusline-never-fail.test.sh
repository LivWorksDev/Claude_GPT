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

# A heartbeat that is a directory (a botched install) is not a crash either.
rm -f "$HB_DIR/current.json"
mkdir -p "$HB_DIR/current.json"
printf '%s' "$PAYLOAD" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "heartbeat is a directory"
rmdir "$HB_DIR/current.json"

# Nothing is ever written to stderr: it would surface in the UI as noise.
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr"
