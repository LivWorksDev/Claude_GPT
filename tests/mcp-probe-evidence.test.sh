#!/usr/bin/env bash
# scripts/mcp-probe.sh — the evidence contract. Nothing here is decorative: the
# orchestrator pastes these paths into the Phase 2 audit, so every path the run
# prints has to exist, the verdict on stdout has to be the verdict on disk, and
# the copied auth token must never, under any path, land inside .tandem/.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/mcp-probe.sh"
export TANDEM_MCP_PROBE_TIMEOUT_SECONDS=5
export CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"

mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

# A .gitignore the user edited by hand: state_init only writes it when ABSENT.
ROOT="$CLAUDE_PROJECT_DIR/.tandem"
mkdir -p "$ROOT"
GITIGNORE_CONTENT="$(printf '*\n!log/\n# kept by hand\n')"
printf '%s\n' "$GITIGNORE_CONTENT" >"$ROOT/.gitignore"

run env CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_ev CODEX_STUB_THREAD_ID=thr_mcp_ev \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" \
  bash "$PROBE" --spend
assert_rc 0 "evidence run"

RUN_DIR="$(LC_ALL=C grep '^MCP-PROBE RESULT:' "$OUT" | LC_ALL=C sed -e 's|.*evidence: ||' | tail -n 1)"
[ -n "$RUN_DIR" ] || fail "the summary line carried no evidence path"

# --- layout under .tandem/state/mcp-probe/<run>/ -----------------------------
case "$RUN_DIR" in
  "$ROOT/state/mcp-probe/"*) : ;;
  *) fail "the run directory is not under $ROOT/state/mcp-probe: $RUN_DIR" ;;
esac
assert_file "$RUN_DIR/codex-version.txt"
assert_file "$RUN_DIR/preflight/initialize.json"
assert_file "$RUN_DIR/preflight/tools.json"
assert_file "$RUN_DIR/preflight/rpc.in.ndjson"
assert_file "$RUN_DIR/preflight/rpc.out.ndjson"
assert_file "$RUN_DIR/preflight/server.stderr.log"
assert_file "$RUN_DIR/probe-b/result.json"
assert_file "$RUN_DIR/probe-b/thread-id.txt"
assert_file "$RUN_DIR/probe-c/config.pre.toml"
assert_file "$RUN_DIR/probe-c/config.post.toml"
assert_file "$RUN_DIR/probe-c/rollout.jsonl"
assert_file "$RUN_DIR/probe-c/turn-context.last.json"
assert_file "$RUN_DIR/probe-a/sessions.txt"
assert_file "$RUN_DIR/probe-a/events.ndjson"
assert_file "$RUN_DIR/probe-a/reply.txt"
assert_file "$RUN_DIR/probe-d/static-verdict.txt"

# --- stdout and verdict.txt say the SAME token -------------------------------
for p in a b c d; do
  assert_file "$RUN_DIR/probe-$p/verdict.txt"
  V_OUT="$(LC_ALL=C grep "^PROBE $p: " "$OUT" | LC_ALL=C sed -e "s|^PROBE $p: \([A-Z_]*\) .*|\1|" | head -n 1)"
  V_FILE="$(LC_ALL=C sed -n 's|^verdict: ||p' "$RUN_DIR/probe-$p/verdict.txt" | head -n 1)"
  [ -n "$V_OUT" ] || fail "probe $p printed no verdict line"
  assert_eq "$V_OUT" "$V_FILE" "probe $p: stdout vs verdict.txt"
done

# Every evidence path the run advertised really exists.
LC_ALL=C grep '^PROBE ' "$OUT" | LC_ALL=C sed -e 's|.*(evidence: ||' -e 's|)$||' >"$SANDBOX/paths.txt"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -d "$p" ] || fail "advertised evidence path does not exist: $p"
done <"$SANDBOX/paths.txt"

# --- the token never enters the project tree ---------------------------------
assert_eq "" "$(find "$ROOT" -name 'auth.json' 2>/dev/null | head -n 1)" \
  "auth.json inside .tandem"
assert_eq "" "$(LC_ALL=C grep -r -l 'fake-for-tests' "$ROOT" 2>/dev/null | head -n 1)" \
  "the token's content inside .tandem"
# …and the ephemeral home that did hold it is gone.
assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'tandem-mcp.*' 2>/dev/null | head -n 1)" \
  "ephemeral CODEX_HOME left behind"

# --- the user's .gitignore is untouched --------------------------------------
assert_eq "$GITIGNORE_CONTENT" "$(cat "$ROOT/.gitignore")" ".tandem/.gitignore"
