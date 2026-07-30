#!/usr/bin/env bash
# tandem — resume an EXISTING Codex thread, re-pinning model, effort and sandbox.
#
# `codex exec resume` accepts the shared options only BEFORE the subcommand,
# so they are passed to the parent `exec`; the whole policy block (sandbox,
# network, writable roots, approvals — see codex_pins in _common.sh) rides
# there too, so a resumed turn can never fall back to whatever default lives in
# the user's ~/.codex/config.toml.
#
# usage: codex-resume.sh <role> <target> <prompt-template.tpl> [extra-file] [notes-file]
# env:   TANDEM_CODEX_CWD  optional working root for the turn (`--cd`)
# exit codes: 0 ok · 1 codex failure · 2 no thread yet (start instead)
#             3 missing dependency · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -ge 3 ] || die "usage: codex-resume.sh <role> <target> <template.tpl> [extra-file] [notes-file]" 64
ROLE_ARG="$1" TARGET="$2" TPL="$3" EXTRA_FILE="${4:-}" NOTES_FILE="${5:-}"

codex_cwd_validate
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

if [ ! -f "$THREAD_FILE" ]; then
  printf 'tandem: no thread exists for "%s" yet — use codex-start.sh first.\n' "$TARGET" >&2
  exit 2
fi
THREAD_ID="$(tr -d '[:space:]' <"$THREAD_FILE")"
[ -n "$THREAD_ID" ] || die "thread file is empty: $THREAD_FILE — reset and start over" 1

EXTRA="$(read_optional_file "$EXTRA_FILE")"
NOTES="$(read_optional_file "$NOTES_FILE")"

TURN="$(cat "$TURN_FILE" 2>/dev/null || printf '0')"
case "$TURN" in '' | *[!0-9]*) TURN=0 ;; esac
# 10# forces base 10: the sanitizer above accepts an all-digits '08'/'09', which
# bash would otherwise read as octal and abort with "value too great for base"
# — a raw bash error, before hb_begin, with no die() and no heartbeat.
TURN=$((10#$TURN + 1))
printf '%s\n' "$TURN" >"$TURN_FILE"
PROMPT_FILE="$STATE_DIR/$KEY.t$TURN.prompt.txt"
MSG_FILE="$STATE_DIR/$KEY.t$TURN.reply.txt"
EVENTS_FILE="$STATE_DIR/$KEY.t$TURN.events.ndjson"

load_prompt "$TPL" >"$PROMPT_FILE"
rm -f "$MSG_FILE"

printf 'tandem: resuming codex thread %s — role=%s model=%s effort=%s sandbox=%s turn=%s\n' \
  "$THREAD_ID" "$ROLE" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_SANDBOX" "$TURN" >&2

hb_begin

# Events stream through tee: full NDJSON still captured for the fallback-id
# guard and the durable record, while stream_milestones narrates progress on
# stdout. PIPESTATUS[0] (not $?) keeps codex's own exit code — a filter hiccup
# must never masquerade as a codex failure.
set +e
codex exec \
  --json --skip-git-repo-check --color never \
  --model "$CODEX_MODEL" \
  --sandbox "$CODEX_SANDBOX" \
  -c model_reasoning_effort="$CODEX_EFFORT" \
  "${CODEX_PINS[@]}" \
  --output-last-message "$MSG_FILE" \
  resume "$THREAD_ID" - <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
  | tee "$EVENTS_FILE" | stream_milestones
rc="${PIPESTATUS[0]}"
set -e

# Token accounting, BEFORE any check on purpose: a turn that produced a
# `turn.completed` already burned its quota even when the wrapper is about to
# reject it (empty reply, a fallback to another thread). "No usage" means "the
# stream carries no turn.completed", never "the wrapper exited non-zero" —
# counting only successful turns would under-report exactly the expensive
# failures. Persistence is hardened: a write that cannot land is swallowed,
# never an aborted turn and never a truncated file (see usage_persist).
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
  printf 'tandem: codex exec resume failed (exit %s). Last stderr lines:\n' "$rc" >&2
  tail -n 20 "$EVENTS_FILE.stderr" >&2 || true
  die "full logs: $EVENTS_FILE and $EVENTS_FILE.stderr" 1
fi
[ -s "$MSG_FILE" ] || die "codex exited 0 but produced no final message — see $EVENTS_FILE" 1

# Guard against codex's silent fallback: resuming with a stale/corrupt id can
# silently attach to a different (or brand-new) thread. If this turn reports a
# thread id other than the one requested, fail loudly instead of trusting it.
GOT_ID="$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EVENTS_FILE" 2>/dev/null || true)"
if [ -n "$GOT_ID" ] && [ "$GOT_ID" != "$THREAD_ID" ]; then
  die "codex resumed thread $GOT_ID instead of $THREAD_ID — state is stale. Run codex-reset.sh and start over." 1
fi

# Per-turn replies are the durable record; last.txt is a convenience pointer
# to the newest one, updated only after every success check passed.
cp "$MSG_FILE" "$LAST_FILE"
hb_end "done" "$(hb_verdict "$MSG_FILE")"

printf '\n--- codex reply (%s, turn %s) ---\n' "$CODEX_MODEL" "$TURN"
cat "$MSG_FILE"
printf '\n--- end ---\nTHREAD_ID: %s\n' "$THREAD_ID"
