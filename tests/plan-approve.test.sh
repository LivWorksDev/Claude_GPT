#!/usr/bin/env bash
# scripts/plan-approve.sh — the plan commit lands on tandem/<slug>, never on the
# user's branch. Every failure mode this script exists for (slug collisions,
# resumes, tracked plans, mode mismatch, a commit that does not land) is GIT
# behaviour: a static assertion on the skills would stay green while every one
# of them was broken. So each case runs against a real, throwaway repository.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PA="$SCRIPTS/plan-approve.sh"
PLAN_REL="docs/plans/demo.plan.md"

# new_repo <name> — a repository with one commit and an UNTRACKED plan, which
# is the state the plan skill hands over at its approval gate.
new_repo() {
  local d="$SANDBOX/$1"
  make_repo "$d"
  printf 'seed\n' >"$d/f.txt"
  commit_all "$d" seed
  mkdir -p "$d/docs/plans"
  printf '# Plan: %s\n' "$1" >"$d/$PLAN_REL"
  printf '%s' "$d"
}

# approve <repo> <in-place|worktree> [args…] — invoked the way a skill does:
# from the main checkout, with the project state anchored there.
approve() {
  local repo="$1" mode="$2"
  shift 2
  if [ "$mode" = "worktree" ]; then
    run_in "$repo" env CLAUDE_PROJECT_DIR="$repo" TANDEM_WORKTREE=1 bash "$PA" "$@"
  else
    run_in "$repo" env CLAUDE_PROJECT_DIR="$repo" bash "$PA" "$@"
  fi
}

g() { git -C "$@"; }
tip() { git -C "$1" rev-parse "refs/heads/tandem/demo"; }
st_file() { printf '%s' "$1/.tandem/state/plan-approve/demo.json"; }
count_commits() { git -C "$1" rev-list --count "$2"; }

# --- usage contract ----------------------------------------------------------
run bash "$PA"
assert_rc 64 "no slug"
run bash "$PA" ""
assert_rc 64 "empty slug"
run bash "$PA" "../escape"
assert_rc 64 "slug with path characters"

# =============================================================================
# 1. Fresh in-place approval
# =============================================================================
A="$(new_repo inplace)"
A_USER="$(g "$A" rev-parse --abbrev-ref HEAD)"
A_SRC="$(g "$A" rev-parse HEAD)"

approve "$A" in-place demo "Plan: demo — first"
assert_rc 0 "fresh in-place approval"
assert_matches "$OUT" '^status: +created$'
assert_matches "$OUT" '^branch: +tandem/demo$'

assert_eq "tandem/demo" "$(g "$A" rev-parse --abbrev-ref HEAD)" "session left on the tandem branch"
A_TIP="$(tip "$A")"
assert_eq "$A_SRC" "$(g "$A" rev-parse "$A_USER")" "the user's branch never moved"
assert_eq "1" "$(count_commits "$A" "$A_USER")" "no new commit on the user's branch"
assert_eq "$A_SRC" "$(g "$A" rev-parse "$A_TIP^")" "the plan commit sits on top of the user's HEAD"
assert_eq "$PLAN_REL" \
  "$(g "$A" diff-tree --no-commit-id --name-only -r "$A_TIP")" "plan-only commit"
assert_eq "" "$(g "$A" status --porcelain)" "clean tree after the approval"
g "$A" ls-files --error-unmatch -- "$PLAN_REL" >/dev/null 2>&1 \
  || fail "the plan is not tracked on the tandem branch"

# The durable record is the resume anchor: exact plan_commit and source_head
# (source_head, never base_head — that name belongs to implement's attempt).
A_STATE="$(st_file "$A")"
assert_file "$A_STATE"
assert_json "$A_STATE" ".branch == \"tandem/demo\" and .mode == \"in-place\""
assert_json "$A_STATE" ".plan_commit == \"$A_TIP\" and .source_head == \"$A_SRC\""
assert_no_file "$A_STATE.pending"

# =============================================================================
# 2. Second invocation, immediately: idempotent no-op
# =============================================================================
approve "$A" in-place demo
assert_rc 0 "second in-place invocation"
assert_matches "$OUT" '^status: +resumed$'
assert_eq "$A_TIP" "$(tip "$A")" "no new commit on the second invocation"
assert_eq "2" "$(count_commits "$A" tandem/demo)" "branch still has exactly base + plan"

# =============================================================================
# 3. Fresh worktree approval
# =============================================================================
B="$(new_repo wt)"
B_USER="$(g "$B" rev-parse --abbrev-ref HEAD)"
B_SRC="$(g "$B" rev-parse HEAD)"

approve "$B" worktree demo
assert_rc 0 "fresh worktree approval"
assert_matches "$OUT" '^status: +created$'
assert_matches "$OUT" "^work_root: +$B/.worktrees/demo\$"

assert_eq "$B_USER" "$(g "$B" rev-parse --abbrev-ref HEAD)" "main checkout stays on the user's branch"
assert_eq "" "$(g "$B" status --porcelain)" "main checkout is clean"
assert_eq "$B_SRC" "$(g "$B" rev-parse "$B_USER")" "the user's branch never moved"
assert_no_file "$B/$PLAN_REL"
assert_file "$B/.worktrees/demo/$PLAN_REL"
git -C "$B/.worktrees/demo" ls-files --error-unmatch -- "$PLAN_REL" >/dev/null 2>&1 \
  || fail "the plan is not tracked inside the worktree"
assert_file_contains "$B/.git/info/exclude" ".worktrees/"

B_TIP="$(tip "$B")"
B_STATE="$(st_file "$B")"
assert_json "$B_STATE" ".mode == \"worktree\" and .plan_commit == \"$B_TIP\""
assert_json "$B_STATE" ".source_head == \"$B_SRC\""

# =============================================================================
# 4. Second worktree invocation: idempotent, and the primary duplicate stays away
# =============================================================================
approve "$B" worktree demo
assert_rc 0 "second worktree invocation"
assert_matches "$OUT" '^status: +resumed$'
assert_eq "$B_TIP" "$(tip "$B")" "no new commit on the second worktree invocation"
assert_no_file "$B/$PLAN_REL"
assert_eq "" "$(g "$B" status --porcelain)" "main checkout still clean"

# =============================================================================
# 5. Resume with a concordant state: the working copy is reconciled
# =============================================================================
# in-place, back on the user's branch, with an identical untracked duplicate.
g "$A" checkout -q "$A_USER"
mkdir -p "$A/docs/plans"
g "$A" show "tandem/demo:$PLAN_REL" >"$A/$PLAN_REL"
approve "$A" in-place demo
assert_rc 0 "in-place resume from the user's branch"
assert_matches "$OUT" '^status: +resumed$'
assert_eq "tandem/demo" "$(g "$A" rev-parse --abbrev-ref HEAD)" "resume checks the branch out"
assert_eq "$A_TIP" "$(tip "$A")" "resume never commits again"

# worktree: an identical duplicate in the MAIN checkout is reconciled away.
mkdir -p "$B/docs/plans"
git -C "$B/.worktrees/demo" show "HEAD:$PLAN_REL" >"$B/$PLAN_REL"
approve "$B" worktree demo
assert_rc 0 "worktree resume with a duplicate in the main checkout"
assert_no_file "$B/$PLAN_REL"
assert_eq "$B_TIP" "$(tip "$B")" "worktree resume never commits again"

# =============================================================================
# 6. Collision: a DIFFERENT plan under the same slug — nothing is touched
# =============================================================================
g "$A" checkout -q "$A_USER"
mkdir -p "$A/docs/plans"
printf '# Plan: a completely different feature\n' >"$A/$PLAN_REL"
approve "$A" in-place demo
assert_rc 65 "collision with a different plan"
assert_file_contains "$ERR" "differs from the plan committed"
assert_eq "$A_TIP" "$(tip "$A")" "the branch was not touched"
assert_eq "$A_USER" "$(g "$A" rev-parse --abbrev-ref HEAD)" "still on the user's branch"
assert_file_contains "$A/$PLAN_REL" "a completely different feature"
rm -f "$A/$PLAN_REL"

# =============================================================================
# 7. The tip is no longer the recorded plan commit
# =============================================================================
C="$(new_repo moved)"
approve "$C" in-place demo
assert_rc 0 "approval before the branch moves on"
printf 'work\n' >"$C/impl.txt"
g "$C" add -A >/dev/null 2>&1
g "$C" commit -q -m "implementation"
approve "$C" in-place demo
assert_rc 65 "tip past the recorded plan commit"
assert_file_contains "$ERR" "past its plan commit"

# =============================================================================
# 8. Implementation commit BEFORE a plan-only tip: shape fools nothing
# =============================================================================
D="$(new_repo shaped)"
approve "$D" in-place demo
assert_rc 0 "approval before the shaped history"
printf 'work\n' >"$D/impl.txt"
g "$D" add -A >/dev/null 2>&1
g "$D" commit -q -m "implementation"
printf '# Plan: shaped (edited)\n' >"$D/$PLAN_REL"
g "$D" commit -q -m "plan tweak" -- "$PLAN_REL"
assert_eq "$PLAN_REL" \
  "$(g "$D" diff-tree --no-commit-id --name-only -r HEAD)" "the tip really is plan-only"
approve "$D" in-place demo
assert_rc 65 "plan-only tip with implementation history behind it"
assert_file_contains "$ERR" "past its plan commit"

# =============================================================================
# 9. A pre-existing branch with no durable state at all
# =============================================================================
E="$(new_repo nostate)"
g "$E" branch tandem/demo
approve "$E" in-place demo
assert_rc 65 "pre-existing branch without durable state"
assert_file_contains "$ERR" "no durable approval state"
assert_file_contains "$ERR" "tandem:implement"
assert_file "$E/$PLAN_REL"

# =============================================================================
# 10. A plan already TRACKED on the user's branch: reused slug
# =============================================================================
F="$(new_repo tracked)"
commit_all "$F" "merged plan"
approve "$F" in-place demo
assert_rc 65 "plan tracked on the user's branch"
assert_file_contains "$ERR" "already tracked on"
assert_file_contains "$ERR" "demo-v2"
run_in "$F" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "no branch was created"

# =============================================================================
# 11. Mode mismatch, in both directions — derived from git, never from the env
# =============================================================================
g "$A" checkout -q tandem/demo
approve "$A" worktree demo
assert_rc 65 "in-place branch under TANDEM_WORKTREE=1"
assert_file_contains "$ERR" "already checked out in the main checkout"
assert_file_contains "$ERR" "mode mismatch"

approve "$B" in-place demo
assert_rc 65 "worktree branch without TANDEM_WORKTREE"
assert_file_contains "$ERR" "checked out in the linked worktree"
assert_file_contains "$ERR" "mode mismatch"

# =============================================================================
# 12. A commit that does not land: complete rollback, in BOTH modes
# =============================================================================
reject_commits() {
  mkdir -p "$1/.git/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$1/.git/hooks/pre-commit"
  chmod +x "$1/.git/hooks/pre-commit"
}

G="$(new_repo hook-inplace)"
G_USER="$(g "$G" rev-parse --abbrev-ref HEAD)"
reject_commits "$G"
approve "$G" in-place demo
assert_rc 65 "in-place commit rejected by a hook"
assert_file_contains "$ERR" "rolled back completely"
assert_eq "$G_USER" "$(g "$G" rev-parse --abbrev-ref HEAD)" "back on the user's branch"
run_in "$G" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "no branch survived the failed commit"
assert_file "$G/$PLAN_REL"
assert_file_contains "$G/$PLAN_REL" "# Plan: hook-inplace"
assert_no_file "$(st_file "$G")"
assert_eq "" "$(g "$G" diff --cached --name-only)" "nothing left staged"

rm -f "$G/.git/hooks/pre-commit"
approve "$G" in-place demo
assert_rc 0 "retry after fixing the cause"
assert_eq "2" "$(count_commits "$G" tandem/demo)" "the retry starts from scratch"

H="$(new_repo hook-worktree)"
H_USER="$(g "$H" rev-parse --abbrev-ref HEAD)"
reject_commits "$H"
approve "$H" worktree demo
assert_rc 65 "worktree commit rejected by a hook"
assert_file_contains "$ERR" "rolled back completely"
assert_eq "$H_USER" "$(g "$H" rev-parse --abbrev-ref HEAD)" "main checkout untouched"
run_in "$H" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "no branch survived the failed worktree commit"
assert_no_file "$H/.worktrees/demo"
assert_file "$H/$PLAN_REL"
assert_file_contains "$H/$PLAN_REL" "# Plan: hook-worktree"
assert_no_file "$(st_file "$H")"

rm -f "$H/.git/hooks/pre-commit"
approve "$H" worktree demo
assert_rc 0 "worktree retry after fixing the cause"
assert_file "$H/.worktrees/demo/$PLAN_REL"
assert_eq "2" "$(count_commits "$H" tandem/demo)" "the worktree retry starts from scratch"

# =============================================================================
# 13. The final state write fails: the landed commit is rolled back too
# =============================================================================
# post-commit runs AFTER the commit landed and its exit code is ignored by git,
# so it is the exact injection point for "the commit is in, the record is not".
I="$(new_repo statefail)"
I_USER="$(g "$I" rev-parse --abbrev-ref HEAD)"
mkdir -p "$I/.git/hooks"
printf '#!/bin/sh\nchmod 555 "%s"\n' "$I/.tandem/state/plan-approve" >"$I/.git/hooks/post-commit"
chmod +x "$I/.git/hooks/post-commit"

approve "$I" in-place demo
STATE_RC="$RC"
chmod 755 "$I/.tandem/state/plan-approve" 2>/dev/null || true
rm -f "$I/.git/hooks/post-commit"
assert_eq "65" "$STATE_RC" "state write failure is a fail-closed stop"
assert_file_contains "$ERR" "left as evidence"
assert_eq "$I_USER" "$(g "$I" rev-parse --abbrev-ref HEAD)" "back on the user's branch"
run_in "$I" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "the landed commit was rolled back with its branch"
assert_file "$I/$PLAN_REL"
assert_no_file "$(st_file "$I")"
assert_file "$(st_file "$I").pending"

approve "$I" in-place demo
assert_rc 0 "retry once the state directory is writable again"
assert_file "$(st_file "$I")"
assert_no_file "$(st_file "$I").pending"

# =============================================================================
# 14. A pending record whose commit matches is recovered, not stranded
# =============================================================================
J="$(new_repo pending)"
approve "$J" in-place demo
assert_rc 0 "approval before the state is lost"
J_TIP="$(tip "$J")"
J_SRC="$(g "$J" rev-parse "$J_TIP^")"
J_BLOB="$(g "$J" rev-parse "$J_TIP:$PLAN_REL")"
rm -f "$(st_file "$J")"
printf '{\n  "branch": "tandem/demo",\n  "mode": "in-place",\n  "source_head": "%s",\n  "plan_blob": "%s"\n}\n' \
  "$J_SRC" "$J_BLOB" >"$(st_file "$J").pending"

approve "$J" in-place demo
assert_rc 0 "pending with a matching commit is recovered"
assert_matches "$OUT" '^status: +recovered$'
assert_json "$(st_file "$J")" ".plan_commit == \"$J_TIP\" and .source_head == \"$J_SRC\""
assert_json "$(st_file "$J")" ".mode == \"in-place\""
assert_no_file "$(st_file "$J").pending"
assert_eq "$J_TIP" "$(tip "$J")" "recovery never commits"

# A pending that does NOT describe the branch is not a licence to guess.
K="$(new_repo pending-bogus)"
approve "$K" in-place demo
assert_rc 0 "approval before the bogus pending"
K_TIP="$(tip "$K")"
rm -f "$(st_file "$K")"
printf '{\n  "branch": "tandem/demo",\n  "mode": "in-place",\n  "source_head": "%s",\n  "plan_blob": "%s"\n}\n' \
  "0000000000000000000000000000000000000000" "0000000000000000000000000000000000000000" \
  >"$(st_file "$K").pending"
approve "$K" in-place demo
assert_rc 65 "pending that does not describe the branch"
assert_file_contains "$ERR" "do not describe each other"
assert_eq "$K_TIP" "$(tip "$K")" "nothing was touched"

# =============================================================================
# 15. A pre-existing .worktrees/<slug> path is never this script's to destroy
# =============================================================================
# The branch does not exist, so whatever sits at that path is foreign data: the
# approval must refuse BEFORE any mutation, and above all must not let a
# rollback rm -rf its way through it.
L="$(new_repo foreign-wt)"
mkdir -p "$L/.worktrees/demo"
printf 'user data\n' >"$L/.worktrees/demo/sentinel.txt"
approve "$L" worktree demo
assert_rc 65 "pre-existing unregistered worktree path"
assert_file_contains "$ERR" "nothing was touched"
assert_file "$L/.worktrees/demo/sentinel.txt"
assert_file_contains "$L/.worktrees/demo/sentinel.txt" "user data"
run_in "$L" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "no branch was created over the foreign path"
assert_file "$L/$PLAN_REL"
assert_no_file "$(st_file "$L")"

# =============================================================================
# 16. Worktree resume checks the REAL working file, not the committed blob
# =============================================================================
M="$(new_repo wt-drift)"
approve "$M" worktree demo
assert_rc 0 "approval before the worktree drifts"
M_TIP="$(tip "$M")"

printf 'tampered\n' >>"$M/.worktrees/demo/$PLAN_REL"
approve "$M" worktree demo
assert_rc 65 "modified plan inside the worktree"
assert_file_contains "$ERR" "modified or staged"
git -C "$M/.worktrees/demo" checkout -q -- "$PLAN_REL"

printf 'tampered\n' >>"$M/.worktrees/demo/$PLAN_REL"
git -C "$M/.worktrees/demo" add -- "$PLAN_REL"
approve "$M" worktree demo
assert_rc 65 "staged plan inside the worktree"
assert_file_contains "$ERR" "modified or staged"
git -C "$M/.worktrees/demo" reset -q -- "$PLAN_REL"
git -C "$M/.worktrees/demo" checkout -q -- "$PLAN_REL"

rm -f "$M/.worktrees/demo/$PLAN_REL"
approve "$M" worktree demo
assert_rc 65 "deleted plan inside the worktree"
assert_file_contains "$ERR" "missing from the worktree"
git -C "$M/.worktrees/demo" checkout -q -- "$PLAN_REL"

approve "$M" worktree demo
assert_rc 0 "resume works again once the worktree is clean"
assert_eq "$M_TIP" "$(tip "$M")" "no drift case ever committed"
