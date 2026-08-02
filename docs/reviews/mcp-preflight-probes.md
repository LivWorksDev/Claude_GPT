# Review: mcp-preflight-probes (v0.26.0)

- **Fecha:** 2026-08-02
- **Plan:** docs/plans/mcp-preflight-probes.plan.md (M19; primera de la Cola 4 — Fase 2)
- **Rama:** tandem/mcp-preflight-probes desde main d735393 (el commit que aterrizó los
  fixtures reales). Aprobación vía `plan-approve.sh` (commit del plan 6abff01).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 79 passed, 0 failed (6 ficheros
  nuevos) · proof: OK (`bash tests/verify.sh` → VERIFY OK, re-run tras cada fix)
- **Modo:** autónomo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1; fixes
  de review aplicados por el orquestador.
- **Tokens del run:** plan-review 5 rondas — in 14 663 288 · out 148 580; code review 4
  rondas — in 12 207 153 · out 104 722; implementación: n/a (transporte opus).
  Preparación ultra (2 workflows, 5 agentes): ~509k tokens de subagentes.

## Plan review — 5 rondas → APPROVED (4 → 3+1 → 2 → 2 → 0), APROBADO EN LA ÚLTIMA

Diez hallazgos, todos ACCEPTED. **P1-1 fue un fallo de SEGURIDAD del plan**: el probe de
herencia reescribía el config a `danger-full-access` + `on-request` justo antes del turno
pagado cuya premisa es que NO se hereda — si la premisa fuese falsa, ese turno correría
sin contención en la máquina del usuario, violando la prohibición del repo. Ahora los
valores hostiles son inocuos (modelo/effort) y la seguridad se deriva de `codex_pins()`
POR CONSTRUCCIÓN. P1-2: `STATIC` no estaba atado a la versión que lo prueba (el README
recomienda `@latest`). P1-3: `--only` arbitrario + continuación tras fallo eran
incompatibles con el hilo compartido → DAG con saltos NOT_RUN de cero turnos. P1-4:
timeout era INDETERMINABLE en el contrato y FAIL en la aceptación. P1-5: el gate de
versión hacía imposibles los tests felices (el stub reporta 0.0.0-stub y un test del
doctor depende de ese valor). P1-6: los fixtures estaban SIN TRACKEAR y `plan-approve`
commitea solo el plan — jamás habrían llegado a la rama; se aterrizaron en main aparte.
P1-7: y ese arreglo dejó obsoleta la base de rama declarada en el plan — Sol vigiló la
coherencia de su propio fix. P2-1/2-2/2-3: fixtures reales + drift sin gasto, codeword
impredecible ausente del prompt de resume, y `NOT_RUN` como estado de primera clase.

## Code review — 4 rondas → APPROVED (5 Major → 3 → 1 Minor → 0)

Ronda 1, cinco Majors de UNA misma clase: **veredictos que podían dar PASS sin probar lo
que afirman.** (1) probe c leía el `turn_context` RANCIO de la llamada anterior — una
continuación fallida se certificaba como herencia congelada; (2) verificaba solo
modelo+effort cuando la promesa incluía approval/sandbox/cwd; (3) probe a caía a PASS sin
`thread.started` — justo la garantía anti-fallback; (4) el gate de versión recortaba
sufijos, así que `0.144.4-dev` heredaba un veredicto de fuente no auditada; (5) el job de
drift comparaba solo nombres: quitar `never` o `read-only` de un enum pasaba verde.
Ronda 2: el baseline del contexto corría CARRERA con el servidor (contado tras enviar la
llamada), el threadId ausente seguía pudiendo pasar, el drift ignoraba
`additionalProperties` por propiedad (el mapa `config` que lleva TODOS los pins podía
cerrarse sin señal), y — la mejor crítica del ciclo — **mi test de regresión de identidad
era VACUO**: sin el codeword en la respuesta, el código viejo fallaba igual por otro
motivo. Ronda 3: un conteo desfasado por mi propio fix. Ronda 4: APPROVED.

## Hallazgo del orquestador (no delegable)

El implementador probó todos los caminos contra el stub; al ejecutar el script contra la
**CLI real** (sin `--spend`, gratis) aparecieron dos warnings de bash en stderr durante un
run con rc 0 — contrato de stderr limpio roto. Los guardias se forkean con `&` y heredaban
los traps del script: pararlos con `kill` (TERM) hacía que el subshell ejecutara
`mcp_cleanup` y matara el servidor que protege. Arreglado en dos capas (reset de traps
heredados + dejar de señalarlos: salen por fichero-marca y el padre solo espera), con
ancla de regresión que falla contra el código previo.

Nota de proceso: la no-vacuidad de los casos nuevos se probó por mutación (reducir el
check de c a modelo+effort hace fallar el caso de sandbox degradado), y el fichero de
veredictos se dividió al superar el presupuesto de 60s del runner — el remedio que el
propio implementador había anticipado en su informe.
