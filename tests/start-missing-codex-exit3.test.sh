#!/usr/bin/env bash
# Missing dependencies are exit 3 and are diagnosed before any state is touched.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"

# --- codex absent from PATH entirely ----------------------------------------
# A minimal symlink farm, not "PATH minus one entry": /usr/bin exists on both
# runners and could plausibly hold a real codex one day.
MINBIN="$(make_minbin)"
ln -sf "$(command -v jq)" "$MINBIN/jq"
FULL_PATH="$PATH"
export PATH="$MINBIN"

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 3 "codex not in PATH"
assert_file_contains "$ERR" "codex CLI not found in PATH"
assert_file_contains "$ERR" "npm install -g @openai/codex@latest"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/review"

export PATH="$FULL_PATH"

# --- codex present but unable to run (missing native binary) ----------------
export CODEX_STUB_SCENARIO=version-fail
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 3 "codex present but broken"
assert_file_contains "$ERR" "codex CLI is present but cannot run"
assert_no_file "$CODEX_STUB_LOG.argv.1"

# --- jq absent ---------------------------------------------------------------
# need_codex runs first, so the stub has to stay reachable to reach need_jq.
rm -f "$MINBIN/jq"
ln -sf "$SANDBOX/bin/codex" "$MINBIN/codex"
export PATH="$MINBIN"
export CODEX_STUB_SCENARIO=ok
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 3 "jq not found"
assert_file_contains "$ERR" "jq not found"
export PATH="$FULL_PATH"
