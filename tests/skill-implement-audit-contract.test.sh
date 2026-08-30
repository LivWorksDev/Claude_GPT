#!/usr/bin/env bash
# The implementation audit orchestration lives in executable Markdown, so pin
# its lifecycle and failure semantics statically like the worktree contracts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

IMPL="$REPO_ROOT/skills/implement/SKILL.md"
assert_file "$IMPL"
FLAT="$SANDBOX/implement.flat"
LC_ALL=C tr '\n' ' ' <"$IMPL" | LC_ALL=C tr -s ' ' >"$FLAT"
[ "$(wc -l <"$IMPL" | tr -d ' ')" -ge 200 ] || fail "implement skill looks truncated"

# The two fresh transports each publish immediately before launch, and resumes
# are explicitly forbidden from manufacturing a new baseline.
SNAPSHOTS="$(grep -F -c 'implement-audit.sh" snapshot <slug> "$WORK_ROOT"' "$IMPL")"
assert_eq 2 "$SNAPSHOTS" "one snapshot command per fresh transport"
assert_file_contains "$FLAT" 'On a **FRESH Opus attempt only**'
assert_file_contains "$FLAT" 'last action immediately before the launch'
assert_file_contains "$FLAT" '# FRESH only; never on resume'
assert_file_contains "$FLAT" 'Never invoke `snapshot` on a resume, recovery, or continuation'
assert_file_contains "$FLAT" 'The `snapshot` line is the last action before either Sol start transport launches'

# check owns the sentinel after implementation and runs before the gate.
assert_file_contains "$IMPL" 'bash "$SCRIPTS/implement-audit.sh" check <slug> "$WORK_ROOT"'
assert_file_contains "$FLAT" 'Before the testing gate, run the machine verdict'
assert_file_contains "$FLAT" 'Exit 20 means the attempt **is `IMPLEMENTATION_PARTIAL` for pipeline purposes, regardless of an implementer'
assert_file_contains "$FLAT" 'Copy every `VIOLATION:` line verbatim to the log'
assert_file_contains "$FLAT" 'Exit 65 blocks progress fail-closed'
assert_file_contains "$FLAT" 'After any remediation, re-run `check`; exit 0 is mandatory before the testing gate'
assert_file_contains "$FLAT" 'never advance to review with open violations and never accept them silently'
assert_file_contains "$IMPL" 'audit — escrituras: OK'

CHECK_LINE="$(grep -nF 'implement-audit.sh" check <slug> "$WORK_ROOT"' "$IMPL" | head -n 1 | cut -d: -f1)"
GATE_LINE="$(grep -nF '## Step 4 — Testing gate' "$IMPL" | head -n 1 | cut -d: -f1)"
[ "$CHECK_LINE" -lt "$GATE_LINE" ] || fail "audit check is not before the testing gate"

# Staged-only state stays visible through two distinct diff views.
assert_file_contains "$IMPL" 'git -C "$WORK_ROOT" diff --cached'
assert_file_contains "$IMPL" 'git -C "$WORK_ROOT" diff` (index↔worktree)'
assert_file_contains "$FLAT" 'Never replace these two views with `git diff HEAD`'

# Handoff closes only after both green gates; census persists.
assert_file_contains "$IMPL" 'bash "$SCRIPTS/implement-audit.sh" close <slug>'
assert_file_contains "$FLAT" 'Only after the testing gate is green **and** the latest write audit exited 0'
assert_file_contains "$FLAT" '`close` removes only the guard; the census remains as the attempt record'

# Both reset routes name the expanded artifacts and the interruption-safe order.
assert_file_contains "$IMPL" '.tandem/state/implement-audit/<slug>.census'
assert_file_contains "$IMPL" '.tandem/state/implement-audit/<slug>.guard'
assert_file_contains "$FLAT" 'census → target-key thread state → guard-last order'
assert_file_contains "$FLAT" '**as the last deletion**'
assert_file_contains "$FLAT" 'Never hand-delete the guard first'

note "implement SKILL.md — fresh snapshot, audit verdict, reset order and close pinned"
