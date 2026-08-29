# Review — exec-watchdog (M24, v0.32.0)

- **Fecha:** 2026-08-29
- **Plan:** `docs/plans/exec-watchdog.plan.md` (M24 — watchdog de turno para el
  transporte exec; origen: informe de campo 2026-08-21, hallazgo A1 + enmienda
  E-A1)
- **Rama:** `tandem/exec-watchdog` off `main` (base 7fbd541, v0.31.0)
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean) · typecheck: n/a (bash) ·
  tests: 85 passed, 0 failed (incluye `tests/exec-watchdog.test.sh` nuevo) ·
  actionlint: OK · proof (`bash tests/verify.sh`): OK — re-ejecutado tras el fix
  del Major del code review
- **Plan review (Sol, xhigh, hilo persistente):** 6 rondas → `VERDICT: APPROVED`
  (cap de 5 ampliado a 6 por gate humano ante el deadlock de la R5)
- **Code review (Sol, xhigh, hilo fresco sin contexto previo):** 2 rondas →
  `VERDICT: APPROVED`
- **Transporte de implementación:** Sol a xhigh (`TANDEM_CRITICAL=1`), sandbox
  `workspace-write`. Anomalía operativa registrada: el turno reestructuró
  `codex-start.sh` mientras ese wrapper lo ejecutaba — bash releyó offsets
  desplazados al terminar el pipeline, la cola del wrapper murió exit 1 y la
  ejecución corrupta truncó el events NDJSON: el ledger de usage del turno se
  recuperó de la narración en vivo del stream. El turno REAL completó
  (`IMPLEMENTATION_COMPLETE`, suite verde en su sandbox). CHANGELOG, version bump
  y la fila de la tabla del backlog: takeover del orquestador (prohibidos al
  implementador por template).

## Hallazgos y disposiciones (condensado)

### Plan review — 6 rondas (la más exigente del proyecto hasta la fecha)

- **R1 `REVISE` — 3 P1 + 2 P2, todos ACEPTADOS:** (P1-1) el grupo propio del
  turno podía sobrevivir a un wrapper interrumpido → dueño compuesto de
  lifecycle; (P1-2) `mcp-transport-parity.test.sh` congela EL FUENTE del bloque
  exec → entra en alcance como única edición nombrada de test existente; (P1-3)
  los lanzamientos foreground documentados de review/implement quedaban fuera del
  watchdog → override explícito `TANDEM_EXEC_TIMEOUT_SECONDS=540` en las líneas
  de comando de las skills, pineado por contract-tests (mecanismo distinto al
  sugerido, mismo efecto); (P2-1) verificación del PGID tras el fork con flag de
  grupo; (P2-2) bucle de deadline POR CONTADOR — un `date` roto no puede volverlo
  infinito.
- **R2 `REVISE` — P1-1(b):** el dueño «limpieza primero, hb_guard después»
  machacaba el exit real con 0 → `rc=$?` capturado a la ENTRADA, patrón mcp.
- **R3 `REVISE` — P2-1(r3):** el dueño mataba sin `wait` → kill-luego-wait de
  `mcp_server_stop`, cosechar ANTES de publicar heartbeat/slot.
- **R4 `REVISE` — P1-1(r4):** carrera nounset — `TURN_GROUP` podía no existir
  cuando el dueño disparase → inicialización antes de armar traps (precedente
  del propio swarm) + expansión defensiva.
- **R5 `REVISE` — P1-1(r5):** publicación no atómica de la propiedad del turno →
  sección crítica con señales de solo-registro (patrón del semáforo de swarm),
  honradas tras publicar; re-probe del grupo en el dueño. RECHAZADO el hook de
  test determinista dentro de la sección crítica (instrumentar el camino
  caliente; el precedente del swarm protege por construcción, sin hook).
- **R6 `APPROVED`:** Sol retiró el hook («not required: the critical-section
  invariant is explicit and follows the existing swarm semaphore pattern»).

### Code review — 2 rondas

- **R1 `REQUEST_CHANGES` — 1 Major, ACEPTADO y corregido por el orquestador:**
  las rutas foreground del implementador Sol (start de plan pequeño y
  continuación) omitían el override 540 y el contract-test congelaba el hueco →
  variantes foreground explícitas en `skills/implement/SKILL.md` + ambos
  contract-tests endurecidos (0→2 exigidos). Gate re-ejecutado en verde.
- **R2 `APPROVED`:** «Both Sol implementer foreground paths now explicitly set
  `TANDEM_EXEC_TIMEOUT_SECONDS=540` … No new issues introduced.»

## Contabilidad del run (ChatGPT quota, tokens)

| Fase | Turnos | In | Out |
| --- | --- | --- | --- |
| Plan review | 6 | 24 059 934 | 218 211 |
| Implement (Sol xhigh) | 1 | 18 157 117 | 47 183 |
| Code review | 2 | 4 059 490 | 29 405 |
| **Total** | **9** | **46 276 541** | **294 799** |

Nota: el ledger del turno de implementación se recuperó de la narración en vivo
(el fichero de events fue truncado por la anomalía del auto-edit del wrapper);
cached/reasoning de ese turno no constan.
