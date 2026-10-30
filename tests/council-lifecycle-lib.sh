#!/usr/bin/env bash
# Shared setup of the two lifecycle cases of council.sh — council-lifecycle
# (the lock, an overlapping close, TERM forwarding, kill -9 recovered by the
# receipt) and council-recovery (a direct retry, the argv signatures, unknown
# liveness, unblock, a kill -9 inside the critical section). Sourced, never run
# as a case: the runner only picks *.test.sh. A5b of the plan was ONE file
# until the full suite pushed it past the runner's 60 s per-case watchdog on a
# loaded host (each scenario spends real seconds in the wrapper's watchdog
# polls), so it is two cases with this common preamble.
# shellcheck disable=SC2034  # these variables and helpers are used by the sourcing cases
make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
FX="$REPO_ROOT/tests/fixtures/council"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
export CODEX_STUB_SCENARIO=ok
SD="$CLAUDE_PROJECT_DIR/.tandem/state/council"
REAL_PS="$(command -v ps)"
[ -n "$REAL_PS" ] || fail "the suite needs ps"

council() { run bash "$COUNCIL" "$@"; }
stub_n() { if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi; }

setup_run() {
  RID="$1"
  DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
  RD="$SD/runs/$RID"
  RJ="$RD/run.json"
  TARGET="council-$RID-g1"
  council init "$RID"
  assert_rc 0 "init $RID"
  jq '.letters = {A: "lider", B: "astra", C: "fable"}' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
  printf '# Brief\n\nObjetivo: x\n' >"$DOC/brief.md"
  council profile "$RID" critico
  assert_rc 0 "profile $RID"
  council seal "$RID" brief
  assert_rc 0 "seal brief $RID"
  # The leader's seal precedes every seat prompt of propose (ready_to_publish
  # may re-seal it: no prompt is staged yet at that point).
  printf 'Propuesta del líder\nENTREGA: PROPUESTA\n' >"$RD/sealed/propose.md"
  council seal "$RID" propose
  assert_rc 0 "seal propose $RID"
  KEY="$(tkey "$TARGET")"
}

# ready_to_publish — the leader's seal and Fable's capture for propose, so that
# only Astra's turn decides whether publish can go.
ready_to_publish() {
  printf 'Propuesta del líder\nENTREGA: PROPUESTA\n' >"$RD/sealed/propose.md"
  council seal "$RID" propose
  assert_rc 0 "seal propose"
  council stage "$RID" propose B
  council stage "$RID" propose C
  cp "$FX/subagent-transcript.jsonl" "$SANDBOX/$RID.agent.jsonl"
  council record-agent "$RID" "agent-$RID" "$SANDBOX/$RID.agent.jsonl"
  council capture "$RID" propose
  assert_rc 0 "capture Fable"
}

wait_until() {
  # wait_until <label> <shell-condition> — order, never wall-clock duration.
  local i=0
  while [ "$i" -lt 200 ]; do
    if eval "$2"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "timed out waiting for: $1"
}

wait_registered() {
  # wait_registered <index> — the reservation at <index> carries its wrapper
  # AND the lock is free again (an older entry's wrapper must never match).
  local i="$1"
  wait_until "the wrapper of entry $i registered" \
    "[ -f \"\$RJ\" ] && jq -e --argjson i $i '(.astra_turns | length) > \$i and .astra_turns[\$i].wrapper != null' \"\$RJ\" >/dev/null 2>&1 && [ ! -d \"\$RD/.lock\" ]"
  WPID="$(jq -r --argjson i "$i" '.astra_turns[$i].wrapper.pid' "$RJ")"
}

wait_gone() { wait_until "pid $1 gone" "! kill -0 $1 2>/dev/null"; }

dead_pid() {
  sleep 0 &
  DEAD=$!
  wait "$DEAD" 2>/dev/null || true
}

inject_entry() {
  # inject_entry <estado> <turn_before> <token> [wrapper|nowrapper]
  local wrap='{pid: $d, lstart: "x"}'
  [ "${4:-wrapper}" = "nowrapper" ] && wrap='null'
  jq --arg e "$1" --argjson tb "$2" --arg tok "$3" --argjson d "$DEAD" --arg t "$TARGET" \
    ".astra_turns += [{fase: \"propose\", intento: 1, tipo: \"sustantivo\", target: \$t, estado: \$e,
       turn_before: \$tb, turno: null, launch_token: \$tok, driver: {pid: \$d, lstart: \"x\"},
       wrapper: $wrap}]" "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
}
