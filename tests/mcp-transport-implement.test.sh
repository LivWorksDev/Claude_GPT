#!/usr/bin/env bash
# TANDEM_TRANSPORT=mcp for the two WORKSPACE-WRITE roles — `implement` and
# `image` — the third and last Phase 2 hop.
#
# The artefact parity is the one M20a proved for `ask` and M20b for `review`,
# travelling the same shared path. What is genuinely new here is that a turn
# which can WRITE crosses the transport: the promises of M2 (sandbox
# `workspace-write`, no network, no extra writable roots, approvals `never`,
# an `approvals_reviewer` that stops a self-review from approving an escape,
# and the native `web_search` pinned OFF exactly where a turn can write) must
# arrive at the model as parameters of the tool call, byte for byte the same
# policy the argv states under exec. That is why the `config` map is compared
# as a WHOLE OBJECT and never as a list of fields: a pin LOST and a pin ADDED
# are both failures, and only an equality catches the second one.
#
# The watchdog matrix is completed here too, and it is decided by the role's
# dominant LAUNCH MODE rather than by its sandbox: `implement` runs in the
# background like `review` (3600s) while `image` keeps the foreground default
# `ask` uses (540s), below the Bash tool's ceiling, even though it writes.
#
# Nothing here spends a model turn: the stub serves both transports and counts
# them in two separate namespaces, so "not one exec turn" and "not one mcp
# server" stay countable facts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "implement {{TARGET}}"

# A file-based login is what the ephemeral CODEX_HOME copies.
mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

export CODEX_STUB_MCP_ROLLOUT=1
export CODEX_STUB_MCP_REPLY="IMPLEMENTATION_COMPLETE"
# The exec branch's thread.started, for the hybrid resume of section 2: the
# anti-fallback guard compares it against the id the mcp start persisted.
export CODEX_STUB_THREAD_ID=thr_mcp_impl
# TANDEM_MCP_TIMEOUT_SECONDS is deliberately NOT exported: the per-role defaults
# are what the watchdog assertions exist to observe.

SD="$(state_dir implement)"
ISD="$(state_dir image)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
PLAN="docs/plans/x.plan.md"

# call_frame <dest> — the first `tools/call codex` frame the wrapper issued.
call_frame() {
  jq -Rc 'fromjson? | objects
    | select((.method? // "") == "tools/call" and (.params.name? // "") == "codex")' \
    "$CODEX_STUB_LOG.mcp.in" | head -n 1 >"$1"
  [ -s "$1" ] || fail "the wrapper never issued a codex tools/call"
}

# want_config <effort> — the EXACT `config` map a workspace-write role must put
# on the wire. Everything in it comes from codex_pins() (_pins.sh) plus the
# effort, which has no first-class parameter of its own. The two ARGV-only pins
# (--ignore-user-config, --ignore-rules) have no key to carry and are realised
# by the ephemeral CODEX_HOME; `--cd` becomes the call's `cwd`.
want_config() {
  jq -nc --arg e "$1" '{
    "sandbox_mode": "workspace-write",
    "sandbox_workspace_write.network_access": false,
    "sandbox_workspace_write.writable_roots": [],
    "approval_policy": "never",
    "approvals_reviewer": "user",
    "web_search": "disabled",
    "model_reasoning_effort": $e
  }'
}

# assert_pins <call-frame> <effort> — the whole-object comparison. A missing pin
# fails, and so does an extra one: the second is the case a per-field checklist
# structurally cannot see, and it is the one that would hand a writing turn more
# permission than the role promises.
assert_pins() {
  local f="$1" want got
  want="$(want_config "$2" | jq -S -c .)"
  got="$(jq -S -c '.params.arguments.config' "$f")"
  assert_eq "$want" "$got" "the tool call's config map, compared as a whole object"
}

# =============================================================================
# 1. the implement start over mcp — full artefact parity, with the WRITE pins
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_THREAD_ID=thr_mcp_impl \
  bash "$SCRIPTS/codex-start.sh" implement "$PLAN" "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of an implement turn"

KEY="$(tkey "$PLAN")"
assert_eq "thr_mcp_impl" "$(cat "$SD/$KEY.thread")" "the thread id the MCP result echoed"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "turn counter"
assert_file "$SD/$KEY.t1.prompt.txt"
assert_file "$SD/$KEY.t1.events.ndjson"
assert_file "$SD/$KEY.t1.events.ndjson.stderr"
assert_file "$SD/$KEY.t1.meta.json"
assert_file "$SD/$KEY.t1.usage.json"
assert_file_contains "$SD/$KEY.t1.reply.txt" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$SD/$KEY.last.txt" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$SD/$KEY.t1.prompt.txt" "implement docs/plans/x.plan.md"

# Not one `codex exec` was launched for this turn.
assert_no_file "$CODEX_STUB_LOG.n"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "tools/call count"

# The events file is the EXEC serialization, and the id the wrapper persisted is
# the one the STREAM announced — the two agree, which is what the start checks.
EV="$SD/$KEY.t1.events.ndjson"
assert_eq "$(cat "$SD/$KEY.thread")" \
  "$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EV")" \
  "the persisted thread id vs the one the stream announced"
assert_not_contains "$EV" "item_type"

# The ledger: the four public fields, the `USAGE:` line, and no total_tokens.
assert_json "$SD/$KEY.t1.usage.json" \
  '. == {"input_tokens":1234,"cached_input_tokens":1000,"output_tokens":56,"reasoning_output_tokens":7}'
assert_json "$SD/$KEY.t1.usage.json" 'has("total_tokens") | not'
assert_file_contains "$ERR" 'USAGE: '
assert_eq "1" "$(grep -c '^USAGE: ' "$ERR" | tr -d ' ')" "USAGE footer lines"

# The same narration the exec path produces, plus the transport's own line —
# with the IMPLEMENT watchdog default, not the foreground one.
assert_file_contains "$OUT" "» thread thr_mcp_impl"
assert_file_contains "$OUT" "» turn done — tokens in 1234 · out 56"
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, turn 1) ---"
assert_file_contains "$OUT" "THREAD_ID: thr_mcp_impl"
assert_file_contains "$ERR" "transport=mcp"
assert_file_contains "$ERR" "watchdog 3600s"
assert_not_contains "$ERR" "watchdog 540s"

# --- the call carried the WRITE parameters, and exactly them -----------------
CALL="$SANDBOX/call.json"
call_frame "$CALL"
assert_json "$CALL" '.params.arguments.model == "gpt-5.6-sol"'
assert_json "$CALL" '.params.arguments.sandbox == "workspace-write"'
assert_json "$CALL" '.params.arguments["approval-policy"] == "never"'
assert_json "$CALL" '.params.arguments.cwd | startswith("/")'
assert_json "$CALL" '.params.arguments.prompt | contains("implement docs/plans/x.plan.md")'
assert_pins "$CALL" high

# --- the rollout is relocated into the user's real store ---------------------
ROLLOUT="$HOME/.codex/sessions/2026/08/02/rollout-2026-08-02T00-00-00-thr_mcp_impl.jsonl"
assert_file "$ROLLOUT"
LC_ALL=C tail -n 1 "$ROLLOUT" | jq -e '.type == "turn_context"' >/dev/null \
  || fail "the relocated rollout does not end in a turn_context line"

# --- the meta and the heartbeat ----------------------------------------------
assert_json "$SD/$KEY.t1.meta.json" \
  '.role == "implement" and .model == "gpt-5.6-sol" and .effort == "high" and .sandbox == "workspace-write"'
assert_json "$SD/$KEY.t1.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "mcp"'
assert_json "$HB" '.status == "done" and .role == "implement" and .turn == 1'
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'

# =============================================================================
# 2. the continuation: the HYBRID `codex exec resume`, honestly recorded
# =============================================================================
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-resume.sh" implement "$PLAN" "$SANDBOX/p.tpl"
assert_rc 0 "hybrid resume of the implement thread"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn counter after the resume"
# It really went through `codex exec resume` — invocation 1 of the exec
# namespace, which the mcp start left untouched. The policy block travels as
# argv there, with the write pins in the same order and the same values.
assert_eq "1" "$(cat "$CODEX_STUB_LOG.n")" "exec invocations after the hybrid resume"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}workspace-write${US}-c${US}model_reasoning_effort=high${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=workspace-write${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--output-last-message${US}${SD}/${KEY}.t2.reply.txt${US}resume${US}thr_mcp_impl${US}-"
# The audit trail never says a bare "mcp" for something exec resumed.
assert_json "$SD/$KEY.t2.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "exec-resume"'
assert_file_contains "$ERR" "the continuation is the hybrid exec-resume"
# The anti-fallback guard is green: same thread, and no second server.
assert_eq "thr_mcp_impl" "$(cat "$SD/$KEY.thread")" "thread id after the resume"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "no second mcp server for a continuation"

# =============================================================================
# 3. the effort precedence, now over mcp
# =============================================================================
# TANDEM_CRITICAL=1 raises the role's effort to xhigh — in the FRAME, which is
# the only place the model can read it under this transport.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp TANDEM_CRITICAL=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_impl_crit \
  bash "$SCRIPTS/codex-start.sh" implement docs/plans/crit.plan.md "$SANDBOX/p.tpl"
assert_rc 0 "mcp start under TANDEM_CRITICAL"
CRIT_CALL="$SANDBOX/crit-call.json"
call_frame "$CRIT_CALL"
assert_pins "$CRIT_CALL" xhigh
assert_json "$SD/$(tkey docs/plans/crit.plan.md).t1.meta.json" '.effort == "xhigh"'

# …and TANDEM_IMPLEMENT_EFFORT beats CRITICAL — the documented precedence,
# unchanged by the transport.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp TANDEM_CRITICAL=1 TANDEM_IMPLEMENT_EFFORT=low \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_impl_low \
  bash "$SCRIPTS/codex-start.sh" implement docs/plans/low.plan.md "$SANDBOX/p.tpl"
assert_rc 0 "mcp start with an explicit effort over CRITICAL"
LOW_CALL="$SANDBOX/low-call.json"
call_frame "$LOW_CALL"
assert_pins "$LOW_CALL" low
assert_json "$SD/$(tkey docs/plans/low.plan.md).t1.meta.json" '.effort == "low"'

# =============================================================================
# 4. the working root pin, and the watchdog override, in one turn
# =============================================================================
# TANDEM_CODEX_CWD is what puts an implement turn inside the worktree. Under mcp
# it becomes the call's `cwd` parameter and must arrive ABSOLUTE (the server
# resolves a relative one against ITS own directory), spaces included, as one
# value and not a split token. The launch runs from a THIRD directory so that
# cannot be an accident of the working directory. The explicit watchdog rides
# along: an override beats the role default here exactly as it does for ask and
# review.
WORK="$SANDBOX/work root"
ELSEWHERE="$SANDBOX/elsewhere"
mkdir -p "$WORK" "$ELSEWHERE"
rm -f "$CODEX_STUB_LOG".*
run_in "$ELSEWHERE" env TANDEM_TRANSPORT=mcp TANDEM_CODEX_CWD="$WORK" \
  TANDEM_MCP_TIMEOUT_SECONDS=11 CODEX_STUB_MCP_THREAD_ID=thr_mcp_impl_cwd \
  bash "$SCRIPTS/codex-start.sh" implement docs/plans/cwd.plan.md "$SANDBOX/p.tpl"
assert_rc 0 "mcp start with a pinned working root"
CWD_CALL="$SANDBOX/cwd-call.json"
call_frame "$CWD_CALL"
assert_eq "$WORK" "$(jq -r '.params.arguments.cwd' "$CWD_CALL")" \
  "the cwd the call frame carried"
assert_json "$CWD_CALL" '.params.arguments.cwd | startswith("/")'
# `--cd` is an ARGV pin with no config key: it becomes `cwd` and must NOT leak
# into the policy map as a spurious entry.
assert_pins "$CWD_CALL" high
assert_file_contains "$ERR" "watchdog 11s"
assert_not_contains "$ERR" "watchdog 3600s"
# The state still landed under CLAUDE_PROJECT_DIR, never in the shell's own
# directory: the cwd pin moves the TURN, not the thread state.
assert_file "$SD/$(tkey docs/plans/cwd.plan.md).thread"
assert_no_file "$ELSEWHERE/.tandem"

# =============================================================================
# 5. `image`: the same write pins, the FOREGROUND watchdog
# =============================================================================
# The decisive assertion of the matrix decision: image writes to the workspace
# and still keeps 540s, because its contract is a foreground turn for 1–3 assets
# and the watchdog has to classify a hang BEFORE the Bash tool's cap kills the
# wrapper. Giving every workspace-write role the wide default would make a hung
# one-asset turn wait an hour.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_THREAD_ID=thr_mcp_image \
  CODEX_STUB_MCP_REPLY="IMAGE_READY: assets/sprite-hero.png" \
  bash "$SCRIPTS/codex-start.sh" image sprite-hero "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of an image turn"

IKEY="$(tkey sprite-hero)"
assert_eq "thr_mcp_image" "$(cat "$ISD/$IKEY.thread")" "the image thread id"
assert_file "$ISD/$IKEY.t1.events.ndjson"
assert_file "$ISD/$IKEY.t1.usage.json"
assert_file_contains "$ISD/$IKEY.t1.reply.txt" "IMAGE_READY: assets/sprite-hero.png"
assert_no_file "$CODEX_STUB_LOG.n"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "tools/call count for the image turn"
assert_file_contains "$ERR" 'USAGE: '
assert_file_contains "$ERR" "transport=mcp"
assert_file_contains "$ERR" "watchdog 540s"
assert_not_contains "$ERR" "watchdog 3600s"

IMG_CALL="$SANDBOX/image-call.json"
call_frame "$IMG_CALL"
assert_json "$IMG_CALL" '.params.arguments.model == "gpt-5.6-sol"'
assert_json "$IMG_CALL" '.params.arguments.sandbox == "workspace-write"'
assert_json "$IMG_CALL" '.params.arguments["approval-policy"] == "never"'
assert_json "$IMG_CALL" '.params.arguments.cwd | startswith("/")'
assert_pins "$IMG_CALL" high

assert_file "$HOME/.codex/sessions/2026/08/02/rollout-2026-08-02T00-00-00-thr_mcp_image.jsonl"
assert_json "$ISD/$IKEY.t1.meta.json" \
  '.role == "image" and .effort == "high" and .sandbox == "workspace-write"'
assert_json "$ISD/$IKEY.t1.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "mcp"'
assert_json "$HB" '.status == "done" and .role == "image" and .turn == 1'

# …and the override wins for image too: the documented way to run a large set in
# the background is to raise the number explicitly, and the narration shows the
# value that was really armed.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=13 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_image_wd \
  bash "$SCRIPTS/codex-start.sh" image sprite-villain "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of an image turn with an explicit watchdog"
assert_file_contains "$ERR" "watchdog 13s"
assert_not_contains "$ERR" "watchdog 540s"

# =============================================================================
# 6. the ROLE gate: an unknown role is 64 from BOTH wrappers
# =============================================================================
# The role case is CLOSED, not a negation, so this is the negative coverage the
# gate keeps now that all four known roles pass — the exact shape the flipped
# cases of tests/mcp-transport-ask.test.sh (implement) and
# tests/mcp-transport-review.test.sh (image) used to carry: 64, nothing
# launched, and no turn consumed.
seed_thread bogus scoped thr_scoped 2
for S in codex-start.sh codex-resume.sh; do
  rm -f "$CODEX_STUB_LOG".*
  run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/$S" bogus scoped "$SANDBOX/p.tpl"
  assert_rc 64 "$S with an unknown role"
  assert_file_contains "$ERR" "supports roles ask, review, implement and image"
  assert_file_contains "$ERR" "got: 'bogus'"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
done
assert_eq "2" "$(cat "$(state_dir bogus)/$(tkey scoped).turn")" \
  "the seeded turn counter after the refusals"

note "mcp transport, workspace-write roles: implement and image parity, the M2 pins on the call frame, effort precedence, the watchdog matrix and the role gate"
