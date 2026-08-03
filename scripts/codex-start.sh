#!/usr/bin/env bash
# tandem — start a NEW persistent Codex thread for a target.
#
# usage: codex-start.sh <role> <target> <prompt-template.tpl> [extra-file] [notes-file]
#   role    review | implement | ask | image  (pins model, effort and sandbox — see _common.sh)
#   target  plan path or kebab-case topic label; it is the state key, reuse it verbatim
#   extra-file / notes-file  optional files whose content fills {{EXTRA}} / {{NOTES}}
#
# env: TANDEM_CODEX_CWD  optional working root for the turn (`--cd`); the thread
#      state and the heartbeat stay where CLAUDE_PROJECT_DIR points — see
#      codex_cwd_validate/codex_pins in _common.sh for the whole policy block.
#      TANDEM_TRANSPORT  exec (default) | mcp. `mcp` routes the turn through
#      `codex mcp-server` and is supported for role `ask` only in this hop; every
#      artefact, exit code and guard is identical either way (scripts/_mcp.sh).
#      TANDEM_MCP_TIMEOUT_SECONDS  per-turn watchdog for the mcp transport.
#
# exit codes: 0 ok · 1 codex failure · 2 thread already exists (resume instead)
#             3 missing dependency · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
# shellcheck source=_mcp.sh
. "$SCRIPT_DIR/_mcp.sh"

[ $# -ge 3 ] || die "usage: codex-start.sh <role> <target> <template.tpl> [extra-file] [notes-file]" 64
ROLE_ARG="$1" TARGET="$2" TPL="$3" EXTRA_FILE="${4:-}" NOTES_FILE="${5:-}"

codex_cwd_validate
# The transport is validated BEFORE any dependency check and before a single
# byte of state moves: an invalid value must answer 64 without launching codex
# and without advancing the turn counter. Same call, same order, in
# codex-resume.sh — a resume that fell back to exec on a bogus value would break
# the fail-closed rule exactly where it matters most.
transport_resolve "$ROLE_ARG" start
need_codex
need_jq
resolve_role "$ROLE_ARG"
codex_pins
state_init

KEY="$(target_key "$TARGET")"
[ -n "$KEY" ] || die "target produced an empty state key: '$TARGET'" 64
THREAD_FILE="$STATE_DIR/$KEY.thread"
TURN_FILE="$STATE_DIR/$KEY.turn"
LAST_FILE="$STATE_DIR/$KEY.last.txt"

if [ -f "$THREAD_FILE" ]; then
  printf 'tandem: a thread already exists for "%s" (%s).\n' "$TARGET" "$(cat "$THREAD_FILE")" >&2
  printf 'tandem: use codex-resume.sh to continue it, or codex-reset.sh to discard it first.\n' >&2
  exit 2
fi

EXTRA="$(read_optional_file "$EXTRA_FILE")"
NOTES="$(read_optional_file "$NOTES_FILE")"

# The attempt number is monotonic across FAILED starts of the same target: a
# post-pipeline failure (empty reply, missing thread id) exits before the
# thread file is written, so the retry comes back through start — and its paid
# predecessor must keep its t<N> artefacts, the usage ledger above all: spent
# quota cannot be un-spent, and a retry that overwrote t1 would erase exactly
# the expensive attempt the accounting exists to expose. Same sanitizer and
# base-10 forcing as codex-resume.sh ('08'/'09' would abort as octal).
TURN="$(cat "$TURN_FILE" 2>/dev/null || printf '0')"
case "$TURN" in '' | *[!0-9]*) TURN=0 ;; esac
TURN=$((10#$TURN + 1))
printf '%s\n' "$TURN" >"$TURN_FILE"
PROMPT_FILE="$STATE_DIR/$KEY.t$TURN.prompt.txt"
MSG_FILE="$STATE_DIR/$KEY.t$TURN.reply.txt"
EVENTS_FILE="$STATE_DIR/$KEY.t$TURN.events.ndjson"

load_prompt "$TPL" >"$PROMPT_FILE"
rm -f "$MSG_FILE"

# Durable per-turn metadata, symmetrical with codex-resume.sh and written BEFORE
# the turn so it survives a failure too. The heartbeat carries the same four
# fields but is GLOBAL and replaceable — the next turn overwrites it — so this is
# the only durable record of what a given turn ran with. Built with `jq -n --arg`,
# never printf: the model comes from an env override and may carry quotes or
# backslashes, which a format string would turn into invalid JSON. Persisted with
# the usage ledger's atomic tmp+mv, best-effort: a record that cannot land is
# swallowed — a display/audit artefact must never abort a paid turn.
META_JSON="$(jq -n \
  --arg role "$ROLE" \
  --arg model "$CODEX_MODEL" \
  --arg effort "$CODEX_EFFORT" \
  --arg sandbox "$CODEX_SANDBOX" \
  '{role: $role, model: $model, effort: $effort, sandbox: $sandbox}' 2>/dev/null || true)"
# The legacy object stays EXACTLY four keys for the default transport: the
# opt-in fields are added only when TANDEM_TRANSPORT was actually given, so a
# turn that nobody opted in for keeps the record every existing consumer reads.
if [ -n "$META_JSON" ] && [ "${TRANSPORT_OPT_IN:-0}" = "1" ]; then
  META_WITH_TRANSPORT="$(printf '%s' "$META_JSON" | jq -c \
    --arg requested "$TRANSPORT_REQUESTED" \
    --arg effective "$TRANSPORT_EFFECTIVE" \
    '. + {transport_requested: $requested, transport_effective: $effective}' \
    2>/dev/null || true)"
  if [ -n "$META_WITH_TRANSPORT" ]; then
    META_JSON="$META_WITH_TRANSPORT"
  fi
fi
if [ -n "$META_JSON" ]; then
  usage_persist "$STATE_DIR/$KEY.t$TURN.meta.json" "$META_JSON" || true
fi

printf 'tandem: starting codex thread — role=%s model=%s effort=%s sandbox=%s target=%s\n' \
  "$ROLE" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_SANDBOX" "$TARGET" >&2
if [ "$TRANSPORT" = "mcp" ]; then
  printf 'tandem: transport=mcp (codex mcp-server, one server per turn, watchdog %ss)\n' \
    "$MCP_TIMEOUT" >&2
fi

hb_begin

# The mcp branch owns EXIT/INT/TERM from here: traps do not stack and hb_begin
# has just replaced the EXIT trap, so ONE composable owner chains the mcp
# cleanup and the heartbeat's failure handling (scripts/_mcp.sh).
if [ "$TRANSPORT" = "mcp" ]; then
  mcp_lifecycle_arm
  mcp_home_build
fi

# Events stream through tee: the full NDJSON is still captured for the
# thread-id extraction and the durable record, while stream_milestones narrates
# progress on stdout. PIPESTATUS[0] (not $?) keeps codex's own exit code — a
# filter hiccup must never masquerade as a codex failure.
set +e
if [ "$TRANSPORT" = "mcp" ]; then
  # The helper RETURNS a status and never exits once the turn has started, so
  # the shared accounting below runs on every path — a hung turn is still a
  # turn, and its quota is still spent.
  mcp_turn_start "$PROMPT_FILE" "$EVENTS_FILE" "$MSG_FILE" "$EVENTS_FILE.stderr"
  rc=$?
else
  codex exec \
    --json --skip-git-repo-check --color never \
    --model "$CODEX_MODEL" \
    --sandbox "$CODEX_SANDBOX" \
    -c model_reasoning_effort="$CODEX_EFFORT" \
    "${CODEX_PINS[@]}" \
    --output-last-message "$MSG_FILE" \
    - <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
    | tee "$EVENTS_FILE" | stream_milestones
  rc="${PIPESTATUS[0]}"
fi
set -e

# Token accounting, BEFORE any check on purpose: a turn that produced a
# `turn.completed` already burned its quota even when the wrapper is about to
# reject it (empty reply, missing thread id). "No usage" means "the stream
# carries no turn.completed", never "the wrapper exited non-zero" — counting
# only successful turns would under-report exactly the expensive failures.
# Persistence is hardened: a write that cannot land is swallowed, never an
# aborted turn and never a truncated file (see usage_persist).
USAGE_JSON="$(turn_usage "$EVENTS_FILE")"
if [ -n "$USAGE_JSON" ]; then
  usage_persist "$STATE_DIR/$KEY.t$TURN.usage.json" "$USAGE_JSON" || true
  HB_TOKENS_IN="$(usage_number "$USAGE_JSON" input_tokens)"
  HB_TOKENS_OUT="$(usage_number "$USAGE_JSON" output_tokens)"
  # One parseable line, on every path: the failure reports (FAILED/DEADLOCK) are
  # exactly where the orchestrator needs it, and copying a line beats
  # recomputing the target_key checksum to find the file.
  printf 'USAGE: %s\n' "$USAGE_JSON" >&2
fi

if [ "$rc" -ne 0 ]; then
  if [ "$TRANSPORT" = "mcp" ]; then
    printf 'tandem: the mcp turn failed — %s. Last stderr lines:\n' "${MCP_STATUS:-unknown reason}" >&2
  else
    printf 'tandem: codex exec failed (exit %s). Last stderr lines:\n' "$rc" >&2
  fi
  tail -n 20 "$EVENTS_FILE.stderr" >&2 || true
  die "full logs: $EVENTS_FILE and $EVENTS_FILE.stderr" 1
fi
[ -s "$MSG_FILE" ] || die "codex exited 0 but produced no final message — see $EVENTS_FILE" 1

# jq failures (e.g. a truncated/garbage event line) must not leak jq's own
# exit code past our documented contract — the emptiness check handles them.
THREAD_ID="$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EVENTS_FILE" 2>/dev/null || true)"
[ -n "$THREAD_ID" ] || die "could not capture a thread.started event — see $EVENTS_FILE" 1
# Under mcp the tool RESULT echoes the id too, and the two must agree: the
# stream says which thread the server configured, the result says which thread
# it is answering for. Persisting either one alone would let a mismatch pass as
# a perfectly ordinary start.
if [ "$TRANSPORT" = "mcp" ]; then
  [ -n "${MCP_THREAD_ID:-}" ] \
    || die "the mcp result echoed no threadId — see $EVENTS_FILE" 1
  [ "$MCP_THREAD_ID" = "$THREAD_ID" ] \
    || die "the mcp result echoed thread $MCP_THREAD_ID but the stream announced $THREAD_ID — refusing to persist an ambiguous thread id" 1
fi
printf '%s\n' "$THREAD_ID" >"$THREAD_FILE"
# Per-turn replies are the durable record; last.txt is a convenience pointer
# to the newest one, updated only after every success check passed.
cp "$MSG_FILE" "$LAST_FILE"
hb_end "done" "$(hb_verdict "$MSG_FILE")"

printf '\n--- codex reply (%s, turn %s) ---\n' "$CODEX_MODEL" "$TURN"
cat "$MSG_FILE"
printf '\n--- end ---\nTHREAD_ID: %s\n' "$THREAD_ID"
