#!/usr/bin/env bash
# codex can silently attach a resume to a DIFFERENT thread. The guard must fail
# loudly and leave a state the operator can reason about, exactly:
#   exit 1 · last.txt untouched · .turn incremented · .thread untouched
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"

seed_thread review demo thr_requested 3
KEY="$(tkey demo)"
SD="$(state_dir review)"
printf 'OLD REPLY FROM TURN 3\n' >"$SD/$KEY.last.txt"

export CODEX_STUB_SCENARIO=resume-fallback
export CODEX_STUB_THREAD_ID=thr_requested
export CODEX_STUB_THREAD_ID_2=thr_somewhere_else
export CODEX_STUB_REPLY="fresh reply that must NOT be promoted"

run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"

assert_rc 1 "silent fallback detected"
assert_file_contains "$ERR" \
  "codex resumed thread thr_somewhere_else instead of thr_requested"
assert_file_contains "$ERR" "Run codex-reset.sh and start over."

# 1. last.txt still points at the last GOOD reply.
assert_eq "OLD REPLY FROM TURN 3" "$(cat "$SD/$KEY.last.txt")" "last.txt intact"
# 2. the turn counter advanced (turn 4 really happened and burned tokens).
assert_eq "4" "$(cat "$SD/$KEY.turn")" "turn incremented"
# 3. the thread file still names the thread we asked for.
assert_eq "thr_requested" "$(cat "$SD/$KEY.thread")" "thread file intact"
# 4. the wrong turn's artefacts are still on disk for inspection.
assert_file_contains "$SD/$KEY.t4.reply.txt" "fresh reply that must NOT be promoted"
assert_file_contains "$SD/$KEY.t4.events.ndjson" "thr_somewhere_else"
# 5. the EXIT guard closed the heartbeat as failed.
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" \
  '.status == "failed" and .turn == 4'
# 6. the rejected turn is still accounted for: a fallback the guard refuses to
#    trust already burned its quota, so the ledger, the 'failed' heartbeat and
#    the footer all carry it — the exit code is what stays untouched.
assert_file "$SD/$KEY.t4.usage.json"
assert_json "$SD/$KEY.t4.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" \
  '.tokens_in == 1234 and .tokens_out == 56'
assert_file_contains "$ERR" 'USAGE: {"input_tokens":1234,"output_tokens":56}'

# codex-start.sh has no such guard to trip: it has nothing to compare against.
# Same scenario, fresh target -> the id that was reported is the id persisted.
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_brand_new
run bash "$SCRIPTS/codex-start.sh" review fresh "$SANDBOX/p.tpl"
assert_rc 0
assert_eq "thr_brand_new" "$(cat "$SD/$(tkey fresh).thread")" "start persists what it saw"
