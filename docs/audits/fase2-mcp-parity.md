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
