#!/usr/bin/env bash
# shellcheck disable=SC2016  # q/upd/jq programs: every single-quoted $name here is jq's
# tandem — the executable contract of the council (/tandem:council).
#
# Three frontier seats of two families weigh an idea and optimise the strategy
# to reach a goal: the session (Opus 5.5, max) leads, moderates and synthesises;
# Fable 5.1 (a persistent Claude subagent, agents/council-fable*.md) and GPT-6
# Astra (a persistent Codex thread, role `council`) propose blind, cross-examine
# each other and review the synthesis round by round, until consensus or the
# round cap. Every seat is read-only. skills/council/SKILL.md is the protocol;
# THIS script is the part of it no model is trusted to do by itself: anonymous
# letters, sealed contributions, byte-faithful channels, the turn lifecycle,
# attempt and turn caps, the objection ledger and the consensus rule.
#
# usage: council.sh <subcommand> [args…]
#   preflight                                    zero turns; reports EVERY problem
#   init <run-id> [--offline]
#   seal <run-id> brief|propose|cross
#   record-agent <run-id> <agent-id> <output-file>
#   astra <run-id> <phase> [--reminder]          the ONLY way an Astra turn starts
#   unblock <run-id> <target>                    by hand only
#   stage <run-id> <phase> <letter> [--with-history | --reminder]
#   capture <run-id> <phase> [--reminder] [--manual]
#   publish <run-id> <phase>
#   ledger <run-id>
#   status <run-id> [--metadata]
#   <phase>  propose | cross | round-<N>     <run-id>  YYYY-MM-DD-<slug>
#
# Paths. DOC_DIR = ${TANDEM_COUNCIL_DIR:-docs/council}/<run-id>, relative to the
# project (CLAUDE_PROJECT_DIR, else $PWD): everything a human reads — brief,
# staged prompts, published answers, syntheses, audits, register, report.
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
# swarm's slots.
#
# env — every TANDEM_COUNCIL_* variable follows the ${VAR+set} discipline:
# defined and empty is a usage error (64), never "unset".
#   TANDEM_COUNCIL_DIR            base of the human-readable artefacts (docs/council)
#   TANDEM_COUNCIL_ROUNDS         review-round cap (default 4)
#   TANDEM_COUNCIL_INTAKE         ask (default) | auto — the skill reads it
#   TANDEM_COUNCIL_MODEL/_EFFORT  Astra's model/effort (resolve_role council)
#   TANDEM_COUNCIL_LEADER_MODEL   the leader the skill expects (default below)
#   TANDEM_COUNCIL_LOCK_TIMEOUT   seconds to wait for the run lock (default 30)
#   TANDEM_CLAUDE_MANAGED_SETTINGS  managed settings file the preflight reads
#                                 (default: the platform's standard path)
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
COUNCIL_AGENT="$PLUGIN_ROOT/agents/council-fable.md"
COUNCIL_AGENT_OFFLINE="$PLUGIN_ROOT/agents/council-fable-offline.md"
# The ONLY model literal of this script: the leader the skill expects. Fable's
# pin lives in the two agents' frontmatter and is READ from there (fable_pin);
# Astra's default comes from _models.sh through resolve_role.
COUNCIL_LEADER_DEFAULT="claude-opus-5-5"
NL='
'

council_usage() {
  cat >&2 <<'EOF'
usage: council.sh <subcommand> [args…]
  preflight
  init <run-id> [--offline]
  seal <run-id> brief|propose|cross
  record-agent <run-id> <agent-id> <output-file>
  astra <run-id> <phase> [--reminder]
  unblock <run-id> <target>
  stage <run-id> <phase> <letter> [--with-history | --reminder]
  capture <run-id> <phase> [--reminder] [--manual]
  publish <run-id> <phase>
  ledger <run-id>
  status <run-id> [--metadata]
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

council_on_exit() {
  local rc=$?
  [ -n "${STATE_TMP:-}" ] && rm -f "$STATE_TMP" 2>/dev/null
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

# --- the line parser shared by stage, ledger and status ------------------------
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

FABLE_PIN=""
FABLE_PIN_ERR=""
fable_pin() {
  # Sets FABLE_PIN, or FABLE_PIN_ERR with the reason it cannot be trusted.
  local ma mb ea eb
  FABLE_PIN=""
  FABLE_PIN_ERR=""
  if [ ! -f "$COUNCIL_AGENT" ] || [ ! -f "$COUNCIL_AGENT_OFFLINE" ]; then
    FABLE_PIN_ERR="missing agent definition(s) under $PLUGIN_ROOT/agents (council-fable.md, council-fable-offline.md)"
    return 1
  fi
  ma="$(fm_value "$COUNCIL_AGENT" model || true)"
  mb="$(fm_value "$COUNCIL_AGENT_OFFLINE" model || true)"
  ea="$(fm_value "$COUNCIL_AGENT" effort || true)"
  eb="$(fm_value "$COUNCIL_AGENT_OFFLINE" effort || true)"
  if [ "$ma" != "$mb" ] || [ "$ea" != "$eb" ]; then
    FABLE_PIN_ERR="the twins disagree: council-fable.md model=${ma:-?} effort=${ea:-?}, council-fable-offline.md model=${mb:-?} effort=${eb:-?}"
    return 1
  fi
  case "$ma" in
    '') FABLE_PIN_ERR="agents/council-fable.md declares no model"; return 1 ;;
    fable | opus | sonnet | haiku | inherit)
      FABLE_PIN_ERR="agents/council-fable.md pins the alias '$ma', not a full model id (an alias can resolve to another generation)"
      return 1
      ;;
  esac
  FABLE_PIN="$ma"
  FABLE_EFFORT="$ea"
  return 0
}
FABLE_EFFORT=""

# =============================================================================
# preflight
# =============================================================================
PF_FAIL=0
pf_ok() { printf '  ok    %s\n' "$1"; }
pf_bad() { printf '  FAIL  %s\n' "$1"; PF_FAIL=1; }
pf_info() { printf '        %s\n' "$1"; }

cmd_preflight() {
  [ $# -eq 0 ] || die "usage: council.sh preflight" 64
  local rounds intake rounds_ok=1 have_jq=1 catalog rc settings f val project
  local managed fpin
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

  # (c) Astra's effective model/effort against the CLI catalog — fail-closed:
  # it is the only free check before a max-effort turn is spent.
  command -v jq >/dev/null 2>&1 || have_jq=0
  resolve_role council
  if [ "$have_jq" -eq 0 ]; then
    pf_bad "jq not found — the run cannot work and the catalog cannot be read (install: brew install jq)"
  elif ! command -v codex >/dev/null 2>&1; then
    pf_bad "Astra model catalog unavailable: codex CLI not found in PATH"
  else
    rc=0
    catalog="$(codex debug models 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$catalog" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
      pf_bad "Astra model catalog unavailable: 'codex debug models' failed or did not print {\"models\":[…]} (rc $rc)"
    elif ! printf '%s' "$catalog" | jq -e --arg m "$CODEX_MODEL" \
      'any(.models[]; .slug == $m)' >/dev/null 2>&1; then
      pf_bad "Astra model '$CODEX_MODEL' is not in the catalog of 'codex debug models' — fix TANDEM_COUNCIL_MODEL"
    elif ! printf '%s' "$catalog" | jq -e --arg m "$CODEX_MODEL" --arg e "$CODEX_EFFORT" \
      'any(.models[] | select(.slug == $m) | .supported_reasoning_levels[]?; .effort == $e)' \
      >/dev/null 2>&1; then
      pf_bad "Astra model '$CODEX_MODEL' does not support effort '$CODEX_EFFORT' (supported: $(printf '%s' "$catalog" \
        | jq -r --arg m "$CODEX_MODEL" '[.models[] | select(.slug == $m) | .supported_reasoning_levels[]?.effort] | join(", ")' 2>/dev/null)) — fix TANDEM_COUNCIL_EFFORT"
    else
      pf_ok "Astra: $CODEX_MODEL supports effort $CODEX_EFFORT (codex debug models)"
    fi
  fi

  # (g) the Claude seat's pin, read from the two agents (never a literal here).
  fpin=""
  if fable_pin; then
    fpin="$FABLE_PIN"
    pf_ok "Fable seat: model=$FABLE_PIN effort=${FABLE_EFFORT:-?} (agents/council-fable.md = agents/council-fable-offline.md)"
  else
    pf_bad "Fable seat: $FABLE_PIN_ERR"
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

  # (e) a global effort level wins over every seat's frontmatter and the leader.
  case "${CLAUDE_CODE_EFFORT_LEVEL+set}" in
    set)
      if [ "$CLAUDE_CODE_EFFORT_LEVEL" = "max" ]; then
        pf_ok "CLAUDE_CODE_EFFORT_LEVEL=max"
      else
        pf_bad "CLAUDE_CODE_EFFORT_LEVEL='$CLAUDE_CODE_EFFORT_LEVEL' overrides the frontmatter effort of every seat and the leader's session — unset it or set it to exactly max"
      fi
      ;;
    *) pf_ok "CLAUDE_CODE_EFFORT_LEVEL unset" ;;
  esac

  # (f) maxEffortLevel in every settings file in scope.
  case "${TANDEM_CLAUDE_MANAGED_SETTINGS+set}" in
    set) managed="$TANDEM_CLAUDE_MANAGED_SETTINGS" ;;
    *)
      case "$(uname -s 2>/dev/null)" in
        Darwin) managed="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
        *) managed="/etc/claude-code/managed-settings.json" ;;
      esac
      ;;
  esac
  project="$PROJECT_DIR"
  settings=0
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    "$project/.claude/settings.json" "$project/.claude/settings.local.json" "$managed"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if [ "$have_jq" -eq 0 ]; then
      pf_bad "cannot read maxEffortLevel in $f without jq"
      settings=1
      continue
    fi
    if ! val="$(jq -r 'if type == "object" and has("maxEffortLevel") then (.maxEffortLevel | tostring) else "" end' "$f" 2>/dev/null)"; then
      pf_bad "cannot parse $f as JSON — maxEffortLevel cannot be verified"
      settings=1
      continue
    fi
    if [ -n "$val" ] && [ "$val" != "max" ]; then
      pf_bad "maxEffortLevel='$val' in $f caps every seat and the leader below max — remove it or set it to max"
      settings=1
    fi
  done
  [ "$settings" -eq 0 ] && pf_ok "no maxEffortLevel below max in the settings in scope"

  # (h) TANDEM_TURN_EFFORT, whatever its value: codex-resume.sh applies it AFTER
  # resolve_role, so a global export would silently degrade every substantive
  # resume — and an invalid one would make the first one exit 64.
  case "${TANDEM_TURN_EFFORT+set}" in
    set)
      pf_bad "TANDEM_TURN_EFFORT='$TANDEM_TURN_EFFORT' must be unset — council.sh astra decides the effort of every turn (max, or low for a reminder)"
      ;;
    *) pf_ok "TANDEM_TURN_EFFORT unset" ;;
  esac

  # (i) a sha256 tool: the seals, the frozen brief and the receipts depend on it.
  if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
    pf_ok "sha256 tool available ($(command -v shasum >/dev/null 2>&1 && printf 'shasum' || printf 'sha256sum'))"
  else
    pf_bad "neither shasum nor sha256sum is available — seals, the frozen brief and the turn receipts need one"
  fi

  # (j) the summary.
  printf '\nsummary:\n'
  pf_info "leader expected: ${TANDEM_COUNCIL_LEADER_MODEL:-$COUNCIL_LEADER_DEFAULT} at effort max (self-declared by the session; confirmed at the brief gate)"
  pf_info "Astra: model=$CODEX_MODEL effort=$CODEX_EFFORT sandbox=$CODEX_SANDBOX (role council)"
  pf_info "Fable: model=${fpin:-?} effort=${FABLE_EFFORT:-?} (agents/council-fable.md)"
  pf_info "rounds=$( [ "$rounds_ok" -eq 1 ] && printf '%s' "$rounds" || printf '?') · intake=$intake"
  if [ "${TANDEM_WEB_SEARCH:-}" = "off" ]; then
    pf_info "web mode: web search is closed for Astra in every run (TANDEM_WEB_SEARCH=off); init --offline also removes Fable's web tools"
  else
    pf_info "web mode: web by default (Astra web_search + Fable WebSearch/WebFetch); init --offline = confidential mode"
  fi
  if [ "$rounds_ok" -eq 1 ]; then
    pf_info "turn bound: typical 2 × (2 + R) = $((2 * (2 + rounds))) max-effort seat turns · ceiling 5 × (2 + R) = $((5 * (2 + rounds))) max-effort turns + $((2 + rounds)) Astra reminders at low (R = $rounds)"
  else
    pf_info "turn bound: unknown until TANDEM_COUNCIL_ROUNDS is valid — typical 2 × (2 + R), ceiling 5 × (2 + R) + (2 + R) reminders at low"
  fi

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
  letter="$(seat_letter astra)"
  [ -n "$letter" ] || die "run.json assigns no letter to astra" 65
  target="$(q -r '.astra_targets[-1] // empty')"
  [ -n "$target" ] || die "run.json lists no Astra target" 65
  key="$(target_key "$target")"
  mode="$(q -r '.mode')"

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
  # the child so `exec -a` still names the wrapper's own process — so it runs at
  # the role's effort whatever the caller exported; a reminder runs at low with
  # the foreground watchdog.
  set -m
  (
    export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
    if [ "$reminder" -eq 1 ]; then
      export TANDEM_TURN_EFFORT=low
      export TANDEM_EXEC_TIMEOUT_SECONDS=540
    else
      unset TANDEM_TURN_EFFORT
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
         modelo: "no verificado", modelos: [], respuesta: $p, sha256: $s, uso: null, registrado: $t}]'
    state_save
    printf '%s\n' "$reply"
    return 0
  fi

  [ -n "$agent" ] || die "no Fable agent recorded for this run — council.sh record-agent first" 1
  [ -r "$out" ] || die "the agent's output file cannot be read: $out" 1
  fable_pin || die "Fable's pin cannot be trusted: $FABLE_PIN_ERR" 65
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
    | jq -c --arg pin "$FABLE_PIN" --arg doc "$DOC_DIR" --arg run "$RUN_DIR" --arg runrel "$RUN_REL" \
      --arg docrel "$DOC_REL" --arg own1 "$own1" --arg own2 "$own2" "$CAPTURE_JQ")" \
    || { rm -f "$slice"; die "the transcript slice could not be analysed" 1; }
  rm -f "$slice"
  line_to="$total"
  nbad="$(printf '%s' "$analysis" | jq -r '.bad_models | length')"
  if [ "$nbad" -gt 0 ]; then
    die "a line of the transcript slice was answered by $(printf '%s' "$analysis" | jq -c '.bad_models | unique') instead of the seat's pin $FABLE_PIN — nothing captured (FAILED terminal: a forced model, a wrong agent type or a silent model switch)" 65
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
    --arg u "$usage" --argjson an "$(printf '%s' "$analysis" | jq -c '{models, reads, mensajes, sin_usage_definitivo}')" --arg t "$(now_utc)" \
    '.captures += [{fase: $f, intento: $k, tipo: $tipo, agent_id: $a, output_file: $o,
       desde: $from, hasta: $to, captura: "capturado", modelo: "verificado",
       modelos: ($an.models | unique), respuesta: $p, sha256: $s, uso: $u,
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
  local srcs L cmds i
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

write_metadata() {
  # write_metadata <last-complete-round> <consensus-json-or-empty>
  local n="$1" cj="$2" tmp key target gen=0 f astra_sum fable_sum nu=0 nf=0 usage_list fable_list
  tmp="$(mktemp "$DOC_DIR/.metadatos.XXXXXX")" || die "cannot create a temp file in $DOC_DIR" 65
  usage_list="$(mktemp "$RUN_DIR/.usage-list.XXXXXX")" || die "cannot create a temp file" 65
  fable_list="$(mktemp "$RUN_DIR/.fable-list.XXXXXX")" || die "cannot create a temp file" 65
  # Astra: every usage file of every generation, each one ONCE — failed and
  # interrupted turns included: the quota was spent all the same.
  for target in $(q -r '.astra_targets[]'); do
    gen=$((gen + 1))
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
  # Per-turn evidence of Astra: the meta.json each wrapper wrote BEFORE its turn.
  local metas
  metas="$(q -c '.astra_turns' | jq -c '.[]' | while IFS= read -r e; do
      t="$(printf '%s' "$e" | jq -r '.target')"
      nn="$(printf '%s' "$e" | jq -r '.turno // empty')"
      m='null'
      if [ -n "$nn" ] && [ -f "$STATE_DIR/$(target_key "$t").t$nn.meta.json" ]; then
        m="$(jq -c '.' "$STATE_DIR/$(target_key "$t").t$nn.meta.json" 2>/dev/null || printf 'null')"
      fi
      printf '%s' "$e" | jq -c --argjson m "$m" '. + {meta: $m}'
    done | jq -sc '.')"
  [ -n "$metas" ] || metas='[]'
  q -r --argjson metas "$metas" --argjson asum "$astra_sum" --argjson fsum "$fable_sum" \
    --argjson nu "$nu" --argjson nf "$nf" --argjson cj "${cj:-null}" --argjson n "$n" '
    def seatname: if . == "lider" then "líder" elif . == "astra" then "Astra (Codex)" else "Fable (Claude)" end;
    def kv: to_entries | map("\(.key)=\(.value)") | join(" ");
    . as $r
    | "# Metadatos del consejo \($r.run_id)",
      "",
      "- Creado: \($r.created) · modo: \($r.mode) · tope de rondas: \($r.max_rounds) · rondas completas: \($n)",
      "- Estado: \(if $cj == null then "sin ninguna ronda completa" elif $cj.consensus then "CONSENSO en la ronda \($cj.round)" else "SIN_CONSENSO tras la ronda \($cj.round)" end)",
      "",
      "## Letras (reveladas al final)",
      "",
      "| Letra | Asiento | Modelo / effort | Evidencia |",
      "| --- | --- | --- | --- |",
      ( $r.letters | to_entries[] | .key as $l | .value as $s
        | if $s == "lider" then
            "| \($l) | líder | \($r.leader_model // "?") / max | autodeclarado por la sesión y confirmado por el usuario en el gate del brief (no medido) |"
          elif $s == "astra" then
            ([ $metas[] | select(.meta != null) | "\(.meta.model)/\(.meta.effort)" ] | unique) as $me
            | "| \($l) | Astra (Codex) | \(if ($me | length) > 0 then ($me | join(", ")) else "sin turnos con meta.json" end) | meta.json de cada turno (\([ $metas[] | select(.meta != null) | "\(.target) t\(.turno)" ] | join(", "))) |"
          else
            ([ $r.captures[] | .modelos[]? ] | unique) as $fm
            | "| \($l) | Fable (Claude) | \(if ($fm | length) > 0 then ($fm | join(", ")) else "no verificado" end) / frontmatter | modelos de cada captura del transcript\(if any($r.captures[]; .captura == "transcrito") then "; hay capturas transcritas a mano (modelo no verificado)" else "" end) |"
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
      ( [ ( $r.prompts[] | select(.recordatorio) | "- recordatorio: \(.fase) letra \(.letra) (a\(.intento))" ),
          ( $r.captures[] | select(.captura == "transcrito") | "- transcripción a mano (--manual): \(.fase) a\(.intento) \(.tipo) — modelo no verificado" ),
          ( $r.prompts[] | select(.historia) | "- reconstrucción: \(.fase) letra \(.letra) (a\(.intento), con historial)" ),
          ( if ($r.astra_targets | length) > 1 then "- generaciones del hilo de Astra: \($r.astra_targets | join(", "))" else empty end ),
          ( if ($r.agents | length) > 1 then "- agentes de Fable registrados: \($r.agents | length) (reconstrucciones)" else empty end ),
          ( $r.astra_turns[] | select(.estado != "done") | "- turno de Astra \(.fase) a\(.intento) \(.tipo): \(.estado)\(if .nota then " — " + .nota else "" end)" ),
          ( ($r.anomalies // [])[] | "- lectura fuera de alcance (\(.asiento), \(.fase) a\(.intento)): \(.rutas // [.comando] | join(" · "))" )
        ] | if length == 0 then "- ninguna" else .[] end ),
      "",
      "## Tokens",
      "",
      "- Astra: \(if ($asum | length) == 0 then "sin ficheros de uso" else ($asum | kv) end) (\($nu) ficheros t<N>.usage.json de \($r.astra_targets | length) generación(es), cada uno una vez, también los de turnos fallidos o interrumpidos)",
      ( ([ $r.captures[] | select(.captura == "capturado") | (.sin_usage_definitivo // 0) ] | add // 0) as $fpart
        | ([ $r.captures[] | select(.captura == "capturado") | (.mensajes // 0) ] | add // 0) as $fmsgs
        | "- Fable: \(if ($fsum | length) == 0 then "sin ficheros de uso" else ($fsum | kv) end) (\($nf) capturas, deduplicadas por message.id)\(if $fpart > 0 then " — COTA INFERIOR: \($fpart) de \($fmsgs) mensajes del transcript sin usage definitivo (su última línea no trae stop_reason)" else "" end)" ),
      "- líder: no medido"
    ' >"$tmp" || { rm -f "$tmp" "$usage_list" "$fable_list"; die "could not compose metadatos.md" 65; }
  rm -f "$usage_list" "$fable_list"
  write_atomic "$DOC_DIR/metadatos.md" "$tmp"
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
    phase="informe (escrito)"
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
  seal) cmd_seal "$@" ;;
  record-agent) cmd_record_agent "$@" ;;
  astra) cmd_astra "$@" ;;
  unblock) cmd_unblock "$@" ;;
  stage) cmd_stage "$@" ;;
  capture) cmd_capture "$@" ;;
  publish) cmd_publish "$@" ;;
  ledger) cmd_ledger "$@" ;;
  status) cmd_status "$@" ;;
  *)
    printf 'tandem: unknown council subcommand: %s\n' "$SUBCMD" >&2
    council_usage
    ;;
esac
