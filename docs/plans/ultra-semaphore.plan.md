# Plan: ultra-semaphore — semáforo de concurrencia dentro de codex-swarm.sh

**Backlog:** M13 (P2/M) · **Fecha:** 2026-07-31 · **Modo:** autónomo (Cola 2, tarea 2/4)


Mover la aplicación del límite `TANDEM_ULTRA_CONCURRENCY` del chunking manual del workflow a un semáforo dentro del propio `codex-swarm.sh`: un lock por `mkdir` (portable bash 3.2/BSD, sin `flock`) en `.tandem/state/ultra/<run>/.slots/`, de modo que N seats lanzados a la vez ejecuten como máximo C turnos codex simultáneos sin barreras por tandas — los seats en exceso esperan dentro del script con timeout acotado y fallo ruidoso (nunca deadlock silencioso), un seat que muere libera su slot vía trap EXIT, y `skills/ultra/SKILL.md` deja de chunkear: `pipeline()`/`parallel()` fluyen a ancho completo, con cada seat lanzado en background Bash porque espera-en-cola + turno supera el cap foreground de 10 minutos del tool Bash (mismo razonamiento ya anclado en M10 para reviews largas).

## Approach

1. **`scripts/codex-swarm.sh` — validación de env, ANTES del toolchain.** Insertar un bloque entre `codex_cwd_validate` (scripts/codex-swarm.sh:73) y `need_codex` (:74): `ULTRA_CONC="${TANDEM_ULTRA_CONCURRENCY-4}"` — expansión SIN `:` para que set-pero-vacío sea inválido, el mismo contrato que `TANDEM_CODEX_CWD` (scripts/_common.sh:79-80) — validado con `case … *[!0-9]*` + `[ -ge 1 ]`; si no, `die "TANDEM_ULTRA_CONCURRENCY must be a positive integer, got '…'" 64` (`die`: scripts/_common.sh:11-15). Idéntico para `ULTRA_TIMEOUT="${TANDEM_ULTRA_SLOT_TIMEOUT-1800}"` (segundos, default generoso 1800). La colocación antes de `need_codex` replica la decisión documentada de `codex_cwd_validate`: "a bad argument must fail as a usage error, never as a missing toolchain" (scripts/_common.sh:72-73).

2. **`scripts/codex-swarm.sh` — `.slots/`, adquisición y liberación.** Definir `SLOTS_DIR="$STATE_DIR/.slots"` junto a `STATE_DIR` (:109) y añadirlo al `mkdir -p` (:110; `mkdir -p` es race-safe entre seats concurrentes). Tras el banner (:127-128) y antes del `set +e`/`codex exec` (:133-134):
   - Armar `trap 'slot_release' EXIT` y además `trap 'exit 129' HUP`, `trap 'exit 130' INT`, `trap 'exit 143' TERM` — en bash el trap EXIT NO corre ante una señal fatal no trapeada; un `exit` dentro del trap de señal sí lo dispara. (Nota conocida: bash difiere los traps de señal hasta que el pipeline foreground de codex termina; un TERM al grupo mata también al codex hijo, el pipeline acaba y el trap libera.)
   - `slot_acquire()`: deadline `$(date +%s) + ULTRA_TIMEOUT`; en cada pasada intenta `mkdir "$SLOTS_DIR/slot.$i" 2>/dev/null` para `i=1..ULTRA_CONC` (`mkdir` es el test-and-set atómico portable); al ganar escribe `$$` + seat en `slot.$i/holder` (solo diagnóstico, best-effort) y retorna. Si todo está ocupado imprime UNA sola vez a stderr `tandem: all C ultra slots busy — waiting (timeout Ns)`, `sleep 1` y reintenta; al agotar el deadline: `die "no free ultra slot after Ns (concurrency=C, run=…, seat=…) — inspect $SLOTS_DIR (a SIGKILLed seat leaves a stale slot dir; remove it if no codex turn is running)" 75`. El escaneo está acotado por min(C, slots ocupados+1): nunca degenera con C grande.
   - `slot_release()`: `rm -rf "$SLOT_DIR"` idempotente, siempre `return 0` — el trap EXIT debe preservar el exit code original del script (incluye el camino `die` de :164-169: un seat que muere libera su slot).
   - El timeout ocurre ANTES de `codex exec`: cero quota gastada, el ledger de usage (:152-162) no se toca y no se escribe reply.

3. **`scripts/codex-swarm.sh` — contrato observable y cabecera.** Añadir ` concurrency=%s` al banner de stderr (:127-128) para que el default 4 sea observable — aditivo: swarm-tiers-readonly-literal.test.sh:69 asserta por substring y sigue verde. Actualizar la cabecera: sección env (:36) con `TANDEM_ULTRA_CONCURRENCY` y `TANDEM_ULTRA_SLOT_TIMEOUT`, y exit codes (:38) → `0 ok · 1 codex failure · 3 missing dependency · 64 usage error · 75 no free slot within the timeout`. Los argv de codex NO cambian: cwd-pin.test.sh:38 y swarm-tiers-readonly-literal.test.sh:21 (assert_argv exacto) siguen verdes.

4. **`tests/stub/codex` — knob `CODEX_STUB_CONC_DIR`.** Nuevo knob documentado en el bloque de contrato de env (tests/stub/codex:12-38): cuando está definido, la rama exec (tras el snapshot de heartbeat, :169-172, y antes del `CODEX_STUB_SLEEP` de :221-223) hace `mkdir -p` del dir, crea marcador `running.$$`, arma `trap 'rm -f "$STUB_CONC_MARK"' EXIT`, y snapshotea el número de stubs vivos a `$CODEX_STUB_LOG.conc.$N` con `find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '` (find, no ls: shellcheck-clean — el stub se shellchequea, tests/verify.sh:244-246). Es el observable que "máximo C turnos codex simultáneos" necesita: la aserción vive en el stub-lado, no en wall-clock (la casa desaconseja duración: tests/lib.sh:287 "Order, never wall-clock duration").

5. **`tests/swarm-semaphore-cap.test.sh` (nuevo) — el corazón de la aceptación.** Patrón de lanzamiento concurrente de swarm-parallel-seats.test.sh:15-28 (CODEX_STUB_LOG propio por seat para que el contador plano del stub no compita): `make_repo "$CLAUDE_PROJECT_DIR"`; `export TANDEM_ULTRA_CONCURRENCY=2 CODEX_STUB_SCENARIO=ok CODEX_STUB_SLEEP=2 CODEX_STUB_CONC_DIR="$SANDBOX/conc"`; lanzar 4 seats (`s1..s4`) en background con `CODEX_STUB_LOG="$SANDBOX/logs/sN" CODEX_STUB_REPLY="reply N" bash "$SCRIPTS/codex-swarm.sh" worker run-cap sN "$SANDBOX/sN.txt" >…out 2>…err &`, `wait` por pid. Aserciones: (a) los 4 exit codes son 0 (`assert_eq`); (b) cada `logs/sN.conc.1` existe, es numérico y `-le 2` — el cap, independiente de timing; (c) el máximo observado es exactamente 2 — el semáforo no serializó de más (no-vacuidad: prueba que el test puede ver solapamiento); (d) `.tandem/state/ultra/$(tkey run-cap)/.slots` existe y queda VACÍO (`find -mindepth 1 -maxdepth 1 | wc -l` = 0): todos los slots liberados; (e) al menos un `sN.err` contiene `ultra slots busy — waiting`; (f) spot-check de dos replies por seat (`assert_file_contains "$UD/$(tkey s1).reply.txt" "reply 1"`).

6. **`tests/swarm-semaphore-release.test.sh` (nuevo) — el seat que muere libera.** Con `TANDEM_ULTRA_CONCURRENCY=1`: (a) `CODEX_STUB_SCENARIO=fail` → `run bash …` → `assert_rc 1` y `.slots` vacío (el camino `die` de :164-168 pasó por el trap EXIT); (b) seguido, `CODEX_STUB_SCENARIO=ok TANDEM_ULTRA_SLOT_TIMEOUT=3` → `assert_rc 0` — si el slot del muerto se hubiera filtrado, esto saldría 75; (c) muerte por señal: seat en background con `CODEX_STUB_SLEEP=3`, `kill -TERM` al pid del script, `wait` → rc 143 y `.slots` vacío (el trap TERM→exit→EXIT corrió tras acabar el pipeline); (d) timeout ruidoso: pre-crear `mkdir -p "$UD_T/.slots/slot.1"` (holder atascado simulado), `TANDEM_ULTRA_SLOT_TIMEOUT=1`, CODEX_STUB_LOG fresco → `assert_rc 75`, `assert_file_contains "$ERR" "no free ultra slot after 1s"`, y `assert_no_file "$CODEX_STUB_LOG.argv.1"` + `assert_no_file "$UD_T/….reply.txt"` — codex nunca se invocó, cero quota; (e) recuperación: `rm -rf` del slot atascado, re-run → `assert_rc 0`.

7. **`tests/swarm-semaphore-env.test.sh` (nuevo) — validación fail-closed.** Con `CODEX_STUB_SCENARIO=version-fail` (patrón de cwd-pin.test.sh:41-50: prueba que la validación corre ANTES de `need_codex` — si corriera después respondería 3): `TANDEM_ULTRA_CONCURRENCY` ∈ {`banana`, `0`, `-2`, `""`} → `assert_rc 64` y stderr nombra la variable; ídem `TANDEM_ULTRA_SLOT_TIMEOUT` ∈ {`banana`, `0`}; `assert_no_file "$CODEX_STUB_LOG.argv.1"`. Después, escenario `ok` y ambas unset → `assert_rc 0` y `assert_file_contains "$ERR" "concurrency=4"` (el default es observable en el banner).

8. **`skills/ultra/SKILL.md` — el chunking muere; seats en background.** (a) Reemplazar el párrafo de concurrencia (skills/ultra/SKILL.md:64) por: `codex-swarm.sh` enforce `TANDEM_ULTRA_CONCURRENCY` (default 4) él mismo con un semáforo por run bajo `.tandem/state/ultra/<run-id>/.slots/` — lanzar cada `parallel()`/`pipeline()` a ancho completo, **no chunking**: los seats sobrantes hacen cola dentro del script; un seat sin slot en `TANDEM_ULTRA_SLOT_TIMEOUT` s (default 1800) falla ruidoso con exit 75 SIN haber arrancado su turno codex (cero quota — reintentable), y el porqué de que el límite viva en el script y no en la disciplina del autor del workflow. (b) Paso 2 del wrapper (:43): de `2. Run (Bash timeout: 600000):` a lanzar con Bash `run_in_background: true` — espera en cola + turno supera regularmente el "10-minute foreground cap", "hard ceiling of the Bash tool" (mismo lenguaje que ancla tests/skill-review-background-contract.test.sh:213-214) — esperando la task-completion notification como barrera antes de extraer; el comando fenced `bash <SCRIPTS>/codex-swarm.sh --preamble … <tier> <run-id> <seat> …` (:44) queda byte-idéntico, así el contrato de skill-ultra-preamble-contract.test.sh:32-44 (flag antes de posicionales, ≥1 launch) sigue verde. (c) La frase "Pipeline, not barrier" (:68) y la degradación (:84) quedan coherentes sin tocar los anclajes de token-accounting (tests/skill-token-accounting-contract.test.sh:68-81 no menciona chunking).

9. **`tests/skill-ultra-concurrency-contract.test.sh` (nuevo) — contrato estático.** La suite conductual no puede ver el prompt del wrapper (documentación ejecutable), así que se ancla estáticamente, patrón exacto de skill-ultra-preamble-contract.test.sh:14-23 (copia aplanada con `tr`, ≥40 líneas para no-vacuidad, :77-78): positivos — `TANDEM_ULTRA_CONCURRENCY`, `.slots`, `TANDEM_ULTRA_SLOT_TIMEOUT`, `no chunking`, `run_in_background: true`, `10-minute foreground cap`, `hard ceiling of the Bash tool`; negativos — `chunk every` y `Bash timeout: 600000` desaparecen del fichero (retirados, no suplementados).

10. **Docs y doctor (menor).** `README.md:95` añade `TANDEM_ULTRA_SLOT_TIMEOUT` a la lista de overrides; `README.md:116` actualiza "concurrencia acotada por TANDEM_ULTRA_CONCURRENCY (default 4)" a "aplicada por el propio script (semáforo por run, sin chunking)". `scripts/codex-doctor.sh:172` añade ` slot_timeout=${TANDEM_ULTRA_SLOT_TIMEOUT:-1800}s` a la línea ultra — aditivo: doctor-env-matrix.test.sh:142 asserta `concurrency=4` por substring y sigue verde.

11. **Metadatos — SIEMPRE del orquestador, post-implementación.** `plugin.json` (versión), `CHANGELOG.md` y el cierre de M13 en `docs/BACKLOG.md` NO se tocan en la implementación: los aplica el orquestador al integrar, como en todos los milestones anteriores.

## Key decisions & tradeoffs

- **`mkdir` como lock, no `flock` ni ficheros-lock con `noclobber`:** `mkdir` es atómico en POSIX, existe idéntico en BSD/macOS bash 3.2 y deja un artefacto inspeccionable (el slot dir con su `holder`). Pre-registrado.
- **Semáforo POR RUN (`.tandem/state/ultra/<run>/.slots/`):** dos runs simultáneos suman 2×C turnos globales. Es la ruta pre-registrada y el caso real es un run a la vez; se documenta como límite conocido en Risks.
- **Exit 75 (EX_TEMPFAIL) para el timeout de slot, no 1:** el timeout ocurre antes de `codex exec` — reintentar es gratis; `1` significa "codex falló" (quota posiblemente gastada). Un código propio deja que el wrapper/orquestador distinga "congestión, reintenta" sin parsear stderr. Amplía el contrato documentado de exit codes (cabecera :38) — ver open questions.
- **Sin auto-reclaim de slots huérfanos (SIGKILL):** el trap EXIT cubre `die`, exit normal y TERM/INT/HUP; un `kill -9` deja slot huérfano hasta el fallo ruidoso por timeout (que nombra `.slots` y el remedio). Reclaim por sondeo `kill -0` del pid añadiría carreras `rm -rf`/`mkdir` entre esperadores por complejidad que el caso no paga — ver open questions.
- **Set-pero-vacío es inválido (expansión `${VAR-default}` sin `:`):** coherente con el contrato de `TANDEM_CODEX_CWD` ("Set-but-empty is invalid … never 'unset'", cwd-pin.test.sh:57-60).
- **Wrapper de seat pasa a `run_in_background: true`:** sin chunking, la espera en cola cuenta contra el timeout del Bash tool del wrapper (cap duro de 10 min, no configurable hacia arriba); es la misma física que motivó M10 (skills/review/SKILL.md:55). La alternativa — mantener foreground y un slot-timeout < 10 min — acotaría artificialmente la cola y haría que el harness matara seats con el fallo mudo que este plan existe para eliminar.
- **Observabilidad del cap vía stub (`CODEX_STUB_CONC_DIR`), no wall-clock:** aserciones de duración son flaky y la suite las proscribe (lib.sh:287); contar stubs vivos en el instante de arranque de cada turno mide exactamente "turnos codex simultáneos", que es la letra de la aceptación.
- **Poll de 1 s con deadline por `date +%s`:** granularidad sobrada frente a turnos de minutos; sin dependencias nuevas.

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `scripts/codex-swarm.sh` | validación env (64, antes del toolchain), `SLOTS_DIR`, `slot_acquire`/`slot_release`, traps EXIT/HUP/INT/TERM, banner con `concurrency=`, exit 75, cabecera env+exit codes |
| `tests/stub/codex` | knob `CODEX_STUB_CONC_DIR` (marcador `running.$$`, snapshot `conc.N`, trap de limpieza) + doc en el contrato de env |
| `tests/swarm-semaphore-cap.test.sh` | **nuevo** — cap con C=2 y 4 seats concurrentes, slots liberados, replies intactas |
| `tests/swarm-semaphore-release.test.sh` | **nuevo** — muerte por `die` y por TERM libera; timeout ruidoso 75 sin invocar codex; recuperación |
| `tests/swarm-semaphore-env.test.sh` | **nuevo** — matriz de validación 64 antes del toolchain; default 4 observable |
| `tests/skill-ultra-concurrency-contract.test.sh` | **nuevo** — contrato estático: no chunking, background, envs documentadas |
| `skills/ultra/SKILL.md` | párrafo de concurrencia reescrito (sin chunking), wrapper en background, envs y exit 75 documentados |
| `scripts/codex-doctor.sh` | (menor) `slot_timeout=` en la línea informativa ultra |
| `README.md` | (menor) override nuevo y párrafo ultra actualizado |
| `plugin.json` / `CHANGELOG.md` / `docs/BACKLOG.md` | **orquestador, post-implementación** — fuera de la implementación |

## Acceptance & proof

Casos (cada uno es una aserción exacta de un test nuevo, ejecutado por el runner en sandbox `env -i` con el stub de codex por env vars):

1. **Cap sin chunking:** 4 seats lanzados a la vez con `TANDEM_ULTRA_CONCURRENCY=2` → todo `conc.N` ≤ 2, máximo observado == 2, los 4 exit 0, replies por seat correctas (`swarm-semaphore-cap`).
2. **Slots liberados en éxito:** `.slots/` vacío al terminar los 4 seats (`swarm-semaphore-cap`).
3. **Seat que muere libera:** escenario `fail` → rc 1 y `.slots/` vacío; TERM a un seat en vuelo → rc 143 y `.slots/` vacío; el siguiente seat con C=1 y timeout 3 s sale 0 (`swarm-semaphore-release`).
4. **Timeout ruidoso, nunca deadlock:** slot pre-ocupado + `TANDEM_ULTRA_SLOT_TIMEOUT=1` → rc 75, stderr `no free ultra slot after 1s`, **cero** invocaciones de codex (`assert_no_file …argv.1` — quota intacta); liberado el slot, re-run sale 0 (`swarm-semaphore-release`).
5. **Env fail-closed:** valores no enteros/≤0/vacíos de ambas variables → rc 64 nombrando la variable, incluso con codex roto (`version-fail`: la validación precede al toolchain); default 4 visible en el banner (`swarm-semaphore-env`).
6. **La skill ya no chunkea:** contrato estático — `chunk every` y `Bash timeout: 600000` ausentes; `no chunking`, `run_in_background: true`, `TANDEM_ULTRA_SLOT_TIMEOUT` y el cap de 10 min anclados (`skill-ultra-concurrency-contract`).
7. **Sin regresión:** argv de codex byte-idéntico (cwd-pin, swarm-tiers-readonly-literal), preamble-contract y token-accounting-contract intactos, doctor-env-matrix verde; shellcheck limpio sobre script, stub y tests nuevos (capa 2 de verify).

PROOF: `bash tests/verify.sh`

## Risks

- **SIGKILL deja slot huérfano:** `kill -9` (o el KILL final del watchdog del runner) salta el trap EXIT; el slot queda ocupado hasta que el fallo por timeout lo denuncia nombrando `.slots/` y el remedio manual. Mitigado por el fichero `holder` (pid+seat para diagnóstico) y el mensaje accionable; sin auto-reclaim por decisión (ver open questions).
- **Traps diferidos durante el pipeline foreground:** bash no ejecuta el trap de TERM hasta que `codex exec | tee | jq` termina; un TERM solo al wrapper con un codex colgado no libera hasta que el hijo muera. En la práctica los kills son al grupo (runner y harness), que matan también a codex. El test de TERM usa un sleep corto del stub para no depender de esto.
- **Aserción de paralelismo (máximo == 2) sensible a máquinas patológicamente lentas:** si el arranque de dos seats se separara > 2 s no habría solapamiento. Mitigado con `CODEX_STUB_SLEEP=2` y manteniendo la aserción del cap (≤ C) independiente de timing; precedente de concurrencia real ya en suite (swarm-parallel-seats con sleep 1).
- **Wrapper haiku en background:** el paso a `run_in_background: true` depende de que el agente wrapper respete la barrera de la notificación de término; se ancla con el mismo lenguaje de barrera que M10 dejó probado en plan/review y con el contrato estático nuevo.
- **Semáforo por run, no global:** dos runs ultra simultáneos ejecutan hasta 2×C turnos; es la semántica del namespace pre-registrado y queda documentada en la skill.

## Out of scope

- Semáforo global cross-run (un `.slots` compartido fuera del namespace del run) — el pre-registro fija `.tandem/state/ultra/<run>/.slots/`.
- Auto-reclaim de slots con holder muerto (sondeo `kill -0`) — el backstop es el timeout ruidoso.
- Heartbeat o statusline para seats ultra (M-otros; los seats siguen sin tocar `current.json`, contrato existente de swarm-parallel-seats.test.sh:53-56).
- Cambios en `codex-start.sh`/`codex-resume.sh` — el semáforo es exclusivo del enjambre.
- Reintentos automáticos tras un 75 — reintentar es decisión del orquestador del run.
- `plugin.json`, `CHANGELOG.md`, `docs/BACKLOG.md` y todo lo relativo a git/rama — orquestador, post-implementación.

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default (incluye las preguntas
abiertas del borrador del enjambre, resueltas por el orquestador).

1. **¿Exit code del timeout de slot?** → 75 (EX_TEMPFAIL): distingue "congestión,
   reintenta gratis" de "1 = fallo codex" y es asertable exacto; ampliar el contrato
   documentado de exit codes del script es exactamente para lo que existe su cabecera.
2. **¿Slots huérfanos por SIGKILL?** → SIN auto-reclamación: solo fallo ruidoso por
   timeout con remedio manual documentado (borrar `.slots/` del run). La alternativa
   (sondear el pid del holder con kill -0 y reclamar) introduce carreras rm/mkdir entre
   esperadores — la clase de bug de concurrencia que este cambio existe para eliminar, no
   para añadir.
3. **¿Rama?** → `tandem/ultra-semaphore` apilada sobre `tandem/status-skill` (cadena de la
   Cola 2), aprobada con `plan-approve.sh`.
4. **¿Versión?** → 0.20.0; metadatos del orquestador tras la implementación.


## Revisiones incorporadas (ronda 1 del red-team — vinculantes sobre el Approach de arriba)

Las siguientes correcciones REEMPLAZAN lo que el Approach diga en contrario:

1. **Señales sin salida durante el pipeline (P1-1):** los handlers de INT/TERM/HUP jamás
   hacen `exit` directamente — registran el código pendiente en una variable
   (`PENDING_SIG=143|130|129`) y RETORNAN; el flujo principal captura `PIPESTATUS`,
   persiste el usage del turno (la contabilidad de M9 es incondicional: un turno que
   completó y quemó cuota se contabiliza AUNQUE llegue una señal) y emite el footer
   `USAGE:` ANTES de honrar la señal pendiente con el exit correspondiente. Aserción nueva:
   TERM entregado tras la finalización natural del stub → el ledger existe igualmente.
2. **Adquisición signal-safe (P2-1):** `SLOT_DIR=""` y `SLOT_HELD=0` inicializados ANTES de
   armar ningún trap (set -u); la sección crítica `mkdir` → registro de holder difiere la
   salida por señal (mismo mecanismo de señal pendiente) hasta que `SLOT_HELD` quede
   definitivamente en 0 o 1; el trap EXIT solo libera cuando `SLOT_HELD=1` — jamás borra el
   slot de otro proceso.
3. **El slot se adquiere ANTES de publicar el prompt staged o borrar la reply anterior
   (P2-2):** un timeout de slot (exit 75) no puede destruir el último resultado durable de
   un seat existente. Test nuevo: seat con reply/prompt previos + slots ocupados → 75 y
   AMBOS ficheros byte a byte intactos.
4. **Barrera de preparación en el test de liberación por TERM (P2-3):** poll acotado hasta
   que existan el registro de invocación del stub Y el holder del slot; se aserta que el
   slot EXISTÍA antes de señalar; solo entonces `kill -TERM`. Sin barrera, el test sería
   vacuamente verde (TERM antes de armar traps → rc 143 y .slots vacío sin ejercitar nada).
5. **Contrato numérico coherente (P2-4):** ambas envs (`TANDEM_ULTRA_CONCURRENCY`,
   `TANDEM_ULTRA_SLOT_TIMEOUT`) rechazan vacío-definido explícitamente, se normalizan con
   `10#` antes de CUALQUIER aritmética (el precedente exacto del doctor: `08`/`09` son
   octal para bash), y el doctor las VALIDA (no solo las muestra con `:-default`). Tests:
   vacío, `08`, `09`.

6. **Señal pendiente honrada también en la COLA (P2-5):** el bucle de espera comprueba
   `PENDING_SIG` en cada frontera segura — tras cada resultado de `mkdir`, tras cada sleep
   interrumpido, antes de evaluar el timeout y antes del staging/lanzamiento de codex. Un
   TERM en cola sale con 143 (nunca 75, nunca adquiere ni gasta). Test: señalar a un
   esperador detrás de un slot ocupado → rc 143, cero invocaciones codex, y el slot AJENO
   intacto.
7. **El test de contabilidad-bajo-TERM usa la ventana del sleep del stub (P2-6):** señalar
   "tras la finalización natural" es carrera pura (el stub emite y muere casi a la vez).
   En su lugar: barrera de preparación prueba stub dormido + slot vivo → TERM AHÍ → bash
   difiere el handler hasta que el stub emite `turn.completed` de forma natural → se aserta
   que el evento existe y que ledger + footer se persistieron ANTES del rc 143.

8. **Barrera también en el test del esperador cancelado (P2-7):** antes de señalar,
   poll acotado hasta que el stderr del esperador contenga el mensaje de espera del
   semáforo ("ultra slots busy — waiting") Y el proceso siga vivo — un TERM antes de armar
   los traps daría rc 143, cero codex y slot intacto SIN ejercitar la cancelación de cola.
   Solo entonces kill -TERM y las aserciones ya definidas.
