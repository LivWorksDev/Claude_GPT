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

# resolve_role <review|implement|ask>
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
    *)
      die "unknown role '$ROLE' (expected: review, implement or ask)" 64
      ;;
  esac
}

# state_init — sets STATE_ROOT/STATE_DIR under the *project* (never inside the
# installed plugin, which is read-only and moves on updates) and keeps the
# whole .tandem/ tree out of git.
state_init() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  STATE_ROOT="$PROJECT_DIR/.tandem"
  STATE_DIR="$STATE_ROOT/state/$ROLE"
  mkdir -p "$STATE_DIR" "$STATE_ROOT/log" "$STATE_ROOT/tmp"
  [ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore"
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
hb_write() {
  [ -n "${STATE_ROOT:-}" ] || return 0
  local status="$1" verdict="${2:-}" tmp
  tmp="$(mktemp "$STATE_ROOT/state/.current.XXXXXX" 2>/dev/null)" || return 0
  if jq -n \
    --arg role "${ROLE:-}" \
    --arg model "${CODEX_MODEL:-}" \
    --arg effort "${CODEX_EFFORT:-}" \
    --arg sandbox "${CODEX_SANDBOX:-}" \
    --arg target "${TARGET:-}" \
    --arg status "$status" \
    --arg verdict "$verdict" \
    --argjson turn "${TURN:-0}" \
    --argjson pid "$$" \
    --argjson started_at "${HB_STARTED_AT:-0}" \
    --argjson updated_at "$(date +%s)" \
    '{role:$role, model:$model, effort:$effort, sandbox:$sandbox,
      target:$target, turn:$turn, pid:$pid, started_at:$started_at,
      updated_at:$updated_at, status:$status,
      verdict:(if $verdict == "" then null else $verdict end)}' \
    >"$tmp" 2>/dev/null
  then
    mv -f "$tmp" "$STATE_ROOT/state/current.json" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
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
    '(VERDICT:[[:space:]]*(APPROVED|REVISE|NEEDS_REWORK|REQUEST_CHANGES))|IMPLEMENTATION_(COMPLETE|PARTIAL)' \
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
