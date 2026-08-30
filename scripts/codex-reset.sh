#!/usr/bin/env bash
# tandem — discard all state for a target's Codex thread (thread id, turn
# counter, prompts, events, last reply). The remote Codex session itself is
# not deleted; it simply stops being referenced.
# usage: codex-reset.sh <role> <target>
# exit codes: 0 ok (also when there was nothing to reset) · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -ge 2 ] || die "usage: codex-reset.sh <role> <target>" 64
resolve_role "$1"
TARGET="$2"
state_init

KEY="$(target_key "$TARGET")"
[ -n "$KEY" ] || die "target produced an empty state key: '$TARGET'" 64

AUDIT_SLUG=""
if [ "$ROLE" = "implement" ]; then
  case "$TARGET" in
    docs/plans/*.plan.md)
      AUDIT_SLUG="${TARGET#docs/plans/}"
      case "$AUDIT_SLUG" in
        '' | */*) AUDIT_SLUG="" ;;
        *) AUDIT_SLUG="${AUDIT_SLUG%.plan.md}" ;;
      esac
      ;;
  esac
fi

# Reset order is a safety contract: census first, resumable attempt state next,
# and the guard last. If reset is interrupted, dependency installs remain
# blocked; it must never leave resumable state behind after disarming the hook.
if [ -n "$AUDIT_SLUG" ]; then
  rm -f "$STATE_ROOT/state/implement-audit/$AUDIT_SLUG.census"
fi

# The trailing dot keeps 'auth.' from matching 'auth-v2.*'. This remains keyed
# by target_key; audit artifacts deliberately use the plan slug instead.
rm -f "$STATE_DIR/$KEY."*

# Drop the status-line heartbeat too, but only if it describes the target being
# reset — another role's turn may legitimately still be showing.
HB="${HB_ROOT:-$STATE_ROOT}/state/current.json"
if [ -f "$HB" ] \
  && [ "$(jq -r '.role // ""' "$HB" 2>/dev/null)" = "$ROLE" ] \
  && [ "$(jq -r '.target // ""' "$HB" 2>/dev/null)" = "$TARGET" ]; then
  rm -f "$HB"
fi

if [ -n "$AUDIT_SLUG" ]; then
  rm -f "$STATE_ROOT/state/implement-audit/$AUDIT_SLUG.guard"
elif [ "$ROLE" = "implement" ]; then
  printf 'tandem: implement audit state unchanged; target is not docs/plans/<slug>.plan.md.\n'
fi

printf 'tandem: state reset for "%s" (role %s).\n' "$TARGET" "$ROLE"
