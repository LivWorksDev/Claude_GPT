#!/usr/bin/env bash
# Absent or corrupt state degrades to an explicit `desconocido` and NEVER to an
# error: this tool is an orientation aid, and a machine whose state is broken —
# or whose toolchain is — is exactly when it gets used. jq and git are therefore
# SOFT dependencies here (the deliberate contrast with the wrappers' exit 3),
# and no degradation may leak a bash trace or an "integer expression expected"
# into the report.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

ST="$SCRIPTS/tandem-status.sh"
PLAN_REL="docs/plans/demo.plan.md"
R="$CLAUDE_PROJECT_DIR"

status() {
  run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$ST" "$@"
  return 0
}

assert_quiet() {
  # A report on stdout, nothing at all on stderr: stderr belongs to exit 2/64.
  assert_not_contains "$ERR" "integer expression"
  assert_not_contains "$ERR" "tandem-status.sh:"
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "${1:-nothing on stderr}"
}

# --- a run with state in every phase -----------------------------------------
make_repo "$R"
printf 'seed\n' >"$R/f.txt"
commit_all "$R" seed
mkdir -p "$R/docs/plans" "$R/.tandem/log" "$R/.tandem/state/implement-claude"
printf '# Plan: demo\n' >"$R/$PLAN_REL"
printf '# tandem log — demo\n\ngate — lint: OK · tests: 1 passed\n' >"$R/.tandem/log/demo.md"

seed_thread review "$PLAN_REL" thr_plan 2
RD="$(state_dir review)"
KP="$(tkey "$PLAN_REL")"
printf 'findings\nVERDICT: REVISE\n' >"$RD/$KP.t1.reply.txt"
printf 'ok\nVERDICT: APPROVED\n' >"$RD/$KP.t2.reply.txt"
printf '{"input_tokens":100,"output_tokens":10}\n' >"$RD/$KP.t1.usage.json"
printf '{"input_tokens":200,"output_tokens":20}\n' >"$RD/$KP.t2.usage.json"
OPJ="$R/.tandem/state/implement-claude/demo.json"
jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_COMPLETE", continuation_rounds:0}' >"$OPJ"

status demo
assert_rc 0 "healthy baseline"
assert_file_contains "$OUT" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" 'plan in 300 · out 30'
assert_quiet "baseline stderr"

# --- the Opus attempt state is not JSON at all -------------------------------
printf 'garbage{' >"$OPJ"
status demo
assert_rc 0 "corrupt attempt state"
assert_matches "$OUT" '^implement: +opus · desconocido'
assert_file_contains "$OUT" "desconocido"
assert_quiet "corrupt attempt state stderr"

# …and a JSON of the wrong SHAPE is corruption too, not a value to trust.
jq -n '{status:{}, last_sentinel:[], continuation_rounds:"x"}' >"$OPJ"
status demo
assert_rc 0 "attempt state with the wrong shape"
assert_file_contains "$OUT" "desconocido (estado corrupto)"
assert_quiet "wrong-shape attempt state stderr"
jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_COMPLETE", continuation_rounds:0}' >"$OPJ"

# --- a corrupt turn counter: rounds are `?`, never an arithmetic error -------
printf 'not-a-number\n' >"$RD/$KP.turn"
status demo
assert_rc 0 "corrupt turn counter"
assert_matches "$OUT" '^plan-review: +\? rondas'
assert_file_contains "$OUT" "REVISE, APPROVED"
assert_quiet "corrupt turn counter stderr"
printf '2\n' >"$RD/$KP.turn"

# --- an unreadable ledger is counted, and the rest of the phase still sums ---
printf 'not json at all' >"$RD/$KP.t2.usage.json"
status demo
assert_rc 0 "corrupt usage ledger"
assert_file_contains "$OUT" 'plan in 100 · out 10 (+1 ilegible)'
assert_file_contains "$OUT" 'total in 100 · out 10'
assert_quiet "corrupt ledger stderr"
printf '{"input_tokens":200,"output_tokens":20}\n' >"$RD/$KP.t2.usage.json"

# --- without jq: a structural report, tokens explicitly unknown --------------
# $SANDBOX/bin plus a minimal symlink farm and NOTHING else: /usr/bin/jq exists
# on macOS and on both CI runners, so dropping $SANDBOX/tools is not enough.
MINBIN="$(make_minbin)"
NOJQ="$SANDBOX/bin:$MINBIN"
if env PATH="$NOJQ" bash -c 'command -v jq' >/dev/null 2>&1; then
  fail "jq is still reachable on the jq-free PATH"
fi
run_in "$R" env PATH="$NOJQ" CLAUDE_PROJECT_DIR="$R" bash "$ST" demo
assert_rc 0 "status without jq"
assert_matches "$OUT" '^slug: +demo$'
assert_matches "$OUT" '^tokens: +desconocido \(sin jq\)$'
assert_file_contains "$OUT" "opus · desconocido (sin jq)"
assert_file_contains "$OUT" "2 rondas"
assert_file_contains "$OUT" "gate — lint: OK · tests: 1 passed"
assert_matches "$OUT" '^fase: +'
assert_quiet "no-jq stderr"

# --- without git: the branch is unknown, the report is not ------------------
rm -f "$MINBIN/git"
NOGIT="$SANDBOX/bin:$MINBIN"
if env PATH="$NOGIT" bash -c 'command -v git' >/dev/null 2>&1; then
  fail "git is still reachable on the git-free PATH"
fi
run_in "$R" env PATH="$NOGIT" CLAUDE_PROJECT_DIR="$R" bash "$ST" demo
assert_rc 0 "status without git"
assert_matches "$OUT" '^rama: +desconocido \(sin git\)$'
assert_matches "$OUT" '^slug: +demo$'
assert_file_contains "$OUT" "2 rondas"
assert_quiet "no-git stderr"

# --- a hostile filesystem: no writable TMPDIR, no writable HOME -------------
# A read-only sandbox is a first-class environment for this tool, and bash
# materializes every heredoc and here-string as a TEMPORARY FILE: on such a
# machine those reads fail, fields come out wrong and a list mode can end in
# "(ningún run conocido)" while still exiting 0 — a false-valid report.
#
# The dynamic half of the guard is below; it is NOT sufficient on its own,
# because bash silently falls back to /tmp when $TMPDIR is unwritable, and /tmp
# cannot be made read-only from a test. The structural assertion right after is
# what actually holds the line.
RO="$SANDBOX/nowrite"
mkdir -p "$RO"
chmod 555 "$RO"
run_in "$R" env TMPDIR="$RO" HOME="$RO" CLAUDE_PROJECT_DIR="$R" bash "$ST" demo
assert_rc 0 "status with an unwritable TMPDIR and HOME"
assert_matches "$OUT" '^slug: +demo$'
assert_file_contains "$OUT" "2 rondas"
assert_file_contains "$OUT" "REVISE, APPROVED"
assert_file_contains "$OUT" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" 'plan in 300 · out 30'
assert_file_contains "$OUT" "gate — lint: OK · tests: 1 passed"
assert_quiet "unwritable TMPDIR stderr"

run_in "$R" env TMPDIR="$RO" HOME="$RO" CLAUDE_PROJECT_DIR="$R" bash "$ST"
assert_rc 0 "listing with an unwritable TMPDIR and HOME"
assert_matches "$OUT" '^demo — '
assert_not_contains "$OUT" "ningún run conocido"
assert_quiet "unwritable TMPDIR listing stderr"
chmod 755 "$RO"

# The structural rule, so a future heredoc cannot creep back in: the script
# reads command output through `$( )` (a pipe) and splits it in place.
assert_not_contains "$SCRIPTS/tandem-status.sh" '<<EOF'
assert_not_contains "$SCRIPTS/tandem-status.sh" '<<-'
assert_not_contains "$SCRIPTS/tandem-status.sh" '<<<'
assert_not_contains "$SCRIPTS/tandem-status.sh" 'mktemp'
if LC_ALL=C grep -nE '<<[A-Za-z_'\''"]' "$SCRIPTS/tandem-status.sh" >/dev/null 2>&1; then
  LC_ALL=C grep -nE '<<[A-Za-z_'\''"]' "$SCRIPTS/tandem-status.sh" >&2
  fail "tandem-status.sh uses a heredoc — bash needs a writable temp dir for those"
fi

# --- an approval record is only an approval when it HOLDS UP -----------------
# plan-approve.sh publishes four fields and re-verifies each against git; if the
# mere presence of the file counted, a truncated write or a record copied from
# another run would read as "plan aprobado" and send the user straight to
# tandem:implement — skipping the human gate this flow exists to protect.
PA_REPO="$SANDBOX/approval"
make_repo "$PA_REPO"
printf 'seed\n' >"$PA_REPO/f.txt"
commit_all "$PA_REPO" seed
mkdir -p "$PA_REPO/docs/plans" "$PA_REPO/.tandem/state/plan-approve"
printf '# Plan: demo\n' >"$PA_REPO/docs/plans/demo.plan.md"
PA_JSON="$PA_REPO/.tandem/state/plan-approve/demo.json"

pa_status() {
  run_in "$PA_REPO" env CLAUDE_PROJECT_DIR="$PA_REPO" bash "$ST" demo
  return 0
}

assert_not_approved() {
  assert_rc 0 "$1"
  assert_file_contains "$OUT" "registro de aprobación corrupto"
  # The phase must NOT advance, and the next step must not send anyone to
  # implement past a gate that was never proven.
  assert_matches "$OUT" '^fase: +plan \(borrador\)$'
  assert_file_contains "$OUT" "ATENCIÓN"
  # Plain, and never padding-dependent: `row()` pads the label to 14 columns, so
  # a needle with the padding baked in ("next:" + 10 spaces) could never match
  # and the guarantee it looked like it was making was vacuous.
  assert_not_contains "$OUT" "/tandem:implement"
  assert_quiet "$1 stderr"
}

# Truncated: the write died half way through.
printf '{\n  "branch": "tandem/demo",\n' >"$PA_JSON"
pa_status
assert_not_approved "truncated approval record"

# Complete in shape, but describing ANOTHER run.
printf '{\n  "branch": "tandem/otro",\n  "plan_commit": "%s",\n  "source_head": "%s",\n  "mode": "in-place"\n}\n' \
  "1111111111111111111111111111111111111111" "2222222222222222222222222222222222222222" \
  >"$PA_JSON"
pa_status
assert_not_approved "approval record of another branch"

# Well-formed and about this branch, but its commits are not in this repository.
printf '{\n  "branch": "tandem/demo",\n  "plan_commit": "%s",\n  "source_head": "%s",\n  "mode": "in-place"\n}\n' \
  "1111111111111111111111111111111111111111" "2222222222222222222222222222222222222222" \
  >"$PA_JSON"
pa_status
assert_not_approved "approval record with commits this repository does not have"

# The positive control: the record the REAL script writes is accepted.
rm -f "$PA_JSON"
run_in "$PA_REPO" env CLAUDE_PROJECT_DIR="$PA_REPO" bash "$SCRIPTS/plan-approve.sh" demo
assert_rc 0 "real approval"
pa_status
assert_rc 0 "real approval record"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_not_contains "$OUT" "corrupto"
assert_file_contains "$OUT" "/tandem:implement demo"
assert_quiet "real approval stderr"

# …and that very record, read on a machine without git, is NOT an approval: the
# four facts plan-approve re-checks (the commit exists, sits on the recorded
# source_head, touches only the plan and carries it) cannot be produced at all
# from a structural read, and a corrupt record is indistinguishable from this
# one here. It degrades to an explicit unverified state instead of certifying.
run_in "$PA_REPO" env PATH="$NOGIT" CLAUDE_PROJECT_DIR="$PA_REPO" bash "$ST" demo
assert_rc 0 "the real approval record, without git"
assert_matches "$OUT" '^fase: +aprobación no verificada$'
assert_file_contains "$OUT" "SIN VERIFICAR (sin git)"
assert_not_contains "$OUT" "plan aprobado"
assert_not_contains "$OUT" "aprobado: commit"
assert_not_contains "$OUT" "/tandem:implement"
assert_quiet "no-git approval record stderr"

# …and now one field at a time, over a record whose COMMITS are perfectly real:
# each structural rule has to reject on its own, with git agreeing about the
# commits, or it is not a rule at all.
PA_COMMIT="$(git -C "$PA_REPO" rev-parse refs/heads/tandem/demo)"
PA_SRC="$(git -C "$PA_REPO" rev-parse "refs/heads/tandem/demo^")"
write_pa() {
  printf '{\n  "branch": "%s",\n  "plan_commit": "%s",\n  "source_head": "%s",\n  "mode": "%s"\n}\n' \
    "$1" "$2" "$3" "$4" >"$PA_JSON"
}

write_pa "tandem/demo" "$PA_COMMIT" "$PA_SRC" "in-place"
pa_status
assert_rc 0 "hand-written record with the real values"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_not_contains "$OUT" "corrupto"

write_pa "tandem/otro" "$PA_COMMIT" "$PA_SRC" "in-place"
pa_status
assert_not_approved "approval record naming another branch"

write_pa "tandem/demo" "$PA_COMMIT" "$PA_SRC" "bogus"
pa_status
assert_not_approved "approval record with an unknown mode"

# git RESOLVES an abbreviated sha, so only the structural rule catches this one.
write_pa "tandem/demo" "${PA_COMMIT:0:7}" "$PA_SRC" "in-place"
pa_status
assert_not_approved "approval record with an abbreviated plan_commit"

write_pa "tandem/demo" "$PA_COMMIT" "${PA_SRC:0:7}" "in-place"
pa_status
assert_not_approved "approval record with an abbreviated source_head"

# The plan commit is real, but it does NOT sit on the recorded source_head.
write_pa "tandem/demo" "$PA_COMMIT" "$PA_COMMIT" "in-place"
pa_status
assert_not_approved "approval record whose source_head is not the plan commit's parent"

# --- the two invariants plan-approve IMPOSES, mirrored here ------------------
# The right parent is not enough: plan-approve refuses a commit that touches
# anything but the plan, and one that does not carry the plan. Checking only
# parentage would bless a perfectly ordinary sibling commit as "plan aprobado"
# and send the user to implement on top of it — these commits are REAL, so the
# cases are not vacuous by construction.
git -C "$PA_REPO" checkout -q -b evil "$PA_SRC" || fail "cannot branch off source_head"
printf 'evil\n' >"$PA_REPO/evil.txt"
git -C "$PA_REPO" add -- evil.txt || fail "cannot stage the sibling commit"
git -C "$PA_REPO" commit -q -m "not an approval at all" || fail "sibling commit failed"
PA_EVIL="$(git -C "$PA_REPO" rev-parse HEAD)"
git -C "$PA_REPO" checkout -q tandem/demo || fail "cannot return to tandem/demo"
git -C "$PA_REPO" branch -D evil >/dev/null 2>&1 || fail "cannot retire the sibling branch"

write_pa "tandem/demo" "$PA_EVIL" "$PA_SRC" "in-place"
pa_status
assert_not_approved "plan commit that touches no plan at all"

# Same parent, and it does touch the plan — plus a second file.
git -C "$PA_REPO" checkout -q -b evil2 "$PA_SRC" || fail "cannot branch off source_head"
mkdir -p "$PA_REPO/docs/plans"
printf '# Plan: demo\n' >"$PA_REPO/docs/plans/demo.plan.md"
printf 'extra\n' >"$PA_REPO/extra.txt"
git -C "$PA_REPO" add -- docs/plans/demo.plan.md extra.txt || fail "cannot stage the mixed commit"
git -C "$PA_REPO" commit -q -m "the plan plus something else" || fail "mixed commit failed"
PA_EVIL2="$(git -C "$PA_REPO" rev-parse HEAD)"
git -C "$PA_REPO" checkout -q tandem/demo || fail "cannot return to tandem/demo"
git -C "$PA_REPO" branch -D evil2 >/dev/null 2>&1 || fail "cannot retire the mixed branch"

write_pa "tandem/demo" "$PA_EVIL2" "$PA_SRC" "in-place"
pa_status
assert_not_approved "plan commit that touches more than the plan"

# The blob guard, on its own: a child that ONLY deletes the plan passes the
# parent check (its parent is the real approval commit) and the plan-only diff
# (the deletion touches exactly that path) — only `commit:plan` catches it.
git -C "$PA_REPO" checkout -q -b noplan "$PA_COMMIT" || fail "cannot branch off the plan commit"
git -C "$PA_REPO" rm -q -- docs/plans/demo.plan.md || fail "cannot delete the plan"
git -C "$PA_REPO" commit -q -m "delete the plan" || fail "deletion commit failed"
PA_DEL="$(git -C "$PA_REPO" rev-parse HEAD)"
git -C "$PA_REPO" checkout -q tandem/demo || fail "cannot return to tandem/demo"
git -C "$PA_REPO" branch -D noplan >/dev/null 2>&1 || fail "cannot retire the deletion branch"

write_pa "tandem/demo" "$PA_DEL" "$PA_COMMIT" "in-place"
pa_status
assert_not_approved "plan commit that does not contain the plan"

# --- a sound record still needs a branch that CARRIES the run ----------------
# A `tandem/<slug>` reset back to source_head counts 0 commits over the plan
# exactly like an untouched one: only containment tells them apart, and nothing
# can be implemented nor reviewed on a branch that lost the approval commit.
write_pa "tandem/demo" "$PA_COMMIT" "$PA_SRC" "in-place"
git -C "$PA_REPO" checkout -q --detach "$PA_COMMIT" || fail "cannot detach HEAD"
git -C "$PA_REPO" branch -f tandem/demo "$PA_SRC" || fail "cannot reset the tandem branch"
pa_status
assert_rc 0 "sound record, branch reset to source_head"
assert_file_contains "$OUT" "ATENCIÓN"
assert_file_contains "$OUT" "la rama tandem/demo no contiene el commit de aprobación"
assert_not_contains "$OUT" "/tandem:implement"
assert_quiet "reset branch stderr"

# …and the block is about the RUN, not about one phase: with gate evidence on
# top, the phase is higher and the next must still recommend neither.
mkdir -p "$PA_REPO/.tandem/log"
printf '# tandem log — demo\n\ngate — lint: OK · tests: 2 passed\n' >"$PA_REPO/.tandem/log/demo.md"
pa_status
assert_rc 0 "broken branch under higher pipeline evidence"
assert_matches "$OUT" '^fase: +gate de testing$'
assert_file_contains "$OUT" "la rama tandem/demo no contiene el commit de aprobación"
assert_not_contains "$OUT" "/tandem:implement"
assert_not_contains "$OUT" "/tandem:review"
assert_quiet "broken branch with gate evidence stderr"

# A branch deleted MID-RUN (no terminal record anywhere) is the same problem
# with a different message. The post-merge control — a terminal record with the
# branch legitimately gone — lives in status-phases and is untouched.
rm -f "$PA_REPO/.tandem/log/demo.md"
git -C "$PA_REPO" branch -D tandem/demo >/dev/null 2>&1 || fail "cannot delete the tandem branch"
pa_status
assert_rc 0 "sound record, branch deleted mid-run"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_file_contains "$OUT" "la rama tandem/demo no existe"
assert_not_contains "$OUT" "/tandem:implement"
assert_quiet "deleted branch stderr"

# --- unverified overrides every next, whatever the phase says ----------------
# The phase is descriptive (what evidence exists); the next is prescriptive
# (what to do), and only the second can push anyone across a gate whose proof
# was never produced.
mkdir -p "$PA_REPO/.tandem/state/implement-claude"
jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_PARTIAL", continuation_rounds:1}' \
  >"$PA_REPO/.tandem/state/implement-claude/demo.json"
run_in "$PA_REPO" env PATH="$NOGIT" CLAUDE_PROJECT_DIR="$PA_REPO" bash "$ST" demo
assert_rc 0 "unverified approval under a higher rung, without git"
assert_matches "$OUT" '^fase: +implementación$'
assert_file_contains "$OUT" "SIN VERIFICAR (sin git)"
assert_not_contains "$OUT" "/tandem:implement"
assert_not_contains "$OUT" "/tandem:review"
assert_quiet "unverified with higher evidence stderr"

# --- git is there, but the state does not live in a repository --------------
# The reason is REPORTED, never a fixed literal: this one is not "sin git".
NOREPO="$SANDBOX/norepo"
mkdir -p "$NOREPO/docs/plans" "$NOREPO/.tandem/state/plan-approve"
printf '# Plan: demo\n' >"$NOREPO/docs/plans/demo.plan.md"
cp "$PA_JSON" "$NOREPO/.tandem/state/plan-approve/demo.json"
run_in "$NOREPO" env CLAUDE_PROJECT_DIR="$NOREPO" bash "$ST" demo
assert_rc 0 "approval record outside a git repository"
assert_matches "$OUT" '^fase: +aprobación no verificada$'
assert_file_contains "$OUT" "SIN VERIFICAR (fuera de un repositorio git)"
assert_not_contains "$OUT" "SIN VERIFICAR (sin git)"
assert_not_contains "$OUT" "plan aprobado"
assert_not_contains "$OUT" "aprobado: commit"
assert_not_contains "$OUT" "/tandem:implement"
assert_quiet "outside-a-repository stderr"

# --- `.tandem/` missing altogether, with the plan on disk -------------------
B="$SANDBOX/plain"
make_repo "$B"
printf 'seed\n' >"$B/f.txt"
commit_all "$B" seed
mkdir -p "$B/docs/plans"
printf '# Plan: solo\n' >"$B/docs/plans/solo.plan.md"

run_in "$B" env CLAUDE_PROJECT_DIR="$B" bash "$ST" solo
assert_rc 0 "no .tandem at all"
assert_matches "$OUT" '^fase: +plan \(borrador\)$'
assert_matches "$OUT" '^log: +ausente$'
assert_matches "$OUT" '^gate: +sin registro$'
assert_matches "$OUT" '^implement: +sin intento$'
assert_matches "$OUT" '^plan-review: +sin hilo$'
assert_quiet "no-state stderr"
# Reading state must never CREATE it.
assert_no_file "$B/.tandem"

# codex was never invoked.
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
