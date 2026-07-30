#!/usr/bin/env bash
# Deliberately hangs forever. NOT part of the normal inventory — it lives in
# tests/fixtures/hang/ so the ordinary run never discovers it (the suite would
# never be green). runner-watchdog-hang points a NESTED runner at this directory
# with a short TEST_TIMEOUT and asserts the watchdog reports it and reaps it.
# shellcheck source=../../lib.sh
. "$TESTS_DIR/lib.sh"

# A descendant whose survival is observable from outside: if the group kill
# misses it, this marker appears a few seconds after the watchdog fired.
( sleep 6; : >"$SANDBOX/descendant-survived" ) &

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"

export CODEX_STUB_SCENARIO=hang
export CODEX_STUB_HANG_SECONDS=120

# Blocks in the codex | tee | stream_milestones pipeline until something kills
# the whole process group.
bash "$SCRIPTS/codex-start.sh" review hang-forever "$SANDBOX/p.tpl"

fail "the hung turn returned on its own — the fixture is broken"
