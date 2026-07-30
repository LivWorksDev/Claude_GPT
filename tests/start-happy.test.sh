#!/usr/bin/env bash
# codex-start.sh: the whole happy path — state files, rendered prompt with real
# extra/notes files, live milestones, heartbeat, printed reply.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" \
  "Review {{TARGET}} please." \
  "--- extra ---" "{{EXTRA}}" \
  "--- notes ---" "{{NOTES}}"
printf 'diff --git a/x b/x\n+added line\n' >"$SANDBOX/extra.txt"
printf 'reviewer notes: be brief\n' >"$SANDBOX/notes.txt"

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_happy_001

run bash "$SCRIPTS/codex-start.sh" review demo \
  "$SANDBOX/p.tpl" "$SANDBOX/extra.txt" "$SANDBOX/notes.txt"
assert_rc 0

KEY="$(tkey demo)"
SD="$(state_dir review)"

assert_eq "thr_happy_001" "$(cat "$SD/$KEY.thread")" "persisted thread id"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "turn counter"
assert_file "$SD/$KEY.t1.prompt.txt"
assert_file "$SD/$KEY.t1.events.ndjson"
assert_file "$SD/$KEY.t1.events.ndjson.stderr"
assert_file_contains "$SD/$KEY.t1.reply.txt" "stub reply for ok"
assert_file_contains "$SD/$KEY.last.txt" "stub reply for ok"

# The prompt codex actually received (not just the file on disk).
assert_file_contains "$(stub_stdin 1)" "Review demo please."
assert_file_contains "$(stub_stdin 1)" "+added line"
assert_file_contains "$(stub_stdin 1)" "reviewer notes: be brief"

# Live milestones narrated on stdout while the turn ran.
assert_file_contains "$OUT" "» thread thr_happy_001"
assert_file_contains "$OUT" "» exec echo hello world"
assert_file_contains "$OUT" "  ✓ ok"
assert_file_contains "$OUT" "» turn done — tokens in 1234 · out 56"

# The reply and the thread id are printed for the caller.
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, turn 1) ---"
assert_file_contains "$OUT" "THREAD_ID: thr_happy_001"
assert_file_contains "$ERR" "role=review model=gpt-5.6-sol effort=xhigh sandbox=read-only target=demo"

# Final heartbeat.
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
assert_json "$HB" '.status == "done"'
assert_json "$HB" '.role == "review" and .model == "gpt-5.6-sol" and .effort == "xhigh"'
assert_json "$HB" '.sandbox == "read-only" and .target == "demo" and .turn == 1'
assert_json "$HB" '.events == "'"$SD/$KEY.t1.events.ndjson"'"'
assert_json "$HB" '.verdict == null'

# state_init keeps the whole tree out of git.
assert_eq "*" "$(cat "$CLAUDE_PROJECT_DIR/.tandem/.gitignore")" ".tandem/.gitignore"
