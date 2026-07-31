#!/usr/bin/env bash
# Without a slug the tool answers "which runs exist at all", and that list is
# also what an unknown slug gets on stderr instead of a report full of
# `desconocido` — a typo must stop honestly. The list is the deduplicated UNION
# of four sources across every candidate root, minus the `ultra-*` namespace,
# which keeps its own state.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

ST="$SCRIPTS/tandem-status.sh"
R="$CLAUDE_PROJECT_DIR"

# runs_named <slug> — how many lines of the listing belong to that run.
runs_named() {
  LC_ALL=C awk -v s="$1" '$1 == s { n++ } END { print n + 0 }' "$OUT"
}

make_repo "$R"
printf 'seed\n' >"$R/f.txt"
commit_all "$R" seed

# --- nothing at all ----------------------------------------------------------
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST"
assert_rc 0 "empty listing"
assert_file_contains "$OUT" "(ningún run conocido)"
assert_no_file "$R/.tandem"

# --- one run per source ------------------------------------------------------
mkdir -p "$R/.tandem/log" "$R/.tandem/state/plan-approve" "$R/.tandem/state/implement-claude"
mkdir -p "$R/docs/plans"
printf '# tandem log — a\n' >"$R/.tandem/log/a.md"
printf '# Plan: a\n' >"$R/docs/plans/a.plan.md"
printf '{\n  "branch": "tandem/b",\n  "plan_commit": "deadbeef",\n  "mode": "in-place"\n}\n' \
  >"$R/.tandem/state/plan-approve/b.json"
printf '{"status":"terminal","last_sentinel":null}\n' >"$R/.tandem/state/implement-claude/c.json"
git -C "$R" branch tandem/d >/dev/null 2>&1 || fail "cannot create tandem/d"
# The swarm keeps its own namespace and is deliberately out of scope…
printf '# ultra run\n' >"$R/.tandem/log/ultra-x.md"
# …and neither an interrupted approval nor a turn report is a run of its own.
printf '{\n  "branch": "tandem/b"\n}\n' >"$R/.tandem/state/plan-approve/b.json.pending"
printf 'report\n' >"$R/.tandem/state/implement-claude/c.t1.report.md"

run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST"
assert_rc 0 "listing with runs"
assert_eq "1" "$(runs_named a)" "run a listed once"
assert_eq "1" "$(runs_named b)" "run b listed once"
assert_eq "1" "$(runs_named c)" "run c listed once"
assert_eq "1" "$(runs_named d)" "run d listed once"
assert_not_contains "$OUT" "ultra-x"
assert_not_contains "$OUT" "pending"
assert_not_contains "$OUT" "report"
assert_eq "4" "$(wc -l <"$OUT" | tr -d ' ')" "exactly four runs"
# Each line carries the phase the evidence proves, not just the name — and a
# run whose only trace is a branch, or an approval record that does not hold up
# (b's is a stub: no source_head, no real commit), says `desconocido` instead of
# inventing a phase. status-degradation owns that rule in depth.
assert_matches "$OUT" '^a — plan \(borrador\)$'
assert_matches "$OUT" '^b — desconocido$'
assert_matches "$OUT" '^c — implementación$'
assert_matches "$OUT" '^d — desconocido$'

# --- an unknown slug: exit 2, and the known runs on stderr -------------------
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST" nope
assert_rc 2 "unknown slug"
assert_file_contains "$ERR" 'no hay ni rastro del run "nope"'
assert_file_contains "$ERR" "runs conocidos"
assert_file_contains "$ERR" "a — "
assert_file_contains "$ERR" "d — "
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "nothing on stdout for an unknown slug"

# --- usage -------------------------------------------------------------------
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST" "../x"
assert_rc 64 "slug with path characters"
assert_file_contains "$ERR" "usage:"
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST" ""
assert_rc 64 "empty slug"
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST" a b
assert_rc 64 "two arguments"

# --- state split across roots: the UNION, deduplicated ----------------------
# The session runs inside a linked worktree that has a `.tandem/` of its own.
# Stopping at the first root with something in it would hide every run of the
# main checkout; counting a run twice because two roots know it would be worse.
M="$SANDBOX/split"
make_repo "$M"
printf 'seed\n' >"$M/f.txt"
commit_all "$M" seed
git -C "$M" worktree add "$M/wt" -b tandem/g >/dev/null 2>&1 \
  || fail "cannot create the linked worktree"
mkdir -p "$M/.tandem/log" "$M/wt/.tandem/log"
printf '# main\n' >"$M/.tandem/log/e.md"
printf '# worktree\n' >"$M/wt/.tandem/log/f.md"
printf '# both\n' >"$M/.tandem/log/g.md"
printf '# both\n' >"$M/wt/.tandem/log/g.md"

run_in "$M/wt" env CLAUDE_PROJECT_DIR="$M/wt" bash "$ST"
assert_rc 0 "listing from a linked worktree"
assert_eq "1" "$(runs_named e)" "the main checkout's run is listed"
assert_eq "1" "$(runs_named f)" "the worktree's run is listed"
assert_eq "1" "$(runs_named g)" "a run known to both roots is listed once"
assert_eq "3" "$(wc -l <"$OUT" | tr -d ' ')" "exactly three runs"

# codex was never invoked — not even to list.
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
