# Plan: council — `/tandem:council`, consejo adversarial de tres modelos para valorar ideas y optimizar estrategias

**Backlog:** M39 (nueva, P2/L) · **Origen:** petición del mantenedor del 2026-10-18 y entrevista
de cuatro decisiones (abajo) · **Fecha:** 2026-10-18 · **Modo:** interactivo (la entrevista se
hizo con el usuario; aprobar este plan, el canario real y el merge son gates humanos) ·
**Base:** `tandem/codex-models-v6` **15502e7** (v0.35.0, todavía sin mergear a main):
`plan-approve.sh` crea `tandem/council` desde ese HEAD, así que la rama queda apilada y se
mergea después de v0.35.0, en orden.

## Goal

tandem ataca planes y diffs, pero no tiene un modo para valorar una idea y optimizar el
procedimiento con el que alcanzar un objetivo. Este plan añade `/tandem:council`: un consejo
adversarial de tres modelos frontera de dos familias. La sesión de Claude Code (Opus 5.5 en
esfuerzo max) lidera: entrevista al usuario, fija un brief, compite con su propia propuesta,
modera y sintetiza. Fable 5.1 en max (subagente Claude persistente entre rondas) y GPT-6
Astra en max (hilo Codex persistente) proponen a ciegas, se contrainterrogan y revisan la
síntesis ronda a ronda hasta consenso o tope. Todos los asientos son de solo lectura; el
resultado es un informe Markdown con la transcripción íntegra en el proyecto. Decisiones del
usuario (2026-10-18): (1) ámbito general, con el proyecto desde el que se lanza como contexto
opcional de solo lectura; (2) el usuario interviene solo al inicio (preguntas + aprobación del
brief) y después el consejo corre solo hasta el final; (3) búsqueda web activada, con fuente
obligatoria para toda cifra; (4) entregable Markdown en el proyecto: informe final +
transcripción completa de las rondas.

## Approach

### 1. Asiento Codex: rol nuevo `council` (Astra, max, read-only)

- **`scripts/_models.sh:34-51`** — asiento nuevo `council` → `gpt-6-astra` (misma rama del
  `case` que `review | ultra-judge`) y la lista de asientos de la cabecera.
- **`scripts/_common.sh:36-66`** — `resolve_role` gana la rama `council)`:
  `CODEX_MODEL="${TANDEM_COUNCIL_MODEL:-$(tandem_default_model council)}"`,
  `CODEX_EFFORT="${TANDEM_COUNCIL_EFFORT:-max}"`, `CODEX_SANDBOX="read-only"`. El comentario de
  uso (línea 28) y el `die` de la línea 63 nombran el rol. Los overrides `TANDEM_REVIEW_*` no
  tocan `council` (variables propias; un test lo fija).
- **`scripts/_common.sh:114-117` y `146-160`** — literal propio
  `TANDEM_EXEC_TIMEOUT_DEFAULT_COUNCIL=3600` y rama `council)` en `exec_timeout_validate`: los
  turnos del consejo corren siempre en background, y un turno max con búsqueda web pasa con
  holgura de los 540 s del default foreground. `TANDEM_EXEC_TIMEOUT_SECONDS` sigue ganando.
- **`scripts/_mcp.sh:119-121` — sin cambios.** El `case` cerrado `ask | review | implement |
  image` ya responde 64 a `council` bajo `TANDEM_TRANSPORT=mcp`, antes de dependencias y de
  estado; un test lo fija (el transporte está roto en la CLI 0.157.1 y M36 lo retira).
- **`scripts/_pins.sh:58-59` — sin cambios.** Un rol read-only conserva `web_search` salvo
  `TANDEM_WEB_SEARCH=off`, que es exactamente lo que el modo confidencial exporta en los turnos
  de Astra.
- **`scripts/codex-start.sh` / `codex-resume.sh`** — las cabeceras (lista de roles) y un
  **recibo de éxito por turno**. Justo después de la última comprobación de éxito — la copia a
  `last.txt` (`codex-start.sh:264`, `codex-resume.sh:263`), la cola de éxito común a todas sus
  ramas de transporte — cada wrapper escribe de forma atómica `<key>.t<N>.ok` con
  `{turn, thread_id, reply_sha256}` (`shasum -a 256` o `sha256sum`, el primero que exista; si no
  hay ninguno, `null`). Ningún camino de fallo lo escribe (hilo equivocado, respuesta vacía, sin
  evento de hilo, codex ≠ 0, watchdog), así que es la única prueba duradera de que ESE turno pasó
  la validación del wrapper. Vale para todos los roles y `codex-reset.sh` lo borra con el resto.
  La skill nunca llama a los wrappers directamente: los invoca `council.sh astra` (§3), que abre el hilo con
  `codex-start.sh council council-<run-id>-g<G> …` si esa generación del target aún no tiene
  hilo, lo continúa con `codex-resume.sh` en otro caso y registra cada turno. El target ata el
  hilo a un run y a una generación (G = 1 al empezar): dos debates nunca comparten hilo, y un
  hilo que el wrapper rechaza se sustituye abriendo la generación siguiente — nunca con
  `codex-reset.sh`, que borra con `rm -f "$STATE_DIR/$KEY."*` (`scripts/codex-reset.sh:42`)
  también los `usage.json` y `meta.json`, es decir, la contabilidad y la evidencia del run.
- **`skills/council/prompts/astra.tpl`** — contiene solo `{{EXTRA}}`. Todo el contenido de una
  fase lo compone `council.sh stage` en un fichero que Astra recibe como extra-file y Fable lee
  con Read: los dos asientos reciben los mismos bytes y la plantilla no añade nada.

### 2. Asiento Claude: `agents/council-fable.md` + gemelo `agents/council-fable-offline.md`

- **Frontmatter:** `name`, `description`, `tools: Read, Grep, Glob, WebSearch, WebFetch` (el
  gemelo offline: `Read, Grep, Glob`), `model: claude-fable-5-1`, `effort: max`, `maxTurns: 50`.
  Cuerpo idéntico byte a byte entre los dos (test de paridad, como `implementer` /
  `implementer-critical`): asiento de solo lectura; lee el fichero de fase que nombra la tarea y
  responde como pide; no lee nada bajo el directorio del run ni bajo `.tandem/` salvo lo que el
  fichero de fase incluye; no revela su modelo (las letras son anónimas).
- **Despacho (en la skill):** `subagent_type: tandem:council-fable` (o `-offline` en modo
  confidencial), `run_in_background: true` y **sin parámetros `model` ni `effort` en la
  llamada**: el de la llamada gana al frontmatter y persiste al reanudar
  (`code.claude.com/docs/en/sub-agents#choose-a-model`), así que el frontmatter es la única
  fuente. ID completo y no el alias `fable`: el alias resuelve a Fable 5 en las sesiones gateway
  de las apps de Claude (`…/model-config#fable-alias-resolution`). Las continuaciones van con
  `SendMessage` al agente registrado, y `SendMessage` nunca se usa como sonda (regla de
  `skills/implement/SKILL.md:188`).
- **Texto de tarea fijo** (anclado por test): «Eres el asiento `<L>` del consejo `<run-id>`.
  Lee completo el fichero `<ruta absoluta>` y responde exactamente como pide.»

### 3. `scripts/council.sh` — el contrato ejecutable del consejo

Un script con subcomandos, bash 3.2 + jq, que sourcea `_common.sh` (`die`, raíces de estado,
`resolve_role`). Rutas: `DOC_DIR="${TANDEM_COUNCIL_DIR:-docs/council}/<run-id>"`, relativa al
proyecto (`CLAUDE_PROJECT_DIR` o `$PWD`), y estado de máquina en
`RUN_DIR=.tandem/state/council/runs/<run-id>/`. `<run-id>` =
`^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]*$`. Códigos de salida: 0 ok · 1 condición no
cumplida · 2 ya existe · 64 uso · 65 integridad · 75 congestión (lock no adquirido, o un turno de Astra del target
aún vivo). Disciplina `${VAR+set}` en toda variable
`TANDEM_COUNCIL_*`: definida y vacía → 64, nunca «sin definir».

**Concurrencia.** `run.json` tiene un único escritor a la vez. Todo subcomando que lo modifica
(también las comprobaciones de topes y las reservas) toma el lock del run — `mkdir
RUN_DIR/.lock`, con un fichero `owner` (pid y `lstart` del proceso) —, LEE el estado dentro del
lock, lo escribe de forma atómica (temporal en el mismo directorio + `mv`, como `usage_persist`
en `scripts/_common.sh:290`) y lo suelta; nunca lo retiene mientras espera a un modelo. La
escritura atómica evita un JSON a medias, pero no dos lecturas-escrituras cruzadas: eso lo evita
el lock. El trap EXIT lo suelta solo si es suyo. Si no se adquiere en
`TANDEM_COUNCIL_LOCK_TIMEOUT` segundos (default 30) → 75, nombrando el lock y su dueño. Un lock
huérfano (solo lo deja un `kill -9` dentro de la sección crítica) se limpia a mano, igual que
los slots del swarm (`scripts/codex-swarm.sh:265`): nunca se reclama automáticamente.

El pin de Fable vive solo en el frontmatter de los dos agentes: `preflight` y `capture` lo
LEEN de `agents/council-fable.md` (comprobando que el gemelo coincide) en vez de llevar un
segundo literal. El único literal de modelo de `council.sh` es el líder esperado
(`TANDEM_COUNCIL_LEADER_MODEL`, default `claude-opus-5-5`).

- **`preflight`** — cero turnos; informa de TODOS los problemas (sin salir al primero) y sale 1
  si hay alguno:
  (a) `TANDEM_COUNCIL_ROUNDS` (default 4): entero positivo;
  (b) `TANDEM_COUNCIL_INTAKE` ∈ {`ask`, `auto`} (default `ask`);
  (c) el modelo/effort efectivos de Astra (`resolve_role council`) existen en `codex debug
  models` (forma real: `{"models":[{"slug":…,"supported_reasoning_levels":[{"effort":…}]}]}`)
  y el modelo admite ese effort; si no, FAIL nombrando `TANDEM_COUNCIL_MODEL` / `_EFFORT`.
  Catálogo no disponible → FAIL (fail-closed: es el único chequeo gratis antes de gastar un
  turno max);
  (d) `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` con `CLAUDE_CODE_SUBAGENT_MODEL` distinto del pin de
  Fable → FAIL (impondría su modelo al asiento);
  (e) `CLAUDE_CODE_EFFORT_LEVEL` definida y ≠ `max` → FAIL (manda sobre el frontmatter de todo
  asiento y sobre la sesión del líder);
  (f) `maxEffortLevel` con valor ≠ `max` en algún settings en alcance — usuario
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`, proyecto `.claude/settings.json` y
  `.claude/settings.local.json`, gestionado en la ruta estándar de la plataforma (verificarla
  contra la doc de settings al implementar; sobreescribible con
  `TANDEM_CLAUDE_MANAGED_SETTINGS` para tests) — → FAIL nombrando el fichero;
  (g) los dos agentes existen bajo la raíz del plugin, sus `model:`/`effort:` coinciden y el
  modelo es un ID completo (un alias `fable|opus|sonnet|haiku|inherit` → FAIL);
  (h) `TANDEM_TURN_EFFORT` definida, con cualquier valor (también vacía o inválida) → FAIL, la
  misma regla que `scripts/codex-doctor.sh:483-494`: `codex-resume.sh:83-85` la aplica DESPUÉS
  de `resolve_role`, así que un export global rebajaría en silencio cada turno sustantivo de las
  fases 2+, y uno inválido haría salir 64 al primero;
  (i) existe `shasum` o `sha256sum` (los sellos, el brief y los recibos dependen de él);
  (j) resumen: líder esperado, Astra modelo/effort, pin de Fable, rondas, entrevista, modo web y
  la cota de turnos de los asientos (ver «Fallos, reintentos y cota»): típico `2 × (2 + R)` en
  max y techo `5 × (2 + R)` en max más `2 + R` recordatorios de Astra en `low`.
- **`init <run-id> [--offline]`** — crea `DOC_DIR` y `RUN_DIR`; un run existente → 2. Escribe
  `run.json`: `run_id`, `created`, `mode` (`web|offline`), `max_rounds`, `letters` (permutación
  aleatoria de {líder, fable, astra} sobre {A, B, C} sacada de `/dev/urandom`: el moderador no
  elige letras), `astra_targets` (`["council-<run-id>-g1"]`; cada reconstrucción de Astra añade la generación
  siguiente), `agents: []`, `astra_turns: []`, `prompts: []`, `captures: []`, `seals: {}`.
- **`seal <run-id> brief|propose|cross`** — `brief`: sha256 de `brief.md` a `run.json` (queda
  congelado: `stage` lo verifica y responde 65 si cambió). `propose|cross`: sha256 de
  `RUN_DIR/sealed/<fase>.md` (la aportación del líder). Si ya existe alguna respuesta de asiento
  de esa fase → 65: es la prueba ejecutable de que el líder escribió la suya antes de ver las
  de los asientos.
- **`record-agent <run-id> <agent-id> <output-file>`** — añade
  `{agent_id, output_file, recorded}` a `agents[]` (el último es el asiento vigente; una
  reconstrucción añade otro) y valida que `output-file` existe (fichero o symlink).
- **`astra <run-id> <fase> [--reminder]`** — el ÚNICO camino por el que la skill lanza un turno
  de Astra, y el dueño de su ciclo de vida. Toma el último intento preparado por `stage` para la
  letra de Astra en esa fase (o su recordatorio) y llama a `codex-start.sh` si la generación
  vigente del target aún no tiene hilo o a `codex-resume.sh` si lo tiene, siempre con el rol
  `council` y `astra.tpl`. Un turno sustantivo se lanza con `TANDEM_TURN_EFFORT` ELIMINADA del
  entorno (`env -u`), así que corre al effort del rol aunque alguien la haya exportado; un
  recordatorio, con `TANDEM_TURN_EFFORT=low` y `TANDEM_EXEC_TIMEOUT_SECONDS=540`.
  - **Reserva y lanzamiento, en UNA sola sección crítica (bajo el lock):** primero recupera las
    entradas `running` del target (abajo); si queda alguna viva → 75, y si queda alguna
    `bloqueada` → 65, sin lanzar nada. Después comprueba los topes (un tercer sustantivo o un
    segundo recordatorio del mismo asiento en la misma fase → 65), añade a `astra_turns[]`
    `{fase, intento, tipo: sustantivo|recordatorio, target, prompt_sha256, estado: "running",
    turn_before, launch_token, driver: {pid, lstart}, inicio}` — con `turn_before` = el
    contador `$KEY.turn` en ese momento y `launch_token` aleatorio (de `/dev/urandom`) y único
    por lanzamiento —, lanza el wrapper como hijo en su propio grupo de procesos (`set -m`) con
    `exec -a council-astra-<launch_token> bash <wrapper> …`, de modo que el argv del wrapper
    lleva el token (verificado en bash 3.2.57: el argv queda `council-astra-<token>
    …/codex-resume.sh council <target> …`; con un `bash -c` de un solo comando, bash hace
    `exec` del comando y el token se pierde, por eso el hijo es siempre `bash <wrapper>`),
    anota `wrapper: {pid, lstart}` y solo entonces suelta el lock. Lanzar y registrar en la
    misma sección crítica cierra la ventana del hijo sin registrar: si el driver muere ahí con
    `kill -9`, el lock queda huérfano y todo subcomando del run responde 75 hasta que una persona
    lo limpie; con TERM/INT, su trap reenvía TERM al hijo, espera, anota el desenlace y suelta el
    lock.
  - **Turno (sin lock):** espera al wrapper. Sus traps INT/TERM/HUP reenvían TERM al wrapper y
    esperan a que salga: el wrapper ya convierte TERM en su salida 143
    (`scripts/codex-resume.sh:209`) y su guarda EXIT mata el grupo de codex
    (`scripts/codex-resume.sh:166-180`, `kill_group_term_kill`; la misma guarda en
    `codex-start.sh:137`).
  - **Cierre (bajo el lock):** `turno` = `turn_before + 1` si el contador avanzó — los dos
    wrappers lo incrementan tras sus validaciones y antes de llamar a codex
    (`codex-start.sh:80-82`, `codex-resume.sh:105-111`); sin cambio no hubo turno. `estado:
    done` solo con exit 0 Y recibo `t<turno>.ok` (§1) cuyo `reply_sha256` coincide con el
    `reply.txt`; `failed` en cualquier otro caso. Sale con el exit del wrapper.
  - **Recuperación automática de una entrada `running`** (la hace, bajo el lock, el subcomando
    que la encuentra), solo si tiene el wrapper registrado. Está viva si vive el driver o el
    wrapper — pid y `lstart` coinciden, así que un pid reutilizado no cuenta — o si algún
    proceso lleva en su argv una de las tres firmas del turno: `council-astra-<launch_token>`
    (el wrapper de ESE lanzamiento, único por lanzamiento), `codex-start.sh council <target>` o
    `codex-resume.sh council <target>` (cualquier wrapper vivo del target, también mientras se
    inicializa y antes de llamar a codex; ninguno puede ser del que recupera, que aún no ha
    lanzado nada) y el `--output-last-message` de ese turno, `<key>.t<turn_before+1>.reply.txt`
    (codex, también huérfano tras un `kill -9` del wrapper). El escaneo toma UNA instantánea de
    `ps -A -ww -o pid= -o command=` en un fichero temporal y la compara dentro del propio
    proceso (`case` de bash, sin un `grep` que lleve la firma en su argv), excluyendo el pid
    del que recupera: ni él ni sus subprocesos de sondeo cuentan como vivos. El hijo entre el
    `fork` y el `exec` no necesita firma propia: solo existe dentro de la sección crítica, es
    decir, con el lock tomado o huérfano, y entonces la recuperación no corre.
    Viva → sigue `running`. Muerta → `done (recuperado)` SOLO con el recibo `t<turn_before+1>.ok`
    y un sha256 que coincide; `interrupted` si el contador no avanzó (no hubo turno) o si avanzó
    uno sin recibo (turno rechazado o cortado: la igualdad de bytes con `last.txt` no prueba
    nada, porque un rechazo puede repetir bytes). Cualquier otra combinación — liveness
    imposible de establecer (sin `ps`), contador que avanzó más de uno, o una entrada sin el
    wrapper registrado (solo existe si alguien limpió un lock huérfano) — → `bloqueada`: nada se
    lanza en ese target hasta que una persona lo resuelva con `unblock`.
  - Los turnos `failed` e `interrupted` nunca se publican, pero su `usage.json`, si existe,
    cuenta en `metadatos.md`: la cuota se gastó igual.
- **`unblock <run-id> <target>`** — solo a mano, y desde la skill únicamente si el usuario lo
  pide: vuelve a comprobar la liveness de las entradas `bloqueada` del target con las tres
  firmas; si algo vive → 75; si no, las clasifica con la misma evidencia (contador + recibo) y
  anota `resuelta a mano`. Un contador que avanzó más de uno sigue sin resolverse (65) y exige
  revisar el estado a mano.
- **`stage <run-id> <fase> <letra> [--with-history | --reminder]`** — fases `propose`, `cross`
  y `round-<N>`. Escribe `DOC_DIR/prompts/<fase>-<letra>.a<K>.md`, con K el siguiente intento
  de esa fase y letra (1 la primera vez): un intento nunca se sobreescribe, y un reintento o una
  reconstrucción crean el intento siguiente con las mismas entradas de fase. Hay como mucho dos
  intentos por fase y letra (un tercero → 65, el tope de «Fallos, reintentos y cota»), y
  `run.json` registra cada uno (`prompts[]`: fase, letra, intento, ruta, sha256, con historia o
  no). El fichero concatena byte a byte `skills/council/prompts/seat-rules.md`, la plantilla de
  fase (`phase-propose.md`, `phase-cross.md` o `phase-round.md`), una cabecera con la letra del
  asiento y su próximo ID libre de objeción, y las entradas de la fase, cada una bajo una línea
  delimitadora fija `===== <etiqueta> =====` sin nombres de modelo. Entradas: propose → brief;
  cross → brief, la propuesta propia y las otras dos (de `DOC_DIR/1-propuestas/`); round-N →
  brief, `sintesis-v<N>.md`, `auditoria-v<N>.md`, `registro.md`, `diff -u` v<N-1>→v<N> (si
  N > 1) y la lista de los P1/P2 propios aún abiertos (calculada por el mismo código que
  `status`). `round-<N>` exige `auditoria-v<N>.md` sin ninguna línea `NO CONFIRMA` (en modo
  offline, con la línea `- OFFLINE: no aplica`); si no, 1. `round-*` solo para las dos letras
  revisoras (la del líder → 64). `--with-history` antepone las salidas publicadas del propio
  asiento, en orden (reconstrucción). `--reminder` escribe en su lugar
  `prompts/<fase>-<letra>.a<K>.reminder.md`: `nudge.md` más la lista de lo que FALTA en la
  respuesta del intento vigente, calculada con el mismo parser (sentinel, `VERDICT:`,
  `RIESGO RESIDUAL:` junto a un APPROVED, líneas de estado de los P1/P2 propios); uno por fase y
  letra. Entrada ausente → 1 nombrando el fichero; hash del brief distinto → 65. Imprime la
  ruta.
- **`capture <run-id> <fase> [--reminder] [--manual]`** — el canal de Fable; lo capturado
  queda ligado al intento vigente de la letra de Fable en esa fase (`captures[]` de `run.json`)
  y una captura más allá del tope de la fase → 65. Lee el `output_file` del
  agente vigente (un transcript JSONL; el harness lo enlaza a
  `~/.claude/projects/<proyecto>/<sesión>/subagents/agent-<id>.jsonl`) desde la línea
  `cursor + 1`, con el cursor en `RUN_DIR/fable.cursor` (0 para un agente nuevo):
  - **modelo:** cada línea `assistant` del tramo lleva `message.model` y debe ser el pin de
    Fable, exacto o con sufijo de fecha `-<8 dígitos>`; cualquier otro valor, o ninguno → 65
    sin escribir respuesta. Caza un modelo forzado, un tipo de agente equivocado o un cambio de
    modelo silencioso.
  - **respuesta:** la última línea `assistant` del tramo con un `tool_use` llamado
    `SubagentHandback` → su `input.message`; si no hay ninguna, los bloques `text` del último
    `message.id` con texto y sin `tool_use`. Se escribe fiel byte a byte (`jq -j`) en
    `RUN_DIR/fable.<fase>.a<K>[.reminder].reply.md`. Ninguna → 1 (turno sin terminar o formato cambiado).
  - **uso:** deduplicado por `message.id` — el transcript real repite cada mensaje de la API en
    varias líneas con el mismo `usage` (103 líneas / 57 ids en la captura de referencia de este
    host) — y suma de `input_tokens`, `cache_read_input_tokens`,
    `cache_creation_input_tokens` y `output_tokens` → `RUN_DIR/fable.<fase>.a<K>[.reminder].usage.json`.
  - **auditoría de lecturas:** un `tool_use` Read/Grep/Glob cuyo input apunta bajo `DOC_DIR` o
    `RUN_DIR` (salvo el fichero de fase propio) se anota como anomalía en `run.json`, sin
    bloquear.
  - El cursor solo avanza con éxito. `--manual`: el líder escribió él mismo el fichero de
    respuesta a partir del resultado del Agent (degradación visible tras un `capture` 1); queda
    registrado `capture: transcrito` y `modelo: no verificado` para ese intento.
- **`publish <run-id> <fase>`** — la barrera entre fases. Exige el sello del líder
  (propose/cross), un turno sustantivo de Astra en estado `done` del intento vigente de su letra
  y una captura de Fable del intento vigente de la suya; publica solo eso, más el recordatorio
  `done` de ese mismo intento si lo hubo, concatenado tras la respuesta que completa. Un turno
  `failed` o `interrupted`, o de un intento anterior, nunca se publica (el de hilo equivocado deja
  su `t<N>.reply.txt` en disco a propósito: `tests/resume-fallback-guard-full.test.sh`). Cada
  turno publicado exige además su recibo `t<N>.ok` con el `reply_sha256` del fichero que se
  publica: un `done` sin recibo o con otro sha → 65. Escribe
  `DOC_DIR/1-propuestas/<letra>.md`, `2-contrainterrogatorio/<letra>.md` o
  `rondas/r<N>-<letra>.md`; un destino existente → 2; escribe en temporales y renombra. La
  procedencia (intento, turnos, capturas, capturado/transcrito, sha256) va a `run.json`, nunca a los
  ficheros publicados (que no revelan identidades). Auditoría de lecturas de Astra: un
  `item.command` de `t<N>.events.ndjson` que nombra `DOC_DIR`, `RUN_DIR` o
  `.tandem/state/council` → anomalía en `run.json`, sin bloquear (Astra lo recibe todo en
  línea y no necesita leer ahí).
- **`ledger <run-id>`** — completitud de `DOC_DIR/registro.md`: cada ID de objeción de toda
  respuesta publicada aparece en exactamente una fila; disposición ∈ {`ACEPTADA`, `RECHAZADA`,
  `ABIERTA`}; la severidad es la que declaró su autor (el moderador no puede rebajar un P1).
  Sale 1 listando cada problema.
- **`status <run-id> [--metadata]`** — `PHASE: …` derivada de lo que hay en disco y después
  `STATUS: CONSENSO` (exit 0) o `STATUS: SIN_CONSENSO` (exit 1), con un motivo por línea. Hay
  consenso si en la última ronda con las dos respuestas revisoras publicadas se cumple todo:
  (1) las dos terminan en `VERDICT: APPROVED` y traen una línea `RIESGO RESIDUAL:`; (2) ningún
  P1/P2 de un revisor está en `NO RESUELTA` o `PENDIENTE` (estado = la última línea de estado
  que su autor emitió desde su creación o su último `REABRE`; sin ninguna → `PENDIENTE`); (3)
  todo `RESUELTA` sobre una objeción que el registro RECHAZÓ trae motivo no vacío (conceder
  exige nombrar el argumento); (4) `ledger` pasa; (5) no hay ninguna fila P1 `ABIERTA`; (6) la
  auditoría de la síntesis revisada en esa ronda (`auditoria-v<N>.md`) existe y no tiene ninguna
  línea `NO CONFIRMA` (en modo offline: `- OFFLINE: no aplica`). Un APPROVED que contradice (2)
  se informa como incoherencia y cuenta como REVISE. `--metadata` copia byte a byte la síntesis
  revisada en la última ronda a `DOC_DIR/estrategia-final.md` y escribe además
  `DOC_DIR/metadatos.md`: letras → modelo/effort con su evidencia (Astra: el
  `t<N>.meta.json` de cada turno; Fable: los modelos de cada captura; líder: autodeclarado),
  rondas y veredictos, anomalías (recordatorios, transcripciones, reconstrucciones, lecturas
  fuera de alcance) y tokens (Astra: la suma de los `t<N>.usage.json` de todas las generaciones
  del target, cada fichero una vez, también los de turnos `failed`/`interrupted`; Fable: las
  capturas; líder: «no medido»).

**Formatos de línea** (definidos en `seat-rules.md`, parseados por `ledger` y `status`):
- objeción: `- [B-3] [P2] <título>` + subviñetas `Escenario:`, `Evidencia:` (URL o
  `fichero:línea`) y `Propuesta:`. La letra es la del propio asiento y el número crece por
  asiento a lo largo del run (`stage` da el siguiente libre).
- estado de una objeción propia: `- [B-3] RESUELTA: <motivo>` / `- [B-3] NO RESUELTA: <motivo>`.
- reabrir: `- [REABRE B-3] <argumento nuevo>` (solo IDs propios).
- fila del registro: `| B-3 | P2 | ACEPTADA | <dónde / por qué> |`.
- línea de auditoría: `- [F2] VERIFICADA <url> — <cifra o afirmación>` (o `NO ACCESIBLE`, o
  `NO CONFIRMA`).
- sentinels: propose → última línea `ENTREGA: PROPUESTA`; cross → `ENTREGA: CONTRAINTERROGATORIO`;
  ronda → `VERDICT: APPROVED` o `VERDICT: REVISE`.

**Fallos, reintentos y cota.** Por fase y asiento hay como mucho dos turnos sustantivos (el
original y un reintento) y un recordatorio. Un turno de Astra `failed` se reintenta una vez con
el mismo prompt si el hilo sigue siendo válido; si el wrapper rechazó el hilo, el reintento es
una reconstrucción: generación nueva del target y `stage --with-history` (intento siguiente). Un
Fable perdido con su sesión, o cuya respuesta no llega, se reconstruye igual (agente nuevo,
`--with-history`, `record-agent`). Un segundo fallo del mismo asiento en la misma fase es FAILED
terminal con el estado preservado, y los topes son ejecutables: `stage` no prepara un tercer
intento, `astra` no lanza un tercer sustantivo ni un segundo recordatorio y `capture` no captura
más allá del tope (65). Cota que muestran el preflight y el gate del brief: típico
`2 × (2 + R)` turnos max (12 con R = 4); techo `5 × (2 + R)` turnos max — Fable: sustantivo,
reintento y recordatorio, los tres en max porque su effort vive en el frontmatter; Astra:
sustantivo y reintento — más `2 + R` recordatorios de Astra en `low` (techo 30 + 6 con R = 4).
Los contadores viven en `run.json`, así que sobreviven a una recuperación.

### 4. `skills/council/SKILL.md` — el protocolo del líder

**Frontmatter:** `name: council`, `description` (cuándo usarla; NO para planes, diffs ni
código → `tandem:plan` / `tandem:review` / `tandem:ultra`; NO para una segunda opinión rápida →
`tandem:ask`), `argument-hint: "[idea y objetivo]"` y `effort: max`. **Sin `model:`**: dura solo
el resto del turno en curso (`…/skills#frontmatter-reference`) y el debate ocupa varios turnos,
así que cambiaría de líder a mitad del run.

0. **Preflight.** `council.sh preflight`. El líder declara el ID de modelo que figura en su
   system prompt; si no es `TANDEM_COUNCIL_LEADER_MODEL`, para y explica cómo cambiarlo
   (selector de modelo o `/model`), nunca sigue con otro líder. Elige el run id y ejecuta `init`.
1. **Entrevista** (`TANDEM_COUNCIL_INTAKE=ask`, el default y la elección del usuario; NO lee
   `TANDEM_AUTONOMOUS`). AskUserQuestion, hasta cuatro preguntas por llamada con respuesta
   recomendada, solo sobre lo que cambia la estrategia: objetivo medible, horizonte, recursos,
   restricciones, qué se ha probado ya, qué no es negociable, criterio de éxito y qué ficheros
   del proyecto son contexto. Escribe `brief.md` (secciones fijas + Supuestos). Gate: el usuario
   aprueba el brief Y confirma que la sesión corre en el modelo líder con esfuerzo max (se le
   muestra el máximo de turnos del preflight); después `seal brief`. Con `auto`: sin preguntas,
   supuestos en el brief, y si el objetivo y el criterio de éxito no se pueden derivar sin
   inventarlos, para y pide un brief completo.
2. **Fase 1 — propuestas a ciegas.** El líder escribe su propuesta en
   `RUN_DIR/sealed/propose.md` y ejecuta `seal propose` ANTES de lanzar a los asientos. Después
   `stage propose` para cada asiento y, en el mismo mensaje, Astra (`council.sh astra <run-id>
   propose` con Bash en background) y Fable (Agent en background con el texto de tarea fijo),
   seguido de `record-agent`. Barrera dura: las dos notificaciones. Luego `capture propose`; si
   falta algo, `stage propose <letra> --reminder` y un recordatorio por asiento (Astra:
   `council.sh astra <run-id> propose --reminder`; Fable: `SendMessage` nombrando ese fichero y
   `capture propose --reminder`); un turno fallido o perdido sigue «Fallos, reintentos y cota»;
   finalmente `publish propose`.
3. **Fase 2 — contrainterrogatorio.** El mismo patrón con `sealed/cross.md` + `seal cross`,
   `stage cross` (cada asiento recibe las otras dos propuestas por letra), `council.sh astra
   <run-id> cross` y `SendMessage`, `capture cross` y `publish cross`.
4. **Síntesis v1 y su auditoría.** El líder escribe `sintesis-v1.md` (secciones fijas) y
   `registro.md` disponiendo cada objeción; `ledger` debe pasar. Después audita con WebFetch las
   fuentes de las cifras que sostienen decisiones de la síntesis y escribe `auditoria-v1.md`
   (formato de línea de §3). Un `NO CONFIRMA` obliga a corregir la síntesis y a auditar de
   nuevo antes de lanzar la ronda: `stage round-1` lo exige. En modo offline,
   `- OFFLINE: no aplica`, y las cifras que no vienen del usuario ni del proyecto quedan como
   SUPUESTO.
5. **Rondas 1..R.** `stage round-<N>` para los dos revisores → `council.sh astra <run-id>
   round-<N>` y `SendMessage` a Fable en paralelo (background) → barrera → `capture round-<N>`
   → recordatorio si falta el VERDICT, el `RIESGO RESIDUAL` o alguna línea de estado →
   `publish round-<N>` → el líder dispone en `registro.md` las objeciones nuevas y responde a
   cada `REABRE` → `ledger` → `status`. CONSENSO → paso 6. Si N = R → paso 6 con SIN_CONSENSO.
   Si no, `sintesis-v<N+1>.md`, su `auditoria-v<N+1>.md` y la ronda siguiente.
6. **Informe.** `status --metadata` (que copia la síntesis revisada en la última ronda a
   `estrategia-final.md`, byte a byte) y el líder escribe `informe.md` con secciones fijas:
   resumen ejecutivo; la estrategia (enlace a `estrategia-final.md`: el informe la resume, nunca
   la reescribe ni la corrige — un cambio después de la última ronda sería un texto que ningún
   revisor aprobó); por qué esta y no las alternativas; supuestos (verificado con fuente / por
   validar + experimento mínimo); riesgos y mitigaciones; métricas, umbrales y criterios de
   abandono; primeros 30 días; decisiones pendientes (las ABIERTAS); disidencias (literales de
   los asientos); estado (CONSENSO o SIN_CONSENSO con los motivos de `status`); enlace a
   `metadatos.md`.

**Líneas rojas:** los asientos nunca escriben y el líder nunca edita la respuesta de un asiento
(solo `capture`/`publish` las mueven; `--manual` es la única excepción y es visible); nunca se
declara consenso sin `status` = CONSENSO; nada se commitea ni se pushea (el usuario decide qué
hacer con `docs/council/`); los turnos de Astra solo por `council.sh astra` — nunca
`codex-start.sh`/`codex-resume.sh` directos, nunca `TANDEM_TRANSPORT` ni `TANDEM_TURN_EFFORT`
en la skill, nunca `codex-reset.sh` sobre un target del consejo; ni `model` ni `effort` en la
llamada Agent, y todo turno de Fable nombra un prompt preparado por `stage`; nunca
`SendMessage` como sonda; la notificación de Bash y la del agente son barreras duras;
`capture` 65 o un tope de «Fallos, reintentos y cota» → FAILED terminal con el estado
preservado. Un asiento Fable cuya sesión ya no es la actual se trata como perdido
(`skills/implement/SKILL.md:188`) y se reconstruye. Invocada con un run id existente, `status`
dice la fase y el run se retoma desde ahí.

### 5. Doctor, documentación y versión

- **`scripts/codex-doctor.sh`** (bloque de la línea 220) — línea nueva
  `council:     model=… effort=… sandbox=read-only (pinned) · claude seat=<modelo>/<effort>
  (agents/council-fable.md)`, con los valores del asiento Claude leídos del frontmatter con
  `sed`; `smoke_add` del modelo de council (se deduplica con Astra: ningún turno extra con los
  defaults).
- **README** — fila en la tabla de skills, sección «Modo consejo» y fila en la política de
  modelos. Requisitos: Opus 5.5 + max por sesión (`max` no se acepta en `effortLevel` ni en
  `modelSettings`: selector o `/effort max`); plugin actualizado y sesión nueva para que el
  agente se registre. Coste: según el plan, Fable puede facturar a créditos de uso
  (`…/model-config#fable-and-usage-credits`). Además: modo confidencial, variables y aviso de
  que nada se commitea (cuidado con ideas confidenciales en repos públicos).
- **ARCHITECTURE** — sección «Consejo» con las decisiones de abajo.
- **CHANGELOG** 0.36.0; **`plugin.json`** 0.36.0 (la descripción menciona el consejo);
  descripción de **`marketplace.json`** ídem.
- **BACKLOG** — fila M39 (`planificada` → `hecha (v0.36.0)` al mergear), entrada completa y nota
  en «Orden de ataque» (priorizada por el mantenedor el 2026-10-18).

### 6. Tests (con el stub, nada real)

- **`tests/stub/codex`** — rama `debug models`: imprime `$CODEX_STUB_MODELS_JSON` (ruta a un
  fichero) o un catálogo propio con la forma real (astra/sol: low…ultra; luna: low…max); no
  avanza el contador de exec; `CODEX_STUB_DEBUG_RC` sigue aplicando.
- **Nuevos:** `tests/council-role.test.sh`, `council-preflight.test.sh`, `council-run.test.sh`
  (init/seal/stage/publish), `council-capture.test.sh`, `council-ledger.test.sh`,
  `skill-council-contract.test.sh` y `agent-council-parity.test.sh`. **Actualizados:**
  `tests/models-defaults.test.sh` (asiento y rol; `unset TANDEM_COUNCIL_MODEL` en `role_model`) y
  `tests/doctor-env-matrix.test.sh:345-346` (línea de council).
- **Fixture de captura** `tests/fixtures/council/subagent-transcript.jsonl`, DERIVADA DE UN
  TRANSCRIPT REAL de este host (Claude Code 2.1.302 desktop, 2026-10-18; p. ej.
  `~/.claude/projects/-Users-myum-Documents-LIVWORKS-CLAUDE-GPT/5f39c87c-11e7-438f-a8b7-a964aa45cc01/subagents/agent-abee3f1d647cbbf3e.jsonl`).
  Conserva claves, tipos, la repetición de `message.id` con `usage` idéntico y el `tool_use`
  `SubagentHandback` con `input.message`; sustituye los valores de texto, thinking e input por
  marcadores y `message.model` por el pin de Fable (el caso de discrepancia conserva el
  `claude-haiku-5-5` real). `tests/fixtures/council/README.md` registra el comando de
  derivación. La respuesta final en bloques de texto y la continuación (segundo turno añadido)
  son SINTÉTICAS y se rotulan así: las valida el canario (lección de M20a: un test construido con
  la forma de salida supuesta valida la suposición, no la conversión).

## Key decisions & tradeoffs

1. **Rol Codex propio `council`** frente a reutilizar `ask` con overrides de entorno. Propio: sus
   pins (Astra, max, read-only, watchdog 3600) se re-fijan solos en cada resume; con `ask` + env,
   un resume sin el override bajaría en silencio a xhigh con el watchdog de 540 s. Coste: más
   superficie (doctor, tests, cabeceras).
2. **Fable como subagente de plugin** frente a `claude -p`. Subagente: canal nativo, persistente
   con `SendMessage`. Con `claude -p`, Fable factura a créditos de uso sin preguntar cuando aplica
   (doc) y se anida un Claude Code dentro de otro. Coste: el agente nuevo no se recarga en caliente
   (sesión nueva) y la captura depende del formato del transcript.
3. **ID completo `claude-fable-5-1`** frente al alias `fable` (que resuelve a Fable 5 en las
   sesiones gateway). Coste: el próximo cambio de generación edita dos ficheros, atados por el
   test de paridad.
4. **Ni `model` ni `effort` en la llamada Agent.** El frontmatter es la única fuente: la llamada
   le ganaría y persistiría en las continuaciones.
5. **El líder no se puede fijar desde un plugin.** Autodeclaración + confirmación en el gate del
   brief + `effort: max` en el frontmatter de la skill; `model:` no, porque solo dura un turno.
6. **Opus compite y sintetiza, pero no vota.** El consenso es de Fable y Astra y lo dictamina
   `council.sh status`, no el moderador. Alternativa descartada: que Opus vote (mayoría de 2/3):
   dos asientos Claude podrían imponerse al único de otra familia, y el moderador aprobaría su
   propia síntesis.
7. **Canal fiel byte a byte.** Astra por los ficheros del wrapper; Fable por la captura del
   transcript (modelo verificado en runtime, uso deduplicado). Formato no reconocido →
   degradación visible (`--manual`, «no verificado»); otro modelo → FAILED. Alternativa
   descartada: que el moderador retipee las respuestas de Fable — es contendiente y podría
   debilitar el texto de un rival, aunque fuera sin querer.
8. **A ciegas por orden de publicación y sello del líder, no por sandbox.** Las lecturas no se
   pueden prohibir (el read-only de Codex y el Read de Fable leen todo el disco). Se auditan
   (eventos de Codex, `tool_use` del transcript) y se muestran como anomalía, sin bloquear.
9. **Anonimato.** Letras A/B/C por permutación aleatoria del script durante todo el run; se
   revelan en `metadatos.md` al final.
10. **Registro ejecutable con formatos de línea estrictos** frente a una convergencia juzgada por
    el LLM. Coste: fragilidad de formato, mitigada con recordatorios baratos (uno por asiento y
    fase).
11. **Informe y transcripción en `docs/council/`** (versionable, decisión del usuario); estado de
    máquina en `.tandem/` (gitignorado). Nada se commitea.
12. **Tope de 4 rondas** (no las 5 del plan): cada ronda son dos turnos max. Configurable.
13. **Entrevista interactiva por defecto (decisión del usuario), sin leer `TANDEM_AUTONOMOUS`.**
    En el entorno del usuario esa variable vale 1 de forma permanente y anularía la entrevista que
    ha pedido. `TANDEM_COUNCIL_INTAKE=auto` cubre el uso desatendido.
14. **Solo transporte exec** (M36 retira MCP).
15. **Astra en `max`, no `ultra`.** El catálogo describe `ultra` como «maximum reasoning with
    automatic task delegation»: delegación fuera del control y de la contabilidad de tandem.
    `TANDEM_COUNCIL_EFFORT=ultra` queda como opción explícita.
16. **Web activada con fuente obligatoria.** Modo confidencial = `TANDEM_WEB_SEARCH=off` en los
    turnos de Astra + gemelo offline de Fable sin herramientas web (garantía del allowlist, no de
    una instrucción).
17. **Un solo `council.sh` con subcomandos** frente a varios scripts. Comparten rutas, `run.json`
    y el parser de líneas: el mismo código calcula los P1/P2 abiertos en `stage` y en `status`.
18. **Turnos de Astra solo por `council.sh astra`**, con el exit del wrapper y el número de
    turno registrados por máquina, frente a llamar a los wrappers desde la skill. Publicar por la
    mera presencia de un `reply.txt` promovería respuestas que el wrapper rechazó (el turno de
    hilo equivocado deja el suyo en disco a propósito). Además es el único sitio que decide el
    effort de cada turno: `env -u TANDEM_TURN_EFFORT` en los sustantivos, `low` en los
    recordatorios. Coste: un subcomando más.
19. **Auditoría de fuentes antes de cada ronda, no tras el consenso.** Una cifra decisiva
    desmentida después de aprobar invalidaría la recomendación aprobada, y corregirla entonces
    produciría un texto que ningún revisor vio. `stage round-<N>` exige la auditoría y `status`
    la vuelve a comprobar; el informe enlaza la síntesis aprobada y no la reescribe.
20. **Generaciones de target en vez de `codex-reset.sh`.** El reset borra `usage.json` y
    `meta.json` del target: perdería la contabilidad y la evidencia de modelo/effort.
21. **Lock por run (`mkdir`) con lectura fresca dentro**, frente a confiar en la escritura
    atómica: `astra` corre en background mientras la skill registra a Fable, y dos
    lecturas-escrituras cruzadas perderían una entrada. Los locks huérfanos no se reclaman
    automáticamente (mismo criterio que los slots del swarm).
22. **El driver es dueño del ciclo de vida del turno.** Lanza y registra en una sola sección
    crítica, reenvía TERM al wrapper, y la liveness se decide por identidad de proceso (pid +
    `lstart`) y por las tres firmas de argv del turno — con un token único por lanzamiento, para que un
    reintento no se confunda con el lanzamiento que recupera —, nunca porque un pid haya muerto. Ante la
    duda, `bloqueada`, y desbloquear es una acción humana (`unblock`): mejor parar que solapar
    dos turnos en el mismo hilo.
23. **Recibo de éxito escrito por el wrapper**, frente a deducir el éxito comparando bytes con
    `last.txt`: un turno rechazado puede repetir bytes (dos APPROVED idénticos), así que solo
    quien valida puede certificar el éxito, ligado al número de turno. Coste: tocar la cola de
    éxito de los dos wrappers, compartida por todos los roles (es aditivo y lo cubre A1b).

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `skills/council/SKILL.md` | nuevo — protocolo del líder |
| `skills/council/prompts/{seat-rules,phase-propose,phase-cross,phase-round,nudge}.md` | nuevos — reglas comunes y plantillas de fase (contenido que `stage` concatena) |
| `skills/council/prompts/astra.tpl` | nuevo — solo `{{EXTRA}}` |
| `agents/council-fable.md`, `agents/council-fable-offline.md` | nuevos — asiento Fable 5.1 max (web / offline) |
| `scripts/council.sh` | nuevo — preflight, init, seal, record-agent, astra, unblock, stage, capture, publish, ledger, status |
| `scripts/_models.sh` | asiento `council` |
| `scripts/_common.sh` | rol `council` y watchdog 3600 |
| `scripts/codex-start.sh`, `scripts/codex-resume.sh` | cabeceras + recibo de éxito por turno (`t<N>.ok`) |
| `scripts/codex-doctor.sh` | línea de política + `smoke_add` |
| `tests/stub/codex` | rama `debug models` |
| `tests/council-{role,preflight,run,capture,ledger}.test.sh`, `tests/skill-council-contract.test.sh`, `tests/agent-council-parity.test.sh` | nuevos |
| `tests/fixtures/council/` | nuevo — transcript derivado + variantes sintéticas + README |
| `tests/models-defaults.test.sh`, `tests/doctor-env-matrix.test.sh` | asiento/rol y línea del doctor |
| `README.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`, `docs/BACKLOG.md` | documentación (M39) |
| `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | 0.36.0 y descripción |
| `docs/audits/council-canario-<fecha>.md` | nuevo, tras el canario real |

## Acceptance & proof

- **A1 Rol `council`.** start y resume: `--model gpt-6-astra --sandbox read-only -c
  model_reasoning_effort=max` y los pins en el orden exacto de
  `tests/start-argv-exact-order.test.sh`; sin `web_search=disabled` por defecto y con él bajo
  `TANDEM_WEB_SEARCH=off`; `TANDEM_COUNCIL_MODEL`/`_EFFORT` ganan; `TANDEM_REVIEW_MODEL`/`_EFFORT`
  no afectan a council; `TANDEM_TRANSPORT=mcp` → 64 sin invocar el stub ni crear estado;
  literal `TANDEM_EXEC_TIMEOUT_DEFAULT_COUNCIL=3600`, `exec_timeout_validate council` → 3600 y
  `TANDEM_EXEC_TIMEOUT_SECONDS` gana.
- **A1b Recibo de turno.** Un start y un resume con éxito escriben `t<N>.ok` con su turno, su
  hilo y el sha256 de su `reply.txt`, en todos los roles. Ninguno de los caminos de fallo de la
  suite lo escribe: escenarios `resume-fallback` y `fail`, respuesta vacía, sin evento de hilo,
  watchdog. Los tests que fijan el conjunto exacto de artefactos por turno se actualizan.
- **A2 Modelos.** El asiento `council` → `gpt-6-astra`; `resolve_role council` sigue al asiento;
  los barridos estáticos siguen vacíos.
- **A3 Doctor.** Línea de council con defaults y con overrides; asiento Claude leído del
  frontmatter.
- **A4 Preflight.** Cada chequeo (a)–(i) tiene caso positivo y negativo — (h) con
  `TANDEM_TURN_EFFORT` heredada como `low`, vacía e inválida —; varios problemas se informan
  todos en una pasada con exit 1; catálogo no disponible → FAIL; el resumen muestra la cota
  típica y el techo; cero turnos exec (el contador del stub no avanza).
- **A5 Run.** `init`: permutación de tres letras distintas sobre los tres asientos, run
  existente → 2, run id inválido → 64. `seal brief` + brief modificado → `stage` 65; `seal
  propose` con una respuesta de asiento ya presente → 65. `stage`: composición byte a byte
  (seat-rules + fase + entradas bajo delimitadores), ninguna línea añadida por el script nombra
  un modelo, `round-*` para la letra del líder → 64, entrada ausente → 1; un segundo `stage`
  crea `a2` sin tocar `a1` y un tercero → 65; `--reminder` lista exactamente lo que falta y es
  único por fase y letra; `round-<N>` sin `auditoria-v<N>.md`, o con un `NO CONFIRMA` → 1.
  `astra`: start sin hilo y resume con hilo; registra turno, tipo, intento y exit (contador
  antes/después; sin cambio → sin turno); un sustantivo lanzado con `TANDEM_TURN_EFFORT=low`
  exportada en el entorno del llamante lleva `model_reasoning_effort=max` en el argv, también
  justo después de un recordatorio (que lleva `low`); un tercer sustantivo o un segundo
  recordatorio de la fase → 65; una entrada `running` con el pid muerto → `interrupted`.
  `publish`: con un turno de hilo equivocado (escenario `resume-fallback` del stub), con un
  start fallido y con un reintento con éxito publica solo el turno `done` del intento vigente, y
  un `done` sin recibo o con otro sha → 65;
  sin él, o sin la captura del intento vigente de Fable → 1 (pérdida de sesión tras preparar el
  prompt; ronda en la que solo un revisor completó: su turno `done` sigue asignado y `publish`
  espera); no sobreescribe (2) y deja la procedencia solo en `run.json`. Reconstrucción de
  Astra: abre `-g2` y `metadatos.md` suma las dos generaciones. Auditoría de lecturas: un
  `events.ndjson` de Astra con un `cat` del directorio del run → anomalía anotada, sin
  bloquear.
- **A5b Concurrencia y ciclo de vida.** Con el lock del run tomado por un proceso vivo,
  `record-agent` espera y no escribe; un cambio hecho en `run.json` durante la espera aparece en
  su escritura final (lee dentro del lock); la reserva de `astra` y la entrada de `record-agent`
  sobreviven las dos, también solapando el cierre de `astra`. Lock no adquirido en el plazo → 75
  nombrando el lock y su dueño, sin reclamarlo; el trap EXIT lo suelta en los caminos de error.
  TERM al driver de `astra` mientras corre el escenario `hang` del stub con
  `CODEX_STUB_HANG_RESISTANT=1` → el wrapper sale, el descendiente resistente queda recogido
  (`CODEX_STUB_HANG_PIDFILE`) y la entrada pasa a `interrupted`. `kill -9` al driver con el
  wrapper vivo → la entrada sigue `running` y un segundo `astra` del target → 75 hasta que el
  wrapper termina; después se recupera como `done (recuperado)` y se publica, o como
  `interrupted`, según `last.txt`. Un proceso cuyo argv nombra el `reply.txt` del turno cuenta
  como vivo; si la liveness no se puede establecer → `bloqueada` y 65. Muerte del driver
  seguida de una respuesta de hilo equivocado con los MISMOS bytes que el `last.txt` vigente →
  `interrupted` (no hay recibo) y nunca publicable. Pausa determinista entre lanzar y
  registrar, con un `ps` falso en el PATH del test que se bloquea en la consulta de `lstart`
  del hijo: `kill -9` al driver en esa pausa → el lock queda huérfano, un segundo `astra` → 75 y
  el contador de invocaciones del stub muestra un solo exec; tras limpiar el lock a mano, la
  entrada sin wrapper registrado → `bloqueada` (65), y `unblock` la clasifica con el recibo
  (`done (recuperado)`) o sin él (`interrupted`), o responde 75 si una de las tres firmas sigue
  viva. Tras salir todos los procesos del lanzamiento original, un `astra` directo (sin `status`
  antes) recupera la entrada con su recibo y lanza, en vez de responder 75: el escaneo no se
  cuenta a sí mismo ni a sus subprocesos de sondeo. Un hijo superviviente del lanzamiento
  original, identificado por su token, sigue bloqueando el lanzamiento.
- **A6 Captura.** Respuesta de handback fiel byte a byte; rama de bloques de texto (sintética);
  el uso deduplicado por `message.id` es la suma por id (y difiere de la suma ingenua por línea
  en la fixture real); un modelo ajeno → 65, nada escrito, cursor intacto; variante con fecha del
  pin aceptada; el segundo turno lee solo líneas nuevas; sin respuesta → 1; `--manual` registra
  transcrito/no verificado; un Read de una ruta prohibida → anomalía; una captura más allá del tope de la fase → 65.
- **A7 Registro y estado.** Registro completo frente a IDs ausentes; severidad rebajada → error;
  conjunto cerrado de disposiciones. CONSENSO solo con los dos APPROVED + `RIESGO RESIDUAL` +
  ningún P1/P2 de revisor en `NO RESUELTA`/`PENDIENTE` + `RESUELTA` razonado sobre un RECHAZADA
  + ningún P1 `ABIERTA`. APPROVED con un P1/P2 propio en `NO RESUELTA` → incoherencia; `REABRE`
  → `PENDIENTE` hasta un estado nuevo; un P1 nuevo en la última ronda → SIN_CONSENSO; un P3 no
  bloquea nunca; una ronda aprobada cuya auditoría tiene un `NO CONFIRMA` → SIN_CONSENSO; `--metadata` suma
  cada fichero de uso una sola vez (también los de turnos fallidos) y `estrategia-final.md` es
  idéntica byte a byte a la última síntesis revisada.
- **A8 Contrato de la skill** (anclas sobre el texto aplanado). El preflight va primero; el líder
  se autodeclara; la entrevista no lee `TANDEM_AUTONOMOUS`; el sello va antes de lanzar a los
  asientos; los lanzamientos de Astra de los bloques de código son `council.sh astra` y
  ninguno llama a `codex-start.sh`, `codex-resume.sh` o `codex-reset.sh` ni fija
  `TANDEM_TRANSPORT` o `TANDEM_TURN_EFFORT`; el despacho es
  `tandem:council-fable` sin `model` ni `effort`; está la frase de la barrera; el consenso solo
  sale de `status`; nunca commit ni push; `capture` 65 → FAILED; nunca `SendMessage` como sonda.
- **A9 Agentes.** Paridad (cuerpos idénticos; el frontmatter solo difiere en name, description y
  tools); conjuntos exactos de herramientas; `model: claude-fable-5-1`; `effort: max`; ninguno
  incluye Bash, Edit, Write ni Agent.
- **A10 Documentación.** Fila y sección en README; sección en ARCHITECTURE; CHANGELOG 0.36.0;
  `plugin.json` 0.36.0; M39 en BACKLOG coherente con su estado.
- **PROOF:** `bash tests/verify.sh`

**Cierre bloqueante — canario real** (gasta cuota de los tres modelos en max: solo con OK
explícito del usuario, después de la code review y antes del merge). Se hace en una sesión nueva
con el plugin cargado (instalación actualizada o `--plugin-dir`) y en una carpeta fuera de
cualquier repo:
- **C1.** `/tandem:council` con una idea pequeña y real del usuario termina (CONSENSO o
  SIN_CONSENSO: los dos son desenlaces válidos) con todos sus artefactos.
- **C2.** Evidencia: el `meta.json` de cada turno sustantivo de Astra dice `gpt-6-astra` /
  `max` / `read-only` y el de cada recordatorio, `low`; cada captura de Fable solo contiene `claude-fable-5-1`; el líder se autodeclara
  `claude-opus-5-5`.
- **C3.** `ledger` y `status` concuerdan con el informe; los tokens de `metadatos.md` salen de
  fuentes de máquina.
- **C4.** Nada se escribe fuera de `DOC_DIR` y `.tandem/` (listado antes/después).
- **C5.** Las formas reales validan las fixtures sintéticas (handback en las continuaciones,
  cursor); si difieren, se regraba la fixture y se corrige antes de cerrar.

La evidencia queda resumida en `docs/audits/council-canario-<fecha>.md`.

## Risks

- **Deriva del formato del transcript** (`SubagentHandback`, repetición de `message.id`) →
  `capture` 1 → degradación visible. Fixture derivada de un transcript real; C5.
- **Cambio de modelo silencioso en el subagente** (la doc indica que en subagentes no se muestra
  el aviso del cambio de modelo por marcado de seguridad) → `capture` 65 → FAILED.
- **Coste de Fable:** según el plan, créditos de uso; para subagentes no está documentado y el
  preflight no lo ve → README y recordatorio en el gate del brief.
- **Latencia de los turnos max:** siempre en background, watchdog de 3600 s para Astra,
  `maxTurns: 50` para Fable y barrera dura.
- **Coste en el peor caso:** techo de `5 × (2 + R)` turnos max por run, con topes ejecutables
  por fase y asiento; se muestra en el gate del brief.
- **Procesos huérfanos tras un `kill -9`:** del driver fuera de la sección crítica, el wrapper
  sigue y cierra él mismo; dentro de ella, el lock huérfano para el run; del wrapper, el codex
  huérfano se detecta por el argv único del turno. Si no se puede establecer, el target queda
  `bloqueado` y el run se para hasta un `unblock` humano.
- **`SubagentHandback` fuera del allowlist `tools:`:** si el harness no la inyecta, el asiento
  termina en texto plano (rama de texto de `capture`). Lo comprueba el canario.
- **Pérdida de sesión:** Fable se reconstruye desde disco (pierde su razonamiento privado), el
  hilo de Astra persiste y `status` da la fase.
- **Sesgo del moderador** → consenso ejecutable, registro completo con la severidad del autor y
  derecho a reabrir.
- **Complacencia** → fase a ciegas, anonimato, concesión razonada (regla 3 de `status`), riesgo
  residual obligatorio y P1/P2 propios listados en cada ronda.
- **Formato incumplido** → recordatorios; un segundo fallo cuenta como REVISE con anomalía en las
  rondas y queda como anomalía visible en las fases 1–2.
- **Ideas confidenciales en un repo público** → nada se commitea; aviso en README; modo
  confidencial.
- **Citas inventadas** → auditoría de fuentes de las cifras que sostienen P1/P2.
- **Registro del agente:** los agentes de plugin no se recargan en caliente, y en este repo el
  plugin no está instalado sobre sí mismo → el canario va en sesión nueva.
- **M35b pendiente** (el doctor da un FAIL falso por `CLAUDE_CODE_SUBAGENT_MODEL`) → el preflight
  del consejo ya implementa la regla vigente; M35b armonizará el doctor.

## Out of scope

Canal directo entre asientos; más de tres asientos o paneles configurables; vista HTML o export a
Claude Docs; vista de runs en `tandem:status`; integración con el juez de M38; transporte MCP;
bloquear lecturas (solo se auditan); Fable vía `claude -p`; commits automáticos; la vigilancia de
deriva general de M37 (aquí solo el chequeo de catálogo del consejo); medir el uso del moderador.

## Assumptions

Decisiones del orquestador que no se preguntaron al usuario (auditables):
- Nombre `council`, por la convención en inglés de las demás skills.
- Tope de 4 rondas.
- Directorio `docs/council/<YYYY-MM-DD>-<slug>/`.
- Letras anónimas por permutación aleatoria.
- Astra en `max` y no `ultra`.
- La entrevista no depende de `TANDEM_AUTONOMOUS`.
- `maxTurns: 50` para Fable.
- La regla de consenso (1)–(5).
- Líder esperado `claude-opus-5-5`.
- Un recordatorio por asiento y fase.
- Formatos de línea en español.
- Canario fuera de cualquier repo.
