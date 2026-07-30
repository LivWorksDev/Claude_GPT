#!/usr/bin/env bash
# Resume tolerates a stream with no thread.started — unlike start, it already
# knows the id, so an absent event is not evidence of a wrong thread. The guard
# only fires on a DIFFERENT id.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"

seed_thread review demo thr_known 1
KEY="$(tkey demo)"
SD="$(state_dir review)"
printf 'OLD\n' >"$SD/$KEY.last.txt"

export CODEX_STUB_SCENARIO=no-thread-event
export CODEX_STUB_REPLY="second turn reply"

run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "no thread.started on resume is fine"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn incremented"
assert_eq "thr_known" "$(cat "$SD/$KEY.thread")" "thread file unchanged"
assert_file_contains "$SD/$KEY.last.txt" "second turn reply"
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" '.status == "done"'

# Garbage that jq cannot slurp is equally tolerated: the guard needs a
# CONFLICTING id, and it never got one.
export CODEX_STUB_SCENARIO=corrupt-ndjson
export CODEX_STUB_THREAD_ID=thr_known
export CODEX_STUB_REPLY="third turn reply"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "unparseable stream on resume is tolerated"
assert_eq "3" "$(cat "$SD/$KEY.turn")" "turn incremented again"
assert_file_contains "$SD/$KEY.last.txt" "third turn reply"

# But an id that IS parseable and DOES conflict still trips the guard.
export CODEX_STUB_SCENARIO=resume-fallback
export CODEX_STUB_THREAD_ID_2=thr_other
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "conflicting id still fails"
assert_file_contains "$SD/$KEY.last.txt" "third turn reply"
