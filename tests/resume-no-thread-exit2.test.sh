#!/usr/bin/env bash
# Resuming what was never started is exit 2 (the mirror of start's exit 2), and
# codex is never called.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 2 "no thread yet"
assert_file_contains "$ERR" 'no thread exists for "demo" yet — use codex-start.sh first.'
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

# A thread under a DIFFERENT role does not satisfy this one.
seed_thread implement demo thr_other 1
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 2 "thread belongs to another role"
assert_no_file "$CODEX_STUB_LOG.argv.1"

# Nor does a thread for a different target.
seed_thread review other-target thr_other2 1
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 2 "thread belongs to another target"
assert_no_file "$CODEX_STUB_LOG.argv.1"
