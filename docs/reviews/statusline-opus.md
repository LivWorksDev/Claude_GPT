# Review: statusline-opus (v0.15.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/statusline-opus.plan.md (M12 del backlog; tarea 3/6 de la cola autónoma)
- **Rama:** tandem/statusline-opus, apilada sobre tandem/token-accounting (cadena de la
  cola). Aprobación vía `plan-approve.sh` (commit del plan 4f7108e; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 56
  passed, 0 failed (+1 fichero de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK ×3;
  un transitorio no reproducible en la primera invocación, registrado en el log)
- **Modo:** autónomo; implementador: Claude Opus 5 (tandem:implementer),
  IMPLEMENTATION_COMPLETE en t1 sin continuaciones
- **Tokens del run:** plan-review 5 rondas — in 10 237 898 · out 95 682; code review 2
  rondas — in 3 240 163 · out 31 206; implementación: n/a (transporte opus)

## Plan review — 5 rondas → APPROVED (3 → 2 → 3 → 2 → 0)

Ronda 1 (1 P1 + 2 P2, ACCEPTED): un heartbeat terminal reciente enmascara el fallback en el
ciclo de vida NORMAL (plan-review termina → Opus arranca en el mismo minuto; con prioridad
absoluta del terminal, un intento < 15 min jamás mostraría running) → regla "Codex VIVO
gana siempre; entre no vivos, el más reciente"; un orphaned (exento de supresión por edad)
taparía todos los intentos futuros; los tests de corrupción debían asertar "exactamente una
línea y sin opus implement", no solo rc/stderr.

Ronda 2 (1 P1 + 1 P2, ACCEPTED): la estructura "fallback tras los exits" hacía la regla
inalcanzable (terminal reciente y orphaned NO salen — se renderizan) → reestructura a etapa
de SELECCIÓN DE GANADOR con cortocircuito de Codex-vivo; empates a resolución de segundo y
stat fallido sin regla → empates deterministas (Opus running gana a Codex no vivo; Opus
terminal pierde) y degradación explícita. Ronda 3 (3 P2, ACCEPTED): candidato Opus corrupto
no puede suprimir un Codex válido (solo se elimina a sí mismo); pid 0/no numérico =
"desconocido, no orphaned" (conserva el contrato existente); el test de stat necesita un
stub que falle en $SANDBOX/bin, no un PATH vacío (mataría a jq antes). Ronda 4 (2 restos de
texto contradictorio, ACCEPTED). Ronda 5: APPROVED.

## Code review — 2 rondas → APPROVED (hilo fresco)

Ronda 1 (3 Minor, ACCEPTED y arreglados por Fable): un `implement-claude/` VACÍO en el
worktree tapaba el estado válido del principal (la resolución era por existencia de
directorio) → kind 'j' que exige al menos un *.json real + test; tests de ventana a 1 s del
límite (2 s de retraso de CI voltean el resultado) → márgenes de 60 s; README:59 seguía
diciendo "solo aparece con Codex" → reformulada. Ronda 2: APPROVED — "No new findings."

Implementación notable: el bloque de render Codex quedó intacto línea a línea (verificado
con el diff), los 5 tests de statusline existentes pasan SIN modificar, y never-fail ganó
20 payloads rotos del attempt state con control positivo anti-vacuidad.
