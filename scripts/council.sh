#!/usr/bin/env bash
# shellcheck disable=SC2016  # q/upd/jq programs: every single-quoted $name here is jq's
# tandem — the executable contract of the council (/tandem:council).
#
# Three frontier seats of two families weigh an idea and optimise the strategy
# to reach a goal: the session (Opus 5.5) leads, moderates and synthesises;
# Fable 5.1 (a persistent Claude subagent, agents/council-fable*.md) and GPT-6
# Astra (a persistent Codex thread, role `council`) propose blind, cross-examine
# each other and review the synthesis round by round, until consensus or the
# round cap. Every seat is read-only, and the three run at ONE effort level, the
# one of the profile the user chose (exploratorio = high, estandar = xhigh,
# critico = max), frozen with the brief. skills/council/SKILL.md is the protocol;
# THIS script is the part of it no model is trusted to do by itself: anonymous
# letters, sealed contributions, byte-faithful channels, the turn lifecycle,
# attempt and turn caps, the objection ledger and the consensus rule.
#
# usage: council.sh <subcommand> [args…]
#   preflight                                    zero turns; reports EVERY problem
#   init <run-id> [--offline]
#   profile <run-id> <perfil>                    exploratorio | estandar | critico
#   seal <run-id> brief|propose|cross
#   record-agent <run-id> <agent-id> <output-file>
#   astra <run-id> <phase> [--reminder]          the ONLY way an Astra turn starts
#   unblock <run-id> <target>                    by hand only
#   stage <run-id> <phase> <letter> [--with-history | --reminder]
#   capture <run-id> <phase> [--reminder] [--manual]
#   publish <run-id> <phase>
#   ledger <run-id>
#   status <run-id> [--metadata]
#   report <run-id>                              informe.html, after informe.md
#   <phase>  propose | cross | round-<N>     <run-id>  YYYY-MM-DD-<slug>
#
# Paths. DOC_DIR = ${TANDEM_COUNCIL_DIR:-docs/council}/<run-id>, relative to the
# project (CLAUDE_PROJECT_DIR, else $PWD): everything a human reads — brief,
# staged prompts, published answers, syntheses, audits, register, report.
# DOC_DIR/informe.html is a VIEW derived from those Markdown files (`report`):
# never edited by hand, regenerated whenever they change.
# RUN_DIR = .tandem/state/council/runs/<run-id>/ (gitignored): run.json, the
# leader's sealed contributions, Fable's captures. Astra's thread files sit
# next to every other role's, in .tandem/state/council/, one target per
# generation: council-<run-id>-g<G>.
#
# Concurrency. run.json has ONE writer at a time: every subcommand that changes
# it — cap checks and reservations included — takes the run lock (mkdir
# RUN_DIR/.lock + an `owner` file), READS the state inside the lock, writes it
# atomically (temp file + mv) and releases it; the lock is never held while a
# model works. An orphaned lock (only a kill -9 inside a critical section leaves
# one) is cleaned by hand, never reclaimed automatically — the same rule as the
# swarm's slots. `report` is the exception that takes no lock at all: it reads
# run.json once, never writes it, and derives everything from its own snapshot
# of the documents.
#
# env — every TANDEM_COUNCIL_* variable follows the ${VAR+set} discipline:
# defined and empty is a usage error (64), never "unset".
#   TANDEM_COUNCIL_DIR            base of the human-readable artefacts (docs/council)
#   TANDEM_COUNCIL_ROUNDS         review-round cap (default 4)
#   TANDEM_COUNCIL_INTAKE         ask (default) | auto — the skill reads it
#   TANDEM_COUNCIL_MODEL          Astra's model (resolve_role council)
#   TANDEM_COUNCIL_EFFORT         never set by hand: the preflight FAILs on it,
#                                 and `astra` exports it to its own child with
#                                 the profile's level
#   TANDEM_COUNCIL_PROFILE        the profile of an `auto` intake (the skill
#                                 reads it; the preflight checks it is viable)
#   TANDEM_COUNCIL_LEADER_MODEL   the leader the skill expects (default below)
#   TANDEM_COUNCIL_LOCK_TIMEOUT   seconds to wait for the run lock (default 30)
#   TANDEM_CLAUDE_MANAGED_SETTINGS  managed settings file the preflight reads
#                                 (default: the platform's standard path)
#   TANDEM_COUNCIL_REPORT_TEMPLATE  internal, for the tests only: the template
#                                 `report` renders (default
#                                 skills/council/report/informe.tpl.html)
#
# exit codes: 0 ok · 1 condition not met · 2 already exists · 3 missing
#             dependency · 64 usage · 65 integrity · 75 congestion (run lock not
#             acquired, or an Astra turn of the target still alive)
#
# Portable: bash 3.2+ (stock macOS), BSD userland. Dependencies: jq, plus codex
# for the turns and ps for the liveness checks.

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

PLUGIN_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
COUNCIL_PROMPTS="$PLUGIN_ROOT/skills/council/prompts"
COUNCIL_AGENTS_DIR="$PLUGIN_ROOT/agents"
# The ONLY model literal of this script: the leader the skill expects. Fable's
# pin lives in the six agents' frontmatter and is READ from there (fable_pin);
# Astra's default comes from _models.sh through resolve_role.
COUNCIL_LEADER_DEFAULT="claude-opus-5-5"
NL='
'
TAB="$(printf '\t')"

council_usage() {
  cat >&2 <<'EOF'
usage: council.sh <subcommand> [args…]
  preflight
  init <run-id> [--offline]
  profile <run-id> exploratorio|estandar|critico
  seal <run-id> brief|propose|cross
  record-agent <run-id> <agent-id> <output-file>
  astra <run-id> <phase> [--reminder]
  unblock <run-id> <target>
  stage <run-id> <phase> <letter> [--with-history | --reminder]
  capture <run-id> <phase> [--reminder] [--manual]
  publish <run-id> <phase>
  ledger <run-id>
  status <run-id> [--metadata]
  report <run-id>
<phase> = propose | cross | round-<N> · <run-id> = YYYY-MM-DD-<slug>
EOF
  exit "${1:-64}"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

positive_int() {
  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ]
}

# --- environment discipline -------------------------------------------------
LOCK_TIMEOUT=30
council_env_validate() {
  local v
  for v in $(compgen -v TANDEM_COUNCIL_ 2>/dev/null || true); do
    case "$v" in TANDEM_COUNCIL_*) : ;; *) continue ;; esac
    # The preflight reports these two itself, among every other problem: any
    # value of TANDEM_COUNCIL_EFFORT is a FAIL there, and so is an empty
    # TANDEM_COUNCIL_PROFILE.
    if [ "${SUBCMD:-}" = "preflight" ]; then
      case "$v" in TANDEM_COUNCIL_EFFORT | TANDEM_COUNCIL_PROFILE) continue ;; esac
    fi
    [ -n "${!v}" ] \
      || die "$v is set but empty — unset it or give it a value (empty is never \"unset\")" 64
  done
  case "${TANDEM_COUNCIL_LOCK_TIMEOUT+set}" in
    set)
      positive_int "$TANDEM_COUNCIL_LOCK_TIMEOUT" \
        || die "TANDEM_COUNCIL_LOCK_TIMEOUT must be a positive integer of seconds (got: '$TANDEM_COUNCIL_LOCK_TIMEOUT')" 64
      LOCK_TIMEOUT="$((10#$TANDEM_COUNCIL_LOCK_TIMEOUT))"
      ;;
  esac
  return 0
}

# --- identifiers --------------------------------------------------------------
RUN_ID=""
PHASE=""
PHASE_KIND=""
ROUND_N=0

run_id_validate() {
  case "$1" in *"$NL"* | '') die "invalid run id '$1' (expected YYYY-MM-DD-<slug>)" 64 ;; esac
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]*$' \
    || die "invalid run id '$1' (expected YYYY-MM-DD-<slug>: lowercase letters, digits and hyphens)" 64
  RUN_ID="$1"
}

phase_validate() {
  local n
  case "$1" in
    propose | cross)
      PHASE="$1"
      PHASE_KIND="$1"
      ROUND_N=0
      ;;
    round-*)
      n="${1#round-}"
      case "$n" in '' | *[!0-9]* | 0*) die "invalid phase '$1' (expected round-<N>, N >= 1)" 64 ;; esac
      PHASE="$1"
      PHASE_KIND="round"
      ROUND_N="$n"
      ;;
    *) die "unknown phase '$1' (expected propose, cross or round-<N>)" 64 ;;
  esac
}

letter_validate() {
  case "$1" in A | B | C) : ;; *) die "invalid letter '$1' (expected A, B or C)" 64 ;; esac
}

# --- paths --------------------------------------------------------------------
council_paths() {
  local base d
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  # The leader's working directory can move between its Bash calls (real
  # canary, 2026-10-18). With no CLAUDE_PROJECT_DIR, the run is looked for in
  # $PWD and then in each parent, so a call made from a subdirectory of the
  # project — its DOC_DIR, say — still finds the run. init never walks: it
  # creates the run where it is called, and prints that PROJECT for the skill
  # to pin in every later call.
  if [ -z "${CLAUDE_PROJECT_DIR:-}" ] && [ "${SUBCMD:-}" != "init" ] && [ -n "${RUN_ID:-}" ]; then
    d="$PWD"
    while :; do
      if [ -f "$d/.tandem/state/council/runs/$RUN_ID/run.json" ]; then
        PROJECT_DIR="$d"
        break
      fi
      [ "$d" = "/" ] && break
      d="$(dirname -- "$d")"
    done
  fi
  DOC_CONFIG="${TANDEM_COUNCIL_DIR:-docs/council}"
  base="$DOC_CONFIG"
  case "$base" in /*) : ;; *) base="$PROJECT_DIR/$base" ;; esac
  while [ "${base%/}" != "$base" ] && [ "$base" != "/" ]; do base="${base%/}"; done
  DOC_BASE="$base"
  DOC_DIR="$DOC_BASE/$RUN_ID"
  DOC_REL=""
  case "$DOC_DIR" in "$PROJECT_DIR"/*) DOC_REL="${DOC_DIR#"$PROJECT_DIR"/}" ;; esac
  STATE_DIR="$PROJECT_DIR/.tandem/state/council"
  RUN_DIR="$STATE_DIR/runs/$RUN_ID"
  RUN_REL=".tandem/state/council/runs/$RUN_ID"
  RUN_JSON="$RUN_DIR/run.json"
}

published_path() {
  # published_path <phase> <letter>
  case "$1" in
    propose) printf '%s' "$DOC_DIR/1-propuestas/$2.md" ;;
    cross) printf '%s' "$DOC_DIR/2-contrainterrogatorio/$2.md" ;;
    round-*) printf '%s' "$DOC_DIR/rondas/r${1#round-}-$2.md" ;;
  esac
}

prompt_path() {
  # prompt_path <phase> <letter> <attempt> <reminder 0|1>
  if [ "$4" = "1" ]; then
    printf '%s' "$DOC_DIR/prompts/$1-$2.a$3.reminder.md"
  else
    printf '%s' "$DOC_DIR/prompts/$1-$2.a$3.md"
  fi
}

fable_file() {
  # fable_file <phase> <attempt> <reminder 0|1> <reply|usage>
  local suffix="reply.md"
  [ "$4" = "usage" ] && suffix="usage.json"
  if [ "$3" = "1" ]; then
    printf '%s' "$RUN_DIR/fable.$1.a$2.reminder.$suffix"
  else
    printf '%s' "$RUN_DIR/fable.$1.a$2.$suffix"
  fi
}

# --- run state (in memory, persisted atomically) ------------------------------
STATE=""
STATE_TMP=""

q() { printf '%s\n' "$STATE" | jq "$@"; }

upd() {
  local next
  next="$(printf '%s\n' "$STATE" | jq -c "$@")" || die "internal error: a run-state update failed" 65
  [ -n "$next" ] || die "internal error: a run-state update produced nothing" 65
  STATE="$next"
}

state_load() {
  [ -f "$RUN_JSON" ] || die "no council run '$RUN_ID' ($RUN_JSON) — start it with: council.sh init $RUN_ID" 1
  STATE="$(jq -c . "$RUN_JSON" 2>/dev/null)" || STATE=""
  [ -n "$STATE" ] || die "run.json is not valid JSON: $RUN_JSON — inspect it by hand" 65
  local rec
  rec="$(q -r '.doc_dir_config // empty')"
  if [ -n "$rec" ] && [ "$rec" != "$DOC_CONFIG" ]; then
    die "run '$RUN_ID' was initialised with TANDEM_COUNCIL_DIR=$rec, but it now resolves to $DOC_CONFIG — use the same value for the whole run" 64
  fi
  return 0
}

state_save() {
  STATE_TMP="$(mktemp "$RUN_DIR/.run.json.XXXXXX" 2>/dev/null)" \
    || die "cannot create a temp file in $RUN_DIR" 65
  if printf '%s\n' "$STATE" | jq . >"$STATE_TMP" 2>/dev/null \
    && mv -f "$STATE_TMP" "$RUN_JSON"; then
    STATE_TMP=""
    return 0
  fi
  rm -f "$STATE_TMP" 2>/dev/null || true
  STATE_TMP=""
  die "could not write $RUN_JSON" 65
}

run_require() {
  [ -f "$RUN_JSON" ] || die "no council run '$RUN_ID' ($RUN_JSON) — start it with: council.sh init $RUN_ID" 1
}

seat_letter() { q -r --arg s "$1" '[.letters | to_entries[] | select(.value == $s) | .key][0] // empty'; }
letter_seat() { q -r --arg l "$1" '.letters[$l] // empty'; }

# --- processes ----------------------------------------------------------------
# proc_lstart <pid> — the process start time, the second half of a process
# IDENTITY (a pid alone can be reused). C locale so two calls always agree.
proc_lstart() {
  local out
  command -v ps >/dev/null 2>&1 || return 1
  out="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | LC_ALL=C tr -s ' \t' '  ' | LC_ALL=C sed -e 's/^ //' -e 's/ $//')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

SELF_LSTART=""
SELF_LSTART_DONE=0
self_lstart() {
  if [ "$SELF_LSTART_DONE" -eq 0 ]; then
    SELF_LSTART="$(proc_lstart "$$" || true)"
    SELF_LSTART_DONE=1
  fi
  printf '%s' "$SELF_LSTART"
}

# --- the run lock ---------------------------------------------------------------
LOCK_DIR=""
LOCK_HELD=0

lock_acquire() {
  local tries=$((LOCK_TIMEOUT * 10)) i=0 owner lst
  LOCK_DIR="$RUN_DIR/.lock"
  lst="$(self_lstart)"
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      printf 'pid=%s\nlstart=%s\ncommand=council.sh %s %s\n' "$$" "$lst" "$SUBCMD" "$RUN_ID" \
        >"$LOCK_DIR/owner" 2>/dev/null || true
      return 0
    fi
    [ "$i" -ge "$tries" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  owner="$(LC_ALL=C tr '\n' ' ' <"$LOCK_DIR/owner" 2>/dev/null || true)"
  die "run lock not acquired within ${LOCK_TIMEOUT}s: $LOCK_DIR (owner: ${owner:-unknown}) — it is never reclaimed automatically; remove it by hand only once no council.sh process of this run is alive" 75
}

lock_release() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    LOCK_HELD=0
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
  return 0
}

REPORT_DIR=""
REPORT_TMP=""
council_on_exit() {
  local rc=$?
  [ -n "${STATE_TMP:-}" ] && rm -f "$STATE_TMP" 2>/dev/null
  # report's snapshot and its half-composed informe.html, also on an error.
  if [ -n "${REPORT_TMP:-}" ]; then rm -f "$REPORT_TMP" 2>/dev/null || true; fi
  if [ -n "${REPORT_DIR:-}" ]; then rm -rf "$REPORT_DIR" 2>/dev/null || true; fi
  lock_release
  exit "$rc"
}
trap 'council_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- small file helpers -------------------------------------------------------
# emit_section <label> <file> — one input under its fixed delimiter line,
# byte for byte; a final newline is added only when the content lacks one, so
# the next delimiter always starts a line.
emit_section() {
  printf '===== %s =====\n' "$1"
  cat "$2"
  if [ -s "$2" ] && [ -n "$(tail -c 1 "$2")" ]; then printf '\n'; fi
}

write_atomic() {
  # write_atomic <dest> <source-file> — rename into place; the source is consumed.
  mv -f "$2" "$1" || { rm -f "$2"; die "could not write $1" 65; }
}

counter_of() {
  # counter_of <key> — the wrapper's turn counter, sanitized exactly as the
  # wrappers do (anything but digits reads as 0).
  local t
  t="$(cat "$STATE_DIR/$1.turn" 2>/dev/null || printf '0')"
  t="$(printf '%s' "$t" | LC_ALL=C tr -d '[:space:]')"
  case "$t" in '' | *[!0-9]*) t=0 ;; esac
  printf '%s' "$((10#$t))"
}

receipt_valid() {
  # receipt_valid <key> <turn> — the wrapper's success receipt for THAT turn,
  # and the reply on disk still has the bytes it certified.
  local key="$1" n="$2" r sha want rturn
  r="$STATE_DIR/$key.t$n.ok"
  [ -f "$r" ] || return 1
  want="$(jq -r '.reply_sha256 // empty' "$r" 2>/dev/null)" || return 1
  rturn="$(jq -r '.turn // empty' "$r" 2>/dev/null)" || return 1
  [ -n "$want" ] && [ "$rturn" = "$n" ] || return 1
  sha="$(file_sha256 "$STATE_DIR/$key.t$n.reply.txt")" || return 1
  [ "$sha" = "$want" ]
}

# --- liveness of an Astra turn --------------------------------------------------
# A turn is alive if its driver or its wrapper is alive — same pid AND same
# lstart, so a reused pid never counts — or if any process carries one of the
# turn's three argv signatures: council-astra-<launch_token> (the wrapper of
# THAT launch and its forks), `codex-start.sh council <target>` /
# `codex-resume.sh council <target>` (any wrapper of the target, also while it
# initialises), and the turn's --output-last-message, <key>.t<turn_before+1>.reply.txt
# (codex itself, orphaned or not). The scan takes ONE snapshot of ps into a temp
# file and matches it IN THIS PROCESS with `case` — no grep carrying the
# signature in its own argv — skipping this process: neither it nor its probing
# subprocesses can count as alive.

pid_identity() {
  # pid_identity <pid> <lstart> → 0 same process alive · 1 gone/another · 2 unknown
  local pid="${1:-}" want="${2:-}" got
  case "$pid" in '' | null | *[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  got="$(proc_lstart "$pid")" || return 2
  [ -n "$want" ] || return 2
  [ "$got" = "$want" ] && return 0
  return 1
}

scan_signatures() {
  # scan_signatures <token> <target> <key> <turn> → 0 alive · 1 none · 2 unknown
  local token="$1" target="$2" key="$3" n="$4" snap line pid cmd found=1
  command -v ps >/dev/null 2>&1 || return 2
  snap="$(mktemp "$RUN_DIR/.ps.XXXXXX" 2>/dev/null)" || return 2
  if ! LC_ALL=C ps -A -ww -o pid= -o command= >"$snap" 2>/dev/null || [ ! -s "$snap" ]; then
    rm -f "$snap"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    cmd="${line#"$pid"}"
    # Three independent signatures: each one is checked on every line.
    if [ -n "$token" ]; then
      case "$cmd" in *"council-astra-$token"*) found=0 ;; esac
    fi
    case "$cmd" in
      *"codex-start.sh council $target "* | *"codex-start.sh council $target" \
        | *"codex-resume.sh council $target "* | *"codex-resume.sh council $target")
        found=0
        ;;
    esac
    case "$cmd" in *"/$key.t$n.reply.txt"*) found=0 ;; esac
    [ "$found" -eq 0 ] && break
  done <"$snap"
  rm -f "$snap"
  return "$found"
}

entry_liveness() {
  # entry_liveness <index> → 0 alive · 1 dead · 2 unknown
  local i="$1" e dpid dl wpid wl token target key tb rc unknown=0
  e="$(q -c --argjson i "$i" '.astra_turns[$i]')"
  dpid="$(printf '%s' "$e" | jq -r '.driver.pid // empty')"
  dl="$(printf '%s' "$e" | jq -r '.driver.lstart // empty')"
  wpid="$(printf '%s' "$e" | jq -r '.wrapper.pid // empty')"
  wl="$(printf '%s' "$e" | jq -r '.wrapper.lstart // empty')"
  token="$(printf '%s' "$e" | jq -r '.launch_token // empty')"
  target="$(printf '%s' "$e" | jq -r '.target')"
  tb="$(printf '%s' "$e" | jq -r '.turn_before')"
  key="$(target_key "$target")"
  rc=0
  pid_identity "$dpid" "$dl" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && unknown=1
  if [ -n "$wpid" ]; then
    rc=0
    pid_identity "$wpid" "$wl" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && unknown=1
  fi
  rc=0
  scan_signatures "$token" "$target" "$key" "$((tb + 1))" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && unknown=1
  [ "$unknown" -eq 1 ] && return 2
  return 1
}

# classify_dead <index> <annotation> — the evidence of a turn whose processes
# are all gone: counter unchanged → no turn; advanced by one WITH its receipt
# (and the certified bytes) → done (recovered); advanced by one without → the
# turn was rejected or cut; anything else cannot be told apart → bloqueada.
# Returns 0 when classified, 1 when it stays bloqueada.
classify_dead() {
  local i="$1" note="$2" target key tb now
  target="$(q -r --argjson i "$i" '.astra_turns[$i].target')"
  tb="$(q -r --argjson i "$i" '.astra_turns[$i].turn_before')"
  key="$(target_key "$target")"
  now="$(counter_of "$key")"
  if [ "$now" -eq "$tb" ]; then
    upd --argjson i "$i" --arg note "$note" --arg t "$(now_utc)" \
      '.astra_turns[$i] |= (.estado = "interrupted" | .turno = null | .recuperado = true
        | .nota = "contador sin avanzar: no hubo turno" | .resolucion = $note | .fin = (.fin // $t))'
    return 0
  fi
  if [ "$now" -eq "$((tb + 1))" ]; then
    if receipt_valid "$key" "$now"; then
      upd --argjson i "$i" --argjson n "$now" --arg note "$note" --arg t "$(now_utc)" \
        '.astra_turns[$i] |= (.estado = "done" | .turno = $n | .recuperado = true
          | .nota = "recibo del wrapper presente" | .resolucion = $note | .fin = (.fin // $t))'
    else
      upd --argjson i "$i" --argjson n "$now" --arg note "$note" --arg t "$(now_utc)" \
        '.astra_turns[$i] |= (.estado = "interrupted" | .turno = $n | .recuperado = true
          | .nota = "turno sin recibo: rechazado o cortado" | .resolucion = $note | .fin = (.fin // $t))'
    fi
    return 0
  fi
  upd --argjson i "$i" --argjson n "$now" \
    '.astra_turns[$i] |= (.estado = "bloqueada"
      | .nota = "el contador avanzó más de uno (\(.turn_before) → \($n)): revisar el estado a mano")'
  return 1
}

# recover_entries <target or ""> — automatic recovery, UNDER THE LOCK, of every
# `running` entry (of one target, or of the whole run). Sets RECOVER_ALIVE and
# RECOVER_BLOCKED, both scoped to the same filter.
RECOVER_ALIVE=0
RECOVER_BLOCKED=0
recover_entries() {
  local filter="$1" idx rc
  RECOVER_ALIVE=0
  for idx in $(q -r --arg t "$filter" '.astra_turns | to_entries[]
      | select(.value.estado == "running" and ($t == "" or .value.target == $t)) | .key'); do
    if [ "$(q -r --argjson i "$idx" '.astra_turns[$i].wrapper == null')" = "true" ]; then
      upd --argjson i "$idx" '.astra_turns[$i] |= (.estado = "bloqueada"
        | .nota = "entrada sin wrapper registrado (lock huérfano limpiado a mano): solo unblock la resuelve")'
      continue
    fi
    rc=0
    entry_liveness "$idx" || rc=$?
    case "$rc" in
      0) RECOVER_ALIVE=$((RECOVER_ALIVE + 1)) ;;
      2)
        upd --argjson i "$idx" '.astra_turns[$i] |= (.estado = "bloqueada"
          | .nota = "liveness imposible de establecer (ps no disponible o fallido)")'
        ;;
      *) classify_dead "$idx" "recuperada automáticamente" || true ;;
    esac
  done
  RECOVER_BLOCKED="$(q -r --arg t "$filter" '[.astra_turns[]
    | select(.estado == "bloqueada" and ($t == "" or .target == $t))] | length')"
  return 0
}

# --- the line parser shared by stage, ledger, status and report ---------------
# Line formats (skills/council/prompts/seat-rules.md): objection
# `- [B-3] [P2] <title>`, own status `- [B-3] RESUELTA: <reason>` /
# `- [B-3] NO RESUELTA: <reason>`, reopen `- [REABRE B-3] <argument>`, register
# row `| B-3 | P2 | ACEPTADA | <where / why> |`. Only a seat's OWN letter
# counts in its own answers: a quoted foreign ID is a reference, not a claim.
# shellcheck disable=SC2016  # jq programs: their $names belong to jq
COUNCIL_JQ='
def m1(re): [capture(re)] | .[0];
def rx_obj: "^\\s*- \\[(?<l>[A-C])-(?<n>[0-9]+)\\] \\[(?<s>P[1-3])\\]\\s+(?<t>.*?)\\s*$";
def rx_st: "^\\s*- \\[(?<l>[A-C])-(?<n>[0-9]+)\\] (?<st>NO RESUELTA|RESUELTA):(?<m>.*?)\\s*$";
def rx_re: "^\\s*- \\[REABRE (?<l>[A-C])-(?<n>[0-9]+)\\](?<a>.*?)\\s*$";
def sevrank: if . == "P1" then 1 elif . == "P2" then 2 else 3 end;
def oid($l; $n): "\($l)-\($n | tonumber)";
def objections:
  sort_by(.author, .order)
  | reduce .[] as $d ({};
      reduce $d.lines[] as $line (.;
        ($line | m1(rx_obj)) as $o
        | ($line | m1(rx_st)) as $s
        | ($line | m1(rx_re)) as $r
        | if $o != null and $o.l == $d.author then
            oid($o.l; $o.n) as $id
            | if has($id) then
                (if ($o.s | sevrank) < (.[$id].sev | sevrank) then .[$id].sev = $o.s else . end)
              else
                .[$id] = {id: $id, author: $o.l, n: ($o.n | tonumber), sev: $o.s, title: $o.t,
                          phase: $d.phase, status: "PENDIENTE", reason: null}
              end
          elif $s != null and $s.l == $d.author and has(oid($s.l; $s.n)) then
            oid($s.l; $s.n) as $id
            | .[$id].status = $s.st | .[$id].reason = ($s.m | sub("^\\s+"; ""))
          elif $r != null and $r.l == $d.author and has(oid($r.l; $r.n)) then
            oid($r.l; $r.n) as $id
            | .[$id].status = "PENDIENTE" | .[$id].reason = null
          else . end));
def lastline: [.lines[] | sub("\\s+$"; "") | select(length > 0)] | last // "";
def verdict: (lastline | m1("^VERDICT: (?<v>APPROVED|REVISE)$")) as $v | if $v == null then null else $v.v end;
def has_riesgo: any(.lines[]; test("^\\s*(-\\s+)?RIESGO RESIDUAL:"));
def riesgo: [ .lines[] | m1("^\\s*(-\\s+)?RIESGO RESIDUAL:(?<t>.*?)\\s*$") | select(. != null)
              | .t | sub("^\\s+"; "") ] | first;
def indent_of: capture("^(?<w>\\s*)").w | length;
# detail_of($docs) — on an objection: the lines indented deeper than its own
# line that follow it in the answer that declared it (Escenario, Evidencia,
# Propuesta…), up to the first line that is not; a blank line belongs to the
# detail only when more indentation follows it.
def detail_of($docs):
  . as $o
  | ([ $docs[] | select(.author == $o.author and .phase == $o.phase) ] | first) as $d
  | if $d == null then "" else
      $d.lines as $L
      | ([ range(0; $L | length) as $i
           | ($L[$i] | m1(rx_obj)) as $m
           | select($m != null and $m.l == $o.author and oid($m.l; $m.n) == $o.id) | $i ] | first) as $at
      | if $at == null then "" else
          ($L[$at] | indent_of) as $k
          | (reduce range($at + 1; $L | length) as $j ({out: [], pend: [], stop: false};
              if .stop then .
              elif ($L[$j] | test("^\\s*$")) then .pend += [$L[$j]]
              elif ($L[$j] | indent_of) > $k then .out += .pend + [$L[$j]] | .pend = []
              else .stop = true end)).out
          | join("\n")
        end
    end;
# events — the history behind objections: every OWN line of a new objection, a
# status or a REABRE, in author and phase order, under the same rules as
# objections (a quoted foreign ID is a reference; a status or a REABRE counts
# once its objection exists). objections stays the source of the final status;
# events decides nothing.
def events:
  sort_by(.author, .order)
  | reduce .[] as $d ({seen: {}, ev: []};
      reduce $d.lines[] as $line (.;
        ($line | m1(rx_obj)) as $o
        | ($line | m1(rx_st)) as $s
        | ($line | m1(rx_re)) as $r
        | if $o != null and $o.l == $d.author then
            oid($o.l; $o.n) as $id
            | .seen[$id] = true
            | .ev += [{id: $id, author: $d.author, phase: $d.phase, kind: "NUEVA", sev: $o.s, text: $o.t}]
          elif $s != null and $s.l == $d.author and (.seen | has(oid($s.l; $s.n))) then
            .ev += [{id: oid($s.l; $s.n), author: $d.author, phase: $d.phase, kind: $s.st,
                     text: ($s.m | sub("^\\s+"; ""))}]
          elif $r != null and $r.l == $d.author and (.seen | has(oid($r.l; $r.n))) then
            .ev += [{id: oid($r.l; $r.n), author: $d.author, phase: $d.phase, kind: "REABRE",
                     text: ($r.a | sub("^\\s+"; ""))}]
          else . end))
  | .ev;
# rounds_of($r1; $r2) — every round with BOTH reviewer answers published, and
# what each reviewer published in it.
def rounds_of($r1; $r2):
  [ .[] | select(.phase | test("^round-[0-9]+$")) ]
  | group_by(.phase | ltrimstr("round-") | tonumber)
  | map(select(any(.[]; .author == $r1) and any(.[]; .author == $r2)))
  | map({n: (.[0].phase | ltrimstr("round-") | tonumber),
         verdicts: ([ .[] | select(.author == $r1 or .author == $r2)
                      | {letra: .author, verdict: verdict, riesgo: riesgo} ] | sort_by(.letra))});
# sources_of($file) — on the lines of an audit: its `- [F<n>] VERIFICADA|NO
# ACCESIBLE|NO CONFIRMA <src> — <desc>` lines, split at the first « — », and
# whether it is the offline audit (`- OFFLINE: no aplica`).
def sources_of($file):
  { file: $file,
    offline: any(.[]; test("^\\s*- OFFLINE: no aplica\\s*$")),
    items: [ .[] | m1("^\\s*-\\s+\\[(?<id>F[0-9]+)\\]\\s+(?<status>VERIFICADA|NO ACCESIBLE|NO CONFIRMA)\\s+(?<rest>.*?)\\s*$")
             | select(. != null)
             | (.rest | m1("^(?<src>.*?) — (?<desc>.*)$")) as $p
             | {id, status,
                src: (if $p == null then .rest else $p.src end),
                desc: (if $p == null then "" else $p.desc end)} ] };
def rows:
  [ .[] | sub("\\s+$"; "") | select(test("^\\|.*\\|$"))
    | split("|") | .[1:-1] | map(sub("^\\s+"; "") | sub("\\s+$"; ""))
    | select(length >= 4 and (.[0] | test("^[A-C]-[0-9]+$")))
    | {id: (.[0] | capture("^(?<l>[A-C])-(?<n>[0-9]+)$") | oid(.l; .n)),
       sev: .[1], disp: .[2], why: (.[3:] | join("|"))} ];
def ledger_problems($objs; $rows):
  ($rows | group_by(.id) | map({key: .[0].id, value: length}) | from_entries) as $count
  | [ $objs[] | select(($count[.id] // 0) == 0)
      | "\(.id) [\(.sev)] de \(.author): no aparece en ninguna fila de registro.md" ]
  + [ $count | to_entries[] | select(.value > 1)
      | "\(.key): aparece en \(.value) filas de registro.md (debe haber exactamente una)" ]
  + [ $rows[] | select(.disp | IN("ACEPTADA", "RECHAZADA", "ABIERTA") | not)
      | "\(.id): disposición «\(.disp)» fuera del conjunto ACEPTADA | RECHAZADA | ABIERTA" ]
  + [ $rows[] | . as $r | ($objs[$r.id] // null) as $o
      | select($o != null and $o.sev != $r.sev)
      | "\($r.id): severidad \($r.sev) en el registro, pero su autor la declaró \($o.sev)" ]
  + [ $rows[] | select(($objs[.id] // null) == null)
      | "\(.id): fila sin ninguna objeción publicada con ese ID" ]
  + [ $rows[] | select(.why == "") | "\(.id): fila sin «dónde / por qué»" ];
'

# doc_json <author> <order> <phase> <file> — one published answer for the parser.
doc_json() {
  jq -Rsc --arg a "$1" --argjson o "$2" --arg p "$3" --arg f "$4" \
    '{author: $a, order: $o, phase: $p, file: $f, lines: split("\n")}' "$4"
}

# docs_json — every published answer, as the parser's input array.
docs_json() {
  local tmp L f n
  tmp="$(mktemp "$RUN_DIR/.docs.XXXXXX")" || die "cannot create a temp file in $RUN_DIR" 65
  for L in A B C; do
    f="$(published_path propose "$L")"
    [ -f "$f" ] && doc_json "$L" 1 propose "$f" >>"$tmp"
    f="$(published_path cross "$L")"
    [ -f "$f" ] && doc_json "$L" 2 cross "$f" >>"$tmp"
    for f in "$DOC_DIR/rondas/r"*"-$L.md"; do
      [ -f "$f" ] || continue
      n="${f##*/r}"
      n="${n%-"$L".md}"
      case "$n" in '' | *[!0-9]*) continue ;; esac
      doc_json "$L" "$((2 + 10#$n))" "round-$((10#$n))" "$f" >>"$tmp"
    done
  done
  jq -sc '.' "$tmp"
  rm -f "$tmp"
}

registro_json() {
  # registro_json — the register's lines as a JSON array ([] when absent).
  if [ -f "$DOC_DIR/registro.md" ]; then
    jq -Rsc 'split("\n")' "$DOC_DIR/registro.md"
  else
    printf '[]'
  fi
}

# audit_problem <N> — prints why auditoria-v<N>.md does not allow a round, or
# nothing when it does: it must exist, carry no NO CONFIRMA line and, offline,
# carry the `- OFFLINE: no aplica` line.
audit_problem() {
  local f="$DOC_DIR/auditoria-v$1.md" mode
  mode="$(q -r '.mode')"
  if [ ! -f "$f" ]; then
    printf 'auditoria-v%s.md no existe (%s)' "$1" "$f"
    return 0
  fi
  if LC_ALL=C grep -q 'NO CONFIRMA' "$f"; then
    printf 'auditoria-v%s.md tiene una línea NO CONFIRMA: corrige la síntesis y vuelve a auditar' "$1"
    return 0
  fi
  if [ "$mode" = "offline" ] && ! LC_ALL=C grep -Eq '^[[:space:]]*- OFFLINE: no aplica[[:space:]]*$' "$f"; then
    printf 'auditoria-v%s.md no trae la línea «- OFFLINE: no aplica» (run offline)' "$1"
    return 0
  fi
  return 0
}

# --- effort profiles ------------------------------------------------------------
# ONE table: a profile fixes a single level for the three seats — leader, Fable
# and Astra — and names Fable's agent pair of that level. Machine names carry no
# accent; the skill and the human documents show them with one.
COUNCIL_PROFILES="exploratorio estandar critico"

profile_level() {
  # profile_level <name> → high | xhigh | max; any other name → 64.
  case "${1:-}" in
    exploratorio) printf 'high' ;;
    estandar) printf 'xhigh' ;;
    critico) printf 'max' ;;
    *) return 64 ;;
  esac
}

profile_display() {
  case "${1:-}" in
    exploratorio) printf 'exploratorio' ;;
    estandar) printf 'estándar' ;;
    critico) printf 'crítico' ;;
    *) printf '%s' "${1:-?}" ;;
  esac
}

level_base() {
  # level_base <level> — the agent file stem of that level's pair. The max pair
  # keeps its 0.37 name, so a run created then recovers with the same type.
  case "$1" in
    max) printf 'council-fable' ;;
    xhigh) printf 'council-fable-xhigh' ;;
    high) printf 'council-fable-high' ;;
    *) return 1 ;;
  esac
}

profile_agent() {
  # profile_agent <name> <web|offline> → Fable's subagent_type for that profile.
  local level base
  level="$(profile_level "$1")" || return 64
  base="$(level_base "$level")" || return 64
  if [ "${2:-web}" = "offline" ]; then
    printf 'tandem:%s-offline' "$base"
  else
    printf 'tandem:%s' "$base"
  fi
}

level_rank() {
  # level_rank <level> — low < medium < high < xhigh < max; anything else 0.
  case "${1:-}" in
    low) printf 1 ;;
    medium) printf 2 ;;
    high) printf 3 ;;
    xhigh) printf 4 ;;
    max) printf 5 ;;
    *) printf 0 ;;
  esac
}

# run_profile — the profile of the loaded run: run.json's `perfil`, or, for a
# run.json without one whose brief is already sealed (created with 0.37),
# critico, marked implicit. Sets RUN_PROFILE (empty: none chosen yet),
# RUN_LEVEL, RUN_AGENT and RUN_PROFILE_IMPLICIT (0|1).
RUN_PROFILE=""
RUN_LEVEL=""
RUN_AGENT=""
RUN_PROFILE_IMPLICIT=0
run_profile() {
  local mode
  RUN_PROFILE="$(q -r '.perfil.nombre // empty')"
  RUN_LEVEL=""
  RUN_AGENT=""
  RUN_PROFILE_IMPLICIT=0
  mode="$(q -r '.mode // "web"')"
  if [ -n "$RUN_PROFILE" ]; then
    RUN_LEVEL="$(q -r '.perfil.esfuerzo // empty')"
    RUN_AGENT="$(q -r '.perfil.agente // empty')"
    [ -n "$RUN_LEVEL" ] || RUN_LEVEL="$(profile_level "$RUN_PROFILE" || true)"
    [ -n "$RUN_AGENT" ] || RUN_AGENT="$(profile_agent "$RUN_PROFILE" "$mode" || true)"
    if [ -z "$RUN_LEVEL" ] || [ -z "$RUN_AGENT" ]; then
      die "run.json names an unknown profile '$RUN_PROFILE'" 65
    fi
    return 0
  fi
  if [ -n "$(q -r '.seals.brief.sha256 // empty')" ]; then
    RUN_PROFILE="critico"
    RUN_LEVEL="max"
    RUN_AGENT="$(profile_agent critico "$mode")"
    RUN_PROFILE_IMPLICIT=1
  fi
  return 0
}

# --- Fable's pin, read from the agents ----------------------------------------
fm_value() {
  # fm_value <file> <key> — one frontmatter value, trimmed and unquoted.
  local f="$1" key="$2" line n=0 v
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [ "$n" -eq 1 ]; then
      [ "$line" = "---" ] || return 1
      continue
    fi
    [ "$line" = "---" ] && return 1
    case "$line" in
      "$key:"*)
        v="${line#"$key:"}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        v="${v#\"}"
        v="${v%\"}"
        v="${v#\'}"
        v="${v%\'}"
        printf '%s' "$v"
        return 0
        ;;
    esac
  done <"$f"
  return 1
}

# fable_models — the six agents exist and declare ONE full model id. Sets
# FABLE_MODEL, or FABLE_PIN_ERR with the reason it cannot be trusted.
FABLE_MODEL=""
fable_models() {
  local level base f m missing="" models="" first=""
  FABLE_MODEL=""
  FABLE_PIN_ERR=""
  for level in max xhigh high; do
    base="$(level_base "$level")"
    for f in "$base.md" "$base-offline.md"; do
      if [ ! -f "$COUNCIL_AGENTS_DIR/$f" ]; then
        missing="$missing${missing:+, }$f"
        continue
      fi
      m="$(fm_value "$COUNCIL_AGENTS_DIR/$f" model || true)"
      models="$models${models:+, }$f model=${m:-?}"
      [ -n "$first" ] || first="${m:-?}"
      [ "$m" = "$first" ] || first="!"
    done
  done
  if [ -n "$missing" ]; then
    FABLE_PIN_ERR="missing agent definition(s) under $COUNCIL_AGENTS_DIR: $missing"
    return 1
  fi
  if [ "$first" = "!" ]; then
    FABLE_PIN_ERR="the six agents disagree on the model: $models"
    return 1
  fi
  case "$first" in
    '' | '?') FABLE_PIN_ERR="agents/council-fable*.md declare no model"; return 1 ;;
    fable | opus | sonnet | haiku | inherit)
      FABLE_PIN_ERR="agents/council-fable*.md pin the alias '$first', not a full model id (an alias can resolve to another generation)"
      return 1
      ;;
  esac
  FABLE_MODEL="$first"
  return 0
}

# fable_pair <level> — the pair of that level: both twins declare that effort.
# Sets FABLE_PIN_ERR when they do not.
fable_pair() {
  local level="$1" base ea eb
  base="$(level_base "$level")" || { FABLE_PIN_ERR="no agent pair for level '$level'"; return 1; }
  ea="$(fm_value "$COUNCIL_AGENTS_DIR/$base.md" effort || true)"
  eb="$(fm_value "$COUNCIL_AGENTS_DIR/$base-offline.md" effort || true)"
  if [ "$ea" != "$eb" ]; then
    FABLE_PIN_ERR="the twins disagree: $base.md effort=${ea:-?}, $base-offline.md effort=${eb:-?}"
    return 1
  fi
  if [ "$ea" != "$level" ]; then
    FABLE_PIN_ERR="$base.md and $base-offline.md declare effort=${ea:-?}, not $level"
    return 1
  fi
  return 0
}

FABLE_PIN=""
FABLE_PIN_ERR=""
fable_pin() {
  # fable_pin <level> — the six agents agree on ONE full model id and the pair
  # of <level> declares that effort: sets FABLE_PIN, or FABLE_PIN_ERR.
  FABLE_PIN=""
  fable_models || return 1
  fable_pair "$1" || return 1
  FABLE_PIN="$FABLE_MODEL"
  return 0
}

# --- the environment a profile needs --------------------------------------------
managed_settings_path() {
  case "${TANDEM_CLAUDE_MANAGED_SETTINGS+set}" in
    set) printf '%s' "$TANDEM_CLAUDE_MANAGED_SETTINGS" ;;
    *)
      case "$(uname -s 2>/dev/null)" in
        Darwin) printf '%s' "/Library/Application Support/ClaudeCode/managed-settings.json" ;;
        *) printf '%s' "/etc/claude-code/managed-settings.json" ;;
      esac
      ;;
  esac
}

# settings_caps — one line per settings file in scope that exists:
# `<value>\t<file>` with its maxEffortLevel ('' when it declares none), or
# `!\t<file>` when it cannot be parsed (or jq is missing).
settings_caps() {
  local f val managed
  managed="$(managed_settings_path)"
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    "$PROJECT_DIR/.claude/settings.json" "$PROJECT_DIR/.claude/settings.local.json" "$managed"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if ! command -v jq >/dev/null 2>&1 \
      || ! val="$(jq -r 'if type == "object" and has("maxEffortLevel") then (.maxEffortLevel | tostring) else "" end' "$f" 2>/dev/null)"; then
      printf '!\t%s\n' "$f"
      continue
    fi
    printf '%s\t%s\n' "$val" "$f"
  done
}

# astra_catalog — Astra's model in the catalog of `codex debug models`. Sets
# ASTRA_LEVELS (its supported efforts, space-separated), or ASTRA_CAT_ERR.
ASTRA_LEVELS=""
ASTRA_CAT_ERR=""
astra_catalog() {
  local catalog rc=0
  ASTRA_LEVELS=""
  ASTRA_CAT_ERR=""
  resolve_role council
  if ! command -v jq >/dev/null 2>&1; then
    ASTRA_CAT_ERR="jq not found — the run cannot work and the catalog cannot be read (install: brew install jq)"
    return 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    ASTRA_CAT_ERR="Astra model catalog unavailable: codex CLI not found in PATH"
    return 1
  fi
  catalog="$(codex debug models 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$catalog" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
    ASTRA_CAT_ERR="Astra model catalog unavailable: 'codex debug models' failed or did not print {\"models\":[…]} (rc $rc)"
    return 1
  fi
  if ! printf '%s' "$catalog" | jq -e --arg m "$CODEX_MODEL" 'any(.models[]; .slug == $m)' >/dev/null 2>&1; then
    ASTRA_CAT_ERR="Astra model '$CODEX_MODEL' is not in the catalog of 'codex debug models' — fix TANDEM_COUNCIL_MODEL"
    return 1
  fi
  ASTRA_LEVELS="$(printf '%s' "$catalog" | jq -r --arg m "$CODEX_MODEL" \
    '[.models[] | select(.slug == $m) | .supported_reasoning_levels[]?.effort | strings] | join(" ")' 2>/dev/null || true)"
  return 0
}

# profile_env_check <level> <mode> [astra] — everything the frozen profile
# needs from THIS environment, which can be another session's after a recovery:
# CLAUDE_CODE_EFFORT_LEVEL, maxEffortLevel in the settings in scope,
# TANDEM_COUNCIL_EFFORT, the pin of Fable's pair of that level and, with
# `astra`, the Codex catalog. Sets PROFILE_CAUSES (one cause per line); 0 when
# there is none. It never writes anything.
PROFILE_CAUSES=""
profile_env_check() {
  local level="$1" with_astra="${3:-}" line val f cap
  PROFILE_CAUSES=""
  case "${CLAUDE_CODE_EFFORT_LEVEL+set}" in
    set)
      [ "$CLAUDE_CODE_EFFORT_LEVEL" = "$level" ] \
        || PROFILE_CAUSES="${PROFILE_CAUSES}CLAUDE_CODE_EFFORT_LEVEL='$CLAUDE_CODE_EFFORT_LEVEL' overrides the profile's level $level for Fable and the leader$NL"
      ;;
  esac
  cap="$(level_rank "$level")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    val="${line%%"$TAB"*}"
    f="${line#*"$TAB"}"
    if [ "$val" = "!" ]; then
      PROFILE_CAUSES="${PROFILE_CAUSES}cannot parse $f as JSON — maxEffortLevel cannot be verified$NL"
    elif [ -n "$val" ] && [ "$(level_rank "$val")" -lt "$cap" ]; then
      PROFILE_CAUSES="${PROFILE_CAUSES}maxEffortLevel='$val' in $f caps the seats and the leader below $level$NL"
    fi
  done <<EOC
$(settings_caps)
EOC
  case "${TANDEM_COUNCIL_EFFORT+set}" in
    set) PROFILE_CAUSES="${PROFILE_CAUSES}TANDEM_COUNCIL_EFFORT='$TANDEM_COUNCIL_EFFORT' is set — the profile decides Astra's effort; unset it$NL" ;;
  esac
  fable_pin "$level" || PROFILE_CAUSES="${PROFILE_CAUSES}Fable seat: $FABLE_PIN_ERR$NL"
  if [ "$with_astra" = "astra" ]; then
    if ! astra_catalog; then
      PROFILE_CAUSES="${PROFILE_CAUSES}$ASTRA_CAT_ERR$NL"
    else
      case " $ASTRA_LEVELS " in
        *" $level "*) : ;;
        *) PROFILE_CAUSES="${PROFILE_CAUSES}Astra model '$CODEX_MODEL' does not support effort '$level' (supported: ${ASTRA_LEVELS:-none})$NL" ;;
      esac
    fi
  fi
  PROFILE_CAUSES="${PROFILE_CAUSES%"$NL"}"
  [ -z "$PROFILE_CAUSES" ]
}

# causes_inline — PROFILE_CAUSES on one line, « · »-separated.
causes_inline() { printf '%s' "$PROFILE_CAUSES" | LC_ALL=C awk 'NR > 1 { printf " · " } { printf "%s", $0 }'; }

# =============================================================================
# preflight
# =============================================================================
PF_FAIL=0
pf_ok() { printf '  ok    %s\n' "$1"; }
pf_bad() { printf '  FAIL  %s\n' "$1"; PF_FAIL=1; }
pf_info() { printf '        %s\n' "$1"; }

# Why each level's profile is discarded (one reason per line; empty = viable).
DISC_high=""
DISC_xhigh=""
DISC_max=""
disc_add() {
  # disc_add <level|all> <reason>
  local l
  for l in high xhigh max; do
    [ "$1" = "all" ] || [ "$1" = "$l" ] || continue
    case "$l" in
      high) DISC_high="$DISC_high${DISC_high:+$NL}$2" ;;
      xhigh) DISC_xhigh="$DISC_xhigh${DISC_xhigh:+$NL}$2" ;;
      max) DISC_max="$DISC_max${DISC_max:+$NL}$2" ;;
    esac
  done
}
disc_of() {
  case "$1" in
    high) printf '%s' "$DISC_high" ;;
    xhigh) printf '%s' "$DISC_xhigh" ;;
    max) printf '%s' "$DISC_max" ;;
  esac
}

cmd_preflight() {
  [ $# -eq 0 ] || die "usage: council.sh preflight" 64
  local rounds intake rounds_ok=1 have_jq=1 settings line val f fpin l p level
  local caps viable="" names="" lvls
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  printf 'tandem council preflight (no model turn is spent)\n\n'

  # (a) rounds
  rounds="${TANDEM_COUNCIL_ROUNDS:-4}"
  if positive_int "$rounds"; then
    rounds="$((10#$rounds))"
    pf_ok "TANDEM_COUNCIL_ROUNDS=$rounds"
  else
    rounds_ok=0
    pf_bad "TANDEM_COUNCIL_ROUNDS='$rounds' is not a positive integer"
  fi

  # (b) intake
  intake="${TANDEM_COUNCIL_INTAKE:-ask}"
  case "$intake" in
    ask | auto) pf_ok "TANDEM_COUNCIL_INTAKE=$intake" ;;
    *) pf_bad "TANDEM_COUNCIL_INTAKE='$intake' is invalid — expected ask or auto" ;;
  esac

  # (c) Astra's model against the CLI catalog — fail-closed: it is the only
  # free check before a seat turn is spent. Each profile's level must be one
  # of the model's supported_reasoning_levels.
  command -v jq >/dev/null 2>&1 || have_jq=0
  if astra_catalog; then
    pf_ok "Astra: $CODEX_MODEL is in the catalog of 'codex debug models' (supports: ${ASTRA_LEVELS:-none})"
    for l in high xhigh max; do
      case " $ASTRA_LEVELS " in
        *" $l "*) : ;;
        *) disc_add "$l" "Astra model '$CODEX_MODEL' does not support effort '$l' (supported: ${ASTRA_LEVELS:-none})" ;;
      esac
    done
  else
    pf_bad "$ASTRA_CAT_ERR"
    disc_add all "Astra's catalog could not be verified"
  fi
  # The profile decides Astra's effort: a global value would contradict it in
  # silence (resolve_role reads it on every start and resume).
  case "${TANDEM_COUNCIL_EFFORT+set}" in
    set) pf_bad "TANDEM_COUNCIL_EFFORT='$TANDEM_COUNCIL_EFFORT' must be unset — the effort profile decides Astra's effort (high, xhigh or max, the same as Fable and the leader); choose the profile instead (TANDEM_COUNCIL_PROFILE for an auto intake)" ;;
    *) pf_ok "TANDEM_COUNCIL_EFFORT unset (the profile decides Astra's effort)" ;;
  esac

  # (g) the Claude seat's pin, read from the six agents (never a literal here).
  fpin=""
  if fable_models; then
    fpin="$FABLE_MODEL"
    pf_ok "Fable seats: the six agents pin model=$FABLE_MODEL (agents/council-fable{,-xhigh,-high}{,-offline}.md)"
    for l in high xhigh max; do
      fable_pair "$l" || disc_add "$l" "Fable seat: $FABLE_PIN_ERR"
    done
  else
    pf_bad "Fable seats: $FABLE_PIN_ERR"
    disc_add all "Fable's agents cannot be trusted"
  fi

  # (d) a forced subagent model would replace the seat's model.
  if [ "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" = "1" ]; then
    case "${CLAUDE_CODE_SUBAGENT_MODEL+set}" in
      set)
        if [ -n "$fpin" ] && [ "$CLAUDE_CODE_SUBAGENT_MODEL" = "$fpin" ]; then
          pf_ok "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 with CLAUDE_CODE_SUBAGENT_MODEL=$fpin (the seat's own pin)"
        else
          pf_bad "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 with CLAUDE_CODE_SUBAGENT_MODEL='$CLAUDE_CODE_SUBAGENT_MODEL' would force that model onto the Fable seat (pin: ${fpin:-?}) — unset either variable"
        fi
        ;;
      *) pf_ok "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 but no CLAUDE_CODE_SUBAGENT_MODEL to force" ;;
    esac
  else
    pf_ok "no forced subagent model (CLAUDE_CODE_SUBAGENT_MODEL_FORCE is not 1)"
  fi

  # (e) a global effort level wins over every seat's frontmatter and the
  # leader's session: only the profile at exactly that level stays viable.
  case "${CLAUDE_CODE_EFFORT_LEVEL+set}" in
    set)
      case "$CLAUDE_CODE_EFFORT_LEVEL" in
        high | xhigh | max)
          pf_ok "CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL — only the profile at that level is viable"
          for l in high xhigh max; do
            [ "$l" = "$CLAUDE_CODE_EFFORT_LEVEL" ] \
              || disc_add "$l" "CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL overrides Fable's frontmatter and the leader's session"
          done
          ;;
        *)
          pf_bad "CLAUDE_CODE_EFFORT_LEVEL='$CLAUDE_CODE_EFFORT_LEVEL' overrides the frontmatter effort of every seat and the leader's session, and it is the level of no profile — unset it or set it to high, xhigh or max"
          disc_add all "CLAUDE_CODE_EFFORT_LEVEL='$CLAUDE_CODE_EFFORT_LEVEL' is the level of no profile"
          ;;
      esac
      ;;
    *) pf_ok "CLAUDE_CODE_EFFORT_LEVEL unset" ;;
  esac

  # (f) maxEffortLevel in every settings file in scope: a cap L discards the
  # profiles above L; a file that cannot be parsed is a FAIL.
  settings=0
  caps="$(settings_caps)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    val="${line%%"$TAB"*}"
    f="${line#*"$TAB"}"
    if [ "$val" = "!" ]; then
      if [ "$have_jq" -eq 0 ]; then
        pf_bad "cannot read maxEffortLevel in $f without jq"
      else
        pf_bad "cannot parse $f as JSON — maxEffortLevel cannot be verified"
      fi
      disc_add all "maxEffortLevel in $f cannot be verified"
      settings=1
      continue
    fi
    [ -n "$val" ] || continue
    [ "$val" = "max" ] && continue
    settings=1
    pf_ok "maxEffortLevel='$val' in $f — the profiles above $val are discarded"
    for l in high xhigh max; do
      [ "$(level_rank "$l")" -le "$(level_rank "$val")" ] \
        || disc_add "$l" "maxEffortLevel='$val' in $f caps the seats and the leader below $l"
    done
  done <<EOC
$caps
EOC
  [ "$settings" -eq 0 ] && pf_ok "no maxEffortLevel below max in the settings in scope"

  # (h) TANDEM_TURN_EFFORT, whatever its value: codex-resume.sh applies it AFTER
  # resolve_role, so a global export would silently degrade every substantive
  # resume — and an invalid one would make the first one exit 64.
  case "${TANDEM_TURN_EFFORT+set}" in
    set)
      pf_bad "TANDEM_TURN_EFFORT='$TANDEM_TURN_EFFORT' must be unset — council.sh astra decides the effort of every turn (the profile's level, or low for a reminder)"
      ;;
    *) pf_ok "TANDEM_TURN_EFFORT unset" ;;
  esac

  # (i) a sha256 tool: the seals, the frozen brief and the receipts depend on it.
  if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
    pf_ok "sha256 tool available ($(command -v shasum >/dev/null 2>&1 && printf 'shasum' || printf 'sha256sum'))"
  else
    pf_bad "neither shasum nor sha256sum is available — seals, the frozen brief and the turn receipts need one"
  fi

  # The viable profiles, and the one an auto intake will take.
  for p in $COUNCIL_PROFILES; do
    level="$(profile_level "$p")"
    if [ -z "$(disc_of "$level")" ]; then
      viable="$viable${viable:+ }$p"
      names="$names${names:+, }$p ($level)"
    fi
  done
  case "${TANDEM_COUNCIL_PROFILE+set}" in
    set)
      if [ -z "$TANDEM_COUNCIL_PROFILE" ]; then
        pf_bad "TANDEM_COUNCIL_PROFILE is set but empty — unset it or name a profile (exploratorio, estandar or critico)"
      elif ! level="$(profile_level "$TANDEM_COUNCIL_PROFILE")"; then
        pf_bad "TANDEM_COUNCIL_PROFILE='$TANDEM_COUNCIL_PROFILE' is not a profile — expected exploratorio, estandar or critico"
      else
        case " $viable " in
          *" $TANDEM_COUNCIL_PROFILE "*) pf_ok "TANDEM_COUNCIL_PROFILE=$TANDEM_COUNCIL_PROFILE ($level) is viable" ;;
          *) pf_bad "TANDEM_COUNCIL_PROFILE=$TANDEM_COUNCIL_PROFILE ($level) is not viable: $(disc_of "$level" | LC_ALL=C awk 'NR > 1 { printf " · " } { printf "%s", $0 }')" ;;
        esac
      fi
      ;;
    *) pf_ok "TANDEM_COUNCIL_PROFILE unset (an auto intake takes critico)" ;;
  esac
  if [ -z "$viable" ]; then
    pf_bad "no effort profile is viable (exploratorio = high, estandar = xhigh, critico = max) — see the discarded profiles below"
  fi

  # (j) the summary.
  printf '\nsummary:\n'
  pf_info "leader expected: ${TANDEM_COUNCIL_LEADER_MODEL:-$COUNCIL_LEADER_DEFAULT} at the chosen profile's level (self-declared by the session; confirmed at the brief gate)"
  pf_info "Astra: model=$CODEX_MODEL sandbox=$CODEX_SANDBOX (role council; effort = the profile's level)"
  pf_info "Fable: model=${fpin:-?} (agents/council-fable*.md: one pair per level)"
  pf_info "rounds=$( [ "$rounds_ok" -eq 1 ] && printf '%s' "$rounds" || printf '?') · intake=$intake"
  if [ "${TANDEM_WEB_SEARCH:-}" = "off" ]; then
    pf_info "web mode: web search is closed for Astra in every run (TANDEM_WEB_SEARCH=off); init --offline also removes Fable's web tools"
  else
    pf_info "web mode: web by default (Astra web_search + Fable WebSearch/WebFetch); init --offline = confidential mode"
  fi
  pf_info "perfiles viables: ${names:-ninguno}"
  for p in $COUNCIL_PROFILES; do
    level="$(profile_level "$p")"
    lvls="$(disc_of "$level")"
    [ -n "$lvls" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pf_info "descartado $p ($level): $line"
    done <<EOC
$lvls
EOC
  done
  for p in $COUNCIL_PROFILES; do
    level="$(profile_level "$p")"
    if [ "$rounds_ok" -eq 1 ]; then
      pf_info "$p: típico 2 × (2 + R) = $((2 * (2 + rounds))) turnos en $level · techo 5 × (2 + R) = $((5 * (2 + rounds))) turnos en $level + $((2 + rounds)) recordatorios de Astra en low (R = $rounds)"
    else
      pf_info "$p: cota desconocida hasta que TANDEM_COUNCIL_ROUNDS sea válida — típico 2 × (2 + R) turnos en $level, techo 5 × (2 + R) + (2 + R) recordatorios en low"
    fi
  done

  if [ "$PF_FAIL" -ne 0 ]; then
    printf '\ncouncil preflight: problems found — fix the FAIL lines above.\n'
    exit 1
  fi
  printf '\ncouncil preflight: ready.\n'
  exit 0
}

# =============================================================================
# init
# =============================================================================
random_byte() {
  od -An -N1 -tu1 /dev/urandom 2>/dev/null | LC_ALL=C tr -d ' \n'
}

random_token() {
  local t
  t="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | LC_ALL=C tr -d ' \n')"
  case "$t" in '' | *[!0-9a-f]*) die "cannot read /dev/urandom for a launch token" 65 ;; esac
  printf '%s' "$t"
}

cmd_init() {
  [ $# -ge 1 ] || die "usage: council.sh init <run-id> [--offline]" 64
  run_id_validate "$1"
  shift
  local mode=web b idx rounds a bseat c
  while [ $# -gt 0 ]; do
    case "$1" in
      --offline) mode=offline ;;
      *) die "unknown argument to init: $1" 64 ;;
    esac
    shift
  done
  rounds="${TANDEM_COUNCIL_ROUNDS:-4}"
  positive_int "$rounds" || die "TANDEM_COUNCIL_ROUNDS must be a positive integer (got: '$rounds')" 64
  rounds="$((10#$rounds))"
  council_paths
  need_jq

  mkdir -p "$STATE_DIR/runs" || die "cannot create $STATE_DIR/runs" 65
  [ -f "$PROJECT_DIR/.tandem/.gitignore" ] || printf '*\n' >"$PROJECT_DIR/.tandem/.gitignore"
  [ -e "$DOC_DIR" ] && die "council run '$RUN_ID' already exists: $DOC_DIR" 2
  mkdir "$RUN_DIR" 2>/dev/null || die "council run '$RUN_ID' already exists: $RUN_DIR" 2
  if ! mkdir -p "$DOC_BASE" || ! mkdir "$DOC_DIR" 2>/dev/null; then
    rmdir "$RUN_DIR" 2>/dev/null || true
    die "council run '$RUN_ID' already exists (or cannot be created): $DOC_DIR" 2
  fi
  mkdir -p "$RUN_DIR/sealed" "$DOC_DIR/prompts"

  # The letters: a uniform permutation drawn from /dev/urandom (rejection
  # sampling, no modulo bias) — the moderator never chooses them.
  while :; do
    b="$(random_byte)"
    case "$b" in '' | *[!0-9]*) rm -rf "$RUN_DIR" "$DOC_DIR"; die "cannot read /dev/urandom" 65 ;; esac
    [ "$b" -lt 252 ] && break
  done
  idx=$((b % 6))
  case "$idx" in
    0) a=lider bseat=fable c=astra ;;
    1) a=lider bseat=astra c=fable ;;
    2) a=fable bseat=lider c=astra ;;
    3) a=fable bseat=astra c=lider ;;
    4) a=astra bseat=lider c=fable ;;
    *) a=astra bseat=fable c=lider ;;
  esac

  STATE="$(jq -cn --arg id "$RUN_ID" --arg created "$(now_utc)" --arg mode "$mode" \
    --argjson rounds "$rounds" --arg a "$a" --arg b "$bseat" --arg c "$c" \
    --arg target "council-$RUN_ID-g1" --arg docdir "$DOC_CONFIG" \
    --arg leader "${TANDEM_COUNCIL_LEADER_MODEL:-$COUNCIL_LEADER_DEFAULT}" --arg proj "$PROJECT_DIR" \
    '{run_id: $id, created: $created, mode: $mode, max_rounds: $rounds,
      letters: {A: $a, B: $b, C: $c}, astra_targets: [$target],
      agents: [], astra_turns: [], prompts: [], captures: [], seals: {},
      leader_model: $leader, doc_dir_config: $docdir, project_dir: $proj}')" \
    || { rm -rf "$RUN_DIR" "$DOC_DIR"; die "cannot build run.json" 65; }
  state_save

  printf 'tandem: council run %s created (mode %s, up to %s rounds)\n' "$RUN_ID" "$mode" "$rounds"
  printf 'PROJECT: %s\nDOC_DIR: %s\nRUN_DIR: %s\n' "$PROJECT_DIR" "$DOC_DIR" "$RUN_DIR"
  printf 'LETTERS: A=%s B=%s C=%s\n' "$a" "$bseat" "$c"
}

# =============================================================================
# profile — the effort profile, chosen by the user before the brief is sealed
# =============================================================================
cmd_profile() {
  [ $# -eq 2 ] || die "usage: council.sh profile <run-id> exploratorio|estandar|critico" 64
  run_id_validate "$1"
  local name="$2" level mode agent cur
  level="$(profile_level "$name")" \
    || die "unknown profile '$name' (expected exploratorio, estandar or critico)" 64
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  [ -z "$(q -r '.seals.brief.sha256 // empty')" ] \
    || die "the brief is already sealed: the profile is frozen with the brief (for another profile, start a new run)" 65
  mode="$(q -r '.mode // "web"')"
  agent="$(profile_agent "$name" "$mode")"
  if ! profile_env_check "$level" "$mode" astra; then
    printf 'tandem: profile %s (%s) is not viable here:\n' "$name" "$level" >&2
    printf '%s\n' "$PROFILE_CAUSES" | LC_ALL=C sed -e 's/^/  - /' >&2
    die "profile $name not chosen — fix the environment or choose another profile" 1
  fi
  cur="$(q -c '[.perfil.nombre, .perfil.agente]')"
  if [ "$cur" != "$(jq -cn --arg n "$name" --arg a "$agent" '[$n, $a]')" ]; then
    upd --arg n "$name" --arg e "$level" --arg a "$agent" --arg t "$(now_utc)" \
      '.perfil = {nombre: $n, esfuerzo: $e, agente: $a, elegido: $t}'
    state_save
  fi
  printf 'PERFIL: %s (%s)\n' "$name" "$level"
  printf 'FABLE_AGENT: %s\n' "$agent"
}

# =============================================================================
# seal
# =============================================================================
seat_response_exists() {
  # seat_response_exists <phase> — any trace of a seat having been ASKED or
  # having ANSWERED in that phase: a staged prompt (a Fable seat can be
  # launched, and can answer, with no capture yet — its answer would then reach
  # the leader before the seal), an Astra launch, a Fable capture, a capture
  # file, or a published answer.
  local p="$1" L f
  [ "$(q -r --arg p "$p" '[(.prompts[] | select(.fase == $p)), (.astra_turns[] | select(.fase == $p)), (.captures[] | select(.fase == $p))] | length')" -gt 0 ] && return 0
  for f in "$RUN_DIR/fable.$p.a"*; do
    [ -e "$f" ] && return 0
  done
  for L in A B C; do
    [ -e "$(published_path "$p" "$L")" ] && return 0
  done
  return 1
}

cmd_seal() {
  [ $# -eq 2 ] || die "usage: council.sh seal <run-id> brief|propose|cross" 64
  run_id_validate "$1"
  local what="$2" f sha cur
  case "$what" in brief | propose | cross) : ;; *) die "seal what? expected brief, propose or cross (got: '$what')" 64 ;; esac
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  if [ "$what" = "brief" ]; then
    f="$DOC_DIR/brief.md"
    [ -s "$f" ] || die "the brief does not exist (or is empty): $f" 1
    sha="$(file_sha256 "$f")" || die "cannot hash $f (no shasum/sha256sum?)" 65
    cur="$(q -r '.seals.brief.sha256 // empty')"
    if [ -n "$cur" ]; then
      [ "$cur" = "$sha" ] || die "the brief is already sealed and has changed since ($cur → $sha) — a sealed brief is frozen" 65
      printf 'tandem: brief already sealed (sha256 %s)\n' "$sha"
      return 0
    fi
    [ -n "$(q -r '.perfil.nombre // empty')" ] \
      || die "choose the effort profile first: council.sh profile $RUN_ID exploratorio|estandar|critico — it is frozen with the brief" 1
  else
    [ -n "$(q -r '.seals.brief.sha256 // empty')" ] || die "seal the brief first: council.sh seal $RUN_ID brief" 1
    f="$RUN_DIR/sealed/$what.md"
    [ -s "$f" ] || die "the leader's $what contribution does not exist (or is empty): $f" 1
    if seat_response_exists "$what"; then
      die "a seat's prompt has already been staged, or a seat launched or answered, in phase $what — the leader's contribution must be sealed BEFORE the seats are launched, and before their prompts are staged" 65
    fi
    sha="$(file_sha256 "$f")" || die "cannot hash $f (no shasum/sha256sum?)" 65
  fi
  upd --arg w "$what" --arg sha "$sha" --arg t "$(now_utc)" '.seals[$w] = {sha256: $sha, sealed: $t}'
  state_save
  printf 'tandem: sealed %s (sha256 %s)\n' "$what" "$sha"
}

# =============================================================================
# record-agent
# =============================================================================
cursor_file() { printf '%s' "$RUN_DIR/fable.cursor"; }

cmd_record_agent() {
  [ $# -eq 3 ] || die "usage: council.sh record-agent <run-id> <agent-id> <output-file>" 64
  run_id_validate "$1"
  local agent="$2" out="$3" tmp
  case "$agent" in '' | *"$NL"*) die "invalid agent id" 64 ;; esac
  case "$out" in '' | *"$NL"*) die "invalid output file" 64 ;; esac
  case "$out" in /*) : ;; *) out="$PWD/$out" ;; esac
  council_paths
  need_jq
  run_require
  [ -f "$out" ] || [ -L "$out" ] || die "the agent's output file does not exist: $out" 1
  lock_acquire
  state_load
  upd --arg a "$agent" --arg o "$out" --arg t "$(now_utc)" \
    '.agents += [{agent_id: $a, output_file: $o, recorded: $t}]'
  state_save
  # A NEW agent starts its transcript at line 0.
  tmp="$(mktemp "$RUN_DIR/.cursor.XXXXXX")" || die "cannot create a temp file in $RUN_DIR" 65
  jq -cn --arg a "$agent" '{agent_id: $a, line: 0}' >"$tmp"
  write_atomic "$(cursor_file)" "$tmp"
  printf 'tandem: agent %s recorded for run %s\n' "$agent" "$RUN_ID"
}

# =============================================================================
# attempts
# =============================================================================
current_attempt() {
  # current_attempt <phase> <letter> — the latest staged (non-reminder) attempt, or 0.
  q -r --arg f "$1" --arg l "$2" \
    '[.prompts[] | select(.fase == $f and .letra == $l and (.recordatorio | not)) | .intento] | max // 0'
}

prompt_entry() {
  # prompt_entry <phase> <letter> <attempt> <reminder true|false>
  q -c --arg f "$1" --arg l "$2" --argjson k "$3" --argjson r "$4" \
    '[.prompts[] | select(.fase == $f and .letra == $l and .intento == $k and (.recordatorio == $r))] | last // empty'
}

astra_done_turn() {
  # astra_done_turn <phase> <attempt> <sustantivo|recordatorio> — the last done
  # turn of that attempt, or nothing.
  q -c --arg f "$1" --argjson k "$2" --arg tipo "$3" \
    '[.astra_turns[] | select(.fase == $f and .intento == $k and .tipo == $tipo and .estado == "done")] | last // empty'
}

astra_reply_of() {
  # astra_reply_of <turn-json> — the reply.txt the wrapper wrote for that turn.
  local target n
  target="$(printf '%s' "$1" | jq -r '.target')"
  n="$(printf '%s' "$1" | jq -r '.turno')"
  printf '%s' "$STATE_DIR/$(target_key "$target").t$n.reply.txt"
}

capture_entry() {
  # capture_entry <phase> <attempt> <sustantivo|recordatorio>
  q -c --arg f "$1" --argjson k "$2" --arg tipo "$3" \
    '[.captures[] | select(.fase == $f and .intento == $k and .tipo == $tipo)] | last // empty'
}

# =============================================================================
# astra — the only path to an Astra turn, and the owner of its lifecycle
# =============================================================================
ASTRA_SIG=0
WPID=0
astra_defer_sig() { ASTRA_SIG="$1"; }
astra_forward_sig() {
  ASTRA_SIG="$1"
  if [ "$WPID" -gt 0 ] 2>/dev/null; then kill -TERM "$WPID" 2>/dev/null || true; fi
}

cmd_astra() {
  [ $# -ge 2 ] || die "usage: council.sh astra <run-id> <phase> [--reminder]" 64
  run_id_validate "$1"
  phase_validate "$2"
  shift 2
  local reminder=0 tipo=sustantivo letter target key k pentry ppath psha sha nsub nrem
  local turn_before wrapper token idx mode tpl wl wrc now estado turno tsub
  while [ $# -gt 0 ]; do
    case "$1" in
      --reminder) reminder=1 ;;
      *) die "unknown argument to astra: $1" 64 ;;
    esac
    shift
  done
  [ "$reminder" -eq 1 ] && tipo=recordatorio
  council_paths
  need_jq
  run_require
  tpl="$COUNCIL_PROMPTS/astra.tpl"
  [ -f "$tpl" ] || die "astra template not found: $tpl" 65

  # --- reservation and launch: ONE critical section ---------------------------
  lock_acquire
  state_load
  # The frozen profile, re-verified against THIS environment before anything
  # is decided or reserved: a recovery can run in another session.
  mode="$(q -r '.mode')"
  run_profile
  [ -n "$RUN_PROFILE" ] \
    || die "no effort profile and no sealed brief: council.sh profile $RUN_ID <perfil>, then seal the brief" 1
  if ! profile_env_check "$RUN_LEVEL" "$mode" astra; then
    printf '%s\n' "$PROFILE_CAUSES" | LC_ALL=C sed -e 's/^/  - /' >&2
    die "the frozen profile $RUN_PROFILE ($RUN_LEVEL) is not viable in this environment — fix it (the profile never changes); nothing was reserved" 1
  fi
  letter="$(seat_letter astra)"
  [ -n "$letter" ] || die "run.json assigns no letter to astra" 65
  target="$(q -r '.astra_targets[-1] // empty')"
  [ -n "$target" ] || die "run.json lists no Astra target" 65
  key="$(target_key "$target")"

  recover_entries "$target"
  if [ "$RECOVER_ALIVE" -gt 0 ]; then
    state_save
    lock_release
    die "an Astra turn of $target is still alive — wait for its completion notification (nothing launched)" 75
  fi
  if [ "$RECOVER_BLOCKED" -gt 0 ]; then
    state_save
    lock_release
    die "an Astra turn of $target is bloqueada — nothing launches on it until a person resolves it: council.sh unblock $RUN_ID $target" 65
  fi

  k="$(current_attempt "$PHASE" "$letter")"
  if [ "$k" -eq 0 ]; then
    state_save
    lock_release
    die "no prompt staged for Astra (letter $letter) in $PHASE — run: council.sh stage $RUN_ID $PHASE $letter" 1
  fi
  if [ "$reminder" -eq 1 ]; then
    pentry="$(prompt_entry "$PHASE" "$letter" "$k" true)"
    if [ -z "$pentry" ]; then
      state_save
      lock_release
      die "no reminder staged for Astra's attempt a$k in $PHASE — run: council.sh stage $RUN_ID $PHASE $letter --reminder" 1
    fi
    if [ -z "$(astra_done_turn "$PHASE" "$k" sustantivo)" ]; then
      state_save
      lock_release
      die "a reminder completes a finished answer, but attempt a$k of $PHASE has no done turn" 1
    fi
  else
    pentry="$(prompt_entry "$PHASE" "$letter" "$k" false)"
  fi
  ppath="$(printf '%s' "$pentry" | jq -r '.ruta')"
  psha="$(printf '%s' "$pentry" | jq -r '.sha256')"
  [ -f "$ppath" ] || die "the staged prompt is gone: $ppath" 65
  sha="$(file_sha256 "$ppath")" || die "cannot hash $ppath" 65
  [ "$sha" = "$psha" ] || die "the staged prompt changed after stage ($ppath) — a prompt is never edited by hand" 65

  # The caps are executable: two substantive turns and one reminder per phase.
  nsub="$(q -r --arg f "$PHASE" '[.astra_turns[] | select(.fase == $f and .tipo == "sustantivo")] | length')"
  nrem="$(q -r --arg f "$PHASE" '[.astra_turns[] | select(.fase == $f and .tipo == "recordatorio")] | length')"
  if [ "$reminder" -eq 1 ] && [ "$nrem" -ge 1 ]; then
    state_save
    lock_release
    die "Astra already had its reminder in $PHASE — the cap is one per seat and phase (FAILED terminal, state preserved)" 65
  fi
  if [ "$reminder" -eq 0 ] && [ "$nsub" -ge 2 ]; then
    state_save
    lock_release
    die "Astra already had two substantive turns in $PHASE — the cap is the original plus one retry (FAILED terminal, state preserved)" 65
  fi

  turn_before="$(counter_of "$key")"
  if [ -f "$STATE_DIR/$key.thread" ]; then
    wrapper="$SCRIPT_DIR/codex-resume.sh"
  else
    wrapper="$SCRIPT_DIR/codex-start.sh"
  fi
  token="$(random_token)"

  # From here on a signal never cuts reservation → launch → registration in
  # half: it is RECORDED and honoured at the boundaries below.
  trap 'astra_defer_sig 130' INT
  trap 'astra_defer_sig 143' TERM
  trap 'astra_defer_sig 129' HUP
  upd --arg f "$PHASE" --argjson k "$k" --arg tipo "$tipo" --arg target "$target" \
    --arg prompt "$ppath" --arg psha "$psha" --argjson tb "$turn_before" --arg tok "$token" \
    --argjson dpid "$$" --arg dl "$(self_lstart)" --arg t "$(now_utc)" \
    --arg w "$(basename "$wrapper")" \
    '.astra_turns += [{fase: $f, intento: $k, tipo: $tipo, target: $target,
       prompt: $prompt, prompt_sha256: $psha, estado: "running", turn_before: $tb,
       turno: null, launch_token: $tok, driver: {pid: $dpid, lstart: $dl},
       wrapper: null, wrapper_script: $w, inicio: $t}]'
  idx="$(q -r '.astra_turns | length - 1')"
  state_save
  if [ "$ASTRA_SIG" -ne 0 ]; then
    upd --argjson i "$idx" --arg t "$(now_utc)" \
      '.astra_turns[$i] |= (.estado = "interrupted" | .nota = "señal antes de lanzar: no hubo turno" | .fin = $t)'
    state_save
    lock_release
    exit "$ASTRA_SIG"
  fi

  # The child leads its own process group and its argv carries the token:
  # `bash <wrapper>` under `exec -a`, never `bash -c` (a one-command -c would
  # exec the command and lose the token). TANDEM_TURN_EFFORT is REMOVED from a
  # substantive turn's environment — the same effect as `env -u`, done inside
  # the child so `exec -a` still names the wrapper's own process — and
  # TANDEM_COUNCIL_EFFORT carries the profile's level, which resolve_role
  # council applies on every start and resume; a reminder runs at low with the
  # foreground watchdog.
  set -m
  (
    export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
    if [ "$reminder" -eq 1 ]; then
      export TANDEM_TURN_EFFORT=low
      export TANDEM_EXEC_TIMEOUT_SECONDS=540
    else
      unset TANDEM_TURN_EFFORT
      export TANDEM_COUNCIL_EFFORT="$RUN_LEVEL"
    fi
    if [ "$mode" = "offline" ]; then
      export TANDEM_WEB_SEARCH=off
    fi
    exec -a "council-astra-$token" bash "$wrapper" council "$target" "$tpl" "$ppath"
  ) &
  WPID=$!
  set +m
  wl="$(proc_lstart "$WPID" || true)"
  upd --argjson i "$idx" --argjson p "$WPID" --arg l "$wl" '.astra_turns[$i].wrapper = {pid: $p, lstart: $l}'
  state_save
  lock_release

  # --- the turn, with no lock: signals are forwarded to the wrapper, which
  # turns TERM into its exit 143 and reaps codex's process group itself.
  trap 'astra_forward_sig 130' INT
  trap 'astra_forward_sig 143' TERM
  trap 'astra_forward_sig 129' HUP
  if [ "$ASTRA_SIG" -ne 0 ]; then kill -TERM "$WPID" 2>/dev/null || true; fi
  wrc=0
  while :; do
    wrc=0
    wait "$WPID" || wrc=$?
    kill -0 "$WPID" 2>/dev/null && continue
    break
  done

  # --- the close, under the lock again -----------------------------------------
  trap 'astra_defer_sig 130' INT
  trap 'astra_defer_sig 143' TERM
  trap 'astra_defer_sig 129' HUP
  lock_acquire
  state_load
  idx="$(q -r --arg tok "$token" '[.astra_turns | to_entries[] | select(.value.launch_token == $tok) | .key] | last // empty')"
  [ -n "$idx" ] || die "the reservation of this launch vanished from run.json (token $token)" 65
  now="$(counter_of "$key")"
  turno="null"
  tsub="sin turno: el contador no avanzó"
  if [ "$now" -eq "$((turn_before + 1))" ]; then
    turno="$now"
    tsub="turno $now"
  elif [ "$now" -gt "$((turn_before + 1))" ]; then
    tsub="el contador avanzó más de uno ($turn_before → $now)"
  fi
  if [ "$ASTRA_SIG" -ne 0 ]; then
    estado="interrupted"
  elif [ "$wrc" -eq 0 ] && [ "$turno" != "null" ] && receipt_valid "$key" "$turno"; then
    estado="done"
  else
    estado="failed"
  fi
  upd --argjson i "$idx" --arg e "$estado" --argjson n "$turno" --argjson rc "$wrc" \
    --arg t "$(now_utc)" --arg note "$tsub" \
    '.astra_turns[$i] |= (.estado = $e | .turno = $n | .exit = $rc | .fin = $t | .nota = $note)'
  state_save
  lock_release
  printf 'tandem: council astra — %s a%s %s: %s (%s, wrapper exit %s)\n' \
    "$PHASE" "$k" "$tipo" "$estado" "$tsub" "$wrc" >&2
  if [ "$estado" = "failed" ] && [ "$wrc" -eq 0 ]; then
    printf 'tandem: the wrapper exited 0 but its receipt is missing or does not certify reply.txt — this turn is NOT publishable\n' >&2
  fi
  [ "$ASTRA_SIG" -ne 0 ] && exit "$ASTRA_SIG"
  exit "$wrc"
}

# =============================================================================
# unblock — by hand only
# =============================================================================
cmd_unblock() {
  [ $# -eq 2 ] || die "usage: council.sh unblock <run-id> <target>" 64
  run_id_validate "$1"
  local target="$2" idx rc left=0 n=0
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  [ "$(q -r --arg t "$target" '.astra_targets | index($t) != null')" = "true" ] \
    || die "'$target' is not an Astra target of run $RUN_ID (targets: $(q -r '.astra_targets | join(", ")'))" 64
  for idx in $(q -r --arg t "$target" '.astra_turns | to_entries[]
      | select(.value.estado == "bloqueada" and .value.target == $t) | .key'); do
    n=$((n + 1))
    rc=0
    entry_liveness "$idx" || rc=$?
    if [ "$rc" -eq 0 ]; then
      state_save
      lock_release
      die "a process of the blocked turn is still alive (pid identity or one of the three argv signatures) — wait for it, then retry" 75
    fi
    if [ "$rc" -eq 2 ]; then
      left=$((left + 1))
      continue
    fi
    classify_dead "$idx" "resuelta a mano" || left=$((left + 1))
  done
  state_save
  if [ "$n" -eq 0 ]; then
    printf 'tandem: nothing is blocked on %s\n' "$target"
    return 0
  fi
  if [ "$left" -gt 0 ]; then
    lock_release
    die "$left blocked entr$( [ "$left" -eq 1 ] && printf 'y' || printf 'ies') of $target could not be resolved (liveness unknown, or a counter that advanced more than one) — review .tandem/state/council by hand" 65
  fi
  printf 'tandem: %s blocked entr%s of %s resolved by hand\n' "$n" "$( [ "$n" -eq 1 ] && printf 'y' || printf 'ies')" "$target"
}

# =============================================================================
# stage
# =============================================================================
brief_verify() {
  local f="$DOC_DIR/brief.md" want sha
  want="$(q -r '.seals.brief.sha256 // empty')"
  [ -n "$want" ] || die "the brief is not sealed yet: council.sh seal $RUN_ID brief" 1
  [ -f "$f" ] || die "input missing: $f" 1
  sha="$(file_sha256 "$f")" || die "cannot hash $f" 65
  [ "$sha" = "$want" ] || die "brief.md changed after it was sealed ($want → $sha) — the brief is frozen" 65
}

need_input() {
  [ -f "$1" ] || die "input missing: $1" 1
}

# open_list_json <letter> — the seat's own P1/P2 still open in what is
# published, from the SAME parser status uses.
open_list_json() {
  local docs
  docs="$(docs_json)"
  printf '%s' "$docs" | jq -c --arg l "$1" "$COUNCIL_JQ"'
    [ objections[] | select(.author == $l and (.sev == "P1" or .sev == "P2") and .status != "RESUELTA") ]
    | sort_by(.n)'
}

next_free_id() {
  local docs
  docs="$(docs_json)"
  printf '%s' "$docs" | jq -r --arg l "$1" "$COUNCIL_JQ"'
    ([ objections[] | select(.author == $l) | .n ] | max // 0) + 1 | "\($l)-\(.)"'
}

# missing_items <response-file> <letter> — what the response lacks, one item
# per line (empty: nothing is missing). Same parser as status.
missing_items() {
  local f="$1" L="$2" opens doc
  opens="$(open_list_json "$L")"
  doc="$(doc_json "$L" 99 "$PHASE" "$f")"
  printf '%s' "$doc" | jq -r --arg kind "$PHASE_KIND" --arg l "$L" --argjson opens "$opens" "$COUNCIL_JQ"'
    . as $d
    | if $kind == "propose" then
        (if ($d | lastline) == "ENTREGA: PROPUESTA" then empty
         else "- la última línea exacta `ENTREGA: PROPUESTA`" end)
      elif $kind == "cross" then
        (if ($d | lastline) == "ENTREGA: CONTRAINTERROGATORIO" then empty
         else "- la última línea exacta `ENTREGA: CONTRAINTERROGATORIO`" end)
      else
        ([ $d.lines[] | m1(rx_st) | select(. != null and .l == $l) | oid(.l; .n) ]) as $seen
        | ( [ $opens[] | select(.id as $i | $seen | index($i) | not)
              | "- la línea de estado de tu \(.id) [\(.sev)]: `- [\(.id)] RESUELTA: <motivo>` o `- [\(.id)] NO RESUELTA: <motivo>`" ]
          + (if ($d | verdict) == null
             then ["- la última línea exacta `VERDICT: APPROVED` o `VERDICT: REVISE`"] else [] end)
          + (if ($d | verdict) == "APPROVED" and (($d | has_riesgo) | not)
             then ["- la línea `RIESGO RESIDUAL: <riesgo>` (obligatoria junto a un APPROVED)"] else [] end) )[]
      end'
}

cmd_stage() {
  [ $# -ge 3 ] || die "usage: council.sh stage <run-id> <phase> <letter> [--with-history | --reminder]" 64
  run_id_validate "$1"
  phase_validate "$2"
  letter_validate "$3"
  local L="$3" history=0 reminder=0 seat k kmax max_rounds path tmp sha resp items
  local astra_l fable_l lider_l other f entry prev audit gens hist_phase hist_file opens
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-history) history=1 ;;
      --reminder) reminder=1 ;;
      *) die "unknown argument to stage: $1" 64 ;;
    esac
    shift
  done
  [ "$history" -eq 1 ] && [ "$reminder" -eq 1 ] && die "--with-history and --reminder are mutually exclusive" 64
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  # stage precedes EVERY turn of Fable and of Astra: the frozen profile is
  # re-verified against this environment before anything is decided.
  run_profile
  if [ -n "$RUN_PROFILE" ] && ! profile_env_check "$RUN_LEVEL" "$(q -r '.mode')"; then
    printf '%s\n' "$PROFILE_CAUSES" | LC_ALL=C sed -e 's/^/  - /' >&2
    die "the frozen profile $RUN_PROFILE ($RUN_LEVEL) is not viable in this environment — fix it (the profile never changes); nothing was staged" 1
  fi
  seat="$(letter_seat "$L")"
  [ -n "$seat" ] || die "run.json assigns no seat to letter $L" 65
  if [ "$PHASE_KIND" = "round" ]; then
    [ "$seat" != "lider" ] || die "round phases are staged only for the two reviewing letters ($L is the leader's)" 64
    max_rounds="$(q -r '.max_rounds')"
    [ "$ROUND_N" -le "$max_rounds" ] || die "$PHASE is beyond the round cap of this run ($max_rounds)" 64
  fi
  brief_verify
  # The leader's contribution is sealed BEFORE any seat of propose/cross gets
  # a prompt: no seat can be launched — or answer — before that, so the seal
  # really proves the leader wrote its own without having seen theirs.
  if [ "$reminder" -eq 0 ] && [ "$PHASE_KIND" != "round" ] \
    && [ -z "$(q -r --arg p "$PHASE" '.seals[$p].sha256 // empty')" ]; then
    die "seal the leader's $PHASE contribution first: council.sh seal $RUN_ID $PHASE — no seat prompt is staged before the seal" 1
  fi
  astra_l="$(seat_letter astra)"
  fable_l="$(seat_letter fable)"
  lider_l="$(seat_letter lider)"
  # Recovery only where stage NEEDS a turn's outcome — a reminder for Astra
  # completes its finished answer. Any other stage leaves running entries to
  # the subcommand that owns them (astra, publish, status).
  if [ "$reminder" -eq 1 ] && [ "$L" = "$astra_l" ]; then
    recover_entries ""
  fi
  mkdir -p "$DOC_DIR/prompts"

  if [ "$reminder" -eq 1 ]; then
    k="$(current_attempt "$PHASE" "$L")"
    [ "$k" -gt 0 ] || die "nothing to remind: no attempt staged for $L in $PHASE" 1
    if [ "$(q -r --arg f "$PHASE" --arg l "$L" '[.prompts[] | select(.fase == $f and .letra == $l and .recordatorio)] | length')" -gt 0 ]; then
      die "a reminder for $L in $PHASE was already staged — the cap is one per phase and letter" 65
    fi
    if [ "$L" = "$astra_l" ]; then
      entry="$(astra_done_turn "$PHASE" "$k" sustantivo)"
      [ -n "$entry" ] || die "no done Astra turn for attempt a$k of $PHASE — a reminder completes a finished answer" 1
      resp="$(astra_reply_of "$entry")"
    elif [ "$L" = "$fable_l" ]; then
      [ -n "$(capture_entry "$PHASE" "$k" sustantivo)" ] \
        || die "no Fable capture for attempt a$k of $PHASE — run: council.sh capture $RUN_ID $PHASE" 1
      resp="$(fable_file "$PHASE" "$k" 0 reply)"
    else
      die "the leader's letter takes no reminders" 64
    fi
    need_input "$resp"
    items="$(missing_items "$resp" "$L")"
    [ -n "$items" ] || die "nothing is missing in the answer of $L for $PHASE (attempt a$k) — no reminder needed" 1
    path="$(prompt_path "$PHASE" "$L" "$k" 1)"
    [ -e "$path" ] && die "the reminder file already exists and is not registered: $path — a prompt is never overwritten" 65
    tmp="$(mktemp "$DOC_DIR/prompts/.stage.XXXXXX")" || die "cannot create a temp file in $DOC_DIR/prompts" 65
    {
      cat "$COUNCIL_PROMPTS/nudge.md"
      printf '===== LO QUE FALTA =====\n'
      printf '%s\n' "$items"
    } >"$tmp"
  else
    k="$(current_attempt "$PHASE" "$L")"
    k=$((k + 1))
    kmax=2
    [ "$k" -le "$kmax" ] || die "$L already has two attempts staged in $PHASE — the cap is the original plus one retry or rebuild (FAILED terminal, state preserved)" 65
    path="$(prompt_path "$PHASE" "$L" "$k" 0)"
    [ -e "$path" ] && die "the prompt file already exists and is not registered: $path — a prompt is never overwritten" 65
    need_input "$COUNCIL_PROMPTS/seat-rules.md"
    case "$PHASE_KIND" in
      propose) need_input "$COUNCIL_PROMPTS/phase-propose.md" ;;
      cross)
        need_input "$COUNCIL_PROMPTS/phase-cross.md"
        need_input "$(published_path propose "$L")"
        for other in A B C; do
          [ "$other" = "$L" ] && continue
          need_input "$(published_path propose "$other")"
        done
        ;;
      round)
        need_input "$COUNCIL_PROMPTS/phase-round.md"
        need_input "$DOC_DIR/sintesis-v$ROUND_N.md"
        audit="$(audit_problem "$ROUND_N")"
        [ -z "$audit" ] || die "$audit" 1
        need_input "$DOC_DIR/registro.md"
        if [ "$ROUND_N" -gt 1 ]; then
          need_input "$DOC_DIR/sintesis-v$((ROUND_N - 1)).md"
          need_input "$(published_path "round-$((ROUND_N - 1))" "$L")"
        fi
        ;;
    esac
    # A rebuild of Astra is a NEW thread: the next generation of its target
    # (never codex-reset.sh, which would also delete the usage ledger and the
    # per-turn meta.json — the run's accounting and its evidence).
    if [ "$history" -eq 1 ] && [ "$L" = "$astra_l" ]; then
      gens="$(q -r '.astra_targets | length')"
      upd --arg t "council-$RUN_ID-g$((gens + 1))" '.astra_targets += [$t]'
    fi
    tmp="$(mktemp "$DOC_DIR/prompts/.stage.XXXXXX")" || die "cannot create a temp file in $DOC_DIR/prompts" 65
    {
      cat "$COUNCIL_PROMPTS/seat-rules.md"
      case "$PHASE_KIND" in
        propose) cat "$COUNCIL_PROMPTS/phase-propose.md" ;;
        cross) cat "$COUNCIL_PROMPTS/phase-cross.md" ;;
        round) cat "$COUNCIL_PROMPTS/phase-round.md" ;;
      esac
      printf '===== TU ASIENTO =====\n'
      printf 'Letra: %s\n' "$L"
      printf 'Fase: %s\n' "$PHASE"
      printf 'Siguiente ID libre de objeción: %s\n' "$(next_free_id "$L")"
    } >"$tmp"
    if [ "$history" -eq 1 ]; then
      for hist_phase in propose cross $(q -r '.max_rounds as $m | [range(1; $m + 1) | "round-\(.)"] | join(" ")'); do
        hist_file="$(published_path "$hist_phase" "$L")"
        [ -f "$hist_file" ] || continue
        emit_section "TU HISTORIAL: $hist_phase" "$hist_file" >>"$tmp"
      done
    fi
    emit_section "BRIEF" "$DOC_DIR/brief.md" >>"$tmp"
    case "$PHASE_KIND" in
      cross)
        emit_section "TU PROPUESTA ($L)" "$(published_path propose "$L")" >>"$tmp"
        for other in A B C; do
          [ "$other" = "$L" ] && continue
          emit_section "PROPUESTA $other" "$(published_path propose "$other")" >>"$tmp"
        done
        ;;
      round)
        emit_section "SÍNTESIS v$ROUND_N" "$DOC_DIR/sintesis-v$ROUND_N.md" >>"$tmp"
        emit_section "AUDITORÍA DE FUENTES v$ROUND_N" "$DOC_DIR/auditoria-v$ROUND_N.md" >>"$tmp"
        emit_section "REGISTRO DE OBJECIONES" "$DOC_DIR/registro.md" >>"$tmp"
        if [ "$ROUND_N" -gt 1 ]; then
          prev="$(mktemp "$RUN_DIR/.diff.XXXXXX")" || die "cannot create a temp file" 65
          f=0
          diff -u --label "sintesis-v$((ROUND_N - 1)).md" --label "sintesis-v$ROUND_N.md" \
            "$DOC_DIR/sintesis-v$((ROUND_N - 1)).md" "$DOC_DIR/sintesis-v$ROUND_N.md" >"$prev" || f=$?
          [ "$f" -le 1 ] || { rm -f "$prev" "$tmp"; die "diff failed on the syntheses" 65; }
          [ -s "$prev" ] || printf '(sin cambios)\n' >"$prev"
          emit_section "CAMBIOS v$((ROUND_N - 1)) -> v$ROUND_N (diff -u)" "$prev" >>"$tmp"
          rm -f "$prev"
        fi
        opens="$(mktemp "$RUN_DIR/.opens.XXXXXX")" || die "cannot create a temp file" 65
        open_list_json "$L" | jq -r 'if length == 0 then "(ninguno)" else
          .[] | "- [\(.id)] [\(.sev)] \(.title) — estado: \(.status)" end' >"$opens"
        emit_section "TUS P1/P2 ABIERTOS" "$opens" >>"$tmp"
        rm -f "$opens"
        ;;
    esac
  fi

  sha="$(file_sha256 "$tmp")" || { rm -f "$tmp"; die "cannot hash the staged prompt (no shasum/sha256sum?)" 65; }
  write_atomic "$path" "$tmp"
  upd --arg f "$PHASE" --arg l "$L" --argjson k "$k" --argjson r "$( [ "$reminder" -eq 1 ] && printf true || printf false)" \
    --argjson h "$( [ "$history" -eq 1 ] && printf true || printf false)" --arg p "$path" --arg s "$sha" --arg t "$(now_utc)" \
    '.prompts += [{fase: $f, letra: $l, intento: $k, recordatorio: $r, historia: $h, ruta: $p, sha256: $s, creado: $t}]'
  state_save
  printf '%s\n' "$path"
}

# =============================================================================
# capture — Fable's channel
# =============================================================================
# shellcheck disable=SC2016  # a jq program
CAPTURE_JQ='
def carr: (.message.content // []) | if type == "array" then . else [] end;
. as $all
| [ $all[] | select(type == "object" and .type == "assistant") ] as $a
| ([ $a[] | select(any(carr[]; type == "object" and .type == "tool_use" and .name == "SubagentHandback")) ] | last) as $hb
| (if $hb != null then
     ([ $hb | carr[] | objects | select(.type == "tool_use" and .name == "SubagentHandback") | .input.message ] | last)
   else
     (reduce $a[] as $l ({o: [], g: {}};
        ($l.message.id // "" | tostring) as $id
        | if (.g | has($id)) then .g[$id] += [$l] else .o += [$id] | .g[$id] = [$l] end)) as $G
     | [ $G.o[] as $id | $G.g[$id]
         | select(any(.[] | carr[]; type == "object" and .type == "text")
                  and (any(.[] | carr[]; type == "object" and .type == "tool_use") | not)) ]
     | if length == 0 then null
       else (last | [ .[] | carr[] | objects | select(.type == "text") | .text | strings ] | join(""))
       end
   end) as $reply
| (reduce $a[] as $l ({}; .[($l.message.id // "" | tostring)] = ($l.message.usage // {}))) as $U
# A message has its FINAL usage only when its last line carries a stop_reason:
# the harness does not always write that last chunk (measured on the real
# canary: the SubagentHandback messages of Fable keep the stream-start count on
# every line, stop_reason null). Such a usage is a lower bound, and is counted.
| (reduce $a[] as $l ({}; .[($l.message.id // "" | tostring)] = ($l.message.stop_reason // null))) as $S
| {
    malformed: ([ $all[] | select(type != "object" or has("__malformed")) ] | length),
    assistant: ($a | length),
    models: [ $a[] | .message.model ],
    bad_models: [ $a[] | .message.model
                  | select((type != "string")
                           or (((. == $pin)
                                or (startswith($pin + "-") and (.[($pin | length) + 1:] | test("^[0-9]{8}$"))))
                               | not)) ],
    # The effort and the agent type Claude Code records on every assistant
    # line of a subagent (`effort`, `attributionAgent`; measured on real
    # transcripts, undocumented): present and different is a mismatch; absent
    # degrades the evidence to "no verificado", never blocks.
    efforts: [ $a[] | .effort | select(. != null) ],
    bad_efforts: [ $a[] | select(.effort != null and .effort != $effort) | .effort ],
    sin_effort: ([ $a[] | select(.effort == null) ] | length),
    agentes: [ $a[] | .attributionAgent | select(. != null) ],
    bad_agentes: [ $a[] | select(.attributionAgent != null and .attributionAgent != $agent) | .attributionAgent ],
    sin_agente: ([ $a[] | select(.attributionAgent == null) ] | length),
    reply: (if ($reply | type) == "string" and ($reply | length) > 0 then $reply else null end),
    mensajes: ($S | length),
    sin_usage_definitivo: ([ $S[] | select(. == null) ] | length),
    usage: {
      input_tokens: ([ $U[] | (.input_tokens | numbers) // 0 ] | add // 0),
      cache_read_input_tokens: ([ $U[] | (.cache_read_input_tokens | numbers) // 0 ] | add // 0),
      cache_creation_input_tokens: ([ $U[] | (.cache_creation_input_tokens | numbers) // 0 ] | add // 0),
      output_tokens: ([ $U[] | (.output_tokens | numbers) // 0 ] | add // 0)
    },
    reads: [ $a[] | carr[] | objects
             | select(.type == "tool_use" and ((.name // "") | IN("Read", "Grep", "Glob")))
             | . as $t
             | [ .input | .. | strings
                 | select((contains($own1) or contains($own2)) | not)
                 | select(contains($doc) or contains($run) or contains($runrel)
                          or ($docrel != "" and contains($docrel))) ]
             | select(length > 0) | {herramienta: $t.name, rutas: .} ]
  }
'

read_cursor() {
  # read_cursor <agent-id> — the next line to read belongs to THAT agent only.
  local f c a
  f="$(cursor_file)"
  [ -f "$f" ] || { printf '0'; return 0; }
  a="$(jq -r '.agent_id // empty' "$f" 2>/dev/null || true)"
  c="$(jq -r '.line // 0' "$f" 2>/dev/null || printf '0')"
  case "$c" in '' | *[!0-9]*) c=0 ;; esac
  if [ "$a" != "$1" ]; then printf '0'; return 0; fi
  printf '%s' "$c"
}

write_cursor() {
  local tmp
  tmp="$(mktemp "$RUN_DIR/.cursor.XXXXXX")" || die "cannot create a temp file in $RUN_DIR" 65
  jq -cn --arg a "$1" --argjson n "$2" '{agent_id: $a, line: $n}' >"$tmp"
  write_atomic "$(cursor_file)" "$tmp"
}

cmd_capture() {
  [ $# -ge 2 ] || die "usage: council.sh capture <run-id> <phase> [--reminder] [--manual]" 64
  run_id_validate "$1"
  phase_validate "$2"
  shift 2
  local reminder=0 manual=0 tipo=sustantivo L k reply usage agent out cursor snap total slice
  local analysis tmp sha nbad own1 own2 rtrue line_to
  while [ $# -gt 0 ]; do
    case "$1" in
      --reminder) reminder=1 ;;
      --manual) manual=1 ;;
      *) die "unknown argument to capture: $1" 64 ;;
    esac
    shift
  done
  [ "$reminder" -eq 1 ] && tipo=recordatorio
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  L="$(seat_letter fable)"
  [ -n "$L" ] || die "run.json assigns no letter to fable" 65
  k="$(current_attempt "$PHASE" "$L")"
  [ "$k" -gt 0 ] || die "no prompt staged for Fable (letter $L) in $PHASE" 1
  rtrue=false
  [ "$reminder" -eq 1 ] && rtrue=true
  [ -n "$(prompt_entry "$PHASE" "$L" "$k" "$rtrue")" ] \
    || die "no $( [ "$reminder" -eq 1 ] && printf 'reminder ')prompt staged for Fable's attempt a$k in $PHASE" 1
  # The cap: one capture per attempt, two substantive per phase, one reminder.
  if [ "$reminder" -eq 1 ]; then
    [ "$(q -r --arg f "$PHASE" '[.captures[] | select(.fase == $f and .tipo == "recordatorio")] | length')" -lt 1 ] \
      || die "Fable's reminder of $PHASE was already captured — beyond the cap of the phase" 65
    [ -n "$(capture_entry "$PHASE" "$k" sustantivo)" ] \
      || die "the reminder completes a captured answer, but attempt a$k of $PHASE has none" 1
  else
    [ -z "$(capture_entry "$PHASE" "$k" sustantivo)" ] \
      || die "attempt a$k of $PHASE was already captured — beyond the cap of the phase" 65
    [ "$(q -r --arg f "$PHASE" '[.captures[] | select(.fase == $f and .tipo == "sustantivo")] | length')" -lt 2 ] \
      || die "two substantive captures already exist for $PHASE — beyond the cap of the phase" 65
  fi
  reply="$(fable_file "$PHASE" "$k" "$reminder" reply)"
  usage="$(fable_file "$PHASE" "$k" "$reminder" usage)"
  agent="$(q -r '.agents[-1].agent_id // empty')"
  out="$(q -r '.agents[-1].output_file // empty')"

  if [ "$manual" -eq 1 ]; then
    # Visible degradation: the leader transcribed the Agent result himself.
    [ -s "$reply" ] || die "write the transcribed answer first: $reply" 1
    sha="$(file_sha256 "$reply")" || die "cannot hash $reply" 65
    if [ -n "$agent" ] && [ -r "$out" ]; then
      total="$(LC_ALL=C tr -cd '\n' <"$out" | wc -c | LC_ALL=C tr -d ' ')"
      write_cursor "$agent" "$total"
    fi
    upd --arg f "$PHASE" --argjson k "$k" --arg tipo "$tipo" --arg a "$agent" --arg p "$reply" \
      --arg s "$sha" --arg t "$(now_utc)" \
      '.captures += [{fase: $f, intento: $k, tipo: $tipo, agent_id: $a, captura: "transcrito",
         modelo: "no verificado", modelos: [], esfuerzo: "no verificado", esfuerzos: [],
         agente: "no verificado", agentes: [], respuesta: $p, sha256: $s, uso: null, registrado: $t}]'
    state_save
    printf '%s\n' "$reply"
    return 0
  fi

  [ -n "$agent" ] || die "no Fable agent recorded for this run — council.sh record-agent first" 1
  [ -r "$out" ] || die "the agent's output file cannot be read: $out" 1
  run_profile
  [ -n "$RUN_PROFILE" ] || die "no effort profile and no sealed brief for this run" 1
  fable_pin "$RUN_LEVEL" || die "Fable's pin cannot be trusted: $FABLE_PIN_ERR" 65
  cursor="$(read_cursor "$agent")"
  snap="$(mktemp "$RUN_DIR/.transcript.XXXXXX")" || die "cannot create a temp file" 65
  cat "$out" >"$snap" || { rm -f "$snap"; die "cannot read $out" 1; }
  total="$(LC_ALL=C tr -cd '\n' <"$snap" | wc -c | LC_ALL=C tr -d ' ')"
  if [ "$cursor" -gt "$total" ]; then
    rm -f "$snap"
    die "the transcript is shorter ($total lines) than its cursor ($cursor) — it is not the file this cursor read" 65
  fi
  slice="$(mktemp "$RUN_DIR/.slice.XXXXXX")" || die "cannot create a temp file" 65
  if [ "$total" -gt "$cursor" ]; then
    sed -n "$((cursor + 1)),${total}p" "$snap" >"$slice"
  fi
  rm -f "$snap"
  own1="$DOC_DIR/prompts/$PHASE-$L.a"
  own2="${DOC_REL:+$DOC_REL/}prompts/$PHASE-$L.a"
  analysis="$(jq -Rs 'split("\n") | map(select(length > 0) | (try fromjson catch {"__malformed": true}))' "$slice" \
    | jq -c --arg pin "$FABLE_PIN" --arg effort "$RUN_LEVEL" --arg agent "$RUN_AGENT" \
      --arg doc "$DOC_DIR" --arg run "$RUN_DIR" --arg runrel "$RUN_REL" \
      --arg docrel "$DOC_REL" --arg own1 "$own1" --arg own2 "$own2" "$CAPTURE_JQ")" \
    || { rm -f "$slice"; die "the transcript slice could not be analysed" 1; }
  rm -f "$slice"
  line_to="$total"
  nbad="$(printf '%s' "$analysis" | jq -r '.bad_models | length')"
  if [ "$nbad" -gt 0 ]; then
    die "a line of the transcript slice was answered by $(printf '%s' "$analysis" | jq -c '.bad_models | unique') instead of the seat's pin $FABLE_PIN — nothing captured (FAILED terminal: a forced model, a wrong agent type or a silent model switch)" 65
  fi
  if [ "$(printf '%s' "$analysis" | jq -r '.bad_efforts | length')" -gt 0 ]; then
    die "a line of the transcript slice ran at effort $(printf '%s' "$analysis" | jq -c '.bad_efforts | unique') instead of the profile's level $RUN_LEVEL ($RUN_PROFILE) — nothing captured (FAILED terminal: otro esfuerzo)" 65
  fi
  if [ "$(printf '%s' "$analysis" | jq -r '.bad_agentes | length')" -gt 0 ]; then
    die "a line of the transcript slice was written by agent type $(printf '%s' "$analysis" | jq -c '.bad_agentes | unique') instead of $RUN_AGENT ($RUN_PROFILE) — nothing captured (FAILED terminal: otro tipo de agente)" 65
  fi
  if [ "$(printf '%s' "$analysis" | jq -r '.malformed')" -gt 0 ]; then
    die "the transcript slice holds lines that are not JSON — format not recognised; transcribe the Agent result into $reply and run: council.sh capture $RUN_ID $PHASE$( [ "$reminder" -eq 1 ] && printf ' --reminder') --manual" 1
  fi
  if [ "$(printf '%s' "$analysis" | jq -r '.reply == null')" = "true" ]; then
    die "no answer in the transcript slice (lines $((cursor + 1))-$total): the turn has not finished or the format changed — wait for the notification; otherwise transcribe the Agent result into $reply and run: council.sh capture $RUN_ID $PHASE$( [ "$reminder" -eq 1 ] && printf ' --reminder') --manual" 1
  fi
  tmp="$(mktemp "$RUN_DIR/.reply.XXXXXX")" || die "cannot create a temp file" 65
  printf '%s' "$analysis" | jq -j '.reply' >"$tmp"
  sha="$(file_sha256 "$tmp")" || { rm -f "$tmp"; die "cannot hash the captured answer" 65; }
  write_atomic "$reply" "$tmp"
  tmp="$(mktemp "$RUN_DIR/.usage.XXXXXX")" || die "cannot create a temp file" 65
  printf '%s' "$analysis" | jq -c '.usage' >"$tmp"
  write_atomic "$usage" "$tmp"
  # Only what run.json records travels as an argument — never the answer text,
  # which can be long enough to strain the argument-size limit.
  upd --arg f "$PHASE" --argjson k "$k" --arg tipo "$tipo" --arg a "$agent" --arg o "$out" \
    --argjson from "$((cursor + 1))" --argjson to "$line_to" --arg p "$reply" --arg s "$sha" \
    --arg u "$usage" --argjson an "$(printf '%s' "$analysis" | jq -c '{models, reads, mensajes, sin_usage_definitivo, efforts, sin_effort, agentes, sin_agente}')" --arg t "$(now_utc)" \
    '.captures += [{fase: $f, intento: $k, tipo: $tipo, agent_id: $a, output_file: $o,
       desde: $from, hasta: $to, captura: "capturado", modelo: "verificado",
       modelos: ($an.models | unique),
       esfuerzo: (if $an.sin_effort == 0 then "verificado" else "no verificado" end),
       esfuerzos: ($an.efforts | unique),
       agente: (if $an.sin_agente == 0 then "verificado" else "no verificado" end),
       agentes: ($an.agentes | unique),
       respuesta: $p, sha256: $s, uso: $u,
       mensajes: $an.mensajes, sin_usage_definitivo: $an.sin_usage_definitivo,
       uso_completo: ($an.sin_usage_definitivo == 0), registrado: $t}]
     | .anomalies = ((.anomalies // []) + [ $an.reads[]
         | {tipo: "lectura-fuera-de-alcance", asiento: "fable", fase: $f, intento: $k,
            herramienta: .herramienta, rutas: .rutas, registrado: $t} ])'
  state_save
  write_cursor "$agent" "$line_to"
  printf '%s\n' "$reply"
}

# =============================================================================
# publish — the barrier between phases
# =============================================================================
astra_events_audit() {
  # astra_events_audit <turn-json> — a command of the turn's events that names
  # the run's directories becomes an anomaly; never a block.
  local e="$1" target n ev
  target="$(printf '%s' "$e" | jq -r '.target')"
  n="$(printf '%s' "$e" | jq -r '.turno')"
  ev="$STATE_DIR/$(target_key "$target").t$n.events.ndjson"
  [ -f "$ev" ] || return 0
  jq -Rc --arg doc "$DOC_DIR" --arg docrel "$DOC_REL" --arg run "$RUN_DIR" \
    'fromjson? | (.item.command? // empty) | strings
     | select(contains($doc) or contains($run) or contains(".tandem/state/council")
              or ($docrel != "" and contains($docrel)))' "$ev" 2>/dev/null \
    | jq -sc 'unique' 2>/dev/null || printf '[]'
}

cmd_publish() {
  [ $# -eq 2 ] || die "usage: council.sh publish <run-id> <phase>" 64
  run_id_validate "$1"
  phase_validate "$2"
  local astra_l fable_l lider_l ka kf asub arem fsub frem f sha dest want dests="" tmp
  local srcs L cmds i meta_missing aeff
  # Paths travel in ARRAYS, never in a space-separated string: a project or a
  # TANDEM_COUNCIL_DIR with a space in its name must publish like any other.
  local -a pub_letters pub_tmps
  pub_letters=()
  pub_tmps=()
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  recover_entries ""
  astra_l="$(seat_letter astra)"
  fable_l="$(seat_letter fable)"
  lider_l="$(seat_letter lider)"

  # The leader's sealed contribution (propose/cross), still holding its seal.
  if [ "$PHASE_KIND" != "round" ]; then
    want="$(q -r --arg p "$PHASE" '.seals[$p].sha256 // empty')"
    [ -n "$want" ] || die "the leader's $PHASE contribution is not sealed: council.sh seal $RUN_ID $PHASE" 1
    f="$RUN_DIR/sealed/$PHASE.md"
    [ -f "$f" ] || die "the sealed contribution is gone: $f" 65
    sha="$(file_sha256 "$f")" || die "cannot hash $f" 65
    [ "$sha" = "$want" ] || die "the leader's sealed $PHASE contribution changed after its seal" 65
  fi

  # Astra: the done substantive turn of the CURRENT attempt, plus its reminder.
  ka="$(current_attempt "$PHASE" "$astra_l")"
  [ "$ka" -gt 0 ] || die "no attempt staged for Astra (letter $astra_l) in $PHASE" 1
  asub="$(astra_done_turn "$PHASE" "$ka" sustantivo)"
  if [ -z "$asub" ]; then
    if [ "$(q -r --arg f "$PHASE" --argjson k "$ka" '[.astra_turns[] | select(.fase == $f and .intento == $k and .estado == "running")] | length')" -gt 0 ]; then
      die "Astra's turn for attempt a$ka of $PHASE is still running — wait for its notification" 1
    fi
    die "no done Astra turn for attempt a$ka of $PHASE — retry or rebuild it (failed and interrupted turns are never published)" 1
  fi
  arem="$(astra_done_turn "$PHASE" "$ka" recordatorio)"
  for f in "$asub" "$arem"; do
    [ -n "$f" ] || continue
    if ! receipt_valid "$(target_key "$(printf '%s' "$f" | jq -r '.target')")" "$(printf '%s' "$f" | jq -r '.turno')"; then
      die "an Astra turn marked done has no receipt certifying its reply ($(printf '%s' "$f" | jq -r '"\(.target) t\(.turno)"')) — refusing to publish it" 65
    fi
  done
  # Astra's effort, MEASURED: the meta.json its wrapper wrote for the
  # substantive turn. Another level is a FAILED terminal; a missing meta.json
  # is a visible anomaly, never a block.
  run_profile
  meta_missing=0
  if [ -n "$RUN_LEVEL" ]; then
    f="$STATE_DIR/$(target_key "$(printf '%s' "$asub" | jq -r '.target')").t$(printf '%s' "$asub" | jq -r '.turno').meta.json"
    if [ -f "$f" ]; then
      aeff="$(jq -r '.effort // empty' "$f" 2>/dev/null || true)"
      [ "$aeff" = "$RUN_LEVEL" ] \
        || die "Astra's substantive turn of attempt a$ka in $PHASE ran at effort '${aeff:-?}' ($f), not the profile's level $RUN_LEVEL ($RUN_PROFILE) — nothing published (FAILED terminal)" 65
    else
      meta_missing=1
    fi
  fi

  # Fable: the capture of the CURRENT attempt, plus its reminder.
  kf="$(current_attempt "$PHASE" "$fable_l")"
  [ "$kf" -gt 0 ] || die "no attempt staged for Fable (letter $fable_l) in $PHASE" 1
  fsub="$(capture_entry "$PHASE" "$kf" sustantivo)"
  [ -n "$fsub" ] || die "no Fable capture for attempt a$kf of $PHASE — council.sh capture $RUN_ID $PHASE" 1
  frem="$(capture_entry "$PHASE" "$kf" recordatorio)"
  for f in "$fsub" "$frem"; do
    [ -n "$f" ] || continue
    want="$(printf '%s' "$f" | jq -r '.sha256')"
    sha="$(file_sha256 "$(printf '%s' "$f" | jq -r '.respuesta')")" || die "a captured answer is gone: $(printf '%s' "$f" | jq -r '.respuesta')" 65
    [ "$sha" = "$want" ] || die "a captured answer changed after its capture: $(printf '%s' "$f" | jq -r '.respuesta') — the leader never edits a seat's answer" 65
  done

  # Destinations: none may exist.
  for L in A B C; do
    [ "$PHASE_KIND" = "round" ] && [ "$L" = "$lider_l" ] && continue
    dest="$(published_path "$PHASE" "$L")"
    [ -e "$dest" ] && die "already published: $dest" 2
    dests="$dests $L"
  done
  mkdir -p "$(dirname "$(published_path "$PHASE" A)")"

  # Compose every destination into a temp file IN ITS OWN DIRECTORY first (a
  # rename there is atomic), and only then rename them all into place.
  for L in $dests; do
    dest="$(published_path "$PHASE" "$L")"
    tmp="$(mktemp "$(dirname "$dest")/.publish.XXXXXX")" || die "cannot create a temp file next to $dest" 65
    pub_letters+=("$L")
    pub_tmps+=("$tmp")
    if [ "$L" = "$lider_l" ]; then
      cat "$RUN_DIR/sealed/$PHASE.md" >"$tmp"
    elif [ "$L" = "$astra_l" ]; then
      cat "$(astra_reply_of "$asub")" >"$tmp"
      if [ -n "$arem" ]; then
        if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then printf '\n' >>"$tmp"; fi
        cat "$(astra_reply_of "$arem")" >>"$tmp"
      fi
    else
      cat "$(printf '%s' "$fsub" | jq -r '.respuesta')" >"$tmp"
      if [ -n "$frem" ]; then
        if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then printf '\n' >>"$tmp"; fi
        cat "$(printf '%s' "$frem" | jq -r '.respuesta')" >>"$tmp"
      fi
    fi
  done
  i=0
  while [ "$i" -lt "${#pub_tmps[@]}" ]; do
    L="${pub_letters[$i]}"
    tmp="${pub_tmps[$i]}"
    dest="$(published_path "$PHASE" "$L")"
    if ! mv -f "$tmp" "$dest"; then
      rm -f "$tmp"
      die "could not publish $dest" 65
    fi
    i=$((i + 1))
  done

  # Provenance goes to run.json only — the published files reveal no identity.
  for L in $dests; do
    dest="$(published_path "$PHASE" "$L")"
    sha="$(file_sha256 "$dest" || true)"
    if [ "$L" = "$lider_l" ]; then
      srcs="$(jq -cn --arg p "$PHASE" '[{fuente: "sello del líder", contribucion: "sealed/\($p).md"}]')"
    elif [ "$L" = "$astra_l" ]; then
      srcs="$(jq -cn --argjson s "$asub" --argjson r "${arem:-null}" \
        '[$s, $r] | map(select(. != null) | {fuente: "turno de Astra", tipo, intento, target, turno, recuperado: (.recuperado // false)})')"
    else
      srcs="$(jq -cn --argjson s "$fsub" --argjson r "${frem:-null}" \
        '[$s, $r] | map(select(. != null) | {fuente: "captura de Fable", tipo, intento, captura, modelo, modelos, sha256})')"
    fi
    upd --arg f "$PHASE" --arg l "$L" --arg seat "$(letter_seat "$L")" --arg d "$dest" \
      --arg s "$sha" --argjson src "$srcs" --arg t "$(now_utc)" \
      '.publications = ((.publications // []) + [{fase: $f, letra: $l, asiento: $seat, destino: $d,
         sha256: $s, fuentes: $src, publicado: $t}])'
  done
  # Astra's read audit: it receives everything inline and never needs to look.
  for f in "$asub" "$arem"; do
    [ -n "$f" ] || continue
    cmds="$(astra_events_audit "$f")"
    [ -n "$cmds" ] || cmds='[]'
    upd --arg f "$PHASE" --argjson e "$f" --argjson c "$cmds" --arg t "$(now_utc)" \
      '.anomalies = ((.anomalies // []) + [ $c[]
         | {tipo: "lectura-fuera-de-alcance", asiento: "astra", fase: $f, intento: $e.intento,
            turno: $e.turno, comando: ., registrado: $t} ])'
  done
  if [ "$meta_missing" -eq 1 ]; then
    upd --arg f "$PHASE" --argjson e "$asub" --arg t "$(now_utc)" \
      '.anomalies = ((.anomalies // []) + [{tipo: "esfuerzo-astra-no-verificado", asiento: "astra",
         fase: $f, intento: $e.intento, target: $e.target, turno: $e.turno, registrado: $t}])'
  fi
  state_save
  for L in $dests; do
    printf '%s\n' "$(published_path "$PHASE" "$L")"
  done
}

# =============================================================================
# ledger and status
# =============================================================================
cmd_ledger() {
  [ $# -eq 1 ] || die "usage: council.sh ledger <run-id>" 64
  run_id_validate "$1"
  local docs regs problems n
  council_paths
  need_jq
  run_require
  state_load
  [ -f "$DOC_DIR/registro.md" ] || { printf 'LEDGER: FALLA\n- registro.md no existe (%s)\n' "$DOC_DIR/registro.md"; exit 1; }
  # The published answers travel on stdin (printf is a builtin): every answer
  # of a long run as one argument could strain the argument-size limit.
  docs="$(docs_json)"
  regs="$(registro_json)"
  problems="$(printf '%s' "$docs" | jq -r --argjson reg "$regs" "$COUNCIL_JQ"'
    . as $docs | ($docs | objections) as $o | ($reg | rows) as $r | ledger_problems($o; $r)[]')"
  if [ -n "$problems" ]; then
    printf 'LEDGER: FALLA\n'
    printf '%s\n' "$problems" | LC_ALL=C sed -e 's/^/- /'
    exit 1
  fi
  n="$(printf '%s' "$docs" | jq -r "$COUNCIL_JQ"'objections | length')"
  printf 'LEDGER: OK (%s objeciones, cada una en exactamente una fila)\n' "$n"
}

# consensus_json <N> <reviewer-letter-1> <reviewer-letter-2> — the six rules
# on the last round with both reviewer answers published.
consensus_json() {
  local n="$1" r1="$2" r2="$3" docs regs audit
  docs="$(docs_json)"
  regs="$(registro_json)"
  audit="$(audit_problem "$n")"
  printf '%s' "$docs" | jq -c --argjson reg "$regs" --arg n "$n" --arg r1 "$r1" --arg r2 "$r2" \
    --arg audit "$audit" --arg hasreg "$([ -f "$DOC_DIR/registro.md" ] && printf 1 || printf 0)" "$COUNCIL_JQ"'
    . as $docs
    | ($docs | objections) as $o
    | ($reg | rows) as $rows
    | ($rows | map({key: .id, value: .disp}) | from_entries) as $disp
    | [$r1, $r2] as $revs
    | [ $docs[] | select(.phase == "round-\($n)" and (.author | IN($r1, $r2))) ] as $rd
    | [ $o[] | select((.author | IN($r1, $r2)) and (.sev == "P1" or .sev == "P2")
                      and (.status == "NO RESUELTA" or .status == "PENDIENTE")) ] as $unres
    | ( [ $rd[] | . as $d | ($d | verdict) as $v
          | if $v == "APPROVED" then
              (if ($d | has_riesgo) then empty
               else "ronda \($n): \($d.author) aprueba sin la línea RIESGO RESIDUAL:" end),
              ([ $unres[] | select(.author == $d.author) | .id ] as $ids
               | if ($ids | length) > 0
                 then "incoherencia: \($d.author) dice VERDICT: APPROVED con \($ids | join(", ")) sin resolver — cuenta como REVISE"
                 else empty end)
            elif $v == "REVISE" then "ronda \($n): \($d.author) termina en VERDICT: REVISE"
            else "ronda \($n): \($d.author) no termina en una línea VERDICT:" end ]
        + [ $unres[] | "\(.id) [\(.sev)] de \(.author): \(.status)" ]
        + [ $o[] | select(.status == "RESUELTA" and ($disp[.id] // "") == "RECHAZADA" and ((.reason // "") == ""))
            | "\(.id): RESUELTA sin motivo sobre una objeción RECHAZADA por el registro (conceder exige nombrar el argumento)" ]
        + (if $hasreg == "1" then [ ledger_problems($o; $rows)[] | "registro: \(.)" ]
           else ["registro: registro.md no existe"] end)
        + [ $rows[] | select(.disp == "ABIERTA" and .sev == "P1") | "\(.id) [P1] sigue ABIERTA en el registro" ]
        + (if $audit != "" then [$audit] else [] end)
      ) as $reasons
    | {round: ($n | tonumber), consensus: ($reasons | length == 0), reasons: $reasons,
       verdicts: [ $rd[] | {letra: .author, verdict: verdict} ]}'
}

last_complete_round() {
  # last_complete_round <r1> <r2> — the highest N with both reviewer answers published.
  local r1="$1" r2="$2" best=0 f n
  for f in "$DOC_DIR/rondas/r"*"-$r1.md"; do
    [ -f "$f" ] || continue
    n="${f##*/r}"
    n="${n%-"$r1".md}"
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ -f "$(published_path "round-$((10#$n))" "$r2")" ] || continue
    [ "$((10#$n))" -gt "$best" ] && best="$((10#$n))"
  done
  printf '%s' "$best"
}

phase_complete() {
  local p="$1" L
  for L in A B C; do
    [ -f "$(published_path "$p" "$L")" ] || return 1
  done
  return 0
}

# --- the facts metadatos.md states, shared with report -------------------------
# usage_facts_json — the tokens: {astra, fable, nu, nf, sin_usage_definitivo,
# mensajes}. Astra: every usage file of every generation, each one ONCE —
# failed and interrupted turns included: the quota was spent all the same.
# Fable: every capture's usage file, plus the lower bound its captures declare
# (messages whose last transcript line carried no stop_reason).
usage_facts_json() {
  local key target f astra_sum fable_sum nu=0 nf=0 usage_list fable_list
  usage_list="$(mktemp "$RUN_DIR/.usage-list.XXXXXX")" || die "cannot create a temp file" 65
  fable_list="$(mktemp "$RUN_DIR/.fable-list.XXXXXX")" || { rm -f "$usage_list"; die "cannot create a temp file" 65; }
  for target in $(q -r '.astra_targets[]'); do
    key="$(target_key "$target")"
    for f in "$STATE_DIR/$key".t*.usage.json; do
      [ -f "$f" ] || continue
      printf '%s\n' "$f" >>"$usage_list"
      nu=$((nu + 1))
    done
  done
  for f in "$RUN_DIR"/fable.*.usage.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f" >>"$fable_list"
    nf=$((nf + 1))
  done
  astra_sum='{}'
  if [ "$nu" -gt 0 ]; then
    astra_sum="$(LC_ALL=C sort -u "$usage_list" | while IFS= read -r f; do jq -c 'objects' "$f" 2>/dev/null || true; done \
      | jq -sc 'reduce .[] as $u ({}; reduce ($u | to_entries[]) as $e (.;
          if ($e.value | type) == "number" then .[$e.key] = ((.[$e.key] // 0) + $e.value) else . end))')"
  fi
  fable_sum='{}'
  if [ "$nf" -gt 0 ]; then
    fable_sum="$(LC_ALL=C sort -u "$fable_list" | while IFS= read -r f; do jq -c 'objects' "$f" 2>/dev/null || true; done \
      | jq -sc 'reduce .[] as $u ({}; reduce ($u | to_entries[]) as $e (.;
          if ($e.value | type) == "number" then .[$e.key] = ((.[$e.key] // 0) + $e.value) else . end))')"
  fi
  rm -f "$usage_list" "$fable_list"
  q -c --argjson asum "$astra_sum" --argjson fsum "$fable_sum" --argjson nu "$nu" --argjson nf "$nf" '
    {astra: $asum, fable: $fsum, nu: $nu, nf: $nf,
     sin_usage_definitivo: ([ .captures[] | select(.captura == "capturado") | (.sin_usage_definitivo // 0) ] | add // 0),
     mensajes: ([ .captures[] | select(.captura == "capturado") | (.mensajes // 0) ] | add // 0)}'
}

# astra_metas_json — per-turn evidence of Astra: every entry of astra_turns
# plus the meta.json its wrapper wrote BEFORE the turn ({meta: null} when
# there is none).
astra_metas_json() {
  local metas
  metas="$(q -c '.astra_turns' | jq -c '.[]' | while IFS= read -r e; do
      t="$(printf '%s' "$e" | jq -r '.target')"
      nn="$(printf '%s' "$e" | jq -r '.turno // empty')"
      m='null'
      if [ -n "$nn" ] && [ -f "$STATE_DIR/$(target_key "$t").t$nn.meta.json" ]; then
        m="$(jq -c '.' "$STATE_DIR/$(target_key "$t").t$nn.meta.json" 2>/dev/null || printf 'null')"
      fi
      printf '%s' "$e" | jq -c --argjson m "$m" '. + {meta: $m}'
    done | jq -sc '.')" || die "cannot read the Astra turns of run.json" 65
  [ -n "$metas" ] || metas='[]'
  printf '%s' "$metas"
}

# --- the leader's effort, measured in its session's transcript -----------------
# resolve_link <path> — follow a symlink chain with plain readlink (BSD has no
# -f), at most 40 hops; prints the final path.
resolve_link() {
  local p="$1" t n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t="$(readlink "$p")" || break
    case "$t" in
      /*) p="$t" ;;
      *) p="$(dirname -- "$p")/$t" ;;
    esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}

# leader_effort_json <last-complete-round> — the leader's effort, measured: the
# session transcript is derived from every Fable output_file in run.json
# (…/<session>/subagents/agent-<id>.jsonl → …/<session>.jsonl), and in it the
# assistant lines that are not sidechain, deduplicated by message.id (the last
# line of each id), are counted by `effort` in two CLOSED windows whose limits
# are timestamps stored in run.json: intake (created → the brief's seal;
# informative only) and debate (the seal → the publish of the last complete
# round; with no complete round yet, the latest publish; with none, empty).
# Counting again gives the same result, however long the session keeps
# working. Best effort: it never changes an exit code.
leader_effort_json() {
  local n="$1" list out real sess total=0 seal
  seal="$(q -r '.seals.brief.sealed // empty')"
  if [ -z "$seal" ]; then
    jq -cn '{medido: false, motivo: "brief sin sellar"}'
    return 0
  fi
  list="$(mktemp "$RUN_DIR/.leader.XXXXXX")" || die "cannot create a temp file in $RUN_DIR" 65
  q -r '.agents[]?.output_file // empty' | while IFS= read -r out; do
    [ -n "$out" ] || continue
    real="$(resolve_link "$out")"
    case "$real" in
      */subagents/agent-*.jsonl)
        sess="${real%/subagents/*}.jsonl"
        if [ -f "$sess" ]; then printf '%s\n' "$sess"; fi
        ;;
    esac
  done | LC_ALL=C sort -u >"$list"
  total="$(LC_ALL=C wc -l <"$list" | LC_ALL=C tr -d ' ')"
  if [ "$total" -eq 0 ]; then
    rm -f "$list"
    jq -cn '{medido: false, motivo: "transcript de la sesión no resoluble desde los output_file de los agentes"}'
    return 0
  fi
  while IFS= read -r sess; do
    jq -cR 'fromjson? | select(type == "object" and .type == "assistant" and (.isSidechain != true)
      and ((.message.id // null) | type) == "string")
      | {id: .message.id, e: (.effort // null), t: (.timestamp // null)}' "$sess" 2>/dev/null || true
  done <"$list" | jq -sc --argjson st "$(q -c '{created, seals, perfil, publications: [(.publications // [])[] | {fase, publicado}]}')" \
    --argjson n "$n" --argjson ns "$total" '
    # Seconds since the epoch WITH the fraction: a transcript line at
    # 12:00:00.900Z is after a cutoff stored as 12:00:00Z.
    def ep: if type == "string" then
              (try (capture("^(?<b>[0-9T:-]+)(?<f>\\.[0-9]+)?Z$")
                    | ((.b + "Z") | fromdateiso8601) + (("0" + (.f // ".0")) | tonumber))
               catch null)
            else null end;
    def counts: {total: length,
                 por_esfuerzo: (group_by(.e) | map({key: (.[0].e // "sin dato" | tostring), value: length}) | from_entries)};
    ($st.created) as $c
    | ($st.seals.brief.sealed) as $s
    | ([ ($st.publications // [])[] | select(.fase == "round-\($n)") | .publicado ] | max) as $fr
    | ([ ($st.publications // [])[] | .publicado ] | max) as $fa
    | (if $n > 0 and $fr != null then $fr elif $fa != null then $fa else $s end) as $e
    | ($st.perfil.esfuerzo // (if $st.seals.brief.sha256 != null then "max" else null end)) as $lvl
    | ($c | ep) as $ce | ($s | ep) as $se | ($e | ep) as $ee
    # The window FIRST, then the dedup by message.id (the last line of each id
    # INSIDE the window): a line written after the cutoff never displaces one
    # that was counted, so later session work cannot change a closed count.
    | ([ .[] | . + {ep: (.t | ep)}
         | select(.ep != null and $ce != null and $ee != null and .ep >= $ce and .ep <= $ee) ]
       | reduce .[] as $m ({}; .[$m.id] = $m) | [ .[] ]) as $msgs
    | [ $msgs[] | select(.ep != null and $ce != null and $se != null and .ep >= $ce and .ep < $se) ] as $in
    | [ $msgs[] | select(.ep != null and $se != null and $ee != null and .ep >= $se and .ep <= $ee) ] as $de
    | {medido: true, sesiones: $ns, nivel: $lvl,
       ventana: {inicio: $c, sello: $s, fin: $e},
       intake: ($in | counts),
       debate: ($de | counts),
       fuera_de_nivel: ([ $de[] | select(.e != null and .e != $lvl) ] | counts)}'
  rm -f "$list"
}

# profile_json — the run's profile as the facts state it, or null.
profile_json() {
  run_profile
  if [ -z "$RUN_PROFILE" ]; then
    printf 'null'
    return 0
  fi
  jq -cn --arg n "$RUN_PROFILE" --arg e "$RUN_LEVEL" --arg a "$RUN_AGENT" \
    --argjson i "$( [ "$RUN_PROFILE_IMPLICIT" -eq 1 ] && printf true || printf false)" \
    --arg d "$(profile_display "$RUN_PROFILE")" \
    '{nombre: $n, nombre_visible: $d, esfuerzo: $e, agente: $a, implicito: $i}'
}

# On run.json: the evidence behind each seat's model, and the anomalies of the
# run — the lists metadatos.md prints and report shows.
# shellcheck disable=SC2016  # jq programs: their $names belong to jq
METADATA_JQ='
def effcount: to_entries | sort_by(-.value, .key) | map("\(.key) ×\(.value)") | join(", ");
def effkeys: to_entries | sort_by(-.value, .key) | map(.key);
def leader_evidence($l):
  "autodeclarado y confirmado en el gate"
  + (if $l == null or ($l.medido | not) then "; no medido"
     else "; medido (deduplicado por message.id) — debate: "
       + (if $l.debate.total == 0 then "sin mensajes" else ($l.debate.por_esfuerzo | effcount) end)
       + " · intake: "
       + (if $l.intake.total == 0 then "sin mensajes" else ($l.intake.por_esfuerzo | effcount) end)
     end);
def seat_facts($metas; $lider; $perfil):
  . as $r
  | [ $r.letters | to_entries[] | .key as $l | .value as $s
      | if $s == "lider" then
          {letra: $l, asiento: $s, modelos: ["\($r.leader_model // "?")"], effort: ($perfil.esfuerzo // null),
           esfuerzos: (if $lider != null and $lider.medido then ($lider.debate.por_esfuerzo | effkeys) else [] end),
           medicion: $lider}
        elif $s == "astra" then
          {letra: $l, asiento: $s,
           modelos: ([ $metas[] | select(.meta != null) | "\(.meta.model)/\(.meta.effort)" ] | unique),
           esfuerzos: ([ $metas[] | select(.meta != null and .tipo == "sustantivo") | .meta.effort | strings ] | unique),
           evidencia: [ $metas[] | select(.meta != null) | "\(.target) t\(.turno)" ]}
        else
          {letra: $l, asiento: $s,
           modelos: ([ $r.captures[] | .modelos[]? ] | unique),
           esfuerzos: ([ $r.captures[] | .esfuerzos[]? ] | unique),
           agentes: ([ $r.captures[] | .agentes[]? ] | unique),
           transcrito: any($r.captures[]; .captura == "transcrito"),
           capturas: ($r.captures | length)}
        end ];
def anomaly_list($lider):
  . as $r
  | [ ( $r.prompts[] | select(.recordatorio) | "recordatorio: \(.fase) letra \(.letra) (a\(.intento))" ),
      ( $r.captures[] | select(.captura == "transcrito") | "transcripción a mano (--manual): \(.fase) a\(.intento) \(.tipo) — modelo no verificado" ),
      ( $r.prompts[] | select(.historia) | "reconstrucción: \(.fase) letra \(.letra) (a\(.intento), con historial)" ),
      ( if ($r.astra_targets | length) > 1 then "generaciones del hilo de Astra: \($r.astra_targets | join(", "))" else empty end ),
      ( if ($r.agents | length) > 1 then "agentes de Fable registrados: \($r.agents | length) (reconstrucciones)" else empty end ),
      ( $r.astra_turns[] | select(.estado != "done") | "turno de Astra \(.fase) a\(.intento) \(.tipo): \(.estado)\(if .nota then " — " + .nota else "" end)" ),
      ( ($r.anomalies // [])[] | select((.tipo // "lectura-fuera-de-alcance") == "lectura-fuera-de-alcance")
        | "lectura fuera de alcance (\(.asiento), \(.fase) a\(.intento)): \(.rutas // [.comando] | join(" · "))" ),
      ( $r.captures[] | select(.captura == "capturado" and .esfuerzo == "no verificado")
        | "esfuerzo de Fable no verificado (el transcript no trae effort): \(.fase) a\(.intento) \(.tipo)" ),
      ( $r.captures[] | select(.captura == "capturado" and .agente == "no verificado")
        | "tipo de agente de Fable no verificado (el transcript no trae attributionAgent): \(.fase) a\(.intento) \(.tipo)" ),
      ( ($r.anomalies // [])[] | select(.tipo == "esfuerzo-astra-no-verificado")
        | "esfuerzo de Astra no verificado (sin meta.json): \(.fase) a\(.intento) — \(.target) t\(.turno)" ),
      ( if $lider != null and $lider.medido and $lider.fuera_de_nivel.total > 0
        then "líder fuera del nivel del perfil durante el debate: \($lider.fuera_de_nivel.por_esfuerzo | effcount) de \($lider.debate.total) mensajes"
        else empty end )
    ];
'

write_metadata() {
  # write_metadata <last-complete-round> <consensus-json-or-empty> — composes
  # metadatos.md from the leader's snapshot (RUN_DIR/lider-esfuerzo.json),
  # written atomically in the same call.
  local n="$1" cj="$2" tmp uf metas lider perfil
  uf="$(usage_facts_json)"
  metas="$(astra_metas_json)"
  perfil="$(profile_json)"
  tmp="$(mktemp "$RUN_DIR/.lider-esfuerzo.XXXXXX")" || die "cannot create a temp file in $RUN_DIR" 65
  leader_effort_json "$n" >"$tmp" 2>/dev/null || true
  jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 || jq -cn '{medido: false, motivo: "medición fallida"}' >"$tmp"
  write_atomic "$RUN_DIR/lider-esfuerzo.json" "$tmp"
  lider="$(jq -c '.' "$RUN_DIR/lider-esfuerzo.json")"
  tmp="$(mktemp "$DOC_DIR/.metadatos.XXXXXX")" || die "cannot create a temp file in $DOC_DIR" 65
  q -r --argjson metas "$metas" --argjson u "$uf" --argjson cj "${cj:-null}" --argjson n "$n" \
    --argjson lider "$lider" --argjson perfil "$perfil" "$METADATA_JQ"'
    def kv: to_entries | map("\(.key)=\(.value)") | join(" ");
    . as $r
    | "# Metadatos del consejo \($r.run_id)",
      "",
      "- Creado: \($r.created) · modo: \($r.mode) · tope de rondas: \($r.max_rounds) · rondas completas: \($n)",
      "- Perfil: \(if $perfil == null then "sin elegir" elif $perfil.implicito then "\($perfil.nombre_visible) (\($perfil.esfuerzo)) — implícito, run anterior a los perfiles" else "\($perfil.nombre_visible) (\($perfil.esfuerzo): líder, Fable y Astra)" end)",
      "- Estado: \(if $cj == null then "sin ninguna ronda completa" elif $cj.consensus then "CONSENSO en la ronda \($cj.round)" else "SIN_CONSENSO tras la ronda \($cj.round)" end)",
      "",
      "## Letras (reveladas al final)",
      "",
      "| Letra | Asiento | Modelo / effort | Evidencia |",
      "| --- | --- | --- | --- |",
      ( seat_facts($metas; $lider; $perfil)[]
        | if .asiento == "lider" then
            "| \(.letra) | líder | \(.modelos[0]) / \(.effort // "sin perfil") | \(leader_evidence($lider)) |"
          elif .asiento == "astra" then
            "| \(.letra) | Astra (Codex) | \(if (.modelos | length) > 0 then (.modelos | join(", ")) else "sin turnos con meta.json" end) | meta.json de cada turno (\(.evidencia | join(", "))) |"
          else
            "| \(.letra) | Fable (Claude) | \(if (.modelos | length) > 0 then (.modelos | join(", ")) else "no verificado" end) / \(if (.esfuerzos | length) > 0 then (.esfuerzos | join(", ")) else "no verificado" end) | modelos y esfuerzos de cada captura del transcript\(if (.agentes | length) > 0 then " (agente: \(.agentes | join(", ")))" else "" end)\(if .transcrito then "; hay capturas transcritas a mano (modelo no verificado)" else "" end) |"
          end ),
      "",
      "## Turnos de Astra",
      "",
      ( if ($metas | length) == 0 then "- ninguno" else
          ( $metas[] | "- \(.fase) a\(.intento) \(.tipo) — \(.estado)\(if .recuperado == true then " (recuperado)" else "" end) · \(.target) t\(.turno // "-")\(if .meta != null then " · " + (.meta | kv) else "" end)" )
        end ),
      "",
      "## Capturas de Fable",
      "",
      ( if ($r.captures | length) == 0 then "- ninguna" else
          ( $r.captures[] | "- \(.fase) a\(.intento) \(.tipo) — \(.captura), modelo \(.modelo)\(if (.modelos | length) > 0 then ": " + (.modelos | join(", ")) else "" end)" )
        end ),
      "",
      "## Rondas y veredictos",
      "",
      ( if $cj == null then "- ninguna ronda completa" else
          "- última ronda completa: \($cj.round) — " + ([ $cj.verdicts[] | "\(.letra) \(.verdict // "sin VERDICT")" ] | join(" · ")),
          ( $cj.reasons[] | "  - \(.)" )
        end ),
      "",
      "## Anomalías",
      "",
      ( anomaly_list($lider) | if length == 0 then "- ninguna" else .[] | "- \(.)" end ),
      "",
      "## Tokens",
      "",
      "- Astra: \(if ($u.astra | length) == 0 then "sin ficheros de uso" else ($u.astra | kv) end) (\($u.nu) ficheros t<N>.usage.json de \($r.astra_targets | length) generación(es), cada uno una vez, también los de turnos fallidos o interrumpidos)",
      ( $u.sin_usage_definitivo as $fpart
        | $u.mensajes as $fmsgs
        | "- Fable: \(if ($u.fable | length) == 0 then "sin ficheros de uso" else ($u.fable | kv) end) (\($u.nf) capturas, deduplicadas por message.id)\(if $fpart > 0 then " — COTA INFERIOR: \($fpart) de \($fmsgs) mensajes del transcript sin usage definitivo (su última línea no trae stop_reason)" else "" end)" ),
      "- líder: no medido"
    ' >"$tmp" || { rm -f "$tmp"; die "could not compose metadatos.md" 65; }
  write_atomic "$DOC_DIR/metadatos.md" "$tmp"
}

# --- the report's documents and their fingerprint -------------------------------
REPORT_MARK='<!-- COUNCIL_DATA -->'

# report_docs <dir> — the CLOSED list of the documents report embeds, as paths
# relative to <dir>, in LC_ALL=C order: brief, informe, estrategia-final,
# metadatos, registro, every sintesis-v<N> and auditoria-v<N>, and the
# published answers (1-propuestas/<L>, 2-contrainterrogatorio/<L>,
# rondas/r<N>-<L>). Never prompts/, never RUN_DIR, never a stray file.
report_docs() {
  local d="$1" rel f n L
  {
    for rel in brief.md informe.md estrategia-final.md metadatos.md registro.md; do
      if [ -f "$d/$rel" ]; then printf '%s\n' "$rel"; fi
    done
    for f in "$d"/sintesis-v*.md "$d"/auditoria-v*.md; do
      [ -f "$f" ] || continue
      rel="${f##*/}"
      case "$rel" in
        sintesis-v*) n="${rel#sintesis-v}" ;;
        *) n="${rel#auditoria-v}" ;;
      esac
      n="${n%.md}"
      case "$n" in '' | *[!0-9]*) continue ;; esac
      printf '%s\n' "$rel"
    done
    for L in A B C; do
      if [ -f "$d/1-propuestas/$L.md" ]; then printf '1-propuestas/%s.md\n' "$L"; fi
      if [ -f "$d/2-contrainterrogatorio/$L.md" ]; then printf '2-contrainterrogatorio/%s.md\n' "$L"; fi
      for f in "$d/rondas/r"*"-$L.md"; do
        [ -f "$f" ] || continue
        n="${f##*/r}"
        n="${n%-"$L".md}"
        case "$n" in '' | *[!0-9]*) continue ;; esac
        printf 'rondas/%s\n' "${f##*/}"
      done
    done
  } | LC_ALL=C sort
}

# report_digest <dir> [<leader-snapshot>] — the fingerprint of the documents
# report embeds: the sha256 of the LC_ALL=C-sorted lines `<relative path>\t<sha256
# of the file>\n` of report_docs <dir>, plus a line `lider-esfuerzo.json\t<sha256>`
# when the leader's effort snapshot exists. report computes it on its snapshot
# and writes it into informe.html; status recomputes it on the live files.
# Content, never mtime.
report_digest() {
  local d="$1" lider="${2:-}" rels raw rel sha out="" rc=0
  rels="$(mktemp "$RUN_DIR/.digest-docs.XXXXXX")" || return 1
  raw="$(mktemp "$RUN_DIR/.digest.XXXXXX")" || { rm -f "$rels"; return 1; }
  report_docs "$d" >"$rels" || rc=1
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      sha="$(file_sha256 "$d/$rel")" || { rc=1; break; }
      printf '%s\t%s\n' "$rel" "$sha" >>"$raw"
    done <"$rels"
  fi
  if [ "$rc" -eq 0 ] && [ -n "$lider" ] && [ -f "$lider" ]; then
    if sha="$(file_sha256 "$lider")"; then
      printf 'lider-esfuerzo.json\t%s\n' "$sha" >>"$raw"
    else
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    if LC_ALL=C sort "$raw" >"$rels"; then
      out="$(file_sha256 "$rels")" || rc=1
    else
      rc=1
    fi
  fi
  rm -f "$rels" "$raw"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

# report_fresh — informe.html carries exactly one fingerprint line, and it is
# the fingerprint of the documents as they are now.
report_fresh() {
  local want have
  want="$(LC_ALL=C sed -n 's/^<!-- tandem-council-digest: \([0-9a-f]\{64\}\) -->$/\1/p' "$DOC_DIR/informe.html" 2>/dev/null)" \
    || return 1
  case "$want" in '' | *"$NL"*) return 1 ;; esac
  have="$(report_digest "$DOC_DIR" "$RUN_DIR/lider-esfuerzo.json")" || return 1
  [ "$want" = "$have" ]
}

cmd_status() {
  [ $# -ge 1 ] || die "usage: council.sh status <run-id> [--metadata]" 64
  run_id_validate "$1"
  shift
  local metadata=0 r1 r2 n cj phase max nxt tmp lider_l
  while [ $# -gt 0 ]; do
    case "$1" in
      --metadata) metadata=1 ;;
      *) die "unknown argument to status: $1" 64 ;;
    esac
    shift
  done
  council_paths
  need_jq
  run_require
  lock_acquire
  state_load
  recover_entries ""
  state_save
  lider_l="$(seat_letter lider)"
  r1="$(seat_letter astra)"
  r2="$(seat_letter fable)"
  [ "$r1" \< "$r2" ] || { tmp="$r1"; r1="$r2"; r2="$tmp"; }
  max="$(q -r '.max_rounds')"
  n="$(last_complete_round "$r1" "$r2")"
  cj=""
  [ "$n" -gt 0 ] && cj="$(consensus_json "$n" "$r1" "$r2")"

  if [ -f "$DOC_DIR/informe.md" ]; then
    # The visual report's freshness is informative: it never changes the
    # STATUS: line nor the exit code.
    if [ ! -f "$DOC_DIR/informe.html" ]; then
      phase="informe (escrito; falta informe.html: council.sh report)"
    elif report_fresh; then
      phase="informe (escrito)"
    else
      phase="informe (escrito; informe.html desactualizado: council.sh report)"
    fi
  elif [ ! -f "$DOC_DIR/brief.md" ]; then
    phase="entrevista (sin brief.md)"
  elif [ -z "$(q -r '.seals.brief.sha256 // empty')" ]; then
    phase="brief (pendiente de aprobación y de seal brief)"
  elif ! phase_complete propose; then
    phase="propose"
  elif ! phase_complete cross; then
    phase="cross"
  elif [ "$n" -eq 0 ]; then
    if [ ! -f "$DOC_DIR/sintesis-v1.md" ]; then phase="sintesis-v1"
    elif [ ! -f "$DOC_DIR/auditoria-v1.md" ]; then phase="auditoria-v1"
    else phase="round-1"
    fi
  elif [ "$(printf '%s' "$cj" | jq -r '.consensus')" = "true" ]; then
    phase="informe (CONSENSO en la ronda $n)"
  elif [ "$n" -ge "$max" ]; then
    phase="informe (SIN_CONSENSO tras el tope de $max rondas)"
  else
    nxt=$((n + 1))
    if [ ! -f "$DOC_DIR/sintesis-v$nxt.md" ]; then phase="sintesis-v$nxt"
    elif [ ! -f "$DOC_DIR/auditoria-v$nxt.md" ]; then phase="auditoria-v$nxt"
    else phase="round-$nxt"
    fi
  fi
  printf 'PHASE: %s\n' "$phase"

  if [ "$metadata" -eq 1 ]; then
    if [ "$n" -gt 0 ]; then
      tmp="$(mktemp "$DOC_DIR/.estrategia.XXXXXX")" || die "cannot create a temp file in $DOC_DIR" 65
      cp "$DOC_DIR/sintesis-v$n.md" "$tmp" || { rm -f "$tmp"; die "cannot copy sintesis-v$n.md" 65; }
      write_atomic "$DOC_DIR/estrategia-final.md" "$tmp"
    else
      printf 'tandem: no complete round yet — estrategia-final.md not written\n' >&2
    fi
    write_metadata "$n" "$cj"
  fi
  lock_release

  # The frozen profile and the subagent_type of Fable, for a recovery after a
  # compaction; and whether THIS environment can still run it (informative:
  # it never changes STATUS: nor the exit code — the skill stops on a `no`).
  run_profile
  if [ -n "$RUN_PROFILE" ]; then
    printf 'PERFIL: %s (%s)%s\n' "$RUN_PROFILE" "$RUN_LEVEL" \
      "$( [ "$RUN_PROFILE_IMPLICIT" -eq 1 ] && printf ' — implícito (run anterior a los perfiles)')"
    printf 'FABLE_AGENT: %s\n' "$RUN_AGENT"
    if profile_env_check "$RUN_LEVEL" "$(q -r '.mode')" astra; then
      printf 'PERFIL_VIABLE: sí\n'
    else
      printf 'PERFIL_VIABLE: no — %s\n' "$(causes_inline)"
    fi
  else
    printf 'PERFIL: sin elegir (council.sh profile %s exploratorio|estandar|critico)\n' "$RUN_ID"
    printf 'FABLE_AGENT: ninguno (sin perfil)\n'
    printf 'PERFIL_VIABLE: sin perfil\n'
  fi

  if [ -n "$cj" ] && [ "$(printf '%s' "$cj" | jq -r '.consensus')" = "true" ]; then
    printf 'STATUS: CONSENSO\n'
    printf -- '- ronda %s: %s\n' "$n" "$(printf '%s' "$cj" | jq -r '[.verdicts[] | "\(.letra) \(.verdict)"] | join(" · ")')"
    exit 0
  fi
  printf 'STATUS: SIN_CONSENSO\n'
  if [ -z "$cj" ]; then
    printf -- '- ninguna ronda tiene publicadas las dos respuestas revisoras\n'
  else
    printf '%s' "$cj" | jq -r '.reasons[] | "- \(.)"'
  fi
  exit 1
}

# =============================================================================
# report — informe.html, the visual form of the finished report
# =============================================================================
# One self-contained page, with no network, that embeds the closed list of
# documents (report_docs) and the facts computed HERE, with the same grammar as
# ledger, status and metadatos.md: the page's JavaScript only presents. The
# Markdown files stay the record with authority; the HTML is derived from them.
# No lock (the moderator writes the Markdown without one): report copies the
# documents ONCE into a private snapshot and derives the embedded texts, the
# facts and the fingerprint from those same bytes — a concurrent edit yields at
# worst a page coherent with the previous version, which status sees stale.
cmd_report() {
  [ $# -eq 1 ] || die "usage: council.sh report <run-id>" 64
  run_id_validate "$1"
  local tpl live missing f rel marks snap work r1 r2 n cj identical an afile digest prog i
  local -a embed
  council_paths
  need_jq
  run_require
  state_load
  live="$DOC_DIR"

  # The three outputs of step 6: never the visual form of a run half-way.
  missing=""
  for f in informe.md estrategia-final.md metadatos.md; do
    if [ ! -f "$live/$f" ]; then missing="$missing${missing:+, }$live/$f"; fi
  done
  [ -z "$missing" ] \
    || die "no informe.html for a report that is not finished — missing: $missing (step 6: status --metadata, then informe.md)" 1
  tpl="${TANDEM_COUNCIL_REPORT_TEMPLATE:-$PLUGIN_ROOT/skills/council/report/informe.tpl.html}"
  [ -f "$tpl" ] || die "report template not found: $tpl" 65
  marks="$(LC_ALL=C grep -cxF -- "$REPORT_MARK" "$tpl" 2>/dev/null || true)"
  [ "$marks" = "1" ] \
    || die "the report template must hold exactly one line $REPORT_MARK (found ${marks:-0}): $tpl" 65

  # The snapshot: every document copied once; everything below reads the copy.
  REPORT_DIR="$(mktemp -d "$RUN_DIR/.report.XXXXXX")" || die "cannot create a temp directory in $RUN_DIR" 65
  snap="$REPORT_DIR/docs"
  work="$REPORT_DIR/work"
  mkdir "$snap" "$work" || die "cannot create the report snapshot in $REPORT_DIR" 65
  report_docs "$live" >"$work/list" || die "cannot list the documents of $live" 65
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in */*) mkdir -p "$snap/${rel%/*}" || die "cannot create the report snapshot in $REPORT_DIR" 65 ;; esac
    cp "$live/$rel" "$snap/$rel" || die "cannot copy $live/$rel into the report snapshot" 65
  done <"$work/list"
  DOC_DIR="$snap"

  # The facts, with the grammar of ledger, status and metadatos.md.
  r1="$(seat_letter astra)"
  r2="$(seat_letter fable)"
  if [ -z "$r1" ] || [ -z "$r2" ]; then die "run.json assigns no letter to astra or to fable" 65; fi
  if [ "$r2" \< "$r1" ]; then f="$r1"; r1="$r2"; r2="$f"; fi
  n="$(last_complete_round "$r1" "$r2")"
  cj="null"
  if [ "$n" -gt 0 ]; then cj="$(consensus_json "$n" "$r1" "$r2")"; fi
  identical=false
  if [ "$n" -gt 0 ] && [ -f "$snap/sintesis-v$n.md" ] \
    && cmp -s "$snap/estrategia-final.md" "$snap/sintesis-v$n.md"; then
    identical=true
  fi
  docs_json >"$work/parser.json"
  registro_json >"$work/registro.json"
  usage_facts_json >"$work/usage.json"
  astra_metas_json >"$work/metas.json"
  profile_json >"$work/perfil.json"
  # The leader's effort: the snapshot status --metadata wrote, read ONCE —
  # report never scans a transcript itself.
  if [ -f "$RUN_DIR/lider-esfuerzo.json" ]; then
    cp "$RUN_DIR/lider-esfuerzo.json" "$REPORT_DIR/lider-esfuerzo.json" \
      || die "cannot copy $RUN_DIR/lider-esfuerzo.json into the report snapshot" 65
  fi
  if [ -f "$REPORT_DIR/lider-esfuerzo.json" ] && jq -e 'type == "object"' "$REPORT_DIR/lider-esfuerzo.json" >/dev/null 2>&1; then
    jq -c '.' "$REPORT_DIR/lider-esfuerzo.json" >"$work/lider.json"
  else
    jq -cn '{medido: false, motivo: "sin instantánea (status --metadata)"}' >"$work/lider.json"
  fi
  an=0
  afile=""
  for f in "$snap"/auditoria-v*.md; do
    [ -f "$f" ] || continue
    rel="${f##*/}"
    rel="${rel#auditoria-v}"
    rel="${rel%.md}"
    case "$rel" in '' | *[!0-9]*) continue ;; esac
    if [ "$((10#$rel))" -gt "$an" ]; then
      an="$((10#$rel))"
      afile="${f##*/}"
    fi
  done
  if [ -n "$afile" ]; then
    jq -Rsc --arg f "$afile" "$COUNCIL_JQ"'split("\n") | sources_of($f)' "$snap/$afile" >"$work/sources.json" \
      || die "cannot read the sources of $afile" 65
  else
    printf '{"file":null,"offline":false,"items":[]}' >"$work/sources.json"
  fi

  # The documents, each one whole, keyed by its path relative to DOC_DIR — in
  # ONE jq call (a path of the closed list holds only [A-Za-z0-9/.-], so it can
  # be spelled as a key of the program).
  prog=""
  i=0
  embed=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    embed+=(--rawfile "d$i" "$snap/$rel")
    prog="$prog${prog:+, }\"$rel\": \$d$i"
    i=$((i + 1))
  done <"$work/list"
  if [ "$i" -gt 0 ]; then
    jq -nc "${embed[@]}" "{$prog}" >"$work/docs.json" || die "cannot embed the documents" 65
  else
    printf '{}' >"$work/docs.json"
  fi
  digest="$(report_digest "$snap" "$REPORT_DIR/lider-esfuerzo.json")" || die "cannot fingerprint the documents (no shasum/sha256sum?)" 65

  # The payload: no `<` byte survives, so no text of a seat can close the
  # <script> that holds it, nor open a comment.
  q -j --slurpfile docs "$work/docs.json" --slurpfile parser "$work/parser.json" \
    --slurpfile reg "$work/registro.json" --slurpfile usage "$work/usage.json" \
    --slurpfile metas "$work/metas.json" --slurpfile sources "$work/sources.json" \
    --slurpfile lider "$work/lider.json" --slurpfile perfil "$work/perfil.json" \
    --argjson cj "$cj" --argjson n "$n" --argjson identical "$identical" \
    --arg r1 "$r1" --arg r2 "$r2" --arg generated "$(now_utc)" "$COUNCIL_JQ$METADATA_JQ"'
    . as $r
    | $parser[0] as $d
    | (($cj // {round: null, consensus: false,
                reasons: ["ninguna ronda tiene publicadas las dos respuestas revisoras"], verdicts: []})
       + {last_round: $n, max_rounds: $r.max_rounds}) as $status
    | {schema: 1,
       generated: $generated,
       run: {run_id: $r.run_id, created: $r.created, mode: $r.mode, max_rounds: $r.max_rounds,
             letters: $r.letters, leader_model: ($r.leader_model // null), perfil: $perfil[0]},
       docs: $docs[0],
       facts: {
         objections: ([ ($d | objections)[] | . + {detail: detail_of($d)} ] | sort_by(.author, .n)),
         events: ($d | events),
         rows: ($reg[0] | rows),
         rounds: ($d | rounds_of($r1; $r2)),
         status: $status,
         strategy: {last_round: $n,
                    synthesis: (if $n > 0 then "sintesis-v\($n).md" else null end),
                    identical: $identical,
                    consensus: $status.consensus},
         sources: $sources[0],
         seats: seat_facts($metas[0]; $lider[0]; $perfil[0]),
         tokens: $usage[0],
         astra_turns: [ $metas[0][] | {fase, intento, tipo, target, estado, turno,
                          recuperado: (.recuperado // false), nota: (.nota // null),
                          inicio: (.inicio // null), fin: (.fin // null), exit: (.exit // null), meta} ],
         anomalies: anomaly_list($lider[0])}}
    | tojson | split("<") | join("\\u003c")' >"$work/payload.json" || die "could not compute the facts of the report" 65

  # Compose next to the destination, then rename into place.
  REPORT_TMP="$(mktemp "$live/.informe.html.XXXXXX")" || die "cannot create a temp file in $live" 65
  {
    LC_ALL=C awk -v m="$REPORT_MARK" '$0 == m { exit } { print }' "$tpl"
    printf '<script type="application/json" id="council-data">'
    cat "$work/payload.json"
    printf '</script>\n<!-- tandem-council-digest: %s -->\n' "$digest"
    LC_ALL=C awk -v m="$REPORT_MARK" 'f { print } $0 == m { f = 1 }' "$tpl"
  } >"$REPORT_TMP" || die "could not compose informe.html" 65
  write_atomic "$live/informe.html" "$REPORT_TMP"
  REPORT_TMP=""
  DOC_DIR="$live"
  rm -rf "$REPORT_DIR"
  REPORT_DIR=""
  printf 'INFORME HTML: %s\n' "$live/informe.html"
}

# =============================================================================
# dispatch
# =============================================================================
[ $# -ge 1 ] || council_usage
SUBCMD="$1"
shift
case "$SUBCMD" in
  -h | --help | help) council_usage 0 ;;
esac
council_env_validate
case "$SUBCMD" in
  preflight) cmd_preflight "$@" ;;
  init) cmd_init "$@" ;;
  profile) cmd_profile "$@" ;;
  seal) cmd_seal "$@" ;;
  record-agent) cmd_record_agent "$@" ;;
  astra) cmd_astra "$@" ;;
  unblock) cmd_unblock "$@" ;;
  stage) cmd_stage "$@" ;;
  capture) cmd_capture "$@" ;;
  publish) cmd_publish "$@" ;;
  ledger) cmd_ledger "$@" ;;
  status) cmd_status "$@" ;;
  report) cmd_report "$@" ;;
  *)
    printf 'tandem: unknown council subcommand: %s\n' "$SUBCMD" >&2
    council_usage
    ;;
esac
