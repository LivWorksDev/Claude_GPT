#!/usr/bin/env bash
# codex-swarm.sh: tier -> model/effort table, and read-only for EVERY tier.
# Swarm seats reason and report; writing stays in the tandem pipeline.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
printf 'fully rendered seat prompt\n' >"$SANDBOX/seat.txt"
export CODEX_STUB_SCENARIO=ok

N=0
check() {
  # check <tier> <seat> <model> <effort>
  local tier="$1" seat="$2" model="$3" effort="$4" runkey seatkey msg
  N=$((N + 1))
  run bash "$SCRIPTS/codex-swarm.sh" "$tier" run-1 "$seat" "$SANDBOX/seat.txt"
  assert_rc 0 "$tier/$seat"
  runkey="$(tkey run-1)"
  seatkey="$(tkey "$seat")"
  msg="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$runkey/$seatkey.reply.txt"
  assert_argv "$N" "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}${model}${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=${effort}${US}--output-last-message${US}${msg}${US}-"
  assert_file_contains "$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$runkey/$seatkey.prompt.txt" \
    "fully rendered seat prompt"
  assert_file_contains "$(stub_stdin "$N")" "fully rendered seat prompt"
}

check judge  s-judge  gpt-5.6-sol  xhigh
check worker s-worker gpt-5.6-sol  high
check scout  s-scout  gpt-5.6-luna high

# Overrides move model and effort per tier…
export TANDEM_ULTRA_JUDGE_MODEL=j-model
export TANDEM_ULTRA_JUDGE_EFFORT=low
export TANDEM_ULTRA_WORKER_MODEL=w-model
export TANDEM_ULTRA_WORKER_EFFORT=medium
export TANDEM_ULTRA_SCOUT_MODEL=s-model
export TANDEM_ULTRA_SCOUT_EFFORT=minimal
check judge  s-judge2  j-model low
check worker s-worker2 w-model medium
check scout  s-scout2  s-model minimal

# …and nothing at all moves the sandbox.
export CODEX_SANDBOX=workspace-write
export TANDEM_ULTRA_SANDBOX=danger-full-access
check judge s-judge3 j-model low
unset CODEX_SANDBOX TANDEM_ULTRA_SANDBOX

# `read-only` is a literal in every recorded argv, and no seat ever emitted
# -c sandbox_mode= (that is resume's business).
i=1
while [ "$i" -le "$N" ]; do
  assert_file_contains "$CODEX_STUB_LOG.argv.$i" "read-only"
  assert_not_contains "$CODEX_STUB_LOG.argv.$i" "workspace-write"
  assert_not_contains "$CODEX_STUB_LOG.argv.$i" "danger-full-access"
  assert_not_contains "$CODEX_STUB_LOG.argv.$i" "sandbox_mode="
  i=$((i + 1))
done

# Seats do not persist threads and do not fight over the heartbeat.
RUNKEY="$(tkey run-1)"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUNKEY/$(tkey s-judge).thread"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
assert_eq "*" "$(cat "$CLAUDE_PROJECT_DIR/.tandem/.gitignore")" ".tandem/.gitignore"
assert_file_contains "$ERR" "tier=judge model=j-model effort=low sandbox=read-only run=run-1 seat=s-judge3"
