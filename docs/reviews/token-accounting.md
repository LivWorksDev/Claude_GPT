# Review: token-accounting (v0.14.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/token-accounting.plan.md (M9 del backlog; tarea 2/6 de la cola autónoma)
- **Rama:** tandem/token-accounting, apilada sobre tandem/swarm-preamble (cadena de la cola,
  merge en orden). Aprobación vía `plan-approve.sh` (commit del plan fb78de3; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 55 passed,
  0 failed (+2 ficheros de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo (TANDEM_AUTONOMOUS=1); implementador: Claude Opus 5
  (tandem:implementer), IMPLEMENTATION_COMPLETE en t1 sin continuaciones
- **Tokens del run (dogfooding de esta misma feature):** plan-review 4 rondas — in 8 967 025
  · out 91 549; code review 2 rondas — in 7 244 088 · out 40 435; implementación: n/a
  (transporte opus). Las dos rondas de code review ya emitieron su línea `USAGE:` con el
  código nuevo en producción.

## Plan review — 4 rondas → APPROVED (6 → 4 → 1 → 0 hallazgos)

Ronda 1 (2 P1 + 4 P2, todos ACCEPTED): extracción tras los checks infracontaría los turnos
caros que fallan (→ extracción tras PIPESTATUS, antes de todo check); un único usage.json
por seat es incompatible con el contrato de retry del swarm (→ ledger por intento);
"last-wins" sin verificar (→ suma campo a campo con evidencia empírica 36/36 streams reales
con un solo turn.completed); log de ronda solo en la rama REVISE + derivación de rutas sin
especificar (→ paso incondicional + footer USAGE: parseable); persistencia bajo set -euo
podía abortar un turno exitoso (→ tmp+mv con fallos tragados); aritmética de statusline
sobre campos sin sanear (→ solo enteros no negativos).

Ronda 2 (2 P1 + 2 P2, ACCEPTED): el footer era inalcanzable en los caminos de fallo (→ una
línea USAGE: por stderr antes de los checks); el wrapper ultra lo descartaba y un solo path
no da atribución por tier (→ schema con usage/usage_file nullables + mapeo seat→tier del
propio workflow); incoherencias internas del plan; regla explícita para campos no numéricos
(se descartan). Ronda 3 (1 P2, ACCEPTED): algoritmo de agregación único — el total sale del
ledger exactamente una vez por seat, el usage devuelto nunca se re-suma. Ronda 4: APPROVED.

## Code review — 2 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Major + 1 Minor, ambos ACCEPTED y arreglados por Fable):

- **CR1 Major — el retry de un start fallido pisaba el ledger t1:** codex-start fijaba
  TURN=1 siempre, y un fallo post-pipeline (reply vacía) sale antes de escribir el thread
  file, así que el retry volvía por start y sobreescribía la cuota ya contabilizada. Fix:
  contador de intento monotónico (lee e incrementa `.turn` con el sanitizador octal-safe de
  resume); el stub gana `CODEX_STUB_TOKENS_IN/OUT`; test de regresión: fallo 1234/56 →
  retry 9000/77 deja t1 intacto y t2 nuevo.
- **CR2 Minor — headings de ronda duplicables:** las ramas REVISE/REQUEST_CHANGES podían
  escribir un segundo `## Round <n>`, doblando el conteo aparente. Fix: ambas skills
  anotan bajo el heading ya escrito por el paso de contabilidad; ancla en el test estático.

Ronda 2: APPROVED — "No new findings introduced by the fixes."
