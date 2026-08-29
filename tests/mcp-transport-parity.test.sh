#!/usr/bin/env bash
# The two halves the behavioural suite cannot reach: what did NOT change, and
# whether the mcp events really pass through the SAME extractors.
#
#   static     the exec branch of both wrappers is frozen byte for byte, the
#              transport validator runs before any dependency, _mcp.sh installs
#              nothing when sourced, never signals a forked guard and never
#              exits once a turn has started, and the watchdog default is TIED
#              to the 600 s Bash-tool timeout the skills use in the foreground.
#   conformance the 14 REAL frames of tests/fixtures/mcp-0.144.4/ replayed
#              through mcp_events_adapt come out as the serialization the
#              archived REAL exec streams carry — same discriminator, same item
#              keys, same four usage fields — and turn_usage and the
#              thread.started selector work over the result WITHOUT a change.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

MCPFIX="$REPO_ROOT/tests/fixtures/mcp-0.144.4"
DRIFT="$TESTS_DIR/fixtures/ndjson/check-drift.sh"

adapt() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  # shellcheck source=../scripts/_mcp.sh
  . "$SCRIPTS/_mcp.sh"
  set +e
  mcp_events_adapt "$1" "$2" "$3"
)

usage_of() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  turn_usage "$1"
)

milestones() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  stream_milestones <"$1"
)

# =============================================================================
# 1. the exec branch keeps the reviewed job + rc-file + deadline shape
# =============================================================================
# The behavioural anchor (start-argv-exact-order.test.sh) pins the argv the stub
# receives; this pins the SOURCE that produces it, so an mcp branch that
# reordered or reindented the exec block fails here instead of surviving until a
# real turn. Indentation is normalised away on purpose: start's block lives
# inside an `if`, and its bytes are the tokens, not the leading spaces.
exec_block() {
  LC_ALL=C awk '
    /RC_FILE="\$STATE_ROOT\/tmp\/exec-/ { keep=1 }
    keep { print }
    keep && /^[[:space:]]*TURN_JOB=0$/ { exit }
  ' "$1" \
    | LC_ALL=C sed -e 's|^[[:space:]]*||'
}

# Quoted delimiter: not one byte of the frozen block is expanded here.
cat >"$SANDBOX/start-block.want" <<'START_BLOCK'
RC_FILE="$STATE_ROOT/tmp/exec-$ROLE-$KEY.t$TURN.$$.rc"
TIMEOUT_MARK="$RC_FILE.timeout"
rm -f "$RC_FILE" "$TIMEOUT_MARK"
trap 'TURN_PENDING_SIG=130' INT
trap 'TURN_PENDING_SIG=143' TERM
set -m
(
codex exec \
--json --skip-git-repo-check --color never \
--model "$CODEX_MODEL" \
--sandbox "$CODEX_SANDBOX" \
-c model_reasoning_effort="$CODEX_EFFORT" \
"${CODEX_PINS[@]}" \
--output-last-message "$MSG_FILE" \
- <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
| tee "$EVENTS_FILE" | stream_milestones
printf '%s' "${PIPESTATUS[0]}" >"$RC_FILE"
) &
TURN_JOB=$!
set +m
if kill -0 -- -"$TURN_JOB" 2>/dev/null; then TURN_GROUP=1; fi
trap 'exit 130' INT
trap 'exit 143' TERM
[ "$TURN_PENDING_SIG" -ne 0 ] && exit "$TURN_PENDING_SIG"
exec_deadline_wait "$TURN_JOB" "$TURN_GROUP" "$EXEC_TIMEOUT" "$TIMEOUT_MARK"
wait "$TURN_JOB" 2>/dev/null || true
TURN_JOB=0
START_BLOCK
exec_block "$SCRIPTS/codex-start.sh" >"$SANDBOX/start-block.got"
cmp -s "$SANDBOX/start-block.want" "$SANDBOX/start-block.got" || {
  printf -- '--- want ---\n' >&2; cat "$SANDBOX/start-block.want" >&2
  printf -- '--- got ---\n' >&2; cat "$SANDBOX/start-block.got" >&2
  fail "the exec branch of codex-start.sh changed"
}

cat >"$SANDBOX/resume-block.want" <<'RESUME_BLOCK'
RC_FILE="$STATE_ROOT/tmp/exec-$ROLE-$KEY.t$TURN.$$.rc"
TIMEOUT_MARK="$RC_FILE.timeout"
rm -f "$RC_FILE" "$TIMEOUT_MARK"
trap 'TURN_PENDING_SIG=130' INT
trap 'TURN_PENDING_SIG=143' TERM
set -m
(
codex exec \
--json --skip-git-repo-check --color never \
--model "$CODEX_MODEL" \
--sandbox "$CODEX_SANDBOX" \
-c model_reasoning_effort="$CODEX_EFFORT" \
"${CODEX_PINS[@]}" \
--output-last-message "$MSG_FILE" \
resume "$THREAD_ID" - <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
| tee "$EVENTS_FILE" | stream_milestones
printf '%s' "${PIPESTATUS[0]}" >"$RC_FILE"
) &
TURN_JOB=$!
set +m
if kill -0 -- -"$TURN_JOB" 2>/dev/null; then TURN_GROUP=1; fi
trap 'exit 130' INT
trap 'exit 143' TERM
[ "$TURN_PENDING_SIG" -ne 0 ] && exit "$TURN_PENDING_SIG"
exec_deadline_wait "$TURN_JOB" "$TURN_GROUP" "$EXEC_TIMEOUT" "$TIMEOUT_MARK"
wait "$TURN_JOB" 2>/dev/null || true
TURN_JOB=0
RESUME_BLOCK
exec_block "$SCRIPTS/codex-resume.sh" >"$SANDBOX/resume-block.got"
cmp -s "$SANDBOX/resume-block.want" "$SANDBOX/resume-block.got" || {
  printf -- '--- want ---\n' >&2; cat "$SANDBOX/resume-block.want" >&2
  printf -- '--- got ---\n' >&2; cat "$SANDBOX/resume-block.got" >&2
  fail "the exec branch of codex-resume.sh changed"
}

# =============================================================================
# 2. the shared validator runs BEFORE dependencies and state, in BOTH wrappers
# =============================================================================
line_of() {
  LC_ALL=C grep -n -- "$2" "$1" | head -n 1 | LC_ALL=C cut -d: -f1
}
for f in codex-start.sh codex-resume.sh; do
  TR="$(line_of "$SCRIPTS/$f" '^transport_resolve ')"
  NC="$(line_of "$SCRIPTS/$f" '^need_codex$')"
  SI="$(line_of "$SCRIPTS/$f" '^state_init$')"
  [ -n "$TR" ] || fail "$f never calls transport_resolve"
  [ -n "$NC" ] || fail "$f lost its need_codex call"
  [ -n "$SI" ] || fail "$f lost its state_init call"
  [ "$TR" -lt "$NC" ] || fail "$f calls transport_resolve after need_codex — a bad value would answer 3, not 64"
  [ "$TR" -lt "$SI" ] || fail "$f calls transport_resolve after state_init — state would move before the refusal"
done

# =============================================================================
# 3. _mcp.sh hygiene: no side effects, no heredocs, no signalled jobs, no exit
# =============================================================================
# Sourcing it must install NOTHING (the _pins.sh contract): the mcp branch arms
# the single EXIT/INT/TERM owner explicitly, after hb_begin.
TRAPS="$( . "$SCRIPTS/_mcp.sh" >/dev/null 2>&1; trap -p )"
assert_eq "" "$TRAPS" "sourcing _mcp.sh installs no traps"

if LC_ALL=C grep -n '<<' "$SCRIPTS/_mcp.sh" >"$SANDBOX/heredocs.txt" 2>/dev/null; then
  cat "$SANDBOX/heredocs.txt" >&2
  fail "_mcp.sh must carry no heredocs — the jq programs are quoted arguments on purpose"
fi

# The forked guard resets the traps it inherited and is NEVER signalled: it
# exits on a mark file and the parent only waits (the M19 lesson — killing a
# background job while job control toggles makes bash 3.2 print
# `run_pending_traps: bad value in trap_list[…]` on a stderr that belongs to
# real diagnostics).
assert_file_contains "$SCRIPTS/_mcp.sh" "trap - EXIT INT TERM"
assert_file_contains "$SCRIPTS/_mcp.sh" 'wait "$guard"'
assert_not_contains "$SCRIPTS/_mcp.sh" 'kill "$guard"'
assert_not_contains "$SCRIPTS/_mcp.sh" 'kill -TERM "$guard"'
assert_not_contains "$SCRIPTS/_mcp.sh" 'kill %'

# Once a turn has started the helper only ever RETURNS: the wrapper owns the
# shared accounting, and an `exit`/`die` in here would skip the ledger of a turn
# whose quota is already spent.
LC_ALL=C sed -n '/^mcp_turn_start() {/,/^}/p' "$SCRIPTS/_mcp.sh" >"$SANDBOX/turn-start.sh"
[ -s "$SANDBOX/turn-start.sh" ] || fail "mcp_turn_start not found in _mcp.sh"
if LC_ALL=C grep -nE '^[[:space:]]*(exit|die)[[:space:]]' "$SANDBOX/turn-start.sh" \
  >"$SANDBOX/turn-start.exits" 2>/dev/null; then
  cat "$SANDBOX/turn-start.exits" >&2
  fail "mcp_turn_start must never exit or die — it returns a status"
fi

# The single lifecycle owner chains BOTH concerns, in that order.
LC_ALL=C sed -n '/^mcp_lifecycle_exit() {/,/^}/p' "$SCRIPTS/_mcp.sh" >"$SANDBOX/lifecycle.sh"
assert_file_contains "$SANDBOX/lifecycle.sh" "mcp_cleanup"
assert_file_contains "$SANDBOX/lifecycle.sh" "hb_write failed"
CLEAN_LINE="$(line_of "$SANDBOX/lifecycle.sh" 'mcp_cleanup')"
HB_LINE="$(line_of "$SANDBOX/lifecycle.sh" 'hb_write failed')"
[ "$CLEAN_LINE" -lt "$HB_LINE" ] \
  || fail "the lifecycle owner must reap the server and the home BEFORE handling the heartbeat"

# The credential is deleted explicitly, on every path, and the ephemeral home
# can never be built inside the project's own state tree: judged on the CODE,
# with the comments (which do name .tandem/ to say exactly this) stripped out.
assert_file_contains "$SCRIPTS/_mcp.sh" 'rm -f "$MCP_HOME/auth.json" "$MCP_HOME/config.toml"'
LC_ALL=C grep -v '^[[:space:]]*#' "$SCRIPTS/_mcp.sh" >"$SANDBOX/mcp-code.sh"
assert_not_contains "$SANDBOX/mcp-code.sh" 'STATE_DIR'
# NOTE: the code DOES mention the state tree, on purpose — it computes it to
# refuse building the ephemeral home inside it. Grepping for the literal was the
# weak form of this check (a TMPDIR pointing at .tandem/tmp would have satisfied
# it while putting the credential exactly where it must never go); the real
# guarantee is behavioural and lives in tests/mcp-transport-ask.test.sh.

# The relocation never crosses a filesystem: it stages inside the destination
# directory and renames there.
LC_ALL=C sed -n '/^mcp_rollout_relocate() {/,/^}/p' "$SCRIPTS/_mcp.sh" >"$SANDBOX/relocate.sh"
assert_file_contains "$SANDBOX/relocate.sh" 'tmp="$dir/.tandem-rollout.$$.tmp"'
assert_file_contains "$SANDBOX/relocate.sh" 'mv "$tmp" "$final"'
assert_file_contains "$SANDBOX/relocate.sh" '[ -e "$final" ]'
assert_not_contains "$SANDBOX/relocate.sh" 'mv "$src"'
assert_not_contains "$SANDBOX/relocate.sh" 'mv -f'

# =============================================================================
# 4. the watchdog defaults, re-tied PER ROLE
# =============================================================================
# ask: a FOREGROUND turn, so its default is tied to the Bash tool's ceiling.
WD="$(LC_ALL=C sed -n 's|^TANDEM_MCP_TIMEOUT_DEFAULT=\([0-9][0-9]*\)$|\1|p' "$SCRIPTS/_mcp.sh" | head -n 1)"
[ -n "$WD" ] || fail "_mcp.sh declares no TANDEM_MCP_TIMEOUT_DEFAULT"
assert_eq "540" "$WD" "the per-turn watchdog default"
SKILL_MS="$(LC_ALL=C sed -n 's|.*Bash timeout: \([0-9][0-9]*\).*|\1|p' \
  "$REPO_ROOT/skills/ask/SKILL.md" | head -n 1)"
[ -n "$SKILL_MS" ] || fail "skills/ask/SKILL.md no longer states a Bash timeout"
assert_eq "600000" "$SKILL_MS" "the skill's foreground Bash timeout, in ms"
# The whole point: the transport owns the deadline, so classification, group
# reaping and accounting all happen INSIDE the wrapper. A watchdog at or above
# the tool's ceiling would be killed before it could do any of it.
[ $((WD * 1000)) -lt "$SKILL_MS" ] \
  || fail "the watchdog default (${WD}s) must stay below the skills' foreground Bash timeout (${SKILL_MS}ms)"

# review: a BACKGROUND turn, where no Bash-tool ceiling applies and an xhigh
# review legitimately runs past ten minutes — so its default is a separate
# literal, deliberately ABOVE the foreground one. Keeping the ask value here
# would kill the role's main use case; the rule that a review start under mcp
# never runs in the foreground is the executable contract of
# tests/skill-review-background-contract.test.sh, not a grep in this file.
WDR="$(LC_ALL=C sed -n 's|^TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW=\([0-9][0-9]*\)$|\1|p' \
  "$SCRIPTS/_mcp.sh" | head -n 1)"
[ -n "$WDR" ] || fail "_mcp.sh declares no TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW"
assert_eq "3600" "$WDR" "the review watchdog default"
[ "$WDR" -gt "$WD" ] \
  || fail "the review watchdog default (${WDR}s) must exceed the foreground one (${WD}s) — otherwise it has no reason to exist"

# implement: the SAME background profile as review — its turns run in the
# background by contract and are frequently the longest in the system — with a
# literal of its own rather than an alias, so the static contract stays readable
# per role and either one can diverge tomorrow without a rename.
WDI="$(LC_ALL=C sed -n 's|^TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT=\([0-9][0-9]*\)$|\1|p' \
  "$SCRIPTS/_mcp.sh" | head -n 1)"
[ -n "$WDI" ] || fail "_mcp.sh declares no TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT"
assert_eq "3600" "$WDI" "the implement watchdog default"
[ "$WDI" -gt "$WD" ] \
  || fail "the implement watchdog default (${WDI}s) must exceed the foreground one (${WD}s) — a background role would die at nine minutes"
assert_eq "$WDR" "$WDI" "implement and review share the background profile"

# image: NO literal of its own, on purpose. Its contract is the FOREGROUND one
# of 1–3 assets, so it falls through the matrix's `*` arm onto the same default
# `ask` uses — the matrix is decided by the role's dominant LAUNCH MODE, not by
# its sandbox. A `_IMAGE` literal appearing here would be a silent widening of
# exactly that contract (a hung one-asset turn waiting an hour instead of nine
# minutes), so its absence is asserted rather than assumed.
assert_not_contains "$SCRIPTS/_mcp.sh" 'TANDEM_MCP_TIMEOUT_DEFAULT_IMAGE'

# All three are mandatory: a role default that is not a positive integer would
# be the "no watchdog" degradation the transport exists to forbid.
case "$WD$WDR$WDI" in *[!0-9]*) fail "the watchdog defaults are not plain integers" ;; esac

# --- the user-facing role set, named consistently wherever the transport is
# documented. The gate is a closed `ask | review | implement | image` case in
# transport_resolve, narrowed for review alone by the TARGET axis of M21; a
# skill note still claiming a smaller set is factually wrong guidance — exactly
# what M20b's widening left behind in the ask skill until review caught it. One
# shared phrase, greppable in the FOUR skills that document the transport.
for f in "$REPO_ROOT/skills/ask/SKILL.md" "$REPO_ROOT/skills/review/SKILL.md" \
  "$REPO_ROOT/skills/implement/SKILL.md" "$REPO_ROOT/skills/image/SKILL.md"; do
  assert_file_contains "$f" 'every role — `review` only for its pipeline targets `cr-*`/`range-review-*`'
  # The superseded wording is GONE, not merely supplemented: a note carrying
  # both would document two different role sets at once.
  assert_not_contains "$f" 'the roles `ask` and `review`'
done
assert_not_contains "$REPO_ROOT/skills/ask/SKILL.md" '`ask` only'

# =============================================================================
# 5. conformance: the REAL frames, replayed through the REAL adapter
# =============================================================================
FIXTURE="$MCPFIX/notifications.ndjson"
assert_file "$FIXTURE"
assert_eq "14" "$(LC_ALL=C grep -c . "$FIXTURE" | tr -d ' ')" \
  "the captured frame count of the real M19 turn"
# The fixture really is the shape the adapter claims to read.
assert_eq "codex/event" "$(jq -rs '[.[] | .method] | unique | .[0]' "$FIXTURE")" \
  "every captured frame is a codex/event notification"
assert_file_contains "$MCPFIX/codex-version.txt" "0.144.4"

EV="$SANDBOX/adapted.ndjson"
RAW="$SANDBOX/adapted.raw.ndjson"
adapt "$FIXTURE" "$EV" "$RAW"
assert_file "$EV"

# --- the shared extractors, unchanged ----------------------------------------
assert_eq "019fc3f3-e634-7b02-922d-0eb401ad9cd0" \
  "$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EV")" \
  "the thread.started selector of codex-start.sh over the adapted stream"
printf '%s\n' "$(usage_of "$EV")" >"$SANDBOX/usage.json"
assert_json "$SANDBOX/usage.json" \
  '. == {"input_tokens":14061,"cached_input_tokens":6912,"output_tokens":5,"reasoning_output_tokens":0}'
# The MCP object drags total_tokens (14066 in the fixture); the ledger must not.
assert_file_contains "$FIXTURE" '"total_tokens": 14066'
assert_json "$SANDBOX/usage.json" 'has("total_tokens") | not'
assert_not_contains "$EV" "total_tokens"
assert_eq "1" "$(jq -rs '[.[] | select(.type == "turn.completed")] | length' "$EV")" \
  "exactly one turn.completed per turn"

# --- the serialization is the EXEC one, checked against a REAL exec stream ---
EXECFIX="$MCPFIX/exec-items.ndjson"
assert_file "$EXECFIX"
assert_not_contains "$EV" "item_type"
assert_not_contains "$EXECFIX" "item_type"
AGENT_REAL="$(jq -Sc 'select(.type == "item.completed" and .item.type == "agent_message")
  | .item | keys' "$EXECFIX" | head -n 1)"
AGENT_ADAPTED="$(jq -Sc 'select(.type == "item.completed" and .item.type == "agent_message")
  | .item | keys' "$EV" | head -n 1)"
assert_eq "$AGENT_REAL" "$AGENT_ADAPTED" \
  "the adapted agent_message item vs the archived REAL exec one"
assert_eq "OK" "$(jq -rs '[.[] | select(.type == "item.completed") | .item.text] | last' "$EV")" \
  "the agent message text the adapter reassembled from content[]"
# A UserMessage produces no exec item — `codex exec` emits none either.
assert_eq "" "$(jq -rs '[.[] | select(.item.type? == "user_message")] | .[0] // empty' "$EV")" \
  "no user_message item in the exec serialization"
# The four public usage fields, in both worlds, with no fifth one anywhere.
assert_eq "$(jq -Sc 'select(.type == "turn.completed") | .usage | keys' "$EXECFIX")" \
  "$(jq -Sc 'select(.type == "turn.completed") | .usage | keys' "$EV")" \
  "turn.completed usage keys: adapted vs the archived REAL exec stream"

# --- the sideline holds the rest, and only the rest --------------------------
assert_file "$RAW"
for t in mcp_startup_update mcp_startup_complete user_message \
  agent_message_content_delta; do
  assert_file_contains "$RAW" "\"type\": \"$t\""
done
# task_started joined the TRANSLATED set (it becomes exec's `turn.started`), so
# it belongs in the events file and no longer in the sideline: a frame must
# appear in exactly one of the two.
for t in session_configured token_count task_complete task_started; do
  assert_not_contains "$RAW" "\"type\": \"$t\""
done
# Nothing is lost and nothing is duplicated: every captured frame either
# produced exactly one events line, was CONSUMED into the turn.completed usage
# (the single token_count), or was kept verbatim in the sideline.
assert_eq "14" \
  "$(( $(LC_ALL=C grep -c . "$EV" | tr -d ' ') \
     + $(jq -rs '[.[] | select(.params.msg.type == "token_count")] | length' "$FIXTURE") \
     + $(LC_ALL=C grep -c . "$RAW" | tr -d ' ') ))" \
  "events lines + consumed token_count frames + sidelined frames == the captured frames"

# --- the narration renders it, exactly as it renders an exec stream ----------
milestones "$EV" >"$SANDBOX/adapted.milestones"
assert_file_contains "$SANDBOX/adapted.milestones" "» thread 019fc3f3-e634-7b02-922d-0eb401ad9cd0"
assert_file_contains "$SANDBOX/adapted.milestones" "» turn done — tokens in 14061 · out 5"

# =============================================================================
# 6. the stale discriminator is retired in every consumer, compat kept
# =============================================================================
assert_file_contains "$SCRIPTS/_common.sh" '.item.type // .item.item_type'
assert_file_contains "$SCRIPTS/statusline.sh" '(.type // .item_type // "")'
assert_file_contains "$DRIFT" '$e.item.type // $e.item.item_type'

# The archived REAL exec stream renders through stream_milestones — the case the
# stale discriminator silently dropped on every real turn.
milestones "$EXECFIX" >"$SANDBOX/real.milestones"
assert_file_contains "$SANDBOX/real.milestones" "» thread 019fb556-b9e8-7612-827f-c701f38bf265"
assert_file_contains "$SANDBOX/real.milestones" "» exec /bin/zsh -lc"
assert_file_contains "$SANDBOX/real.milestones" "  ✓ ok"
assert_file_contains "$SANDBOX/real.milestones" "» edit scripts/codex-doctor.sh"
assert_file_contains "$SANDBOX/real.milestones" "» web search"
assert_file_contains "$SANDBOX/real.milestones" "» turn done — tokens in 2654421 · out 22270"

# …and check-drift.sh now CLASSIFIES it, so its load-bearing checks actually
# fire instead of being permanently advisory. (The report itself is expected to
# find shape drift against the synthetic fixtures; what matters here is that the
# classes were triggered at all.)
run bash "$DRIFT" "$EXECFIX"
assert_file_contains "$OUT" "ok       thread.started|-|thread_id:string"
assert_file_contains "$OUT" "ok       turn.completed|-|usage.input_tokens:number"
assert_file_contains "$OUT" "ok       item.started|command_execution|item.command:string"
assert_file_contains "$OUT" "ok       item.completed|command_execution|item.exit_code:number"
assert_file_contains "$OUT" "ok       item.completed|file_change|item.changes.N.path:string"
assert_not_contains "$OUT" "advisory item.started|command_execution"
assert_not_contains "$OUT" "advisory item.completed|command_execution"
assert_not_contains "$OUT" "advisory item.completed|file_change"

note "mcp transport: exec branch frozen, adapter conformant with the real 0.144.4 frames"
# --- the adapter never LOSES events it already produced ---------------------
# A jq condition of the shape `X | numbers != null` yields EMPTY when the field
# is not a number, an empty condition makes the whole `if` empty, and a reduce
# body with no output leaves the accumulator NULL — silently discarding every
# event accumulated so far. That is not hypothetical: it swallowed
# `thread.started` and `turn.started` in this very milestone, and the stub did
# not reveal it because its items happened to carry every optional field. The
# anchor is the ORDER of the adapted stream over the real fixture: the first
# line must be the thread id, or something upstream is eating events again.
ADAPT_ORDER="$SANDBOX/adapt-order.txt"
LC_ALL=C jq -r '.type' "$SANDBOX/adapted.ndjson" >"$ADAPT_ORDER"
assert_eq "thread.started" "$(head -n 1 "$ADAPT_ORDER")" "the first adapted event"
assert_file_contains "$ADAPT_ORDER" "turn.started"
assert_eq "turn.completed" "$(tail -n 1 "$ADAPT_ORDER")" "the last adapted event"
# …and an item WITHOUT the optional fields (no id, no exit_code, no status) must
# not make the adapter drop anything either.
MINIMAL="$SANDBOX/minimal.ndjson"
{
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"session_configured","thread_id":"thr_min"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"item_completed","item":{"type":"CommandExecution","command":"ls"}}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"task_complete"}}}'
} >"$MINIMAL"
run_in "$SANDBOX" bash -c '. "$1/_common.sh" >/dev/null 2>&1 || true; . "$1/_mcp.sh"; mcp_events_adapt "$2" "$3" "$4"'   _ "$SCRIPTS" "$MINIMAL" "$SANDBOX/minimal.out.ndjson" "$SANDBOX/minimal.raw.ndjson"
assert_rc 0 "adapting an item with no optional fields"
assert_eq "thread.started" "$(LC_ALL=C jq -r '.type' "$SANDBOX/minimal.out.ndjson" | head -n 1)" \
  "the thread id survives an item without optional fields"

# --- a failed publication must FAIL the turn, not half-publish it -----------
# The adapter returning 1 while the caller ignored it was a real defect: the
# turn went on to narrate, relocate and DELETE the source rollout, and the
# wrapper only noticed later as a missing thread.started — an orphan rollout
# and no usable accounting. The events file is unwritable here, so publication
# cannot succeed.
UNWRITABLE="$SANDBOX/unwritable"
mkdir -p "$UNWRITABLE"
chmod 555 "$UNWRITABLE"
run_in "$SANDBOX" bash -c '. "$1/_common.sh" >/dev/null 2>&1 || true; . "$1/_mcp.sh"; mcp_events_adapt "$2" "$3" "$4"' \
  _ "$SCRIPTS" "$FIXTURE" "$UNWRITABLE/ev.ndjson" "$SANDBOX/ignored.raw.ndjson"
ADAPT_RC="$RC"
chmod 755 "$UNWRITABLE" 2>/dev/null || true
assert_eq "1" "$ADAPT_RC" "the adapter reports a failed publication"
assert_no_file "$UNWRITABLE/ev.ndjson"

# --- the real exec shapes, field by field -----------------------------------
# Anchored on the ARCHIVED real items, not on what the stub happens to emit: a
# running command carries exit_code null and a status, and a web search carries
# an OBJECT action. Dropping those was the "still not equivalent to exec" finding.
# The INPUT is the core TurnItem shape MCP really emits — argv as an ARRAY,
# `summary_text` for reasoning, `changes` as a MAP — not the exec shape it must
# be converted INTO. Feeding the output shape back in was the flaw of the first
# version of this case: it validated an assumption instead of the conversion.
CMD_RUNNING="$SANDBOX/cmd-running.ndjson"
printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"item_started","item":{"id":"item_1","type":"CommandExecution","command":["ls","-l"],"aggregated_output":"","status":"in_progress"}}}}' >"$CMD_RUNNING"
run_in "$SANDBOX" bash -c '. "$1/_common.sh" >/dev/null 2>&1 || true; . "$1/_mcp.sh"; mcp_events_adapt "$2" "$3" "$4"' \
  _ "$SCRIPTS" "$CMD_RUNNING" "$SANDBOX/cmd.out.ndjson" "$SANDBOX/cmd.raw.ndjson"
assert_rc 0 "adapting a running command"
assert_eq '["aggregated_output","command","exit_code","id","status","type"]' \
  "$(LC_ALL=C jq -c '.item | keys' "$SANDBOX/cmd.out.ndjson")" \
  "a running command carries the same keys as the real exec item"
assert_eq "null" "$(LC_ALL=C jq -c '.item.exit_code' "$SANDBOX/cmd.out.ndjson")" \
  "exit_code is present and null while the command runs"
# argv became ONE command line, never the JSON text of an array.
assert_eq '"ls -l"' "$(LC_ALL=C jq -c '.item.command' "$SANDBOX/cmd.out.ndjson")" \
  "an argv array renders as a command line"

# …and the other two core shapes: reasoning carries summary_text, file changes
# arrive as a map and must leave as the array exec emits.
CORE_SHAPES="$SANDBOX/core-shapes.ndjson"
{
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"item_completed","item":{"id":"r1","type":"Reasoning","summary_text":"thinking hard"}}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"item_completed","item":{"id":"f1","type":"FileChange","changes":{"a.txt":"update"},"status":"completed"}}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":{"type":"item_completed","item":{"id":"c1","type":"CollabAgentToolCall","tool":"resume_agent","sender_thread_id":"thr_a","receiver_thread_ids":["thr_b"],"agents_states":{"thr_b":"running"},"status":"completed"}}}}'
} >"$CORE_SHAPES"
run_in "$SANDBOX" bash -c '. "$1/_common.sh" >/dev/null 2>&1 || true; . "$1/_mcp.sh"; mcp_events_adapt "$2" "$3" "$4"' \
  _ "$SCRIPTS" "$CORE_SHAPES" "$SANDBOX/core.out.ndjson" "$SANDBOX/core.raw.ndjson"
assert_rc 0 "adapting the core item shapes"
assert_eq '"thinking hard"' \
  "$(LC_ALL=C jq -c 'select(.item.type == "reasoning") | .item.text' "$SANDBOX/core.out.ndjson")" \
  "reasoning text comes from summary_text"
assert_eq '[{"path":"a.txt","kind":"update"}]' \
  "$(LC_ALL=C jq -c 'select(.item.type == "file_change") | .item.changes' "$SANDBOX/core.out.ndjson")" \
  "a changes map becomes the array exec emits"
# exec publishes the core CollabAgentToolCall as `collab_tool_call`, WITHOUT a
# server and WITH the collaboration identity: the discriminator consumers match
# on, and the fields that say which agents took part.
COLLAB="$(LC_ALL=C jq -c 'select(.item.id? == "c1") | .item' "$SANDBOX/core.out.ndjson")"
assert_eq '"collab_tool_call"' "$(printf '%s' "$COLLAB" | jq -c '.type')" \
  "the exec discriminator for a collaboration call"
assert_eq '"thr_a"' "$(printf '%s' "$COLLAB" | jq -c '.sender_thread_id')" "sender preserved"
assert_eq '["thr_b"]' "$(printf '%s' "$COLLAB" | jq -c '.receiver_thread_ids')" "receivers preserved"
assert_eq "null" "$(printf '%s' "$COLLAB" | jq -c '.server')" "no invented server field"
assert_eq '"wait"' "$(printf '%s' "$COLLAB" | jq -c '.tool')" "resume_agent renders as exec's wait"
assert_eq '{"thr_b":"running"}' "$(printf '%s' "$COLLAB" | jq -c '.agents_states')" \
  "the agents_states MAP survives"
assert_eq "null" "$(printf '%s' "$COLLAB" | jq -c '.prompt')" "an absent prompt stays null"
