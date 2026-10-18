#!/usr/bin/env bash
# council.sh init / seal / stage / astra / publish — the run's contract (A5).
#
# init draws the letters; seal freezes the brief and proves the leader wrote
# its contribution before the seats were launched; stage composes every prompt
# byte for byte from fixed files and published inputs, under fixed delimiters
# that name no model, with executable attempt caps; astra is the only path to an
# Astra turn and records it by machine (start without a thread, resume with
# one, the role's effort for every substantive turn whatever the caller
# exported, low for a reminder, caps); publish moves only the done turn of the
# CURRENT attempt — never a failed, interrupted or wrong-thread one — after
# checking the wrapper's receipt, waits for a missing seat, never overwrites,
# keeps the provenance in run.json, and audits Astra's commands.
# The concurrency and lifecycle half (A5b) lives in council-lifecycle.test.sh.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
PROMPTS="$REPO_ROOT/skills/council/prompts"
FX="$REPO_ROOT/tests/fixtures/council"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
export CODEX_STUB_SCENARIO=ok
SD="$CLAUDE_PROJECT_DIR/.tandem/state/council"

council() { run bash "$COUNCIL" "$@"; }
stub_n() { if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi; }
last_argv() { printf '%s' "$CODEX_STUB_LOG.argv.$(stub_n)"; }
sha_of() { shasum -a 256 <"$1" | cut -d' ' -f1; }

# setup_run <run-id> — init, deterministic letters (A leader, B Astra, C
# Fable: the moderator never chooses them, a test may), a sealed brief.
setup_run() {
  RID="$1"
  DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
  RD="$SD/runs/$RID"
  RJ="$RD/run.json"
  council init "$RID"
  assert_rc 0 "init $RID"
  jq '.letters = {A: "lider", B: "astra", C: "fable"}' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
  printf '# Brief\n\nObjetivo: medible «con comillas» y `código`\n' >"$DOC/brief.md"
  council seal "$RID" brief
  assert_rc 0 "seal brief $RID"
  G1KEY="$(tkey "council-$RID-g1")"
}

# header <letter> <phase> <next-id> — the bytes stage adds before the inputs.
header() {
  printf '===== TU ASIENTO =====\nLetra: %s\nFase: %s\nSiguiente ID libre de objeción: %s\n' "$1" "$2" "$3"
}
section() {
  # section <label> <file>
  printf '===== %s =====\n' "$1"
  cat "$2"
}
seal_phase() {
  # seal_phase <phase> — the leader's contribution for <phase>, written and
  # sealed: no seat of propose/cross gets a prompt before this.
  printf 'Aportación sellada del líder (%s)\n' "$1" >"$RD/sealed/$1.md"
  council seal "$RID" "$1"
  assert_rc 0 "seal $1 $RID"
}

# =============================================================================
# init
# =============================================================================
council init 2026-10-18-perm
assert_rc 0 "init"
PJ="$SD/runs/2026-10-18-perm/run.json"
assert_json "$PJ" '(.letters | keys) == ["A", "B", "C"] and ([.letters[]] | sort) == ["astra", "fable", "lider"]'
assert_json "$PJ" '.run_id == "2026-10-18-perm" and .mode == "web" and .max_rounds == 4
  and .astra_targets == ["council-2026-10-18-perm-g1"] and .agents == [] and .astra_turns == []
  and .prompts == [] and .captures == [] and .seals == {}'
assert_file_contains "$OUT" "LETTERS: A=$(jq -r .letters.A "$PJ") B=$(jq -r .letters.B "$PJ") C=$(jq -r .letters.C "$PJ")"
[ -d "$CLAUDE_PROJECT_DIR/docs/council/2026-10-18-perm" ] || fail "init did not create DOC_DIR"
assert_eq "*" "$(cat "$CLAUDE_PROJECT_DIR/.tandem/.gitignore")" ".tandem stays out of git"
cp "$PJ" "$SANDBOX/perm.before"
council init 2026-10-18-perm
assert_rc 2 "an existing run"
cmp -s "$SANDBOX/perm.before" "$PJ" || fail "a second init touched the existing run"
for bad in 2026-10-18 26-10-18-x 2026-10-18-Bad "2026-10-18-x y" 2026-10-18--x ../2026-10-18-x \
  2026-10-18-x/y "$(printf '2026-10-18-a\nb')" ""; do
  council init "$bad"
  assert_rc 64 "invalid run id [$bad]"
done
run env TANDEM_COUNCIL_ROUNDS=3 bash "$COUNCIL" init 2026-10-18-off --offline
assert_rc 0 "offline init with three rounds"
assert_json "$SD/runs/2026-10-18-off/run.json" '.mode == "offline" and .max_rounds == 3'
run env TANDEM_COUNCIL_DIR= bash "$COUNCIL" init 2026-10-18-empty-dir
assert_rc 64 "TANDEM_COUNCIL_DIR set but empty"

# =============================================================================
# stage: byte-for-byte composition, caps, inputs
# =============================================================================
setup_run 2026-10-18-stage
# The leader's seal comes BEFORE any seat's prompt: with no prompt there is no
# launch and no answer, so nothing a seat says can reach the leader first.
council stage "$RID" propose B
assert_rc 1 "stage before the leader's seal"
assert_file_contains "$ERR" "seal the leader's propose contribution first"
assert_no_file "$DOC/prompts/propose-B.a1.md"
assert_json "$RJ" '.prompts == []'
seal_phase propose
council stage "$RID" propose B
assert_rc 0 "stage propose B"
P1="$DOC/prompts/propose-B.a1.md"
assert_eq "$P1" "$(cat "$OUT")" "stage prints the path"
{
  cat "$PROMPTS/seat-rules.md" "$PROMPTS/phase-propose.md"
  header B propose B-1
  section BRIEF "$DOC/brief.md"
} >"$SANDBOX/want.propose"
cmp -s "$SANDBOX/want.propose" "$P1" || { diff "$SANDBOX/want.propose" "$P1" >&2; fail "propose prompt composition"; }
# The lines the SCRIPT adds name no model, ever: the letters are anonymous.
LC_ALL=C grep -E '^(===== .* =====|Letra: |Fase: |Siguiente ID libre)' "$P1" >"$SANDBOX/added"
[ -s "$SANDBOX/added" ] || fail "no script-added line found"
if LC_ALL=C grep -Eiq 'astra|fable|opus|claude|gpt|codex|haiku|sonnet|luna|lider|líder' "$SANDBOX/added"; then
  fail "a line added by stage names a model or a seat: $(cat "$SANDBOX/added")"
fi
assert_json "$RJ" '.prompts | length == 1 and .[0].fase == "propose" and .[0].letra == "B" and .[0].intento == 1
  and (.[0].recordatorio | not) and (.[0].historia | not)'
assert_json "$RJ" ".prompts[0].sha256 == \"$(sha_of "$P1")\""
# Once a seat's prompt is staged — even before any launch or capture, which is
# when a Fable seat could already have answered — the leader cannot re-seal.
council seal "$RID" propose
assert_rc 65 "re-sealing propose after a seat's prompt was staged"
assert_file_contains "$ERR" "before their prompts are staged"
# A second stage is attempt a2, a1 untouched; a third is beyond the cap.
SHA1="$(sha_of "$P1")"
council stage "$RID" propose B
assert_rc 0 "second stage"
assert_file "$DOC/prompts/propose-B.a2.md"
assert_eq "$SHA1" "$(sha_of "$P1")" "a1 after a2 was staged"
council stage "$RID" propose B
assert_rc 65 "third stage"
assert_file_contains "$ERR" "already has two attempts staged in propose"
assert_no_file "$DOC/prompts/propose-B.a3.md"
# Rounds are staged only for the reviewers.
council stage "$RID" round-1 A
assert_rc 64 "a round for the leader's letter"
council stage "$RID" round-9 B
assert_rc 64 "a round beyond the cap"
# The sealed brief is frozen.
cp "$DOC/brief.md" "$SANDBOX/brief.orig"
printf 'una línea añadida después del sello\n' >>"$DOC/brief.md"
council stage "$RID" propose C
assert_rc 65 "brief changed after its seal"
assert_file_contains "$ERR" "brief.md changed after it was sealed"
council seal "$RID" brief
assert_rc 65 "re-sealing a changed brief"
cp "$SANDBOX/brief.orig" "$DOC/brief.md"
council stage "$RID" propose C
assert_rc 0 "the restored brief"

# --- cross: the own proposal and the other two, by letter -------------------
mkdir -p "$DOC/1-propuestas"
printf 'Propuesta del líder\nENTREGA: PROPUESTA\n' >"$DOC/1-propuestas/A.md"
printf 'Propuesta B\n- [B-1] [P2] Coste\n  - Escenario: x\n- [B-2] [P1] Canal\n  - Escenario: y\nENTREGA: PROPUESTA\n' >"$DOC/1-propuestas/B.md"
printf 'Propuesta C sin salto final\n- [C-1] [P2] Plazo\nENTREGA: PROPUESTA' >"$DOC/1-propuestas/C.md"
council stage "$RID" cross B
assert_rc 1 "a cross stage before the leader's cross seal"
assert_file_contains "$ERR" "seal the leader's cross contribution first"
seal_phase cross
mv "$DOC/1-propuestas/C.md" "$SANDBOX/C.md"
council stage "$RID" cross B
assert_rc 1 "a missing input"
assert_file_contains "$ERR" "input missing: $DOC/1-propuestas/C.md"
mv "$SANDBOX/C.md" "$DOC/1-propuestas/C.md"
council stage "$RID" cross B
assert_rc 0 "stage cross B"
{
  cat "$PROMPTS/seat-rules.md" "$PROMPTS/phase-cross.md"
  header B cross B-3
  section BRIEF "$DOC/brief.md"
  section "TU PROPUESTA (B)" "$DOC/1-propuestas/B.md"
  section "PROPUESTA A" "$DOC/1-propuestas/A.md"
  section "PROPUESTA C" "$DOC/1-propuestas/C.md"
  printf '\n'
} >"$SANDBOX/want.cross"
cmp -s "$SANDBOX/want.cross" "$DOC/prompts/cross-B.a1.md" \
  || { diff "$SANDBOX/want.cross" "$DOC/prompts/cross-B.a1.md" >&2; fail "cross prompt composition"; }

# --- rounds: the audit gates the round, the composition carries the diff ----
printf '# Síntesis v1\n\nPaso 1\nPaso 2\n' >"$DOC/sintesis-v1.md"
printf '| B-1 | P2 | ACEPTADA | v1 |\n| B-2 | P1 | ACEPTADA | v1 |\n| C-1 | P2 | ACEPTADA | v1 |\n' >"$DOC/registro.md"
council stage "$RID" round-1 B
assert_rc 1 "a round without its audit"
assert_file_contains "$ERR" "auditoria-v1.md no existe"
printf -- '- [F1] VERIFICADA https://example.com — 1\n- [F2] NO CONFIRMA https://example.com/x — 2\n' >"$DOC/auditoria-v1.md"
council stage "$RID" round-1 B
assert_rc 1 "a round whose audit has a NO CONFIRMA"
assert_file_contains "$ERR" "auditoria-v1.md tiene una línea NO CONFIRMA"
printf -- '- [F1] VERIFICADA https://example.com — 1\n' >"$DOC/auditoria-v1.md"
council stage "$RID" round-1 B
assert_rc 0 "round-1 B"
{
  cat "$PROMPTS/seat-rules.md" "$PROMPTS/phase-round.md"
  header B round-1 B-3
  section BRIEF "$DOC/brief.md"
  section "SÍNTESIS v1" "$DOC/sintesis-v1.md"
  section "AUDITORÍA DE FUENTES v1" "$DOC/auditoria-v1.md"
  section "REGISTRO DE OBJECIONES" "$DOC/registro.md"
  printf '===== TUS P1/P2 ABIERTOS =====\n- [B-1] [P2] Coste — estado: PENDIENTE\n- [B-2] [P1] Canal — estado: PENDIENTE\n'
} >"$SANDBOX/want.r1"
cmp -s "$SANDBOX/want.r1" "$DOC/prompts/round-1-B.a1.md" \
  || { diff "$SANDBOX/want.r1" "$DOC/prompts/round-1-B.a1.md" >&2; fail "round-1 prompt composition"; }
# Round 2 carries the diff v1 → v2 and only what is still open.
mkdir -p "$DOC/rondas"
printf -- '- [B-1] RESUELTA: cubierto\nRIESGO RESIDUAL: x\nVERDICT: REVISE\n' >"$DOC/rondas/r1-B.md"
printf 'VERDICT: REVISE\n' >"$DOC/rondas/r1-C.md"
printf '# Síntesis v2\n\nPaso 1\nPaso 2 corregido\n' >"$DOC/sintesis-v2.md"
printf -- '- [F1] VERIFICADA https://example.com — 1\n' >"$DOC/auditoria-v2.md"
council stage "$RID" round-2 B
assert_rc 0 "round-2 B"
diff -u --label sintesis-v1.md --label sintesis-v2.md "$DOC/sintesis-v1.md" "$DOC/sintesis-v2.md" >"$SANDBOX/v1v2.diff"
{
  cat "$PROMPTS/seat-rules.md" "$PROMPTS/phase-round.md"
  header B round-2 B-3
  section BRIEF "$DOC/brief.md"
  section "SÍNTESIS v2" "$DOC/sintesis-v2.md"
  section "AUDITORÍA DE FUENTES v2" "$DOC/auditoria-v2.md"
  section "REGISTRO DE OBJECIONES" "$DOC/registro.md"
  section "CAMBIOS v1 -> v2 (diff -u)" "$SANDBOX/v1v2.diff"
  printf '===== TUS P1/P2 ABIERTOS =====\n- [B-2] [P1] Canal — estado: PENDIENTE\n'
} >"$SANDBOX/want.r2"
cmp -s "$SANDBOX/want.r2" "$DOC/prompts/round-2-B.a1.md" \
  || { diff "$SANDBOX/want.r2" "$DOC/prompts/round-2-B.a1.md" >&2; fail "round-2 prompt composition"; }

# --- --reminder: exactly what is missing, once per phase and letter ---------
cp "$FX/subagent-transcript.jsonl" "$SANDBOX/stage-agent.jsonl"
council record-agent "$RID" agent-stage "$SANDBOX/stage-agent.jsonl"
council capture "$RID" propose
assert_rc 0 "capture C's proposal (its handback lacks ENTREGA: PROPUESTA)"
council stage "$RID" propose C --reminder
assert_rc 0 "stage C's reminder"
{
  cat "$PROMPTS/nudge.md"
  printf '===== LO QUE FALTA =====\n- la última línea exacta `ENTREGA: PROPUESTA`\n'
} >"$SANDBOX/want.rem"
cmp -s "$SANDBOX/want.rem" "$DOC/prompts/propose-C.a1.reminder.md" \
  || { diff "$SANDBOX/want.rem" "$DOC/prompts/propose-C.a1.reminder.md" >&2; fail "propose reminder"; }
council stage "$RID" propose C --reminder
assert_rc 65 "a second reminder for the same phase and letter"
# A round reminder lists the missing status lines, the RIESGO RESIDUAL next to
# an APPROVED, and nothing that is present. C's own open P2 is C-1.
council stage "$RID" round-1 C
assert_rc 0 "round-1 C"
jq -c --arg m $'Revisión de C\n- [C-9] RESUELTA: un ID que C nunca declaró\nVERDICT: APPROVED' \
  '.message.content |= (if type == "array" then map(if .type == "tool_use" then .input.message = $m else . end) else . end)' \
  "$FX/synthetic-continuation.jsonl" >>"$SANDBOX/stage-agent.jsonl"
council capture "$RID" round-1
assert_rc 0 "capture C's round answer (synthetic turn)"
council stage "$RID" round-1 C --reminder
assert_rc 0 "stage C's round reminder"
{
  cat "$PROMPTS/nudge.md"
  printf '===== LO QUE FALTA =====\n'
  printf -- '- la línea de estado de tu C-1 [P2]: `- [C-1] RESUELTA: <motivo>` o `- [C-1] NO RESUELTA: <motivo>`\n'
  printf -- '- la línea `RIESGO RESIDUAL: <riesgo>` (obligatoria junto a un APPROVED)\n'
} >"$SANDBOX/want.rrem"
cmp -s "$SANDBOX/want.rrem" "$DOC/prompts/round-1-C.a1.reminder.md" \
  || { diff "$SANDBOX/want.rrem" "$DOC/prompts/round-1-C.a1.reminder.md" >&2; fail "round reminder"; }

# =============================================================================
# astra: a launch whose wrapper refuses before the counter → no turn recorded
# =============================================================================
setup_run 2026-10-18-noturn
seal_phase propose
council stage "$RID" propose B
N_BEFORE="$(stub_n)"
run env TANDEM_TRANSPORT=mcp bash "$COUNCIL" astra "$RID" propose
assert_rc 64 "astra exits with the wrapper's own code"
assert_eq "$N_BEFORE" "$(stub_n)" "no codex invocation"
assert_json "$RJ" '.astra_turns | length == 1 and .[0].estado == "failed" and .[0].turno == null
  and .[0].turn_before == 0 and .[0].exit == 64 and (.[0].nota | startswith("sin turno"))'

# =============================================================================
# astra + publish on one run: a failed start, its retry, a reminder, the caps,
# the wrong thread, the rebuild by generation
# =============================================================================
setup_run 2026-10-18-pub
printf 'Propuesta del líder\nENTREGA: PROPUESTA\n' >"$RD/sealed/propose.md"
council seal "$RID" propose
assert_rc 0 "seal the leader's proposal"
council stage "$RID" propose B
council stage "$RID" propose C
cp "$FX/subagent-transcript.jsonl" "$SANDBOX/agent-1.jsonl"
council record-agent "$RID" agent-1 "$SANDBOX/agent-1.jsonl"
council capture "$RID" propose
assert_rc 0 "capture Fable a1"
council publish "$RID" propose
assert_rc 1 "publish with no Astra turn yet"
assert_file_contains "$ERR" "no done Astra turn for attempt a1 of propose"

# a1 — a failed START (no thread yet).
run env CODEX_STUB_SCENARIO=fail bash "$COUNCIL" astra "$RID" propose
assert_rc 1 "a failed start"
assert_json "$RJ" '.astra_turns[0] | .fase == "propose" and .intento == 1 and .tipo == "sustantivo"
  and .estado == "failed" and .turn_before == 0 and .turno == 1 and .exit == 1
  and .wrapper_script == "codex-start.sh" and (.wrapper.pid | type) == "number"'
council publish "$RID" propose
assert_rc 1 "a failed turn is never published"

# The leader can no longer re-seal: a seat has been launched in this phase.
council seal "$RID" propose
assert_rc 65 "seal propose after a seat was launched"
assert_file_contains "$ERR" "BEFORE the seats are launched"

# a2 — the retry: still a start (a failed start leaves no thread).
council stage "$RID" propose B
printf 'Propuesta de B\n- [B-1] [P2] Riesgo de coste\n  - Escenario: x\n  - Evidencia: https://example.com/b\n  - Propuesta: y\n' \
  >"$SANDBOX/astra-prop.txt"
run env CODEX_STUB_REPLY_FILE="$SANDBOX/astra-prop.txt" TANDEM_TURN_EFFORT=low bash "$COUNCIL" astra "$RID" propose
assert_rc 0 "the retry"
assert_json "$RJ" '.astra_turns[1] | .intento == 2 and .estado == "done" and .turn_before == 1 and .turno == 2
  and .wrapper_script == "codex-start.sh"'
assert_file_contains "$(last_argv)" "model_reasoning_effort=max"
assert_not_contains "$(last_argv)" "${US}resume${US}"
# astra.tpl adds nothing: Astra receives the very bytes Fable reads with Read.
cmp -s "$DOC/prompts/propose-B.a2.md" "$(stub_stdin "$(stub_n)")" \
  || fail "Astra's prompt is not the staged file byte for byte"

# The reminder: a resume at low, whatever the caller exported.
council stage "$RID" propose B --reminder
assert_rc 0 "stage Astra's reminder"
assert_file_contains "$DOC/prompts/propose-B.a2.reminder.md" '- la última línea exacta `ENTREGA: PROPUESTA`'
printf 'ENTREGA: PROPUESTA\n' >"$SANDBOX/astra-rem.txt"
run env CODEX_STUB_REPLY_FILE="$SANDBOX/astra-rem.txt" TANDEM_TURN_EFFORT=xhigh bash "$COUNCIL" astra "$RID" propose --reminder
assert_rc 0 "the reminder turn"
assert_file_contains "$(last_argv)" "model_reasoning_effort=low"
assert_file_contains "$(last_argv)" "${US}resume${US}thr_stub_1${US}"
assert_json "$RJ" '.astra_turns[2] | .tipo == "recordatorio" and .intento == 2 and .estado == "done" and .turno == 3
  and .wrapper_script == "codex-resume.sh"'
assert_json "$SD/$G1KEY.t3.meta.json" '.effort == "low"'
# The caps: one reminder, two substantive turns.
N_BEFORE="$(stub_n)"
council astra "$RID" propose --reminder
assert_rc 65 "a second reminder"
run env TANDEM_TURN_EFFORT=low bash "$COUNCIL" astra "$RID" propose
assert_rc 65 "a third substantive turn"
assert_file_contains "$ERR" "already had two substantive turns in propose"
assert_eq "$N_BEFORE" "$(stub_n)" "no turn spent by a capped launch"

# --- publish refuses a done turn the wrapper never certified ----------------
cp "$SD/$G1KEY.t2.ok" "$SANDBOX/t2.ok"
rm -f "$SD/$G1KEY.t2.ok"
council publish "$RID" propose
assert_rc 65 "a done turn without its receipt"
assert_file_contains "$ERR" "has no receipt certifying its reply"
cp "$SANDBOX/t2.ok" "$SD/$G1KEY.t2.ok"
cp "$SD/$G1KEY.t2.reply.txt" "$SANDBOX/t2.reply"
printf 'una línea añadida a mano\n' >>"$SD/$G1KEY.t2.reply.txt"
council publish "$RID" propose
assert_rc 65 "a done turn whose reply no longer has the certified bytes"
cp "$SANDBOX/t2.reply" "$SD/$G1KEY.t2.reply.txt"

# --- Fable lost its session after a new prompt was prepared ----------------
council stage "$RID" propose C --with-history
assert_rc 0 "Fable's rebuild prompt"
council publish "$RID" propose
assert_rc 1 "publish without the capture of Fable's CURRENT attempt"
assert_file_contains "$ERR" "no Fable capture for attempt a2 of propose"
cp "$FX/subagent-transcript.jsonl" "$SANDBOX/agent-2.jsonl"
council record-agent "$RID" agent-2 "$SANDBOX/agent-2.jsonl"
council capture "$RID" propose
assert_rc 0 "capture the rebuilt Fable"

council publish "$RID" propose
assert_rc 0 "publish propose"
cmp -s "$RD/sealed/propose.md" "$DOC/1-propuestas/A.md" || fail "the leader's sealed proposal is not published verbatim"
{ cat "$SD/$G1KEY.t2.reply.txt"; cat "$SD/$G1KEY.t3.reply.txt"; } >"$SANDBOX/want.B"
cmp -s "$SANDBOX/want.B" "$DOC/1-propuestas/B.md" \
  || fail "Astra's published answer must be the done turn of the current attempt plus its reminder"
cmp -s "$RD/fable.propose.a2.reply.md" "$DOC/1-propuestas/C.md" || fail "Fable's published answer is not its current capture"
# Provenance lives in run.json, never in the published files.
for L in A B C; do
  if LC_ALL=C grep -Eiq 'astra|fable|claude|gpt|codex|opus' "$DOC/1-propuestas/$L.md"; then
    fail "the published $L.md reveals an identity"
  fi
done
assert_json "$RJ" '[.publications[] | select(.fase == "propose")] | length == 3'
assert_json "$RJ" '.publications[] | select(.letra == "B") | .fuentes == [
  {fuente: "turno de Astra", tipo: "sustantivo", intento: 2, target: "council-2026-10-18-pub-g1", turno: 2, recuperado: false},
  {fuente: "turno de Astra", tipo: "recordatorio", intento: 2, target: "council-2026-10-18-pub-g1", turno: 3, recuperado: false}]'
assert_json "$RJ" '.publications[] | select(.letra == "C") | .fuentes[0].intento == 2 and .fuentes[0].captura == "capturado"'
council publish "$RID" propose
assert_rc 2 "publish never overwrites"

# --- a running entry whose processes are dead → interrupted -----------------
sleep 0 &
DEAD=$!
wait "$DEAD" 2>/dev/null || true
jq --argjson d "$DEAD" --argjson tb "$(cat "$SD/$G1KEY.turn")" --arg t "council-2026-10-18-pub-g1" \
  '.astra_turns += [{fase: "propose", intento: 2, tipo: "sustantivo", target: $t, estado: "running",
     turn_before: $tb, turno: null, launch_token: "deadbeefdeadbeef", driver: {pid: $d, lstart: "x"},
     wrapper: {pid: $d, lstart: "x"}}]' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
council status "$RID"
assert_json "$RJ" '.astra_turns[-1] | .estado == "interrupted" and .recuperado == true
  and .nota == "contador sin avanzar: no hubo turno"'

# =============================================================================
# cross: the wrong thread, then the rebuild by generation
# =============================================================================
printf 'Cruce del líder\nENTREGA: CONTRAINTERROGATORIO\n' >"$RD/sealed/cross.md"
council seal "$RID" cross
council stage "$RID" cross B
council stage "$RID" cross C
printf 'respuesta del hilo EQUIVOCADO\n' >"$SANDBOX/wrong.txt"
run env CODEX_STUB_SCENARIO=resume-fallback CODEX_STUB_THREAD_ID_2=thr_elsewhere \
  CODEX_STUB_REPLY_FILE="$SANDBOX/wrong.txt" TANDEM_TURN_EFFORT=low bash "$COUNCIL" astra "$RID" cross
assert_rc 1 "the wrapper rejects the wrong thread"
# A substantive resume right after a reminder, with low exported: still max.
assert_file_contains "$(last_argv)" "model_reasoning_effort=max"
assert_file_contains "$(last_argv)" "${US}resume${US}thr_stub_1${US}"
assert_json "$RJ" '[.astra_turns[] | select(.fase == "cross")][0] | .estado == "failed" and .turno == 4'
assert_file_contains "$SD/$G1KEY.t4.reply.txt" "hilo EQUIVOCADO"
assert_no_file "$SD/$G1KEY.t4.ok"
council publish "$RID" cross
assert_rc 1 "the wrong-thread turn is never published"

# The rebuild: the next generation of the target, with the seat's own history.
council stage "$RID" cross B --with-history
assert_rc 0 "stage the rebuild"
assert_json "$RJ" '.astra_targets == ["council-2026-10-18-pub-g1", "council-2026-10-18-pub-g2"]'
assert_file_contains "$DOC/prompts/cross-B.a2.md" "===== TU HISTORIAL: propose ====="
assert_file_contains "$DOC/prompts/cross-B.a2.md" "Propuesta de B"
G2KEY="$(tkey "council-$RID-g2")"
# Its stream runs a command that names the run directory: an anomaly, no block.
{
  printf '{"type":"thread.started","thread_id":"thr_g2"}\n'
  printf '{"type":"item.started","item":{"type":"command_execution","command":"cat %s/sealed/cross.md"}}\n' "$RD"
  printf '{"type":"item.completed","item":{"type":"command_execution","command":"cat %s/sealed/cross.md","exit_code":0}}\n' "$RD"
  printf '{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}\n'
} >"$SANDBOX/g2.ndjson"
printf 'Cruce de B\nENTREGA: CONTRAINTERROGATORIO\n' >"$SANDBOX/astra-cross.txt"
run env CODEX_STUB_FIXTURE="$SANDBOX/g2.ndjson" CODEX_STUB_REPLY_FILE="$SANDBOX/astra-cross.txt" \
  bash "$COUNCIL" astra "$RID" cross
assert_rc 0 "the rebuilt Astra opens g2"
assert_json "$RJ" '[.astra_turns[] | select(.fase == "cross")][1] | .target == "council-2026-10-18-pub-g2"
  and .wrapper_script == "codex-start.sh" and .turno == 1 and .estado == "done" and .intento == 2'
assert_eq "thr_g2" "$(cat "$SD/$G2KEY.thread")" "g2's own thread"
# Only one reviewer is done: its turn stays assigned and publish waits.
council publish "$RID" cross
assert_rc 1 "publish waits for Fable"
assert_file_contains "$ERR" "no Fable capture for attempt a1 of cross"
cat "$FX/synthetic-continuation.jsonl" >>"$SANDBOX/agent-2.jsonl"
council capture "$RID" cross
assert_rc 0 "capture Fable's cross"
council publish "$RID" cross
assert_rc 0 "publish cross"
cmp -s "$SD/$G2KEY.t1.reply.txt" "$DOC/2-contrainterrogatorio/B.md" || fail "cross must publish g2's done turn"
assert_not_contains "$DOC/2-contrainterrogatorio/B.md" "hilo EQUIVOCADO"
assert_json "$RJ" "[.anomalies[] | select(.asiento == \"astra\")] | length == 1"
assert_json "$RJ" ".anomalies[] | select(.asiento == \"astra\") | .fase == \"cross\" and .comando == \"cat $RD/sealed/cross.md\""

# metadatos.md sums every usage file of BOTH generations, each once (the
# failed start emitted no turn.completed, so it left no ledger file).
council status "$RID" --metadata
assert_rc 1 "no round yet"
assert_file_contains "$DOC/metadatos.md" "- Astra: input_tokens=3709 output_tokens=171 (4 ficheros t<N>.usage.json de 2 generación(es)"
assert_file_contains "$DOC/metadatos.md" "- generaciones del hilo de Astra: council-$RID-g1, council-$RID-g2"
assert_file_contains "$DOC/metadatos.md" "- reconstrucción: cross letra B (a2, con historial)"
assert_file_contains "$DOC/metadatos.md" "- lectura fuera de alcance (astra, cross a2): cat $RD/sealed/cross.md"
assert_no_file "$DOC/estrategia-final.md"

note "council run: init letters, frozen brief, byte-exact stage with caps, astra start/resume/effort/caps, publish of the current attempt only, rebuild by generation"
