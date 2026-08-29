#!/usr/bin/env bash
# scripts/mcp-probe.sh — the COST gate. Without --spend the script may talk to
# the MCP server (the handshake is free and needs no auth) but must not issue a
# single tools/call nor a single `codex exec`: the stub's two counters, one per
# transport, are the meter. The static verdict of (d) is emitted either way, and
# its version gate is fail-closed — a CLI that is not the audited one gets no
# green verdict for code it may no longer contain.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/mcp-probe.sh"
export TANDEM_MCP_PROBE_TIMEOUT_SECONDS=5
# The MCP tests pin the audited version so the STATIC verdicts are reachable;
# the stub's default (codex-cli 0.0.0-stub) is asserted by another test and must
# stay untouched, which is why this is a knob and not a new default.
export CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"

# A file-based login is what the probes copy into the ephemeral home.
seed_auth() {
  mkdir -p "$HOME/.codex"
  printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"
}
seed_auth

reset_stub() { rm -f "$CODEX_STUB_LOG".*; }

calls() {
  if [ -f "$CODEX_STUB_LOG.mcp.calls" ]; then cat "$CODEX_STUB_LOG.mcp.calls"; else printf '0'; fi
}
turns() {
  if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi
}

# --- 1. no flag: the free preflight runs, nothing is spent -------------------
reset_stub
run bash "$PROBE"
assert_rc 0 "default run"
assert_file_contains "$OUT" "ok    handshake: initialize + tools/list"
assert_file_contains "$OUT" "total: 3 REAL codex turns"
assert_file_contains "$OUT" "--spend not given: nothing is spent"
assert_file_contains "$OUT" "PROBE b: NOT_RUN — requires --spend"
assert_file_contains "$OUT" "PROBE c: NOT_RUN — requires --spend"
assert_file_contains "$OUT" "PROBE a: NOT_RUN — requires --spend"
# The static verdict does NOT need --spend: it is a closed question, not a turn.
assert_file_contains "$OUT" "PROBE d: STATIC"
assert_file_contains "$OUT" "MCP-PROBE RESULT: 0 pass · 0 fail · 0 indeterminable · 1 static · 3 not run"
# Zero turns on BOTH transports, asserted through the stub's own counters.
assert_no_file "$CODEX_STUB_LOG.mcp.calls"
assert_no_file "$CODEX_STUB_LOG.n"
assert_eq "0" "$(calls)" "tools/call without --spend"
assert_eq "0" "$(turns)" "codex exec without --spend"
# stderr belongs to exit 2/64 alone — a successful run says NOTHING there. This
# is a regression anchor, not decoration: the watchdogs are forked with `&` and
# the parent stops them with a plain `kill` (TERM), so a background subshell that
# inherited the script's TERM trap would run the cleanup it must never run and
# bash would print `run_pending_traps: bad value in trap_list[15]` here. Found by
# running the real server (the stub's timing hid it), fixed by resetting the
# inherited traps inside each watchdog.
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "stderr on a successful run"
assert_not_contains "$ERR" "run_pending_traps"
# …and the handshake really happened (the preflight is not free by being absent).
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"method":"initialize"'
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"method":"tools/list"'

# --- 2. a CLI that is not the audited one gets no STATIC verdict -------------
reset_stub
run env -u CODEX_STUB_VERSION_TEXT bash "$PROBE"
assert_rc 1 "unaudited CLI version"
assert_file_contains "$OUT" "PROBE d: INDETERMINABLE"
assert_file_contains "$OUT" "veredicto estático auditado para 0.144.4"
assert_file_contains "$OUT" "codex-cli 0.0.0-stub"
assert_not_contains "$OUT" "PROBE d: STATIC"
assert_eq "0" "$(calls)" "no call while merely reporting a version mismatch"

# --- 3. usage errors: 64, and nothing is launched ----------------------------
reset_stub
run bash "$PROBE" --bogus
assert_rc 64 "unknown argument"
assert_file_contains "$ERR" "unknown argument: --bogus"
assert_file_contains "$ERR" "usage: mcp-probe.sh [--spend] [--only <a|b|c|d>[,…]]"
assert_no_file "$CODEX_STUB_LOG.mcp.in"

run bash "$PROBE" --only e
assert_rc 64 "unknown probe"
assert_file_contains "$ERR" "unknown probe in --only: e"
assert_no_file "$CODEX_STUB_LOG.mcp.in"

run bash "$PROBE" --only ""
assert_rc 64 "empty --only"

run env TANDEM_MCP_PROBE_TIMEOUT_SECONDS=abc bash "$PROBE"
assert_rc 64 "non-numeric timeout"
assert_file_contains "$ERR" "TANDEM_MCP_PROBE_TIMEOUT_SECONDS must be a positive integer"
assert_no_file "$CODEX_STUB_LOG.mcp.in"

# The watchdog governs the free preflight too, so it is validated with or
# without the spend flag.
run env TANDEM_MCP_PROBE_TIMEOUT_SECONDS=0 bash "$PROBE" --spend
assert_rc 64 "zero is not a positive integer"
assert_no_file "$CODEX_STUB_LOG.mcp.calls"

# The confidentiality switch is validated in the same usage-error window:
# before need_codex, before the free server handshake, and before probe state.
PROBE_SD="$(state_dir mcp-probe)"
for WEB_VALUE in "" bogus; do
  reset_stub
  rm -rf "$PROBE_SD"
  run env TANDEM_WEB_SEARCH="$WEB_VALUE" bash "$PROBE" --spend
  assert_rc 64 "invalid TANDEM_WEB_SEARCH '$WEB_VALUE'"
  assert_file_contains "$ERR" "TANDEM_WEB_SEARCH is not a valid value"
  assert_eq "0" "$(calls)" "tools/call count for invalid TANDEM_WEB_SEARCH"
  assert_eq "0" "$(turns)" "codex exec count for invalid TANDEM_WEB_SEARCH"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
  assert_no_file "$PROBE_SD"
done

# --- 4. --only runs the prerequisite CLOSURE, and says so in the budget ------
reset_stub
run bash "$PROBE" --only a
assert_rc 0 "--only a"
assert_file_contains "$OUT" "probe b  home-auth"
assert_file_contains "$OUT" "probe c  frozen-inheritance"
assert_file_contains "$OUT" "probe a  rollout-resume"
assert_file_contains "$OUT" "total: 3 REAL codex turns"
# d was not selected: no static verdict, and the counters say so.
assert_not_contains "$OUT" "PROBE d:"
assert_file_contains "$OUT" "MCP-PROBE RESULT: 0 pass · 0 fail · 0 indeterminable · 0 static · 3 not run"

reset_stub
run bash "$PROBE" --only d
assert_rc 0 "--only d"
assert_file_contains "$OUT" "total: 0 REAL codex turns"
assert_file_contains "$OUT" "PROBE d: STATIC"
assert_not_contains "$OUT" "PROBE b:"

# --- 5. no auth.json: INDETERMINABLE before a single turn is spent ----------
reset_stub
rm -f "$HOME/.codex/auth.json"
run bash "$PROBE" --spend
assert_rc 1 "no auth.json"
assert_file_contains "$OUT" "PROBE b: INDETERMINABLE"
assert_file_contains "$OUT" "no auth.json in"
assert_file_contains "$OUT" "codex login"
assert_file_contains "$OUT" "PROBE c: NOT_RUN — dependencia b no superada"
assert_file_contains "$OUT" "PROBE a: NOT_RUN — dependencia b no superada"
assert_no_file "$CODEX_STUB_LOG.mcp.calls"
assert_eq "0" "$(turns)" "no exec turn without a token"
seed_auth

# --- 6. junk on the wire never breaks the free handshake --------------------
# The client polls an NDJSON file while it is being written: only lines jq
# accepts are parsed, and the rest are re-polled.
reset_stub
run env CODEX_STUB_MCP_SCENARIO=garbage bash "$PROBE"
assert_rc 0 "garbage on the wire, no spend"
assert_file_contains "$OUT" "ok    handshake: initialize + tools/list"
assert_file_contains "$OUT" "PROBE d: STATIC"
assert_no_file "$CODEX_STUB_LOG.mcp.calls"
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"method":"tools/list"'

# --- 7. paid probe turns inherit the closed web-search policy ---------------
reset_stub
run env TANDEM_WEB_SEARCH=off CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_THREAD_ID=thr_mcp_stub_1 \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" \
  bash "$PROBE" --spend
assert_rc 0 "paid probes with web search off"
assert_eq "2" "$(calls)" "mcp tools/call count with --spend"
assert_eq "1" "$(turns)" "exec resume count with --spend"
assert_file_contains "$CODEX_STUB_LOG.mcp.in" '"web_search":"disabled"'
assert_file_contains "$CODEX_STUB_LOG.argv.1" "web_search=disabled"
