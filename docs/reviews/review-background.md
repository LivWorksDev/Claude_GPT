# Review: review-background (v0.18.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/review-background.plan.md (M10 del backlog; tarea 6/6 — cierra la
  cola autónoma)
- **Rama:** tandem/review-background, apilada sobre tandem/doctor-preflight-gaps.
  Aprobación vía `plan-approve.sh` (commit del plan 760b216; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 60
  passed, 0 failed (+1 fichero de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5 (tandem:implementer),
  IMPLEMENTATION_COMPLETE en t1 sin continuaciones
- **Tokens del run:** plan-review 3 rondas — in 7 723 274 · out 47 867; code review 2
  rondas — in 1 939 900 · out 19 656; implementación: n/a (transporte opus)

## Plan review — 3 rondas → APPROVED (4 → 1 → 0)

Ronda 1 (4 P2, ACCEPTED): la finalización del background no era barrera dura (el
orquestador podría anotar `tokens: n/a` prematuro o lanzar un resume sobre un turno vivo) →
barrera explícita; el test no distinguía los 4 lanzamientos reales de los 2 nudges →
clasificación por template con conteos exactos; anclas positivas sin retirar el wording
legacy dejarían el default ambiguo → negativas seccionadas; el PROOF no cubría el caso
operativo → dogfood en dos piezas. Ronda 2 (1 resto): el dogfood debía cruzar los 600 s
reales → sonda background de coste cero de 601 s. Ronda 3: APPROVED.

## Code review — 2 rondas → APPROVED (hilo fresco, EN BACKGROUND — dogfood del propio texto)

Ronda 1 (1 Major, ACCEPTED y arreglado por Fable): el contrato contaba BLOQUES, no
lanzamientos lógicos — un start/resume duplicado del mismo tipo dentro de un bloque pasaría
con los totales correctos → fail explícito con más de un lanzamiento lógico por bloque,
verificado con mutación (duplicado → falla nombrando el bloque; restaurado → pasa).
Ronda 2: APPROVED — "No se encontraron regresiones nuevas."

## Dogfood operativo (aceptación del backlog)

- **Sonda de umbral:** tarea Bash en background durmió 601 s (PROBE_OK) y su notificación
  llegó tras cruzar el techo de 600 s del foreground — supervivencia larga por mecanismo,
  coste cero.
- **Semántica:** las DOS rondas de esta code review corrieron en background siguiendo el
  texto nuevo, con la secuencia completa registrada en el log: barrera respetada →
  notificación → `USAGE:` copiado → verdict procesado.
