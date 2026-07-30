#!/usr/bin/env bash
# codex-start.sh refuses to shadow an existing thread: exit 2, codex untouched.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

seed_thread review demo thr_existing 4
KEY="$(tkey demo)"
SD="$(state_dir review)"
printf 'PREVIOUS REPLY\n' >"$SD/$KEY.last.txt"

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 2 "thread already exists"
assert_file_contains "$ERR" 'a thread already exists for "demo" (thr_existing).'
assert_file_contains "$ERR" "use codex-resume.sh to continue it"

# Nothing was launched and nothing was clobbered.
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_eq "thr_existing" "$(cat "$SD/$KEY.thread")" "thread id preserved"
assert_eq "4" "$(cat "$SD/$KEY.turn")" "turn counter preserved"
assert_file_contains "$SD/$KEY.last.txt" "PREVIOUS REPLY"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

# A different role has its own namespace and is unaffected.
run bash "$SCRIPTS/codex-start.sh" implement demo "$SANDBOX/p.tpl"
assert_rc 0 "same target, different role"
assert_file "$(state_dir implement)/$KEY.thread"
