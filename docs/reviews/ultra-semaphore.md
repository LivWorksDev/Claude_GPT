# Review: ultra-semaphore (v0.20.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/ultra-semaphore.plan.md (M13; tarea 2/4 de la Cola 2 — borrador del
  enjambre ultracode, arbitrado)
- **Rama:** tandem/ultra-semaphore, apilada sobre tandem/status-skill. Aprobación vía
  `plan-approve.sh` (commit del plan 838935c; main intacta).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 68 passed, 0 failed (+4 ficheros) ·
  proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1; el fix
  de review lo aplicó el orquestador directamente (Minor).
- **Tokens del run:** plan-review 4 rondas — in 7 296 549 · out 97 612; code review 3
  rondas — in 4 327 881 · out 51 679; implementación: n/a (transporte opus).

## Plan review — 4 rondas → APPROVED (4 → 2 → 1 → 0)

Ronda 1 (1 P1 + 3 P2, ACCEPTED): el `trap 'exit 143'` durante el pipeline se saltaba
PIPESTATUS y la contabilidad de M9 (un turno completado quedaría sin ledger) → señal
PENDIENTE registrada, contabilidad primero; adquisición no signal-safe → SLOT_HELD +
sección crítica con señal diferida; el staging/borrado previo a la adquisición destruía la
reply anterior en un timeout → adquirir antes de tocar ficheros; el test de TERM era
vacuamente verde → barreras de preparación; 08/09 octales + vacío oculto por el display
del doctor → 10# + validación real. Ronda 2 (2 P2): señal pendiente honrada también en la
COLA (un TERM en espera salía 75 o adquiría tras la cancelación); el test
TERM-tras-completar era carrera pura → ventana del sleep del stub. Ronda 3 (1 P2): barrera
también en el test del esperador cancelado. Ronda 4: APPROVED.

## Code review — 3 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Minor, ACCEPTED — fix directo del orquestador): una señal tras el último
`sig_honor` (validación del resultado, emisión de la reply) solo se registraba y jamás se
honraba — un TERM tardío acababa como éxito. Fix: re-armado de los traps a salida directa
tras la frontera de contabilidad. Ronda 2 (refinamiento del mismo Minor): el drenaje iba
ANTES del re-armado — una señal entre ambos caía en el handler viejo y quedaba pendiente
para siempre; la aserción consolidaba el orden erróneo. Fix: re-armar los TRES traps
primero, drenar después; aserción estructural por orden de líneas (la ventana es de
microsegundos — una señal en vivo sería un test flaky). Ronda 3: APPROVED.

Mutation testing del implementador: 4/4 cazadas, incluida la reintroducción exacta del bug
del P1-1 (cazada por el test del ledger).
