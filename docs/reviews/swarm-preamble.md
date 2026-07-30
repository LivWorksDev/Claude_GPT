# Review: swarm-preamble (v0.13.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/swarm-preamble.plan.md (M8 del backlog; tarea 1/6 de la cola autónoma)
- **Rama:** tandem/swarm-preamble, apilada sobre tandem/plan-commit-branch (v0.12.0) —
  dependencia declarada: la cadena de la cola se mergea en orden (M3 → M8 → …). La
  aprobación del plan fue la primera ejecución en producción de `scripts/plan-approve.sh`
  (commit del plan 247f850 en la rama; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 53 passed,
  0 failed (+2 ficheros de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo (TANDEM_AUTONOMOUS=1); implementador: Claude Opus 5
  (tandem:implementer), IMPLEMENTATION_COMPLETE en t1 sin continuaciones

## Plan review — 2 rondas → APPROVED

Ronda 1 (REVISE, 1 P1 + 3 P2, los 4 ACCEPTED): P1 la versión 0.13.0 desde main contradecía
la mergeabilidad independiente (main en 0.11.0, la 0.12.0 sin mergear) → la rama se apila
sobre tandem/plan-commit-branch con la dependencia declarada; P2 el contrato del wrapper no
tenía cobertura (flag nuevo + copia manual retenida = preámbulo duplicado con todo verde) →
test estático de contrato; P2 el test comportamental no probaba los bytes que codex recibe
ni el quoting del filename → cmp doble (staged + stdin del stub), ruta con espacios/glob, y
codex pasa a leer stdin del staged en ambos modos; P2 el PROOF omitía capas obligatorias →
`bash tests/verify.sh`. Ronda 2: APPROVED sin hallazgos nuevos.

## Code review — 1 ronda → APPROVED (hilo fresco)

Sin hallazgos: "El diff implementa fielmente el plan, incluidos los ficheros no rastreados,
sin regresiones accionables detectadas. La cobertura verifica staged, stdin real,
compatibilidad sin flag y validación fail-closed."

Desviaciones aditivas del implementador, arbitradas por Fable como sanas: aserción del
usage-string actualizada a la firma nueva (necesaria); `--` end-of-options escrito y
retirado (camino no testeado; un prompt-file que empiece por `--` da 64 fail-closed);
`--preamble=<file>` no soportado (el plan especifica valor separado por espacio); dos
aserciones one-liner extra (argv de codex libre del flag; anti-vacuidad de la referencia).
