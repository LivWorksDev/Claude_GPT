#!/usr/bin/env bash
# hb_write: a real JSON null for absent verdict/events (never ""), numbers for
# the numeric fields, atomic replacement, and never an aborted turn.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

ROOT="$SANDBOX/hbroot"
HB="$ROOT/state/current.json"

hbw() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  ROLE="${HB_ROLE_IN:-review}"
  CODEX_MODEL=gpt-5.6-sol CODEX_EFFORT=xhigh CODEX_SANDBOX=read-only
  TARGET="demo target"
  TURN="${TURN_IN:-3}"
  HB_STARTED_AT=1700000000
  EVENTS_FILE="${EVENTS_IN:-}"
  HB_TOKENS_IN="${TOK_IN:-}"
  HB_TOKENS_OUT="${TOK_OUT:-}"
  HB_ROOT="$ROOT"
  hb_write "$1" "${2:-}"
)

# --- absent verdict and events are JSON null, not empty strings --------------
hbw running
assert_json "$HB" '.verdict == null'
assert_json "$HB" '.events == null'
assert_json "$HB" '.verdict | type == "null"'
assert_json "$HB" '(.turn | type) == "number" and .turn == 3'
assert_json "$HB" '(.pid | type) == "number" and .pid > 0'
assert_json "$HB" '(.started_at | type) == "number" and .started_at == 1700000000'
assert_json "$HB" '(.updated_at | type) == "number" and .updated_at > 1700000000'
assert_json "$HB" '.status == "running" and .role == "review"'
assert_json "$HB" '.model == "gpt-5.6-sol" and .effort == "xhigh"'
assert_json "$HB" '.sandbox == "read-only" and .target == "demo target"'
# Absent token counts are JSON nulls too — never 0, which would claim a turn
# was free, and never "" where the status line expects a number.
assert_json "$HB" '.tokens_in == null and .tokens_out == null'
assert_json "$HB" '(.tokens_in | type) == "null"'
# Exactly the fourteen documented keys, no more.
assert_json "$HB" '[keys_unsorted[]] | length == 14'

# --- present values are strings ---------------------------------------------
EVENTS_IN="$SANDBOX/e.ndjson" hbw "done" APPROVED
assert_json "$HB" '.verdict == "APPROVED"'
assert_json "$HB" '.events == "'"$SANDBOX/e.ndjson"'"'
assert_json "$HB" '.status == "done"'

# --- token counts: numbers when closed, ALWAYS null while running ------------
TOK_IN=1234 TOK_OUT=56 hbw "done" APPROVED
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'
assert_json "$HB" '(.tokens_in | type) == "number" and (.tokens_out | type) == "number"'

TOK_IN=1234 TOK_OUT=56 hbw running
assert_json "$HB" '.tokens_in == null and .tokens_out == null'

# Anything that is not a number degrades to null instead of poisoning the field.
TOK_IN="lots" TOK_OUT="" hbw "done"
assert_json "$HB" '.tokens_in == null and .tokens_out == null'

# --- the file is replaced atomically: no half-written object, no temp litter --
assert_eq "1" "$(find "$ROOT/state" -maxdepth 1 -type f | wc -l | tr -d ' ')" \
  "files under state/"
if ls "$ROOT/state"/.current.* >/dev/null 2>&1; then
  fail "hb_write left a temp file behind"
fi

# --- the tree is gitignored even when hb_write created it alone --------------
assert_eq "*" "$(cat "$ROOT/.gitignore")" "heartbeat root .gitignore"

# --- best effort: no root, unwritable root -> return 0, never abort a turn ----
rc=0
(
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  unset HB_ROOT STATE_ROOT
  hb_write running
) || rc=$?
assert_eq "0" "$rc" "hb_write with no root"

mkdir -p "$SANDBOX/ro"
chmod 500 "$SANDBOX/ro"
rc=0
( . "$SCRIPTS/_common.sh"
  ROLE=review; HB_ROOT="$SANDBOX/ro/nested"; hb_write running ) || rc=$?
chmod 700 "$SANDBOX/ro"
assert_eq "0" "$rc" "hb_write with an unwritable root"

# --- hb_end disarms the guard, hb_guard preserves the exit code --------------
rc=0
( . "$SCRIPTS/_common.sh"
  ROLE=review; HB_ROOT="$ROOT"; TURN=1
  hb_begin
  hb_end "done" "APPROVED" ) || rc=$?
assert_eq "0" "$rc" "clean turn"
assert_json "$HB" '.status == "done" and .verdict == "APPROVED"'

rc=0
( . "$SCRIPTS/_common.sh"
  ROLE=review; HB_ROOT="$ROOT"; TURN=1
  hb_begin
  die "boom" 42 ) >/dev/null 2>&1 || rc=$?
assert_eq "42" "$rc" "die preserves its exit code through the EXIT guard"
assert_json "$HB" '.status == "failed"'
