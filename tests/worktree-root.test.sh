#!/usr/bin/env bash
# scripts/worktree-root.sh — the fail-closed resolution of the working root.
# This is the failure mode the argv tests cannot see: they are handed a correct
# TANDEM_CODEX_CWD, so they would stay green while the skills anchored a turn to
# the wrong tree.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WR="$SCRIPTS/worktree-root.sh"
MAIN="$CLAUDE_PROJECT_DIR"
# NOT .worktrees/<slug>: the registry is the source of truth, not a convention.
WT="$SANDBOX/elsewhere/custom root"

make_repo "$MAIN"
printf 'seed\n' >"$MAIN/f.txt"
commit_all "$MAIN"

# --- without TANDEM_WORKTREE: always the main checkout ------------------------
run_in "$MAIN" bash "$WR" demo
assert_rc 0 "no TANDEM_WORKTREE"
assert_eq "$MAIN" "$(cat "$OUT")" "main checkout"

# Usage errors stay usage errors.
run_in "$MAIN" bash "$WR"
assert_rc 64 "no slug"
run_in "$MAIN" bash "$WR" ""
assert_rc 64 "empty slug"

# Outside git it fails instead of guessing a root.
mkdir -p "$SANDBOX/nogit"
run_in "$SANDBOX/nogit" bash "$WR" demo
assert_rc 65 "outside a git repository"
assert_file_contains "$ERR" "not inside a git repository"

export TANDEM_WORKTREE=1

# --- the branch does not exist yet -------------------------------------------
run_in "$MAIN" bash "$WR" demo
assert_rc 65 "branch missing"
assert_file_contains "$ERR" "the branch tandem/demo does not exist"

# --- the branch exists but no worktree is registered for it ------------------
git -C "$MAIN" branch tandem/demo >/dev/null 2>&1 || fail "git branch failed"
run_in "$MAIN" bash "$WR" demo
assert_rc 65 "branch without a worktree"
assert_file_contains "$ERR" "no worktree is registered"

# --- registered in a NON-default path: that exact path, absolute -------------
git -C "$MAIN" worktree add -q "$WT" tandem/demo >/dev/null 2>&1 \
  || fail "git worktree add failed"
run_in "$MAIN" bash "$WR" demo
assert_rc 0 "registered worktree"
assert_eq "$WT" "$(cat "$OUT")" "non-default worktree path"

# The answer does not depend on where it is asked from.
run_in "$WT" bash "$WR" demo
assert_rc 0 "resolved from inside the worktree"
assert_eq "$WT" "$(cat "$OUT")" "same path from inside the worktree"

# --- ambiguity: never a silent pick ------------------------------------------
git -C "$MAIN" worktree add -q --force "$SANDBOX/dup" tandem/demo >/dev/null 2>&1 \
  || fail "git worktree add --force failed"
run_in "$MAIN" bash "$WR" demo
assert_rc 65 "two worktrees for one branch"
assert_file_contains "$ERR" "ambiguous working root"
assert_file_contains "$ERR" "$WT"

# --- registered but gone from disk: not a reason to fall back ----------------
git -C "$MAIN" worktree remove --force "$SANDBOX/dup" >/dev/null 2>&1 \
  || fail "git worktree remove failed"
rm -rf "$WT"
run_in "$MAIN" bash "$WR" demo
assert_rc 65 "worktree missing from disk"
assert_file_contains "$ERR" "missing from disk"

# …and in no failure did it ever print the main checkout on stdout.
assert_not_contains "$OUT" "$MAIN"
