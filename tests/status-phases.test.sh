#!/usr/bin/env bash
# tandem-status.sh walks a REAL run: a real repository, the real plan-approve.sh,
# real thread state, real ledgers and a real merge. Every rung of the phase
# ladder is asserted where the evidence for it appears, because the ladder is
# the whole point of this tool — a status that lies about where a run stands is
# worse than no status at all.
#
# Two contracts ride along on every single invocation:
#   - codex is NEVER called (asserted at the end, on the stub's own records);
#   - the report is STRICTLY read-only: the working tree, `.tandem/` and the
#     refs are snapshotted before and after each run and compared byte for byte.
#     Sourcing _common.sh puts state_init (which mkdirs) within reach, so an
#     accidental call is exactly what this net catches.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

ST="$SCRIPTS/tandem-status.sh"
PLAN_REL="docs/plans/demo.plan.md"
R="$CLAUDE_PROJECT_DIR"
STATUS_PATH=""

# ro_snap <repo> <out> — ordered listing + per-file cksum of the working tree
# and of `.tandem/`, plus the refs and the checked-out branch. `.git`'s internal
# bookkeeping is git's own business (a read-only plumbing call may refresh its
# caches); what must not change is everything else.
ro_snap() {
  local d="$1" out="$2" f
  {
    (cd "$d" && find . -path ./.git -prune -o -print) | LC_ALL=C sort
    (cd "$d" && find . -path ./.git -prune -o -type f -print) | LC_ALL=C sort \
      | while IFS= read -r f; do
        printf '%s ' "$f"
        cksum <"$d/$f"
      done
    git -C "$d" show-ref 2>/dev/null | LC_ALL=C sort
    git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null
  } >"$out"
  return 0
}

# status_in <cwd> <project-dir> <label> [args…] — one invocation, wrapped in
# the read-only proof. BOTH directories are snapshotted: the shell's working
# repository and the project whose state is being read need not be the same.
# $STATUS_PATH, when set, replaces PATH for that run only.
status_in() {
  local cwd="$1" proj="$2" label="$3"
  shift 3
  ro_snap "$cwd" "$SANDBOX/ro.a.before"
  ro_snap "$proj" "$SANDBOX/ro.b.before"
  if [ -n "$STATUS_PATH" ]; then
    run_in "$cwd" env PATH="$STATUS_PATH" CLAUDE_PROJECT_DIR="$proj" bash "$ST" "$@"
  else
    run_in "$cwd" env CLAUDE_PROJECT_DIR="$proj" bash "$ST" "$@"
  fi
  ro_snap "$cwd" "$SANDBOX/ro.a.after"
  ro_snap "$proj" "$SANDBOX/ro.b.after"
  if ! cmp -s "$SANDBOX/ro.a.before" "$SANDBOX/ro.a.after" \
    || ! cmp -s "$SANDBOX/ro.b.before" "$SANDBOX/ro.b.after"; then
    diff "$SANDBOX/ro.a.before" "$SANDBOX/ro.a.after" >&2 2>/dev/null || true
    diff "$SANDBOX/ro.b.before" "$SANDBOX/ro.b.after" >&2 2>/dev/null || true
    fail "status ($label) modified the repository — it must be strictly read-only"
  fi
  return 0
}

status() { status_in "$R" "$R" "$@"; }

# =============================================================================
# 1. Only the plan on disk: `plan (borrador)`, and `.tandem/` stays ABSENT
# =============================================================================
make_repo "$R"
printf 'seed\n' >"$R/f.txt"
commit_all "$R" seed
USER_BRANCH="$(git -C "$R" rev-parse --abbrev-ref HEAD)"
mkdir -p "$R/docs/plans"
printf '# Plan: demo\n' >"$R/$PLAN_REL"

status "solo plan" demo
assert_rc 0 "plan draft"
assert_matches "$OUT" '^fase: +plan \(borrador\)$'
assert_file_contains "$OUT" "/tandem:plan"
assert_no_file "$R/.tandem"

# =============================================================================
# 2. The plan-review thread: rounds and one verdict per round, in order
# =============================================================================
seed_thread review "$PLAN_REL" thr_plan 1
RD="$(state_dir review)"
KP="$(tkey "$PLAN_REL")"
printf 'findings\nVERDICT: REVISE\n' >"$RD/$KP.t1.reply.txt"
printf '{"input_tokens":100,"output_tokens":10}\n' >"$RD/$KP.t1.usage.json"

status "plan-review ronda 1" demo
assert_rc 0 "plan under review, round 1"
assert_file_contains "$OUT" "1 ronda · veredictos: REVISE"
assert_matches "$OUT" '^fase: +plan en revisión$'
assert_file_contains "$OUT" "retomar el hilo"

printf '2\n' >"$RD/$KP.turn"
printf 'no new findings\nVERDICT: APPROVED\n' >"$RD/$KP.t2.reply.txt"
printf '{"input_tokens":200,"output_tokens":20}\n' >"$RD/$KP.t2.usage.json"

status "plan-review" demo
assert_rc 0 "plan under review"
assert_file_contains "$OUT" "2 rondas"
assert_file_contains "$OUT" "REVISE, APPROVED"
assert_matches "$OUT" '^fase: +plan en revisión$'
# 7. First human gate: APPROVED with no approval record yet.
assert_file_contains "$OUT" "plan-approve.sh"

# =============================================================================
# 3. Approval through the REAL plan-approve.sh
# =============================================================================
run_in "$R" env CLAUDE_PROJECT_DIR="$R" bash "$SCRIPTS/plan-approve.sh" demo
assert_rc 0 "real plan approval"
PLAN_COMMIT="$(git -C "$R" rev-parse refs/heads/tandem/demo)"

status "plan aprobado" demo
assert_rc 0 "plan approved"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_file_contains "$OUT" "tandem/demo · tip ${PLAN_COMMIT:0:7}"
assert_file_contains "$OUT" "0 commit(s) sobre el plan"
assert_file_contains "$OUT" "/tandem:implement demo"

# …and the repository consulted is the PROJECT's, not whichever one the shell
# happens to stand in: run from an unrelated checkout, the branch, the commit
# count and the approval must still be the project's.
U="$SANDBOX/unrelated"
make_repo "$U"
printf 'other\n' >"$U/other.txt"
commit_all "$U" "unrelated repository"
status_in "$U" "$R" "desde otro repositorio" demo
assert_rc 0 "invoked from an unrelated repository"
assert_file_contains "$OUT" "tandem/demo · tip ${PLAN_COMMIT:0:7}"
assert_file_contains "$OUT" "0 commit(s) sobre el plan"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_not_contains "$OUT" "sin rama"
assert_not_contains "$OUT" "corrupto"

# =============================================================================
# 4. The durable Opus attempt: running, then terminal PARTIAL
# =============================================================================
OPD="$R/.tandem/state/implement-claude"
mkdir -p "$OPD"
jq -n '{status:"running", last_sentinel:null, continuation_rounds:0}' >"$OPD/demo.json"

status "opus running" demo
assert_rc 0 "opus attempt running"
assert_file_contains "$OUT" "opus"
assert_file_contains "$OUT" "running"
assert_matches "$OUT" '^fase: +implementación$'
assert_file_contains "$OUT" "guard de liveness"

jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_PARTIAL", continuation_rounds:1}' \
  >"$OPD/demo.json"
status "opus partial" demo
assert_rc 0 "opus attempt partial"
assert_file_contains "$OUT" "IMPLEMENTATION_PARTIAL"
assert_file_contains "$OUT" "continuación"

# =============================================================================
# 5. The testing gate, one line and wrapped over two
# =============================================================================
LOG="$R/.tandem/log/demo.md"
mkdir -p "$R/.tandem/log"
printf '# tandem log — demo\n\n## Round 1 — Sol · tokens: in 100 · out 10\n\n' >"$LOG"
printf 'gate — lint: OK · typecheck: OK · tests: 3 passed, 1 added · proof: OK\n' >>"$LOG"

status "gate" demo
assert_rc 0 "testing gate"
assert_file_contains "$OUT" "gate — lint: OK · typecheck: OK · tests: 3 passed, 1 added · proof: OK"
assert_matches "$OUT" '^fase: +gate de testing$'
assert_file_contains "$OUT" "/tandem:review demo"

# The real logs wrap it: the LAST logical block wins and comes out normalized.
printf '\ngate — lint: OK (shellcheck pineado) · typecheck: n/a (bash) · tests: 61 passed, 0\n' >>"$LOG"
printf 'failed (+2 casos nuevos) · proof: OK\n\n' >>"$LOG"
status "gate multilínea" demo
assert_rc 0 "wrapped gate"
assert_file_contains "$OUT" \
  "gate — lint: OK (shellcheck pineado) · typecheck: n/a (bash) · tests: 61 passed, 0 failed (+2 casos nuevos) · proof: OK"
cp "$LOG" "$SANDBOX/demo.log.base"

# =============================================================================
# 6/8. The code-review thread, the token sums, and the second human gate
# =============================================================================
seed_thread review "cr-demo" thr_cr 1
KC="$(tkey "cr-demo")"
printf 'findings\nVERDICT: REQUEST_CHANGES\n' >"$RD/$KC.t1.reply.txt"
printf '{"input_tokens":50,"output_tokens":5}\n' >"$RD/$KC.t1.usage.json"

status "code review ronda 1" demo
assert_rc 0 "code review, round 1"
assert_matches "$OUT" '^fase: +code review$'
assert_file_contains "$OUT" "1 ronda · veredictos: REQUEST_CHANGES"
assert_file_contains "$OUT" "/tandem:review demo (retomar)"

# Round 2 comes back APPROVED — and left no ledger, which is a fact the totals
# must carry as it is, not as a zero-filled guess.
printf '2\n' >"$RD/$KC.turn"
printf 'looks good\nVERDICT: APPROVED\n' >"$RD/$KC.t2.reply.txt"

status "code review" demo
assert_rc 0 "code review"
assert_matches "$OUT" '^fase: +code review$'
assert_file_contains "$OUT" "2 rondas · veredictos: REQUEST_CHANGES, APPROVED"
# 8. Second human gate: APPROVED with no terminal record yet.
assert_file_contains "$OUT" "Step 4"
# Tokens: summed from the ledgers, per phase and for the whole run.
assert_file_contains "$OUT" 'plan in 300 · out 30'
assert_file_contains "$OUT" 'cr in 50 · out 5'
assert_file_contains "$OUT" 'implement n/a (transporte opus)'
assert_file_contains "$OUT" 'total in 350 · out 35'

# =============================================================================
# 6/9. A commit on the branch with NO terminal record: contradictory, never done
# =============================================================================
printf 'work\n' >"$R/impl.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "implementation"
FINAL_SHA="$(git -C "$R" rev-parse HEAD)"

status "commits sin registro" demo
assert_rc 0 "commits with no final record"
assert_matches "$OUT" '^fase: +contradictorio — commits sin registro final$'
assert_file_contains "$OUT" "1 commit(s) sobre el plan"
assert_file_contains "$OUT" "ATENCIÓN"
assert_not_contains "$OUT" "run completo"

# =============================================================================
# 6b. The terminal record arrives: `commit final`
# =============================================================================
printf 'final — commit: %s\n' "$FINAL_SHA" >>"$LOG"
status "registro terminal" demo
assert_rc 0 "verified terminal record"
assert_matches "$OUT" '^fase: +commit final$'
assert_file_contains "$OUT" "run completo"

# =============================================================================
# 10c. A commit AFTER the record: the branch moved past the final gate
# =============================================================================
printf 'late\n' >"$R/late.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "unreviewed work"
status "rama avanzó" demo
assert_rc 0 "branch past the terminal record"
assert_matches "$OUT" '^fase: +contradictorio — rama avanzó tras registro final$'
assert_file_contains "$OUT" "ATENCIÓN"
assert_not_contains "$OUT" "run completo"
git -C "$R" reset --hard "$FINAL_SHA" >/dev/null 2>&1

# =============================================================================
# 10. The legitimate merge deletes the branch — the record survives it
# =============================================================================
git -C "$R" checkout -q "$USER_BRANCH"
git -C "$R" merge --ff-only tandem/demo >/dev/null 2>&1 || fail "ff-merge failed"
git -C "$R" branch -d tandem/demo >/dev/null 2>&1 || fail "branch -d failed"
run_in "$R" git show-ref --verify --quiet refs/heads/tandem/demo
assert_rc 1 "the tandem branch is gone"

status "post-merge" demo
assert_rc 0 "record survives the merge"
assert_matches "$OUT" '^fase: +commit final$'
assert_file_contains "$OUT" "run completo"
assert_file_contains "$OUT" "sin rama tandem/demo"

# =============================================================================
# 10b. A sha that is valid but FOREIGN to the run is never "run completo"
# =============================================================================
SOURCE_HEAD="$(jq -r '.source_head' "$R/.tandem/state/plan-approve/demo.json")"
[ -n "$SOURCE_HEAD" ] || fail "cannot read source_head from the approval record"

cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "$SOURCE_HEAD" >>"$LOG"
status "sha ajeno" demo
assert_rc 0 "foreign sha"
assert_matches "$OUT" '^fase: +commit final \(no verificado\)$'
assert_file_contains "$OUT" "verificar a mano"
assert_not_contains "$OUT" "run completo"

cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "0000000000000000000000000000000000000000" >>"$LOG"
status "sha inexistente" demo
assert_rc 0 "unknown sha"
assert_matches "$OUT" '^fase: +commit final \(no verificado\)$'
assert_not_contains "$OUT" "run completo"

# The PLAN COMMIT itself is not the end of a run: it is an ancestor of itself,
# so anything less than a STRICT descendant would certify an approval with no
# implementation behind it as a finished run.
PLAN_COMMIT_FULL="$(jq -r '.plan_commit' "$R/.tandem/state/plan-approve/demo.json")"
[ -n "$PLAN_COMMIT_FULL" ] || fail "cannot read plan_commit from the approval record"
cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "$PLAN_COMMIT_FULL" >>"$LOG"
status "registro igual al plan commit" demo
assert_rc 0 "terminal record equal to the plan commit"
assert_matches "$OUT" '^fase: +commit final \(no verificado\)$'
assert_not_contains "$OUT" "run completo"

# A line that only STARTS like the record is not one: an abbreviated sha, or a
# full sha with prose after it, must not be read as the run's terminal record.
cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s (merged into main)\n' "$FINAL_SHA" >>"$LOG"
status "registro con basura detrás" demo
assert_rc 0 "terminal record with trailing prose"
assert_not_contains "$OUT" "commit final"
assert_not_contains "$OUT" "run completo"
assert_matches "$OUT" '^fase: +code review$'

cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "${FINAL_SHA:0:7}" >>"$LOG"
status "registro con sha corto" demo
assert_rc 0 "terminal record with an abbreviated sha"
assert_not_contains "$OUT" "commit final"
assert_matches "$OUT" '^fase: +code review$'

# …and without git there is nothing to verify it against, so it degrades the
# same way instead of blessing a merge nobody checked.
cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "$FINAL_SHA" >>"$LOG"
MINBIN="$(make_minbin)"
rm -f "$MINBIN/git"
NOGIT="$SANDBOX/bin:$MINBIN"
# Probed in a FRESH shell: this one has already run git, and bash's command
# hash would answer from its cache however PATH is set.
if env PATH="$NOGIT" bash -c 'command -v git' >/dev/null 2>&1; then
  fail "git is still reachable on the git-free PATH"
fi
STATUS_PATH="$NOGIT"
status "sin git" demo
STATUS_PATH=""
assert_rc 0 "terminal record without git"
assert_matches "$OUT" '^fase: +commit final \(no verificado\)$'
assert_not_contains "$OUT" "run completo"
# The approval degrades with it: without git the four facts plan-approve
# re-checks cannot be produced, so the record is reported UNVERIFIED and
# "aprobado: commit" — the proven state — never appears.
assert_not_contains "$OUT" "aprobado: commit"
assert_file_contains "$OUT" "SIN VERIFICAR (sin git)"

# Back to the verified record for the remaining cases.
cp "$SANDBOX/demo.log.base" "$LOG"
printf 'final — commit: %s\n' "$FINAL_SHA" >>"$LOG"

# =============================================================================
# Dual root: the session stands in a linked worktree, the state does not
# =============================================================================
# A FOREIGN run's state inside the worktree's own `.tandem/` must not mask the
# slug that lives under the main checkout: the root is picked by evidence OF
# THAT SLUG, never by "the first .tandem I found".
D="$SANDBOX/dual"
make_repo "$D"
printf 'seed\n' >"$D/f.txt"
commit_all "$D" seed
git -C "$D" worktree add "$D/wt" -b tandem/dual >/dev/null 2>&1 \
  || fail "cannot create the linked worktree"
mkdir -p "$D/.tandem/log" "$D/wt/.tandem/log"
printf '# log dual\n\ngate — lint: OK · main checkout\n' >"$D/.tandem/log/dual.md"
printf '# log ajeno\n\ngate — lint: OK · worktree\n' >"$D/wt/.tandem/log/otro.md"

status_in "$D" "$D/wt" "sesión en worktree" dual
assert_rc 0 "session inside a linked worktree"
assert_file_contains "$OUT" "gate — lint: OK · main checkout"
assert_not_contains "$OUT" "gate — lint: OK · worktree"
assert_matches "$OUT" '^fase: +gate de testing$'

# =============================================================================
# The `sol` transport: the attempt is a THREAD, and its ledgers do get summed
# =============================================================================
S="$SANDBOX/soltrans"
make_repo "$S"
printf 'seed\n' >"$S/f.txt"
commit_all "$S" seed
mkdir -p "$S/docs/plans" "$S/.tandem/state/implement"
printf '# Plan: solrun\n' >"$S/docs/plans/solrun.plan.md"
SKEY="$(tkey "docs/plans/solrun.plan.md")"
printf 'thr_impl\n' >"$S/.tandem/state/implement/$SKEY.thread"
printf '1\n' >"$S/.tandem/state/implement/$SKEY.turn"
printf 'done\nIMPLEMENTATION_COMPLETE\n' >"$S/.tandem/state/implement/$SKEY.t1.reply.txt"
printf '{"input_tokens":70,"output_tokens":7}\n' >"$S/.tandem/state/implement/$SKEY.t1.usage.json"

status_in "$S" "$S" "transporte sol" solrun
assert_rc 0 "sol transport"
assert_matches "$OUT" '^implement: +sol · t1 · IMPLEMENTATION_COMPLETE$'
assert_file_contains "$OUT" 'implement in 70 · out 7'
assert_file_contains "$OUT" 'total in 70 · out 7'
assert_matches "$OUT" '^fase: +implementación$'
assert_file_contains "$OUT" "gate de testing (tandem:implement paso 4)"

# =============================================================================
# The other two modes go through the same read-only proof
# =============================================================================
status "listado"
assert_rc 0 "list mode"
assert_file_contains "$OUT" "demo — commit final"

status "slug inexistente" no-such-run
assert_rc 2 "unknown slug"
assert_file_contains "$ERR" "no hay ni rastro"

# =============================================================================
# codex was never invoked, in any mode
# =============================================================================
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
