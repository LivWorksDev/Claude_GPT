# Review: doctor-preflight-gaps (v0.17.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/doctor-preflight-gaps.plan.md (M7 del backlog; tarea 5/6 de la cola autónoma)
- **Rama:** tandem/doctor-preflight-gaps, apilada sobre tandem/turn-effort-override.
  Aprobación vía `plan-approve.sh` (commit del plan 9a35851; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 59
  passed, 0 failed (+1 fichero de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5 (tandem:implementer),
  IMPLEMENTATION_COMPLETE en t1 sin continuaciones
- **Tokens del run:** plan-review 3 rondas — in 9 510 568 · out 68 835; code review 3
  rondas — in 5 002 852 · out 49 247; implementación: n/a (transporte opus)

## Plan review — 3 rondas → APPROVED (5 → 4 → 0)

Ronda 1 (1 P1 + 4 P2, ACCEPTED): **`minimal` NO existe para sol/luna en la CLI pineada**
(evidencia de `codex debug models --bundled`; el parsing global del CLI valida el string,
no el soporte por modelo — el effort hard-codeado habría reportado "retirado" en falso un
modelo sano) → sin override de effort; la lista inline de pins no era "la misma política"
(faltaban 5) → `codex_pins()` extraída a `scripts/_pins.sh` sourceable sin efectos, paridad
por construcción; el smoke persistía sesión y corría sobre el repo del usuario →
`--ephemeral` + `--cd` temporal + sin web search; clasificación por presencia del nombre
misclasificaría auth/cuota → semántica de modelo-no-disponible + stub selectivo por modelo;
sin timeout → watchdog por modelo con continuación.

Ronda 2 (1 P1 + 3 P2, ACCEPTED): el watchdog de 120 s era intesteable bajo el timeout de
60 s del runner → override validado `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS` + cuelgue
selectivo por modelo en el stub; `codex_pins` ya emite `--cd` con `TANDEM_CODEX_CWD`
heredada (dos `--cd` = exit 2) → el smoke fija la env al temporal antes del helper; la
sonda `exec --help` contaba como turno en el stub → rama explícita no contada, y sin
`--ephemeral` → FAIL + cero turnos; secciones obsoletas del plan. Ronda 3: APPROVED.

## Code review — 3 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Major + 2 Minor, ACCEPTED y arreglados por Fable): sin limpieza de señales, un
doctor interrumpido huérfana al grupo codex aislado, y matar al watchdog nada más morir el
líder salta el KILL que recoge descendientes TERM-resistentes → `smoke_cleanup` con traps
EXIT/INT/TERM + el doctor espera a que el watchdog complete su TERM→KILL + el stub gana un
hijo TERM-resistente con pidfile y el test aserta su muerte; el rc de `exec --help` se
ignoraba (un help fallido que imprime el flag licenciaba turnos) → rc 0 exigido + test;
`config-probe.sh` seguía apuntando a `_common.sh` → referencias a `_pins.sh`.

Ronda 2 (1 Major refinado, ACCEPTED): la limpieza comprobaba la vida del LÍDER — en la
ventana de gracia el líder muere y el GRUPO sigue vivo con el resistente → el grupo se
comprueba y mata con independencia del líder; test de interrupción con TERM en la ventana.
Ronda 3: APPROVED — "No new findings."

Verificación empírica del implementador: `--ephemeral` y todos los flags del smoke
confirmados contra el `exec --help` de la codex-cli 0.144.4 real; paridad byte a byte del
doctor sin argumentos y de los tres tests de argv tras la extracción de `_pins.sh`.
Leftover aceptado: ningún turno real ejecutado desde el pipeline — se recomienda un
`bash scripts/codex-doctor.sh --smoke` manual antes de release.
