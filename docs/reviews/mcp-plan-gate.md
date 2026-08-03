# Review: mcp-plan-gate (v0.29.0)

- **Fecha:** 2026-08-03
- **Plan:** docs/plans/mcp-plan-gate.plan.md (M21; hallazgo Major del run real de M20b —
  el gate mcp del rol review se restringe a sus targets del pipeline, vía (a))
- **Rama:** tandem/mcp-plan-gate desde main 658ad77 (v0.28.0 + evidencia del run real de
  M20b). Aprobación vía `plan-approve.sh` (commit del plan 1c7617a6).
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean, actionlint clean) · typecheck:
  n/a (bash) · tests: 82 passed, 0 failed · proof: OK (`bash tests/verify.sh` →
  VERIFY OK, re-run tras cada cambio)
- **Modo:** interactivo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1,
  sin continuaciones; una adición del orquestador sobre observación del implementador.
- **Tokens del run:** plan-review 1 ronda — in 987 356 · out 7 845 (primer APPROVED a la
  primera del proyecto); code review 2 rondas — in 2 195 483 · out 14 436;
  implementación: n/a (transporte opus).

## Plan review — 1 ronda → APPROVED (0)

Sin hallazgos P1/P2: el gate por target en la frontera pre-estado del validador, la
simetría en ambos wrappers, el orden target→timeout y la cobertura propuesta se dieron
por completos a la primera.

## Code review — 2 rondas → APPROVED (1 → 0)

1 Major: los metadatos del punto 6 (orquestador) no estaban aún en el diff — plugin.json
en 0.28.0, sin entrada de CHANGELOG, M21 "pendiente" en el backlog y ARCHITECTURE sin el
eje nuevo. Aceptado y corregido en la ronda: los cuatro escritos y verificados por el
revisor como consistentes con el gate implementado. El gate funcional y sus tests
coincidieron con el plan desde la ronda 1.

## El detalle que define el cambio

El rol `review` tiene TRES familias de lanzamiento tras un solo wrapper y el gate por rol
no las distingue: pipeline (`cr-*`) y range (`range-review-*`) están migradas y probadas
con run real; la plan review de `tandem:plan` (target = ruta del plan) conserva
legítimamente su excepción foreground para planes pequeños, y bajo mcp el watchdog de
review (3600s) supera el cap foreground de Bash (600s) — el tool mataría el turno antes
de que el watchdog clasifique. El eje target responde 64 fail-closed en vez de correr ese
riesgo, con el orden target>timeout anclado por test y la migración `seeded`→`cr-seeded`
para que el caso de override vacío siga probando SU 64. Adición del orquestador sobre
observación del implementador: las cabeceras de ambos wrappers describen ahora el eje
target (la misma clase de texto rancio que la review de M20b cazó en ask/SKILL.md).
