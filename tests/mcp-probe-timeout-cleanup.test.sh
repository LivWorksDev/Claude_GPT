#!/usr/bin/env bash
# scripts/mcp-probe.sh — a hung turn and an interrupted script.
#
# The taxonomy is the point: a watchdog expiry is ALWAYS INDETERMINABLE, never
# FAIL — it proves nothing but "no answer before the deadline" — and because
# INDETERMINABLE is not green the exit code stays 1 and the hang stays
# actionable. The cleanup is the other point: the server's whole process GROUP
# dies (including a TERM-resistant descendant), the ephemeral CODEX_HOME with
# the copied token is removed, and the evidence under .tandem/ survives.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/mcp-probe.sh"
export CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"

mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

run_dir() {
  LC_ALL=C grep '^MCP-PROBE RESULT:' "$OUT" | LC_ALL=C sed -e 's|.*evidence: ||' | tail -n 1
}

homes_left() {
  find "$TMPDIR" -maxdepth 1 -name 'tandem-mcp.*' 2>/dev/null | head -n 1
}

# --- 1. a call that never answers: INDETERMINABLE, on time, with the group reaped
RES_PIDFILE="$SANDBOX/resistant.pid"
rm -f "$CODEX_STUB_LOG".*
run env CODEX_STUB_MCP_SCENARIO=hang-call CODEX_STUB_MCP_HANG_RESISTANT=1 \
  CODEX_STUB_HANG_PIDFILE="$RES_PIDFILE" CODEX_STUB_HANG_SECONDS=120 \
  TANDEM_MCP_PROBE_TIMEOUT_SECONDS=2 \
  bash "$PROBE" --spend
assert_rc 1 "a hung call is not green"
assert_file_contains "$OUT" "PROBE b: INDETERMINABLE"
assert_file_contains "$OUT" "no answer within 2s"
assert_file_contains "$OUT" "watchdog expired"
# The one explicit exception of the taxonomy: never FAIL.
assert_not_contains "$OUT" "PROBE b: FAIL"
# The chain stops without spending anything else.
assert_file_contains "$OUT" "PROBE c: NOT_RUN — dependencia b no superada"
assert_file_contains "$OUT" "PROBE a: NOT_RUN — dependencia b no superada"

# The TERM-resistant child only dies if the cleanup completes its TERM→KILL
# sequence on the GROUP.
assert_file "$RES_PIDFILE"
RES_PID="$(cat "$RES_PIDFILE" 2>/dev/null)"
case "$RES_PID" in
  '' | *[!0-9]*) fail "the stub did not record the resistant child's pid" ;;
esac
i=0
while [ "$i" -lt 6 ] && kill -0 "$RES_PID" 2>/dev/null; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$RES_PID" 2>/dev/null; then
  kill -KILL "$RES_PID" 2>/dev/null || true
  fail "the TERM-resistant server child (pid $RES_PID) survived the probe"
fi

# The ephemeral home is gone; the evidence is not.
assert_eq "" "$(homes_left)" "ephemeral CODEX_HOME removed"
RD="$(run_dir)"
assert_file "$RD/probe-b/verdict.txt"
assert_file_contains "$RD/probe-b/verdict.txt" "verdict: INDETERMINABLE"
assert_file "$RD/preflight/tools.json"
assert_file "$RD/preflight/rpc.in.ndjson"

# --- 2. TERM to the script in flight: the group is reaped just the same ------
rm -f "$CODEX_STUB_LOG".*
RES_PIDFILE_2="$SANDBOX/resistant-int.pid"
env CODEX_STUB_MCP_SCENARIO=hang-call CODEX_STUB_MCP_HANG_RESISTANT=1 \
  CODEX_STUB_HANG_PIDFILE="$RES_PIDFILE_2" CODEX_STUB_HANG_SECONDS=120 \
  TANDEM_MCP_PROBE_TIMEOUT_SECONDS=30 \
  bash "$PROBE" --spend >"$OUT" 2>"$ERR" &
PROBE_PID=$!
# Long enough to be inside the hung call, far from the 30s watchdog: the
# interruption, not the deadline, is what has to reap the group here.
sleep 5
kill -TERM "$PROBE_PID" 2>/dev/null
RC_INT=0
wait "$PROBE_PID" 2>/dev/null || RC_INT=$?
[ -f "$RES_PIDFILE_2" ] || fail "the stub did not record the resistant child's pid (interruption case)"
RES_PID_2="$(cat "$RES_PIDFILE_2" 2>/dev/null)"
case "$RES_PID_2" in
  '' | *[!0-9]*) fail "unreadable resistant pid: '$RES_PID_2'" ;;
esac
i=0
while [ "$i" -lt 6 ] && kill -0 "$RES_PID_2" 2>/dev/null; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$RES_PID_2" 2>/dev/null; then
  kill -KILL "$RES_PID_2" 2>/dev/null || true
  fail "the resistant child (pid $RES_PID_2) survived the interrupted probe"
fi
assert_eq "" "$(homes_left)" "ephemeral CODEX_HOME removed after the interruption"
note "interrupted probe exited rc=$RC_INT with the group reaped"
