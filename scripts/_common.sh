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
      if [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
        CODEX_MODEL="${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-sol}"
      else
        CODEX_MODEL="${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-luna}"
      fi
      CODEX_EFFORT="${TANDEM_IMPLEMENT_EFFORT:-high}"
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
