# Plan: mcp-transport-ask — primer salto de la Fase 2 (núcleo cliente + rol ask)

**Backlog:** M20a (P2/M, primer tercio del M20/L) · **Fecha:** 2026-08-03 · **Modo:**
autónomo (Cola 4, tarea 2/4) · **Base:** main **7269c8b** (v0.26.0 + fixture
`notifications.ndjson` — el commit del que dependen adaptador y conformance; NO
5d3a0a1, su padre, que no lo contiene).

## Goal

`TANDEM_TRANSPORT=mcp` habilita, SOLO para el rol `ask`, el transporte
`codex mcp-server` en los wrappers — con paridad total de artefactos y contratos:
mismos ficheros por turno (prompt/reply/events/usage/meta), misma línea `USAGE:`,
mismo heartbeat, mismos exit codes, mismo guard anti-fallback. Default `exec`
intacto byte a byte; valor inválido → 64 fail-closed. La decisión arquitectónica
v1 es explícita y honesta: **un servidor por turno** — `codex-reply` solo existe
dentro de una invocación, así que las continuaciones entre invocaciones van por el
híbrido `codex exec resume` que M19 probó end-to-end (mismo CODEX_HOME efímero
reconstruible: basta el rollout). Lo que este salto compra: pins por map `config`
en la llamada, errores tipados de hilo (jamás el fallback silencioso), el
**watchdog por turno obligatorio** (hallazgo d de M19: una aprobación de MCP-tool
bajo `never` cuelga sin timeout y el cliente no puede resolverla), y la base de
cliente compartida para los saltos b/c y el eventual servidor persistente (v2,
fuera de alcance: exigiría puente fifo/socket con riesgo de interleaving — los
frames con diffs inline superan PIPE_BUF).

## Approach

1. **`scripts/_mcp.sh` (nuevo, sourceable como `_pins.sh`)** — el cliente ndjson
   extraído de la experiencia de `mcp-probe.sh` (fifo + fd post-fork + `rpc_send`/
   `rpc_wait` con sondeo `jq fromjson?` + guardias SIN señales que salen por
   fichero-marca — las tres lecciones del run real ya aprendidas: traps heredados
   reseteados, nada de `kill` a jobs bajo `set -m`, rutas canónicas `pwd -P`).
   Funciones:
   - `mcp_home_build` — CODEX_HOME efímero de tandem en TMPDIR canónico:
     `config.toml` espejo de `codex_pins()` SOLO — sin `model` ni effort: viajan
     exclusivamente como params del tool-call (`model` de primera clase, effort
     por el map `config`), que ya son JSON seguro; escribirlos en TOML con el
     writer del probe interpolaría texto sin escapar (los overrides
     TANDEM_*_MODEL admiten comillas y backslashes — el caso hostil de los tests
     existentes entra también al camino MCP). `auth.json` copiado `chmod 600`
     (ausente → die 3 con
     "run `CODEX_HOME=<home> codex login`"); **jamás bajo `.tandem/`**.
     **Ciclo de vida ÚNICO y componible:** los traps no se apilan y `hb_begin`
     REEMPLAZA el trap EXIT (su contrato) — instalar otro en `_mcp.sh` dejaría
     server/home/credencial huérfanos o el heartbeat colgado en running según el
     orden. La rama mcp instala UN solo owner de EXIT/INT/TERM que encadena
     ambos: primero la limpieza mcp (segar grupo, borrar home), después el
     manejo de fallo del heartbeat. Tests de las CINCO salidas (éxito, fallo del
     wrapper, timeout, INT, TERM): estado final del heartbeat Y cero
     procesos/homes supervivientes.
   - `mcp_turn_start <prompt-file> <events-out> <msg-out> <stderr-out>` — servidor
     fresco, handshake, `tools/call codex` con los params espejo (sandbox,
     approval-policy, cwd ABSOLUTO desde `TANDEM_CODEX_CWD`/PWD, map `config` con
     TODOS los pins + effort), **watchdog por turno** (`TANDEM_MCP_TIMEOUT_SECONDS`,
     default **540** — menor que el Bash timeout de 600s de las skills en
     foreground, o el orquestador mataría el turno antes de que el watchdog
     clasifique y limpie; un contrato estático ata ambos valores; validado
     entero positivo → 64):
     vencido → mata el grupo del servidor y DEVUELVE estado de timeout — el
     helper NUNCA hace `exit` después de arrancar un turno: el wrapper lo captura
     bajo `set +e` y ejecuta la contabilidad COMPARTIDA (turn_usage sobre lo que
     el stream alcanzó a traer, `USAGE:`, diagnóstico) ANTES de salir 1 — un
     turno colgado por elicitation jamás cuelga al orquestador NI escapa de la
     contabilidad.
   - `mcp_events_adapt` — un ADAPTADOR real, no una desenvoltura: el stream real
     lleva `params={_meta,id,msg}` con tipos PROPIOS (fixture commiteado
     `tests/fixtures/mcp-0.144.4/notifications.ndjson`, 14 frames del turno real
     de M19). Mapeo explícito: `session_configured` →
     `{"type":"thread.started","thread_id":msg.thread_id}`; `token_count` → se
     RETIENE el último `msg.info.last_token_usage`; `task_complete` → un único
     `{"type":"turn.completed","usage":<retenido>}` con los nombres de campo que
     `turn_usage` suma — construido con EXACTAMENTE los cuatro campos públicos
     del `Usage` de exec (input/cached_input/output/reasoning_output): el objeto
     MCP arrastra `total_tokens`, y como turn_usage retiene todo campo numérico,
     colarlo contaminaría los ledgers con un campo que los de exec no llevan;
     `item_started`/`item_completed` → TRADUCIDOS a la serialización EXACTA de
     `exec_events.rs` de 0.144.4: `item.started`/`item.completed` con
     discriminador **`item.type`** (así aparece en nuestros propios streams
     reales archivados y en ThreadItemDetails del schema oficial — NO
     `item.item_type`, que es el discriminador RANCIO que nuestro
     stream_milestones usa hoy: hallazgo lateral del red-team, un desajuste
     latente preexistente en scripts/_common.sh:283 que este salto corrige,
     aceptando `item_type` solo como compatibilidad); casos de comando/búsqueda
     fixturados desde la fuente, `stream_milestones` y su fixture
     `tests/fixtures/ndjson/happy.ndjson` actualizados, y replay-coverage con un
     evento REAL de exec archivado junto al fixture MCP — la conformance no
     puede pasar con dos esquemas incompatibles;
     `error` → traducido con su mensaje; el resto (`mcp_startup_*`,
     `agent_message*`, `user_message`, `raw_response_item`) va a un lateral
     `.mcp.raw.ndjson` y NO entra al fichero de events. Los extractores quedan
     intactos POR CONFORMANCE PROBADA: replay del fixture real a través del
     adaptador → `turn_usage` devuelve el usage correcto y el selector encuentra
     el thread-id. El resultado del tool (structuredContent.content) se escribe
     en `<msg-out>`.
2. **Validador COMPARTIDO `transport_resolve` en `_mcp.sh`**, llamado por
   codex-start.sh Y codex-resume.sh ANTES de dependencias o mutación de estado
   (`TANDEM_TRANSPORT` ∈ {exec, mcp}, unset = exec, otro → 64 nombrando el
   valor; mcp con rol ≠ ask → 64 en AMBOS wrappers — un resume que cayera en
   silencio a exec con un bogus violaría el fail-closed; tests contra los dos:
   64, cero invocaciones codex, contador de turno sin incrementar).
   **`scripts/codex-start.sh`** — la rama mcp aplica SOLO a `ROLE=ask` en este salto (mcp + otro rol → 64 con
   "role ask only in this hop; see docs/BACKLOG.md M20b/M20c"). El bloque
   `codex exec` actual (líneas ~92-100) se conserva byte-idéntico en la rama exec;
   la rama mcp llama a `_mcp.sh` y todo lo demás — TURN/meta/heartbeat/usage/
   thread-id/last.txt/salida — corre EXACTAMENTE el mismo código posterior (la
   paridad de artefactos hace que no haya un segundo camino que mantener).
   `THREAD_FILE` guarda el threadId que el resultado MCP ecoa (verificado igual:
   ausente → die 1).
3. **`scripts/codex-resume.sh`** — bajo `TANDEM_TRANSPORT=mcp` + ask, la
   continuación usa el HÍBRIDO probado: `codex exec … resume <id>` con los pins de
   siempre y `CODEX_HOME` del proceso SIN tocar (el hilo vive en el CODEX_HOME
   real del usuario cuando lo creó exec… **no**: lo creó el server MCP en el home
   efímero — ver Key decisions: el home del hilo). El guard anti-fallback y toda
   la contabilidad quedan idénticos.
4. **El home del hilo, decisión central — realojo SEGURO:** el servidor efímero
   escribe el rollout en su home efímero, que el cleanup borra. Secuencia
   obligatoria (P1-3): (1) parar el servidor — EOF, wait, grupo segado — ANTES
   de tocar el rollout (el recorder apenda en vivo); (2) COPIAR a un temporal
   oculto DENTRO del directorio destino
   (`${CODEX_HOME:-$HOME/.codex}/sessions/<ruta-fecha>/.tmp.<pid>`) — un `mv`
   desde TMPDIR cruza filesystems y NO es rename atómico; (3) validar (tamaño
   > 0, última línea JSON parseable); (4) rename DENTRO del mismo directorio al
   nombre final con guard de no-sobrescritura (`[ -e ] && die`); (5) borrar el
   origen SOLO tras el éxito. **La credencial jamás se retiene (P1-4):** el
   cleanup borra SIEMPRE `auth.json` y `config.toml`, en todo camino incluido el
   fallo del realojo — solo el rollout puede sobrevivir, en un directorio de
   recuperación modo 700 con fichero a 600 y la ruta en stderr. Test del camino
   exacto: fallo forzado del realojo → auth ausente del disco, rollout
   recuperable. Es la inversa de lo que M19 probó a mano (un rollout basta).
5. **`tests/stub/codex`** — la rama `exec` del stub aprende `resume` sobre
   rollouts que la rama mcp-server escribió (ya lo hace vía CODEX_STUB_MCP_ROLLOUT
   + CODEX_STUB_THREAD_ID: se reutiliza tal cual); knob nuevo mínimo si hace
   falta para el realojo.
6. **Tests (2 nuevos + toques):**
   - `tests/mcp-transport-ask.test.sh` (comportamental, stub): con
     `TANDEM_TRANSPORT=mcp`, `codex-start.sh ask <topic>` produce los MISMOS
     artefactos que exec (mismos nombres t<N>, USAGE: en stderr, thread file con
     el id ecoado, rollout realojado al store del usuario del sandbox); el
     meta.json de un turno EXEC conserva EXACTAMENTE el objeto legacy de cuatro
     claves (anclado por tests existentes — el default es byte-idéntico); un
     turno opt-in añade `transport_requested`/`transport_effective`, y el resume
     híbrido registra `requested: "mcp", effective: "exec-resume"` — nunca un
     "mcp" a secas que falsearía la auditoría; resume tras el start-mcp continúa el hilo por el
     híbrido con anti-fallback verde; transporte inválido → 64; mcp + review →
     64; watchdog corto → exit 1 con grupo segado y artefactos del turno
     preservados; default exec byte-idéntico (argv del stub comparado contra un
     run sin la variable).
   - `tests/mcp-transport-parity.test.sh` (estático + conformance): la rama exec
     de codex-start.sh no cambió (anclas sobre el bloque argv); `_mcp.sh` sin
     heredocs peligrosos ni señales a jobs; los eventos desenvueltos pasan por los
     MISMOS extractores vía REPLAY del fixture real `notifications.ndjson` (los
     14 frames del turno real de M19 atraviesan `mcp_events_adapt` y `turn_usage`
     devuelve el usage correcto; el selector de thread.started también); el
     contrato estático ata el default del watchdog (540) al Bash timeout de las
     skills (600000 ms).
   - **Run real post-merge (paso del orquestador, como en M19):** un start ask
     real con mcp (1 turno) + su resume híbrido (1 turno), con líneas y
     artefactos pegados a la auditoría — el backlog exige un run real por rol.
   - `skills/ask/SKILL.md`: una nota corta de que `TANDEM_TRANSPORT=mcp` existe
     para este rol (opt-in, default exec), sin cambiar ningún comando.
7. **Metadatos (orquestador):** plugin.json → 0.27.0, CHANGELOG, BACKLOG M20a,
   fila de la cola, ARCHITECTURE (párrafo de estado de la Fase 2).

## Key decisions & tradeoffs

- **Un servidor por turno, honesto:** `codex-reply` entre invocaciones es
  imposible (el hilo muere con el proceso) y un servidor persistente exige un
  puente multi-cliente que corrompería frames > PIPE_BUF. v1 usa MCP para el
  turno de arranque y el híbrido exec-resume para continuar — el valor está en
  los pins por llamada, los errores tipados, el watchdog y la base para v2.
- **Realojar el rollout al store real del usuario** (con la secuencia de staging
  del punto 4: server segado → copia a temporal dentro del destino → validación →
  rename intra-directorio — jamás un `mv` cross-filesystem): es la inversa exacta
  del probe a de M19 y hace al hilo un ciudadano normal (resume, `codex-show`,
  reset). Alternativa rechazada: un sessions-store propio bajo `.tandem/` —
  exigiría enseñar a todo el tooling un segundo store, y `.tandem/` es efímero
  por contrato.
- **Paridad por desenvoltura de eventos, no extractores duales:** la rama mcp
  produce el MISMO events-NDJSON que exec y todo el post-proceso es código
  compartido — un solo camino que mantener, y la promesa "byte-compatible donde
  aplique" se cumple por construcción.
- **Watchdog default 540s y el transporte es el DUEÑO del timeout:** menor que
  los 600s de Bash de las skills (que no se tocan) para que clasificación y
  limpieza ocurran dentro del wrapper; los runs en background siguen cubiertos
  porque la barrera espera al wrapper. El contrato estático ata ambos valores.
  Obligatorio e inescapable (hallazgo d).
- **Solo ask en este salto:** el rol sin worktrees, sin barrera de background
  formal y de menor riesgo; review (barrera, promoción) e implement
  (workspace-write, swarm) tienen contratos propios que merecen su propio run.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/_mcp.sh` | NUEVO — cliente ndjson compartido, home efímero, watchdog, adaptador |
| `scripts/_common.sh` | `stream_milestones`: discriminador `item.type` (el real de exec; `item_type` queda como compatibilidad) |
| `scripts/statusline.sh` | El lector de actividad en vivo resuelve `.type // .item_type` (hoy solo lee el rancio: con el fixture migrado, la suite rompería y los streams reales seguirían invisibles) |
| `tests/fixtures/ndjson/happy.ndjson` | Actualizado al discriminador real |
| `tests/statusline-live-activity.test.sh` | La MATRIZ real de actividad (comando, edición, razonamiento, mensaje, búsqueda): casos primarios migrados a `item.type` + UN caso explícito de compatibilidad `item_type` — migrar solo el camino de agent-message dejaría invisible la actividad real con los tests en verde |
| `tests/statusline-x1f-empty-fields.test.sh` | Sin cambios de propósito: sigue enfocado a su regresión de transporte de campos (el fixture compartido migra y el test lo sigue) |
| `tests/fixtures/ndjson/check-drift.sh` | El clasificador de drift resuelve `.item.type // .item.item_type` — hoy clasifica los eventos reales como `-` y sus checks load-bearing quedan meramente advisory; un evento real de exec prueba que las clases disparadas activan los checks |
| `scripts/codex-start.sh` | Flag + rama mcp (solo ask); rama exec byte-idéntica |
| `scripts/codex-resume.sh` | Flag + híbrido exec-resume bajo mcp+ask |
| `tests/stub/codex` | Reuso de la rama mcp-server para el flujo start-mcp/resume-exec |
| `tests/mcp-transport-ask.test.sh` | NUEVO — comportamental |
| `tests/mcp-transport-parity.test.sh` | NUEVO — estático + conformance de extractores |
| `skills/ask/SKILL.md` | Nota de opt-in |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/ARCHITECTURE.md` | v0.27.0 — orquestador |

## Acceptance & proof

- Con `TANDEM_TRANSPORT=mcp`: `codex-start.sh ask <topic>` (stub) produce
  artefactos con paridad (t<N>.prompt/reply/events/usage/meta, USAGE: línea,
  thread file), el rollout queda realojado en el store del usuario del sandbox,
  y `codex-resume.sh` continúa ESE hilo por el híbrido con el guard anti-fallback
  en verde.
- Sin la variable: el argv de exec que recibe el stub es BYTE-IDÉNTICO al actual
  (ancla de no-regresión).
- `TANDEM_TRANSPORT=bogus` → 64 nombrando el valor; `mcp` + rol ≠ ask → 64
  nombrando el salto pendiente.
- Watchdog vencido → exit 1, grupo del servidor segado, artefactos del turno
  (usage incluido si hubo turn.completed) preservados; stderr señala el timeout.
- `turn_usage` y el selector de thread.started funcionan SIN CAMBIOS sobre el
  events-file de la rama mcp (conformance de extractores).
- Cero servidores MCP lanzados cuando el transporte es exec (contador del stub).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- El realojo del rollout toca el store REAL del usuario: solo un fichero nuevo
  con nombre único (fecha+ThreadId), staging dentro del destino y guard de
  no-sobrescritura; en fallo, el rollout va al directorio de RECUPERACIÓN
  700/600 (nunca se queda en el home efímero: la credencial se borra siempre)
  con la ruta en stderr.
- La desenvoltura asume que los eventos internos de `codex/event` tienen la misma
  forma que el NDJSON de exec: los fixtures reales de M19 (rpc.out crudo) son la
  referencia; cualquier desajuste → die 1 señalando el evento, nunca artefactos
  a medias.
- Concurrencia: dos starts mcp simultáneos = dos servidores efímeros
  independientes con homes distintos — sin estado compartido nuevo.

## Out of scope

- M20b (review: barrera background sobre mcp) y M20c (implement/swarm,
  workspace-write); el servidor persistente (v2) y cualquier puente fifo/socket.
- `codex-reply` entre invocaciones; cambios en `_pins.sh` o en el flujo exec.
- Drift-probe del map config (vive en el job de CI de M19); doctor —smoke mcp.
- Metadatos (orquestador).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Server persistente o por turno?** → Por turno (v1 honesto); persistente es
   v2 con su propio análisis de interleaving.
2. **¿Dónde vive el hilo?** → Realojado al store real del usuario (la inversa del
   probe a de M19); `.tandem/` jamás.
3. **¿Continuaciones?** → Híbrido `exec resume` probado; `codex-reply` solo
   intra-invocación (no se usa en este salto).
4. **¿Rama?** → `tandem/mcp-transport-ask` desde el main ACTUAL, que debe
   contener el fixture 7269c8b, con `plan-approve.sh`.
5. **¿Versión?** → 0.27.0; metadatos del orquestador tras la implementación.
