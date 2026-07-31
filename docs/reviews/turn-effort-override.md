# Review: turn-effort-override (v0.16.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/turn-effort-override.plan.md (M5 del backlog; tarea 4/6 de la cola autónoma)
- **Rama:** tandem/turn-effort-override, apilada sobre tandem/statusline-opus (cadena de la
  cola). Aprobación vía `plan-approve.sh` (commit del plan 0f10b95; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 58
  passed, 0 failed (+2 ficheros de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5 (tandem:implementer),
  IMPLEMENTATION_COMPLETE en t1 sin continuaciones
- **Tokens del run:** plan-review 4 rondas — in 5 357 505 · out 56 143; code review 1
  ronda — in 1 371 878 · out 7 609; implementación: n/a (transporte opus)

## Plan review — 4 rondas → APPROVED (5 → 4 → 1 → 0)

Ronda 1 (2 P1 + 3 P2, ACCEPTED): no existía comando/template de nudge implementable
(prefijar los comandos reales degradaría trabajo real; reutilizar sus templates relanzaría
el trabajo caro) → nudge.tpl dedicado por skill con comandos fenced concretos; el effort no
quedaba en ningún artefacto durable (heartbeat global y reemplazable) → `t<N>.meta.json`
por turno; la cuarta rama de nudge (image) estaba omitida; la validación llegaba tarde
(64 debe ganar a 3 con dependencia ausente) → validación pre-deps; la lista rechazaba
max/ultra que el README documenta → lista ampliada.

Ronda 2 (1 P1 + 3 P2, ACCEPTED): los nudges de review/implement omitían el pin
`TANDEM_CODEX_CWD` (el contrato de worktree rechaza lanzamientos sin pin y el nudge
reanudaría en el árbol equivocado) → ambos con las dos variables; contrato de salida por
rol (implement necesita informe + sentinel, no solo la línea); el meta de start sin
cobertura y una afirmación obsoleta; printf de strings del entorno → jq -n --arg con test
JSON-hostil. Ronda 3 (1 resto de coherencia Acceptance/Goal, ACCEPTED). Ronda 4: APPROVED.

## Code review — 1 ronda → APPROVED (hilo fresco)

Sin hallazgos: "La implementación es fiel al plan y las pruebas cubren los casos de
aceptación relevantes." Desviaciones del implementador arbitradas como sanas: _common.sh
intocado (lógica inline en los wrappers, con ancla negativa que lo fija) y prosa de los
nudges sin nombrar codex-resume.sh (el contrato de worktree escanea toda línea de
review/implement — una mención en prosa lo rompería). Check negativo propio del
implementador: retirar el prefijo o el pin hace fallar el contrato nuevo con los mensajes
esperados.
