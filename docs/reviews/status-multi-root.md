# Review: status-multi-root (v0.25.0)

- **Fecha:** 2026-08-02
- **Plan:** docs/plans/status-multi-root.plan.md (M17; cierre de la Cola 3 — hallazgo
  Major 2 de la primera range review real)
- **Rama:** tandem/status-multi-root, cierre de la cadena: main 333236f ←
  status-approval-proof (v0.23) ← doctor-version-strict (v0.24) ← esta (v0.25).
  Aprobación vía `plan-approve.sh` (commit del plan d70cc15; main intacta).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 73 passed, 0 failed
  (status-multi-root.test.sh nuevo, 632→700 líneas tras los fixes de CR) · proof: OK
  (`bash tests/verify.sh` → VERIFY OK, re-run tras cada fix)
- **Modo:** autónomo con DOS intervenciones humanas explícitas (abajo); implementador:
  Claude Opus 5, IMPLEMENTATION_COMPLETE en t1; fixes de review del orquestador.
- **Tokens del run:** plan-review 7 rondas — in 14 852 024 · out 199 163; code review 3
  rondas — in 8 373 787 · out 53 717; implementación: n/a (transporte opus).

## Plan review — 7 rondas → APPROVED, con DEADLOCK del cap resuelto por el humano

El red-team más rico de las tres colas. Ronda 1 (4 P1 + 2 P2): compute_keys antes del
descubrimiento (claves rancias perderían raíces solo-thread); la escalera tiene DOCE
peldaños tras M16 y el rango 10..0 solo daba 11 (interacción entre tareas de la propia
cola); el empate por prioridad reproduce el next equivocado → orden de revisión
intra-fase; el linaje Opus faltaba en la sonda. Ronda 2: orden de revisión TOTAL (mismo
turno: completada>ausente; verdicts distintos = contradicción; Opus continuation_rounds
primero); dueños de la evidencia no-estado; secciones desincronizadas. Ronda 3:
**agent.id NO es identidad** (la recovery documentada lo renueva — compararlo inventa
split-brain); rama solo-en-candidato-no-default; tupla de progreso VALIDADA (rondas
negativas/fraccionarias jamás entran en aritmética). Ronda 4: dominancia válido>inválido
en progreso; OP_ID_VALID definido. Ronda 5: REVISE — los dos P2 ACCEPTED de r4 no
llegaron al fichero (el edit abortó en assert sin && con el resume) → **cap agotado:
DEADLOCK terminal declarado; nada aprobado.** El humano autorizó la reanudación
("apruebo"). Ronda 6: NO fue confirmación — P2-6 genuino (dominancia de LINAJE a fase
igual, sin la cual una raíz prioritaria corrupta enmascara un COMPLETE válido) →
ACCEPTED. Ronda 7: APPROVED.

## Code review — 3 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Major + 1 Minor): opus_vote comparaba progreso SIN comprobar linaje (con
ambos inválidos decidía el progreso, no la prioridad del plan; el test both-corrupt lo
ocultaba porque ambas reglas elegían la misma raíz) → gate de dos-linajes-válidos en el
voto + test invertido (la copia prioritaria corrupta lleva el PEOR progreso) + rendering
arbitrado con distinción: linaje PRESENTE-pero-inválido → corrupto sin IMPL_SENT; AUSENTE
→ display legacy (anclado por M11 — degradarlo rompería ese contrato); arnés read-only
ampliado a la tercera raíz derivada. Ronda 2: Major parcial — la presencia usaba el mismo
filtro que exige strings (plan_hash null o medio linaje parecían "ausentes") → has()
independiente, legacy solo con las TRES claves ausentes, 3 casos nuevos con control de
contraste. Ronda 3: APPROVED — "No new findings."

Notas de proceso: la objeción del implementador (branch nunca dispara contradicción por
construcción) se aceptó tal cual con comentario en código; el DEADLOCK previo produjo la
lección "edición y resume SIEMPRE en cadena &&", aplicada en todo el resto del run.
