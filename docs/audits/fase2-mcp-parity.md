# Auditoría de paridad — Fase 2: transporte `codex mcp-server`

**Fecha:** 2026-08-02 · **Método:** enjambre ultracode de 3 agentes (superficie local por
JSON-RPC real sin gastar turnos; código fuente upstream clonado en el tag exacto
`rust-v0.144.4` = commit 8c68d4c, idéntico a la CLI local; matriz de exigencias leída del
propio repo). Capturas crudas y JSONs completos en el scratchpad de la sesión de origen;
este documento es el registro durable.

## Veredicto: VIABLE CON CONDICIONES — y con una corrección al roadmap

La forma de migración que ARCHITECTURE esbozaba (`claude mcp add --scope user … codex
mcp-server`, las skills llamando a las tools directamente) **NO es viable** para las
garantías de tandem. La forma que SÍ lo es: **los wrappers bash se convierten en clientes
MCP** — conservan su interfaz completa (exit codes, artefactos por turno, línea USAGE,
heartbeat) y por dentro hablan ndjson JSON-RPC con un proceso `codex mcp-server` en vez de
lanzar `codex exec`. Las skills no cambian, como prometía el roadmap — pero el beneficio
neto es más estrecho de lo asumido y hay dos regresiones arquitectónicas serias que
resolver antes de decidir.

## Lo que el servidor SÍ da (verificado en fuente, fichero:línea en los findings)

- **Sandbox por llamada**: el tool `codex` acepta `sandbox` (enum read-only /
  workspace-write / danger-full-access) y `approval-policy` como params de primera clase.
- **Todos nuestros pins, por llamada**: el param `config` acepta las claves dotted de
  config.toml — `sandbox_workspace_write.network_access`, `writable_roots`,
  `approvals_reviewer`, `web_search`, y también `model_reasoning_effort` (el effort no es
  param de primera clase pero pasa por ahí).
- **La trampa del fallback silencioso NO existe**: threadId corrupto → error de parseo;
  desconocido → `Session not found`, jamás una sesión nueva en silencio
  (message_processor.rs:463-474). El resultado ecoa el threadId. Mejor que la CLI.
- **`codex-reply` hereda el config CONGELADO de la primera llamada** (mismo objeto de
  thread en memoria, `thread_settings: Default::default()`) — no relee el config del
  usuario: la herencia ES la política pineada de la primera llamada. Equivalente funcional
  del re-pin, con forma distinta.
- **Frescura del veredicto por construcción**: el resultado del call es la respuesta de
  ESE turno (structuredContent {threadId, content}).
- **Usage completo por turno** — pero SOLO por notificaciones `codex/event`
  (TokenCountEvent con input/cached/output/reasoning), no en el resultado. El wrapper
  cliente debe consumir el stream de notificaciones.
- Multiplexación de N threads por conexión (con `_meta.threadId` por notificación),
  cancelación por turno, stdout limpio (logs a stderr), framing ndjson (Content-Length no
  responde).

## Las dos regresiones serias

1. **Los threads mueren con el proceso del servidor.** `mcp-server` NO tiene camino de
   resume desde rollout: tras reiniciar el proceso, todo threadId anterior da "Session
   not found" (thread_manager.rs:1127-1134). Los hilos de tandem hoy sobreviven días
   (deadlocks resueltos por el humano en M15/M17 se reanudaron mucho después) gracias a
   `codex exec resume` sobre rollouts. PREGUNTA ABIERTA CLAVE: ¿el servidor ESCRIBE
   rollouts que `codex exec resume <id>` pueda levantar? Si sí, hay híbrido natural
   (MCP para turnos vivos, CLI para revivir hilos muertos); si no, la durabilidad de
   hilos — pilar del diseño — se pierde.
2. **No existe `--ignore-user-config` en el servidor** (solo en `codex exec`;
   LoaderOverrides.ignore_user_config existe en el crate config pero mcp-server nunca lo
   setea). El config.toml del usuario se relee EN CADA tool-call `codex` — y ojo: los
   `-c` del argv del servidor NO se re-aplican a las sesiones (into_config construye el
   ConfigBuilder solo con el `config` del call). MITIGACIÓN CANDIDATA: arrancar el
   servidor con un **CODEX_HOME propiedad de tandem** (config.toml nuestro + auth
   resuelto — la superficie confirmó que el handshake no exige auth y que CODEX_HOME se
   respeta; queda verificar auth.json/keyring en un turno real) + los pins por llamada
   como cinturón. Sin esa verificación, bloqueante.

## Riesgos nuevos del transporte (no son paridad: son topología)

- Elicitation headless: bajo `approval-policy: never` los paths principales de core
  suprimen approvals (probable, no exhaustivo), pero si una elicitation se emite y nadie
  responde, **el turno queda colgado sin timeout** (exec_approval.rs:118) — el wrapper
  necesita un auto-deny.
- El param `config` es `additionalProperties: true`: una clave renombrada upstream vuelve
  a ser un no-op silencioso — el drift-watch necesita su equivalente MCP (eco de config
  efectiva, o probe sin turno).
- Un servidor stdio compartido para seats ultra concurrentes: ¿serializa turnos?, ¿mezcla
  streams? — sin cubrir por ningún pin actual.
- `deny_unknown_fields` en los params del tool (bien: rechaza `profile` eliminado) pero
  los ejemplos de modelo del schema están rancios; `cwd` relativo se resuelve contra el
  cwd del PROCESO del servidor — pasar siempre absoluto.

## Matriz de paridad (resumen; severidades de la matriz completa)

| Garantía | ¿MCP la da? |
| --- | --- |
| Aislamiento config/.rules del usuario | ❌ directo · ✅ candidato vía CODEX_HOME aislado (verificar auth) |
| Sandbox por rol y por llamada | ✅ param de primera clase |
| Re-pin en continuación | ✅ por herencia congelada (verificar con test de comportamiento) |
| network_access / writable_roots / approvals / web_search / effort | ✅ vía `config` por llamada |
| Frescura del veredicto | ✅ por construcción |
| Anti-fallback de thread + eco de id | ✅ mejor que la CLI |
| USAGE por turno | ⚠️ solo por notificaciones — el wrapper debe ser cliente MCP |
| Durabilidad de hilos entre procesos/sesiones | ❌ hoy — depende de la pregunta de rollouts |
| Exit codes / artefactos / heartbeat / semáforo | ✅ siguen siendo client-side (forma wrapper-cliente) |
| Drift-watch de pins | ⚠️ necesita equivalente (config silenciosa dentro del map) |

## Camino propuesto

1. **M19 `mcp-preflight-probes`**: cerrar los 4 desconocidos con probes de comportamiento
   (algunos gastan UN turno, gateados): (a) ¿el servidor escribe rollouts reanudables por
   `codex exec resume`?; (b) CODEX_HOME aislado con auth real — ¿un turno autentica?;
   (c) prueba de herencia congelada en `codex-reply` (pin en call 1, config.toml hostil,
   verificar el efectivo en call 2); (d) elicitation bajo never en un caso que la fuerce.
2. **M20 `mcp-transport-wrappers`** (contingente a M19): `TANDEM_TRANSPORT=mcp` con doble
   vía en los wrappers, stub de servidor MCP para la suite, migración rol a rol (ask →
   review → implement), drift-probe MCP, y el híbrido de resume si (a) lo permite.
3. Si M19 falla en (a) o (b): la migración se DESCARTA con este documento como razón, y
   la Fase 2 se replantea (p.ej. esperar upstream: ignore-user-config en mcp-server, o
   resume desde rollout).


---

# Resultados M19 — run real con `--spend` (2026-08-02)

Ejecutado con `scripts/mcp-probe.sh --spend` contra la CLI real (codex-cli 0.144.4):
**3 turnos de cuota**, evidencia en `.tandem/state/mcp-probe/20260802T212926.99831/`.

| Probe | Veredicto | Qué quedó probado |
| --- | --- | --- |
| b · home-auth | **PASS** | El `auth.json` copiado a un CODEX_HOME propiedad de tandem AUTORIZÓ un turno real (thread `019fc3f3-…`). La mitigación de que el servidor no tenga `--ignore-user-config` FUNCIONA. |
| c · frozen-inheritance | **PASS** (ver nota) | El `turn_context` de la continuación ecoa `model gpt-5.6-sol`, `effort xhigh`, `approval_policy never`, `sandbox read-only` y el cwd aislado — los valores pineados en la llamada 1 — con un `config.toml` hostil en el home. La herencia congelada de `codex-reply` es real. |
| a · rollout-resume | **PASS** (confirmado a mano) | `codex exec resume <threadId>` levantó el hilo creado vía MCP tras morir el servidor: `thread.started` idéntico al pedido y respuesta = el codeword sembrado en el turno 1. **El híbrido MCP-vivo + CLI-resurrección funciona end-to-end.** Basta con el fichero de rollout: se reconstruyó un CODEX_HOME solo con él. |
| d · elicitation-never | **STATIC** | Supresión total de approvals exec/patch bajo `never`; el cuelgue por aprobación de MCP-tool es alcanzable e irresoluble desde el cliente. |

**Nota honesta sobre (c):** el script emitió `INDETERMINABLE` en el run, y el fallo era
del INSTRUMENTO, no del servidor: macOS exporta `TMPDIR` con barra final, así que el
`cwd` enviado llevaba `//` y el servidor lo devolvía normalizado — el comparador vio un
desajuste que nunca existió. Corregido (canonicalización con `pwd -P`), con ancla de
regresión probada por mutación, y el veredicto material se estableció leyendo la
evidencia archivada, que se commiteó como fixture (`rollout-turn-context.json`).
Por el DAG, (a) quedó `NOT_RUN` en el run y se confirmó después a mano con el rollout
archivado — el tercer turno autorizado.

## Veredicto de la Fase 2: VIABLE — M20 sigue adelante

Las dos regresiones bloqueantes de la auditoría están CERRADAS con evidencia viva:
los hilos sobreviven al proceso del servidor (vía rollout + `exec resume`) y el
aislamiento del config del usuario se logra con un CODEX_HOME propiedad de tandem cuyo
`auth.json` autoriza. La forma de migración sigue siendo la de wrapper-cliente.

**Requisito nuevo y duro para M20**, del cierre estático de (d): una aprobación de
MCP-tool bajo `never` cuelga el turno **sin timeout y sin que el cliente pueda
resolverlo** (el runner descarta el `ElicitationRequest`). El transporte de producción
necesita su propio watchdog por turno — no basta con `approval-policy: never`.


---

# Resultados M20a — run real del transporte (2026-08-03)

Primer uso REAL del transporte MCP tras el merge de v0.27.0: **2 turnos de cuota**,
rol `ask`, hilo `019fc768-e43a-7dd0-acb6-59fb055993fd`.

| Comprobación | Resultado |
| --- | --- |
| Turno 1 vía `codex mcp-server` | **OK** — el modelo respondió y cerró con su marcador |
| Eventos adaptados | **OK** — `thread.started` → `turn.started` → `item.completed` → `turn.completed`, la forma exacta de `codex exec --json` |
| Línea `USAGE:` y ledger | **OK** — los cuatro campos públicos (in 14 046 · out 36), sin `total_tokens` |
| Meta del turno | **OK** — `transport_requested: "mcp"`, `transport_effective: "mcp"` |
| Rollout realojado | **OK** — `~/.codex/sessions/2026/08/03/rollout-…-019fc768….jsonl`, modo 600, en el store REAL del usuario |
| Turno 2 por híbrido `exec resume` | **OK** — sobre el MISMO hilo, citó verbatim el marcador del turno 1 (`MCP-REAL-OK`): memoria real, no un hilo nuevo educado |
| Meta del turno 2 | **OK** — `transport_effective: "exec-resume"`, la auditoría no miente sobre quién habló |

**Conclusión:** la forma decidida en la auditoría (wrapper-cliente, un servidor por turno,
continuaciones por el híbrido, rollout realojado) funciona de punta a punta con cuota
real. M20b (`review`) y M20c (`implement`/swarm) pueden construir sobre esta base.

## Run real de M20b (2026-08-03) — rol `review` por MCP, modo range

- **Forma:** range review real `range-review-m20b` sobre `01b7ca4..e0c493f` (el propio
  commit de M20b), lanzada con `TANDEM_TRANSPORT=mcp` en background — la regla que ese
  mismo commit institucionaliza, aplicada en su primer uso.
- **Narración:** `transport=mcp (codex mcp-server, one server per turn, watchdog 3600s)`
  — el watchdog POR ROL armado con el default de review, no el de ask.
- **Turno end-to-end:** thread `019fc7ab-f44f-7120-a51e-f5c01f156e95`; decenas de
  comandos read-only del revisor sobre el commit anclado; `USAGE:` presente
  (in 148191 · cached 146176 · out 315); verdict entregado y turno cerrado sin
  intervención del watchdog.
- **Meta del turno:** `transport_requested: "mcp"` y `transport_effective: "mcp"`, con
  role review / effort xhigh / sandbox read-only — paridad de artefactos verificada
  sobre un turno real del rol migrado.
- **Veredicto:** REQUEST_CHANGES con 1 Major legítimo — el gate autoriza el ROL completo
  y la plan review de skills/plan/SKILL.md (mismo rol, fuera del alcance declarado de
  M20b) hereda mcp sin su regla de background: registrado como **M21** en el backlog. La
  semántica range se respetó: el hallazgo ES el entregable, cero fix loop.
- **Conclusión:** segundo rol migrado con run real en verde. El transporte no falló en
  nada; el hallazgo es de superficie de gate, no del mecanismo.

## Runs reales de M20c (2026-08-03) — los canarios que cierran la Fase 2 (wrappers)

**Canario implement (workspace-write real por MCP):** turno Sol high real vía
`codex-start.sh implement canary-m20c` con `TANDEM_TRANSPORT=mcp`, workspace y estado
anclados a un repo git de scratch. Evidencia: narración
`transport=mcp (…, watchdog 3600s)` — el default WIDE del rol armado; el turno ESCRIBIÓ
de verdad (`canary-m20c.txt` con el codeword único `M20C-IMPLEMENT-CANARY-lumbre-9427`,
y nada más tocado en el árbol); paridad completa de artefactos
(t1.prompt/reply/events/usage/meta + lateral .mcp.raw + thread + turn); meta
`{"role":"implement","effort":"high","sandbox":"workspace-write",
"transport_requested":"mcp","transport_effective":"mcp"}`; sentinel
IMPLEMENTATION_COMPLETE; USAGE in 14709 · out 108; rollout realojado al store real
(thread 019fc853-1bba-7a71-8463-40326d509ab0).

**Canario image (1 asset real por MCP, foreground por contrato):** turno Sol high real
vía `codex-start.sh image canary-icon` con mcp, en foreground — el contrato del rol
(watchdog default 540s por rol, bajo el cap de Bash; sin override). El turno generó un
PNG REAL con gpt-image-2 (128×128 RGB, redimensionado con `sips` DENTRO del sandbox
workspace-write) en `assets/canary-icon.png`; `IMAGE_READY` como cierre; meta
`{"role":"image","effort":"high","sandbox":"workspace-write","transport_requested":
"mcp","transport_effective":"mcp"}`; USAGE in 28313 · out 77; rollout realojado
(thread 019fc853-bf68-72b2-8edb-366ada850e93).

**Conclusión — FASE 2 (wrappers) COMPLETA:** los CUATRO roles tienen run real en verde
sobre el transporte MCP (ask y su resume híbrido en M20a; review range xhigh en M20b;
implement escribiendo e image generando en M20c). La matriz de watchdog por rol se
observó armada en ambos perfiles (3600 background / 540 foreground). El swarm de ultra
sigue `exec` POR DISEÑO (decisión en ARCHITECTURE, no omisión). Los límites declarados
persisten: un servidor por turno (persistente = v2), sin correlación de IDs del
procesador oficial.
