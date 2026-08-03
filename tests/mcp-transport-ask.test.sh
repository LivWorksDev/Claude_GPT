#!/usr/bin/env bash
# TANDEM_TRANSPORT=mcp — the behavioural contract of the first Phase 2 hop.
#
# The promise is ARTEFACT PARITY: with the opt-in, `codex-start.sh ask` produces
# the same per-turn files as `codex exec`, the same `USAGE:` line, the same
# heartbeat, the same exit codes and the same guards — because everything after
# the turn is literally the same code. The default is untouched, byte for byte,
# and every fail-closed answer is 64 from BOTH wrappers.
#
# Nothing here spends a model turn: the stub serves both transports and counts
# them in two separate namespaces, so "not one exec turn" and "not one mcp
# server" are countable facts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "ask about {{TARGET}}"

# A file-based login is what the ephemeral CODEX_HOME copies.
mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"

export CODEX_STUB_MCP_ROLLOUT=1
export CODEX_STUB_MCP_THREAD_ID=thr_mcp_ask
export CODEX_STUB_THREAD_ID=thr_mcp_ask
export CODEX_STUB_MCP_REPLY="Bottom line: the transport is opt-in."
export TANDEM_MCP_TIMEOUT_SECONDS=20

SD="$(state_dir ask)"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
ROLLOUT_REL="sessions/2026/08/02/rollout-2026-08-02T00-00-00-thr_mcp_ask.jsonl"

homes_left() { find "$TMPDIR" -maxdepth 1 -name 'tandem-mcp-turn.*' 2>/dev/null | head -n 1; }
recovery_dirs() { find "$TMPDIR" -maxdepth 1 -name 'tandem-rollout-recovery.*' 2>/dev/null | LC_ALL=C sort; }

mode_of() {
  # mode_of <path> — the octal permission bits, BSD flavour then GNU.
  local m
  m="$(stat -f %Lp "$1" 2>/dev/null)"
  case "$m" in '' | *[!0-7]*) m="$(stat -c %a "$1" 2>/dev/null)" ;; esac
  printf '%s' "$m"
}

# The frozen exec argv of an `ask` turn — the same anchor
# start-argv-exact-order.test.sh carries, reused here so "the default did not
# move" is an equality and not a vibe.
ask_argv() {
  printf '%s' "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}${1}${US}-"
}

# =============================================================================
# 1. the happy start over mcp — full artefact parity
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-start.sh" ask demo "$SANDBOX/p.tpl"
assert_rc 0 "mcp start"

KEY="$(tkey demo)"
assert_eq "thr_mcp_ask" "$(cat "$SD/$KEY.thread")" "the thread id the MCP result echoed"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "turn counter"
assert_file "$SD/$KEY.t1.prompt.txt"
assert_file "$SD/$KEY.t1.events.ndjson"
assert_file "$SD/$KEY.t1.events.ndjson.stderr"
assert_file "$SD/$KEY.t1.meta.json"
assert_file_contains "$SD/$KEY.t1.reply.txt" "Bottom line: the transport is opt-in."
assert_file_contains "$SD/$KEY.last.txt" "Bottom line: the transport is opt-in."
# The prompt really crossed as the rendered template, trailing bytes included.
assert_file_contains "$SD/$KEY.t1.prompt.txt" "ask about demo"

# NOT ONE `codex exec` was launched for this turn — the two stub namespaces are
# the meter.
assert_no_file "$CODEX_STUB_LOG.n"
assert_file "$CODEX_STUB_LOG.mcp.in"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "tools/call count"

# --- the events file is the EXEC serialization, not an unwrapped MCP stream --
EV="$SD/$KEY.t1.events.ndjson"
assert_eq "thr_mcp_ask" \
  "$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EV")" \
  "the shared thread.started selector over the mcp events file"
# The discriminator is `item.type`, and the stale name never appears.
assert_not_contains "$EV" "item_type"
assert_eq "command_execution" \
  "$(jq -rs '[.[] | select(.type == "item.started") | .item.type][0] // empty' "$EV")" \
  "the first started item's class"
assert_eq "agent_message" \
  "$(jq -rs '[.[] | select(.type == "item.completed") | .item.type] | last' "$EV")" \
  "the last completed item's class"
# A UserMessage produces NO exec item: `codex exec` emits none either.
assert_not_contains "$EV" "user_message"
# The frames that are not part of the exec serialization went to the sideline…
RAW="$EV.mcp.raw.ndjson"
assert_file "$RAW"
assert_file_contains "$RAW" "mcp_startup_update"
assert_file_contains "$RAW" "user_message"
assert_file_contains "$RAW" "agent_message_content_delta"
# …and never into the events file.
assert_not_contains "$EV" "mcp_startup_update"
assert_not_contains "$EV" "task_started"

# --- the ledger: the FOUR public fields, and never total_tokens --------------
assert_file "$SD/$KEY.t1.usage.json"
assert_json "$SD/$KEY.t1.usage.json" \
  '. == {"input_tokens":1234,"cached_input_tokens":1000,"output_tokens":56,"reasoning_output_tokens":7}'
assert_json "$SD/$KEY.t1.usage.json" 'has("total_tokens") | not'
assert_file_contains "$ERR" 'USAGE: '
assert_not_contains "$ERR" 'total_tokens'
assert_eq "1" "$(grep -c '^USAGE: ' "$ERR" | tr -d ' ')" "USAGE footer lines"

# --- the same narration the exec path produces -------------------------------
assert_file_contains "$OUT" "» thread thr_mcp_ask"
assert_file_contains "$OUT" "» exec echo hello world"
assert_file_contains "$OUT" "  ✓ ok"
assert_file_contains "$OUT" "» turn done — tokens in 1234 · out 56"
assert_file_contains "$OUT" "--- codex reply (gpt-5.6-sol, turn 1) ---"
assert_file_contains "$OUT" "THREAD_ID: thr_mcp_ask"
assert_file_contains "$ERR" "transport=mcp"

# --- the call carried the pins, the model and the effort as PARAMETERS -------
CALL="$SANDBOX/call.json"
jq -Rc 'fromjson? | objects
  | select((.method? // "") == "tools/call" and (.params.name? // "") == "codex")' \
  "$CODEX_STUB_LOG.mcp.in" | head -n 1 >"$CALL"
[ -s "$CALL" ] || fail "the wrapper never issued a codex tools/call"
assert_json "$CALL" '.params.arguments.model == "gpt-5.6-sol"'
assert_json "$CALL" '.params.arguments.sandbox == "read-only"'
assert_json "$CALL" '.params.arguments["approval-policy"] == "never"'
assert_json "$CALL" '.params.arguments.cwd | startswith("/")'
assert_json "$CALL" '.params.arguments.config["model_reasoning_effort"] == "xhigh"'
assert_json "$CALL" '.params.arguments.config["sandbox_mode"] == "read-only"'
assert_json "$CALL" '.params.arguments.config["approval_policy"] == "never"'
assert_json "$CALL" '.params.arguments.config["approvals_reviewer"] == "user"'
assert_json "$CALL" '.params.arguments.config["sandbox_workspace_write.network_access"] == false'
assert_json "$CALL" '.params.arguments.config["sandbox_workspace_write.writable_roots"] == []'
assert_json "$CALL" '.params.arguments.prompt | contains("ask about demo")'

# --- the ephemeral home: pins ONLY, and the credential never survives --------
assert_file "$CODEX_STUB_LOG.mcp.cfg.1"
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.1" 'sandbox_mode = "read-only"'
assert_file_contains "$CODEX_STUB_LOG.mcp.cfg.1" 'approval_policy = "never"'
# The model and the effort are NOT in the TOML: they travel as JSON parameters,
# where an override full of quotes cannot break out of anything.
assert_not_contains "$CODEX_STUB_LOG.mcp.cfg.1" "model ="
assert_not_contains "$CODEX_STUB_LOG.mcp.cfg.1" "model_reasoning_effort"
assert_eq "present" "$(cat "$CODEX_STUB_LOG.mcp.auth.1")" "auth.json during the call"
assert_eq "" "$(homes_left)" "ephemeral CODEX_HOME after the turn"
assert_eq "" "$(LC_ALL=C grep -rl 'fake-for-tests' "$CLAUDE_PROJECT_DIR/.tandem" 2>/dev/null | head -n 1)" \
  "the token's content inside .tandem"

# --- the rollout is relocated into the user's real store ---------------------
assert_file "$HOME/.codex/$ROLLOUT_REL"
LC_ALL=C tail -n 1 "$HOME/.codex/$ROLLOUT_REL" | jq -e '.type == "turn_context"' >/dev/null \
  || fail "the relocated rollout does not end in a turn_context line"
assert_eq "600" "$(mode_of "$HOME/.codex/$ROLLOUT_REL")" "relocated rollout mode"
assert_eq "" "$(recovery_dirs)" "no recovery directory on the happy path"

# --- the opt-in meta fields ---------------------------------------------------
assert_json "$SD/$KEY.t1.meta.json" \
  '.role == "ask" and .model == "gpt-5.6-sol" and .effort == "xhigh" and .sandbox == "read-only"'
assert_json "$SD/$KEY.t1.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "mcp"'

# --- the heartbeat closed clean ----------------------------------------------
assert_json "$HB" '.status == "done" and .role == "ask" and .turn == 1'
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'

# =============================================================================
# 2. the continuation: the HYBRID `codex exec resume`, honestly recorded
# =============================================================================
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-resume.sh" ask demo "$SANDBOX/p.tpl"
assert_rc 0 "hybrid resume"
assert_eq "2" "$(cat "$SD/$KEY.turn")" "turn counter after the resume"
# It really went through `codex exec resume` — invocation 1 of the exec
# namespace, which the mcp start left untouched.
assert_eq "1" "$(cat "$CODEX_STUB_LOG.n")" "exec invocations after the hybrid resume"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}--output-last-message${US}${SD}/${KEY}.t2.reply.txt${US}resume${US}thr_mcp_ask${US}-"
# The audit trail never says a bare "mcp" for something exec resumed.
assert_json "$SD/$KEY.t2.meta.json" \
  '.transport_requested == "mcp" and .transport_effective == "exec-resume"'
assert_file_contains "$ERR" "the continuation is the hybrid exec-resume"
# The anti-fallback guard is green: same thread, no second server.
assert_eq "thr_mcp_ask" "$(cat "$SD/$KEY.thread")" "thread id after the resume"
assert_eq "1" "$(cat "$CODEX_STUB_LOG.mcp.calls")" "no second mcp server for a continuation"

# =============================================================================
# 3. the default is untouched, and the opt-in `exec` is the same command line
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
run bash "$SCRIPTS/codex-start.sh" ask plain "$SANDBOX/p.tpl"
assert_rc 0 "default exec start"
PKEY="$(tkey plain)"
assert_argv 1 "$(ask_argv "$SD/$PKEY.t1.reply.txt")"
# The legacy meta.json object is EXACTLY four keys when nobody opted in.
assert_json "$SD/$PKEY.t1.meta.json" '(keys | sort) == ["effort","model","role","sandbox"]'
# Not one mcp server was launched for an exec turn.
assert_no_file "$CODEX_STUB_LOG.mcp.in"
assert_no_file "$CODEX_STUB_LOG.mcp.calls"

run env TANDEM_TRANSPORT=exec bash "$SCRIPTS/codex-start.sh" ask optin "$SANDBOX/p.tpl"
assert_rc 0 "opt-in exec start"
OKEY="$(tkey optin)"
assert_argv 2 "$(ask_argv "$SD/$OKEY.t1.reply.txt")"
assert_no_file "$CODEX_STUB_LOG.mcp.in"
# …and the two argvs differ ONLY in the per-turn reply path.
A="$(LC_ALL=C sed -e "s|$SD/$PKEY|@KEY@|g" "$CODEX_STUB_LOG.argv.1")"
B="$(LC_ALL=C sed -e "s|$SD/$OKEY|@KEY@|g" "$CODEX_STUB_LOG.argv.2")"
assert_eq "$A" "$B" "opt-in exec argv vs the argv of a run without the variable"
assert_json "$SD/$OKEY.t1.meta.json" \
  '.transport_requested == "exec" and .transport_effective == "exec"'

# =============================================================================
# 4. fail-closed: 64 from BOTH wrappers, nothing launched, no turn consumed
# =============================================================================
seed_thread ask seeded thr_seeded 4

closed() {
  # closed <script> <target> <expected-message> <env…>
  local script="$1" target="$2" needle="$3"
  shift 3
  rm -f "$CODEX_STUB_LOG".*
  run env "$@" bash "$SCRIPTS/$script" ask "$target" "$SANDBOX/p.tpl"
  assert_rc 64 "$script $* "
  assert_file_contains "$ERR" "$needle"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
}

for S in codex-start.sh codex-resume.sh; do
  closed "$S" seeded "TANDEM_TRANSPORT is not a valid transport: 'bogus'" TANDEM_TRANSPORT=bogus
  closed "$S" seeded "TANDEM_TRANSPORT is not a valid transport: ''" TANDEM_TRANSPORT=
  closed "$S" seeded "must be a positive integer of seconds" \
    TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=abc
  closed "$S" seeded "must be a positive integer of seconds" \
    TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=0
done
# The turn counter of the seeded thread never moved: the validator runs before
# any state mutation.
assert_eq "4" "$(cat "$SD/$(tkey seeded).turn")" "turn counter after eight refusals"

# `mcp` on a role this hop does NOT serve is refused by BOTH wrappers, naming
# the pending one. `review` joined `ask` in M20b, so the role asserted here is
# `implement` — the other still-excluded role, `image`, carries the same assert
# in tests/mcp-transport-review.test.sh.
seed_thread implement scoped thr_scoped 2
for S in codex-start.sh codex-resume.sh; do
  rm -f "$CODEX_STUB_LOG".*
  run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/$S" implement scoped "$SANDBOX/p.tpl"
  assert_rc 64 "$S with role implement"
  assert_file_contains "$ERR" "supports roles ask and review in this hop"
  assert_file_contains "$ERR" "M20c"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.mcp.in"
done
assert_eq "2" "$(cat "$(state_dir implement)/$(tkey scoped).turn")" \
  "implement turn counter untouched"

# =============================================================================
# 5. the watchdog: a hung turn exits 1, the group dies, the ledger survives
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
RES_PIDFILE="$SANDBOX/resistant.pid"
run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=2 \
  CODEX_STUB_MCP_SCENARIO=hang-call CODEX_STUB_MCP_HANG_AFTER_EVENTS=1 \
  CODEX_STUB_MCP_HANG_RESISTANT=1 CODEX_STUB_HANG_PIDFILE="$RES_PIDFILE" \
  CODEX_STUB_HANG_SECONDS=120 \
  bash "$SCRIPTS/codex-start.sh" ask hung "$SANDBOX/p.tpl"
assert_rc 1 "a hung mcp turn"
assert_file_contains "$ERR" "watchdog expired"
assert_file_contains "$ERR" "no answer within 2s"
HKEY="$(tkey hung)"
# The turn's artefacts are PRESERVED, the usage above all: the quota is spent
# whether or not the client ever saw an answer.
assert_file "$SD/$HKEY.t1.prompt.txt"
assert_file "$SD/$HKEY.t1.events.ndjson"
assert_file "$SD/$HKEY.t1.meta.json"
assert_file "$SD/$HKEY.t1.usage.json"
assert_json "$SD/$HKEY.t1.usage.json" \
  '. == {"input_tokens":1234,"cached_input_tokens":1000,"output_tokens":56,"reasoning_output_tokens":7}'
assert_file_contains "$ERR" 'USAGE: '
# No thread file: a turn that never answered is not a thread to continue.
assert_no_file "$SD/$HKEY.thread"
assert_json "$HB" '.status == "failed"'
assert_eq "" "$(homes_left)" "ephemeral home after a watchdog expiry"

# The TERM-resistant child only dies if the whole GROUP was reaped.
assert_file "$RES_PIDFILE"
RES_PID="$(cat "$RES_PIDFILE" 2>/dev/null)"
case "$RES_PID" in '' | *[!0-9]*) fail "the stub recorded no resistant child pid" ;; esac
i=0
while [ "$i" -lt 6 ] && kill -0 "$RES_PID" 2>/dev/null; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$RES_PID" 2>/dev/null; then
  kill -KILL "$RES_PID" 2>/dev/null || true
  fail "the TERM-resistant server child (pid $RES_PID) survived the watchdog"
fi

# =============================================================================
# 6. a failing turn: exit 1, heartbeat failed, nothing left behind
# =============================================================================
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp CODEX_STUB_MCP_SCENARIO=auth-error \
  bash "$SCRIPTS/codex-start.sh" ask rejected "$SANDBOX/p.tpl"
assert_rc 1 "an errored mcp tool call"
assert_file_contains "$ERR" "isError"
assert_file_contains "$ERR" "401 Unauthorized"
assert_no_file "$SD/$(tkey rejected).thread"
assert_json "$HB" '.status == "failed"'
assert_eq "" "$(homes_left)" "ephemeral home after a failed turn"

# =============================================================================
# 7. the rollout relocation refuses to overwrite, and the credential still dies
# =============================================================================
# The destination of thr_mcp_ask is already occupied by phase 1's rollout, so a
# fresh start for the same thread id hits the no-overwrite guard — the exact
# path P1-3/P1-4 describe, without touching a single permission bit.
BEFORE="$SANDBOX/rollout.before"
cp "$HOME/.codex/$ROLLOUT_REL" "$BEFORE"
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-start.sh" ask blocked "$SANDBOX/p.tpl"
assert_rc 1 "a relocation that cannot land"
assert_file_contains "$ERR" "refusing to overwrite an existing rollout"
assert_file_contains "$ERR" "recovered at"
# The existing rollout was NOT touched.
cmp -s "$BEFORE" "$HOME/.codex/$ROLLOUT_REL" \
  || fail "the pre-existing rollout in the user's store was modified"
# The rollout is recoverable, in a 700 directory with the file at 600…
REC_DIR="$(recovery_dirs | tail -n 1)"
[ -n "$REC_DIR" ] || fail "no recovery directory was created"
assert_eq "700" "$(mode_of "$REC_DIR")" "recovery directory mode"
REC_FILE="$(find "$REC_DIR" -type f -name '*.jsonl' | head -n 1)"
[ -n "$REC_FILE" ] || fail "the recovery directory holds no rollout"
assert_eq "600" "$(mode_of "$REC_FILE")" "recovered rollout mode"
# …and the CREDENTIAL is gone from the disk, on this path too.
assert_eq "" "$(homes_left)" "ephemeral home after a failed relocation"
assert_eq "" "$(LC_ALL=C grep -rl 'fake-for-tests' "$REC_DIR" 2>/dev/null | head -n 1)" \
  "the token inside the recovery directory"
assert_eq "" "$(find "$TMPDIR" -name 'auth.json' 2>/dev/null | head -n 1)" \
  "an auth.json anywhere under TMPDIR"
assert_no_file "$SD/$(tkey blocked).thread"
assert_json "$HB" '.status == "failed"'

# =============================================================================
# 8. no file-based login: exit 3 with the command that fixes it, before anything
# =============================================================================
# A machine whose token lives only in the keyring has nothing to copy, and its
# keyring entry is keyed by the home — so the mcp transport says so instead of
# starting a server that could only fail.
mv "$HOME/.codex/auth.json" "$SANDBOX/auth.json.parked"
rm -f "$CODEX_STUB_LOG".*
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-start.sh" ask keyring "$SANDBOX/p.tpl"
assert_rc 3 "no auth.json to copy"
assert_file_contains "$ERR" "no auth.json in"
assert_file_contains "$ERR" "codex login"
assert_no_file "$CODEX_STUB_LOG.mcp.in"
assert_no_file "$CODEX_STUB_LOG.n"
assert_json "$HB" '.status == "failed"'
assert_eq "" "$(homes_left)" "ephemeral home after a missing credential"
mv "$SANDBOX/auth.json.parked" "$HOME/.codex/auth.json"

# =============================================================================
# 9. the five exits: INT and TERM close the same lifecycle
# =============================================================================
signal_case() {
  # signal_case <signal> <target> <expected-rc>
  # The `local` arguments are expanded BEFORE the builtin assigns any of them
  # (bash 3.2), so `pidfile` gets its own statement.
  local sig="$1" target="$2" want="$3" pid rc=0 i child
  local pidfile="$SANDBOX/sig-$sig.pid"
  rm -f "$CODEX_STUB_LOG".*
  # Job control ON only around the fork (the runner's own trick): without it a
  # background command inherits SIGINT as IGNORED, and a signal ignored on entry
  # cannot be trapped — the INT case would prove nothing while looking green.
  # With it the wrapper leads its own process group and receives both signals
  # exactly as a terminal or a skill would deliver them.
  set -m
  env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=60 \
    CODEX_STUB_MCP_SCENARIO=hang-call CODEX_STUB_MCP_HANG_RESISTANT=1 \
    CODEX_STUB_HANG_PIDFILE="$pidfile" CODEX_STUB_HANG_SECONDS=120 \
    bash "$SCRIPTS/codex-start.sh" ask "$target" "$SANDBOX/p.tpl" \
    >"$OUT" 2>"$ERR" &
  pid=$!
  set +m
  # Wait for the turn to be genuinely in flight, by ORDER and not by clock.
  wait_for_json "$HB" '.status == "running"' 200 \
    || { kill -KILL "$pid" 2>/dev/null; fail "the $sig case never reached a running turn"; }
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$pidfile" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -"$sig" "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || rc=$?
  assert_eq "$want" "$rc" "exit code after $sig"
  assert_json "$HB" '.status == "failed"'
  assert_eq "" "$(homes_left)" "ephemeral home after $sig"
  [ -f "$pidfile" ] || fail "the stub recorded no resistant child pid for $sig"
  child="$(cat "$pidfile" 2>/dev/null)"
  case "$child" in '' | *[!0-9]*) fail "unreadable resistant pid for $sig: '$child'" ;; esac
  i=0
  while [ "$i" -lt 6 ] && kill -0 "$child" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "the resistant child (pid $child) survived the $sig"
  fi
  assert_no_file "$SD/$(tkey "$target").thread"
}

signal_case INT sig-int 130
signal_case TERM sig-term 143

note "mcp transport: parity, hybrid resume, fail-closed 64s, watchdog and all five exits"

# --- the credential can never land inside the project's state tree ----------
# A TMPDIR pointing at .tandem/tmp is the case that turns the "never under
# .tandem/" promise into a lie — and a SIGKILL would leave the token there. The
# transport must refuse that base and fall back, so the guarantee is BEHAVIOURAL
# (grepping the source for the literal was the weak form: the code legitimately
# names the state tree in order to refuse it).
mkdir -p "$CLAUDE_PROJECT_DIR/.tandem/tmp"
run env TMPDIR="$CLAUDE_PROJECT_DIR/.tandem/tmp" TANDEM_TRANSPORT=mcp \
  CODEX_STUB_MCP_THREAD_ID=thr_mcp_tmpdir \
  bash "$SCRIPTS/codex-start.sh" ask tmpdir-inside-state "$SANDBOX/p.tpl"
assert_rc 0 "TMPDIR inside the state tree"
assert_file_contains "$ERR" "is inside the tandem state tree"
# The decisive assertion: no credential anywhere under .tandem/, during or after.
CRED_HITS="$(find "$CLAUDE_PROJECT_DIR/.tandem" -name auth.json 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$CRED_HITS" "auth.json under .tandem/"
# …and no ephemeral home was left behind there either.
HOME_HITS="$(find "$CLAUDE_PROJECT_DIR/.tandem" -type d -name 'tandem-mcp-turn.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$HOME_HITS" "ephemeral homes under .tandem/"
