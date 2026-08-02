#!/usr/bin/env bash
# tests/fixtures/mcp-0.144.4/ — the REAL frames of `codex mcp-server` 0.144.4,
# captured from the live server with zero model turns.
#
# A green suite proves nothing if the stub invented the shapes it serves, so
# this case contrasts BOTH sides against those bytes: what the stub emits, and
# what scripts/mcp-probe.sh actually sends and reads. A divergence fails here
# instead of surviving until a paid run.
#
# The `SessionConfigured` notification and the rollout's `turn_context` line
# have NO fixture yet — capturing them costs a real turn — so they are NOT
# invented here: the case reports them as pending, and the moment the
# orchestrator commits them with the evidence of the `--spend` run, the
# conformance below extends itself to cover them.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/mcp-probe.sh"
FIX="$REPO_ROOT/tests/fixtures/mcp-0.144.4"
export TANDEM_MCP_PROBE_TIMEOUT_SECONDS=5
export CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"

assert_file "$FIX/initialize.json"
assert_file "$FIX/tools-list.json"
assert_file "$FIX/handshake-raw.jsonl"
assert_file "$FIX/codex-version.txt"
assert_file_contains "$FIX/codex-version.txt" "0.144.4"

# --- 0. the fixture set is self-consistent -----------------------------------
# The raw bytes and the pretty JSONs must be the same two frames, or the
# "ground truth" is already two different truths.
jq -S . "$FIX/initialize.json" >"$SANDBOX/fx-init.json"
jq -S . "$FIX/tools-list.json" >"$SANDBOX/fx-tools.json"
LC_ALL=C sed -n 1p "$FIX/handshake-raw.jsonl" | jq -S . >"$SANDBOX/raw-init.json"
LC_ALL=C sed -n 2p "$FIX/handshake-raw.jsonl" | jq -S . >"$SANDBOX/raw-tools.json"
cmp -s "$SANDBOX/fx-init.json" "$SANDBOX/raw-init.json" \
  || fail "initialize.json and handshake-raw.jsonl line 1 disagree"
cmp -s "$SANDBOX/fx-tools.json" "$SANDBOX/raw-tools.json" \
  || fail "tools-list.json and handshake-raw.jsonl line 2 disagree"

# --- 1. the stub serves the REAL shapes --------------------------------------
rm -f "$CODEX_STUB_LOG".*
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"conformance","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
} | codex mcp-server >"$SANDBOX/stub-handshake.ndjson" 2>"$SANDBOX/stub-handshake.err"

LC_ALL=C sed -n 1p "$SANDBOX/stub-handshake.ndjson" >"$SANDBOX/stub-init.json"
LC_ALL=C sed -n 2p "$SANDBOX/stub-handshake.ndjson" >"$SANDBOX/stub-tools.json"

# The frame's own shape: envelope keys, protocol version, capabilities, and the
# server identity the client keys on.
INIT_Q='{env:(keys), pv:.result.protocolVersion, caps:.result.capabilities,
         si:(.result.serverInfo|keys), name:.result.serverInfo.name}'
assert_eq "$(jq -S -c "$INIT_Q" "$FIX/initialize.json")" \
  "$(jq -S -c "$INIT_Q" "$SANDBOX/stub-init.json")" \
  "initialize frame: stub vs real 0.144.4"

# The tool surface the probe depends on, key by key: names, every inputSchema
# property, what is required, the enums whose values the probe SENDS, and the
# structured output it reads.
TOOLS_Q='[.result.tools[] | {
    name,
    props:(.inputSchema.properties|keys),
    required:(.inputSchema.required),
    approval:(.inputSchema.properties["approval-policy"].enum),
    sandbox:(.inputSchema.properties["sandbox"].enum),
    out:(.outputSchema.properties|keys),
    out_required:(.outputSchema.required)
  }] | sort_by(.name)'
assert_eq "$(jq -S -c "$TOOLS_Q" "$FIX/tools-list.json")" \
  "$(jq -S -c "$TOOLS_Q" "$SANDBOX/stub-tools.json")" \
  "tools/list schema: stub vs real 0.144.4"

# --- 2. what the PROBE sends fits the real schema ----------------------------
rm -f "$CODEX_STUB_LOG".*
mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"
run env CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_conf CODEX_STUB_THREAD_ID=thr_mcp_conf \
  CODEX_STUB_REPLY_FILE="$CODEX_STUB_LOG.mcp.codeword" \
  bash "$PROBE" --spend
assert_rc 0 "conformance run"

CALL_CODEX="$(jq -Rc 'fromjson? | objects
  | select((.method? // "") == "tools/call" and (.params.name? // "") == "codex")' \
  "$CODEX_STUB_LOG.mcp.in" | head -n 1)"
CALL_REPLY="$(jq -Rc 'fromjson? | objects
  | select((.method? // "") == "tools/call" and (.params.name? // "") == "codex-reply")' \
  "$CODEX_STUB_LOG.mcp.in" | head -n 1)"
[ -n "$CALL_CODEX" ] || fail "the probe never issued a codex tools/call"
[ -n "$CALL_REPLY" ] || fail "the probe never issued a codex-reply tools/call"
printf '%s\n' "$CALL_CODEX" >"$SANDBOX/call-codex.json"
printf '%s\n' "$CALL_REPLY" >"$SANDBOX/call-reply.json"

# Every argument the probe sends exists in the REAL schema, every required one
# is present, and the enum values it picks are values the real enums accept.
assert_json "$SANDBOX/call-codex.json" '
  . as $f | ($f | .params.arguments | keys) as $sent
  | ('"$(jq -c '.result.tools[] | select(.name=="codex") | .inputSchema' "$FIX/tools-list.json")"') as $schema
  | (($sent - ($schema.properties|keys)) | length == 0)
    and ((($schema.required) - $sent) | length == 0)
    and (($schema.properties["sandbox"].enum | index($f.params.arguments.sandbox)) != null)
    and (($schema.properties["approval-policy"].enum | index($f.params.arguments["approval-policy"])) != null)'

assert_json "$SANDBOX/call-reply.json" '
  . as $f | ($f | .params.arguments | keys) as $sent
  | ('"$(jq -c '.result.tools[] | select(.name=="codex-reply") | .inputSchema' "$FIX/tools-list.json")"') as $schema
  | (($sent - ($schema.properties|keys)) | length == 0)
    and ((($schema.required) - $sent) | length == 0)
    and (($f.params.arguments.threadId | type) == "string")'

# `cwd` is sent ABSOLUTE on purpose: the real server resolves a relative one
# against ITS OWN working directory (the fixture says so in the schema).
assert_json "$SANDBOX/call-codex.json" '.params.arguments.cwd | startswith("/")'

# --- 3. what the PROBE reads is what the real schema promises ----------------
# The parser keys on structuredContent.{threadId,content}; the real outputSchema
# declares exactly those two as required. If upstream renames them, both this
# assertion and the grep below have to move together.
assert_json "$FIX/tools-list.json" '
  [.result.tools[] | .outputSchema.required | sort] | all(. == ["content","threadId"])'
assert_file_contains "$PROBE" "structuredContent.threadId"
assert_file_contains "$PROBE" "structuredContent.content"

# --- 4. the shapes with NO fixture yet ---------------------------------------
# Deliberately not invented here. When the orchestrator commits them from the
# real `--spend` run, the conformance extends to the stub's own emission.
SC_FIX="$FIX/session-configured.json"
TC_FIX="$FIX/rollout-turn-context.json"
RUN_DIR="$(LC_ALL=C grep '^MCP-PROBE RESULT:' "$OUT" | LC_ALL=C sed -e 's|.*evidence: ||' | tail -n 1)"
assert_file "$RUN_DIR/probe-c/turn-context.last.json"

if [ -f "$TC_FIX" ]; then
  assert_eq "$(jq -S -c 'keys' "$TC_FIX")" \
    "$(jq -S -c 'keys' "$RUN_DIR/probe-c/turn-context.last.json")" \
    "turn_context item: stub vs the captured real one"
else
  note "PENDING fixture: $TC_FIX (a real turn_context line — costs one paid turn)"
fi
if [ -f "$SC_FIX" ]; then
  assert_json "$SC_FIX" '.. | objects | has("rollout_path")'
else
  note "PENDING fixture: $SC_FIX (a real SessionConfigured frame — costs one paid turn)"
fi

# --- the REAL turn_context, captured in the paid run of M19 -----------------
# The probe's inheritance verdict rests on reading five fields out of this item.
# Until the paid run there was no captured shape to check the reader against —
# and the very first real run proved why it matters: the probe compared its own
# unnormalized cwd against the server's normalized one and called a working
# inheritance INDETERMINABLE. These anchors tie the reader to the real bytes.
TC="$FIX/rollout-turn-context.json"
assert_file "$TC"
assert_eq "turn_context" "$(jq -r '.type' "$TC")" "the item's type tag"
for f in model effort approval_policy cwd; do
  v="$(jq -r --arg f "$f" '.payload[$f] // empty' "$TC")"
  [ -n "$v" ] || fail "the real turn_context has no payload.$f — the probe reads it"
done
assert_eq "read-only" "$(jq -r '.payload.sandbox_policy.type' "$TC")" "sandbox_policy shape"
# …and the probe's own selector must actually match this real item: the tolerant
# `type == turn_context` branch is the one the live rollout exercises.
jq -Rc 'fromjson? | objects
  | select(((.type? // "") == "turn_context")
           or ((.item_type? // "") == "turn_context")
           or (has("turn_context")))' "$TC" | grep -q . \
  || fail "the probe's turn_context selector does not match the REAL item"
