#!/usr/bin/env bash
# tandem — show the state of a Codex thread without calling Codex.
# usage: codex-show.sh <role> <target>
# exit codes: 0 ok · 2 no thread · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -ge 2 ] || die "usage: codex-show.sh <role> <target>" 64
resolve_role "$1"
TARGET="$2"
state_init

KEY="$(target_key "$TARGET")"
[ -n "$KEY" ] || die "target produced an empty state key: '$TARGET'" 64
THREAD_FILE="$STATE_DIR/$KEY.thread"
TURN_FILE="$STATE_DIR/$KEY.turn"
MSG_FILE="$STATE_DIR/$KEY.last.txt"

if [ ! -f "$THREAD_FILE" ]; then
  printf 'tandem: no thread exists for "%s" (role %s).\n' "$TARGET" "$ROLE" >&2
  exit 2
fi

printf 'target:    %s\nrole:      %s\nthread_id: %s\nturns:     %s\n' \
  "$TARGET" "$ROLE" "$(cat "$THREAD_FILE")" "$(cat "$TURN_FILE" 2>/dev/null || printf '?')"
if [ -s "$MSG_FILE" ]; then
  printf -- '\n--- last reply ---\n'
  cat "$MSG_FILE"
  printf -- '\n--- end ---\n'
else
  printf '\n(no last reply captured)\n'
fi
