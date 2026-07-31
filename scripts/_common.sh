#!/usr/bin/env bash
# tandem — shared helpers for the codex-* scripts. Source this file, do not run it.
# Portable: bash 3.2+ (stock macOS), BSD userland. Hard dependencies: codex, jq.

set -euo pipefail

# bash >= 5.2 enables patsub_replacement by default, which expands '&' inside
# ${var//pat/rep} replacements; disable it so substitutions stay literal.
shopt -u patsub_replacement 2>/dev/null || true

die() {
  # die <message> [exit-code]
  printf 'tandem: %s\n' "$1" >&2
  exit "${2:-1}"
}

need_codex() {
  command -v codex >/dev/null 2>&1 \
    || die "codex CLI not found in PATH. Install: npm install -g @openai/codex@latest" 3
  codex --version >/dev/null 2>&1 \
    || die "codex CLI is present but cannot run (missing native binary?). Repair: npm install -g @openai/codex@latest" 3
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq not found. Install: brew install jq" 3
}

# resolve_role <review|implement|ask|image>
# Sets ROLE, CODEX_MODEL, CODEX_EFFORT, CODEX_SANDBOX.
# The sandbox is pinned per role and is deliberately NOT overridable by env:
# reviewers must never write; implementers never leave the workspace;
# danger-full-access is never used.
resolve_role() {
  ROLE="$1"
  case "$ROLE" in
    implement)
      CODEX_MODEL="${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-sol}"
      if [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
        CODEX_EFFORT="${TANDEM_IMPLEMENT_EFFORT:-xhigh}"
      else
        CODEX_EFFORT="${TANDEM_IMPLEMENT_EFFORT:-high}"
      fi
      CODEX_SANDBOX="workspace-write"
      ;;
    review | ask)
      CODEX_MODEL="${TANDEM_REVIEW_MODEL:-gpt-5.6-sol}"
      CODEX_EFFORT="${TANDEM_REVIEW_EFFORT:-xhigh}"
      CODEX_SANDBOX="read-only"
      ;;
    image)
      # Sol at high on purpose (not a scout tier): the pixels come from
      # gpt-image-2 either way, but the text model writes the actual image
      # prompt and drives the chroma workflow — brief comprehension is what
      # buys one-shot renders. workspace-write so assets land in the repo.
      CODEX_MODEL="${TANDEM_IMAGE_MODEL:-gpt-5.6-sol}"
      CODEX_EFFORT="${TANDEM_IMAGE_EFFORT:-high}"
      CODEX_SANDBOX="workspace-write"
      ;;
    *)
      die "unknown role '$ROLE' (expected: review, implement, ask or image)" 64
      ;;
  esac
}

# codex_cwd_validate — TANDEM_CODEX_CWD is the optional working-root pin: when
# DEFINED it must name an existing directory, forwarded to codex as a single
# `--cd <DIR>` token. No normalization of our own (no `pwd -P`): the contract is
# "an existing directory, passed through literally", and the skills always pass
# absolute paths — canonicalizing here would invent a semantic contract codex
# itself does not have (it resolves --cd preserving symlinks).
#
# Called BEFORE need_codex on purpose: a bad argument must fail as a usage
# error, never as a missing toolchain.
codex_cwd_validate() {
  case "${TANDEM_CODEX_CWD+set}" in
    set) : ;;
    *) return 0 ;;
  esac
  [ -n "$TANDEM_CODEX_CWD" ] \
    || die "TANDEM_CODEX_CWD is set but empty — unset it, or name an existing directory" 64
  [ -d "$TANDEM_CODEX_CWD" ] \
    || die "TANDEM_CODEX_CWD is not an existing directory: $TANDEM_CODEX_CWD" 64
}

# codex_pins lives in _pins.sh, NOT here: scripts/codex-doctor.sh needs the very
# same policy block for its --smoke turns and cannot source this file (the
# `set -euo pipefail` above would abort a diagnosis that must report every
# problem it finds). One definition, sourced by both sides, is what keeps the
# smoke turn structurally identical to a real one — a second inline list would
# drift in silence. _pins.sh has no shell side effects by contract, so sourcing
# it here changes nothing for the wrappers.
_TANDEM_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_pins.sh
. "$_TANDEM_SCRIPT_DIR/_pins.sh"

# state_init — sets STATE_ROOT/STATE_DIR under the *project* (never inside the
# installed plugin, which is read-only and moves on updates) and keeps the
# whole .tandem/ tree out of git.
state_init() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  STATE_ROOT="$PROJECT_DIR/.tandem"
  STATE_DIR="$STATE_ROOT/state/$ROLE"
  mkdir -p "$STATE_DIR" "$STATE_ROOT/log" "$STATE_ROOT/tmp"
  [ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore"
  # Heartbeat root: a turn launched inside a linked git worktree must stay
  # visible to a status line watching the MAIN checkout, so the heartbeat goes
  # under the main repo's .tandem (resolved via the common git dir; in a
  # normal checkout this is the same directory). Falls back to STATE_ROOT
  # outside git. Thread state stays in STATE_DIR, scoped to where it ran.
  HB_ROOT="$STATE_ROOT"
  local common main
  if command -v git >/dev/null 2>&1 \
    && common="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$common" ]; then
    case "$common" in /*) : ;; *) common="$PWD/$common" ;; esac
    if main="$(CDPATH='' cd -- "$(dirname -- "$common")" 2>/dev/null && pwd)" \
      && [ -n "$main" ]; then
      HB_ROOT="$main/.tandem"
    fi
  fi
}

# --- token accounting ------------------------------------------------------
# Every `turn.completed` event carries the turn's `usage`. The ChatGPT quota is
# the real operating constraint of a tandem run, so that number is persisted
# next to the turn's other artefacts instead of scrolling past in the live
# panel. The scripts only ever record the raw datum: who sums it per round, per
# phase or per run is the orchestrator's business (the skills), because a
# wrapper knows nothing about rounds or runs.

# turn_usage <events-file> — prints ONE compact JSON object: the field-by-field
# SUM of the `.usage` of EVERY `turn.completed` in the stream. Prints nothing
# (and returns 0) when the file is absent, empty, malformed, or carries no such
# event.
#
# Why a sum and not "the last one wins": 36/36 real streams archived under
# .tandem/state/review/ (codex-cli 0.144.4) carry EXACTLY ONE `turn.completed`,
# so for every stream ever observed here the sum IS the object verbatim. Should
# the CLI ever emit one event per internal attempt, summing counts what the
# retries cost — discarding them would under-report precisely the expensive
# turns this ledger exists to expose, and that is the one unrecoverable error.
#
# Field names are codex's, verbatim (`input_tokens`, `cached_input_tokens`,
# `output_tokens`, `reasoning_output_tokens` observed), so a future NUMERIC
# field rides along for free; a non-numeric value is dropped rather than allowed
# to break the sum. Malformed lines are skipped exactly like stream_milestones
# (fromjson?), and a jq failure degrades to "no usage", never to an error.
turn_usage() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  jq -Rrs '
    [ split("\n")[] | fromjson? | objects
      | select(.type == "turn.completed") | .usage | objects ]
    | if length == 0 then empty
      else
        reduce .[] as $u ({};
          reduce ($u | to_entries[]) as $e (.;
            if ($e.value | type) == "number"
            then .[$e.key] = ((.[$e.key] // 0) + $e.value)
            else . end))
        | tojson
      end' "$f" 2>/dev/null || true
  return 0
}

# usage_number <usage-json> <key> — the value of <key> when it really is a
# number, nothing otherwise: the heartbeat must never carry a string where the
# status line expects an integer.
usage_number() {
  printf '%s' "${1:-}" | jq -r --arg k "${2:-}" \
    'if (.[$k] | type) == "number" then .[$k] else empty end' 2>/dev/null || true
  return 0
}

# usage_persist <dest> <json> — atomic best-effort write (temp file in the same
# directory + mv). Returns non-zero when the file did not land, so a caller can
# decide whether to advertise the path, but it NEVER aborts the turn: under
# `set -euo pipefail` a failed redirection would take down a turn that already
# burned real quota, and half a JSON object on disk is worse than none. Same
# contract as the heartbeat — accounting is a ledger, never a gate.
#
# A destination that exists and is not a plain file is left alone (`mv` would
# move the temp file INSIDE a directory and call it a success): it is not ours
# to replace, and reporting failure keeps the footer honest.
usage_persist() {
  local dest="${1:-}" json="${2:-}" dir tmp
  [ -n "$dest" ] || return 1
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then return 1; fi
  dir="$(dirname -- "$dest")"
  [ -d "$dir" ] || return 1
  tmp="$(mktemp "$dir/.usage.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$json" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dest" 2>/dev/null && [ -f "$dest" ]; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# usage_next_index <prefix> — the next free N for `<prefix>.t<N>.usage.json`.
# Swarm seats have no turn counter (a retry overwrites the seat's files by
# contract), but the quota a previous attempt burned is already spent, so its
# usage accumulates as a ledger instead of being overwritten. Retries of one
# seat are sequential, so scanning for the first free slot is enough.
usage_next_index() {
  local prefix="${1:-}" n=1
  while [ -e "$prefix.t$n.usage.json" ]; do
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- heartbeat -------------------------------------------------------------
# A single JSON file the status line reads to show what Codex is doing right
# now. It is a *display* artefact: every write is best-effort and must never
# abort a Codex turn, so failures here are swallowed on purpose. The durable
# record remains the per-turn files under state/<role>/.
#
# Written atomically (temp file in the same directory + mv) so a status line
# refresh can never observe a half-written object.

# hb_write <status> [verdict] — status: running | done | failed
#
# tokens_in/tokens_out come from $HB_TOKENS_IN/$HB_TOKENS_OUT, which the
# wrappers fill from the turn's usage the moment the pipeline ends. They are
# ALWAYS null while 'running': the usage only exists once the turn closes, and
# showing the previous turn's tokens during a new one would simply be a lie.
hb_write() {
  local status="$1" verdict="${2:-}" tmp root
  root="${HB_ROOT:-${STATE_ROOT:-}}"
  [ -n "$root" ] || return 0
  mkdir -p "$root/state" 2>/dev/null || return 0
  [ -f "$root/.gitignore" ] || printf '*\n' >"$root/.gitignore" 2>/dev/null || true
  tmp="$(mktemp "$root/state/.current.XXXXXX" 2>/dev/null)" || return 0
  if jq -n \
    --arg role "${ROLE:-}" \
    --arg model "${CODEX_MODEL:-}" \
    --arg effort "${CODEX_EFFORT:-}" \
    --arg sandbox "${CODEX_SANDBOX:-}" \
    --arg target "${TARGET:-}" \
    --arg status "$status" \
    --arg verdict "$verdict" \
    --arg events "${EVENTS_FILE:-}" \
    --arg tokens_in "${HB_TOKENS_IN:-}" \
    --arg tokens_out "${HB_TOKENS_OUT:-}" \
    --argjson turn "${TURN:-0}" \
    --argjson pid "$$" \
    --argjson started_at "${HB_STARTED_AT:-0}" \
    --argjson updated_at "$(date +%s)" \
    '{role:$role, model:$model, effort:$effort, sandbox:$sandbox,
      target:$target, turn:$turn, pid:$pid, started_at:$started_at,
      updated_at:$updated_at, status:$status,
      verdict:(if $verdict == "" then null else $verdict end),
      events:(if $events == "" then null else $events end),
      tokens_in:(if $status == "running" then null
                 else (($tokens_in | tonumber?) // null) end),
      tokens_out:(if $status == "running" then null
                  else (($tokens_out | tonumber?) // null) end)}' \
    >"$tmp" 2>/dev/null
  then
    mv -f "$tmp" "$root/state/current.json" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# stream_milestones — compact live progress from codex's NDJSON on stdin, one
# line per meaningful event, so a background shell's output panel narrates the
# turn while it runs. Malformed lines are skipped (fromjson?); if jq itself
# ever died, the trailing cat keeps draining so codex (behind tee) never
# receives SIGPIPE mid-turn.
stream_milestones() {
  jq --unbuffered -Rr '
    fromjson? |
    if .type == "thread.started" then "» thread \(.thread_id // "?")"
    elif .type == "item.started" and (.item.item_type // "") == "command_execution" then
      "» exec \((.item.command // "?") | gsub("\\s+"; " ") | .[0:110])"
    elif .type == "item.completed" and (.item.item_type // "") == "command_execution" then
      (if (.item.exit_code // 0) == 0 then "  ✓ ok"
       else "  ✗ exit \(.item.exit_code)" end)
    elif .type == "item.completed" and (.item.item_type // "") == "file_change" then
      "» edit \((.item.changes // []) | map(.path // "?")
        | if length <= 3 then join(", ")
          else (.[0:3] | join(", ")) + " +\(length - 3) more" end)"
    elif .type == "item.started" and (.item.item_type // "") == "web_search" then
      "» web search"
    elif .type == "turn.completed" then
      "» turn done — tokens in \(.usage.input_tokens // "?") · out \(.usage.output_tokens // "?")"
    elif .type == "turn.failed" then "✗ turn failed: \(.error.message // "unknown error")"
    elif .type == "error" then "✗ \(.message // "stream error")"
    else empty end
  ' 2>/dev/null || cat >/dev/null
}

# hb_begin — mark a turn as running and arm the EXIT guard, so a crash, a
# `die` or a Ctrl-C leaves 'failed' behind instead of a heartbeat stuck on
# 'running' forever.
hb_begin() {
  HB_STARTED_AT="$(date +%s)"
  HB_ACTIVE=1
  hb_write running
  trap 'hb_guard' EXIT
}

# hb_end <status> [verdict] — final write; disarms the guard.
hb_end() {
  HB_ACTIVE=0
  hb_write "$1" "${2:-}"
}

hb_guard() {
  local rc=$?
  [ "${HB_ACTIVE:-0}" = "1" ] && hb_write failed
  exit "$rc"
}

# hb_verdict <reply-file> — extracts the sentinel a role's prompt asks Codex to
# emit, so the status line can colour the outcome. Prints nothing if absent.
hb_verdict() {
  [ -f "$1" ] || return 0
  LC_ALL=C grep -Eo \
    '(VERDICT:[[:space:]]*(APPROVED|REVISE|NEEDS_REWORK|REQUEST_CHANGES))|IMPLEMENTATION_(COMPLETE|PARTIAL)|IMAGE_(READY|BLOCKED)' \
    "$1" 2>/dev/null | tail -n 1 | LC_ALL=C sed -e 's|^VERDICT:[[:space:]]*||' || true
}

# target_key <target> — filesystem-safe state key derived from the label as
# given (no path resolution: always refer to the same work by the same label).
# A checksum of the raw label is appended so distinct labels that sanitize to
# the same text ('a/b' vs 'a b') cannot collide on one thread. Prints nothing
# for labels with no usable characters (callers must reject empty keys).
target_key() {
  local sanitized
  sanitized="$(printf '%s' "$1" | LC_ALL=C tr '\r\n' '__' \
    | LC_ALL=C sed -e 's|[^A-Za-z0-9._-]|_|g' -e 's|^\.\{1,\}||')"
  [ -n "$sanitized" ] || return 0
  printf '%s.%s' "$sanitized" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

# load_prompt <template-file> — expands {{TARGET}}, {{EXTRA}} and {{NOTES}}
# from $TARGET/$EXTRA/$NOTES in a single left-to-right pass: replaced values
# are never re-scanned, so a diff or note that itself contains '{{NOTES}}'
# (e.g. when tandem edits its own templates) cannot be expanded again. Values
# are inserted literally (no awk/sed pitfalls with '&' or backslashes).
load_prompt() {
  local file="$1" rest out best bestpre p pre v
  [ -f "$file" ] || die "prompt template not found: $file" 64
  rest="$(cat "$file")"
  out=""
  while :; do
    best="" bestpre=""
    for p in '{{TARGET}}' '{{EXTRA}}' '{{NOTES}}'; do
      case "$rest" in
        *"$p"*)
          pre="${rest%%"$p"*}"
          if [ -z "$best" ] || [ "${#pre}" -lt "${#bestpre}" ]; then
            best="$p" bestpre="$pre"
          fi
          ;;
      esac
    done
    [ -z "$best" ] && break
    case "$best" in
      '{{TARGET}}') v="${TARGET:-}" ;;
      '{{EXTRA}}') v="${EXTRA:-}" ;;
      '{{NOTES}}') v="${NOTES:-}" ;;
    esac
    out="$out$bestpre$v"
    rest="${rest#*"$best"}"
  done
  printf '%s\n' "$out$rest"
}

# read_optional_file <path-or-empty> — prints file content, or nothing.
read_optional_file() {
  local f="${1:-}"
  [ -z "$f" ] && return 0
  [ -f "$f" ] || die "context file not found: $f" 64
  cat "$f"
}
