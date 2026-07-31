#!/usr/bin/env bash
# codex-doctor.sh --smoke — the only part of the doctor that spends real quota.
#
# Two contracts dominate this file. First, COST: without the flag the doctor
# must never issue a single `codex exec`, and with it exactly one turn per
# UNIQUE configured model (the stub's invocation counter is the meter — its
# `exec --help` probe deliberately does not advance it). Second, CONTINUATION:
# a model that is gone, a turn that fails on auth and a turn that hangs must
# each leave the remaining models diagnosed, so the "and the next model still
# answered" assertions here are the contract, not a courtesy.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_LOGIN_RC=0

doctor()       { run env "$@" bash "$SCRIPTS/codex-doctor.sh"; }
doctor_smoke() { run env "$@" bash "$SCRIPTS/codex-doctor.sh" --smoke; }

# The stub's records are cumulative per sandbox; each case starts from zero so
# "2 turns" means this run's two turns.
reset_stub() { rm -f "$CODEX_STUB_LOG".*; }

turns() {
  # REAL exec turns recorded so far (the file only exists once one happened).
  if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi
}

tok_after() {
  # tok_after <n> <token> — the argv token FOLLOWING <token> in invocation <n>.
  tr "$US" '\n' <"$CODEX_STUB_LOG.argv.$1" | awk -v t="$2" 'p==1{print;exit} $0==t{p=1}'
}

tok_count() {
  tr "$US" '\n' <"$CODEX_STUB_LOG.argv.$1" | awk -v t="$2" '$0==t{n++} END{print n+0}'
}

pins_of() {
  # The pin block the REAL helper produces for a read-only seat rooted at <dir>,
  # joined with the stub's separator. Derived from scripts/_pins.sh itself so
  # this file can never freeze a second copy of the policy.
  (
    CODEX_SANDBOX=read-only
    TANDEM_CODEX_CWD="$1"
    # shellcheck source=../scripts/_pins.sh
    . "$SCRIPTS/_pins.sh"
    codex_pins
    IFS="$US"
    printf '%s' "${CODEX_PINS[*]}"
  )
}

assert_temp_root() {
  # assert_temp_root <dir> — a private temp directory, never the user's tree.
  local d="$1"
  case "$d" in
    "$TMPDIR"/*) : ;;
    *) fail "smoke working root is not under TMPDIR ($TMPDIR): $d" ;;
  esac
  case "$d/" in
    "$REPO_ROOT"/* | "$CLAUDE_PROJECT_DIR"/*) fail "smoke working root is inside the project: $d" ;;
  esac
}

# --- 1. no flag: not one single codex exec, ever ------------------------------
reset_stub
doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "default run"
assert_eq "0" "$(turns)" "exec turns without --smoke"
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_not_contains "$OUT" "model smoke"

# --- 2. an unknown argument is a usage error, before anything runs ------------
reset_stub
run env -u TANDEM_IMPLEMENTER bash "$SCRIPTS/codex-doctor.sh" --bogus
assert_rc 64 "unknown argument"
assert_file_contains "$ERR" "unknown argument: --bogus"
assert_file_contains "$ERR" "usage: codex-doctor.sh [--smoke]"
assert_eq "0" "$(turns)" "exec turns after a usage error"

# --- 3. --smoke with the default policy: exactly two turns, deduped ----------
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER
assert_rc 0 "smoke, default policy"
assert_file_contains "$OUT" "about to spend 2 REAL codex turns"
assert_file_contains "$OUT" "ok    model gpt-5.6-sol answers"
assert_file_contains "$OUT" "ok    model gpt-5.6-luna answers"
assert_eq "2" "$(turns)" "one turn per unique model (five roles, two models)"
assert_no_file "$CODEX_STUB_LOG.argv.3"
assert_file_contains "$OUT" "tandem doctor: all good."

# The argv, byte for byte — the only unknown is the temp root, read back from
# the command line itself and then re-asserted whole.
CD1="$(tok_after 1 --cd)"
assert_temp_root "$CD1"
assert_eq "1" "$(tok_count 1 --cd)" "exactly one --cd (the CLI rejects two)"
TMPROOT="$(dirname "$CD1")"
assert_argv 1 "exec${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}$(pins_of "$CD1")${US}-c${US}web_search=disabled${US}--ephemeral${US}--output-last-message${US}${TMPROOT}/reply.txt${US}-"
assert_argv 2 "exec${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-luna${US}--sandbox${US}read-only${US}$(pins_of "$CD1")${US}-c${US}web_search=disabled${US}--ephemeral${US}--output-last-message${US}${TMPROOT}/reply.txt${US}-"

# Stated again on their own, because these four are the reasons the block exists.
assert_file_contains "$CODEX_STUB_LOG.argv.1" "--ephemeral"
assert_file_contains "$CODEX_STUB_LOG.argv.1" "web_search=disabled"
assert_file_contains "$CODEX_STUB_LOG.argv.1" "approvals_reviewer=user"
# No effort override: `minimal` is unsupported by the default models, and
# forcing one could report a healthy model as retired.
assert_not_contains "$CODEX_STUB_LOG.argv.1" "model_reasoning_effort"
assert_not_contains "$CODEX_STUB_LOG.argv.2" "model_reasoning_effort"

# The prompt is one line and the turn writes nothing into the project.
assert_file_contains "$(stub_stdin 1)" "Reply with exactly: OK"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem"
# The private working root is cleaned up by the trap.
assert_no_file "$CD1"

# --- 4. the model SET: overrides, dedupe and the implement rule ---------------
# A third distinct model means a third turn.
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER TANDEM_IMAGE_MODEL=custom-image
assert_rc 0 "smoke with three distinct models"
assert_file_contains "$OUT" "about to spend 3 REAL codex turns"
assert_eq "3" "$(turns)" "three unique models"
assert_eq "gpt-5.6-sol" "$(tok_after 1 --model)" "model of turn 1"
assert_eq "custom-image" "$(tok_after 2 --model)" "model of turn 2"
assert_eq "gpt-5.6-luna" "$(tok_after 3 --model)" "model of turn 3"

# Under sol the implement model joins the set — and dedupes into it by default.
reset_stub
doctor_smoke TANDEM_IMPLEMENTER=sol
assert_rc 0 "smoke under sol, default models"
assert_eq "2" "$(turns)" "implement dedupes into review's model"

reset_stub
doctor_smoke TANDEM_IMPLEMENTER=sol TANDEM_IMPLEMENT_MODEL=impl-only
assert_rc 0 "smoke under sol with a distinct implement model"
assert_eq "3" "$(turns)" "implement is smoked under sol"
assert_eq "impl-only" "$(tok_after 2 --model)" "the implement model"

# Under opus it is NOT: that transport spends no codex turn at all.
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER TANDEM_IMPLEMENT_MODEL=impl-only
assert_rc 0 "smoke under opus with a distinct implement model"
assert_eq "2" "$(turns)" "implement is not smoked under opus"
assert_not_contains "$CODEX_STUB_LOG.argv.1" "impl-only"
assert_not_contains "$CODEX_STUB_LOG.argv.2" "impl-only"

# --- 5. an inherited TANDEM_CODEX_CWD never survives into the smoke ----------
mkdir -p "$SANDBOX/inherited"
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER TANDEM_CODEX_CWD="$SANDBOX/inherited"
assert_rc 0 "smoke with an inherited working root"
assert_eq "1" "$(tok_count 1 --cd)" "still exactly one --cd"
CD_INH="$(tok_after 1 --cd)"
assert_temp_root "$CD_INH"
assert_eq "0" "$(tok_count 1 "$SANDBOX/inherited")" "the inherited root never reaches codex"

# Defined-but-empty is overwritten just the same (the wrappers reject it; here
# it must simply not produce a second, empty --cd).
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER TANDEM_CODEX_CWD=
assert_rc 0 "smoke with a defined-empty working root"
assert_eq "1" "$(tok_count 1 --cd)" "one --cd with a defined-empty inherited value"
assert_temp_root "$(tok_after 1 --cd)"

# --- 6. a model the API does not know: named, actionable, and not the end ----
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_FAIL_MODEL=gpt-5.6-sol CODEX_STUB_FAIL_KIND=model
assert_rc 1 "smoke with an unavailable model"
assert_file_contains "$OUT" "FAIL  model gpt-5.6-sol is not available"
assert_file_contains "$OUT" "the CLI/API rejected the model NAME itself"
assert_file_contains "$OUT" "action: point the matching TANDEM_*_MODEL override"
# Continuation is an assertion, not a courtesy.
assert_eq "2" "$(turns)" "the later model still ran"
assert_file_contains "$OUT" "ok    model gpt-5.6-luna answers"
assert_file_contains "$OUT" "tandem doctor: problems found"

# --- 7. an auth failure that MENTIONS the model is not a deprecation ---------
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_FAIL_MODEL=gpt-5.6-sol CODEX_STUB_FAIL_KIND=other
assert_rc 1 "smoke with an auth failure"
assert_file_contains "$OUT" "FAIL  model gpt-5.6-sol: the turn failed (exit 7) — NOT a model-availability failure"
assert_not_contains "$OUT" "gpt-5.6-sol is not available"
# The stderr the classification was based on is shown, never swallowed.
assert_file_contains "$OUT" "stderr: Error: 401 Unauthorized"
assert_eq "2" "$(turns)" "the later model still ran after an auth failure"
assert_file_contains "$OUT" "ok    model gpt-5.6-luna answers"

# --- 8. a hung model is cut by the watchdog, alone ---------------------------
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_HANG_MODEL=gpt-5.6-sol \
  TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=2
assert_rc 1 "smoke with a hung model"
assert_file_contains "$OUT" "FAIL  model gpt-5.6-sol: no reply within 2s"
assert_file_contains "$OUT" "NOT a model-availability failure"
# The FAIL line is the whole report: bash's own "Terminated: 15 <command line>"
# job notice must not be dumped into the middle of a diagnosis.
assert_not_contains "$ERR" "Terminated"
assert_eq "2" "$(turns)" "the later model still ran after a timeout"
assert_file_contains "$OUT" "ok    model gpt-5.6-luna answers"

# --- 9. the watchdog override is validated ------------------------------------
reset_stub
run env -u TANDEM_IMPLEMENTER TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=abc \
  bash "$SCRIPTS/codex-doctor.sh" --smoke
assert_rc 64 "non-numeric timeout override"
assert_file_contains "$ERR" "TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS must be a positive integer"
assert_eq "0" "$(turns)" "no turn after an invalid timeout"

run env -u TANDEM_IMPLEMENTER TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=0 \
  bash "$SCRIPTS/codex-doctor.sh" --smoke
assert_rc 64 "zero is not a positive integer"

# …and it is irrelevant without the flag: the default run stays byte-identical.
run env -u TANDEM_IMPLEMENTER TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=abc \
  bash "$SCRIPTS/codex-doctor.sh"
assert_rc 0 "an invalid timeout does not break the default diagnosis"
assert_eq "0" "$(turns)" "still no turn"

# --- 10. a CLI without --ephemeral: FAIL, and zero real turns ----------------
# The capability probe (`exec --help`) is not a paid turn, which is exactly why
# every count above could be trusted.
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_HELP_NO_EPHEMERAL=1
assert_rc 1 "smoke against a CLI without --ephemeral"
assert_file_contains "$OUT" "FAIL  smoke not run: this codex CLI has no 'exec --ephemeral' flag"
assert_file_contains "$OUT" "npm install -g @openai/codex@latest"
assert_eq "0" "$(turns)" "the probe never became a turn"
assert_no_file "$CODEX_STUB_LOG.argv.1"

# --- 11. a FAILED help probe proves nothing: FAIL, zero real turns -----------
# Help text scraped out of a failed `exec --help` (it can still print the flag
# before dying) must not license real turns.
reset_stub
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_HELP_RC=3
assert_rc 1 "smoke against a CLI whose help probe fails"
assert_file_contains "$OUT" "FAIL  smoke not run: 'codex exec --help' failed (rc 3)"
assert_eq "0" "$(turns)" "no turn on an unproven capability"

# --- 12. the watchdog reaps TERM-resistant descendants -----------------------
# The group leader dies on the watchdog's TERM, but its child ignores TERM: only
# the KILL half of the sequence reaps it — and the doctor must LET the watchdog
# finish that half instead of killing it the moment the leader is gone.
reset_stub
RES_PIDFILE="$SANDBOX/resistant.pid"
doctor_smoke -u TANDEM_IMPLEMENTER CODEX_STUB_HANG_MODEL=gpt-5.6-sol \
  CODEX_STUB_HANG_RESISTANT=1 CODEX_STUB_HANG_PIDFILE="$RES_PIDFILE" \
  TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=2
assert_rc 1 "smoke with a TERM-resistant hung model"
assert_file "$RES_PIDFILE"
RES_PID="$(cat "$RES_PIDFILE" 2>/dev/null)"
case "$RES_PID" in
  '' | *[!0-9]*) fail "the stub did not record the resistant child's pid" ;;
esac
if kill -0 "$RES_PID" 2>/dev/null; then
  kill -KILL "$RES_PID" 2>/dev/null || true
  fail "the TERM-resistant child (pid $RES_PID) survived the doctor's watchdog"
fi
assert_eq "2" "$(turns)" "the later model still ran after the resistant hang"

# --- 13. an interrupted doctor reaps the group, leader alive or not ----------
# TERM arrives while the hung turn is in flight — possibly inside the watchdog's
# grace window, where the leader is already dead but the TERM-resistant child
# keeps the process GROUP alive. The cleanup trap must kill the group on its own
# liveness, never gated on the leader's.
reset_stub
RES_PIDFILE_2="$SANDBOX/resistant-int.pid"
env -u TANDEM_IMPLEMENTER CODEX_STUB_HANG_MODEL=gpt-5.6-sol \
  CODEX_STUB_HANG_RESISTANT=1 CODEX_STUB_HANG_PIDFILE="$RES_PIDFILE_2" \
  TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=2 \
  bash "$SCRIPTS/codex-doctor.sh" --smoke >"$OUT" 2>"$ERR" &
DOC_PID=$!
# t≈3: past the watchdog's TERM (t=2), inside its KILL grace (t=4) on a fast
# box; still mid-hang on a slow one. The contract asserted below holds on both
# paths — the grace-window one is the CR2 regression case.
sleep 3
kill -TERM "$DOC_PID" 2>/dev/null
RC_DOC=0
wait "$DOC_PID" 2>/dev/null || RC_DOC=$?
[ -f "$RES_PIDFILE_2" ] || fail "the stub did not record the resistant child's pid (interruption case)"
RES_PID_2="$(cat "$RES_PIDFILE_2" 2>/dev/null)"
case "$RES_PID_2" in
  '' | *[!0-9]*) fail "unreadable resistant pid: '$RES_PID_2'" ;;
esac
# The cleanup's own TERM->KILL grace is 1s; give it a moment, then require death.
i=0
while [ "$i" -lt 6 ] && kill -0 "$RES_PID_2" 2>/dev/null; do sleep 1; i=$((i + 1)); done
if kill -0 "$RES_PID_2" 2>/dev/null; then
  kill -KILL "$RES_PID_2" 2>/dev/null || true
  fail "the resistant child (pid $RES_PID_2) survived the interrupted doctor"
fi
note "interrupted doctor exited rc=$RC_DOC with the group reaped"

# Nothing in this file ever created state in the project.
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem"
