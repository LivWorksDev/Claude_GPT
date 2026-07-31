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
#     swarm (fresh context per seat); retrying a seat overwrites its files —
#     every one of them EXCEPT the token ledger `<seat>.t<N>.usage.json`, which
#     gains one file per attempt because spent quota cannot be un-spent.
#   - No shared heartbeat: N parallel turns would fight over current.json.
#     The Workflow progress UI and the shell-panel milestones narrate instead.
#   - Sandbox is read-only for EVERY tier and not overridable: swarm seats
#     reason and report — they never write. Writing stays in the tandem
#     pipeline (implement), with its clean-tree and dedicated-branch rules.
#
# env: TANDEM_CODEX_CWD           optional working root for the seat (`--cd`)
#      TANDEM_ULTRA_CONCURRENCY   max simultaneous codex turns of ONE run
#                                 (default 4). Enforced HERE, by a per-run
#                                 semaphore under .tandem/state/ultra/<run>/
#                                 .slots/, so the limit holds even when the
#                                 orchestration launches every seat at once.
#      TANDEM_ULTRA_SLOT_TIMEOUT  seconds a seat waits for a free slot before
#                                 failing loud instead of deadlocking
#                                 (default 1800). Both are positive integers;
#                                 set-but-empty is a usage error, never a
#                                 silent default.
#
# exit codes: 0 ok · 1 codex failure · 3 missing dependency · 64 usage error ·
#             75 no free slot within the timeout (EX_TEMPFAIL — the turn never
#             started, so retrying costs no quota)
# A seat killed by HUP/INT/TERM exits 129/130/143: the signal is recorded and
# honoured at the next safe boundary, never mid-turn, so a turn that already
# completed is still accounted for and the slot is always released.

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

# --- the semaphore's dials, validated BEFORE the toolchain -------------------
# Same placement rule as codex_cwd_validate: a bad argument must fail as a usage
# error, never as a missing toolchain. Expanded WITHOUT `:` so that set-but-empty
# is invalid instead of silently becoming the default — the exact contract of
# TANDEM_CODEX_CWD.
ultra_int_validate() {
  # ultra_int_validate <var-name> <value> — dies 64 unless <value> is a positive
  # decimal integer. `10#` normalizes before ANY arithmetic: to bash a leading
  # zero means octal, so `08`/`09` would be a fatal arithmetic error instead of
  # the eight and nine the user wrote.
  local name="$1" value="$2"
  case "$value" in
    '')
      die "$name is set but empty — unset it, or give it a positive integer" 64
      ;;
    *[!0-9]*)
      die "$name must be a positive integer, got '$value'" 64
      ;;
  esac
  [ "$((10#$value))" -ge 1 ] \
    || die "$name must be a positive integer, got '$value'" 64
}

ULTRA_CONC="${TANDEM_ULTRA_CONCURRENCY-4}"
ultra_int_validate TANDEM_ULTRA_CONCURRENCY "$ULTRA_CONC"
ULTRA_CONC=$((10#$ULTRA_CONC))

ULTRA_TIMEOUT="${TANDEM_ULTRA_SLOT_TIMEOUT-1800}"
ultra_int_validate TANDEM_ULTRA_SLOT_TIMEOUT "$ULTRA_TIMEOUT"
ULTRA_TIMEOUT=$((10#$ULTRA_TIMEOUT))

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
# The semaphore is per RUN: two simultaneous runs get one set of slots each
# (2×C turns globally), which is the semantics of this state namespace and is
# documented as such in skills/ultra/SKILL.md. `mkdir -p` is race-safe between
# concurrent seats.
SLOTS_DIR="$STATE_DIR/.slots"
mkdir -p "$STATE_DIR" "$SLOTS_DIR" "$STATE_ROOT/log" "$STATE_ROOT/tmp"
[ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore"

MSG_FILE="$STATE_DIR/$SEAT_KEY.reply.txt"
EVENTS_FILE="$STATE_DIR/$SEAT_KEY.events.ndjson"
# The staged prompt is the durable record of what this seat was sent AND the
# file codex reads from stdin — one file, so the record can never drift from
# the turn. `cat` concatenates the bytes and nothing else: no separator, no
# header, no printf format string anywhere near the content.
STAGED_PROMPT="$STATE_DIR/$SEAT_KEY.prompt.txt"

# --- the semaphore ------------------------------------------------------------
# State BEFORE any trap is armed (set -u), and in this order: the EXIT trap may
# fire at any point from here on and must never read an undefined variable, nor
# delete a slot this process does not own.
SLOT_DIR=""
SLOT_HELD=0
PENDING_SIG=0

# A signal handler NEVER exits. It records the code and returns, so a signal
# delivered mid-turn cannot skip the token accounting of a turn that already
# burned quota, and cannot cut the mkdir → holder critical section in half.
# The exit happens at the safe boundaries below (sig_honor), and nowhere else.
trap 'PENDING_SIG=129' HUP
trap 'PENDING_SIG=130' INT
trap 'PENDING_SIG=143' TERM

# slot_release — idempotent, and only ever OUR slot: SLOT_HELD is set inside the
# critical section of slot_acquire, so a seat that never won one (a timeout, a
# usage error, a cancelled wait) leaves every other seat's slot untouched.
# Always returns 0: an EXIT trap must preserve the script's own exit code.
slot_release() {
  if [ "$SLOT_HELD" -eq 1 ] && [ -n "$SLOT_DIR" ]; then
    SLOT_HELD=0
    rm -rf "$SLOT_DIR" 2>/dev/null || true
  fi
  return 0
}
trap 'slot_release' EXIT

# sig_honor — act on a recorded signal, at a boundary where acting is safe.
sig_honor() {
  [ "$PENDING_SIG" -ne 0 ] || return 0
  printf 'tandem: signal received — seat aborted (exit %s, run=%s seat=%s)\n' \
    "$PENDING_SIG" "$RUN_ID" "$SEAT" >&2
  exit "$PENDING_SIG"
}

# slot_acquire — wait for one of the C slots of this run. `mkdir` is the
# portable atomic test-and-set (bash 3.2 / BSD have no flock) and leaves an
# inspectable artefact: the slot directory with its `holder` file.
#
# There is NO auto-reclaim of orphaned slots: a SIGKILLed seat (only KILL skips
# the EXIT trap) leaves its slot behind until the bounded wait below denounces
# it by name. Probing the holder's pid to steal the slot would add exactly the
# rm/mkdir races this semaphore exists to remove.
slot_acquire() {
  local deadline now i announced=0
  deadline=$(( $(date +%s) + ULTRA_TIMEOUT ))
  while :; do
    i=1
    while [ "$i" -le "$ULTRA_CONC" ]; do
      if mkdir "$SLOTS_DIR/slot.$i" 2>/dev/null; then
        # CRITICAL SECTION: nothing may exit between winning the directory and
        # recording that we own it — a signal here would either leak the slot
        # (exit before SLOT_HELD=1) or, worse, teach a later release to delete
        # a slot that by then belongs to somebody else. Signals are only
        # recorded, so the section is safe by construction; the boundary is the
        # sig_honor immediately after it.
        SLOT_DIR="$SLOTS_DIR/slot.$i"
        SLOT_HELD=1
        printf 'pid=%s run=%s seat=%s since=%s\n' \
          "$$" "$RUN_ID" "$SEAT" "$(date +%s)" >"$SLOT_DIR/holder" 2>/dev/null || true
        sig_honor
        return 0
      fi
      sig_honor
      i=$((i + 1))
    done
    now="$(date +%s)"
    # Before the timeout verdict: a seat that was told to die dies as 143, never
    # as a congestion 75, and never after acquiring anything.
    sig_honor
    if [ "$now" -ge "$deadline" ]; then
      die "no free ultra slot after ${ULTRA_TIMEOUT}s (concurrency=$ULTRA_CONC, run=$RUN_ID, seat=$SEAT) — inspect $SLOTS_DIR (a SIGKILLed seat leaves a stale slot dir; remove it if no codex turn is running)" 75
    fi
    if [ "$announced" -eq 0 ]; then
      announced=1
      printf 'tandem: all %s ultra slots busy — waiting (timeout %ss, run=%s seat=%s)\n' \
        "$ULTRA_CONC" "$ULTRA_TIMEOUT" "$RUN_ID" "$SEAT" >&2
    fi
    sleep 1 || true
    sig_honor
  done
}

# The slot comes BEFORE the prompt is staged and before the previous reply is
# removed: a seat that waits in vain (75) or is cancelled in the queue (143)
# must not have destroyed the last durable result of an earlier attempt.
slot_acquire

if [ "$HAVE_PREAMBLE" -eq 1 ]; then
  cat "$PREAMBLE_FILE" "$PROMPT_FILE" >"$STAGED_PROMPT"
else
  cat "$PROMPT_FILE" >"$STAGED_PROMPT"
fi
rm -f "$MSG_FILE"

printf 'tandem: swarm seat — tier=%s model=%s effort=%s sandbox=%s run=%s seat=%s concurrency=%s\n' \
  "$TIER" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_SANDBOX" "$RUN_ID" "$SEAT" "$ULTRA_CONC" >&2

# Last boundary before spending quota: a signal recorded while the prompt was
# being staged stops the seat here, with no turn started.
sig_honor

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

# Token accounting, BEFORE any check (same rule as codex-start.sh: a seat that
# produced a `turn.completed` burned its quota even if the wrapper rejects it),
# but kept as a LEDGER: retrying a seat overwrites its reply/prompt/events by
# contract, while the tokens the previous attempt spent are already gone. Each
# attempt therefore lands in its own `.t<N>.usage.json` and never overwrites an
# earlier one; the aggregate of a run is the sum of every attempt of every seat.
USAGE_JSON="$(turn_usage "$EVENTS_FILE")"
if [ -n "$USAGE_JSON" ]; then
  USAGE_FILE="$STATE_DIR/$SEAT_KEY.t$(usage_next_index "$STATE_DIR/$SEAT_KEY").usage.json"
  printf 'USAGE: %s\n' "$USAGE_JSON" >&2
  # The path is advertised only once it really landed: the wrapper reports it
  # verbatim, and a footer pointing at a file that does not exist would be worse
  # than an absent one.
  if usage_persist "$USAGE_FILE" "$USAGE_JSON"; then
    printf 'USAGE_FILE: %s\n' "$USAGE_FILE" >&2
  fi
fi

# The accounting is durable from here on, so the recording handlers have done
# their job: RE-ARM the traps to exit directly FIRST — a signal landing during
# the final stretch (result validation, reply emission) must exit as
# 129/130/143, not masquerade as success — and only THEN drain whatever the
# recording handlers caught during the pipeline. Draining before re-arming
# would leave a gap: a signal between the drain and the re-arm would hit the
# old recording handler and stay pending forever.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
sig_honor

if [ "$rc" -ne 0 ]; then
  printf 'tandem: codex exec failed (exit %s). Last stderr lines:\n' "$rc" >&2
  tail -n 20 "$EVENTS_FILE.stderr" >&2 || true
  die "full logs: $EVENTS_FILE and $EVENTS_FILE.stderr" 1
fi
[ -s "$MSG_FILE" ] || die "codex exited 0 but produced no final message — see $EVENTS_FILE" 1

printf '\n--- codex reply (%s, %s/%s) ---\n' "$CODEX_MODEL" "$RUN_ID" "$SEAT"
cat "$MSG_FILE"
printf '\n--- end ---\n'
