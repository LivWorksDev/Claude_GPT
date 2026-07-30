#!/usr/bin/env bash
# The scripts persist the raw usage of a turn; WHO sums it, where it is written
# and when it is written lives in the skills, and the behavioural suite cannot
# see any of that. A skill that quietly dropped its accounting step would leave
# every round line, phase total and run report tokenless with the whole suite
# green — so the contract is asserted statically here, on executable
# documentation, exactly like the worktree and preamble contracts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# Markdown wraps, so prose anchors are judged on a whitespace-flattened copy: a
# re-wrapped sentence is the same contract, an absent one is not.
flatten() {
  # flatten <skill-file> — prints the path of the flattened copy.
  local f="$1" out
  [ -f "$f" ] || fail "skill not found: $f"
  out="$SANDBOX/$(basename "$(dirname "$f")").flat"
  LC_ALL=C tr '\n' ' ' <"$f" | LC_ALL=C tr -s ' ' >"$out"
  # Never vacuously green: an emptied skill is a different bug, not a pass.
  local lines
  lines="$(wc -l <"$f" | tr -d ' ')"
  [ "$lines" -ge 40 ] || fail "$f looks truncated ($lines lines) — the anchors prove nothing"
  printf '%s' "$out"
}

PLAN="$(flatten "$REPO_ROOT/skills/plan/SKILL.md")"
REVIEW="$(flatten "$REPO_ROOT/skills/review/SKILL.md")"
IMPLEMENT="$(flatten "$REPO_ROOT/skills/implement/SKILL.md")"
RUN="$(flatten "$REPO_ROOT/skills/run/SKILL.md")"
ULTRA="$(flatten "$REPO_ROOT/skills/ultra/SKILL.md")"

# --- plan and review: unconditional, and BEFORE the verdict branch -----------
# The ordering anchor is the whole point: the log used to be written only in the
# REVISE / REQUEST_CHANGES branch, so an APPROVED-at-the-first-attempt round
# left no trace of what it cost.
for f in "$PLAN" "$REVIEW"; do
  assert_file_contains "$f" 'before reading the `VERDICT:` line'
  assert_file_contains "$f" "unconditionally"
  assert_file_contains "$f" 'USAGE:'
  assert_file_contains "$f" '.tandem/log/<slug>.md'
  assert_file_contains "$f" "tokens: in"
  assert_file_contains "$f" "tokens: n/a"
done
# …and each phase closes with its own aggregate.
assert_file_contains "$PLAN" "the phase's token total"
assert_file_contains "$REVIEW" "this phase's token total"
# One token-bearing entry per round: the REVISE/REQUEST_CHANGES branch appends
# beneath the heading the accounting step wrote, never a duplicate heading that
# would double the apparent round count.
for f in "$PLAN" "$REVIEW"; do
  assert_file_contains "$f" "BENEATH the round heading the accounting step already wrote"
  assert_file_contains "$f" 'never a second `## Round <n>` heading'
done

# --- implement: the same step under sol, an explicit n/a under opus ----------
assert_file_contains "$IMPLEMENT" 'USAGE:'
assert_file_contains "$IMPLEMENT" "unconditional"
assert_file_contains "$IMPLEMENT" "tokens: n/a (transporte opus)"
# The sol step must be per turn AND per continuation, not just at launch.
assert_file_contains "$IMPLEMENT" "each Step 2 continuation"

# --- run: aggregate per phase and total, in EVERY terminal state -------------
assert_file_contains "$RUN" "the aggregate per phase plus the total for the whole run"
assert_file_contains "$RUN" "EVERY terminal state"
assert_file_contains "$RUN" "DEADLOCK, PARTIAL and FAILED included"

# --- ultra: nullable footers on every seat, and ONE aggregation rule ---------
assert_file_contains "$ULTRA" "USAGE_FILE:"
assert_file_contains "$ULTRA" '`usage` and `usage_file` fields'
assert_file_contains "$ULTRA" "including when the script exited non-zero"
assert_file_contains "$ULTRA" "Either line may be absent"
assert_file_contains "$ULTRA" "return null for a missing one"
# The schema itself declares them, nullable, for every seat.
assert_file_contains "$ULTRA" '`usage` (string or **null**) and `usage_file` (string or **null**)'
assert_file_contains "$ULTRA" "returned by EVERY seat including the ones that exited non-zero"
# The anti-double-count rule, both halves of it.
assert_file_contains "$ULTRA" "adding each file EXACTLY ONCE per seat"
assert_file_contains "$ULTRA" "is **NEVER** added to the total"
assert_file_contains "$ULTRA" "double-count"
# …and the reason usage_file exists at all: the checksum is not reversible.
assert_file_contains "$ULTRA" "never reconstruct that prefix from \`target_key\`"

# --- the footers the skills are told to read really are emitted --------------
# A contract asserted only against Markdown could drift away from the scripts;
# these two anchors keep the documentation and the wrappers on the same page.
assert_matches "$SCRIPTS/codex-start.sh" "^ *printf 'USAGE: %s"
assert_matches "$SCRIPTS/codex-resume.sh" "^ *printf 'USAGE: %s"
assert_matches "$SCRIPTS/codex-swarm.sh" "^ *printf 'USAGE: %s"
assert_matches "$SCRIPTS/codex-swarm.sh" "^ *printf 'USAGE_FILE: %s"

note "plan/review/implement/run/ultra SKILL.md — token accounting anchored"
