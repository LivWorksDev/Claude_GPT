#!/usr/bin/env bash
# jq is a hard dependency for the codex wrappers and a soft one for the status
# line. Each script degrades its own way and none of them corrupts state.
#
# PATH here is $SANDBOX/bin plus a minimal symlink farm and NOTHING else: modern
# macOS and both CI runners ship /usr/bin/jq, so merely dropping $SANDBOX/tools
# would leave jq perfectly reachable and the whole case would be a no-op.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

MINBIN="$(make_minbin)"
NOJQ="$SANDBOX/bin:$MINBIN"
FULL_PATH="$PATH"

if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then
  fail "jq is still reachable on the jq-free PATH"
fi
PATH="$NOJQ" command -v codex >/dev/null 2>&1 || fail "the stub is not on the jq-free PATH"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

# --- codex-start.sh: exit 3, before any state is written ---------------------
run env PATH="$NOJQ" bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 3 "codex-start without jq"
assert_file_contains "$ERR" "jq not found. Install: brew install jq"
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/review"

run env PATH="$NOJQ" bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 3 "codex-resume without jq"
run env PATH="$NOJQ" bash "$SCRIPTS/codex-swarm.sh" worker r s "$SANDBOX/p.tpl"
assert_rc 3 "codex-swarm without jq"

# --- statusline.sh: rc 0 with an honest one-line message ---------------------
statusline_payload | env PATH="$NOJQ" bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
RC=$?
assert_rc 0 "statusline without jq"
assert_file_contains "$OUT" "tandem: jq not found"
assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "one line only"
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "nothing on stderr"

# Even with a perfectly good heartbeat waiting to be rendered.
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
write_hb "$HB" "status=running" "pid=$$"
statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
  | env PATH="$NOJQ" bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "statusline without jq, heartbeat present"
assert_file_contains "$OUT" "tandem: jq not found"
assert_not_contains "$OUT" "codex"

# --- codex-reset.sh: state goes, the heartbeat SURVIVES ----------------------
# Without jq the ownership test cannot be evaluated, and an unattributable
# heartbeat must be kept rather than deleted on a guess.
SD="$(state_dir review)"
mkdir -p "$SD"
KEY="$(tkey demo)"
printf 'thr\n' >"$SD/$KEY.thread"
printf '2\n' >"$SD/$KEY.turn"
printf 'reply\n' >"$SD/$KEY.last.txt"
write_hb "$HB" "role=review" "target=demo" "status=done"

run env PATH="$NOJQ" bash "$SCRIPTS/codex-reset.sh" review demo
assert_rc 0 "codex-reset without jq"
assert_file_contains "$OUT" 'state reset for "demo"'
assert_no_file "$SD/$KEY.thread"
assert_no_file "$SD/$KEY.turn"
assert_no_file "$SD/$KEY.last.txt"
assert_file "$HB"
assert_json "$HB" '.role == "review" and .target == "demo"'

# With jq back, the same reset does drop it.
printf 'thr\n' >"$SD/$KEY.thread"
export PATH="$FULL_PATH"
run bash "$SCRIPTS/codex-reset.sh" review demo
assert_rc 0 "codex-reset with jq"
assert_no_file "$HB"

# --- codex-show.sh needs no jq at all ----------------------------------------
printf 'thr_show\n' >"$SD/$KEY.thread"
printf '2\n' >"$SD/$KEY.turn"
run env PATH="$NOJQ" bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 0 "codex-show without jq"
assert_file_contains "$OUT" "thread_id: thr_show"
assert_file_contains "$OUT" "turns:     2"
