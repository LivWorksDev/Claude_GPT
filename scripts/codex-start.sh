#!/usr/bin/env bash
# tandem — start a NEW persistent Codex thread for a target.
#
# usage: codex-start.sh <role> <target> <prompt-template.tpl> [extra-file] [notes-file]
#   role    review | implement | ask | image  (pins model, effort and sandbox — see _common.sh)
#   target  plan path or kebab-case topic label; it is the state key, reuse it verbatim
#   extra-file / notes-file  optional files whose content fills {{EXTRA}} / {{NOTES}}
#
# exit codes: 0 ok · 1 codex failure · 2 thread already exists (resume instead)
#             3 missing dependency · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -ge 3 ] || die "usage: codex-start.sh <role> <target> <template.tpl> [extra-file] [notes-file]" 64
ROLE_ARG="$1" TARGET="$2" TPL="$3" EXTRA_FILE="${4:-}" NOTES_FILE="${5:-}"

need_codex
need_jq
resolve_role "$ROLE_ARG"
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

TURN=1
printf '%s\n' "$TURN" >"$TURN_FILE"
PROMPT_FILE="$STATE_DIR/$KEY.t$TURN.prompt.txt"
MSG_FILE="$STATE_DIR/$KEY.t$TURN.reply.txt"
EVENTS_FILE="$STATE_DIR/$KEY.t$TURN.events.ndjson"

load_prompt "$TPL" >"$PROMPT_FILE"
rm -f "$MSG_FILE"

printf 'tandem: starting codex thread — role=%s model=%s effort=%s sandbox=%s target=%s\n' \
  "$ROLE" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_SANDBOX" "$TARGET" >&2

hb_begin

# Events stream through tee: the full NDJSON is still captured for the
# thread-id extraction and the durable record, while stream_milestones narrates
# progress on stdout. PIPESTATUS[0] (not $?) keeps codex's own exit code — a
# filter hiccup must never masquerade as a codex failure.
set +e
codex exec \
  --json --skip-git-repo-check --color never \
  --model "$CODEX_MODEL" \
  --sandbox "$CODEX_SANDBOX" \
  -c model_reasoning_effort="$CODEX_EFFORT" \
  --output-last-message "$MSG_FILE" \
  - <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
  | tee "$EVENTS_FILE" | stream_milestones
rc="${PIPESTATUS[0]}"
set -e

if [ "$rc" -ne 0 ]; then
  printf 'tandem: codex exec failed (exit %s). Last stderr lines:\n' "$rc" >&2
  tail -n 20 "$EVENTS_FILE.stderr" >&2 || true
  die "full logs: $EVENTS_FILE and $EVENTS_FILE.stderr" 1
fi
[ -s "$MSG_FILE" ] || die "codex exited 0 but produced no final message — see $EVENTS_FILE" 1

# jq failures (e.g. a truncated/garbage event line) must not leak jq's own
# exit code past our documented contract — the emptiness check handles them.
THREAD_ID="$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$EVENTS_FILE" 2>/dev/null || true)"
[ -n "$THREAD_ID" ] || die "could not capture a thread.started event — see $EVENTS_FILE" 1
printf '%s\n' "$THREAD_ID" >"$THREAD_FILE"
# Per-turn replies are the durable record; last.txt is a convenience pointer
# to the newest one, updated only after every success check passed.
cp "$MSG_FILE" "$LAST_FILE"
hb_end "done" "$(hb_verdict "$MSG_FILE")"

printf '\n--- codex reply (%s, turn %s) ---\n' "$CODEX_MODEL" "$TURN"
cat "$MSG_FILE"
printf '\n--- end ---\nTHREAD_ID: %s\n' "$THREAD_ID"
