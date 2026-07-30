#!/usr/bin/env bash
# Usage errors are 64 and never degrade to 1: a caller distinguishes "I invoked
# this wrong" from "codex failed" by the exit code alone.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

usage() {
  run bash "$SCRIPTS/codex-start.sh" "$@"
  assert_rc 64 "usage: [$*]"
}

# Too few positional arguments — checked before any dependency probe.
usage
usage review
usage review demo

assert_file_contains "$ERR" "usage: codex-start.sh <role> <target> <template.tpl>"

# Unknown role.
usage auditor demo "$SANDBOX/p.tpl"
assert_file_contains "$ERR" "unknown role 'auditor' (expected: review, implement, ask or image)"

# Missing template.
usage review demo "$SANDBOX/missing.tpl"
assert_file_contains "$ERR" "prompt template not found:"

# Missing optional context files.
usage review demo "$SANDBOX/p.tpl" "$SANDBOX/nope-extra.txt"
assert_file_contains "$ERR" "context file not found:"
usage review demo "$SANDBOX/p.tpl" "$SANDBOX/p.tpl" "$SANDBOX/nope-notes.txt"
assert_file_contains "$ERR" "context file not found:"

# Unusable target label.
usage review "..." "$SANDBOX/p.tpl"
assert_file_contains "$ERR" "empty state key"

# codex was never invoked for any of the above.
assert_no_file "$CODEX_STUB_LOG.argv.1"

# The same wrong invocations against codex-resume.sh and codex-show.sh.
run bash "$SCRIPTS/codex-resume.sh" review demo
assert_rc 64 "resume usage"
assert_file_contains "$ERR" "usage: codex-resume.sh"
run bash "$SCRIPTS/codex-show.sh" review
assert_rc 64 "show usage"
assert_file_contains "$ERR" "usage: codex-show.sh"
run bash "$SCRIPTS/codex-reset.sh" review
assert_rc 64 "reset usage"
assert_file_contains "$ERR" "usage: codex-reset.sh"
