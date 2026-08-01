# Changelog

## 0.24.0 — 2026-08-01

- **El gate crítico de versión de Claude Code es por fin fail-closed de verdad** (M18,
  tarea 3/3 de la Cola 3; hallazgo Major 3 de la primera range review real, reproducido
  empíricamente: `Claude Code build 123 version 2.1.110` pasaba el gate ≥ 2.1.111 como
  "123"). `claude_dotted` exige un token estricto de TRES componentes decimales `N.N.N`
  del PRIMER token que empiece por dígito (sufijo no numérico tipo `-beta` recortado);
  builds, fechas, dos o cuatro componentes → indeterminable → FAIL, sin rescatar jamás
  una versión posterior (un formato ambiguo no puede autocertificarse).
- **`version_ge` valida ANTES de comparar:** ambos operandos como `N.N.N` exacto y nada
  más — el retorno temprano por campo dejaba `3.bad` y `3.0.0.7` ganando en el primer
  campo sin mirar la basura posterior; fuera el zero-fill (un campo ausente es una
  versión rota, no un 0).
- **Pin anti-drift de oración normativa completa:** la regla íntegra del parse vive
  VERBATIM en el comentario de `claude_dotted` y en el gate 3 de la skill de implement, y
  el contrato la aserta entera en ambos ficheros (más la negativa: la frase laxa retirada
  no puede sobrevivir). Variante de checker compartido rechazada razonadamente: el gate 3
  lo ejecuta el modelo leyendo prosa.
- Suite: 72 ficheros (cobertura nueva dentro de los existentes): 5 casos stub de límites
  del parser + 6 casos directos del comparador (función extraída del propio script, sin
  segunda copia del algoritmo).

## 0.23.0 — 2026-08-01

- **`/tandem:status` deja de poder certificar en falso una aprobación** (M16, tarea 1/3
  de la Cola 3; hallazgo Major 1 de la primera range review real). `PA_VALID` espeja
  ahora los CUATRO invariantes de `plan-approve.sh`: el commit existe, su first-parent es
  el source_head registrado, toca SOLO el plan registrado (`diff-tree`) y contiene ese
  blob (`rev-parse "sha:path"`). Un commit hermano plausible, uno que toque el plan más
  otro fichero, o un hijo que solo borre el plan → "registro de aprobación corrupto",
  jamás "plan aprobado".
- **Sin git no se certifica: estado nuevo "aprobación no verificada"** (`SIN VERIFICAR
  (sin git | fuera de un repositorio git)`, con la razón real). La fase es descriptiva,
  el next es prescriptivo: bajo unverified, TODO `next:` es la verificación manual — la
  salida no recomienda `/tandem:implement` ni `/tandem:review` por ningún camino.
- **Readiness de rama separado de la validez del registro:** la rama debe existir Y
  contener el commit de aprobación (`merge-base --is-ancestor`) — una rama reseteada a
  source_head cuenta 0 commits sobre el plan como una intacta y solo la contención las
  distingue; sin readiness, ningún next de pipeline (implement NI review); las fases
  terminales quedan intactas (rama borrada tras merge sigue legítima).
- Suite: 72 ficheros de test (sin ficheros nuevos — la cobertura crece dentro de los
  existentes): 9 casos nuevos en status-degradation (incluido el aislamiento
  del guard de blob con un commit que solo borra el plan), 2 aserciones en el caso sin-git
  de status-phases, anchors del estado nuevo en skill-status-contract, y el fix de una
  aserción negativa VACUA preexistente (needle con padding imposible desde `row()`).

## 0.22.0 — 2026-07-31

- **Modo rango: review de commits YA en la historia, fuera del pipeline** (M15 del
  backlog, tarea 4/4 de la Cola 2 — cierre). `/tandem:review <label> --range A..B` revisa
  un rango committeado (rama, PR, tramo de historia) y entrega veredicto + hallazgos,
  jamás un commit: sin Step 4, sin fix loop, sin testing gate, sin promoción
  (`TANDEM_PROMOTE_REVIEWS` no aplica). El diseño solo-documentación del borrador se
  retiró en el red-team (6 rondas, incluida una reanudación humana tras deadlock del cap):
  la mecánica de git vive en un helper testeable.
- **`scripts/review-range.sh <label> <rango>` (nuevo):** valida label (charset de
  plan-approve) y rango (exactamente un `..`/`...`; endpoints vacíos/con control/forma de
  opción → 64), resuelve ambos endpoints con `rev-parse --verify` y reconstruye el spec
  desde los SHAs completos — el texto del usuario jamás llega a git como revisión;
  bootstrap de `.tandem/` (primer uso sin tandem funciona, `.gitignore` existente
  preservado); contexto atómico (tmp + `mv`, todo fallo git/fs → 65 explícito) con
  endpoints resueltos, commits, stat, lecturas OBLIGATORIAS ancladas a B
  (`git show <shaB>:` — el checkout puede estar en otra versión) y el diff completo inline
  bajo `DIFF:`; salida parseable `TARGET:/ENDPOINTS:/CONTEXT_FILE:/LOG_FILE:/WORK_ROOT:`.
  Exit: 0 · 2 rango vacío · 3 sin git · 64 uso · 65 git/estado.
- **Namespace disjunto por construcción:** hilo `range-review-<label>` (nunca colisiona
  con `cr-<slug>`) y log en `.tandem/log/ranges/<label>.md` — subdirectorio fuera del scan
  de `/tandem:status`, que sigue viendo solo runs de pipeline. Re-review por MISMO label =
  mismo linaje (el hilo recuerda sus hallazgos); rango no relacionado exige label nuevo o
  reset explícito.
- **Templates propios** `start-range.tpl`/`resume-range.tpl` (los del pipeline instruyen
  "UNCOMMITTED"/`git diff HEAD` — contradicen el modo de frente); mismos contratos de
  veredicto, barrera dura de background y contabilidad `USAGE:` que el pipeline.
- Suite: 72 casos (de 70): `review-range` comportamental (grafo divergente con tres-puntos
  byte-exacto y distinto del dos-puntos, 64/65/2, árbol sucio no bloquea, no-colisión por
  `target_key`, status ciego a ranges, fallo de escritura no publica contexto) y
  `skill-range-contract` estático (tabla de decisión, anclas negativas — sin `git commit`,
  sin `final — commit:`, la prohibición obsoleta del frontmatter eliminada, templates sin
  regresión al framing de pipeline); `skill-review-background-contract` y
  `skill-turn-effort-contract` ahora mode-aware (grupos pipeline/rango contados por
  separado).

## 0.21.0 — 2026-07-31

- **`TANDEM_CRITICAL=1` tiene por fin efecto real bajo Opus** (M6 del backlog, tarea 3/4
  de la Cola 2). El tool Agent no expone effort por llamada, pero el frontmatter del agent
  type sí: nuevo `agents/implementer-critical.md` — copia byte a byte del implementer
  (misma allowlist, mismas prohibiciones; la paridad la fija un test de cuerpo completo
  con allowlist de diferencias {name, description, effort}) con `effort: xhigh`. Bajo
  CRITICAL + opus, `tandem:implement` usa ese agent type; el protocolo existente
  (SendMessage, attempt state, recovery) queda intacto. La vía Workflow del borrador
  original se retiró en el red-team: incompatible con el protocolo de identidad.
- **Tipo efectivo persistido y recovery mismo-modo:** el attempt state gana `agent_type`
  (enum cerrado {implementer, implementer-critical}; estado legacy sin el campo se
  normaliza a implementer y se persiste; valor desconocido jamás se despacha). La recovery
  usa SIEMPRE el tipo registrado; un mismatch entorno-vs-registro en cualquiera de las dos
  direcciones exige consentimiento (interactivo) o termina FAILED (autonomous) — nunca una
  degradación silenciosa de un intento crítico.
- **Gates de honestidad:** preflight de `CLAUDE_CODE_EFFORT_LEVEL` (definida ≠ xhigh bajo
  CRITICAL+opus → STOP: su precedencia pisaría el frontmatter) y gate de versión Claude
  Code ≥ 2.1.111 (el frontmatter effort llegó en 2.1.78 pero el VALOR xhigh solo en
  2.1.111 — evidencia de changelog del red-team), espejado en doctor Y en el preflight de
  implement (la skill es invocable sin doctor). El doctor muestra siempre efforts
  EFECTIVOS: `TANDEM_IMPLEMENT_EFFORT` pisa el xhigh de CRITICAL bajo sol y la línea lo
  dice en vez de prometer.
- Suite: 70 casos (de 68): `agent-critical-parity` (paridad frontmatter+cuerpo, nombres
  exactos) y `skill-critical-contract` nuevos; `doctor-env-matrix` ampliado con efforts
  efectivos, EFFORT_LEVEL y los límites exactos del gate de versión (2.1.110 FAIL /
  2.1.111 ok / ausente FAIL, todo silencioso sin CRITICAL) vía stub de `claude`.

## 0.20.0 — 2026-07-31

- **Semáforo de concurrencia dentro de `codex-swarm.sh`** (M13 del backlog, tarea 2/4 de la
  Cola 2). El tope `TANDEM_ULTRA_CONCURRENCY` dependía de que el autor del workflow
  chunkease los `parallel()` — barreras que el propio diseño desaconseja, y sin límite si
  se olvidaba. Ahora el script lo aplica él mismo: locks por `mkdir` (portable BSD, sin
  flock) en `.tandem/state/ultra/<run>/.slots/`, slot liberado por trap EXIT (un seat que
  muere libera), espera acotada con `TANDEM_ULTRA_SLOT_TIMEOUT` (default 1800 s) → exit 75
  (EX_TEMPFAIL: "congestión, reintenta gratis" — distinguible del 1 de fallo codex), y sin
  auto-reclamación de slots huérfanos por SIGKILL (las carreras rm/mkdir entre esperadores
  son la clase de bug que este cambio elimina; remedio manual documentado). `pipeline()`
  fluye sin barreras; el chunking manual desaparece de la skill.
- **Seguridad de señales alrededor de la contabilidad**: los handlers INT/TERM/HUP
  REGISTRAN la señal y retornan — jamás salen durante el pipeline de codex; PIPESTATUS, el
  ledger de usage y los footers `USAGE:`/`USAGE_FILE:` se persisten ANTES de honrar la
  señal (129/130/143). La adquisición es signal-safe (sección crítica mkdir→holder con
  señal diferida; el EXIT solo libera con SLOT_HELD=1 — nunca el slot de otro), precede a
  cualquier mutación de artefactos del seat (un timeout no destruye la reply previa —
  byte a byte testeado), y un TERM en cola sale 143 en cada frontera segura, nunca 75 ni
  adquiere. Ambos diales validados (10#, vacío-definido rechazado) también por el doctor.
- Suite: 68 casos (de 64): stub con censo de concurrencia (`CODEX_STUB_CONC_DIR`),
  `swarm-semaphore-cap` (4 seats con C=2 → máx observado exactamente 2), `-release`
  (liberación por die, TERM en vuelo con barrera → 143 con ledger y footers, timeout 75
  con artefactos intactos, remedio manual, TERM en cola con barrera anti-vacuidad),
  `-env` (validación pre-toolchain, 08/09 decimales) y el contrato estático
  `skill-ultra-concurrency-contract`; `doctor-env-matrix` ampliado. Mutation testing: el
  bug exacto del P1-1 (trap con exit directo) cazado por el test del ledger.

## 0.19.0 — 2026-07-31

- **Nueva skill `/tandem:status`** (M11 del backlog, tarea 1/4 de la Cola 2). Todo el
  estado de un run existía en disco pero había que saberse los ficheros de memoria; ahora
  `scripts/tandem-status.sh` (solo lectura ESTRICTA: ni un byte escrito, jamás un turno
  codex — probado con snapshots byte a byte alrededor de cada invocación) pinta por slug:
  plan y aprobación, rama y worktree, rondas y veredictos por fase, intento Opus/Sol, gate
  de testing (bloques multilínea reales), tokens agregados por fase desde los ledgers de
  M9, la FASE que la evidencia prueba y un `next:` determinista que cubre también las dos
  pausas de gate humano. Sin slug: listado de runs conocidos (unión deduplicada de todas
  las raíces de estado). jq y git son dependencias blandas (degradan a `desconocido`);
  raíz de estado doble resuelta por evidencia DEL SLUG (una sesión en worktree ve el estado
  del principal). Exit 0/2/64, nunca 1/3.
- **Registro terminal del run — `final — commit: <sha>`**: el Step 4 de `tandem:review`
  escribe ahora esta línea machine-parseable en el log tras el commit aprobado. Es la única
  prueba durable y parseable de que un run cerró: la rama no es evidencia para siempre (el
  merge legítimo la borra — los 7 runs históricos de este repo lo demuestran), y sin ella
  un lector posterior no distingue un run aprobado de un commit no autorizado del
  implementador. El status la valida con dureza: el sha debe descender de `plan_commit`
  (uno válido pero ajeno NO verifica), con la rama viva el tip debe SER el sha (un
  descendiente = commits post-gate = `contradictorio`), y "run completo" queda reservado al
  registro verificado.
- Suite: 64 casos (de 60): `status-phases` (ciclo de vida completo con el plan-approve.sh
  real, ambas pausas de gate, casos de registro terminal 6/6b/9/10/10b/10c, merge ff +
  borrado de rama, gate envuelto, tokens, cero codex, snapshots de solo-lectura),
  `status-degradation` (corrupto/ausente/sin jq/sin git), `status-list` (unión, dedupe,
  exclusiones, exit 2 con lista) y `skill-status-contract` (anclas; negativas solo sobre
  bloques ejecutables) nuevos.

## 0.18.0 — 2026-07-31

- **Reviews largas en background por defecto** (M10 del backlog, tarea 6/6 — cierra la cola
  autónoma). Las skills de plan y review fijaban `timeout: 600000` en foreground para sus
  turnos de review — el MÁXIMO del tool Bash: una review xhigh de un diff/plan grande podía
  morir a los 10 minutos con la cuota ya gastada. Los cuatro lanzamientos reales (start y
  resume de plan-review y code-review) documentan ahora `run_in_background: true` como
  default para cualquier plan/diff real, con foreground `timeout: 600000` SOLO como
  excepción para lo pequeño y el wording legacy RETIRADO (no meramente complementado).
- **La notificación de finalización es una barrera dura de sincronización**: nada de leer
  el `VERDICT:`, copiar la línea `USAGE:` al log (jamás un `tokens: n/a` prematuro) ni
  lanzar resume/nudge alguno antes de que llegue — el hilo ni siquiera está persistido
  antes, y un resume concurrente sobre un turno vivo es la corrupción exacta que la barrera
  prohíbe. Los nudges (`TANDEM_TURN_EFFORT=low`) quedan explícitamente en foreground:
  turnos de una línea que vuelven en segundos.
- Dogfood registrado en el log del run: una sonda background de coste cero durmió 601 s y
  su notificación llegó tras cruzar el techo de 600 s (la supervivencia larga, por
  mecanismo); la propia code review de este run corrió en background con la secuencia
  barrera → notificación → USAGE → verdict.
- Suite: 60 casos (de 59): `skill-review-background-contract` nuevo — parser de comandos
  lógicos clasificando por template (nudge.tpl = foreground asertado; el resto = background
  con barrera), exactamente 2 lanzamientos reales + 1 nudge por skill, negativas
  seccionadas sobre el wording legacy (`timeout: 600000` solo dentro de la frase de
  excepción) y anti-regresión de implement.

## 0.17.0 — 2026-07-31

- **El doctor avisa del conflicto de `CLAUDE_CODE_SUBAGENT_MODEL`** (M7 del backlog, tarea
  5/6 de la cola autónoma): con implementer opus y la variable definida con otro valor, el
  preflight de implement paraba a mitad de pipeline sin que el diagnóstico previo dijera
  nada. Ahora es una línea FAIL accionable (des-definirla, fijarla a `opus`, o
  `TANDEM_IMPLEMENTER=sol`); definida como `opus` → ok informativo; bajo sol no aplica.
- **`codex-doctor.sh --smoke`** — un turno REAL mínimo por modelo ÚNICO configurado (2 con
  la política default, deduplicado; implement solo bajo sol) que responde "¿este nombre de
  modelo sigue existiendo?" antes de que una deprecación muerda a mitad de un run largo.
  Jamás corre sin el flag (cero `codex exec` por defecto, fijado por test) y avisa del
  coste antes de lanzar nada. Aislamiento total del diagnóstico: `--ephemeral` (con sonda
  de capacidad contra `exec --help` — sin el flag en el CLI instalado, FAIL y cero turnos),
  `--cd` único a un temporal privado (vía `TANDEM_CODEX_CWD` fijada antes de los pins — dos
  `--cd` son exit 2 del CLI), `-c web_search=disabled`, SIN override de effort (`minimal`
  no existe para sol/luna en la CLI pineada — el parsing global valida el string, no el
  soporte por modelo; forzarlo reportaría "retirado" en falso) y watchdog por modelo
  (120 s, override validado `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS`) con continuación
  garantizada: un cuelgue o fallo de un modelo nunca deja sin diagnóstico a los demás.
  Clasificación por SEMÁNTICA de modelo-no-disponible en el stderr, nunca por la mera
  presencia del nombre (los errores de auth/cuota también lo citan).
- **`codex_pins()` extraída a `scripts/_pins.sh`** (sourceable sin efectos de shell): el
  doctor no puede sourcear `_common.sh` (su `set -euo pipefail` rompería el "reporta
  todo"), y una lista duplicada inline habría driftado en silencio. Los wrappers quedan
  byte a byte idénticos (los tests de argv existentes pasan sin modificar).
- Suite: 59 casos (de 58): `doctor-smoke.test.sh` nuevo (cero exec por defecto, dedupe,
  paridad de pins, --ephemeral y su modo negativo, --cd único también con env heredada,
  fallo selectivo por modelo con continuación asertada, auth-shaped, cuelgue selectivo con
  watchdog, 64s de usage, nada bajo .tandem/); `doctor-env-matrix` ampliado con los 5 casos
  de la variable; el stub gana `exec --help` no contado y selectividad
  FAIL/HANG por modelo preservando los escenarios globales.

## 0.16.0 — 2026-07-31

- **Effort puntual para turnos-recordatorio** (M5 del backlog, tarea 4/6 de la cola
  autónoma). Cuando una respuesta llega sin su línea `VERDICT:`/sentinel, el nudge que pide
  solo lo que faltó pagaba el effort del rol (xhigh en review). Nueva env
  `TANDEM_TURN_EFFORT`, leída SOLO por `codex-resume.sh` (start y swarm la ignoran a
  propósito — fijado por test): lista cerrada
  `minimal|low|medium|high|xhigh|max|ultra`, validada ANTES de las dependencias (un valor
  inválido responde 64 incluso sin codex en el PATH — usage nunca degrada a 3), aplicada
  tras `resolve_role` sobre `CODEX_EFFORT` (argv, narración, heartbeat y meta llevan el
  effort real sin segunda fuente de verdad). El sandbox sigue fijado por rol.
- **Cuatro comandos de nudge dedicados con template propio** — las ramas de sentinel
  ausente eran prosa y su único comando concreto era el de trabajo real (prefijarlo habría
  degradado trabajo real a low): `nudge.tpl` nuevos en plan, review, implement e image
  (esta cuarta rama, rol a high, estaba omitida en el borrador), con contrato de salida POR
  ROL — plan/review/image re-emiten solo su línea; implement re-emite el informe final +
  sentinel prohibiendo trabajo adicional. Los nudges de review/implement llevan también el
  pin `TANDEM_CODEX_CWD` (el contrato de worktree no exime a los recordatorios). Los
  resumes reales quedan intactos y sin la variable.
- **Registro durable por turno — `t<N>.meta.json`** (`{role, model, effort, sandbox}`): el
  heartbeat es global y reemplazable, así que era imposible probar a posteriori con qué
  effort corrió un nudge. Escrito por start y resume ANTES del turno (sobrevive a fallos),
  construido con `jq -n --arg` (un modelo de un override de entorno puede llevar comillas o
  backslashes — printf produciría JSON inválido) y persistido con el tmp+mv best-effort del
  ledger de M9.
- Suite: 58 casos (de 56): `resume-turn-effort` (argv+heartbeat+meta con low, max/ultra
  aceptados, 64 con valor inválido/vacío incluso sin codex, start/swarm inmunes, modelo
  JSON-hostil) y `skill-turn-effort-contract` (las cuatro ramas con prefijo y template,
  pin de worktree en review/implement, anclas por rol, resumes reales sin la variable)
  nuevos.

## 0.15.0 — 2026-07-31

- **La línea 2 de la status line ya no queda muda durante las implementaciones Opus** (M12
  del backlog, tarea 3/6 de la cola autónoma). El attempt state durable
  (`.tandem/state/implement-claude/<slug>.json`) lleva presencia y desenlace — el 80% del
  valor — y ahora se renderiza: `⚒ opus implement · running · <slug>` en ámbar durante el
  intento, el sentinel coloreado 900 s al cerrar (`IMPLEMENTATION_COMPLETE` verde,
  `IMPLEMENTATION_PARTIAL` ámbar) y `⚠ sin señal` gris cuando un `running` lleva > 2 h sin
  cierre (indistinguible de una sesión muerta; mismo criterio honesto que `orphaned`).
  Actividad en vivo: no — el fichero cambia exactamente dos veces por intento y narrar más
  sería inventarlo (v2 explícito).
- **La línea 2 se reestructura como selección de ganador, no como fallback tras los exits**
  (hallazgo P1 del red-team: los heartbeats terminal-recientes y orphaned no salen — se
  renderizan — así que un fallback "donde el camino Codex se rinde" habría sido invisible
  exactamente en el ciclo de vida real, donde la plan-review Codex termina y Opus arranca en
  el mismo minuto, y un orphaned lo taparía para siempre). Regla: un turno Codex VIVO (pid
  comprobado; pid 0/corrupto = desconocido, conserva prioridad — contrato existente) gana
  siempre; entre estados no vivos gana el timestamp más reciente (mtime del JSON vs
  `updated_at`), con empates deterministas (Opus running gana al Codex no vivo; Opus
  terminal pierde) y degradación explícita sin `stat` (BSD `-f %m` → GNU `-c %Y` → sin
  ventana; con heartbeat elegible presente, gana Codex). Un candidato corrupto solo se
  elimina a sí mismo de la selección — jamás suprime al otro. El bloque de render Codex
  queda intacto línea a línea.
- Suite: 56 casos (de 55): `statusline-opus-fallback` nuevo (transición real del pipeline,
  orphaned viejo, empate exacto de timestamps con `touch -t`, stub de `stat` que falla,
  corrupción cruzada, pid 0, raíz doble desde worktree, orden multi-JSON en ambas
  direcciones); `statusline-never-fail` ampliado con 20 payloads rotos del attempt state +
  fichero ilegible + directorio, asertando exactamente una línea de salida y cero rastro de
  `opus implement` (el contrato es "línea 2 ausente", no "sin crash"), con control positivo
  anti-vacuidad. Los 5 tests de statusline existentes quedan verdes SIN modificar.

## 0.14.0 — 2026-07-31

- **Contabilidad de tokens por turno, ronda y run** (M9 del backlog, tarea 2/6 de la cola
  autónoma). Cada `turn.completed` del NDJSON ya persistido trae el `usage` del turno y
  hasta ahora se narraba en vivo y se descartaba — con la cuota ChatGPT como restricción
  operativa real, un run no tenía coste conocible. Nuevo `turn_usage` en `_common.sh`: suma
  campo a campo del `.usage` de TODOS los `turn.completed` del stream (36/36 streams reales
  archivados traen exactamente uno, así que la suma es el objeto verbatim; si el CLI emitiera
  eventos por-intento, sumar contabiliza los reintentos en vez de descartarlos), nombres de
  campo de codex verbatim (numéricos futuros viajan gratis; no numéricos se descartan),
  tolerante a líneas malformadas.
- **La extracción ocurre tras el pipeline y ANTES de cualquier check**: una reply vacía, un
  thread ausente o un fallback rechazado ya quemaron su cuota — se persiste
  `.t<N>.usage.json` (escritura atómica best-effort que jamás cambia el exit code ni deja
  JSON truncado), el heartbeat gana `tokens_in`/`tokens_out` (null SIEMPRE en `running`;
  poblados también en el heartbeat `failed` de un turno rechazado) y se emite exactamente
  una línea `USAGE: {…}` por stderr en TODOS los caminos — la que las skills copian al log
  sin recomputar checksums de `target_key`. En swarm el usage es un LEDGER por intento
  (`<seat>.t<N>.usage.json`, nunca pisado por un retry: la cuota gastada no se des-gasta)
  con footers `USAGE:`/`USAGE_FILE:`.
- **Statusline**: dos campos nuevos al FINAL del transporte `\x1f` (un heartbeat pre-M9
  degrada sin desplazar campos — la lección del bug v0.5.0) y render humanizado `1.2k→56`
  solo en estados terminales y solo con enteros no negativos: string, decimal, negativo o
  corrupto omiten el segmento sin ruido, como pid y timestamps.
- **Las cinco skills ganan el paso de contabilidad incondicional**, antes de ramificar por
  veredicto (una ronda APPROVED a la primera cuesta lo mismo que una REVISE y hasta ahora no
  dejaba rastro), con total por fase en cada resolución, agregado por fase + total del run
  en el informe final de TODOS los estados terminales (DEADLOCK/PARTIAL/FAILED incluidos), y
  en ultra el algoritmo de agregación único: el total sale del ledger exactamente una vez
  por seat, el `usage` devuelto por el wrapper es metadato de display y nunca se re-suma,
  `usage`/`usage_file` nullables también en seats fallidos. Bajo transporte opus el log
  anota `tokens: n/a (transporte opus)` — ausencia registrada, no olvido.
- Suite: 55 casos (de 53): `common-turn-usage` (suma, verbatim, garbage, no numéricos) y
  `skill-token-accounting-contract` (anclas de las cinco skills + los footers realmente
  emitidos por los tres wrappers) nuevos; 12 tests ampliados (usage con igualdad jq exacta
  en happy paths, cuota quemada contabilizada en los tres caminos de fallo, persistencia
  blindada, ledger t1→t2 con retry fallido que no corrompe, heartbeat nulls, statusline con
  tokens malformados y heartbeat pre-M9) y `lib.sh` (write_hb con tokens).

## 0.13.0 — 2026-07-31

- **El preámbulo de los enjambres ultra lo concatena el script, no un modelo** (M8 del
  backlog, primera tarea de la cola autónoma). El wrapper `haiku` de cada seat debía
  reproducir "el contenido completo del preámbulo, verbatim" — un modelo pequeño retecleando
  texto largo es exactamente donde aparecen mutaciones silenciosas. `codex-swarm.sh` acepta
  ahora `[--preamble <file>]` (flag opcional ANTES de los posicionales; la aridad de 4
  posicionales exactos se conserva con y sin flag — nunca un quinto posicional, el contrato
  que `swarm-usage-and-fail` fija a propósito) y construye el prompt staged como
  `cat <preamble> <brief>` sin inyectar un solo byte separador; `codex exec` pasa a leer
  stdin DEL staged en ambos modos, así que el registro durable
  (`.tandem/state/ultra/<run>/<seat>.prompt.txt`) y lo que codex recibe son el mismo
  fichero. Validación fail-closed: `--preamble` sin valor, fichero ausente o flag
  desconocido → 64 con usage. El wrapper de `skills/ultra/SKILL.md` queda reducido a
  brief + ejecución + extracción, con el preámbulo viajando como RUTA absoluta.
- Suite: 53 casos (de 51). `swarm-preamble.test.sh` comportamental: `cmp` byte a byte (nunca
  "contiene") del staged Y del stdin drenado por el stub contra la concatenación de
  referencia, con el preámbulo en una ruta con espacios y glob (caza filenames sin comillas)
  y contenido con `%s`, tabs y backslashes (caza expansiones de printf); el argv de codex se
  aserta libre del flag. `skill-ultra-preamble-contract.test.sh` estático: ancla positiva
  brief-only, ancla negativa sobre la instrucción vieja de copiar el preámbulo (el bug de
  preámbulo DUPLICADO — flag nuevo + copia manual retenida — es invisible para el test
  comportamental), y cada lanzamiento fenced de `codex-swarm.sh` debe llevar `--preamble`
  antes de los posicionales. `swarm-usage-and-fail` amplía la matriz fail-closed del flag y
  la aridad en ambas direcciones con el flag presente.

## 0.12.0 — 2026-07-30

- **El commit del plan aterriza en `tandem/<slug>`, nunca en la rama del usuario** (M3 del backlog). Hasta ahora el plan aprobado se commiteaba en la rama actual (típicamente `main`) y la rama tandem no nacía hasta `implement` Step 0.6 — un commit huérfano en main si el run se abandonaba y, en autonomous, una escritura no supervisada en la rama por defecto que violaba la propia línea roja del modo. Nuevo `scripts/plan-approve.sh <slug> [mensaje]`: crea `tandem/<slug>` desde el HEAD del usuario y aterriza el commit del plan (solo el fichero del plan) dentro de la rama — in-place (`git checkout -b`, la sesión queda en la rama) o worktree (`TANDEM_WORKTREE=1`: worktree en `.worktrees/<slug>` ya en la aprobación y el plan se MUEVE dentro; el checkout principal queda limpio y en la rama del usuario).
- La transición es fail-closed e idempotente, con estado durable transaccional en `.tandem/state/plan-approve/<slug>.json` (`branch`, `plan_commit`, `source_head` — el parent del commit del plan; nombre deliberadamente distinto del `base_head` de implement, que es el TIP de la rama tandem — y `mode`): registro pending atómico antes de mutar git → commit → finalización con `mv` atómico. Un commit que no aterriza, o un estado que no se puede publicar, se deshace por completo (rollback de rama/worktree con el working copy del plan SIEMPRE preservado); un pending cuyo commit concuerda se recupera finalizando el estado. Resume solo con estado concordante (tip == `plan_commit`, parent == `source_head`, diff plan-only, blob idéntico — la forma del tip sola no basta: una rama `base → implementación → tip plan-only` se rechaza); rama sin estado, plan divergente, slug cuyo plan ya está trackeado en la rama del usuario (reutilizado de un plan mergeado), o mismatch entre `TANDEM_WORKTREE` y el estado real de `git worktree list` (derivado de git, nunca del entorno a ciegas) → exit 65, nunca una adivinanza. Sin dependencia de jq: el registro se escribe con printf, se relee con sed y cada valor se re-verifica contra git.
- `tandem:implement` se re-cablea alrededor del flujo nuevo: la ruta se decide por la EXISTENCIA de la rama (existe → resolver `WORK_ROOT` antes de los gates; no existe → ruta legacy pre-0.12 en la que gate 6 sigue creándola), el plan gate verifica el plan EN la rama tandem (`git cat-file -e`), el clean-tree gate exige limpieza en el checkout principal Y en `$WORK_ROOT`, gate 6 pasa de crear a verificar/reutilizar con la misma validación de mismatch de modo, y el baseline de seguridad (`base_head`/`remote_snapshot`) y el `plan_hash` se capturan SIEMPRE anclados (`git -C "$WORK_ROOT"`) y DESPUÉS de resolver la raíz — capturarlos del checkout principal marcaría como violación de seguridad cualquier implementación worktree legítima, porque la rama tandem va un commit por delante por construcción. El contrato de `TANDEM_WORKTREE` se amplía a "plan approval and implement/review only" (decide también dónde aterriza el commit de aprobación; `ask`/`image` siguen sin anclarse).
- Suite: 51 casos (de 49; el runner cuenta ficheros — los 2 nuevos concentran decenas de aserciones). `tests/plan-approve.test.sh` comportamental contra repos desechables reales: aprobación fresca y segunda invocación idempotente en ambos modos, colisión, resume concordante con reconciliación del duplicado, tip movido, historia de implementación tras un tip plan-only, rama sin estado, plan trackeado, mismatch en ambas direcciones, hook que rechaza con rollback y retry en ambos modos, fallo forzado de la escritura del estado con pending como evidencia, y recuperación de pending (positiva y negativa). `tests/skill-plan-branch-contract.test.sh` estático fija los contratos que viven en Markdown (el script invocado en ambos gates, el commit sin rama viejo ausente, baseline/`plan_hash` anclados, la línea roja intacta); `skill-worktree-contract` aserta la frase nueva del contrato ampliado.

## 0.11.0 — 2026-07-30

- **Aislamiento del entorno del usuario en todos los turnos Codex** (M1+M2+M4 del backlog). Hasta ahora los wrappers re-fijaban `sandbox_mode` pero cargaban el `~/.codex/config.toml` del usuario, así que la red del sandbox (`sandbox_workspace_write.network_access`), las raíces escribibles extra (`writable_roots`), las auto-aprobaciones (`approvals_reviewer=auto_review`), los servidores MCP y las execpolicies `.rules` se heredaban en silencio. Cada turno lleva ahora `--ignore-user-config --ignore-rules` — el login sobrevive porque la auth se resuelve por `CODEX_HOME` — más el bloque de pins explícito como defensa en profundidad y declaración verificable de intención: `sandbox_mode`, `network_access=false`, `writable_roots=[]`, `approval_policy=never`, `approvals_reviewer=user`, y `web_search=disabled` **solo donde el turno puede escribir** (implement, image), porque la búsqueda web es una herramienta nativa que `network_access` no gobierna y `implement.tpl` prometía al modelo que no había red. Los asientos read-only conservan la búsqueda por decisión explícita (no pueden escribir y la capacidad es útil); con el config del usuario ignorado, su comportamiento pasa a ser el default determinista de la CLI. **Cambio de comportamiento visible**: el modelo por defecto, los MCP propios y los ajustes de UI del usuario ya no llegan a los turnos de tandem, y el implementador Sol pierde la búsqueda web.
- **Raíz de trabajo explícita, resuelta y validada por un script** (`scripts/worktree-root.sh`, nuevo). `TANDEM_WORKTREE=1` solo estaba cableado para el transporte Opus: con `TANDEM_IMPLEMENTER=sol` el turno corría con el cwd de la sesión — el checkout principal — y `tandem:review` ni mencionaba el worktree, así que su gate de entrada miraba el árbol equivocado y **el commit final podía aterrizar en el árbol equivocado**. El helper imprime el checkout principal sin `TANDEM_WORKTREE`, y con él la ruta absoluta del worktree **registrado** para `tandem/<slug>` leída de `git worktree list --porcelain` (no de la convención `.worktrees/<slug>`, que la skill permite no seguir); cero coincidencias, varias, o una ruta registrada que ya no existe son error duro (exit 65) — nunca un fallback silencioso al principal. La nueva env `TANDEM_CODEX_CWD` traduce esa raíz a `codex exec --cd` y se valida **antes** de `need_codex` (vacía o no-directorio → 64). Deliberadamente NO se mueve `CLAUDE_PROJECT_DIR`: el estado del hilo y el heartbeat siguen bajo el checkout principal, así que `codex-show`/`codex-reset` siguen funcionando desde allí y borrar el worktree no destruye el hilo. `tandem:implement` y `tandem:review` resuelven la raíz una vez y anclan a ella **todo**: cada comando git incluido el commit final, cada Read/Edit/Write por ruta absoluta, cada comando no-git y cada lanzamiento de Codex. `TANDEM_WORKTREE` queda documentado como implement/review-only.
- **Vigilancia del drift de claves** (`scripts/config-probe.sh`, nuevo). La CLI acepta un `-c clave=valor` desconocido en **silencio absoluto** (rc 0), así que el día que una release renombre un pin, el pin deja de aplicar y todo sigue verde. El probe entrega a cada clave pineada un valor deliberadamente inválido y exige que la CLI lo rechace nombrándola; una clave que acepta cualquier cosa es una clave muerta. Usa `codex debug prompt-input` bajo un `CODEX_HOME` desechable — nunca `codex exec`, porque en el caso exacto que busca detectar el override se aceptaría y arrancaría un turno real, gastando cuota y disfrazando el diagnóstico de fallo de red. El job `config-drift` semanal lo ejecuta contra la CLI pineada y contra `@latest`, **sin gate de secret** — el probe no necesita credenciales, así que un repo sin `OPENAI_API_KEY` (el caso común de un fork) también se entera de que un pin dejó de aplicar; el gate por secret queda solo alrededor de los turnos de modelo reales del job `codex-smoke`.
- Suite: 49 casos (de 44). Los tres tests de argv byte a byte cubren el bloque de pins completo y `web_search` en ambos sentidos por rol; nuevos `cwd-pin`, `worktree-root`, `worktree-sol-anchored`, `config-probe` y `skill-worktree-contract` — este último parsea las skills y exige que cada invocación de `codex-start`/`codex-resume` lleve su `TANDEM_CODEX_CWD`, porque el fallo real de M1 vive en Markdown y ningún test de argv puede verlo.

## 0.10.0 — 2026-07-30

- Suite de tests con stub de codex, `shellcheck` pineado y CI (M14 del backlog): 44 casos en `tests/` que dan regresión automática a las ~1.100 líneas de bash endurecido del plugin, sin dependencias nuevas y sin red. El stub `tests/stub/codex` imita el binario real (dispatch `--version`/`login`/`exec`, NDJSON por escenario, `--output-last-message`, exit codes forzables) y se gobierna **solo por variables de entorno** — nada de ficheros de escenario compartidos, así que dos casos no pueden pisarse; registra por invocación el argv completo unido con `\x1f` (aserción de orden exacto con una sola comparación), el prompt drenado de stdin y un **snapshot del heartbeat en fase `running`**, el único momento en que el contrato "el heartbeat running lleva la ruta del NDJSON" es observable.
- Aislamiento total por caso (regla dura tras el incidente 2026-07-20, en que un test escribió `.tandem/` en el checkout real): sandbox propio, ejecución con `env -i` + allowlist explícita, `$SANDBOX/tools/` con symlinks **solo** a los binarios `jq` y `git` concretos (nunca el directorio de Homebrew, que trae bash 5 y quizá el codex real del desarrollador), guard anti-checkout con exit 99 en `lib.sh` y self-check al arranque que verifica dentro del entorno scrubbeado que `codex` resuelve al stub y que `bash` es el `$TESTS_BASH` esperado. Watchdog por caso en bash puro: cada test se lanza con job control para liderar su propio grupo de procesos y el timeout mata el grupo entero, de modo que un stub colgado no deja huérfanos (`tee`/`jq`) vivos — con meta-test (`runner-watchdog-hang`) que lo demuestra vía runner anidado.
- Cobertura de contratos: exit codes exactos por escenario (0/1/2/3/64, incluida la distinción "exit fijo 1 ≠ rc de codex" y "64 nunca degrada a 1"), argv de codex byte a byte para start/resume/swarm y los cuatro roles (con la posición y exclusividad de `-c sandbox_mode=` en resume y los sandboxes pineados frente a cualquier env), el guard anti-fallback de resume con su estado exacto, heartbeat (`running` con ruta de events, SIGTERM → `failed` con rc 143 preservado, SIGKILL → `running` huérfano que la status line pinta `orphaned`, verdict/events como null JSON real), transporte `\x1f` de la status line con campos vacíos consecutivos, degradación sin `jq`, el shim de la status line **ejecutado** en sus cuatro configuraciones de resolución, y la matriz de entorno del doctor (unset vs set-vacío de `TANDEM_IMPLEMENTER`).
- Cuatro bugs reales corregidos al fijar contratos, cada uno con test propio: `codex-resume.sh` interpretaba un `.turn` con `08`/`09` como octal y reventaba con un error crudo de bash antes del heartbeat (ahora `$((10#$TURN + 1))`, `08` → turno 9); `statusline-install.sh` escribía el shim **antes** de validar `settings.json`, así que con un settings corrupto el shim sí se (re)escribía mientras el `die` afirmaba "nothing was changed" (validación movida delante); `hb_end done …` pasaba el literal `done` sin comillas en `codex-start.sh`/`codex-resume.sh`, que ShellCheck marca SC1010; y `statusline.sh` comparaba numéricamente el pid del heartbeat sin sanearlo — un heartbeat corrupto filtraba «integer expression expected» a stderr en cada render (ahora se sanea como el resto de campos numéricos).
- `tests/verify.sh` como punto de entrada único de verificación (el mismo que llama el CI): suite + `shellcheck` sobre `scripts/` y `tests/` + `actionlint` sobre el workflow, con binarios **pineados por checksum** auto-provisionados en `tests/.tools/` (gitignorado, fuera del empaquetado del plugin). Solo se cachean los archivos de release (también en el cache de CI); su sha256 pineado se re-verifica en **cada** ejecución y el binario se re-extrae y publica de forma atómica probando la versión sobre el fichero staged — un cache envenenado o un impostor preexistente en `.tools/` nunca superan el pin commiteado (con test propio de endurecimiento). Una capa que no puede correr falla nombrándose; `TANDEM_VERIFY_OFFLINE=1` es la única degradación y es deliberada y ruidosa. CI en GitHub Actions con `lint` bloqueante, matriz `ubuntu-latest` + `macos-latest` (preflight que verifica bash 3.2 real en `/bin/bash`, porque `env bash` resolvería al bash 5 de Homebrew y probaríamos el intérprete equivocado) con subida de los sandboxes rojos como artifact, y `codex-smoke` semanal/manual no bloqueante que ejercita los wrappers reales contra la CLI pineada y contra `@latest` y corre `check-drift.sh` sobre los fixtures NDJSON.

## 0.9.0 — 2026-07-24

- Implementador seleccionable (`TANDEM_IMPLEMENTER`): **Claude Opus 5 implementa por defecto** vía el subagente restringido `tandem:implementer` (nuevo `agents/implementer.md` — allowlist de harness `Read, Edit, Write, Glob, Grep, Bash`, sin MCP/web/Agent anidado, prohibiciones git en el system prompt); `TANDEM_IMPLEMENTER=sol` restaura el transporte Codex CLI anterior sin cambios (mismos scripts, templates y sandbox `workspace-write`). Motivo: descorrelacionar los puntos ciegos de generador y revisor — hasta ahora Sol implementaba y Sol revisaba (hilo fresco, mismo modelo); con Opus implementando, Sol red-team y review son cross-family en cada gate. Valor desconocido del selector → error duro en la skill y línea FAIL en doctor, nunca fallback silencioso.
- Transporte claude endurecido por el red-team del plan (5 rondas, 12 hallazgos): preflight fail-closed de `CLAUDE_CODE_SUBAGENT_MODEL` (su precedencia pisaría el `model: opus` del agent type) con auto-atestación de modelo en el informe; nuevo template `skills/implement/prompts/implement-claude.tpl` (plan congelado, directorio de trabajo único y absoluto — con `TANDEM_WORKTREE=1` el prompt fija la ruta del worktree y verificación/gate anclan su cwd allí —, contrato de informe y sentinels `IMPLEMENTATION_COMPLETE/PARTIAL`); estado durable espejo en `.tandem/state/implement-claude/<slug>.json` + informes por turno (identidad del intento = `plan_hash` del **blob commiteado** `git rev-parse HEAD:plan` — marcar checkboxes en la working copy no invalida continuaciones — + rama; identidad coincidente permite reanudar, mismatch solo descartar o parar); continuaciones vía `SendMessage` al mismo subagente con cap `TANDEM_IMPL_ROUNDS` leído de disco; guard de liveness **observacional** antes de cualquier reset, keyed por el `task_id` del background task persistido con `status` running/terminal (nunca `SendMessage` como sonda — reanudaría al agente; worktree registrado limpio; estado ausente = ambiguo, no inactivo), en autonomous la ambigüedad termina `FAILED` con estado preservado; baseline de seguridad durable (`base_head` + `remote_snapshot` inmutables al arrancar el intento) para que la verificación de rama/`HEAD`/remotos funcione también tras recovery en sesión nueva; el clean-tree gate aplica solo a intentos frescos — reanudar un intento coincidente llega legítimamente con su trabajo sin commitear.
- Semántica y verificación: `TANDEM_CRITICAL=1` bajo opus no altera el esfuerzo (Agent no lo expone) pero mantiene la review inomitible; bajo sol conserva high→xhigh. La verificación de Fable añade comparación de rama/`HEAD`/remotos contra el baseline del intento — bajo opus, el `base_head`/`remote_snapshot` durable del JSON; bajo sol, el snapshot pre-lanzamiento — (mitiga el Bash sin sandbox OS del transporte claude; aplica también a sol). Nota de sesgo de árbitro en ARCHITECTURE: Fable arbitra hallazgos de Sol sobre código de su propia familia — el estándar de evidencia `file:line` + disposición por hallazgo no se relaja. Doctor muestra el implementador efectivo; README/plugin.json/marketplace.json actualizados al nuevo default (rollback = `TANDEM_IMPLEMENTER=sol`). Limitación v1 documentada: la 2ª línea de la status line no narra implementaciones opus (Claude Code muestra el progreso nativo del subagente).

## 0.8.0 — 2026-07-24

- Modo imagen (`/tandem:image`): generación de assets con la herramienta nativa de Codex (gpt-image-2) guardando en rutas exactas del repo. Nuevo rol `image` en `resolve_role` — Sol `high` (no un tier scout: el modelo de texto escribe el prompt de imagen y dirige el flujo; entender el brief es lo que sube el one-shot), sandbox `workspace-write` fijado, overrides `TANDEM_IMAGE_MODEL`/`TANDEM_IMAGE_EFFORT`. Un hilo por asset (refinar = resume con memoria completa; el template de refine prefiere editar el render anterior a regenerar), brief estructurado en `.tandem/tmp/`, y gate visual de Fable: abre cada PNG con Read y lo juzga contra el brief; auditoría de escrituras por snapshot de `git status --porcelain` (los turnos de imagen solo AÑADEN ficheros, sin rama dedicada porque no hay diff de código). Sentinels `IMAGE_READY`/`IMAGE_BLOCKED` integrados en `hb_verdict` y coloreados en la status line (verde/rojo); doctor informa la política del rol.
- Workaround de transparencia por chroma-key (`scripts/chroma-strip.sh`) para necesidad de negocio (sprites, logos, assets sobre fondos variables): gpt-image-2 no emite fondos transparentes, así que el render va sobre fondo plano `#00ff00` (o `#ff00ff` con sujetos verdes) y el script convierte el color clave en canal alfa — backend python3+Pillow (distancia Chebyshev vectorizada con ImageChops, rampa de alfa graduada y despill del canal dominante en los bordes) con fallback a ImageMagick (`-fuzz`/`-transparent`, alfa binario), y modo `--check` que verifica alfa real (parte del gate de la skill). Sin backend → `IMAGE_BLOCKED` honesto; doctor informa el backend detectado y qué instalar.

## 0.7.0 — 2026-07-23

- Modo ultra (`/tandem:ultra`): enjambres multi-agente estilo ultracode dirigidos por Fable — review adversarial multi-dimensión con verify por refutación, panel de jueces, caza de bugs loop-until-dry, barrido de investigación. Mapeo de asientos a Codex: `judge` = Sol `xhigh` (donde iría Fable), `worker` = Sol `high` (donde iría Opus), `scout` = Luna `high` (donde iría Haiku); overrides `TANDEM_ULTRA_{JUDGE,WORKER,SCOUT}_MODEL`/`_EFFORT`. Nuevo `scripts/codex-swarm.sh`: turno Codex one-shot y paralelo-seguro — hilo fresco por seat (sin resume: la independencia es el punto), sandbox `read-only` fijado para todos los tiers, estado por run en `.tandem/state/ultra/<run>/`, sin heartbeat compartido (N turnos paralelos pelearían por `current.json`; narran el panel de shell y la UI del Workflow). Los `agent()` del workflow son envoltorios `haiku` que lanzan el script y estructuran la respuesta con schema. Deliberación previa obligatoria (forma, asientos, coste) con aprobación humana — o brief completo en autonomous; concurrencia acotada (`TANDEM_ULTRA_CONCURRENCY`, default 4); el enjambre nunca escribe ni commitea y nunca sustituye el gate de `tandem:review`. Doctor informa la política de tiers ultra. Degradación sin Workflow: fan-out con `Agent` o turnos secuenciales en background, mismos scripts y prompts.

- Modo autonomous (`TANDEM_AUTONOMOUS=1`): `/tandem:run` de principio a fin sin interacción. Los gates humanos se convierten en política verificable — plan commiteado solo con `VERDICT: APPROVED`; commit final solo con review `APPROVED` + testing gate en verde, siempre en `tandem/<slug>`. La entrevista se sustituye por una sección **Assumptions** auditable en el plan (default conservador + razón por decisión); brief insuficiente → el run no empieza. `TANDEM_PROMOTE_REVIEWS` pasa a ser obligatorio (0/1) en autonomous y se valida en el preflight (también en doctor). Estados terminales explícitos con informe final: `COMPLETED`/`DEADLOCK`/`PARTIAL`/`FAILED`, todos retomables con las skills interactivas. Invariantes intactas: deadlock terminal (nunca aprobación por agotamiento), NEEDS_REWORK → DEADLOCK, review nunca omitible, PARTIAL tras caps no avanza a review, nunca push/merge/rama por defecto, sandboxes y caps sin cambios.

## 0.5.0 — 2026-07-20

- Heartbeat visible desde worktrees: los turnos lanzados dentro de un worktree enlazado (`TANDEM_WORKTREE`) escribían el heartbeat en el `.tandem/` del worktree y la status line, que mira el checkout principal, nunca lo veía. Ahora `state_init` resuelve el repo principal vía `git rev-parse --git-common-dir` y el heartbeat va siempre allí (el estado de hilos sigue donde corrió el turno); la status line hace además el fallback inverso para sesiones abiertas dentro de un worktree.
- Actividad en vivo en la status line: el heartbeat incluye la ruta del `events.ndjson` del turno y, mientras `running`, la línea 2 muestra qué hace Codex ahora mismo (`exec pytest -q…`, `edit models.py`, `thinking…`, `writing reply…`) leyendo el último evento con lectura acotada (`tail -c`) tolerante a líneas parciales.
- Milestones en vivo en el panel de shell: `codex-start/resume` pasan el NDJSON por `tee` + `stream_milestones`, que narra en stdout cada hito (`» exec …`, `✓ ok` / `✗ exit N`, `» edit a, b +N more`, `» turn done — tokens in/out`, `✗ turn failed`) — el panel "Shell details" de un turno en background se convierte en un feed de progreso. `PIPESTATUS[0]` preserva el exit code real de codex (un fallo del filtro nunca se disfraza de fallo de Codex) y el filtro drena el stream si muere para no matar a codex con SIGPIPE.
- Fix del transporte de campos en la status line: `@tsv` + `IFS=$'\t'` colapsaba campos vacíos (el tab es whitespace para `read`), desplazando los siguientes una posición — p.ej. con `verdict` nulo la ruta de events acababa en la variable equivocada, y sin `effort` el % de contexto se corría. Sustituido por unit separator (`\x1f`), que no colapsa.

## 0.4.0 — 2026-07-20

- Status line (`scripts/statusline.sh`): modelo, effort, porcentaje de contexto con barra, coste y rama en la primera línea; la puerta de Codex en la segunda (rol, modelo, effort, turno, sandbox, cronómetro, veredicto), coloreada por desenlace y visible solo cuando hay actividad reciente. Degrada a una línea corta si falta `jq`, el payload es inválido o el proyecto no tiene `.tandem/`.
- Heartbeat `.tandem/state/current.json`: `codex-start.sh`/`codex-resume.sh` marcan cada turno como `running` y lo cierran con `done` + veredicto extraído del sentinel de la respuesta. Un `trap EXIT` cubre `die`, Ctrl-C y crashes dejando `failed`; la status line detecta además procesos huérfanos vía pid. `codex-reset.sh` limpia el heartbeat solo si describe el target reseteado.
- Instalación portable de la status line (`/tandem:statusline` + `scripts/statusline-install.sh`): Claude Code no deja a un plugin declarar la status line principal, así que la skill la instala con consentimiento — shim en `~/.claude/tandem-statusline.sh` que re-resuelve el script del plugin en cada render (sobrevive a actualizaciones, fallback mínimo si tandem desaparece) + entrada `statusLine` en el `settings.json` del usuario (atómico, backup, exit 2 ante una statusLine ajena salvo `--force`, y rehúsa tocar un settings corrupto). `codex-doctor.sh` informa del estado de la integración. Respeta `CLAUDE_CONFIG_DIR`.

## 0.3.0 — 2026-07-14

- Respuestas de Codex por turno: los scripts guardan `state/<clave>.t<N>.reply.txt` en cada turno (el historial completo del debate queda legible por ronda); `<clave>.last.txt` pasa a ser un puntero de conveniencia que solo se actualiza tras superar todas las comprobaciones de éxito.
- Registro durable del review (opcional): `tandem:review` puede promocionar el veredicto y el resumen del debate a `docs/reviews/<slug>.md` en el commit de aprobación — `TANDEM_PROMOTE_REVIEWS=1` siempre, `0` nunca, sin definir se ofrece en el gate humano.

## 0.2.1 — 2026-07-14

- Punto ciego de archivos nuevos corregido (detectado en el test end-to-end del pipeline): `git diff HEAD` no muestra archivos sin trackear, así que los prompts del code review y los pasos de verificación de `implement`/`review` ahora exigen leer directamente cada entrada `??` de `git status -s`, y el context file del review lista los archivos cambiados marcando los untracked.

## 0.2.0 — 2026-07-14

- Política de modelos "solo Sol" para máximo desempeño: la implementación pasa de `gpt-5.6-luna` a `gpt-5.6-sol` (effort `high`); `TANDEM_CRITICAL=1` ahora sube el effort de implementación a `xhigh` en lugar de cambiar de modelo. Review/ask siguen en Sol `xhigh`.

## 0.1.0 — 2026-07-14

Primera versión del plugin `tandem`.

- Skills: `run`, `plan`, `implement`, `review`, `ask`, `doctor`.
- Scripts compartidos endurecidos (`codex-start/resume/show/reset/doctor` + `_common`): sandbox fijado por rol y re-fijado en cada resume, estado por proyecto en `.tandem/`, salidas por turno, detección del fallback silencioso de `resume`, errores visibles, portable a macOS/BSD (bash 3.2).
- Política de modelos: Sol `xhigh` para review/ask (read-only), Luna `high` para implementación (workspace-write), `TANDEM_CRITICAL=1` para implementar con Sol.
- Documentación de arquitectura y roadmap de migración a Codex MCP.
