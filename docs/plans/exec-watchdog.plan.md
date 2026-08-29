# Plan: exec-watchdog — watchdog de turno para el transporte exec (start, swarm y resume)

**Backlog:** M24 (P2/M) · **Origen:** informe de campo 2026-08-21, hallazgo A1 +
enmienda E-A1 (`docs/audits/informe-campo-2026-08-21.md`) · **Fecha:** 2026-08-29 ·
**Modo:** interactivo · **Base:** main **7fbd541** (v0.31.0).

## Goal

`codex exec` se lanza hoy sin deadline en los tres wrappers
(`codex-start.sh:147-156` rama exec, `codex-resume.sh:161-169`,
`codex-swarm.sh:285-294`), y las skills mandan el trabajo real con
`run_in_background: true` — donde el tope de 600 s del tool Bash no aplica: un turno
colgado es ilimitado y su único observador es humano. En un enjambre, además, retiene
uno de los slots del semáforo (el timeout de 1800 s acota la espera de slot, no al
ocupante). El hueco alcanza al propio transporte MCP: sus continuaciones viajan
SIEMPRE por el híbrido `exec resume`, así que el watchdog de `_mcp.sh` solo protege
el primer turno de cada hilo — las rondas 2+ de una review a xhigh, los turnos más
largos del sistema, quedan sin observador (E-A1). Este plan porta el watchdog por
rol del transporte MCP al exec en los tres wrappers: misma matriz de deadlines por
modo de lanzamiento dominante, misma familia de variables
(`TANDEM_EXEC_TIMEOUT_SECONDS`, validación fail-closed 64 antes de dependencias),
TERM→KILL con grupo de proceso, quota contabilizada en el timeout, heartbeat
cerrando en `failed` (start/resume) y slot liberado (swarm). Es una generalización
de piezas que ya existen en el repo — `mcp_kill_group`/`mcp_timeout_validate` en
`_mcp.sh` y el `smoke_watchdog` del doctor — no una pieza nueva.

## Approach

1. **`scripts/_common.sh` — los helpers compartidos, UNA definición (lección de
   `_pins.sh`):**
   - `kill_group_term_kill <pid> <group> <grace>` — el `mcp_kill_group` de
     `_mcp.sh:431-450` MOVIDO aquí literalmente (grupo comprobado con independencia
     del líder: durante la gracia TERM→KILL el líder suele haber muerto mientras un
     descendiente TERM-resistente mantiene vivo el grupo). `_mcp.sh` pasa a llamar
     al helper movido — mismo comportamiento byte a byte, cero duplicación.
   - `exec_timeout_validate <profile>` — espejo de `mcp_timeout_validate`
     (`_mcp.sh:186-209`): resuelve `EXEC_TIMEOUT` desde literales por perfil y
     aplica el override `TANDEM_EXEC_TIMEOUT_SECONDS` con disciplina `${VAR+set}`
     (definida-pero-vacía o no-entero-positivo → die 64 nombrando la variable).
     Literales PROPIOS, no alias de los MCP (mismos valores hoy, divergibles mañana
     sin renombrar): `TANDEM_EXEC_TIMEOUT_DEFAULT=540` (perfiles foreground: `ask`,
     `image`), `TANDEM_EXEC_TIMEOUT_DEFAULT_REVIEW=3600`,
     `TANDEM_EXEC_TIMEOUT_DEFAULT_IMPLEMENT=3600` (perfiles background) y
     `TANDEM_EXEC_TIMEOUT_DEFAULT_ULTRA=3600` (los seats de enjambre corren en
     background vía Workflow, perfil review). La matriz se decide por el MODO DE
     LANZAMIENTO DOMINANTE, nunca por el sandbox — la regla documentada en
     `_mcp.sh:177-185`.
   - `exec_deadline_wait <job-pid> <group> <seconds> <timeout-marker>` — el bucle
     de deadline del padre, POR CONTADOR (la forma exacta del `smoke_watchdog` del
     doctor, P2-2 de la ronda 1): como máximo `<seconds>` iteraciones de
     `kill -0` + `sleep 1` — libre de `date` por construcción, así que un reloj
     roto no puede convertirlo en un watchdog infinito (no existe camino que
     recompute «restante»). Al agotar el contador con el job vivo:
     `kill_group_term_kill` con el flag `<group>` VERIFICADO (P2-1) y marker en
     disco. Sin fork de watchdog: durante el turno el padre no tiene otro trabajo,
     así que el bucle ES el watchdog (el doctor forkeja el suyo porque usa `wait`
     para el rc; aquí el rc viaja por fichero — punto 2).
2. **Los tres wrappers — reestructura del pipeline caliente, misma forma en los
   tres.** Hoy:
   `codex exec … | tee "$EVENTS_FILE" | stream_milestones` + `rc=${PIPESTATUS[0]}`
   en foreground, sin límite. Pasa a:

   ```bash
   TURN_JOB=0
   TURN_GROUP=0   # consumidas por el dueño EXIT: inicializadas ANTES de armarlo
                  # y antes del fork (set -u; el precedente de codex-swarm.sh:177)
   TURN_PENDING_SIG=0
   trap 'TURN_PENDING_SIG=130' INT   # SECCIÓN CRÍTICA fork→publicación: registrar,
   trap 'TURN_PENDING_SIG=143' TERM  # no salir (codex-swarm.sh:183-230, verbatim)
   set -m
   ( codex exec … - <"$PROMPT_FILE" 2>"$EVENTS_FILE.stderr" \
       | tee "$EVENTS_FILE" | stream_milestones
     printf '%s' "${PIPESTATUS[0]}" >"$RC_FILE" ) &
   TURN_JOB=$!
   set +m
   kill -0 -- -"$TURN_JOB" 2>/dev/null && TURN_GROUP=1
   trap 'exit 130' INT               # propiedad publicada: dueños normales
   trap 'exit 143' TERM
   [ "$TURN_PENDING_SIG" -ne 0 ] && exit "$TURN_PENDING_SIG"  # → dueño EXIT limpia
   exec_deadline_wait "$TURN_JOB" "$TURN_GROUP" "$EXEC_TIMEOUT" "$TIMEOUT_MARK"
   wait "$TURN_JOB" 2>/dev/null || true
   TURN_JOB=0
   ```

   Publicación atómica de la propiedad (P1-1 de las rondas 4 y 5): durante la
   ventana fork→publicación las señales solo se REGISTRAN — el patrón exacto de
   la sección crítica del semáforo de swarm («signals are only recorded, so the
   section is safe by construction») — y se honran inmediatamente después, con
   `TURN_JOB`/`TURN_GROUP` ya publicados, de modo que el dueño EXIT limpia el
   grupo ENTERO: la ventana en la que un TERM encontraría `TURN_JOB=0` (no matar
   nada) o `TURN_GROUP=0` (matar solo al líder, dejando vivos codex/tee) queda
   eliminada por construcción, no por timing. En swarm, esta sección se integra
   con los handlers de registro que el seat YA tiene (`PENDING_SIG`): no se
   duplican — la ventana del fork queda dentro de la disciplina existente del
   seat y `sig_honor` se invoca tras la publicación. Sin hooks de test en el
   camino caliente (deliberado, mismo estatus que la sección crítica del swarm):
   el test de interrupción cubre el camino post-publicación.

   Con `set -m` el subshell es líder de su PROPIO grupo (`$!` = PGID, el mismo
   truco del `smoke_run_one` del doctor), y el invariante se VERIFICA tras el
   fork en vez de asumirse (P2-1, el mismo `kill -0 -- -pid` de `_mcp.sh:509` y
   `codex-doctor.sh:439`): con `TURN_GROUP=0` el helper degrada a kill por PID
   del líder — nunca se aborta un turno ya pagado por un job control caprichoso,
   y la garantía TERM-resistente queda condicionada al grupo, como en el doctor.
   El TERM→KILL alcanza a codex, a tee y a cualquier descendiente
   TERM-resistente sin tocar al wrapper. El rc de codex viaja por `RC_FILE`
   (bajo `$STATE_ROOT/tmp`, nombre único por turno, borrado tras leerse):
   `PIPESTATUS` no cruza un job en background, y el fichero preserva el contrato
   «un hipo del filtro nunca se disfraza de fallo de codex» que hoy fija
   `start-codex-fails-exit1-not-rc.test.sh`. Clasificación tras el `wait`:
   marker presente → TIMEOUT (mensaje con el deadline, el rol/perfil y el nombre
   `TANDEM_EXEC_TIMEOUT_SECONDS`, como el mensaje MCP); sin marker →
   `rc="$(cat "$RC_FILE")"` (ausente/no-numérico → fallo explícito 1). La
   contabilidad (`turn_usage` sobre lo que tee llegó a volcar) corre ANTES de
   cualquier clasificación, como siempre: un turno que emitió `turn.completed` y
   colgó después ya gastó su quota — el ledger se escribe igual.

   **Dueño compuesto de lifecycle (P1-1) — el grupo del turno nunca sobrevive al
   wrapper.** Hoy codex comparte el grupo del wrapper (sin job control), así que
   una señal de grupo lo alcanza; con grupo propio eso dejaría de ser verdad y
   una cancelación huérfanaría a codex ESCRIBIENDO y gastando quota. El mismo
   problema que el transporte mcp resolvió con su dueño único (`_mcp.sh:388`):
   - **start/resume:** INT/TERM se limitan a `exit 130`/`exit 143` y TODO pasa
     por UN dueño EXIT con la forma EXACTA del patrón mcp (`_mcp.sh:400-404`,
     refinamiento P1-1(b) de la ronda 2 — el status se captura ANTES de limpiar,
     o una limpieza exitosa lo machacaría con 0):

     ```bash
     turn_lifecycle_guard() {
       local rc=$? g                                # PRIMERO: el status real
       if [ "${TURN_JOB:-0}" -gt 0 ] 2>/dev/null; then
         g="${TURN_GROUP:-0}"
         kill -0 -- -"$TURN_JOB" 2>/dev/null && g=1   # re-probe: defensa 0→1
         kill_group_term_kill "$TURN_JOB" "$g" 1
         wait "$TURN_JOB" 2>/dev/null || true       # cosechar ANTES de publicar
         TURN_JOB=0
       fi
       [ "${HB_ACTIVE:-0}" = "1" ] && hb_write failed
       exit "$rc"
     }
     ```

     El `wait` no es decoración (P2-1 de la ronda 3): el helper de kill solo
     ENVÍA señales — el reparto kill-luego-wait es el de `mcp_server_stop`
     (`_mcp.sh:472-473`), y sin él el heartbeat `failed` (o el slot liberado, en
     swarm) se publicaría antes de que el grupo esté cosechado, con zombies que
     vuelven flaky el test de interrupción.

     `hb_guard` NO se reutiliza tras la limpieza (recaptura `$?` al entrar,
     `_common.sh:342`): el dueño escribe el heartbeat directamente, misma
     semántica, menos superficie. Un timeout (`die … 1`), un fallo codex (1) o
     un TERM (143) conservan su exit code; los tests de exit codes existentes lo
     vigilan sin editarse.
   - **swarm:** el trap EXIT existente (`slot_release`) se extiende con el mismo
     orden — status capturado a la entrada, reap del grupo del turno, liberar el
     slot, `return 0` del trap preservando el exit del script (contrato actual
     de `slot_release`); la semántica de señales del seat
     (record-and-honor-at-boundary) queda intacta.
   - `TURN_JOB` se limpia inmediatamente tras el `wait` para que el dueño jamás
     mate un PID reciclado.
   - **`codex-start.sh`:** el watchdog arma SOLO la rama exec (la rama mcp ya
     tiene el suyo). `exec_timeout_validate "$ROLE_ARG"` en la ventana de usage
     errors, junto a `web_search_validate`/`transport_resolve`. Timeout → mensaje +
     `die … 1` → `hb_guard` cierra el heartbeat en `failed` (el trap de `hb_begin`
     ya existe).
   - **`codex-resume.sh`:** idéntico, SIEMPRE armado (aquí vive el cierre real de
     E-A1: las continuaciones del transporte mcp son `exec resume`). Perfil = rol.
   - **`codex-swarm.sh`:** `exec_timeout_validate ultra` junto a
     `ultra_int_validate`. La semántica de señales del seat queda INTACTA
     (record-and-honor-at-boundary): el watchdog mata al grupo de CODEX, jamás al
     seat — el seat sigue vivo, contabiliza, clasifica el timeout, y su trap EXIT
     libera el slot (la sinergia E-A1 que reduce la incidencia de M30). Sin
     heartbeat: el swarm no lo tiene por diseño (N seats pelearían por
     current.json) y este plan no se lo inventa — sus observables de timeout son
     el exit 1, el mensaje y el slot liberado.
3. **`scripts/_mcp.sh` — solo el reemplazo de `mcp_kill_group` por el helper
   movido** (alias fino o llamada directa): comportamiento idéntico, fijado por la
   suite mcp existente sin editar una aserción.
3b. **Las excepciones foreground documentadas ganan el override explícito
   (P1-3).** La matriz por modo dominante deja fuera los lanzamientos foreground
   legítimos de review/implement — las plan reviews de planes pequeños, los
   diffs pequeños de cr, y los nudges de plan/review/implement — cuyo 3600
   excede el cap de 600 s del tool Bash: ahí el cuelgue moriría sin clasificar,
   como hoy. En vez de un default foreground que mataría el caso de uso
   principal del rol (el fail-open que `_mcp.sh:37-44` rechaza), esas líneas de
   comando en las skills prefijan `TANDEM_EXEC_TIMEOUT_SECONDS=540` — el mismo
   mecanismo por-invocación de `TANDEM_TURN_EFFORT`, en el mismo sitio (la línea
   del comando), pineado por los skill-contract-tests, que es la manera
   establecida del repo de fijar comandos de skill. Ficheros:
   `skills/plan/SKILL.md` (nudge + lanzamiento foreground de plan pequeño),
   `skills/review/SKILL.md` (nudge ×2 + foreground de diff pequeño),
   `skills/implement/SKILL.md` (nudge), y los contract-tests que pinan esas
   líneas (al menos `skill-turn-effort-contract.test.sh`; el implementador
   actualiza exactamente los que fallen nombrando la línea).
4. **`tests/stub/codex` — un flag nuevo, mínimo:** `CODEX_STUB_HANG_AFTER_EVENTS=1`
   para el camino exec (el lado MCP ya tiene su equivalente
   `CODEX_STUB_MCP_HANG_AFTER_EVENTS`): emite el stream completo con
   `turn.completed` y SOLO ENTONCES cuelga — el caso «quota gastada, luego cuelgue»
   que la contabilidad-antes-del-éxito existe para no perder.
5. **Tests — NUEVO `tests/exec-watchdog.test.sh`:**
   - Cuelgue puro por wrapper (`CODEX_STUB_SCENARIO=hang`,
     `CODEX_STUB_HANG_SECONDS=600`, `TANDEM_EXEC_TIMEOUT_SECONDS=1`): los tres
     wrappers salen 1 en segundos, stderr nombra deadline y variable, sin línea
     `USAGE:` (el stream no llevó `turn.completed`), y en start/resume el
     heartbeat queda `failed`; en swarm el slot queda LIBRE tras el timeout (un
     seat posterior adquiere `slot.1` de inmediato) y el prompt/reply del seat
     quedan como los dejó el intento.
   - Cuelgue TERM-resistente (`CODEX_STUB_HANG_RESISTANT=1`): tras el KILL no
     sobrevive ningún descendiente (el hijo del stub muere con el grupo).
   - Cuelgue post-quota (`CODEX_STUB_HANG_AFTER_EVENTS=1`): el ledger
     `*.usage.json` aterriza y la línea `USAGE:` se emite AUNQUE el turno termine
     clasificado como timeout — la invariante de contabilidad-antes-del-éxito.
   - Validación fail-closed: `TANDEM_EXEC_TIMEOUT_SECONDS` vacía/`abc`/`0` → 64
     nombrando la variable en los tres wrappers, bajo PATH mínimo (usage error
     gana a «missing dependency»), sin invocar codex y con el contador de turno
     intacto (patrón de `web-search-switch.test.sh`).
   - Interrupción del wrapper (P1-1): con un turno colgado en vuelo, señal TERM
     SOLO al wrapper — el grupo interior registrado desaparece sin reaping del
     lado del test, el heartbeat queda `failed` (start/resume) y el slot
     liberado (swarm).
   - Reloj roto (P2-2): con un `date` roto/no-numérico en el PATH, el timeout
     dispara igual — el bucle es por contador y no puede volverse infinito.
   - Ancla estática: el literal del perfil foreground
     (`TANDEM_EXEC_TIMEOUT_DEFAULT`) se queda bajo 600 — el mismo lazo estático
     que `mcp-transport-parity.test.sh` ata para el lado MCP, para que el
     watchdog clasifique ANTES de que el tool Bash mate al wrapper (restricción
     de `_mcp.sh:29-36`, citada por E-A1).
   - **`tests/mcp-transport-parity.test.sh` (P1-2) — la ÚNICA edición de un test
     existente, deliberada y nombrada:** su sección 1 congela EL FUENTE del
     bloque exec de start y resume byte a byte hasta `rc="${PIPESTATUS[0]}"`,
     precisamente la forma que este plan reestructura. Los dos freezes se
     sustituyen por el freeze del bloque NUEVO (job + rc-file + deadline) —
     mismo propósito: una rama mcp que reordene o derive el bloque exec sigue
     fallando aquí antes de sobrevivir hasta un turno real. Toda aserción de
     comportamiento del test se conserva.
   - **Resto de la suite: intacta y es la prueba del default.** Sin la variable
     y con turnos que completan, nada cambia: los literales de argv no se tocan
     (el watchdog no añade NI un token al argv), y los tests de heartbeat
     (`hb-term-vs-kill`, `hb-running-snapshot`, `common-hb-*`), de PIPESTATUS
     (`start-codex-fails-exit1-not-rc`) y de semáforo (`swarm-semaphore-*`)
     deben pasar SIN editar una aserción — son la especificación de la
     reestructura. Excepciones nombradas: el source-freeze de arriba y los
     contract-tests de skill que pinan las líneas de comando tocadas por 3b.
6. **Docs y versión.** README (párrafo de overrides: la variable, la matriz y la
   restricción foreground; mención en la sección de observabilidad),
   `docs/ARCHITECTURE.md` (sección del transporte: el watchdog ya no es exclusivo
   de mcp), `CHANGELOG.md` 0.32.0 + `.claude-plugin/plugin.json` 0.32.0,
   `docs/BACKLOG.md`: M24 → `hecha (v0.32.0)`, más una nota de una línea en M23
   (uno de sus disparadores declarados — «un watchdog por seat que el semáforo no
   cubra» — queda desactivado a coste M, E-A1) y en M30 (la incidencia baja sola:
   TERM del watchdog → trap EXIT → slot liberado).

## Key decisions & tradeoffs

- **Bucle de deadline en el padre, POR CONTADOR, sin fork de watchdog.** Durante
  el turno el padre solo espera, así que el bucle es el watchdog; el doctor
  forkeja el suyo porque necesita `wait` para el rc — aquí el rc viaja por
  fichero. Contador de iteraciones en vez de deadline con `date` (P2-2): acotado
  por construcción, sin camino de reloj roto que lo vuelva infinito. Menos
  procesos, menos traps heredados (la lección del `mcp_fifo_guard`), mismo
  TERM→KILL. Alternativa rechazada: portar el fork del doctor tal cual — más
  piezas móviles para el mismo disparo.
- **El grupo del turno tiene dueño de lifecycle en el wrapper (P1-1).** Aislar a
  codex en su propio grupo protege al wrapper del TERM→KILL, pero invierte el
  riesgo: una cancelación del wrapper dejaría el turno vivo y escribiendo. El
  dueño compuesto (INT/TERM/EXIT → matar y esperar el grupo del turno → cierre de
  heartbeat/slot) restaura la garantía de hoy con la estructura nueva — el patrón
  exacto del dueño único del transporte mcp. Residual declarado: un SIGKILL
  directo al wrapper salta cualquier trap y huérfana el grupo — la misma clase de
  residual que el slot huérfano de M30, y con la misma respuesta (herramienta
  explícita, no promesa).
- **Subshell-job con `set -m` + rc-file, en vez de mantener el pipeline foreground
  y adivinar el PGID.** Con job control el subshell backgroundeado ES el líder de
  grupo y `$!` ES el PGID (precedente: `smoke_run_one`); un pipeline foreground no
  expone su PGID sin `ps`, y matar por PID suelto dejaría vivos a los
  descendientes TERM-resistentes. Coste: `PIPESTATUS` deja de estar disponible
  directamente y se preserva vía rc-file — el contrato lo vigila un test existente
  sin editar.
- **`TANDEM_EXEC_TIMEOUT_SECONDS` propia; los turnos exec NUNCA leen
  `TANDEM_MCP_TIMEOUT_SECONDS`.** Predictibilidad: cada transporte tiene un mando
  con su nombre. Tradeoff declarado (el más contestable): bajo
  `TANDEM_TRANSPORT=mcp`, el primer turno de un hilo obedece la variable mcp y sus
  continuaciones (`exec resume`) la exec — quien suba una debe subir la otra; el
  README lo documenta junto a la matriz. Alternativa rechazada: que exec-resume
  herede la variable mcp cuando `TRANSPORT_OPT_IN=1` — acopla los mandos y hace
  imposible razonar cuál aplica sin leer el estado del turno.
- **Literales de default propios (540/3600/3600/3600), no alias de los MCP.** El
  mismo argumento que `TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT` documenta en
  `_mcp.sh:55-57`: los valores coinciden hoy y pueden divergir mañana sin
  renombrar nada. El perfil ultra es nuevo (mcp no cubre swarm) y nace en 3600:
  seats a high/xhigh en background, perfil review.
- **El swarm sigue sin heartbeat.** El acceptance del backlog dice «heartbeat en
  failed» en general; el diseño real del swarm lo excluye a propósito
  (`codex-swarm.sh:30-31`) y este plan no revierte esa decisión: en swarm los
  observables del timeout son exit 1 + mensaje + slot liberado. Inventar un
  heartbeat por seat sería alcance de M23/M27, no de M24.
- **Matriz por modo dominante + override explícito en cada excepción foreground
  documentada (P1-3).** El default exec de review/implement es 3600 (su modo
  dominante es background; un default < 600 mataría el caso de uso principal del
  rol, exactamente el fail-open que `_mcp.sh:37-44` rechaza), y el perfil real de
  cada lanzamiento no es derivable dentro del wrapper. La resolución no es
  prosa suelta: las líneas de comando foreground de las skills (nudges, plan
  pequeño, diff pequeño) prefijan `TANDEM_EXEC_TIMEOUT_SECONDS=540` y los
  skill-contract-tests las pinan — el mecanismo y el enforcement de
  `TANDEM_TURN_EFFORT`. Con eso, TODO lanzamiento documentado queda bajo un
  watchdog que clasifica antes que el cap del tool; un foreground fuera de
  contrato queda bajo el cap externo, como hoy.
- **Timeout sale 1, nunca un código nuevo.** La quota ya se gastó (a diferencia
  del 75 de «slot nunca adquirido»); el mensaje, no el código, lleva la
  clasificación — paridad con el camino mcp, cuyo timeout también muere en 1.

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `scripts/_common.sh` | `kill_group_term_kill` (movido de `_mcp.sh`), `exec_timeout_validate` + literales por perfil, `exec_deadline_wait` |
| `scripts/_mcp.sh` | `mcp_kill_group` delega en el helper movido — comportamiento idéntico |
| `scripts/codex-start.sh` | validador en ventana usage-error; reestructura del pipeline exec a job+rc-file+deadline; dueño compuesto de lifecycle (turno+heartbeat); clasificación de timeout |
| `scripts/codex-resume.sh` | ídem, siempre armado (cierre de E-A1) |
| `scripts/codex-swarm.sh` | validador (perfil ultra); misma reestructura; señales del seat intactas; trap EXIT extendido: reapea el grupo del turno y libera el slot |
| `tests/stub/codex` | flag `CODEX_STUB_HANG_AFTER_EVENTS` en el camino exec |
| `tests/exec-watchdog.test.sh` | NUEVO — cuelgue puro ×3, TERM-resistente, post-quota con ledger, interrupción del wrapper (P1-1), date roto (P2-2), validación 64×3, ancla estática foreground < 600 |
| `tests/mcp-transport-parity.test.sh` | P1-2 — los dos source-freezes del bloque exec se actualizan a la forma nueva; aserciones de comportamiento intactas |
| `skills/plan/SKILL.md` · `skills/review/SKILL.md` · `skills/implement/SKILL.md` | P1-3 — `TANDEM_EXEC_TIMEOUT_SECONDS=540` prefijado en nudges y lanzamientos foreground documentados |
| skill-contract-tests afectados (al menos `skill-turn-effort-contract.test.sh`) | pinan las líneas de comando tocadas por el punto anterior |
| `README.md` | variable + matriz + restricción foreground + nota mcp/exec |
| `docs/ARCHITECTURE.md` | el watchdog deja de ser exclusivo del transporte mcp |
| `CHANGELOG.md` · `.claude-plugin/plugin.json` | entrada y bump 0.32.0 |
| `docs/BACKLOG.md` | M24 → `hecha (v0.32.0)`; notas de una línea en M23 y M30 |

## Acceptance & proof

1. Un turno colgado en cualquiera de los tres wrappers muere por TERM→KILL dentro
   del deadline de su perfil, con exit 1 y el mensaje nombrando deadline y
   `TANDEM_EXEC_TIMEOUT_SECONDS`; en start/resume el heartbeat queda `failed`; en
   swarm el slot queda liberado (un seat posterior lo adquiere de inmediato).
2. Un turno que emitió `turn.completed` y colgó después conserva su ledger
   `*.usage.json` y su línea `USAGE:` aunque el desenlace sea timeout — la
   contabilidad corre antes que cualquier clasificación.
3. Un cuelgue TERM-resistente no deja ningún descendiente vivo tras el KILL.
4. `TANDEM_EXEC_TIMEOUT_SECONDS` vacía, no numérica o 0 → 64 nombrando la
   variable, en los tres wrappers, antes de dependencias, sin invocar codex y con
   el contador de turno intacto.
5. Un wrapper interrumpido (TERM solo al wrapper, turno colgado en vuelo) no deja
   el grupo del turno vivo: el dueño de lifecycle lo reapea antes de cerrar
   heartbeat (start/resume) o de soltar el slot (swarm).
6. Con un `date` roto en el PATH el timeout dispara igual: el bucle es por
   contador y no tiene camino infinito.
7. Sin la variable y con turnos que completan, NADA cambia: argv byte a byte
   idéntico (el watchdog no toca el argv) y la suite existente — heartbeat,
   PIPESTATUS, semáforo, literales — pasa sin editar una sola aserción, con DOS
   excepciones nombradas y deliberadas: el source-freeze de
   `mcp-transport-parity.test.sh` (que congela la forma que este plan
   reestructura y se mueve con ella) y los skill-contract-tests de las líneas de
   comando que ganan el override foreground.
8. El literal del perfil foreground (`TANDEM_EXEC_TIMEOUT_DEFAULT`) queda bajo el
   cap de 600 s del tool Bash, atado estáticamente por test como en el lado mcp;
   toda línea de comando foreground documentada en las skills lleva
   `TANDEM_EXEC_TIMEOUT_SECONDS=540` explícito, pineado por contrato.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint).

## Risks

- **Reestructura del camino caliente en los tres wrappers a la vez.** Mitigación:
  la forma es idéntica en los tres, los contratos finos ya están pineados por
  tests que NO se editan (heartbeat, rc-vs-PIPESTATUS, semáforo, argv), y el
  precedente de `set -m` + grupo propio corre en producción en el doctor.
- **Job control en bash 3.2 no interactivo / BSD.** `set -m` alrededor del fork es
  exactamente lo que `smoke_run_one` y el stub MCP ya hacen en macOS stock; el
  riesgo real es un `wait` que devuelva el estado del job tras el KILL — por eso
  el rc viaja por fichero y el `wait` final va con `|| true`.
- **tee y pérdida de cola del stream al matar el grupo.** Aceptado y correcto: la
  contabilidad lee lo que aterrizó; «sin `turn.completed`» significa «sin usage»,
  que es la semántica documentada de `turn_usage`. El caso contrario (quota
  gastada antes del cuelgue) queda cubierto por el flag nuevo del stub.
- **Un timeout demasiado corto heredado del entorno** mataría turnos legítimos en
  cadena. Mitigación: la variable es override explícito, los defaults son por
  perfil y fail-closed (vacía = 64, nunca un default silencioso), y el mensaje de
  timeout nombra la variable para que el diagnóstico sea de una línea.
- **Deriva entre las dos matrices (exec/mcp).** Literales separados a propósito;
  el ancla estática nueva ata los foreground de ambas al mismo techo (< 600), y el
  CHANGELOG documenta la equivalencia de valores en origen.

## Out of scope

- Heartbeat por seat de swarm (diseño deliberado del swarm; sería M23/M27).
- Watchdog para `mcp-probe.sh` (tiene el suyo, `TANDEM_MCP_PROBE_TIMEOUT_SECONDS`)
  y para el doctor (`TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS`) — ya existen.
- Tocar la matriz o las variables del transporte mcp más allá de mover
  `mcp_kill_group` a `_common.sh`.
- `codex-swarm.sh --reap` y cualquier limpieza de slots huérfanos por SIGKILL
  (M30, entrada propia).
- Línea nueva del doctor mostrando la matriz exec (útil, pero es alcance de
  diagnóstico; entrada de backlog aparte si se quiere).

## Assumptions

Entrevista omitida: la entrada M24 + E-A1 (verificadas contra el árbol) fijan
alcance, mecanismo, matriz y aceptación; las decisiones restantes se derivaron con
defaults conservadores y están razonadas en Key decisions:

- **Nombre `TANDEM_EXEC_TIMEOUT_SECONDS`** y literales propios por perfil
  (540/3600/3600 + ultra 3600), espejo de la familia mcp.
- **Perfil ultra = 3600** (seats en background, perfil review); sin deadline por
  tier — el override global basta.
- **Exit 1 en timeout** (quota gastada), mensaje como clasificador, paridad mcp.
- **Los turnos exec no leen la variable mcp** (mandos independientes,
  documentados juntos).
- **Versión 0.32.0** (siguiente minor, convención del CHANGELOG).
