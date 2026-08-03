# Review: mcp-transport-review (v0.28.0)

- **Fecha:** 2026-08-03
- **Plan:** docs/plans/mcp-transport-review.plan.md (M20b; segundo salto de la Fase 2 —
  rol `review` sobre el transporte MCP, pipeline + range)
- **Rama:** tandem/mcp-transport-review desde main 01b7ca4 (v0.27.0 + evidencia del run
  real de M20a). Aprobación vía `plan-approve.sh` (commit del plan 2d27bc9e).
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean, actionlint clean) · typecheck:
  n/a (bash) · tests: 82 passed, 0 failed (1 fichero nuevo) · proof: OK
  (`bash tests/verify.sh` → VERIFY OK, re-run tras el fix de review)
- **Modo:** interactivo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1,
  sin continuaciones; fix de review del orquestador.
- **Tokens del run:** plan-review 2 rondas — in 2 756 284 · out 28 330; code review 2
  rondas — in 2 189 728 · out 15 174; implementación: n/a (transporte opus).

## Plan review — 2 rondas → APPROVED (4 → 0)

4 hallazgos P2, los 4 aceptados. El mejor: la regla "background siempre bajo mcp" chocaba
con el contrato EJECUTABLE por lanzamiento ya existente
(`tests/skill-review-background-contract.test.sh`), que exige la excepción foreground
small-diff en cada resume — un ancla file-level habría pasado con la skill contradictoria.
La regla quedó definida POR LANZAMIENTO: solo los starts mcp (los únicos turnos con
watchdog MCP) pierden la excepción; los resumes híbridos son turnos exec y la conservan;
los nudges siguen en foreground. También: `TANDEM_MCP_TIMEOUT_SECONDS=` vacío caía en
silencio al default por el `:-` (bug latente preexistente, cerrado con la disciplina
`${VAR+set}`); la "continuación híbrida si hay hallazgos" del run real violaba la
semántica range (los hallazgos SON el entregable y la invocación termina); y las
garantías de limpieza se acotaron a los caminos atrapables — el residuo bajo SIGKILL es
riesgo residual declarado, no una promesa.

## Code review — 2 rondas → APPROVED (1 → 0)

1 hallazgo Minor, legítimo: `skills/ask/SKILL.md` seguía diciendo que el transporte era
"(opt-in, `ask` only)" — guía de usuario factualmente incorrecta tras abrir el gate a
`ask | review`. Corregido nombrando el conjunto real de roles, con ancla anti-drift en el
parity test: la frase compartida "the roles `ask` and `review`" exigida en AMBAS skills
que documentan el transporte, más negativo sobre el texto rancio en la de ask.

## Lo que este salto NO tocó, a propósito

Cero ramas nuevas en los wrappers: la paridad por adaptador de M20a hace que `review`
viaje por el camino compartido — el diff real es gate (case cerrado `ask | review`,
64 nombra M20c), watchdog por rol (`TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW=3600`, elegido no
medido: los turnos xhigh observados rondan 10–25 min) y cobertura. El test comportamental
nuevo prueba además el caso range con tres directorios distintos y un cwd CON ESPACIO en
el call frame, y el clasificador del contrato trata un script desconocido como fallo.
`implement`/`image` siguen → 64 (M20c).
