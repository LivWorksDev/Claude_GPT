# Review: mcp-transport-implement (v0.30.0)

- **Fecha:** 2026-08-03
- **Plan:** docs/plans/mcp-transport-implement.plan.md (M20c; tercer y último salto de la
  Fase 2 en los wrappers — roles workspace-write `implement` + `image`; swarm fuera por
  diseño)
- **Rama:** tandem/mcp-transport-implement desde main 0afd288 (v0.29.0). Aprobación vía
  `plan-approve.sh` (commit del plan f04f9a05).
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean, actionlint clean) · typecheck:
  n/a (bash) · tests: 83 passed, 0 failed (1 fichero nuevo) · proof: OK
  (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** interactivo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1,
  sin continuaciones; metadatos del orquestador ANTES de la code review (lección M21).
- **Tokens del run:** plan-review 2 rondas — in 11 009 546 · out 34 352; code review
  1 ronda — in 2 258 566 · out 9 689 (primera CR limpia a la primera de la Fase 2);
  implementación: n/a (transporte opus).

## Plan review — 2 rondas → APPROVED (3 → 0)

3 hallazgos, los 3 de calidad. **P1-1**: aplicar `check_skill` a implement/SKILL.md tal
como estaba habría roto la suite — sus secciones sol carecían del lenguaje exacto del
contrato (deuda de M10); la resolución fue armonizar las tres secciones al estándar, no
un checker a medida. **P2-1**: la prueba del call frame omitía `approvals_reviewer=user`
y el `web_search` off que `_pins.sh` fija exactamente en los roles de escritura —
resuelto con comparación de OBJETO ENTERO (un pin perdido O SOBRANTE falla). **P2-2**:
el plan declaraba la Fase 2 completa antes de los únicos canarios funcionales — aceptada
la secuenciación (el cierre de M20 es bloqueante sobre los canarios post-merge) y
rechazada la extensión del stub con escritura observable (un artefacto del stub prueba
que el stub escribe, no que el sandbox de codex se comporte: CI prueba el contrato, los
canarios el comportamiento).

## Code review — 1 ronda → APPROVED (0)

Sin hallazgos: fidelidad al plan, test nuevo incluido, enforcement de pins de escritura,
matriz de watchdog, resumes híbridos y "honest pre-canary metadata" — el revisor validó
explícitamente la secuencia de declaración. Los metadatos viajaron en el diff desde
antes del lanzamiento de la review: la ronda extra que M21 pagó por el orden invertido
no se repitió.

## Los detalles que definen el salto

La matriz de watchdog se decide por el modo de lanzamiento DOMINANTE, no por el sandbox:
`implement` 3600s (literal propio, no alias del de review), `image` 540s aunque escriba
— y esa decisión quedó anclada estáticamente con un assert de AUSENCIA del literal
`_IMAGE` (un default ancho para image sería un ensanchamiento silencioso de su contrato
foreground). Las promesas de M2 se verifican sobre el frame MCP como objeto completo, la
precedencia de effort (CRITICAL → xhigh; `TANDEM_IMPLEMENT_EFFORT` gana) quedó probada
sobre el transporte, y la cobertura negativa del gate migró al caso de rol desconocido
con la forma exacta de los casos flipados. El cierre de M20/Fase 2 NO viaja en esta
versión: queda bloqueado sobre los dos canarios reales (implement workspace-write real +
image 1 asset), cuyo commit de evidencia es quien lo declara.
