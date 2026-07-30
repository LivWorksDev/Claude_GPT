#!/usr/bin/env bash
# tandem — approve a plan: create `tandem/<slug>` and land the plan commit
# INSIDE it, so the user's branch (typically main) never receives a commit
# during a tandem run — not even an abandoned one.
#
# usage: plan-approve.sh <slug> [commit-message]
#   slug            the kebab-case name carried through every tandem skill;
#                   the plan is docs/plans/<slug>.plan.md and the branch is
#                   tandem/<slug>.
#   commit-message  optional; defaults to "Plan: <slug>".
#
# env: TANDEM_WORKTREE=1  the approval creates a LINKED WORKTREE
#      (.worktrees/<slug>) and moves the plan into it, leaving the main
#      checkout clean and on the user's branch. Unset (default, "in-place"):
#      `git checkout -b` in the main checkout, which leaves the session on the
#      tandem branch.
#
# The transition is fail-closed and idempotent:
#   - a plan already TRACKED on the user's branch is a reused slug → STOP;
#   - a pre-existing `tandem/<slug>` is only resumed when the durable approval
#     state agrees with git (tip == plan_commit, first parent == source_head,
#     plan-only diff, matching blob); anything else is a STOP, never a guess;
#   - the mode is derived from `git worktree list`, never from the environment
#     alone: a mismatch between the two is a STOP in both directions;
#   - the state record is published transactionally (pending → mutate → atomic
#     finalize). A commit that does not land — or a finalization that does not
#     land — is rolled back completely, and the plan's working copy is ALWAYS
#     preserved: it is the one irreplaceable artefact here.
#
# Durable state: <project>/.tandem/state/plan-approve/<slug>.json —
#   {"branch", "plan_commit", "source_head", "mode"}. `source_head` is the
#   user's HEAD at approval time (the plan commit's first parent); it is
#   deliberately NOT called `base_head`, which belongs to tandem:implement's
#   attempt state and designates the TIP of the tandem branch.
#
# No jq dependency: the record is written with printf and read back with sed —
# every field is a sha, a branch name or one of two literal modes, and every
# value read is re-verified against git before it is trusted.
#
# exit codes: 0 ok (fresh approval, idempotent resume or pending recovery)
#             3 missing dependency · 64 usage error
#             65 fail-closed stop (the repository state is not one this script
#                may resolve on its own)

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  die "usage: plan-approve.sh <slug> [commit-message]" 64
fi
SLUG="$1"
COMMIT_MSG="${2:-Plan: $SLUG}"
[ -n "$SLUG" ] || die "plan-approve.sh: empty slug" 64
# The slug becomes a branch name, a path component and a JSON value. Anything
# outside this charset is rejected instead of escaped.
case "$SLUG" in
  *[!A-Za-z0-9._-]*) die "invalid slug '$SLUG' — use [A-Za-z0-9._-] only" 64 ;;
  [-.]*) die "invalid slug '$SLUG' — must not start with '-' or '.'" 64 ;;
esac
[ -n "$COMMIT_MSG" ] || die "plan-approve.sh: empty commit message" 64

command -v git >/dev/null 2>&1 || die "git not found in PATH" 3

# --- orientation: where we are, where we are going --------------------------
# The MAIN checkout, not the current one, is the anchor for every git command:
# the script may be invoked from a subdirectory, and under TANDEM_WORKTREE=1 it
# mutates the main checkout and a linked worktree in the same run. Same
# derivation worktree-root.sh and state_init use.
COMMON="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$COMMON" ] || die "not inside a git repository: $PWD" 65
case "$COMMON" in /*) : ;; *) COMMON="$PWD/$COMMON" ;; esac
MAIN="$(CDPATH='' cd -- "$(dirname -- "$COMMON")" 2>/dev/null && pwd)" \
  || die "cannot resolve the main checkout from $COMMON" 65

PLAN_REL="docs/plans/$SLUG.plan.md"
MAIN_PLAN="$MAIN/$PLAN_REL"
BRANCH="tandem/$SLUG"
WT_DEFAULT="$MAIN/.worktrees/$SLUG"

# State lives under the project (never inside the plugin, never inside the
# worktree): a worktree can be removed without destroying the approval record.
STATE_ROOT="${CLAUDE_PROJECT_DIR:-$MAIN}/.tandem"
STATE_DIR="$STATE_ROOT/state/plan-approve"
STATE_FILE="$STATE_DIR/$SLUG.json"
PENDING_FILE="$STATE_FILE.pending"

if [ "${TANDEM_WORKTREE:-}" = "1" ]; then
  ENV_MODE="worktree"
else
  ENV_MODE="in-place"
fi

# Ownership flag for rollback: only a worktree THIS run created may ever be
# removed. A pre-existing .worktrees/<slug> is someone else's data.
WT_CREATED=0

USER_BRANCH="$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || true)"
SOURCE_HEAD="$(git -C "$MAIN" rev-parse HEAD 2>/dev/null || true)"
[ -n "$SOURCE_HEAD" ] \
  || die "the repository has no commits yet — commit something before approving a plan" 65
# Detached HEAD is workable: the restore target is the sha itself.
if [ -n "$USER_BRANCH" ]; then ORIG_REF="$USER_BRANCH"; else ORIG_REF="$SOURCE_HEAD"; fi

ON_BRANCH=0
if [ "$USER_BRANCH" = "$BRANCH" ]; then ON_BRANCH=1; fi

BRANCH_EXISTS=0
if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then BRANCH_EXISTS=1; fi

# --- helpers ----------------------------------------------------------------

# scan_branch_worktrees — fills WT_COUNT / WT_PATH from the worktree REGISTRY,
# the only source of truth about where a branch is checked out. `git worktree
# list --porcelain` emits one record per worktree, separated by blank lines:
# `worktree <path>`, `HEAD <sha>`, then `branch <ref>` or `detached`. Paths may
# contain spaces, so records are read line by line and never word-split.
scan_branch_worktrees() {
  local line cur=""
  WT_COUNT=0
  WT_PATH=""
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) cur="${line#worktree }" ;;
      "branch refs/heads/$BRANCH")
        WT_COUNT=$((WT_COUNT + 1))
        [ -n "$WT_PATH" ] || WT_PATH="$cur"
        ;;
    esac
  done <<EOF
$(git -C "$MAIN" worktree list --porcelain 2>/dev/null || true)
EOF
}

canon() {
  CDPATH='' cd -- "$1" 2>/dev/null && pwd
}

# json_str <file> <key> — reads one string field of a record THIS script wrote
# (one field per line). Every value is re-verified against git afterwards, so a
# malformed record can only ever produce a mismatch, never a wrong success.
json_str() {
  [ -f "$1" ] || return 0
  LC_ALL=C sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null || true
}

state_prepare() {
  mkdir -p "$STATE_DIR" 2>/dev/null \
    || die "cannot create the approval state directory: $STATE_DIR" 65
  [ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore" 2>/dev/null || true
}

# write_state <dest> <plan_commit> <source_head> <mode>
write_state() {
  printf '{\n  "branch": "%s",\n  "plan_commit": "%s",\n  "source_head": "%s",\n  "mode": "%s"\n}\n' \
    "$BRANCH" "$2" "$3" "$4" >"$1"
}

# write_pending <mode> <source_head> <plan_blob> — the record written BEFORE any
# git mutation, so a run interrupted between the commit and the finalization can
# be recognised and completed instead of being mistaken for an unexplained
# branch.
write_pending() {
  printf '{\n  "branch": "%s",\n  "mode": "%s",\n  "source_head": "%s",\n  "plan_blob": "%s"\n}\n' \
    "$BRANCH" "$1" "$2" "$3" >"$PENDING_FILE"
}

# finalize_state <plan_commit> <source_head> <mode> — atomic publish (temp file
# in the same directory + mv). Returns non-zero if the record could not be
# published; the caller rolls git back, because a landed commit with no state is
# exactly the shape this script refuses to resume later.
finalize_state() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/.$SLUG.json.XXXXXX" 2>/dev/null)" || return 1
  if ! write_state "$tmp" "$1" "$2" "$3"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$STATE_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -f "$PENDING_FILE" 2>/dev/null || true
  return 0
}

# ensure_worktrees_excluded — `.worktrees/` must not show up as an untracked
# path in the USER's project; the exclude file is per-repository and is not a
# tracked artefact, so this never edits their .gitignore.
ensure_worktrees_excluded() {
  local exclude="$COMMON/info/exclude"
  mkdir -p "$COMMON/info" 2>/dev/null || true
  if [ -f "$exclude" ] && LC_ALL=C grep -qxF '.worktrees/' "$exclude" 2>/dev/null; then
    return 0
  fi
  printf '.worktrees/\n' >>"$exclude" 2>/dev/null || true
}

# restore_plan_from_branch — last resort of the "the working copy is ALWAYS
# preserved" rule: recover the plan text from the commit that is about to be
# deleted. Writes through a temp file so a failed `git show` cannot leave an
# empty plan behind.
restore_plan_from_branch() {
  [ ! -f "$MAIN_PLAN" ] || return 0
  mkdir -p "$(dirname "$MAIN_PLAN")" 2>/dev/null || true
  if git -C "$MAIN" show "refs/heads/$BRANCH:$PLAN_REL" >"$MAIN_PLAN.tandem-restore" 2>/dev/null; then
    mv -f "$MAIN_PLAN.tandem-restore" "$MAIN_PLAN" 2>/dev/null || true
  else
    rm -f "$MAIN_PLAN.tandem-restore" 2>/dev/null || true
  fi
}

# rollback — undo EVERY mutation of a transition that did not complete. Each
# step is guarded: a rollback must run to the end even when one of its steps is
# already unnecessary (or impossible).
rollback() {
  if [ "$ENV_MODE" = "worktree" ]; then
    # Guarded by ownership: the fresh path refuses to start when the path
    # already exists, so WT_CREATED is the proof that whatever sits at
    # $WT_DEFAULT was created by this very run and may be undone. Without it,
    # a mere `git worktree add` conflict would rm -rf a directory that was
    # never ours.
    if [ "$WT_CREATED" -eq 1 ] && [ -d "$WT_DEFAULT" ]; then
      if [ -f "$WT_DEFAULT/$PLAN_REL" ] && [ ! -f "$MAIN_PLAN" ]; then
        mkdir -p "$(dirname "$MAIN_PLAN")" 2>/dev/null || true
        mv -f "$WT_DEFAULT/$PLAN_REL" "$MAIN_PLAN" 2>/dev/null || true
      fi
      if ! git -C "$MAIN" worktree remove --force "$WT_DEFAULT" >/dev/null 2>&1; then
        rm -rf "$WT_DEFAULT" 2>/dev/null || true
      fi
      git -C "$MAIN" worktree prune >/dev/null 2>&1 || true
    fi
  else
    # Unstage first: when the commit never landed, the plan must go back to
    # being an untracked working file, exactly as it was.
    git -C "$MAIN" reset -q HEAD -- "$PLAN_REL" >/dev/null 2>&1 || true
    git -C "$MAIN" checkout -q "$ORIG_REF" >/dev/null 2>&1 || true
  fi
  restore_plan_from_branch
  git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 || true
  if [ ! -f "$MAIN_PLAN" ]; then
    printf 'tandem: WARNING — could not restore %s while rolling back; look for it in %s\n' \
      "$PLAN_REL" "$BRANCH" >&2
  fi
}

summary() {
  # summary <status> <plan_commit> <work_root>
  printf 'status:     %s\n' "$1"
  printf 'branch:     %s\n' "$BRANCH"
  printf 'plan:       %s\n' "$PLAN_REL"
  printf 'commit:     %s\n' "$2"
  printf 'mode:       %s\n' "$ENV_MODE"
  printf 'work_root:  %s\n' "$3"
  printf 'state:      %s\n' "$STATE_FILE"
}

# --- mode derived from git, never from the environment alone ----------------
scan_branch_worktrees
if [ "$WT_COUNT" -gt 1 ]; then
  die "$BRANCH is checked out in $WT_COUNT worktrees — remove the duplicates, no silent pick" 65
fi
GIT_MODE=""
if [ "$WT_COUNT" -eq 1 ]; then
  if [ "$(canon "$WT_PATH" || true)" = "$MAIN" ]; then GIT_MODE="in-place"; else GIT_MODE="worktree"; fi
fi
if [ -n "$GIT_MODE" ] && [ "$GIT_MODE" != "$ENV_MODE" ]; then
  if [ "$GIT_MODE" = "worktree" ]; then
    printf 'tandem: %s is checked out in the linked worktree %s, but TANDEM_WORKTREE is not 1.\n' \
      "$BRANCH" "$WT_PATH" >&2
    die "mode mismatch — re-run with TANDEM_WORKTREE=1, or undo that worktree by hand. Never guessing." 65
  fi
  printf 'tandem: TANDEM_WORKTREE=1, but %s is already checked out in the main checkout %s.\n' \
    "$BRANCH" "$MAIN" >&2
  die "mode mismatch — re-run without TANDEM_WORKTREE, or undo that branch by hand. Never guessing." 65
fi

# --- guard: a plan TRACKED on the user's branch is a reused slug ------------
# Skipped when the session already stands on tandem/<slug>: the plan tracked
# THERE is the expected result of a completed approval, not a reused slug.
if [ "$ON_BRANCH" -eq 0 ] \
  && git -C "$MAIN" ls-files --error-unmatch -- "$PLAN_REL" >/dev/null 2>&1; then
  printf 'tandem: %s is already tracked on %s — this slug belongs to a plan that was merged.\n' \
    "$PLAN_REL" "${USER_BRANCH:-HEAD}" >&2
  printf 'tandem: pick another slug (e.g. %s-v2), or retire the old plan by hand.\n' "$SLUG" >&2
  die "refusing to approve a reused slug (a tracked plan is never moved)" 65
fi

# --- pre-existing branch: resume ONLY on a concordant durable state ----------
if [ "$BRANCH_EXISTS" -eq 1 ]; then
  TIP="$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)"
  [ -n "$TIP" ] || die "cannot read the tip of $BRANCH" 65
  TIP_PARENT="$(git -C "$MAIN" rev-parse --verify -q "$TIP^" 2>/dev/null || true)"
  TIP_FILES="$(git -C "$MAIN" diff-tree --no-commit-id --name-only -r "$TIP" 2>/dev/null || true)"
  TIP_BLOB="$(git -C "$MAIN" rev-parse --verify -q "$TIP:$PLAN_REL" 2>/dev/null || true)"

  RESULT="resumed"
  if [ ! -f "$STATE_FILE" ] && [ -f "$PENDING_FILE" ]; then
    # A pending record with a commit that matches it is a run that died between
    # the commit and the finalization: complete it instead of stranding it.
    P_BRANCH="$(json_str "$PENDING_FILE" branch)"
    P_MODE="$(json_str "$PENDING_FILE" mode)"
    P_SOURCE="$(json_str "$PENDING_FILE" source_head)"
    P_BLOB="$(json_str "$PENDING_FILE" plan_blob)"
    if [ "$P_BRANCH" = "$BRANCH" ] && [ -n "$P_SOURCE" ] && [ "$P_SOURCE" = "$TIP_PARENT" ] \
      && [ -n "$P_BLOB" ] && [ "$P_BLOB" = "$TIP_BLOB" ] && [ "$TIP_FILES" = "$PLAN_REL" ] \
      && [ "$P_MODE" = "$ENV_MODE" ]; then
      state_prepare
      finalize_state "$TIP" "$P_SOURCE" "$P_MODE" \
        || die "the approval commit landed but its state record cannot be written under $STATE_DIR — fix the permissions and re-run" 65
      printf 'tandem: recovered the interrupted approval of %s (state finalized)\n' "$SLUG" >&2
      RESULT="recovered"
    else
      printf 'tandem: %s exists and %s is present, but they do not describe each other.\n' \
        "$BRANCH" "$PENDING_FILE" >&2
      die "refusing to resume an approval this state does not explain — resume the work with tandem:implement, or retire $BRANCH by hand" 65
    fi
  fi

  if [ ! -f "$STATE_FILE" ]; then
    printf 'tandem: %s already exists but there is no approval state at %s.\n' "$BRANCH" "$STATE_FILE" >&2
    printf 'tandem: a branch with implementation history is resumed with tandem:implement, never by re-approving the plan.\n' >&2
    die "no durable approval state for $SLUG — nothing here is guessed" 65
  fi

  ST_BRANCH="$(json_str "$STATE_FILE" branch)"
  ST_COMMIT="$(json_str "$STATE_FILE" plan_commit)"
  ST_SOURCE="$(json_str "$STATE_FILE" source_head)"
  ST_MODE="$(json_str "$STATE_FILE" mode)"
  if [ -z "$ST_BRANCH" ] || [ -z "$ST_COMMIT" ] || [ -z "$ST_SOURCE" ] || [ -z "$ST_MODE" ]; then
    die "the approval state at $STATE_FILE is unreadable or incomplete — retire it by hand after checking $BRANCH" 65
  fi
  [ "$ST_BRANCH" = "$BRANCH" ] \
    || die "the approval state at $STATE_FILE records branch $ST_BRANCH, not $BRANCH" 65
  [ "$ST_MODE" = "$ENV_MODE" ] \
    || die "mode mismatch — the approval of $SLUG was recorded as '$ST_MODE' but this invocation is '$ENV_MODE'; re-run with the matching mode, or undo the state by hand" 65
  if [ "$TIP" != "$ST_COMMIT" ]; then
    printf 'tandem: the tip of %s is %s, but the recorded plan commit is %s.\n' "$BRANCH" "$TIP" "$ST_COMMIT" >&2
    printf 'tandem: the branch moved on — continue with tandem:implement (attempt state), never by re-approving the plan.\n' >&2
    die "refusing to re-approve a branch that is past its plan commit" 65
  fi
  [ "$TIP_PARENT" = "$ST_SOURCE" ] \
    || die "the first parent of the plan commit ($TIP_PARENT) is not the recorded source_head ($ST_SOURCE)" 65
  [ "$TIP_FILES" = "$PLAN_REL" ] \
    || die "the plan commit $TIP touches more than $PLAN_REL — refusing to treat it as an approval" 65
  [ -n "$TIP_BLOB" ] || die "the plan commit $TIP does not contain $PLAN_REL" 65

  # Reference plan: the working file of the main checkout when it exists.
  # Identical + untracked = the duplicate a previous approval left behind (or a
  # re-created copy): it is reconciled away. Divergent = STOP, untouched.
  #
  # ABSENT is not a divergence: under worktree mode the reference is the plan
  # tracked in the registered worktree (verified below), and in-place it simply
  # means the session stands on the user's branch, where git removed a file that
  # only the tandem branch tracks — the committed blob is then the single copy
  # and the checkout below materialises it.
  if [ -f "$MAIN_PLAN" ]; then
    MAIN_BLOB="$(git -C "$MAIN" hash-object -- "$MAIN_PLAN" 2>/dev/null || true)"
    if [ "$MAIN_BLOB" != "$TIP_BLOB" ]; then
      printf 'tandem: %s in the main checkout differs from the plan committed on %s.\n' "$PLAN_REL" "$BRANCH" >&2
      printf 'tandem: nothing was touched. Pick another slug (e.g. %s-v2), or reconcile the two texts by hand.\n' "$SLUG" >&2
      die "refusing to approve over a divergent plan" 65
    fi
    if ! git -C "$MAIN" ls-files --error-unmatch -- "$PLAN_REL" >/dev/null 2>&1; then
      rm -f "$MAIN_PLAN" \
        || die "cannot remove the duplicate $MAIN_PLAN left by the previous approval" 65
      printf 'tandem: removed the untracked duplicate %s (identical to the committed plan)\n' "$PLAN_REL" >&2
    fi
  fi

  if [ "$ENV_MODE" = "worktree" ]; then
    if [ "$WT_COUNT" -eq 0 ]; then
      ensure_worktrees_excluded
      git -C "$MAIN" worktree add "$WT_DEFAULT" "$BRANCH" >/dev/null 2>&1 \
        || die "could not re-attach a worktree for $BRANCH at $WT_DEFAULT" 65
      WT_PATH="$WT_DEFAULT"
      printf 'tandem: re-attached the worktree for %s at %s\n' "$BRANCH" "$WT_PATH" >&2
    fi
    [ -d "$WT_PATH" ] \
      || die "the worktree registered for $BRANCH is missing from disk: $WT_PATH (run: git worktree prune, then re-run)" 65
    # The reference is the REAL working file of the worktree, never the
    # committed blob read back through HEAD: a plan modified, staged or deleted
    # inside the worktree is a divergent working copy, and a divergent working
    # copy is a STOP — the same fail-closed rule the main checkout gets.
    WT_PLAN="$WT_PATH/$PLAN_REL"
    [ -f "$WT_PLAN" ] \
      || die "the plan is missing from the worktree working tree: $WT_PLAN — restore it (git -C \"$WT_PATH\" checkout -- \"$PLAN_REL\") or retire $BRANCH by hand" 65
    [ -z "$(git -C "$WT_PATH" status --porcelain -- "$PLAN_REL" 2>/dev/null)" ] \
      || die "the plan is modified or staged inside $WT_PATH — reconcile it by hand before resuming" 65
    WT_BLOB="$(git -C "$WT_PATH" hash-object -- "$WT_PLAN" 2>/dev/null || true)"
    [ "$WT_BLOB" = "$TIP_BLOB" ] \
      || die "the plan in $WT_PATH does not match the plan committed on $BRANCH" 65
    WORK_ROOT="$WT_PATH"
  else
    if [ "$ON_BRANCH" -eq 0 ]; then
      git -C "$MAIN" checkout -q "$BRANCH" \
        || die "could not check out $BRANCH in $MAIN — resolve the working tree by hand and re-run" 65
    fi
    WORK_ROOT="$MAIN"
  fi

  rm -f "$PENDING_FILE" 2>/dev/null || true
  summary "$RESULT" "$TIP" "$WORK_ROOT"
  exit 0
fi

# --- fresh approval ---------------------------------------------------------
[ -f "$MAIN_PLAN" ] \
  || die "plan not found: $MAIN_PLAN — write the plan before approving it" 65

PLAN_BLOB="$(git -C "$MAIN" hash-object -- "$MAIN_PLAN" 2>/dev/null || true)"
[ -n "$PLAN_BLOB" ] || die "cannot hash $MAIN_PLAN" 65

# In a fresh approval the branch does not exist, so ANY pre-existing
# .worktrees/<slug> is foreign data this script must neither reuse nor destroy.
# Refusing here — before a single mutation — is what makes rollback's ownership
# guard sound.
if [ "$ENV_MODE" = "worktree" ] && [ -e "$WT_DEFAULT" ]; then
  printf 'tandem: %s already exists but %s does not — that path is not this approval'\''s to manage.\n' \
    "$WT_DEFAULT" "$BRANCH" >&2
  die "remove or rename $WT_DEFAULT by hand and re-run (nothing was touched)" 65
fi

state_prepare
write_pending "$ENV_MODE" "$SOURCE_HEAD" "$PLAN_BLOB" \
  || die "cannot write the pending approval record $PENDING_FILE" 65

if [ "$ENV_MODE" = "worktree" ]; then
  ensure_worktrees_excluded
  if ! git -C "$MAIN" worktree add "$WT_DEFAULT" -b "$BRANCH" >/dev/null 2>&1; then
    rollback
    rm -f "$PENDING_FILE" 2>/dev/null || true
    die "could not create the worktree $WT_DEFAULT for $BRANCH" 65
  fi
  WT_CREATED=1
  WORK_ROOT="$WT_DEFAULT"
  mkdir -p "$WORK_ROOT/$(dirname "$PLAN_REL")" 2>/dev/null || true
  # MOVED, never copied: a duplicate would break the clean-tree gate and create
  # a second source of truth. The tracked-plan guard above is what makes this
  # safe (a tracked file is never moved).
  if ! mv -f "$MAIN_PLAN" "$WORK_ROOT/$PLAN_REL"; then
    rollback
    rm -f "$PENDING_FILE" 2>/dev/null || true
    die "could not move $PLAN_REL into $WORK_ROOT" 65
  fi
else
  if ! git -C "$MAIN" checkout -q -b "$BRANCH"; then
    rollback
    rm -f "$PENDING_FILE" 2>/dev/null || true
    die "could not create $BRANCH in $MAIN" 65
  fi
  WORK_ROOT="$MAIN"
fi

if ! git -C "$WORK_ROOT" add -- "$PLAN_REL" \
  || ! git -C "$WORK_ROOT" commit -q -m "$COMMIT_MSG" -- "$PLAN_REL"; then
  printf 'tandem: the plan commit did not land (rejecting hook? missing git identity?).\n' >&2
  rollback
  rm -f "$PENDING_FILE" 2>/dev/null || true
  die "approval rolled back completely; $PLAN_REL is preserved in $MAIN — fix the cause and re-run" 65
fi

PLAN_COMMIT="$(git -C "$WORK_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$PLAN_COMMIT" ] || [ "$PLAN_COMMIT" = "$SOURCE_HEAD" ]; then
  printf 'tandem: no new commit is on top of %s after committing the plan.\n' "$SOURCE_HEAD" >&2
  rollback
  rm -f "$PENDING_FILE" 2>/dev/null || true
  die "the approval commit cannot be verified; $PLAN_REL is preserved in $MAIN" 65
fi

# The state record is part of the transaction, not an appendix: a landed commit
# whose state cannot be published is undone exactly like a commit that never
# landed. The pending record stays behind as evidence.
if ! finalize_state "$PLAN_COMMIT" "$SOURCE_HEAD" "$ENV_MODE"; then
  printf 'tandem: the plan commit landed but the approval state could not be written under %s.\n' "$STATE_DIR" >&2
  rollback
  die "approval rolled back completely; fix the state directory (permissions? disk?) and re-run — $PENDING_FILE is left as evidence" 65
fi

printf 'tandem: plan approved — %s committed on %s (%s mode)\n' "$PLAN_REL" "$BRANCH" "$ENV_MODE" >&2
summary "created" "$PLAN_COMMIT" "$WORK_ROOT"
