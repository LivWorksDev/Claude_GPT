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
  assert_not_contains "$OUT" "next:          /tandem:implement"
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
