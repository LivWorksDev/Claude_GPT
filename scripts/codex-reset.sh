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

# The trailing dot keeps 'auth.' from matching 'auth-v2.*'.
rm -f "$STATE_DIR/$KEY."*
printf 'tandem: state reset for "%s" (role %s).\n' "$TARGET" "$ROLE"
