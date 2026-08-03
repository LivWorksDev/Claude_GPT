#!/usr/bin/env bash
# TANDEM_TRANSPORT=mcp for the `review` role — the second Phase 2 hop.
#
# The promise is the one M20a proved for `ask`, now for a role with TWO modes
# that share one wrapper and one gate: the pipeline review (`cr-<slug>`) and the
# out-of-pipeline range review (`range-review-<label>`). Same per-turn files,
# same `USAGE:` line, same heartbeat, same exit codes, same anti-fallback guard,
# continuations through the hybrid `codex exec resume`.
#
# What is genuinely NEW here is the watchdog PER ROLE: 540 s is tied to the Bash
# tool's foreground ceiling and sized for `ask`, while an xhigh review runs in
# the background precisely because it exceeds ten minutes — so `review` gets its
# own wide default, without the watchdog ever becoming optional.
#
# Nothing here spends a model turn: the stub serves both transports and counts
# them in two separate namespaces, so "not one exec turn" and "not one mcp
# server" stay countable facts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "review {{TARGET}}"

# A file-based login is what the ephemeral CODEX_HOME copies.
mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

export CODEX_STUB_MCP_ROLLOUT=1
export CODEX_STUB_MCP_REPLY="VERDICT: APPROVED"
# The exec branch's thread.started, for the hybrid resume of section 2: the
# anti-fallback guard compares it against the id the mcp start persisted.
export CODEX_STUB_THREAD_ID=thr_mcp_review
# TANDEM_MCP_TIMEOUT_SECONDS is deliberately NOT exported: the per-role defaults
# are what this case exists to observe.

SD="$(state_dir review)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

# call_frame <dest> — the first `tools/call codex` frame the wrapper issued.
call_frame() {
  jq -Rc 'fromjson? | objects
    | select((.method? // "") == "tools/call" and (.params.name? // "") == "codex")' \
    "$CODEX_STUB_LOG.mcp.in" | head -n 1 >"$1"
  [ -s "$1" ] || fail "the wrapper never issued a codex tools/call"
}

# =============================================================================
# 1. the pipeline start over mcp — artefact parity, with the ROLE's parameters
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_THREAD_ID=thr_mcp_review \
  bash "$SCRIPTS/codex-start.sh" review cr-demo "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of a pipeline review"

KEY="$(tkey cr-demo)"
assert_eq "thr_mcp_review" "$(cat "$SD/$KEY.thread")" "the thread id the MCP result echoed"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "turn counter"
assert_file "$SD/$KEY.t1.prompt.txt"
assert_file "$SD/$KEY.t1.events.ndjson"
assert_file "$SD/$KEY.t1.events.ndjson.stderr"
assert_file "$SD/$KEY.t1.meta.json"
assert_file "$SD/$KEY.t1.usage.json"
assert_file_contains "$SD/$KEY.t1.reply.txt" "VERDICT: APPROVED"
assert_file_contains "$SD/$KEY.last.txt" "VERDICT: APPROVED"
assert_file_contains "$SD/$KEY.t1.prompt.txt" "review cr-demo"

# Not one `codex exec` was launched for this turn.
assert_no_file "$CODEX_STUB_LOG.n"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "tools/call count"

# The events file is the EXEC serialization, and the id the wrapper persisted is
# the one the STREAM announced — the two agree, which is what the start checks.
EV="$SD/$KEY.t1.events.ndjson"
assert_eq "thr_mcp_review" \
  "$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EV")" \
  "the shared thread.started selector over the mcp events file"
assert_not_contains "$EV" "item_type"

# The ledger: the four public fields, the `USAGE:` line, and no total_tokens.
assert_json "$SD/$KEY.t1.usage.json" \
  '. == {"input_tokens":1234,"cached_input_tokens":1000,"output_tokens":56,"reasoning_output_tokens":7}'
assert_file_contains "$ERR" 'USAGE: '
assert_eq "1" "$(grep -c '^USAGE: ' "$ERR" | tr -d ' ')" "USAGE footer lines"

# The same narration the exec path produces, plus the transport's own line —
# with the REVIEW watchdog default, not the foreground one.
assert_file_contains "$OUT" "» thread thr_mcp_review"
assert_file_contains "$OUT" "» turn done — tokens in 1234 · out 56"
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, turn 1) ---"
assert_file_contains "$OUT" "THREAD_ID: thr_mcp_review"
assert_file_contains "$ERR" "transport=mcp"
assert_file_contains "$ERR" "watchdog 3600s"

# --- the call carried the params of the ROLE, not of the transport ------------
CALL="$SANDBOX/call.json"
call_frame "$CALL"
assert_json "$CALL" '.params.arguments.model == "gpt-5.6-sol"'
assert_json "$CALL" '.params.arguments.sandbox == "read-only"'
assert_json "$CALL" '.params.arguments["approval-policy"] == "never"'
assert_json "$CALL" '.params.arguments.config["model_reasoning_effort"] == "xhigh"'
assert_json "$CALL" '.params.arguments.config["sandbox_mode"] == "read-only"'
assert_json "$CALL" '.params.arguments.config["approval_policy"] == "never"'
assert_json "$CALL" '.params.arguments.config["approvals_reviewer"] == "user"'
assert_json "$CALL" '.params.arguments.cwd | startswith("/")'
assert_json "$CALL" '.params.arguments.prompt | contains("review cr-demo")'

# --- the rollout is relocated into the user's real store ---------------------
ROLLOUT="$HOME/.codex/sessions/2026/08/02/rollout-2026-08-02T00-00-00-thr_mcp_review.jsonl"
assert_file "$ROLLOUT"
LC_ALL=C tail -n 1 "$ROLLOUT" | jq -e '.type == "turn_context"' >/dev/null \
  || fail "the relocated rollout does not end in a turn_context line"

# --- the meta and the heartbeat ----------------------------------------------
assert_json "$SD/$KEY.t1.meta.json" \
  '.role == "review" and .model == "gpt-5.6-sol" and .effort == "xhigh" and .sandbox == "read-only"'
assert_json "$SD/$KEY.t1.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "mcp"'
assert_json "$HB" '.status == "done" and .role == "review" and .turn == 1'
assert_json "$HB" '.verdict == "APPROVED"'

# =============================================================================
# 2. the continuation: the HYBRID `codex exec resume`, honestly recorded
# =============================================================================
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-resume.sh" review cr-demo "$SANDBOX/p.tpl"
assert_rc 0 "hybrid resume of the review thread"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn counter after the resume"
# It really went through `codex exec resume` — invocation 1 of the exec
# namespace, which the mcp start left untouched.
assert_eq "1" "$(cat "$CODEX_STUB_LOG.n")" "exec invocations after the hybrid resume"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}${SD}/${KEY}.t2.reply.txt${US}resume${US}thr_mcp_review${US}-"
# The audit trail never says a bare "mcp" for something exec resumed.
assert_json "$SD/$KEY.t2.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "exec-resume"'
assert_file_contains "$ERR" "the continuation is the hybrid exec-resume"
# The anti-fallback guard is green: same thread, and no second server.
assert_eq "thr_mcp_review" "$(cat "$SD/$KEY.thread")" "thread id after the resume"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "no second mcp server for a continuation"

# =============================================================================
# 3. the watchdog is PER ROLE, and the env override still wins
# =============================================================================
# ask keeps the foreground-sized default: the non-regression anchor of M20a.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_THREAD_ID=thr_mcp_ask_wd \
  bash "$SCRIPTS/codex-start.sh" ask topic "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of an ask turn"
assert_file_contains "$ERR" "watchdog 540s"
assert_not_contains "$ERR" "watchdog 3600s"

# …and an explicit override beats the role default, for review too.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=7 \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_review_wd \
  bash "$SCRIPTS/codex-start.sh" review cr-override "$SANDBOX/p.tpl"
assert_rc 0 "mcp start with an explicit watchdog"
assert_file_contains "$ERR" "watchdog 7s"
assert_not_contains "$ERR" "watchdog 3600s"

# A DEFINED-but-empty override is invalid like any other value — never "unset",
# and never a silent fall back onto the (much larger) role default. Both
# wrappers, nothing launched, no turn consumed.
#
# The target is `cr-seeded` and not a bare `seeded` on purpose: the target gate
# of section 6 would refuse the launch BEFORE the watchdog is validated at all,
# and this case exists to prove the timeout's own 64. The order between the two
# is itself asserted below.
seed_thread review cr-seeded thr_seeded 4
for S in codex-start.sh codex-resume.sh; do
  rm -f "$CODEX_STUB_LOG".*
  run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS= \
    bash "$SCRIPTS/$S" review cr-seeded "$SANDBOX/p.tpl"
  assert_rc 64 "$S with a defined-but-empty watchdog override"
  assert_file_contains "$ERR" "must be a positive integer of seconds (got: '')"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
done
assert_eq "4" "$(cat "$SD/$(tkey cr-seeded).turn")" "turn counter after the empty-override refusals"

# =============================================================================
# 4. the RANGE mode: the skill's pins survive the transport
# =============================================================================
# The launch of Range step 2 pins CLAUDE_PROJECT_DIR (where the thread state
# belongs) and TANDEM_CODEX_CWD (where the turn reads the code), and runs from
# neither. Three distinct directories, so "the state landed in the pinned root"
# and "the call frame carries the requested absolute cwd" cannot both be an
# accident of the working directory.
RANGE_ROOT="$SANDBOX/pinned-root"
RANGE_WORK="$SANDBOX/range work"
ELSEWHERE="$SANDBOX/elsewhere"
mkdir -p "$RANGE_ROOT" "$RANGE_WORK" "$ELSEWHERE"
rm -f "$CODEX_STUB_LOG".*
run_in "$ELSEWHERE" env CLAUDE_PROJECT_DIR="$RANGE_ROOT" TANDEM_CODEX_CWD="$RANGE_WORK" \
  TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_THREAD_ID=thr_mcp_range \
  bash "$SCRIPTS/codex-start.sh" review range-review-m20b "$SANDBOX/p.tpl"
assert_rc 0 "mcp start of a range review"

RKEY="$(tkey range-review-m20b)"
RSD="$RANGE_ROOT/.tandem/state/review"
assert_eq "thr_mcp_range" "$(cat "$RSD/$RKEY.thread")" \
  "the range thread state landed under the pinned root"
assert_file "$RSD/$RKEY.t1.usage.json"
assert_file "$RSD/$RKEY.t1.events.ndjson"
assert_json "$RSD/$RKEY.t1.meta.json" \
  '.role == "review" and .transport_requested == "mcp" and .transport_effective == "mcp"'
# …and nowhere else: not in the shell's own directory, not under the default
# project dir this case has been using so far.
assert_no_file "$ELSEWHERE/.tandem"
assert_no_file "$SD/$RKEY.thread"

# The `cwd` of the call frame is the ABSOLUTE directory that was asked for —
# spaces included, as one value and not a split token.
RCALL="$SANDBOX/range-call.json"
call_frame "$RCALL"
assert_eq "$RANGE_WORK" "$(jq -r '.params.arguments.cwd' "$RCALL")" \
  "the cwd the range call frame carried"
assert_json "$RCALL" '.params.arguments.cwd | startswith("/")'
assert_json "$RCALL" '.params.arguments.model == "gpt-5.6-sol"'
assert_json "$RCALL" '.params.arguments.sandbox == "read-only"'
assert_json "$RCALL" '.params.arguments.config["model_reasoning_effort"] == "xhigh"'

# NOTE (M20c): the `mcp + image → 64` case that used to live here is GONE
# because `image` now passes — M20c closed the role matrix with the two
# workspace-write roles. The negative coverage of the ROLE gate did not vanish
# with it: it moved, in the same shape (64 + not one invocation + the turn
# counter untouched), to the unknown-role case of
# tests/mcp-transport-implement.test.sh. What this file keeps is the axis that
# is genuinely its own — the review TARGET gate below.

# =============================================================================
# 5. the gate's THIRD axis: a review TARGET the transport does not serve
# =============================================================================
# The role gate above cannot see WHICH of review's three launch families is
# calling: `tandem:plan` reviews a plan path through the very same wrapper, and
# it legitimately keeps a foreground exception for small plans. Routed through
# mcp it would arm the 3600s review watchdog, and the Bash tool's 600s cap would
# kill the turn before the watchdog could classify anything — quota spent, no
# ledger. So a target that is neither `cr-*` nor `range-review-*` is 64 from
# BOTH wrappers, with nothing launched and no turn consumed.
seed_thread review "docs/plans/x.plan.md" thr_plan 3
for S in codex-start.sh codex-resume.sh; do
  rm -f "$CODEX_STUB_LOG".*
  run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/$S" review "docs/plans/x.plan.md" "$SANDBOX/p.tpl"
  assert_rc 64 "$S with a plan-path review target"
  assert_file_contains "$ERR" "supports review targets"
  assert_file_contains "$ERR" "plan reviews stay on exec"
  assert_file_contains "$ERR" "M21"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
done
assert_eq "3" "$(cat "$SD/$(tkey "docs/plans/x.plan.md").turn")" \
  "plan-review turn counter untouched"

# ORDER: with an unsupported target AND an invalid watchdog at once, the answer
# is the TARGET's. Which launches exist under this transport is a flow question
# and is decided before how wide the watchdog is — otherwise the caller would be
# told to fix a number for a launch that mcp never accepts.
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS= \
  bash "$SCRIPTS/codex-start.sh" review "docs/plans/x.plan.md" "$SANDBOX/p.tpl"
assert_rc 64 "an unsupported target and an empty watchdog override at once"
assert_file_contains "$ERR" "supports review targets"
assert_not_contains "$ERR" "must be a positive integer of seconds"

# …and the supported targets are untouched by the axis: `ask` keeps free-form
# topics (section 3 started `topic` over mcp) and the pipeline/range targets of
# sections 1 and 4 are the positive coverage.

note "mcp transport, review role: pipeline and range parity, hybrid resume, per-role watchdog, target gate"
