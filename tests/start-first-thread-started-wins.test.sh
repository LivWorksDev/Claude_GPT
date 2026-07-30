#!/usr/bin/env bash
# Two thread.started events in one stream: the FIRST one is the thread we own.
# `[…][0]` is load-bearing — taking the last would persist an id that resume
# cannot attach to.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"

export CODEX_STUB_SCENARIO=multi-thread-started
export CODEX_STUB_THREAD_ID=thr_first
export CODEX_STUB_THREAD_ID_2=thr_second

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0
KEY="$(tkey demo)"
SD="$(state_dir review)"
assert_eq "thr_first" "$(cat "$SD/$KEY.thread")" "first thread.started wins"
assert_file_contains "$OUT" "THREAD_ID: thr_first"
assert_file_contains "$SD/$KEY.t1.events.ndjson" "thr_second"

# Same contract straight off the recorded fixture.
unset CODEX_STUB_THREAD_ID CODEX_STUB_THREAD_ID_2
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_FIXTURE="$TESTS_DIR/fixtures/ndjson/multi-thread.ndjson"
run bash "$SCRIPTS/codex-start.sh" review demo-fixture "$SANDBOX/p.tpl"
assert_rc 0
assert_eq "thr_fixture_first" \
  "$(cat "$SD/$(tkey demo-fixture).thread")" "first id from the fixture"
