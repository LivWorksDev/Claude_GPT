#!/usr/bin/env bash
# scripts/mcp-probe.sh — one verdict per failure mode, in the RIGHT probe.
#
# Two contracts dominate this file. First, HONEST CLASSIFICATION: auth,
# inheritance and anti-fallback are different failures and must never be
# reported as each other. Second, the DAG: a probe whose prerequisite did not
# pass emits NOT_RUN and spends NOTHING — the tools/call counter is the proof —
# while the independent static probe keeps reporting either way.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/mcp-probe.sh"
export TANDEM_MCP_PROBE_TIMEOUT_SECONDS=5
export CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"

mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

reset_stub() { rm -f "$CODEX_STUB_LOG".*; }
calls() {
  if [ -f "$CODEX_STUB_LOG.mcp.calls" ]; then cat "$CODEX_STUB_LOG.mcp.calls"; else printf '0'; fi
}
turns() {
  if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi
}
run_dir() {
  LC_ALL=C grep '^MCP-PROBE RESULT:' "$OUT" | LC_ALL=C sed -e 's|.*evidence: ||' | tail -n 1
}
line_no() {
  LC_ALL=C grep -n -F -- "$1" "$OUT" | LC_ALL=C cut -d: -f1 | head -n 1
}

# --- a PASS must PROVE what it claims ----------------------------------------
# Every case here was a REAL finding of this milestone's code review: a verdict
# that could have been handed out without evidence for what it asserts. They
# live apart from the verdict cases because together they exceed the runner's
# per-test budget — the split is the remedy, not a smaller suite.

# (c) The continuation ERRORED and appended nothing: reading "the last
# turn_context" would find call 1's own and certify a failed call as frozen
# inheritance. The count taken before the call is what makes that impossible.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=reply-error CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "codex-reply answered with isError"
assert_file_contains "$OUT" "PROBE c: INDETERMINABLE"
assert_file_contains "$OUT" "isError"
assert_not_contains "$OUT" "PROBE c: PASS"

# (c) Same trap without an error to notice it by: the call succeeds and appends
# no context at all.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=reply-silent CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "continuation that appends no turn_context"
assert_file_contains "$OUT" "PROBE c: INDETERMINABLE"
assert_file_contains "$OUT" "appended no turn_context"
assert_not_contains "$OUT" "PROBE c: PASS"

# (c) Model and effort inherited, security DEGRADED: a check that looked only at
# the model would hand out a PASS while the continuation lost `never` and
# `read-only` — the reassurance this probe exists not to give.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=unsafe-inherited CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "inheritance with a degraded sandbox"
assert_not_contains "$OUT" "PROBE c: PASS"

# (c) A continuation that appends a pinned context but echoes no threadId: the
# answer cannot be tied to the thread being judged.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=reply-no-thread CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "continuation without an echoed threadId"
assert_file_contains "$OUT" "PROBE c: INDETERMINABLE"
assert_file_contains "$OUT" "without echoing a threadId"
assert_not_contains "$OUT" "PROBE c: PASS"

# (a) The resume answers WITH the codeword but the stream carries NO
# thread.started. The reply file is what makes this case bite: with a default
# reply the old code would fail anyway for want of the codeword, and the test
# would prove nothing about the identity guard it exists to anchor.
reset_stub
run env CODEX_STUB_MCP_ROLLOUT=1 CODEX_STUB_SCENARIO=no-thread-event \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" bash "$PROBE" --spend
assert_rc 1 "resume without thread.started"
assert_file_contains "$OUT" "PROBE a: INDETERMINABLE"
assert_file_contains "$OUT" "no thread.started id"
assert_not_contains "$OUT" "PROBE a: PASS"

# (d) A suffixed build is NOT the audited one: `0.144.4-dev` is a source nobody
# read, and the static verdict may not be inherited by it.
reset_stub
run env CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4-dev" bash "$PROBE"
assert_rc 1 "suffixed version"
assert_file_contains "$OUT" "PROBE d: INDETERMINABLE"
assert_not_contains "$OUT" "PROBE d: STATIC"

# (c) The path the probe SENDS must be the path the server can echo back. macOS
# exports TMPDIR with a trailing slash, so an unnormalized `mktemp -d` yields
# `…/T//tandem-mcp.XXXX` while the server answers with the collapsed form: probe
# (c) then reports INDETERMINABLE over a mismatch that never happened. That is
# not hypothetical — it is what the FIRST real run of this script did, with its
# own evidence showing the inheritance had worked. Anchored on the request the
# probe writes: no doubled separator may reach the wire.
reset_stub
mkdir -p "$SANDBOX/withslash"
run env TMPDIR="$SANDBOX/withslash/" CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_slash CODEX_STUB_THREAD_ID=thr_mcp_slash \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" bash "$PROBE" --spend
assert_rc 0 "TMPDIR with a trailing slash"
PROBE_B_REQ="$(find "$CLAUDE_PROJECT_DIR/.tandem/state/mcp-probe" -type f \
  -name request.json -path '*/probe-b/*' 2>/dev/null | LC_ALL=C sort | tail -n 1)"
CWD_SENT="$(jq -r '.params.arguments.cwd' "$PROBE_B_REQ" 2>/dev/null)"
case "$CWD_SENT" in
  *//*) fail "the cwd sent to the server carries a doubled separator: $CWD_SENT" ;;
  '') fail "no cwd was recorded in probe b's request" ;;
  *) : ;;
esac
assert_file_contains "$OUT" "PROBE c: PASS"
