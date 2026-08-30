#!/usr/bin/env bash
# tandem — Claude Code PreToolUse guard for dependency-mutating Bash commands.
#
# Keep the mutator grammar in sync with scripts/implement-audit.sh's broader
# dependency deny-list. Pattern matching deliberately happens before touching
# the filesystem so ordinary Bash calls take the cheapest path.

set -uo pipefail
set -f

PAYLOAD="$(cat)"
COMMAND=""
if command -v jq >/dev/null 2>&1; then
  COMMAND="$(printf '%s' "$PAYLOAD" | jq -r '
    if (.tool_input.command? | type) == "string" then .tool_input.command else empty end
  ' 2>/dev/null)" || COMMAND=""
else
  COMMAND="$PAYLOAD"
  # Raw JSON fallback: turn structural punctuation into token separators. This
  # remains deliberately conservative (a matching phrase in another string may
  # block) but still recognizes the command words without a JSON parser.
  COMMAND="${COMMAND//\"/ }"
  COMMAND="${COMMAND//\{/ }"
  COMMAND="${COMMAND//\}/ }"
  COMMAND="${COMMAND//\[/ }"
  COMMAND="${COMMAND//\]/ }"
  COMMAND="${COMMAND//:/ }"
  COMMAND="${COMMAND//,/ }"
fi

mutator_in_tail() {
  local token
  for token in "$@"; do
    token="${token#\(}"
    token="${token%\)}"
    case "$token" in
      install | i | ci | add | remove | rm | uninstall | un | update | up | upgrade)
        return 0
        ;;
    esac
  done
  return 1
}

yarn_is_bare() {
  local token skip_value=0
  [ $# -eq 0 ] && return 0
  for token in "$@"; do
    if [ "$skip_value" -eq 1 ]; then
      skip_value=0
      continue
    fi
    case "$token" in
      --cwd | --cache-folder | --modules-folder | --mutex | --network-timeout | --registry | --use-yarnrc | -C)
        skip_value=1
        ;;
      --* | -*) : ;;
      *) return 1 ;;
    esac
  done
  return 0
}

segment_mutates() {
  local token manager
  # Intentional shell-token approximation: globbing is disabled above, and
  # word splitting is the conservative segment grammar this hook specifies.
  # shellcheck disable=SC2086
  set -- $1
  while [ $# -gt 0 ]; do
    token="$1"
    shift
    token="${token#\(}"
    token="${token%\)}"
    case "$token" in
      npm | pnpm | yarn)
        manager="$token"
        if mutator_in_tail "$@"; then
          return 0
        fi
        if [ "$manager" = "yarn" ] && yarn_is_bare "$@"; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

command_mutates() {
  local segments segment
  segments="${COMMAND//&&/$'\n'}"
  segments="${segments//||/$'\n'}"
  segments="${segments//;/$'\n'}"
  segments="${segments//|/$'\n'}"
  while IFS= read -r segment || [ -n "$segment" ]; do
    segment_mutates "$segment" && return 0
  done <<<"$segments"
  return 1
}

command_mutates || exit 0

# Tokenization above disables pathname expansion; re-enable it only now that a
# mutator matched and the guard directory actually has to be inspected.
set +f
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
AUDIT_DIR="$PROJECT_DIR/.tandem/state/implement-audit"
for GUARD in "$AUDIT_DIR"/*.guard; do
  [ -e "$GUARD" ] || continue
  SLUG="${GUARD##*/}"
  SLUG="${SLUG%.guard}"
  printf 'tandem: dependency mutation blocked for active implement attempt "%s".\n' "$SLUG" >&2
  printf 'M25 guard: npm/pnpm/yarn mutators can rewrite lockfiles that the closing write audit will reject.\n' >&2
  printf 'Wait for Step 5 to close the attempt, or, if it is truly dead, use the exact reset protocol (bash scripts/codex-reset.sh implement docs/plans/%s.plan.md).\n' "$SLUG" >&2
  exit 2
done

exit 0
