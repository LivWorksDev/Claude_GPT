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

# --- 1. the happy path: PASS · PASS · PASS · STATIC --------------------------
reset_stub
run env CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_happy CODEX_STUB_THREAD_ID=thr_mcp_happy \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" \
  bash "$PROBE" --spend
assert_rc 0 "happy path"
assert_file_contains "$OUT" "PROBE b: PASS"
assert_file_contains "$OUT" "PROBE c: PASS"
assert_file_contains "$OUT" "PROBE a: PASS"
assert_file_contains "$OUT" "PROBE d: STATIC"
assert_file_contains "$OUT" "MCP-PROBE RESULT: 3 pass · 0 fail · 0 indeterminable · 1 static · 0 not run"
assert_eq "2" "$(calls)" "two tools/call (codex + codex-reply)"
assert_eq "1" "$(turns)" "one codex exec resume"

# The budget is printed WHOLE before anything is launched: stdout is written
# sequentially, and the first tools/call can only happen after the preflight
# lines, which sit below the total.
BUDGET_LINE="$(line_no 'total: 3 REAL codex turns')"
PREFLIGHT_LINE="$(line_no 'preflight (free')"
FIRST_PROBE_LINE="$(line_no 'PROBE b:')"
[ -n "$BUDGET_LINE" ] || fail "the budget total was never printed"
[ "$BUDGET_LINE" -lt "$PREFLIGHT_LINE" ] \
  || fail "the budget must precede the preflight (got $BUDGET_LINE vs $PREFLIGHT_LINE)"
[ "$PREFLIGHT_LINE" -lt "$FIRST_PROBE_LINE" ] \
  || fail "the preflight must precede the first probe line"

# The config was rewritten BETWEEN the two calls: the snapshots the server took
# at each call are the evidence.
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.1" 'model = "gpt-5.6-sol"'
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.2" 'model = "tandem-bogus-model-m19"'
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.1" 'model_reasoning_effort = "xhigh"'
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.2" 'model_reasoning_effort = "low"'
# …and the hostile rewrite touched ONLY model and effort. Degrading the security
# fields right before the turn whose premise is that they are not inherited
# would run a PAID turn without containment if the premise were false.
for cfg in 1 2; do
  assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'sandbox_mode = "read-only"'
  assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'approval_policy = "never"'
  assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'approvals_reviewer = "user"'
  assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'sandbox_workspace_write.network_access = false'
  assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'sandbox_workspace_write.writable_roots = []'
  assert_not_contains "$CODEX_STUB_LOG.mcp.cfg.$cfg" 'danger-full-access'
done
# The token was in the ephemeral home before the paid call, not after it.
assert_file_contains "$CODEX_STUB_LOG.mcp.auth.1" "present"

# The call carries the pins per call as well as in the home's config.
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"sandbox":"read-only"'
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"approval-policy":"never"'
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"model_reasoning_effort":"xhigh"'

# Anti-self-fulfilment: the codeword is seeded in (b) and NEVER handed to (a).
CW="$(cat "$CODEX_STUB_LOG.mcp.codeword" 2>/dev/null)"
case "$CW" in
  TDM-*) : ;;
  *) fail "the stub did not recover a codeword from call 1: '$CW'" ;;
esac
assert_file_contains "$CODEX_STUB_LOG.mcp.in" "$CW"
assert_not_contains "$(stub_stdin 1)" "$CW"
RD="$(run_dir)"
assert_not_contains "$RD/probe-a/prompt.txt" "$CW"
assert_file_contains "$RD/probe-a/reply.txt" "$CW"

# --- 2. auth failure: FAIL in (b), zero extra turns, (d) unaffected ----------
reset_stub
run env CODEX_STUB_MCP_SCENARIO=auth-error CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "auth error"
assert_file_contains "$OUT" "PROBE b: FAIL"
assert_file_contains "$OUT" "AUTH semantics"
assert_file_contains "$OUT" "401 Unauthorized"
# The dependents skip, and the skip is free: still exactly ONE tools/call.
assert_file_contains "$OUT" "PROBE c: NOT_RUN — dependencia b no superada"
assert_file_contains "$OUT" "PROBE a: NOT_RUN — dependencia b no superada"
assert_eq "1" "$(calls)" "no call after the prerequisite failed"
assert_eq "0" "$(turns)" "no exec turn after the prerequisite failed"
# The independent probe still reports: the DAG governs the chain, not the free
# static verdict.
assert_file_contains "$OUT" "PROBE d: STATIC"
assert_file_contains "$OUT" "MCP-PROBE RESULT: 0 pass · 1 fail · 0 indeterminable · 1 static · 2 not run"

# --- 3. the continuation re-read the config: FAIL in (c), not in (b) --------
reset_stub
run env CODEX_STUB_MCP_SCENARIO=hostile-inherited CODEX_STUB_MCP_ROLLOUT=1 bash "$PROBE" --spend
assert_rc 1 "hostile inheritance"
assert_file_contains "$OUT" "PROBE b: PASS"
assert_file_contains "$OUT" "PROBE c: FAIL"
assert_file_contains "$OUT" "echoes the HOSTILE config"
assert_file_contains "$OUT" "tandem-bogus-model-m19"
assert_file_contains "$OUT" "PROBE a: NOT_RUN — dependencia c no superada"
assert_eq "2" "$(calls)" "the continuation ran, its dependent did not"
assert_eq "0" "$(turns)" "no resume turn after (c) failed"
RD="$(run_dir)"
assert_file "$RD/probe-c/config.pre.toml"
assert_file "$RD/probe-c/config.post.toml"
assert_file "$RD/probe-c/turn-context.last.json"
assert_file_contains "$RD/probe-c/turn-context.last.json" "tandem-bogus-model-m19"

# --- 4. resume attached to another thread: FAIL by the anti-fallback guard ---
reset_stub
run env CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_x CODEX_STUB_THREAD_ID=thr_other \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" \
  bash "$PROBE" --spend
assert_rc 1 "resume fallback"
assert_file_contains "$OUT" "PROBE b: PASS"
assert_file_contains "$OUT" "PROBE c: PASS"
assert_file_contains "$OUT" "PROBE a: FAIL"
assert_file_contains "$OUT" "resume attached to thread thr_other instead of thr_mcp_x"
assert_eq "1" "$(turns)" "the resume turn ran"

# --- 5. a resumed thread with no memory of the codeword: FAIL in (a) --------
reset_stub
run env CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_m CODEX_STUB_THREAD_ID=thr_mcp_m \
  CODEX_STUB_REPLY="I do not remember any codeword." \
  bash "$PROBE" --spend
assert_rc 1 "resume without the codeword"
assert_file_contains "$OUT" "PROBE a: FAIL"
assert_file_contains "$OUT" "never echoed the codeword"
assert_not_contains "$OUT" "PROBE a: PASS"

# --- 6. broken machinery is never a probe's FAIL ----------------------------
# A server that does not advertise the tools (an old CLI, a renamed subcommand)
# is the probe's own machinery failing: every live probe degrades to
# INDETERMINABLE, and nothing is spent.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=no-tools bash "$PROBE" --spend
assert_rc 1 "server without the tools"
assert_file_contains "$OUT" "BROKEN"
assert_file_contains "$OUT" "the probe machinery is at fault"
assert_file_contains "$OUT" "PROBE b: INDETERMINABLE"
assert_file_contains "$OUT" "PROBE c: INDETERMINABLE"
assert_file_contains "$OUT" "PROBE a: INDETERMINABLE"
assert_not_contains "$OUT" "FAIL"
assert_eq "0" "$(calls)" "no call against a server that offers no tools"
assert_eq "0" "$(turns)" "no exec turn either"
