#!/usr/bin/env bash
# The plan commit must land on tandem/<slug>, and the pieces of that contract
# that live in executable documentation cannot be reached by the behavioural
# suite: a skill that silently went back to `git commit` on the user's branch,
# or to an unanchored baseline, would keep plan-approve.test.sh perfectly green
# while every autonomous run wrote to main again.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PLAN_SKILL="$REPO_ROOT/skills/plan/SKILL.md"
IMPL_SKILL="$REPO_ROOT/skills/implement/SKILL.md"
RUN_SKILL="$REPO_ROOT/skills/run/SKILL.md"

assert_file "$PLAN_SKILL"
assert_file "$IMPL_SKILL"
assert_file "$RUN_SKILL"

# --- the transition is delegated to the script, not danced in Markdown -------
assert_file "$SCRIPTS/plan-approve.sh"
run bash "$SCRIPTS/plan-approve.sh"
assert_rc 64 "plan-approve.sh usage"

assert_file_contains "$PLAN_SKILL" "plan-approve.sh"
assert_file_contains "$PLAN_SKILL" "tandem/<slug>"
# Both gates — human and autonomous — go through the same transition.
assert_matches "$PLAN_SKILL" 'TANDEM_AUTONOMOUS=1.*plan-approve\.sh|plan-approve\.sh.*transition and continue'
# Per-mode effects the user has to be told about.
assert_file_contains "$PLAN_SKILL" "TANDEM_WORKTREE=1"
assert_file_contains "$PLAN_SKILL" ".worktrees/<slug>"

# --- the old branch-less commit is gone, not merely supplemented -------------
assert_not_contains "$PLAN_SKILL" "keeps the tree clean for tandem:implement's clean-tree gate"
assert_not_contains "$PLAN_SKILL" 'git add docs/plans/<slug>.plan.md && git commit'

# --- implement: baseline and plan_hash anchored to the working root ----------
assert_file_contains "$IMPL_SKILL" 'git -C "$WORK_ROOT" rev-parse HEAD:docs/plans/<slug>.plan.md'
assert_file_contains "$IMPL_SKILL" 'git -C "$WORK_ROOT" rev-parse HEAD'
assert_file_contains "$IMPL_SKILL" 'git -C "$WORK_ROOT" remote -v'
# An unanchored capture is exactly the bug this asserts against: the tandem
# branch is one commit ahead of the user's branch by construction, so a
# main-checkout baseline turns every clean worktree run into a "safety failure".
assert_not_contains "$IMPL_SKILL" 'record the absolute plan path, `git rev-parse HEAD`'

# --- the re-attach can never flip the approval's recorded mode ---------------
# With zero worktree registrations git cannot derive the real mode, so the
# durable approval state is the only witness; a skill that dropped this check
# would let TANDEM_WORKTREE alone convert an in-place approval into a worktree
# one (or the inverse) exactly when the registry is empty.
assert_file_contains "$IMPL_SKILL" 'state/plan-approve/<slug>.json'
assert_file_contains "$IMPL_SKILL" 'its `mode` field is authoritative'

# --- the red line the whole change exists to honour --------------------------
assert_file_contains "$RUN_SKILL" "never touch the default branch"
assert_file_contains "$RUN_SKILL" "tandem/<slug>"

# --- never vacuously green ---------------------------------------------------
# Each anchor above is asserted against a file that really does carry the rest
# of the contract; a skill emptied of its plan gate is a different bug, not a
# pass.
for f in "$PLAN_SKILL" "$IMPL_SKILL" "$RUN_SKILL"; do
  lines="$(wc -l <"$f" | tr -d ' ')"
  [ "$lines" -ge 40 ] || fail "$f looks truncated ($lines lines) — the anchors above prove nothing"
done
note "plan/implement/run SKILL.md — branch contract anchored"
