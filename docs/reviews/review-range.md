# Review: review-range (v0.22.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/review-range.plan.md (M15; tarea 4/4 de la Cola 2 — cierre.
  REESCRITO íntegro en el red-team: el diseño solo-documentación del borrador resultó
  insuficiente y la mecánica de git pasó a un helper testeable)
- **Rama:** tandem/review-range, apilada sobre tandem/critical-opus-effort. Aprobación vía
  `plan-approve.sh` (commit del plan 9636eff; main intacta).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 72 passed, 0 failed (+2 ficheros) ·
  proof: OK (`bash tests/verify.sh` → VERIFY OK, re-run tras fixes de review)
- **Modo:** autónomo con una intervención humana explícita (abajo); implementador: Claude
  Opus 5, IMPLEMENTATION_COMPLETE en t1; fixes de review aplicados por el orquestador.
- **Tokens del run:** plan-review 6 rondas — in 9 932 129 · out 158 657; code review 2
  rondas — in 3 200 876 · out 39 946; implementación: n/a (transporte opus).

## Plan review — 6 rondas → APPROVED, con DEADLOCK del cap resuelto por el humano

Ronda 1 (7 hallazgos): bootstrap imposible en repo sin `.tandem/`; namespace `cr-range-*`
colisionable con slugs legales; los logs top-level hacían que /tandem:status recomendara
el camino prohibido a commit; instrucciones mutuamente excluyentes ("Steps 1-3 tal cual" +
"sin fix loop"); el reviewer podía inspeccionar la versión equivocada del código
circundante (checkout ≠ B); rango verbatim inseguro → REESCRITURA alrededor de
`scripts/review-range.sh`. Ronda 2: faltaban templates de rango (los del pipeline
instruyen "UNCOMMITTED"/`git diff HEAD`); dos contratos estáticos existentes rompían con
la sección nueva → mode-aware; `$WORK_ROOT` usado sin definir → el helper emite
`WORK_ROOT:`. Ronda 3: el frontmatter aún PROHIBÍA el caso nuevo ("NOT for
already-committed code"); anclas de templates; regla de linaje (mismo label = mismo
linaje). Ronda 4: prueba comportamental tres-puntos con grafo divergente; rama del
doble-sin-veredicto definida. Ronda 5: REVISE — el fix de ronda 4 del tres-puntos no llegó
al fichero (edit `s.replace` silencioso del orquestador, sin assert) → **cap de 5 rondas
alcanzado: DEADLOCK terminal declarado honestamente; nada aprobado ni commiteado.** El
humano revisó el informe y autorizó explícitamente una ronda de confirmación. Ronda 6:
APPROVED — "No new findings. The revised plan is implementable, its namespaces and failure
paths are safe."

## Code review — 2 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Major + 1 Minor, ACCEPTED — fixes del orquestador): los lanzamientos de rango
solo fijaban `TANDEM_CODEX_CWD` mientras los wrappers anclan el estado del hilo a
`${CLAUDE_PROJECT_DIR:-$PWD}` — desde un subdirectorio o worktree enlazado, el hilo se
separaría del contexto/log del helper y una invocación posterior arrancaría un hilo FRESCO
para el mismo label (ruptura silenciosa del linaje; el test lo ocultaba exportando siempre
la variable) → pin `CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$WORK_ROOT}"` en los 3
lanzamientos, ancla en el contrato y caso comportamental sin variable desde subdirectorio;
`mv -f` con un directorio okupando el destino "publica" el temporal DENTRO con éxito falso
→ pre-check de destino no-regular + verificación post-mv, caso de regresión con 65 y sin
temporal dentro. Ronda 2: APPROVED — "No new findings."

Nota de proceso: el DEADLOCK de la fase de plan fue causado por un fallo mecánico del
orquestador (edit sin `assert old in s`), no por desacuerdo técnico — se declaró terminal
según la política, se informó, y la continuación requirió autorización humana explícita.
