#!/usr/bin/env bash
# tandem — resolve the working root for a slug, fail-closed.
#
# usage: worktree-root.sh <slug>
#   Without TANDEM_WORKTREE=1 → the MAIN checkout (the common case; nothing
#   about the flow changes).
#   With TANDEM_WORKTREE=1 → the absolute path of the worktree REGISTERED for
#   `refs/heads/tandem/<slug>`, wherever it lives: the implement skill may reuse
#   a worktree already registered outside `.worktrees/<slug>`, so the registry
#   is the source of truth, never a path convention.
#
# Zero or several matches, or a registered path missing from disk, are hard
# errors: falling back to the main checkout would silently run a turn — or a
# commit — against the wrong tree, which is the exact failure this exists to
# prevent.
#
# The path printed on stdout is what callers pass as TANDEM_CODEX_CWD (and as
# `git -C`); diagnostics go to stderr, so `$(worktree-root.sh <slug>)` is safe.
#
# exit codes: 0 ok · 3 missing dependency · 64 usage error
#             65 the repository state yields no unambiguous working root

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -eq 1 ] || die "usage: worktree-root.sh <slug>" 64
SLUG="$1"
[ -n "$SLUG" ] || die "worktree-root.sh: empty slug" 64

command -v git >/dev/null 2>&1 || die "git not found in PATH" 3

# The MAIN checkout, not the current one: `--show-toplevel` would answer with
# the worktree we happen to stand in. Same derivation state_init uses for the
# heartbeat root, so state and working root can never disagree about which tree
# is "the main one".
COMMON="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$COMMON" ] || die "not inside a git repository: $PWD" 65
case "$COMMON" in /*) : ;; *) COMMON="$PWD/$COMMON" ;; esac
MAIN="$(CDPATH='' cd -- "$(dirname -- "$COMMON")" 2>/dev/null && pwd)" \
  || die "cannot resolve the main checkout from $COMMON" 65

if [ "${TANDEM_WORKTREE:-}" != "1" ]; then
  printf '%s\n' "$MAIN"
  exit 0
fi

BRANCH="tandem/$SLUG"
git show-ref --verify --quiet "refs/heads/$BRANCH" \
  || die "TANDEM_WORKTREE=1 but the branch $BRANCH does not exist — create the worktree first" 65

# `git worktree list --porcelain` emits one record per worktree, records
# separated by a blank line: `worktree <path>`, `HEAD <sha>`, then `branch
# <ref>` or `detached`. Paths may contain spaces, so records are read line by
# line and never word-split.
MATCHES=""
COUNT=0
CUR=""
while IFS= read -r line; do
  case "$line" in
    'worktree '*) CUR="${line#worktree }" ;;
    "branch refs/heads/$BRANCH")
      COUNT=$((COUNT + 1))
      MATCHES="$MATCHES$CUR
"
      ;;
  esac
done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF

if [ "$COUNT" -eq 0 ]; then
  die "TANDEM_WORKTREE=1 but no worktree is registered for $BRANCH (run: git worktree add .worktrees/$SLUG $BRANCH)" 65
fi
if [ "$COUNT" -gt 1 ]; then
  printf 'tandem: %s is checked out in %s worktrees:\n%s' "$BRANCH" "$COUNT" "$MATCHES" >&2
  die "ambiguous working root for $BRANCH — remove the duplicates, no silent pick" 65
fi

ROOT="${MATCHES%$'\n'}"
[ -d "$ROOT" ] \
  || die "the worktree registered for $BRANCH is missing from disk: $ROOT (run: git worktree prune, then re-add it)" 65

printf '%s\n' "$ROOT"
