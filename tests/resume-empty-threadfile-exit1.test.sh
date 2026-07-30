#!/usr/bin/env bash
# A thread file that exists but holds no id is corruption, not "no thread yet":
# exit 1 with a reset instruction, never exit 2 and never a resume with "".
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

KEY="$(seed_key review demo)"
SD="$(state_dir review)"

: >"$SD/$KEY.thread"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "zero-byte thread file"
assert_file_contains "$ERR" "thread file is empty"
assert_file_contains "$ERR" "reset and start over"
assert_no_file "$CODEX_STUB_LOG.argv.1"

# Whitespace only is also empty once tr has stripped it.
printf ' \n\t\n' >"$SD/$KEY.thread"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 1 "whitespace-only thread file"
assert_file_contains "$ERR" "thread file is empty"
assert_no_file "$CODEX_STUB_LOG.argv.1"

# It fails before hb_begin: no heartbeat is left behind for the status line.
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
