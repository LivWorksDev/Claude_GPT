#!/usr/bin/env bash
# tandem — one-shot, parallel-safe Codex seat for ultra swarms.
#
# usage: codex-swarm.sh [--preamble <file>] <tier> <run-id> <seat> <prompt-file>
#   --preamble   OPTIONAL file prepended to the prompt, byte for byte, by THIS
#                script — concatenating the shared seat preamble is machine
#                work, not something a wrapper model should retype verbatim.
#                No separator of any kind is injected: the staged prompt is
#                exactly <preamble bytes><prompt bytes>, so the final newline of
#                the preamble is its author's business, as in any text file.
#   tier         judge | worker | scout  (pins model + effort; see below)
#   run-id       kebab-case id of the swarm run (state namespace)
#   seat         label of this seat within the run (state file prefix)
#   prompt-file  FULLY RENDERED prompt (no template expansion happens here)
#
# The flag goes BEFORE the positionals and the positional arity stays exactly
# four, with or without it: an extra argument is a usage error, never a silently
# ignored one.
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
# env: TANDEM_CODEX_CWD  optional working root for the seat (`--cd`)
#
# exit codes: 0 ok · 1 codex failure · 3 missing dependency · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

USAGE="usage: codex-swarm.sh [--preamble <file>] <tier> <run-id> <seat> <prompt-file>"

# Flag parsing: a plain while/case loop (bash 3.2 has no long-option getopts and
# no associative arrays) that stops at the first non-flag word. Fail-closed —
# an unknown `--flag` is a usage error, never an argument that silently becomes
# the tier.
PREAMBLE_FILE=""
HAVE_PREAMBLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --preamble)
      [ $# -ge 2 ] || die "--preamble requires a file argument — $USAGE" 64
      PREAMBLE_FILE="$2"
      HAVE_PREAMBLE=1
      shift 2
      ;;
    --*)
      die "unknown option '$1' — $USAGE" 64
      ;;
    *)
      break
      ;;
  esac
done

[ $# -eq 4 ] || die "$USAGE" 64
TIER="$1" RUN_ID="$2" SEAT="$3" PROMPT_FILE="$4"

codex_cwd_validate
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
codex_pins

[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE" 64
if [ "$HAVE_PREAMBLE" -eq 1 ]; then
  [ -f "$PREAMBLE_FILE" ] || die "preamble file not found: $PREAMBLE_FILE" 64
fi

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
# The staged prompt is the durable record of what this seat was sent AND the
# file codex reads from stdin — one file, so the record can never drift from
# the turn. `cat` concatenates the bytes and nothing else: no separator, no
# header, no printf format string anywhere near the content.
STAGED_PROMPT="$STATE_DIR/$SEAT_KEY.prompt.txt"
if [ "$HAVE_PREAMBLE" -eq 1 ]; then
  cat "$PREAMBLE_FILE" "$PROMPT_FILE" >"$STAGED_PROMPT"
else
  cat "$PROMPT_FILE" >"$STAGED_PROMPT"
fi
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
  "${CODEX_PINS[@]}" \
  --output-last-message "$MSG_FILE" \
  - <"$STAGED_PROMPT" 2>"$EVENTS_FILE.stderr" \
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
