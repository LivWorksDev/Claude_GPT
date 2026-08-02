#!/usr/bin/env bash
# One slug, several state roots. A run executed in a linked worktree keeps its
# thread state where it ran while the rest of the evidence lives under the main
# checkout: the split is DESIGNED, not an accident, so answering from the first
# root that carries anything lets a stale copy mask the authoritative run —
# wrong `fase:`, wrong `next:`. This case owns the reconciliation:
#
#   - the most advanced PHASE wins, whatever the candidate order says;
#   - at the same phase, an explicit REVISION ORDER decides (later turn, then a
#     completed reply, then Opus rounds and terminality), never priority;
#   - only VALIDATED facts are ever compared: corrupt state keeps its existing
#     degradation and can neither win nor manufacture a contradiction;
#   - divergent IDENTITY facts (thread ids, approval commit, terminal record,
#     the immutable Opus lineage) are split brain: exit 2, empty stdout, both
#     roots on stderr and NO next step at all.
#
# Two contracts ride along on every invocation, exactly as in status-phases:
# codex is never called, and the report is strictly read-only (both directories
# are snapshotted byte for byte around each run).
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

ST="$SCRIPTS/tandem-status.sh"

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

# status_in <cwd> <project-dir> <label> [args…] — one invocation, wrapped in the
# read-only proof. BOTH directories are snapshotted: the shell's working
# repository and the project whose state is read need not be the same, and in
# this case they deliberately never are.
status_in() {
  local cwd="$1" proj="$2" label="$3"
  shift 3
  ro_snap "$cwd" "$SANDBOX/ro.a.before"
  ro_snap "$proj" "$SANDBOX/ro.b.before"
  # The derived MAIN checkout is analyzed by the resolver even when neither
  # argument names it: it is a subject of this proof, not a bystander.
  if [ -n "${MAIN:-}" ] && [ -d "${MAIN:-}" ]; then
    ro_snap "$MAIN" "$SANDBOX/ro.c.before"
  else
    : >"$SANDBOX/ro.c.before"
  fi
  run_in "$cwd" env CLAUDE_PROJECT_DIR="$proj" bash "$ST" "$@"
  ro_snap "$cwd" "$SANDBOX/ro.a.after"
  ro_snap "$proj" "$SANDBOX/ro.b.after"
  if [ -n "${MAIN:-}" ] && [ -d "${MAIN:-}" ]; then
    ro_snap "$MAIN" "$SANDBOX/ro.c.after"
  else
    : >"$SANDBOX/ro.c.after"
  fi
  if ! cmp -s "$SANDBOX/ro.a.before" "$SANDBOX/ro.a.after" \
    || ! cmp -s "$SANDBOX/ro.b.before" "$SANDBOX/ro.b.after" \
    || ! cmp -s "$SANDBOX/ro.c.before" "$SANDBOX/ro.c.after"; then
    diff "$SANDBOX/ro.a.before" "$SANDBOX/ro.a.after" >&2 2>/dev/null || true
    diff "$SANDBOX/ro.b.before" "$SANDBOX/ro.b.after" >&2 2>/dev/null || true
    diff "$SANDBOX/ro.c.before" "$SANDBOX/ro.c.after" >&2 2>/dev/null || true
    fail "status ($label) modified the repository — it must be strictly read-only"
  fi
  return 0
}

# assert_quiet [label] — stderr belongs to exit 2/64 alone, and no comparison
# here may leak an arithmetic diagnostic into a report that exited 0.
assert_quiet() {
  assert_not_contains "$ERR" "integer expression"
  assert_not_contains "$ERR" "tandem-status.sh:"
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "${1:-nothing on stderr}"
}

# dual <name> — a fresh main checkout with a linked worktree under it, so no
# case inherits another's state. Sets MAIN and WT, both PHYSICAL paths ($SANDBOX
# is already resolved by the runner). The worktree's branch is deliberately NOT
# `tandem/*`: it must not become a run of its own in list mode.
dual() {
  local d="$SANDBOX/$1"
  make_repo "$d"
  printf 'seed\n' >"$d/f.txt"
  commit_all "$d" seed
  git -C "$d" worktree add "$d/wt" -b "side-$1" >/dev/null 2>&1 \
    || fail "cannot create the linked worktree for $1"
  MAIN="$d"
  WT="$d/wt"
  return 0
}

# log_at <root> <slug> <gate-note> — a log whose gate line names its own root.
log_at() {
  mkdir -p "$1/.tandem/log"
  printf '# tandem log — %s\n\ngate — lint: OK · %s\n' "$2" "$3" >"$1/.tandem/log/$2.md"
  return 0
}

# thread_at <root> <role> <key> <id> <turn>
thread_at() {
  local dir="$1/.tandem/state/$2"
  mkdir -p "$dir"
  printf '%s\n' "$4" >"$dir/$3.thread"
  printf '%s\n' "$5" >"$dir/$3.turn"
  return 0
}

# reply_at <root> <role> <key> <turn> <verdict>
reply_at() {
  printf 'findings\nVERDICT: %s\n' "$5" >"$1/.tandem/state/$2/$3.t$4.reply.txt"
  return 0
}

# opus_at <root> <slug> <agent-id> <plan-hash> <branch> <status> <sentinel> <rounds>
# The durable Opus attempt state, written with the shapes the implement contract
# documents. `continuation_rounds` and `last_sentinel` are injected as raw JSON
# so a case can write a NEGATIVE, fractional or unknown value on purpose.
opus_at() {
  local dir="$1/.tandem/state/implement-claude"
  mkdir -p "$dir"
  jq -n --arg id "$3" --arg ph "$4" --arg br "$5" --arg st "$6" \
    --argjson sent "$7" --argjson rounds "$8" \
    '{agent:{name:"impl", id:$id}, agent_type:"tandem:implementer",
      task_id:"task-1", status:$st, continuation_rounds:$rounds,
      last_sentinel:$sent, last_report:null, worktree:null,
      plan_path:"docs/plans/x.plan.md", plan_hash:$ph, branch:$br}' >"$dir/$2.json"
  return 0
}

# runs_named <slug> — how many lines of the listing belong to that run.
runs_named() {
  LC_ALL=C awk -v s="$1" '$1 == s { n++ } END { print n + 0 }' "$OUT"
}

# =============================================================================
# A. The backlog case: the session stands in the worktree, the main checkout is
#    one rung further. The main checkout's report wins; the stale root shows up
#    ONLY as an annotation. Against the pre-M17 code this case FAILS — the
#    worktree, being first, used to answer for the whole run.
# =============================================================================
dual a
log_at "$WT" demo "worktree"
log_at "$MAIN" demo "main checkout"
KC="$(tkey "cr-demo")"
thread_at "$MAIN" review "$KC" thr_cr 1
reply_at "$MAIN" review "$KC" 1 REQUEST_CHANGES

status_in "$WT" "$WT" "A: el principal manda" demo
assert_rc 0 "the more advanced root answers"
assert_matches "$OUT" '^fase: +code review$'
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "$MAIN · evidencia también en $WT (fase: gate de testing)"
assert_file_contains "$OUT" "gate — lint: OK · main checkout"
assert_not_contains "$OUT" "gate — lint: OK · worktree"
assert_file_contains "$OUT" "1 ronda · veredictos: REQUEST_CHANGES"
assert_quiet "A stderr"

# =============================================================================
# B. The inverse: the PRIORITY root is the advanced one. It wins too — what
#    decides is the rung, not the candidate order.
# =============================================================================
dual b
log_at "$MAIN" demo "main checkout"
log_at "$WT" demo "worktree"
thread_at "$WT" review "$KC" thr_cr 1
reply_at "$WT" review "$KC" 1 APPROVED

status_in "$WT" "$WT" "B: la prioritaria manda cuando va por delante" demo
assert_rc 0 "the priority root wins on its own merits"
assert_matches "$OUT" '^fase: +code review$'
assert_matches "$OUT" "^raíz: +$WT "
assert_file_contains "$OUT" "evidencia también en $MAIN (fase: gate de testing)"
assert_file_contains "$OUT" "gate — lint: OK · worktree"
assert_quiet "B stderr"

# =============================================================================
# C. Contradiction: two thread ids for the SAME key. An honest run cannot have
#    those, so there is no report to emit at all.
# =============================================================================
dual c
KP="$(tkey "docs/plans/demo.plan.md")"
thread_at "$WT" review "$KP" thr_worktree 1
thread_at "$MAIN" review "$KP" thr_main 1

status_in "$WT" "$WT" "C: hilos distintos para la misma clave" demo
assert_rc 2 "contradictory roots"
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "nothing on stdout for a contradiction"
assert_file_contains "$ERR" 'evidencia contradictoria para "demo" entre raíces de estado'
assert_file_contains "$ERR" "  - $WT — fase: plan en revisión"
assert_file_contains "$ERR" "  - $MAIN — fase: plan en revisión"
assert_file_contains "$ERR" "thread de plan-review distinto entre raíces"
assert_file_contains "$ERR" "resolver a mano — sin paso siguiente automático"
# A contradiction is never a step forward: no `next:` line, no skill to invoke.
assert_not_contains "$ERR" "next:"
assert_not_contains "$ERR" "/tandem:"
assert_not_contains "$OUT" "next:"
assert_not_contains "$OUT" "/tandem:"

# =============================================================================
# D. The same state twice, byte for byte: no drama, no contradiction — the
#    priority root answers and the other one is visible as an annotation.
# =============================================================================
dual d
log_at "$MAIN" demo "copia"
log_at "$WT" demo "copia"

status_in "$WT" "$WT" "D: duplicado idéntico" demo
assert_rc 0 "identical duplicate"
assert_matches "$OUT" '^fase: +gate de testing$'
assert_matches "$OUT" "^raíz: +$WT "
assert_file_contains "$OUT" "evidencia también en $MAIN (fase: gate de testing)"
assert_not_contains "$OUT" "contradictorio"
assert_quiet "D stderr"

# =============================================================================
# E. A symlink to the checkout is not a second root: the dedupe is PHYSICAL, so
#    there is one root, one story and no annotation at all.
# =============================================================================
E="$SANDBOX/e"
mkdir -p "$E"
make_repo "$E/real"
printf 'seed\n' >"$E/real/f.txt"
commit_all "$E/real" seed
log_at "$E/real" demo "raíz única"
ln -s "$E/real" "$E/link" || fail "cannot create the symlink"

status_in "$E/link" "$E/real" "E: symlink a la misma raíz" demo
assert_rc 0 "symlinked candidate"
assert_matches "$OUT" "^raíz: +$E/real$"
assert_not_contains "$OUT" "evidencia también en"
assert_not_contains "$OUT" "$E/link"
assert_quiet "E stderr"

# =============================================================================
# F. List mode is panoramic: a contradictory slug says so, ONCE, and the exit
#    code stays 0 — the detail is what slug mode is for.
# =============================================================================
dual f
log_at "$MAIN" fcontra "principal"
log_at "$WT" fcontra "worktree"
KF="$(tkey "docs/plans/fcontra.plan.md")"
thread_at "$WT" review "$KF" thr_worktree 1
thread_at "$MAIN" review "$KF" thr_main 1
log_at "$MAIN" fsano "principal"

status_in "$WT" "$WT" "F: listado con un slug contradictorio"
assert_rc 0 "list mode with a contradictory slug"
assert_matches "$OUT" '^fcontra — contradictorio entre raíces$'
assert_eq "1" "$(runs_named fcontra)" "the contradictory run is listed once"
assert_matches "$OUT" '^fsano — gate de testing$'
assert_quiet "F stderr"

# =============================================================================
# G. The SAME thread with different progress: two copies of one run share a
#    phase, so priority would serve the stale verdict. The later turn wins, and
#    with it the `next:` of the NEW verdict.
# =============================================================================
dual g
KG="$(tkey "docs/plans/gdemo.plan.md")"
thread_at "$WT" review "$KG" thr_shared 1
reply_at "$WT" review "$KG" 1 REVISE
thread_at "$MAIN" review "$KG" thr_shared 2
reply_at "$MAIN" review "$KG" 1 REVISE
reply_at "$MAIN" review "$KG" 2 APPROVED

status_in "$WT" "$WT" "G: mismo hilo, turno más nuevo" gdemo
assert_rc 0 "same thread, newer turn"
assert_matches "$OUT" '^fase: +plan en revisión$'
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "2 rondas · veredictos: REVISE, APPROVED"
assert_file_contains "$OUT" "plan-approve.sh"
assert_quiet "G stderr"

# G2. Same thread, SAME turn: the completed reply beats the absent one.
dual g2
thread_at "$WT" review "$KG" thr_shared 1
thread_at "$MAIN" review "$KG" thr_shared 1
reply_at "$MAIN" review "$KG" 1 APPROVED

status_in "$WT" "$WT" "G2: respuesta completada contra ausente" gdemo
assert_rc 0 "completed reply beats an absent one"
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "1 ronda · veredictos: APPROVED"
assert_file_contains "$OUT" "plan-approve.sh"
assert_quiet "G2 stderr"

# G3. Same thread, same turn, TWO completed verdicts that disagree: there is no
#     order between them, and inventing one by priority is the bug being fixed.
dual g3
thread_at "$WT" review "$KG" thr_shared 1
reply_at "$WT" review "$KG" 1 REVISE
thread_at "$MAIN" review "$KG" thr_shared 1
reply_at "$MAIN" review "$KG" 1 APPROVED

status_in "$WT" "$WT" "G3: dos veredictos del mismo turno" gdemo
assert_rc 2 "two completed verdicts for one turn"
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "nothing on stdout"
assert_file_contains "$ERR" "veredictos distintos en el mismo turno del hilo de plan-review"
assert_file_contains "$ERR" "resolver a mano — sin paso siguiente automático"
assert_not_contains "$ERR" "/tandem:"

# =============================================================================
# H. The durable Opus attempt: same lineage, different progress. Rounds come
#    FIRST — a running turn of round 1 is newer than a terminal round 0 — and
#    the two snapshots carry DIFFERENT agent ids on purpose: a recovery renews
#    that id without touching the attempt, so it is not identity.
# =============================================================================
dual h
mkdir -p "$MAIN/docs/plans"
printf '# Plan: hdemo\n' >"$MAIN/docs/plans/hdemo.plan.md"
commit_all "$MAIN" "plan hdemo"
PH="$(git -C "$MAIN" rev-parse HEAD:docs/plans/hdemo.plan.md)"
[ -n "$PH" ] || fail "cannot resolve the plan blob"
opus_at "$WT" hdemo agent-old "$PH" tandem/hdemo terminal '"IMPLEMENTATION_PARTIAL"' 0
opus_at "$MAIN" hdemo agent-new "$PH" tandem/hdemo running '"IMPLEMENTATION_PARTIAL"' 1

status_in "$WT" "$WT" "H: la ronda 1 es más nueva que una terminal de ronda 0" hdemo
assert_rc 0 "continuation_rounds decides first"
assert_matches "$OUT" '^fase: +implementación$'
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "opus · running"
assert_file_contains "$OUT" "continuaciones: 1"
assert_file_contains "$OUT" "guard de liveness"
assert_quiet "H stderr"

# H2. Same round: the finished turn beats the one still running.
dual h2
mkdir -p "$MAIN/docs/plans"
printf '# Plan: hdemo\n' >"$MAIN/docs/plans/hdemo.plan.md"
commit_all "$MAIN" "plan hdemo"
PH2="$(git -C "$MAIN" rev-parse HEAD:docs/plans/hdemo.plan.md)"
opus_at "$WT" hdemo agent-a "$PH2" tandem/hdemo running '"IMPLEMENTATION_PARTIAL"' 1
opus_at "$MAIN" hdemo agent-b "$PH2" tandem/hdemo terminal '"IMPLEMENTATION_COMPLETE"' 1

status_in "$WT" "$WT" "H2: terminal gana a running en la misma ronda" hdemo
assert_rc 0 "terminal beats running at the same round"
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "opus · terminal · IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" "gate de testing (tandem:implement paso 4)"
assert_quiet "H2 stderr"

# H3. The same terminal revision with two different outcomes is not an order.
dual h3
mkdir -p "$MAIN/docs/plans"
printf '# Plan: hdemo\n' >"$MAIN/docs/plans/hdemo.plan.md"
commit_all "$MAIN" "plan hdemo"
PH3="$(git -C "$MAIN" rev-parse HEAD:docs/plans/hdemo.plan.md)"
opus_at "$WT" hdemo agent-a "$PH3" tandem/hdemo terminal '"IMPLEMENTATION_COMPLETE"' 2
opus_at "$MAIN" hdemo agent-b "$PH3" tandem/hdemo terminal '"IMPLEMENTATION_PARTIAL"' 2

status_in "$WT" "$WT" "H3: sentinels distintos en la misma revisión terminal" hdemo
assert_rc 2 "two terminal outcomes for one revision"
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "nothing on stdout"
assert_file_contains "$ERR" "sentinel distinto en la misma revisión terminal del intento opus"
assert_not_contains "$ERR" "/tandem:"

# H4. A progress tuple that is not valid is NOT comparable: it can neither win
#     by priority nor force a split brain, and nothing about it may reach
#     arithmetic. The valid IMPLEMENTATION_COMPLETE of the non-priority root
#     dominates, and stderr stays empty.
dual h4
mkdir -p "$MAIN/docs/plans"
printf '# Plan: hdemo\n' >"$MAIN/docs/plans/hdemo.plan.md"
commit_all "$MAIN" "plan hdemo"
PH4="$(git -C "$MAIN" rev-parse HEAD:docs/plans/hdemo.plan.md)"
opus_at "$WT" hdemo agent-a "$PH4" tandem/hdemo desconocido '"NONSENSE"' -1
opus_at "$MAIN" hdemo agent-b "$PH4" tandem/hdemo terminal '"IMPLEMENTATION_COMPLETE"' 0

status_in "$WT" "$WT" "H4: progreso inválido en la prioritaria" hdemo
assert_rc 0 "invalid progress never wins"
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "opus · terminal · IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" "gate de testing (tandem:implement paso 4)"
assert_quiet "H4 stderr"

# …a fractional round counter is garbage too, and garbage is never arithmetic.
opus_at "$WT" hdemo agent-a "$PH4" tandem/hdemo running '"IMPLEMENTATION_PARTIAL"' 0.5
status_in "$WT" "$WT" "H4: rondas fraccionarias" hdemo
assert_rc 0 "fractional rounds never win"
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "opus · terminal · IMPLEMENTATION_COMPLETE"
assert_quiet "H4 fractional stderr"

# …and when BOTH tuples are garbage there is nothing to order: priority decides.
opus_at "$MAIN" hdemo agent-b "$PH4" tandem/hdemo terminal '"OTRA_COSA"' 3
status_in "$WT" "$WT" "H4: ambas inválidas" hdemo
assert_rc 0 "both tuples invalid"
assert_matches "$OUT" "^raíz: +$WT "
assert_quiet "H4 both-invalid stderr"

# =============================================================================
# I. The Opus lineage. `plan_hash` and `branch` ARE the attempt's identity, so
#    two different ones are a split brain; `agent.id` is not, because a
#    legitimate recovery renews it without resetting the attempt.
# =============================================================================
dual i
mkdir -p "$MAIN/docs/plans"
printf '# Plan: idemo\n' >"$MAIN/docs/plans/idemo.plan.md"
commit_all "$MAIN" "plan idemo"
PI="$(git -C "$MAIN" rev-parse HEAD:docs/plans/idemo.plan.md)"
PI2="$(git -C "$MAIN" rev-parse HEAD:f.txt)"
if [ -z "$PI2" ] || [ "$PI" = "$PI2" ]; then
  fail "need two distinct blobs in the fixture"
fi
opus_at "$WT" idemo agent-a "$PI" tandem/idemo terminal '"IMPLEMENTATION_PARTIAL"' 0
opus_at "$MAIN" idemo agent-b "$PI2" tandem/idemo terminal '"IMPLEMENTATION_PARTIAL"' 0

status_in "$WT" "$WT" "I: plan_hash distinto entre raíces" idemo
assert_rc 2 "two lineages for one attempt"
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "nothing on stdout"
assert_file_contains "$ERR" "plan_hash del intento opus distinto entre raíces"
assert_not_contains "$ERR" "/tandem:"

# The same lineage with a DIFFERENT agent id is the shape of a recovery, not of
# a contradiction.
opus_at "$MAIN" idemo agent-recovered "$PI" tandem/idemo terminal '"IMPLEMENTATION_PARTIAL"' 0
status_in "$WT" "$WT" "I: agent.id distinto, mismo linaje" idemo
assert_rc 0 "a renewed agent id is not a contradiction"
assert_matches "$OUT" '^fase: +implementación$'
assert_not_contains "$ERR" "contradictoria"
assert_quiet "I recovery stderr"

# Control: a CORRUPT lineage in the priority root against a valid one in the
# other. The valid lineage dominates BEFORE any progress is compared — note the
# corrupt snapshot carries the "better" progress on purpose, so only the
# dominance rule can produce this answer.
opus_at "$WT" idemo agent-a "no-es-un-blob" tandem/idemo terminal '"IMPLEMENTATION_PARTIAL"' 5
opus_at "$MAIN" idemo agent-b "$PI" tandem/idemo terminal '"IMPLEMENTATION_COMPLETE"' 0
status_in "$WT" "$WT" "I: linaje corrupto contra linaje válido" idemo
assert_rc 0 "a corrupt lineage never wins by priority"
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "opus · terminal · IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" "gate de testing (tandem:implement paso 4)"
assert_quiet "I dominance stderr"

# …and with BOTH lineages corrupt there is nothing to dominate: priority again.
# The corrupt PRIORITY copy deliberately carries the WORSE progress: a buggy
# progress comparison across unidentified attempts would pick the other root,
# so only candidate priority can produce this answer. And a lineage PRESENT but
# invalid renders as corrupt — its sentinel must not drive a next step.
opus_at "$WT" idemo agent-a "no-es-un-blob" tandem/idemo terminal '"IMPLEMENTATION_PARTIAL"' 0
opus_at "$MAIN" idemo agent-b "tampoco-un-blob" tandem/idemo terminal '"IMPLEMENTATION_COMPLETE"' 5
status_in "$WT" "$WT" "I: ambos linajes corruptos" idemo
assert_rc 0 "both lineages corrupt"
assert_matches "$OUT" "^raíz: +$WT "
assert_file_contains "$OUT" "opus · desconocido (estado corrupto)"
assert_not_contains "$OUT" "IMPLEMENTATION_PARTIAL"
assert_quiet "I both-corrupt stderr"

# =============================================================================
# a HALF-present or malformed lineage is corrupt, never "legacy absent"
# =============================================================================
# Presence is asked with has(): a null plan_hash, or a lineage with only one
# key, is not the shape M11 displays — its sentinel belongs to an attempt this
# tool cannot identify and must not recommend the testing gate. The control
# with ALL keys absent still displays: that IS the anchored legacy shape.
mkdir -p "$MAIN/.tandem/state/implement-claude"
jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_COMPLETE",
        continuation_rounds:0, plan_hash:null}' \
  >"$MAIN/.tandem/state/implement-claude/pdemo.json"
status_in "$MAIN" "$MAIN" "P: plan_hash null" pdemo
assert_rc 0 "a null lineage key is corrupt, not absent"
assert_file_contains "$OUT" "opus · desconocido (estado corrupto)"
assert_not_contains "$OUT" "tandem:implement paso 4"
assert_quiet "P null-lineage stderr"

jq -n --arg br "tandem/pdemo" \
  '{status:"terminal", last_sentinel:"IMPLEMENTATION_COMPLETE",
    continuation_rounds:0, branch:$br}' \
  >"$MAIN/.tandem/state/implement-claude/pdemo.json"
status_in "$MAIN" "$MAIN" "P: media lineage" pdemo
assert_rc 0 "half a lineage is corrupt, not absent"
assert_file_contains "$OUT" "opus · desconocido (estado corrupto)"
assert_not_contains "$OUT" "tandem:implement paso 4"
assert_quiet "P half-lineage stderr"

jq -n '{status:"terminal", last_sentinel:"IMPLEMENTATION_COMPLETE",
        continuation_rounds:0}' \
  >"$MAIN/.tandem/state/implement-claude/pdemo.json"
status_in "$MAIN" "$MAIN" "P: legacy absent" pdemo
assert_rc 0 "the all-absent legacy shape still displays"
assert_file_contains "$OUT" "opus · terminal · IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" "tandem:implement paso 4"
assert_quiet "P legacy stderr"
rm -f "$MAIN/.tandem/state/implement-claude/pdemo.json"

# =============================================================================
# J. A VALID approval record in one root and a CORRUPT one — with a different
#    raw sha — in the other is not a split brain: the corrupt record was never
#    validated, so it carries no comparable fact. It degrades exactly as always
#    and the sound record wins the ladder.
# =============================================================================
dual j
mkdir -p "$MAIN/docs/plans"
printf '# Plan: jdemo\n' >"$MAIN/docs/plans/jdemo.plan.md"
run_in "$MAIN" env CLAUDE_PROJECT_DIR="$MAIN" bash "$SCRIPTS/plan-approve.sh" jdemo
assert_rc 0 "real plan approval"
J_COMMIT="$(git -C "$MAIN" rev-parse refs/heads/tandem/jdemo)"
mkdir -p "$WT/.tandem/state/plan-approve"
printf '{\n  "branch": "tandem/jdemo",\n  "plan_commit": "%s",\n  "source_head": "%s",\n  "mode": "in-place"\n}\n' \
  "1111111111111111111111111111111111111111" "2222222222222222222222222222222222222222" \
  >"$WT/.tandem/state/plan-approve/jdemo.json"

status_in "$WT" "$WT" "J: registro corrupto contra registro válido" jdemo
assert_rc 0 "a corrupt approval record is not a contradiction"
assert_matches "$OUT" '^fase: +plan aprobado$'
assert_matches "$OUT" "^raíz: +$MAIN "
assert_file_contains "$OUT" "aprobado: commit ${J_COMMIT:0:7}"
assert_file_contains "$OUT" "/tandem:implement jdemo"
# The loser's degradation stays with the loser: no field of the report may come
# from a root that did not win.
assert_not_contains "$OUT" "registro de aprobación corrupto"
assert_quiet "J stderr"

# =============================================================================
# K. Evidence that is ONLY a thread, in the non-priority root. The keys are
#    computed before any discovery, or this root would look empty and the
#    report would be built from the one that knows nothing.
# =============================================================================
dual k
KK="$(tkey "docs/plans/kdemo.plan.md")"
thread_at "$MAIN" review "$KK" thr_k 1
reply_at "$MAIN" review "$KK" 1 REVISE

status_in "$WT" "$WT" "K: evidencia solo de hilo" kdemo
assert_rc 0 "thread-only evidence is found"
assert_matches "$OUT" '^fase: +plan en revisión$'
assert_matches "$OUT" "^raíz: +$MAIN$"
assert_file_contains "$OUT" "1 ronda · veredictos: REVISE"
assert_quiet "K stderr"

# =============================================================================
# L. List mode, several slugs: the keys of the PREVIOUS slug must never decide
#    the roots of the next one. `zzz` is known through its branch and its only
#    state is a thread in the non-priority root.
# =============================================================================
dual l
log_at "$WT" aaa "worktree"
git -C "$MAIN" branch tandem/zzz >/dev/null 2>&1 || fail "cannot create tandem/zzz"
KZ="$(tkey "docs/plans/zzz.plan.md")"
thread_at "$MAIN" review "$KZ" thr_z 1
reply_at "$MAIN" review "$KZ" 1 REVISE

status_in "$WT" "$WT" "L: listado multi-slug con claves por slug"
assert_rc 0 "list mode recomputes the keys per slug"
assert_matches "$OUT" '^aaa — gate de testing$'
assert_matches "$OUT" '^zzz — plan en revisión$'
assert_quiet "L stderr"

# =============================================================================
# M. No `.tandem` anywhere and the plan in ANOTHER candidate, reached through a
#    symlink: the row names the physical owner and says what it does not carry.
# =============================================================================
M="$SANDBOX/m"
mkdir -p "$M/other"
make_repo "$M/owner"
printf 'seed\n' >"$M/owner/f.txt"
commit_all "$M/owner" seed
mkdir -p "$M/owner/docs/plans"
printf '# Plan: mdemo\n' >"$M/owner/docs/plans/mdemo.plan.md"
ln -s "$M/owner" "$M/link" || fail "cannot create the symlink"

status_in "$M/link" "$M/other" "M: solo el plan, en otra candidata" mdemo
assert_rc 0 "the plan's owner is named"
assert_matches "$OUT" "^raíz: +$M/owner \\(sin estado \\.tandem\\)$"
assert_matches "$OUT" '^fase: +plan \(borrador\)$'
assert_not_contains "$OUT" "$M/link"
assert_quiet "M stderr"

# =============================================================================
# N. The branch lives ONLY in a non-default candidate's repository. The root
#    that OWNS it answers — analyzing the default root would report "no trace"
#    of a run whose branch is right there.
# =============================================================================
N="$SANDBOX/n"
make_repo "$N/def"
printf 'seed\n' >"$N/def/f.txt"
commit_all "$N/def" seed
make_repo "$N/owner"
printf 'seed\n' >"$N/owner/f.txt"
commit_all "$N/owner" seed
git -C "$N/owner" branch tandem/ndemo >/dev/null 2>&1 || fail "cannot create tandem/ndemo"

status_in "$N/owner" "$N/def" "N: la rama vive en otra candidata" ndemo
assert_rc 0 "the branch's owner is analyzed"
assert_matches "$OUT" "^raíz: +$N/owner \\(sin estado \\.tandem\\)$"
assert_matches "$OUT" '^rama: +tandem/ndemo · tip '
assert_not_contains "$OUT" "sin rama"
assert_quiet "N stderr"

# …and when the plan is in one candidate and the branch in another, the row
# says both instead of naming an owner of neither.
mkdir -p "$N/def/docs/plans"
printf '# Plan: ndemo\n' >"$N/def/docs/plans/ndemo.plan.md"
status_in "$N/owner" "$N/def" "N: plan aquí, rama allá" ndemo
assert_rc 0 "plan and branch in different candidates"
assert_matches "$OUT" "^raíz: +$N/def \\(sin estado \\.tandem\\) · rama en $N/owner$"
assert_quiet "N split stderr"

# =============================================================================
# The rank ladder: twelve rungs, twelve UNIQUE ranks, 11 down to 0, and every
# rank assigned in the SAME branch as its phase. A parallel string→number map
# could drift from the printed ladder, so the pairing is asserted at the source:
# each `FASE=` line must be followed IMMEDIATELY by its `FASE_RANK=`, and each
# adjacent pair of rungs must differ by exactly one, in the ladder's own order.
# (The behavioural half of this — a higher rung beating a lower one across two
# roots, and the M16 rung included in the count — is cases A and B; the
# `plan aprobado`/`aprobación no verificada` pair cannot be exercised
# behaviourally at all, since one rung needs git and the other its absence.)
# =============================================================================
LADDER="$SANDBOX/ladder.actual"
LC_ALL=C awk '
  /^[[:space:]]*FASE="/ {
    if (pend != "") { print "MISSING_RANK"; exit 1 }
    ph = $0
    sub(/^[[:space:]]*FASE="/, "", ph)
    sub(/"[[:space:]]*$/, "", ph)
    pend = ph
    pline = NR
    next
  }
  /^[[:space:]]*FASE_RANK=/ {
    r = $0
    sub(/^[[:space:]]*FASE_RANK=/, "", r)
    sub(/[[:space:]]*$/, "", r)
    if (pend == "") { print "ORPHAN_RANK"; exit 1 }
    if (NR != pline + 1) { print "MISPLACED_RANK"; exit 1 }
    printf "%s\t%s\n", r, pend
    pend = ""
    next
  }
  END { if (pend != "") print "MISSING_RANK" }
' "$ST" >"$LADDER"

assert_not_contains "$LADDER" "MISSING_RANK"
assert_not_contains "$LADDER" "ORPHAN_RANK"
assert_not_contains "$LADDER" "MISPLACED_RANK"

LADDER_WANT="$SANDBOX/ladder.want"
{
  printf '11\tcommit final\n'
  printf '10\tcontradictorio — rama avanzó tras registro final\n'
  printf '9\tcommit final (no verificado)\n'
  printf '8\tcontradictorio — commits sin registro final\n'
  printf '7\tcode review\n'
  printf '6\tgate de testing\n'
  printf '5\timplementación\n'
  printf '4\tplan aprobado\n'
  printf '3\taprobación no verificada\n'
  printf '2\tplan en revisión\n'
  printf '1\tplan (borrador)\n'
  printf '0\tdesconocido\n'
} >"$LADDER_WANT"

if ! cmp -s "$LADDER" "$LADDER_WANT"; then
  diff "$LADDER_WANT" "$LADDER" >&2 2>/dev/null || true
  fail "the phase ladder and its ranks do not match, rung for rung"
fi

# Each ADJACENT pair, explicitly: strictly descending, by exactly one.
PREV=""
while IFS="$(printf '\t')" read -r rank phase; do
  [ -n "$phase" ] || fail "a ladder rung with no phase"
  case "$rank" in '' | *[!0-9]*) fail "rank [$rank] of [$phase] is not a number" ;; esac
  if [ -n "$PREV" ]; then
    [ "$((PREV - rank))" -eq 1 ] \
      || fail "adjacent rungs must differ by exactly one: $PREV then $rank ($phase)"
  fi
  PREV="$rank"
done <"$LADDER"
assert_eq "0" "$PREV" "the last rung is rank 0"
assert_eq "12" "$(wc -l <"$LADDER" | tr -d ' ')" "twelve rungs"

# =============================================================================
# codex was never invoked, in any mode
# =============================================================================
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
