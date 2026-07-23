#!/usr/bin/env bash
# tandem — one-shot, parallel-safe Codex seat for ultra swarms.
#
# usage: codex-swarm.sh <tier> <run-id> <seat> <prompt-file>
#   tier         judge | worker | scout  (pins model + effort; see below)
#   run-id       kebab-case id of the swarm run (state namespace)
#   seat         label of this seat within the run (state file prefix)
#   prompt-file  FULLY RENDERED prompt (no template expansion happens here)
#
# Tier policy (the ultracode mapping — override models/efforts via env):
#   judge   gpt-5.6-sol  xhigh   seats that would need a frontier judge
#   worker  gpt-5.6-sol  high    standard analysis / review seats
#   scout   gpt-5.6-luna high    mechanical sweeps and triage
#
# Differences vs codex-start.sh, all deliberate:
#   - No thread persistence and no resume: seat independence is the point of a
#     swarm (fresh context per seat); retrying a seat overwrites its files.
#   - No shared heartbeat: N parallel turns would fight over current.json.
#     The Workflow progress UI and the shell-panel milestones narrate instead.
#   - Sandbox is read-only for EVERY tier and not overridable: swarm seats
#     reason and report — they never write. Writing stays in the tandem
#     pipeline (implement), with its clean-tree and dedicated-branch rules.
#
# exit codes: 0 ok · 1 codex failure · 3 missing dependency · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -eq 4 ] || die "usage: codex-swarm.sh <tier> <run-id> <seat> <prompt-file>" 64
TIER="$1" RUN_ID="$2" SEAT="$3" PROMPT_FILE="$4"

need_codex
need_jq

case "$TIER" in
  judge)
    CODEX_MODEL="${TANDEM_ULTRA_JUDGE_MODEL:-gpt-5.6-sol}"
    CODEX_EFFORT="${TANDEM_ULTRA_JUDGE_EFFORT:-xhigh}"
    ;;
  worker)
    CODEX_MODEL="${TANDEM_ULTRA_WORKER_MODEL:-gpt-5.6-sol}"
    CODEX_EFFORT="${TANDEM_ULTRA_WORKER_EFFORT:-high}"
    ;;
  scout)
    CODEX_MODEL="${TANDEM_ULTRA_SCOUT_MODEL:-gpt-5.6-luna}"
    CODEX_EFFORT="${TANDEM_ULTRA_SCOUT_EFFORT:-high}"
    ;;
  *)
    die "unknown tier '$TIER' (expected: judge, worker or scout)" 64
    ;;
esac
CODEX_SANDBOX="read-only"

[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE" 64

RUN_KEY="$(target_key "$RUN_ID")"
[ -n "$RUN_KEY" ] || die "run-id produced an empty state key: '$RUN_ID'" 64
SEAT_KEY="$(target_key "$SEAT")"
[ -n "$SEAT_KEY" ] || die "seat produced an empty state key: '$SEAT'" 64

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE_ROOT="$PROJECT_DIR/.tandem"
STATE_DIR="$STATE_ROOT/state/ultra/$RUN_KEY"
mkdir -p "$STATE_DIR" "$STATE_ROOT/log" "$STATE_ROOT/tmp"
[ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore"

MSG_FILE="$STATE_DIR/$SEAT_KEY.reply.txt"
EVENTS_FILE="$STATE_DIR/$SEAT_KEY.events.ndjson"
cp "$PROMPT_FILE" "$STATE_DIR/$SEAT_KEY.prompt.txt"
rm -f "$MSG_FILE"

printf 'tandem: swarm seat — tier=%s model=%s effort=%s sandbox=%s run=%s seat=%s\n' \
  "$TIER" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_SANDBOX" "$RUN_ID" "$SEAT" >&2

# Same tee + milestones plumbing as codex-start.sh: the NDJSON is the durable
# record, stream_milestones narrates the shell panel, PIPESTATUS[0] keeps
# codex's own exit code.
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

printf '\n--- codex reply (%s, %s/%s) ---\n' "$CODEX_MODEL" "$RUN_ID" "$SEAT"
cat "$MSG_FILE"
printf '\n--- end ---\n'
