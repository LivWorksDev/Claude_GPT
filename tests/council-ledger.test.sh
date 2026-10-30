#!/usr/bin/env bash
# council.sh ledger and status — the executable register and the consensus
# rule, judged on published answers written straight to disk (no model turn is
# needed to exercise the parser).
#
# ledger: every objection ID of every published answer sits in exactly one row
# of registro.md, the disposition belongs to {ACEPTADA, RECHAZADA, ABIERTA} and
# the severity is the one its author declared (the moderator cannot downgrade a
# P1). status: CONSENSO only when, in the last round with both reviewer answers,
# (1) both end in VERDICT: APPROVED with a RIESGO RESIDUAL: line, (2) no
# reviewer P1/P2 is NO RESUELTA or PENDIENTE, (3) every RESUELTA over a RECHAZADA
# row names its reason, (4) the ledger passes, (5) no P1 row is ABIERTA and (6)
# the audit of that round's synthesis exists with no NO CONFIRMA. An APPROVED
# that contradicts (2) is an incoherence and counts as REVISE; a P3 never
# blocks. --metadata copies the reviewed synthesis byte for byte and sums every
# usage file exactly once.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
RID=2026-10-18-ledger
DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
RD="$CLAUDE_PROJECT_DIR/.tandem/state/council/runs/$RID"
RJ="$RD/run.json"
SD="$CLAUDE_PROJECT_DIR/.tandem/state/council"

council() { run bash "$COUNCIL" "$@"; }
rj_set() { jq "$@" "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"; }

council init "$RID"
assert_rc 0 "init"
# Deterministic letters for the scenario (the moderator never chooses them;
# a test may): A = leader, B = Astra, C = Fable.
rj_set '.letters = {A: "lider", B: "astra", C: "fable"}'
mkdir -p "$DOC/1-propuestas" "$DOC/2-contrainterrogatorio" "$DOC/rondas"
printf '# Brief\n\nObjetivo: medible\n' >"$DOC/brief.md"
council profile "$RID" critico
assert_rc 0 "profile"
council seal "$RID" brief
assert_rc 0 "seal brief"

objection() {
  # objection <id> <sev> <title>
  printf -- '- [%s] [%s] %s\n  - Escenario: algo falla\n  - Evidencia: https://example.com/%s\n  - Propuesta: cambiarlo\n' \
    "$1" "$2" "$3" "$1"
}

write_base() {
  {
    printf 'Propuesta del líder\n'
    printf 'ENTREGA: PROPUESTA\n'
  } >"$DOC/1-propuestas/A.md"
  {
    printf 'Propuesta B\n'
    objection B-1 P2 "Riesgo de coste"
    printf 'ENTREGA: PROPUESTA\n'
  } >"$DOC/1-propuestas/B.md"
  {
    printf 'Propuesta C\n'
    objection C-1 P1 "Objetivo inalcanzable con ese plazo"
    objection C-2 P3 "Detalle de redacción"
    printf 'ENTREGA: PROPUESTA\n'
  } >"$DOC/1-propuestas/C.md"
  {
    printf 'Cruce del líder\n'
    objection A-1 P2 "La propuesta B ignora el canal"
    printf 'ENTREGA: CONTRAINTERROGATORIO\n'
  } >"$DOC/2-contrainterrogatorio/A.md"
  {
    printf 'Cruce de B\n'
    objection B-2 P1 "El canal principal no escala"
    # A quoted FOREIGN ID is a reference, never a declaration of B's.
    objection C-1 P3 "cita de la objeción de C"
    printf 'ENTREGA: CONTRAINTERROGATORIO\n'
  } >"$DOC/2-contrainterrogatorio/B.md"
  {
    printf 'Cruce de C\n'
    objection C-3 P2 "Riesgo regulatorio"
    printf 'ENTREGA: CONTRAINTERROGATORIO\n'
  } >"$DOC/2-contrainterrogatorio/C.md"
  {
    printf '| ID | Sev | Disposición | Dónde / por qué |\n'
    printf '| --- | --- | --- | --- |\n'
    printf '| A-1 | P2 | ACEPTADA | v1 §2 |\n'
    printf '| B-1 | P2 | ACEPTADA | v1 §3 |\n'
    printf '| B-2 | P1 | RECHAZADA | el canal alternativo lo cubre |\n'
    printf '| C-1 | P1 | ACEPTADA | v1 §1 |\n'
    printf '| C-2 | P3 | ABIERTA | pendiente de decidir |\n'
    printf '| C-3 | P2 | ACEPTADA | v1 §4 |\n'
  } >"$DOC/registro.md"
  printf '# Síntesis v1\n\nLa estrategia «aprobada», con `bytes` raros: \\ $ & ñ\n' >"$DOC/sintesis-v1.md"
  printf -- '- [F1] VERIFICADA https://example.com/dato — 42 %%\n' >"$DOC/auditoria-v1.md"
  {
    printf 'Revisión de B\n'
    printf -- '- [B-1] RESUELTA: cubierto en §3\n'
    printf -- '- [B-2] RESUELTA: concedo: el canal alternativo escala\n'
    printf 'RIESGO RESIDUAL: el coste puede subir\n'
    printf 'VERDICT: APPROVED\n'
  } >"$DOC/rondas/r1-B.md"
  {
    printf 'Revisión de C\n'
    printf -- '- [C-1] RESUELTA: el plazo nuevo es realista\n'
    printf -- '- [C-3] RESUELTA: cubierto en §4\n'
    printf 'RIESGO RESIDUAL: dependencia externa\n'
    printf 'VERDICT: APPROVED\n'
  } >"$DOC/rondas/r1-C.md"
}

expect_consensus() {
  council status "$RID"
  assert_rc 0 "$1"
  assert_file_contains "$OUT" "STATUS: CONSENSO"
}

expect_no_consensus() {
  # expect_no_consensus <label> <reason-substring>
  council status "$RID"
  assert_rc 1 "$1"
  assert_file_contains "$OUT" "STATUS: SIN_CONSENSO"
  assert_file_contains "$OUT" "$2"
}

ledger_fails_with() {
  council ledger "$RID"
  assert_rc 1 "ledger: $2"
  assert_file_contains "$OUT" "LEDGER: FALLA"
  assert_file_contains "$OUT" "$1"
}

# =============================================================================
# the ledger
# =============================================================================
write_base
council ledger "$RID"
assert_rc 0 "complete register"
assert_file_contains "$OUT" "LEDGER: OK (6 objeciones"

# An ID with no row.
LC_ALL=C grep -v '^| C-3 ' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
ledger_fails_with "- C-3 [P2] de C: no aparece en ninguna fila de registro.md" "an absent ID"
# Two rows for one ID.
write_base
printf '| B-1 | P2 | RECHAZADA | otra vez |\n' >>"$DOC/registro.md"
ledger_fails_with "- B-1: aparece en 2 filas de registro.md (debe haber exactamente una)" "a duplicated ID"
# The moderator downgrades a P1.
write_base
LC_ALL=C sed -e 's/^| B-2 | P1 |/| B-2 | P2 |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
ledger_fails_with "- B-2: severidad P2 en el registro, pero su autor la declaró P1" "a downgraded severity"
# A disposition outside the closed set.
write_base
LC_ALL=C sed -e 's/^| A-1 | P2 | ACEPTADA |/| A-1 | P2 | PARCIAL |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
ledger_fails_with "- A-1: disposición «PARCIAL» fuera del conjunto ACEPTADA | RECHAZADA | ABIERTA" "a disposition outside the set"
# A row for an objection nobody published, and a row with no where/why.
write_base
printf '| B-9 | P2 | ACEPTADA | inventada |\n' >>"$DOC/registro.md"
LC_ALL=C sed -e 's/^| C-1 | P1 | ACEPTADA | v1 §1 |/| C-1 | P1 | ACEPTADA | |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
ledger_fails_with "- B-9: fila sin ninguna objeción publicada con ese ID" "an invented ID"
assert_file_contains "$OUT" "- C-1: fila sin «dónde / por qué»"
# A failing ledger is a failing consensus.
expect_no_consensus "consensus with a failing ledger" "- registro: B-9: fila sin ninguna objeción publicada con ese ID"
# No register at all.
write_base
rm -f "$DOC/registro.md"
council ledger "$RID"
assert_rc 1 "no register"
assert_file_contains "$OUT" "registro.md no existe"

# =============================================================================
# the consensus rule
# =============================================================================
write_base
expect_consensus "the base case: both APPROVED, everything resolved"
assert_file_contains "$OUT" "PHASE: informe (CONSENSO en la ronda 1)"
assert_file_contains "$OUT" "- ronda 1: B APPROVED · C APPROVED"

# (1) a REVISE, an APPROVED without RIESGO RESIDUAL, a missing VERDICT.
write_base
printf 'VERDICT: REVISE\n' >>"$DOC/rondas/r1-C.md"
expect_no_consensus "one reviewer REVISE" "- ronda 1: C termina en VERDICT: REVISE"
write_base
LC_ALL=C grep -v '^RIESGO RESIDUAL' "$DOC/rondas/r1-B.md" >"$DOC/x.tmp" && mv "$DOC/x.tmp" "$DOC/rondas/r1-B.md"
expect_no_consensus "APPROVED without RIESGO RESIDUAL" "- ronda 1: B aprueba sin la línea RIESGO RESIDUAL:"
write_base
LC_ALL=C grep -v '^VERDICT' "$DOC/rondas/r1-B.md" >"$DOC/x.tmp" && mv "$DOC/x.tmp" "$DOC/rondas/r1-B.md"
expect_no_consensus "no VERDICT line" "- ronda 1: B no termina en una línea VERDICT:"

# (2) an APPROVED with its own P2 still NO RESUELTA is an incoherence.
write_base
printf 'Revisión de C\n- [C-1] RESUELTA: ok\n- [C-3] NO RESUELTA: sigue el riesgo\nRIESGO RESIDUAL: x\nVERDICT: APPROVED\n' >"$DOC/rondas/r1-C.md"
expect_no_consensus "APPROVED with an own P2 NO RESUELTA" "- incoherencia: C dice VERDICT: APPROVED con C-3 sin resolver — cuenta como REVISE"
assert_file_contains "$OUT" "- C-3 [P2] de C: NO RESUELTA"
# …and one with no status line at all stays PENDIENTE.
printf 'Revisión de C\n- [C-1] RESUELTA: ok\nRIESGO RESIDUAL: x\nVERDICT: APPROVED\n' >"$DOC/rondas/r1-C.md"
expect_no_consensus "a P2 with no status line" "- C-3 [P2] de C: PENDIENTE"

# REABRE → PENDIENTE until a NEW status line.
write_base
printf -- '- [REABRE C-3] el regulador publicó una norma nueva\nVERDICT: APPROVED\n' >>"$DOC/rondas/r1-C.md"
expect_no_consensus "a reopened objection" "- C-3 [P2] de C: PENDIENTE"
printf -- '- [C-3] RESUELTA: la síntesis ya contempla la norma\nVERDICT: APPROVED\n' >>"$DOC/rondas/r1-C.md"
expect_consensus "a reopened objection resolved again"

# A NEW P1 in the last round blocks: it is PENDIENTE by construction.
write_base
{
  printf 'Revisión de B\n'
  printf -- '- [B-1] RESUELTA: ok\n- [B-2] RESUELTA: concedo: el canal alternativo escala\n'
  objection B-3 P1 "Problema nuevo de esta versión"
  printf 'RIESGO RESIDUAL: x\nVERDICT: REVISE\n'
} >"$DOC/rondas/r1-B.md"
printf '| B-3 | P1 | ACEPTADA | v2 |\n' >>"$DOC/registro.md"
expect_no_consensus "a new P1 in the last round" "- B-3 [P1] de B: PENDIENTE"

# A P3 never blocks — with no status line, or even NO RESUELTA.
write_base
printf -- '- [C-2] NO RESUELTA: sigue igual\nVERDICT: APPROVED\n' >>"$DOC/rondas/r1-C.md"
LC_ALL=C sed -e 's/^| C-2 | P3 | ABIERTA |/| C-2 | P3 | RECHAZADA |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
expect_consensus "a P3 NO RESUELTA does not block"
# The leader's own objections are not a reviewer's: A-1 needs no status line.
assert_not_contains "$OUT" "A-1"

# (3) a RESUELTA over a RECHAZADA row must name its reason.
write_base
printf 'Revisión de B\n- [B-1] RESUELTA: ok\n- [B-2] RESUELTA:\nRIESGO RESIDUAL: x\nVERDICT: APPROVED\n' >"$DOC/rondas/r1-B.md"
expect_no_consensus "a reasonless concession" "- B-2: RESUELTA sin motivo sobre una objeción RECHAZADA por el registro (conceder exige nombrar el argumento)"

# (5) a P1 row ABIERTA blocks; a P2 row ABIERTA does not.
write_base
LC_ALL=C sed -e 's/^| C-1 | P1 | ACEPTADA |/| C-1 | P1 | ABIERTA |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
expect_no_consensus "a P1 ABIERTA" "- C-1 [P1] sigue ABIERTA en el registro"
write_base
LC_ALL=C sed -e 's/^| A-1 | P2 | ACEPTADA |/| A-1 | P2 | ABIERTA |/' "$DOC/registro.md" >"$DOC/r.tmp" && mv "$DOC/r.tmp" "$DOC/registro.md"
expect_consensus "a P2 ABIERTA does not block"

# (6) the audit of the reviewed synthesis.
write_base
printf -- '- [F2] NO CONFIRMA https://example.com/otro — 17 %%\n' >>"$DOC/auditoria-v1.md"
expect_no_consensus "an approved round whose audit has a NO CONFIRMA" "auditoria-v1.md tiene una línea NO CONFIRMA"
rm -f "$DOC/auditoria-v1.md"
expect_no_consensus "no audit" "auditoria-v1.md no existe"
# Offline: the audit must carry the OFFLINE line.
write_base
rj_set '.mode = "offline"'
expect_no_consensus "offline without the OFFLINE line" "no trae la línea «- OFFLINE: no aplica» (run offline)"
printf -- '- OFFLINE: no aplica\n' >"$DOC/auditoria-v1.md"
expect_consensus "offline with the OFFLINE line"
rj_set '.mode = "web"'

# The LAST round with both reviewer answers is the one judged.
write_base
printf '# Síntesis v2\n\nOtra versión\n' >"$DOC/sintesis-v2.md"
printf -- '- [F1] VERIFICADA https://example.com/dato — 42 %%\n' >"$DOC/auditoria-v2.md"
printf 'Revisión 2 de B\nRIESGO RESIDUAL: x\nVERDICT: REVISE\n' >"$DOC/rondas/r2-B.md"
expect_consensus "round 2 has only one reviewer answer: round 1 is the last complete one"
printf 'Revisión 2 de C\nRIESGO RESIDUAL: y\nVERDICT: APPROVED\n' >"$DOC/rondas/r2-C.md"
expect_no_consensus "round 2 complete with a REVISE" "- ronda 2: B termina en VERDICT: REVISE"
assert_file_contains "$OUT" "PHASE: sintesis-v3"

# =============================================================================
# --metadata: the reviewed synthesis byte for byte, every usage file once
# =============================================================================
write_base
rm -f "$DOC/rondas/r2-B.md" "$DOC/rondas/r2-C.md"
K1="$(tkey "council-$RID-g1")"
K2="$(tkey "council-$RID-g2")"
mkdir -p "$SD"
printf '{"input_tokens":100,"output_tokens":10}\n' >"$SD/$K1.t1.usage.json"
printf '{"input_tokens":200,"output_tokens":20,"reasoning_output_tokens":5}\n' >"$SD/$K1.t2.usage.json"
printf '{"input_tokens":300,"output_tokens":30}\n' >"$SD/$K2.t1.usage.json"
printf '{"role":"council","model":"gpt-6-astra","effort":"max","sandbox":"read-only"}\n' >"$SD/$K1.t1.meta.json"
printf '{"role":"council","model":"gpt-6-astra","effort":"max","sandbox":"read-only"}\n' >"$SD/$K2.t1.meta.json"
# g1 t2 failed — its quota is spent all the same — and it is referenced TWICE.
rj_set --arg g1 "council-$RID-g1" --arg g2 "council-$RID-g2" \
  '.astra_targets = [$g1, $g2]
   | .astra_turns = [
      {fase: "propose", intento: 1, tipo: "sustantivo", target: $g1, estado: "done", turno: 1},
      {fase: "cross", intento: 1, tipo: "sustantivo", target: $g1, estado: "failed", turno: 2},
      {fase: "cross", intento: 1, tipo: "recordatorio", target: $g1, estado: "failed", turno: 2},
      {fase: "cross", intento: 2, tipo: "sustantivo", target: $g2, estado: "done", turno: 1}]'
printf '{"input_tokens":2,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":7}\n' \
  >"$RD/fable.propose.a1.usage.json"
printf '{"input_tokens":3,"cache_read_input_tokens":20,"cache_creation_input_tokens":6,"output_tokens":8}\n' \
  >"$RD/fable.cross.a1.usage.json"
council status "$RID" --metadata
assert_rc 0 "status --metadata on a consensus"
assert_file "$DOC/estrategia-final.md"
cmp -s "$DOC/sintesis-v1.md" "$DOC/estrategia-final.md" \
  || fail "estrategia-final.md is not byte-identical to the synthesis reviewed in the last round"
META="$DOC/metadatos.md"
assert_file "$META"
assert_file_contains "$META" "- Astra: input_tokens=600 output_tokens=60 reasoning_output_tokens=5 (3 ficheros t<N>.usage.json de 2 generación(es)"
assert_file_contains "$META" "- Fable: input_tokens=5 cache_read_input_tokens=30 cache_creation_input_tokens=11 output_tokens=15 (2 capturas"
assert_file_contains "$META" "- líder: no medido"
assert_file_contains "$META" "| A | líder | claude-opus-5-5 / max | autodeclarado"
assert_file_contains "$META" "| B | Astra (Codex) | gpt-6-astra/max |"
assert_file_contains "$META" "- generaciones del hilo de Astra: council-$RID-g1, council-$RID-g2"
assert_file_contains "$META" "- Estado: CONSENSO en la ronda 1"

# With a complete round 2, the reviewed synthesis is v2.
printf '# Síntesis v2\n\nOtra versión\n' >"$DOC/sintesis-v2.md"
printf -- '- [F1] VERIFICADA https://example.com/dato — 42 %%\n' >"$DOC/auditoria-v2.md"
printf 'Revisión 2 de B\nRIESGO RESIDUAL: x\nVERDICT: APPROVED\n' >"$DOC/rondas/r2-B.md"
printf 'Revisión 2 de C\nRIESGO RESIDUAL: y\nVERDICT: APPROVED\n' >"$DOC/rondas/r2-C.md"
council status "$RID" --metadata
assert_rc 0 "status --metadata after round 2"
cmp -s "$DOC/sintesis-v2.md" "$DOC/estrategia-final.md" \
  || fail "estrategia-final.md must follow the synthesis reviewed in the LAST round"

note "council ledger + status: closed register, author severity, the six consensus rules, metadata sums"
