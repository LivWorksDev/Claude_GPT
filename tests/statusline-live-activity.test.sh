#!/usr/bin/env bash
# While a turn is running, line 2 says what Codex is doing right now: the LAST
# meaningful item event in the NDJSON, read with a bounded tail that tolerates
# the half line it produces.
#
# The matrix below is the REAL one: codex-cli 0.144.4 discriminates an item with
# `item.type`, and reading only the stale `item.item_type` left this block silent
# on every real turn while these very cases stayed green. So the whole matrix
# (command, edit, reasoning, message, search) runs on the real name, and ONE
# explicit case keeps the compatibility read honest for older archived streams —
# migrating just the agent-message path would have left real activity invisible
# with the suite perfectly green.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
EV="$SANDBOX/events.ndjson"

show() {
  write_hb "$HB" "status=running" "pid=$$" "events=$EV"
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0
}

ev() { printf '%s\n' "$@" >"$EV"; }

# --- the primary matrix, on the REAL discriminator ---------------------------
ev '{"type":"item.started","item":{"type":"command_execution","command":"pytest    -q\n   tests/"}}'
show
assert_file_contains "$OUT" "exec pytest -q tests/"

ev '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"src/deep/nested/models.py"}]}}'
show
assert_file_contains "$OUT" "edit models.py"

ev '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a.py"},{"path":"b.py"},{"path":"c.py"}]}}'
show
assert_file_contains "$OUT" "edit 3 files"

ev '{"type":"item.completed","item":{"type":"file_change","changes":[]}}'
show
assert_file_contains "$OUT" "edit"

ev '{"type":"item.started","item":{"type":"reasoning"}}'
show
assert_file_contains "$OUT" "thinking…"

ev '{"type":"item.updated","item":{"type":"agent_message"}}'
show
assert_file_contains "$OUT" "writing reply…"

ev '{"type":"item.started","item":{"type":"web_search"}}'
show
assert_file_contains "$OUT" "searching web…"

# A REAL archived exec stream, verbatim — the case the stale discriminator got
# wrong in production while every synthetic fixture said otherwise.
cp "$TESTS_DIR/fixtures/mcp-0.144.4/exec-items.ndjson" "$EV"
assert_eq "agent_message" \
  "$(jq -rs '[.[] | select(.type == "item.started" or .type == "item.updated"
                           or .type == "item.completed") | .item.type] | last' "$EV")" \
  "the archived real exec stream's last item class"
show
assert_file_contains "$OUT" "writing reply…"

# --- the compatibility read: an older stream with the stale name -------------
ev '{"type":"item.started","item":{"item_type":"command_execution","command":"legacy-runner --once"}}'
show
assert_file_contains "$OUT" "exec legacy-runner --once"

# --- the LAST matching event wins — that is what "right now" means -----------
ev '{"type":"item.started","item":{"type":"reasoning"}}' \
   '{"type":"item.started","item":{"type":"command_execution","command":"make"}}' \
   '{"type":"item.completed","item":{"type":"agent_message"}}'
show
assert_file_contains "$OUT" "writing reply…"
assert_not_contains "$OUT" "exec make"

# Events that are not item.* are ignored, even when they come last.
ev '{"type":"item.started","item":{"type":"web_search"}}' \
   '{"type":"turn.completed","usage":{"input_tokens":1}}'
show
assert_file_contains "$OUT" "searching web…"

# Unknown item types produce no activity rather than garbage.
ev '{"type":"item.started","item":{"type":"brand_new_thing"}}'
show
assert_file_contains "$OUT" "⚙ codex"
assert_not_contains "$OUT" "brand_new_thing"

# A half line at the head (what tail -c leaves behind) is tolerated.
cp "$TESTS_DIR/fixtures/ndjson/truncated-head.ndjson" "$EV"
show
assert_file_contains "$OUT" "exec go test ./... -run TestVeryLongNameThatG"
assert_not_contains "$OUT" "tail -c cut this line"

# A long command is clipped to 40 characters.
ev '{"type":"item.started","item":{"type":"command_execution","command":"0123456789012345678901234567890123456789ZZZZ"}}'
show
assert_file_contains "$OUT" "exec 0123456789012345678901234567890123456789"
assert_not_contains "$OUT" "ZZZZ"

# The whole block is skipped when there is nothing to read.
rm -f "$EV"
show
assert_file_contains "$OUT" "⚙ codex"
assert_not_contains "$OUT" "exec"

: >"$EV"
show
assert_file_contains "$OUT" "⚙ codex"

printf 'garbage\nnot json\n' >"$EV"
show
assert_file_contains "$OUT" "⚙ codex"
assert_not_contains "$OUT" "garbage"

# Activity is a running-only concern.
cp "$TESTS_DIR/fixtures/ndjson/happy.ndjson" "$EV"
write_hb "$HB" "status=done" "pid=$$" "events=$EV" "verdict=APPROVED"
statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
RC=$?
assert_rc 0 "finished turn"
assert_not_contains "$OUT" "writing reply…"
assert_file_contains "$OUT" "APPROVED"
