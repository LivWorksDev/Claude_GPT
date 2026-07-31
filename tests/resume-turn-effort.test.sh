#!/usr/bin/env bash
# TANDEM_TURN_EFFORT — the per-invocation effort override for reminder turns
# ("nudges"), read ONLY by codex-resume.sh.
#
# Three things are asserted together because each one alone can be green while
# the feature is broken: the argv the CLI really receives, the heartbeat (what
# the status line shows WHILE the turn runs) and the per-turn meta.json — the
# durable record, the only one that survives the next turn overwriting the
# global heartbeat. Invalid values are usage errors (64) BEFORE dependencies,
# and start/swarm ignore the variable on purpose.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "nudge for {{TARGET}}"
printf 'fully rendered seat prompt\n' >"$SANDBOX/seat.txt"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_effort_1

seed_thread review demo thr_effort_1 0
KEY="$(tkey demo)"
SD="$(state_dir review)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

# --- 1. low: argv, heartbeat AND the durable meta.json all carry it ----------
export TANDEM_TURN_EFFORT=low
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume with TANDEM_TURN_EFFORT=low"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=low${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}$SD/$KEY.t1.reply.txt${US}resume${US}thr_effort_1${US}-"
# Only the effort moved: the role's sandbox is still pinned read-only.
assert_file_contains "$ERR" "effort=low sandbox=read-only"
assert_json "$HB" '.effort == "low" and .sandbox == "read-only" and .turn == 1'
assert_file "$SD/$KEY.t1.meta.json"
assert_json "$SD/$KEY.t1.meta.json" \
  '. == {role:"review", model:"gpt-5.6-sol", effort:"low", sandbox:"read-only"}'

# --- 2. max and ultra are valid values ---------------------------------------
export TANDEM_TURN_EFFORT=max
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume with TANDEM_TURN_EFFORT=max"
assert_file_contains "$CODEX_STUB_LOG.argv.2" "model_reasoning_effort=max"
assert_json "$SD/$KEY.t2.meta.json" '.effort == "max"'

export TANDEM_TURN_EFFORT=ultra
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume with TANDEM_TURN_EFFORT=ultra"
assert_file_contains "$CODEX_STUB_LOG.argv.3" "model_reasoning_effort=ultra"
assert_json "$SD/$KEY.t3.meta.json" '.effort == "ultra"'

# --- 3. without the variable the role's effort is untouched ------------------
unset TANDEM_TURN_EFFORT
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume without TANDEM_TURN_EFFORT"
assert_file_contains "$CODEX_STUB_LOG.argv.4" "model_reasoning_effort=xhigh"
assert_json "$HB" '.effort == "xhigh" and .turn == 4'
assert_json "$SD/$KEY.t4.meta.json" '.effort == "xhigh"'

# …and THAT is why the meta.json exists: the heartbeat has already been
# overwritten three times, while the nudge's real effort is still on disk.
assert_json "$SD/$KEY.t1.meta.json" '.effort == "low"'

# --- 4. an invalid value is a usage error, and no turn is spent --------------
export TANDEM_TURN_EFFORT=turbo
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "invalid TANDEM_TURN_EFFORT"
assert_file_contains "$ERR" "TANDEM_TURN_EFFORT"
assert_file_contains "$ERR" "turbo"
assert_no_file "$CODEX_STUB_LOG.argv.5"
assert_no_file "$SD/$KEY.t5.meta.json"
assert_eq "4" "$(cat "$SD/$KEY.turn")" "turn counter after a rejected value"

# Defined-but-empty is invalid like any other value, never "unset".
export TANDEM_TURN_EFFORT=""
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "empty TANDEM_TURN_EFFORT"
assert_file_contains "$ERR" "TANDEM_TURN_EFFORT"
assert_no_file "$CODEX_STUB_LOG.argv.5"

# --- 5. usage errors beat dependency errors: 64 even with codex absent -------
# A minimal symlink farm, not "PATH minus one entry": /usr/bin exists on both
# runners and could plausibly hold a real codex one day.
MINBIN="$(make_minbin)"
ln -sf "$(command -v jq)" "$MINBIN/jq"
FULL_PATH="$PATH"
export PATH="$MINBIN"
export TANDEM_TURN_EFFORT=turbo
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 64 "invalid value with codex absent from PATH"
assert_file_contains "$ERR" "TANDEM_TURN_EFFORT"
assert_not_contains "$ERR" "codex CLI not found in PATH"
export PATH="$FULL_PATH"

# --- 6. start and swarm IGNORE the variable (the scope stays narrow) ---------
export TANDEM_TURN_EFFORT=low
run bash "$SCRIPTS/codex-start.sh" review fresh "$SANDBOX/p.tpl"
assert_rc 0 "start with TANDEM_TURN_EFFORT defined"
FKEY="$(tkey fresh)"
assert_file_contains "$CODEX_STUB_LOG.argv.5" "model_reasoning_effort=xhigh"
assert_not_contains "$CODEX_STUB_LOG.argv.5" "model_reasoning_effort=low"
# …and its meta.json records the ROLE's effort, with all four fields populated.
assert_json "$SD/$FKEY.t1.meta.json" \
  '. == {role:"review", model:"gpt-5.6-sol", effort:"xhigh", sandbox:"read-only"}'

run bash "$SCRIPTS/codex-swarm.sh" worker run-1 s-1 "$SANDBOX/seat.txt"
assert_rc 0 "swarm with TANDEM_TURN_EFFORT defined"
assert_file_contains "$CODEX_STUB_LOG.argv.6" "model_reasoning_effort=high"
assert_not_contains "$CODEX_STUB_LOG.argv.6" "model_reasoning_effort=low"

# --- 7. meta.json is JSON, not printf: a model full of quotes/backslashes ----
WEIRD='mo"del\n'
export TANDEM_REVIEW_MODEL="$WEIRD"
export TANDEM_TURN_EFFORT=low
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume with a JSON-hostile model override"
META="$SD/$KEY.t5.meta.json"
assert_json "$META" '.effort == "low" and .role == "review" and .sandbox == "read-only"'
assert_eq "$WEIRD" "$(jq -r '.model' "$META")" "meta.json model, verbatim"
unset TANDEM_REVIEW_MODEL
unset TANDEM_TURN_EFFORT
