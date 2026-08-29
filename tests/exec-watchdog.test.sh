#!/usr/bin/env bash
# The exec transport owns a bounded, counter-based watchdog in start, resume
# and swarm: timeout classification, accounting, lifecycle cleanup and
# fail-closed configuration are one contract.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
printf 'fully rendered seat prompt\n' >"$SANDBOX/seat.txt"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
REVIEW_SD="$(state_dir review)"

assert_pid_gone() {
  local f="$1" label="$2" pid i=0
  assert_file "$f"
  pid="$(cat "$f")"
  while [ "$i" -lt 30 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "$label survived the wrapper cleanup (pid=$pid)"
}

slots_left() {
  find "$1/.slots" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# --- pure hang: all three wrappers classify it, and no usage is invented ----
export CODEX_STUB_SCENARIO=hang
export CODEX_STUB_HANG_SECONDS=600
export TANDEM_EXEC_TIMEOUT_SECONDS=1

run bash "$SCRIPTS/codex-start.sh" review wd-start "$SANDBOX/p.tpl"
assert_rc 1 "start exec watchdog"
START_KEY="$(tkey wd-start)"
assert_file_contains "$ERR" "no answer within 1s for exec profile review"
assert_file_contains "$ERR" "TANDEM_EXEC_TIMEOUT_SECONDS"
assert_not_contains "$ERR" "USAGE:"
assert_no_file "$REVIEW_SD/$START_KEY.t1.usage.json"
assert_json "$HB" '.status == "failed" and .role == "review" and .target == "wd-start"'

seed_thread review wd-resume thr_exec_watchdog 3
RESUME_KEY="$(tkey wd-resume)"
run bash "$SCRIPTS/codex-resume.sh" review wd-resume "$SANDBOX/p.tpl"
assert_rc 1 "resume exec watchdog"
assert_file_contains "$ERR" "no answer within 1s for exec profile review"
assert_file_contains "$ERR" "TANDEM_EXEC_TIMEOUT_SECONDS"
assert_not_contains "$ERR" "USAGE:"
assert_no_file "$REVIEW_SD/$RESUME_KEY.t4.usage.json"
assert_json "$HB" '.status == "failed" and .role == "review" and .target == "wd-resume"'

run bash "$SCRIPTS/codex-swarm.sh" worker wd-run hung-seat "$SANDBOX/seat.txt"
assert_rc 1 "swarm exec watchdog"
RUN_KEY="$(tkey wd-run)"
SEAT_KEY="$(tkey hung-seat)"
ULTRA_SD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUN_KEY"
assert_file_contains "$ERR" "no answer within 1s for exec profile ultra (tier=worker)"
assert_file_contains "$ERR" "TANDEM_EXEC_TIMEOUT_SECONDS"
assert_not_contains "$ERR" "USAGE:"
assert_eq "0" "$(slots_left "$ULTRA_SD")" "slots after a swarm timeout"
assert_file "$ULTRA_SD/$SEAT_KEY.prompt.txt"
cmp -s "$SANDBOX/seat.txt" "$ULTRA_SD/$SEAT_KEY.prompt.txt" \
  || fail "the timed-out attempt did not preserve its staged prompt"
assert_no_file "$ULTRA_SD/$SEAT_KEY.reply.txt"

# The released slot is usable immediately by a later seat of the same run.
export CODEX_STUB_SCENARIO=ok
run bash "$SCRIPTS/codex-swarm.sh" worker wd-run next-seat "$SANDBOX/seat.txt"
assert_rc 0 "the seat after a timeout acquires slot.1"
assert_eq "0" "$(slots_left "$ULTRA_SD")" "slots after the later seat"

# --- TERM-resistant descendant: KILL reaches the whole verified group -------
export CODEX_STUB_SCENARIO=hang
export CODEX_STUB_HANG_RESISTANT=1
export CODEX_STUB_HANG_PIDFILE="$SANDBOX/resistant.pid"
run bash "$SCRIPTS/codex-start.sh" review wd-resistant "$SANDBOX/p.tpl"
assert_rc 1 "TERM-resistant exec hang"
assert_pid_gone "$CODEX_STUB_HANG_PIDFILE" "TERM-resistant descendant"
unset CODEX_STUB_HANG_RESISTANT CODEX_STUB_HANG_PIDFILE

# --- turn.completed landed before the hang: quota remains accounted ---------
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_HANG_AFTER_EVENTS=1
run bash "$SCRIPTS/codex-start.sh" review wd-after-events "$SANDBOX/p.tpl"
assert_rc 1 "post-quota exec hang"
AFTER_KEY="$(tkey wd-after-events)"
assert_file_contains "$ERR" 'USAGE: {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$ERR" "no answer within 1s for exec profile review"
assert_json "$REVIEW_SD/$AFTER_KEY.t1.usage.json" \
  '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$HB" '.status == "failed" and .tokens_in == 1234 and .tokens_out == 56'
unset CODEX_STUB_HANG_AFTER_EVENTS

# --- fail-closed override: usage error beats dependencies and state ----------
seed_thread review wd-invalid thr_exec_watchdog 7
INVALID_TURN="$REVIEW_SD/$(tkey wd-invalid).turn"
INVALID_ULTRA="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey wd-invalid-run)"
MINBIN="$(make_minbin)"

invalid_timeout() {
  local script="$1" value="$2" label="$3"
  rm -f "$CODEX_STUB_LOG".*
  case "$script" in
    codex-start.sh)
      run env PATH="$MINBIN" TANDEM_EXEC_TIMEOUT_SECONDS="$value" \
        bash "$SCRIPTS/$script" review wd-invalid "$SANDBOX/p.tpl"
      ;;
    codex-resume.sh)
      run env PATH="$MINBIN" TANDEM_EXEC_TIMEOUT_SECONDS="$value" \
        bash "$SCRIPTS/$script" review wd-invalid "$SANDBOX/p.tpl"
      ;;
    codex-swarm.sh)
      run env PATH="$MINBIN" TANDEM_EXEC_TIMEOUT_SECONDS="$value" \
        bash "$SCRIPTS/$script" worker wd-invalid-run invalid-seat "$SANDBOX/seat.txt"
      ;;
  esac
  assert_rc 64 "$label"
  assert_file_contains "$ERR" "TANDEM_EXEC_TIMEOUT_SECONDS must be a positive integer"
  assert_not_contains "$ERR" "codex CLI not found"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.argv.1"
  assert_eq "7" "$(cat "$INVALID_TURN")" "turn counter after $label"
  assert_no_file "$INVALID_ULTRA"
}

for SCRIPT in codex-start.sh codex-resume.sh codex-swarm.sh; do
  invalid_timeout "$SCRIPT" "" "$SCRIPT empty timeout"
  invalid_timeout "$SCRIPT" abc "$SCRIPT non-numeric timeout"
  invalid_timeout "$SCRIPT" 0 "$SCRIPT zero timeout"
done

# --- TERM only to each wrapper: the inner group is gone before publication --
export CODEX_STUB_SCENARIO=hang
export CODEX_STUB_HANG_SECONDS=600
export CODEX_STUB_HANG_RESISTANT=1
export TANDEM_EXEC_TIMEOUT_SECONDS=30

interrupt_start_or_resume() {
  local kind="$1" target="$2" pidfile wrapper rc=0 i=0
  pidfile="$SANDBOX/$target.pid"
  export CODEX_STUB_HANG_PIDFILE="$pidfile"
  rm -f "$pidfile" "$HB"
  if [ "$kind" = "resume" ]; then
    seed_thread review "$target" thr_exec_interrupt 1
    wrapper=codex-resume.sh
  else
    wrapper=codex-start.sh
  fi
  bash "$SCRIPTS/$wrapper" review "$target" "$SANDBOX/p.tpl" \
    >"$SANDBOX/$target.out" 2>"$SANDBOX/$target.err" &
  WRAPPER_PID=$!
  while [ "$i" -lt 150 ]; do
    if [ -f "$pidfile" ] && [ -f "$HB" ] \
      && jq -e '.status == "running"' "$HB" >/dev/null 2>&1; then break; fi
    kill -0 "$WRAPPER_PID" 2>/dev/null || fail "$wrapper exited before the TERM barrier"
    sleep 0.1
    i=$((i + 1))
  done
  assert_file "$pidfile"
  kill -TERM "$WRAPPER_PID"
  wait "$WRAPPER_PID" || rc=$?
  assert_eq "143" "$rc" "$wrapper TERM exit"
  assert_pid_gone "$pidfile" "$wrapper inner descendant"
  assert_json "$HB" '.status == "failed" and .target == '"\"$target\""
}

interrupt_start_or_resume start wd-term-start
interrupt_start_or_resume resume wd-term-resume

# Swarm retains its record-and-honor boundary: the pending TERM wins over the
# timeout verdict after the bounded watchdog reaps the hung group and before
# the EXIT owner releases the slot.
export TANDEM_EXEC_TIMEOUT_SECONDS=1
export CODEX_STUB_HANG_PIDFILE="$SANDBOX/wd-term-swarm.pid"
TERM_RUN_KEY="$(tkey wd-term-run)"
TERM_ULTRA="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$TERM_RUN_KEY"
bash "$SCRIPTS/codex-swarm.sh" worker wd-term-run wd-term-seat "$SANDBOX/seat.txt" \
  >"$SANDBOX/wd-term-swarm.out" 2>"$SANDBOX/wd-term-swarm.err" &
SWARM_PID=$!
i=0
while [ "$i" -lt 150 ]; do
  if [ -f "$CODEX_STUB_HANG_PIDFILE" ] \
    && [ -f "$TERM_ULTRA/.slots/slot.1/holder" ]; then break; fi
  kill -0 "$SWARM_PID" 2>/dev/null || fail "swarm exited before the TERM barrier"
  sleep 0.1
  i=$((i + 1))
done
assert_file "$CODEX_STUB_HANG_PIDFILE"
kill -TERM "$SWARM_PID"
SWARM_RC=0
wait "$SWARM_PID" || SWARM_RC=$?
assert_eq "143" "$SWARM_RC" "swarm TERM exit"
assert_pid_gone "$CODEX_STUB_HANG_PIDFILE" "swarm inner descendant"
assert_eq "0" "$(slots_left "$TERM_ULTRA")" "slots after swarm TERM"
unset CODEX_STUB_HANG_RESISTANT CODEX_STUB_HANG_PIDFILE

# --- a broken date cannot affect the counter-based exec deadline ------------
BROKENBIN="$SANDBOX/broken-date-bin"
mkdir -p "$BROKENBIN"
for utility in "$MINBIN"/*; do
  ln -sf "$utility" "$BROKENBIN/$(basename "$utility")"
done
ln -sf "$(command -v jq)" "$BROKENBIN/jq"
ln -sf "$SANDBOX/bin/codex" "$BROKENBIN/codex"
rm -f "$BROKENBIN/date"
printf '#!/usr/bin/env bash\nprintf '\''not-a-number\\n'\''\n' >"$BROKENBIN/date"
chmod +x "$BROKENBIN/date"

run env PATH="$BROKENBIN" CODEX_STUB_SCENARIO=hang CODEX_STUB_HANG_SECONDS=600 \
  TANDEM_EXEC_TIMEOUT_SECONDS=1 \
  bash "$SCRIPTS/codex-start.sh" review wd-broken-date "$SANDBOX/p.tpl"
assert_rc 1 "exec timeout with broken date"
assert_file_contains "$ERR" "no answer within 1s for exec profile review"
assert_file_contains "$ERR" "TANDEM_EXEC_TIMEOUT_SECONDS"

# The foreground literal must remain below the Bash tool's 600-second cap.
WD="$(LC_ALL=C sed -n 's|^TANDEM_EXEC_TIMEOUT_DEFAULT=\([0-9][0-9]*\)$|\1|p' \
  "$SCRIPTS/_common.sh" | head -n 1)"
[ -n "$WD" ] || fail "_common.sh declares no TANDEM_EXEC_TIMEOUT_DEFAULT"
assert_eq "540" "$WD" "the exec foreground watchdog default"
[ "$WD" -lt 600 ] \
  || fail "the exec foreground watchdog (${WD}s) must stay below the 600s Bash cap"

note "exec watchdog: timeout, quota, group cleanup, signals, validation and broken clock covered"
