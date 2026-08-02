# Plan: mcp-preflight-probes — instrumento de decisión de la Fase 2

**Backlog:** M19 (P2/M) · **Fecha:** 2026-08-02 · **Modo:** autónomo (Cola 4, tarea 1/2)
**Origen:** los cuatro desconocidos de `docs/audits/fase2-mcp-parity.md`.

**Cambio de alcance respecto a la entrada del backlog, con evidencia:** un análisis
estático posterior (fuente `rust-v0.144.4` = 8c68d4c, ya clonada) CERRÓ tres de los cuatro
desconocidos y redujo el presupuesto de 6 turnos a **3 en una secuencia compartida**:

- **(a) rollouts reanudables → SÍ, verificado.** `mcp-server` construye su ThreadManager
  con `thread_store_from_config` (message_processor.rs:75-88) → LiveThread::create →
  RolloutRecorder escribe `CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<ThreadId>.jsonl`
  (recorder.rs:1505-1521), y `codex exec resume <uuid>` resuelve por
  `find_thread_path_by_id_str` sobre ese mismo store (read_thread.rs:225-229). El
  ThreadId del fichero ES el que el resultado MCP ecoa. Condiciones: mismo CODEX_HOME en
  ambos procesos y no activar `ephemeral`. El híbrido MCP-vivo + CLI-resurrección es
  viable → el probe pasa de decisivo a **confirmatorio end-to-end**.
- **(c) herencia congelada → cerrada.** El path de `codex-reply` solo hace `get_thread`
  (message_processor.rs:463); ningún ConfigBuilder se construye (contraste:
  codex_tool_config.rs:181-185 en cada `codex`). Observable barato hallado: cada turno
  real apenda un `RolloutItem::TurnContext` con model/effort/approval_policy/sandbox/cwd
  (turn_context.rs:364-389) al rollout cuya ruta viene en el `SessionConfigured` de la
  call 1 (protocol.rs:3893-3896) → **0 turnos extra**, se lee dentro de la secuencia.
- **(d) elicitation bajo never → cerrada en AMBOS sentidos, y el hallazgo es peor de lo
  temido.** La supresión de approvals exec/patch bajo `never` es TOTAL (exec_policy.rs:174-196,
  sandboxing.rs:206-242, safety.rs:57-61, network_approval.rs:190-192) — verificado, ya no
  "probable". PERO queda una vía alcanzable: la aprobación de MCP-tools
  (`mcp_permission_prompt_is_auto_approved` → false bajo Never con perfil Managed,
  codex-mcp/src/mcp/mod.rs:79-98; forzable con `default_tools_approval_mode = "prompt"`),
  que emite `EventMsg::ElicitationRequest`, y el core espera un oneshot **sin timeout**
  (session/mcp.rs:259-282). El tool runner de mcp-server DESCARTA ese evento
  (codex_tool_runner.rs:276-279, "TODO: forward elicitation requests to the client?"): el
  cuelgue es alcanzable **e irresoluble desde el cliente MCP** — ni siquiera cabe un
  auto-deny. Un demo vivo quemaría un turno que nunca completa → **0 turnos, veredicto
  estático con cita**.
- **(b) auth en CODEX_HOME de tandem → único desconocido real.** Todo lo estructural está
  verificado (default `File` → `<CODEX_HOME>/auth.json`, storage.rs:150-152; keyring solo
  si el usuario lo configuró y su key depende del home, storage.rs:234-245;
  installation_id y state db se autogeneran). Lo único no decidible estáticamente es que
  el token copiado autorice contra el API **en vivo**: 1 turno, ineludible.

## Goal

Un script gateado `scripts/mcp-probe.sh` que produzca, con evidencia archivada, el
dictamen de viabilidad de la Fase 2: confirmar en vivo la cadena que decide la migración
(auth en home propio → herencia congelada → resurrección del hilo por CLI tras matar el
servidor) y registrar los veredictos ya cerrados estáticamente sin gastar cuota por ellos.
Cada probe emite una línea parseable; nada verde sin prueba; el dictamen (actualizar la
auditoría y decidir M20) es paso del orquestador, no del script.

## Approach

1. **`scripts/mcp-probe.sh` (nuevo) — gating y esqueleto.**
   `mcp-probe.sh [--spend] [--only <a|b|c|d>[,…]]`, env
   `TANDEM_MCP_PROBE_TIMEOUT_SECONDS` (watchdog por turno, default 240, validado entero
   positivo o **64** — el patrón de `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS`,
   codex-doctor.sh:51-63). Sourcea `_common.sh` y `set +e` inmediato (config-probe.sh:25-29:
   un diagnóstico reporta TODOS los probes y jamás aborta en el primero). `need_codex` /
   `need_jq` → 3; argumento desconocido → 64 antes de imprimir nada. `ROLE=mcp-probe` +
   `state_init`; `RUN_DIR="$STATE_DIR/<timestamp>.$$"` (unicidad sin lock).
2. **CODEX_HOME propiedad de tandem, efímero.** `mktemp -d` con
   `trap … EXIT` + INT(130) + TERM(143) (config-probe.sh:33-36 ampliado con las señales de
   codex-doctor.sh:555-557). Dentro: `config.toml` escrito con printf + tmp+mv atómico,
   espejo TOML de `codex_pins()` (_pins.sh:38-62), y `auth.json` COPIADO del home real con
   `chmod 600`. **Sin auth.json (keyring) → los probes que autentican quedan
   INDETERMINABLE con la razón "no auth.json — run `CODEX_HOME=<tandem> codex login`",
   sin gastar el turno.** El cleanup mata el grupo del servidor por su propia vida
   (codex-doctor.sh:388-408) y borra el home. **auth.json jamás entra en `.tandem/`.**
3. **Cliente ndjson JSON-RPC en bash puro.** `mkfifo`; servidor lanzado bajo `set -m` para
   que lidere su grupo (codex-doctor.sh:417-430) con
   `CODEX_HOME="$PROBE_HOME" codex mcp-server < fifo > rpc.out.ndjson 2> server.stderr.log &`;
   el fd de escritura se abre DESPUÉS del fork (en BSD el open de FIFO bloquea sin lector)
   y bajo el mismo watchdog. `rpc_send` (con eco a `rpc.in.ndjson`) y `rpc_wait <id> <secs>`
   con sondeo sleep-1 y `jq -Rr 'fromjson? | select(.id==N)'` — solo líneas completas y
   parseables, el resto se re-sondea. Handshake por servidor: `initialize` +
   `notifications/initialized` + `tools/list`, asertando `codex` y `codex-reply`;
   `tools.json` capturado como evidencia. El preflight corre SIEMPRE y **gratis** (el
   handshake no exige auth, confirmado en la auditoría); si falla, se culpa a sí mismo
   (config-probe.sh:49-54) y todos los probes salen INDETERMINABLE. Un
   `unknown subcommand` de una CLI vieja es maquinaria rota, nunca FAIL de un probe.
4. **Presupuesto ANTES de lanzar nada** (contrato literal del smoke, codex-doctor.sh:511-514):
   tabla por probe + `total: N REAL codex turns`, impresa entera antes del primer
   tool-call. Sin `--spend`: solo preflight, cada probe imprime
   `NOT_RUN (requires --spend)`, exit 0.
5. **Los probes — una secuencia compartida de 3 turnos, más dos estáticos.**
   El estado se comparte a propósito (es lo que se está probando: que el hilo sobreviva);
   el orden es el de la cadena de decisión y cada paso deja evidencia propia.
   **DAG de dependencias, explícito y con semántica de autorización:** `b → c → a`
   (b crea el hilo, el rollout y el codeword; c continúa ESE hilo; a lo resucita); `d` es
   independiente y gratis. `--only` opera sobre el CIERRE de prerequisitos: una selección
   que incluya `c` o `a` sin `b` **muestra el cierre en el presupuesto y lo ejecuta**
   (nunca un turno oculto ni un probe sin su prerequisito). Si un prerequisito FALLA o
   queda INDETERMINABLE, sus dependientes emiten
   `PROBE <x>: NOT_RUN — dependencia <y> no superada` y consumen **cero turnos**: la
   "continuación tras un fallo" aplica solo a probes INDEPENDIENTES (d), no a los
   encadenados — esto sustituye la promesa anterior de que c/a corrían igual tras un
   fallo de b.
   - **b (home-auth) · 1 turno · el único ineludible.** Call `codex` con pins completos
     (`sandbox: read-only`, `approval-policy: never`, map `config` con las claves de
     `codex_pins` + `model_reasoning_effort`, `cwd` ABSOLUTO — el relativo se resuelve
     contra el cwd del proceso servidor), prompt que siembra un codeword y pide "OK".
     PASS = resultado con `structuredContent.threadId` y contenido; FAIL = error con
     semántica de auth (clasificador de semántica, no de mera mención —
     codex-doctor.sh:456-466); INDETERMINABLE = timeout u otro error.
     **Taxonomía única para TODOS los probes:** un vencimiento de watchdog es SIEMPRE
     `INDETERMINABLE` (no prueba nada más que "sin respuesta antes del plazo"), jamás
     FAIL — y como INDETERMINABLE no es verde, el exit sigue siendo 1 y el cuelgue sigue
     siendo accionable. Captura del
     `SessionConfigured` (threadId + `rollout_path`) como evidencia para los siguientes.
   - **c (frozen-inheritance) · 1 turno.** Entre calls se REESCRIBE el `config.toml` del
     home con valores hostiles **INOCUOS**: `model = "tandem-bogus-model-m19"` y un
     `model_reasoning_effort` distinto del pineado. **Los campos de seguridad
     (`sandbox_mode`, `approval_policy`, `network_access`, `writable_roots`) se mantienen
     en los valores pineados en AMBAS configuraciones**: degradarlos justo antes del turno
     cuya premisa es que NO se heredan significa que, si la premisa es falsa, el turno
     pagado corre sin contención en la máquina del usuario — y el repo prohíbe
     `danger-full-access` en todo transporte (ARCHITECTURE.md). Probar la herencia de los
     campos de seguridad exigiría un sandbox de SO independiente y queda FUERA DE ALCANCE;
     el `turn_context` del rollout ecoa igualmente sandbox/approval, así que su herencia se
     OBSERVA sin degradar nada. Snapshots pre/post del config. Call `codex-reply` con el threadId. **Discriminador directo, no
     autoinforme del modelo:** la ÚLTIMA línea `turn_context` del rollout debe ecoar los
     valores de la call 1 (model/effort/approval/sandbox/cwd) y no los hostiles → PASS;
     si aparece cualquier valor hostil → FAIL (el server relee config en la continuación);
     rollout ausente o sin turn_context → INDETERMINABLE.
   - **a (rollout-resume) · 1 turno.** Kill limpio del servidor (TERM → wait); listado de
     `$PROBE_HOME/sessions/` a evidencia; después
     `CODEX_HOME="$PROBE_HOME" codex exec … "${CODEX_PINS[@]}" … resume <threadId> - <prompt`
     — la forma exacta de codex-resume.sh:120-127 — pidiendo el codeword sembrado en b.
     El codeword es **impredecible por run** (de `/dev/urandom`, no derivable del prompt)
     y el prompt del resume **jamás lo contiene**: pide recordarlo. PASS = rc 0 **Y**
     `thread.started.thread_id == threadId` (el guard anti-fallback de
     codex-resume.sh:157-163) **Y** el codeword aparece en la respuesta (memoria real, no
     un hilo nuevo educado); FAIL = "Session not found", sin rollout, id distinto o sin
     codeword; INDETERMINABLE = fallo no clasificable.
   - **d (elicitation-never) · 0 turnos · veredicto ESTÁTICO, ATADO A LA VERSIÓN.** El
     script archiva `codex --version` y emite `STATIC` **solo si la versión es exactamente
     la auditada** (`MCP_STATIC_AUDITED_VERSION="0.144.4"`, constante nombrada); cualquier
     otra versión → `INDETERMINABLE — veredicto estático auditado para 0.144.4, esta CLI
     es <v>` (el README recomienda `@latest`: una CLI más nueva recibiría verde por código
     que no contiene). El mismo gate condiciona todo veredicto apoyado en cierres
     estáticos. Con la versión auditada, emite
     `PROBE d: STATIC — …` con las dos mitades y sus citas: supresión total de approvals
     exec/patch bajo `never`, y cuelgue alcanzable e IRRESOLUBLE por MCP-tool-approval
     (el runner descarta `ElicitationRequest`). Un demo vivo colgaría un turno pagado que
     nunca completa: se documenta por qué NO se ejecuta. `STATIC` es un veredicto de
     primera clase, distinto de PASS, y no exige `--spend`.
6. **Veredictos y exit.** Cada probe escribe `verdict.txt` y emite
   `PROBE <name>: <PASS|FAIL|INDETERMINABLE|STATIC|NOT_RUN> — <razón> (evidence: <ruta>)`;
   cierre con `MCP-PROBE RESULT: <p> pass · <f> fail · <i> indeterminable · <s> static ·
   <n> not run — evidence: $RUN_DIR`. **`NOT_RUN` es un estado de primera clase del
   contrato** (mismo token en stdout y en `verdict.txt`, con guion bajo para que sea un
   campo parseable único): cubre tanto el caso sin `--spend` como el salto por dependencia
   no superada, se cuenta aparte en el resumen y es **neutro para el exit** — quien
   determina el código de salida es el prerequisito que falló, nunca el salto. Exit 0 = todo lo corrido PASS/STATIC (o solo preflight); 1 =
   cualquier FAIL/INDETERMINABLE o maquinaria rota; 3 = dependencia; 64 = usage.
   **INDETERMINABLE nunca es verde** (el mismo fail-closed del parser de versión de M18).
7. **`tests/stub/codex` — rama `mcp-server`.** Dispatch antes de la rama exec (precedente
   de las ramas --version/login/debug), bucle `read`+jq respondiendo initialize /
   tools/list / `tools/call codex` / `tools/call codex-reply` en ndjson. Knobs solo por
   env (regla estructural del stub): `CODEX_STUB_MCP_SCENARIO` =
   `ok | auth-error | hostile-inherited | hang-call | no-tools | garbage`,
   **`CODEX_STUB_VERSION_TEXT`** (knob NUEVO: default intacto `codex-cli 0.0.0-stub` — un
   test del doctor depende de ese valor exacto, doctor-env-matrix.test.sh:21 — y los tests
   MCP de camino feliz lo fijan a `codex-cli 0.144.4` para satisfacer el gate de versión de
   los veredictos estáticos), `CODEX_STUB_MCP_THREAD_ID`, `CODEX_STUB_MCP_ROLLOUT` (escribe un rollout falso con
   líneas `turn_context` bajo `$CODEX_HOME/sessions/`, con los valores de la call 1 o los
   hostiles según escenario), `CODEX_STUB_MCP_HANG_RESISTANT`. Registros con **namespace
   propio** `.mcp.in` / `.mcp.calls` / `.mcp.cfg.N` (snapshot del config.toml en cada
   tools/call — así el test observa la reescritura hostil entre calls) / `.mcp.auth.N`,
   sin tocar el contador exec `.n` del que dependen los tests del doctor. La mitad
   `exec resume` del probe (a) la sirve la rama exec YA existente.
8. **Tests (4 ficheros nuevos).**
   - `mcp-probe-gating.test.sh`: sin `--spend` → cero llamadas de AMBOS transportes
     (`.mcp.calls` y `.n` ausentes), líneas NOT_RUN, rc 0, y `PROBE d: STATIC` presente
     igualmente (con `CODEX_STUB_VERSION_TEXT="codex-cli 0.144.4"`); **caso de versión NO
     coincidente** (stub con su default `0.0.0-stub`) → `PROBE d: INDETERMINABLE`
     nombrando la versión auditada, y rc 1; `--bogus`, `--only e`, timeout `abc`/`0` → 64 sin lanzar nada; sin
     auth.json → b INDETERMINABLE sin gasto.
   - `mcp-probe-verdicts.test.sh`: camino feliz → PASS en a/b/c + STATIC en d, presupuesto
     total impreso ANTES del primer call, contadores cuadrando; `auth-error` → b FAIL
     nombrando auth **y c/a emiten `NOT_RUN — dependencia b no superada` con CERO turnos
     adicionales** (aserción sobre `.mcp.calls`), mientras d sigue emitiendo su veredicto
     por ser independiente — el DAG manda sobre la continuación; `hostile-inherited` (el rollout ecoa el modelo hostil)
     → c FAIL; `CODEX_STUB_THREAD_ID` distinto → a FAIL por anti-fallback; sin codeword en
     la respuesta del resume → a FAIL; **aserción anti-autocumplimiento: el codeword
     aparece en el input de b y NUNCA en el de a** (grep sobre `.mcp.in` y sobre el prompt
     staged del resume), y el stub del camino feliz lo RECUPERA de lo registrado en la
     primera llamada en vez de llevarlo hard-coded; `.mcp.cfg.1` con el config tandem y `.mcp.cfg.2`
     con el hostil prueban que la reescritura ocurrió ENTRE calls.
   - `mcp-probe-timeout-cleanup.test.sh`: `hang-call` con timeout 2s → **INDETERMINABLE**
     en plazo (taxonomía única) con rc 1, grupo del servidor segado incluido un hijo
     TERM-resistente
     (doctor-smoke.test.sh:239-258), PROBE_HOME borrado, evidencia PRESERVADA; TERM al
     script en vuelo → grupo segado igual (doctor-smoke.test.sh:260-291).
   - `mcp-probe-evidence.test.sh`: layout completo bajo `.tandem/state/mcp-probe/<run>/`;
     coherencia stdout ↔ verdict.txt; **`find .tandem -name auth.json` vacío siempre**;
     `.tandem/.gitignore` intacto; las rutas de evidencia impresas existen.
8b. **Fixtures REALES de 0.144.4 y drift sin gasto** (el stub define las formas que el
   script consume: una suite verde no puede detectar que el servidor real cambió, y la
   interfaz MCP upstream está declarada experimental). **Los fixtures YA ESTÁN TRACKEADOS en `main`** (commit
   `d735393`, ANTES de la aprobación de este plan y por separado de él: `plan-approve.sh`
   commitea SOLO el fichero del plan y su invariante de resume rechaza un commit que toque
   otros ficheros — un fixture sin trackear jamás llegaría a la rama de implementación, y
   en modo in-place chocaría con el gate de árbol limpio). Capturados del servidor real en
   la auditoría, cero turnos:
   `tests/fixtures/mcp-0.144.4/` con `handshake-raw.jsonl` (bytes crudos),
   `initialize.json`, `tools-list.json` (los inputSchema completos de ambas tools),
   `codex-version.txt` y un README de procedencia. Un test nuevo,
   `tests/mcp-fixture-conformance.test.sh`, los contrasta con lo que el stub emite y con
   lo que el parser del script espera — si divergen, falla. Los fixtures de
   `SessionConfigured` y de la línea `turn_context` NO existen todavía (capturarlos exige
   un turno pagado): el implementador **no los inventa** — el test los marca como
   pendientes y el orquestador los añade con la evidencia del run real de `--spend`,
   ampliando entonces la conformance. Además, el job semanal `config-drift`
   gana un paso **sin gasto**: handshake real (`initialize` + `tools/list`) contra la CLI
   pineada y `@latest`, comparado con `tools-list.json`; una diferencia es señal de drift.
9. **`docs/ARCHITECTURE.md`:** párrafo corto en la sección Fase 2 presentando el script
   como instrumento de decisión (los probes, el gating, y que el registro durable de
   resultados es `docs/audits/fase2-mcp-parity.md`).
10. **Paso del ORQUESTADOR (fuera del alcance del implementador):** tras el merge, Fable
    ejecuta `bash scripts/mcp-probe.sh --spend` (3 turnos), pega las líneas `PROBE …` y la
    ruta de evidencia en una sección "## Resultados M19 — run real" de la auditoría,
    actualiza las filas de la matriz al veredicto observado y decide el estado de M20.

## Key decisions & tradeoffs

- **Los cierres estáticos se respetan: 3 turnos, no 6.** Gastar cuota en re-demostrar lo
  que el código ya prueba sería teatro; los probes vivos existen para lo que el código no
  puede decidir (que un token autorice de verdad) y para el end-to-end del híbrido.
- **Secuencia compartida en vez de probes independientes.** Rompe la independencia (un
  fallo temprano deja los siguientes sin correr) a cambio de probar lo que importa: que el
  MISMO hilo sobreviva al ciclo completo. Cada paso deja evidencia propia y el resumen
  dice qué no llegó a correr.
- **El discriminador de (c) es el `turn_context` del rollout, no el comportamiento del
  modelo.** Evidencia directa de la config efectiva del turno; un modelo educado no puede
  falsear un PASS.
- **`STATIC` como veredicto de primera clase.** Ni PASS (no se observó) ni
  INDETERMINABLE (no es incertidumbre): es una pregunta cerrada por código, con cita. Y
  el probe (d) documenta por qué NO se ejecuta.
- **Sin auth.json → INDETERMINABLE antes de gastar.** Fail-closed y respetuoso con la
  cuota; el mensaje dice exactamente qué hacer.
- **Cliente JSON-RPC en bash puro** (mkfifo + fd + sondeo jq con deadline): cero
  dependencias nuevas, mismo estilo de watchdog que el doctor.
- **Stub MCP dentro de `tests/stub/codex` con namespace de registros propio:** el binario
  real es el mismo `codex`, y el contador exec del que dependen los tests del doctor no se
  toca.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/mcp-probe.sh` | NUEVO — gating, home efímero, cliente ndjson, 3 probes vivos + 1 estático, evidencia y veredictos |
| `tests/stub/codex` | Rama `mcp-server` con escenarios y registros `.mcp.*` propios |
| `tests/mcp-probe-gating.test.sh` | NUEVO — cero turnos sin flag, validación 64, sin-auth |
| `tests/mcp-probe-verdicts.test.sh` | NUEVO — veredictos de cada camino, presupuesto, snapshots de config |
| `tests/mcp-probe-timeout-cleanup.test.sh` | NUEVO — cuelgue, segado de grupo, cleanup, interrupción |
| `tests/mcp-probe-evidence.test.sh` | NUEVO — layout, coherencia, auth.json nunca en .tandem |
| `tests/mcp-fixture-conformance.test.sh` | NUEVO — stub y parser contrastados contra los fixtures REALES de 0.144.4 |
| `.github/workflows/tests.yml` | Job `config-drift`: paso SIN GASTO de handshake real contra pineada y `@latest`, comparado con `tools-list.json` |
| `docs/ARCHITECTURE.md` | Párrafo del instrumento en la sección Fase 2 |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/audits/…` | v0.26.0 y resultados — orquestador |

## Acceptance & proof

- `bash tests/verify.sh` verde entero (suite + shellcheck sobre el script nuevo y el stub
  + actionlint), también bajo bash 3.2.
- **Cero turnos fuera del flag:** sin `--spend`, ni un `tools/call` ni un `codex exec`
  (contadores del stub ausentes), rc 0, y el veredicto STATIC de (d) igualmente impreso.
- Con `--spend` y el stub en camino feliz: presupuesto impreso ANTES del primer call,
  líneas `PROBE` de a/b/c en PASS con rutas de evidencia existentes, d en STATIC, rc 0.
- Cada modo de fallo del stub produce **el veredicto correcto** en SU probe, con
  clasificación honesta (auth ≠ herencia ≠ anti-fallback), **y el timeout es la excepción
  explícita: SIEMPRE `INDETERMINABLE`, nunca FAIL**; los probes dependientes de uno no
  superado quedan `NOT_RUN` sin gastar turnos.
- Cuelgue: **INDETERMINABLE** dentro del timeout (jamás FAIL — taxonomía única) con rc 1,
  grupo del servidor (incluido hijo TERM-resistente) segado, PROBE_HOME borrado,
  evidencia preservada; TERM al script sega el grupo.
- `--bogus`, `--only e`, timeout no-entero-positivo → 64 sin lanzar nada; INDETERMINABLE
  nunca da rc 0; `find .tandem -name auth.json` vacío.

- **Conformance con los fixtures reales:** el stub y el parser del script coinciden con
  `tests/fixtures/mcp-0.144.4/tools-list.json` e `initialize.json` (nombres de tools,
  claves de sus inputSchema, forma de los frames); una divergencia falla la suite. El paso
  de drift del workflow es sintácticamente válido para actionlint.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **El stub codifica las formas de frame leídas en la fuente 0.144.4** — si el servidor
  real difiere, la suite verde no lo detecta. Mitigación: el preflight archiva el
  `tools.json` REAL y los `rpc.out` crudos siempre; todo desajuste degrada a
  INDETERMINABLE con evidencia, jamás a un PASS falso.
- FIFO en BSD: el open de escritura bloquea sin lector — orden servidor-primero,
  fd-después, y bajo watchdog (un servidor que muere al arrancar colgaría el `exec 3>`).
- Sondeo de un NDJSON en escritura: solo se parsean líneas que jq acepta; el escenario
  `garbage` lo cubre.
- El auth.json real viaja a TMPDIR con chmod 600 y traps EXIT/INT/TERM; una máquina con
  keyring degrada a INDETERMINABLE — documentado, no sorpresa.
- Timeout default generoso (240s): la lección del smoke es que un timeout corto mata
  turnos sanos lentos y se confunde con un modelo retirado.
- Los tests de cuelgue usan 2s para caber en el TEST_TIMEOUT=60 del runner: mismo perfil
  de riesgo ya aceptado en doctor-smoke.

## Out of scope

- M20 completo (transporte de producción, drift-probe del map `config`, migración rol a
  rol) — contingente a este dictamen.
- Actualizar la auditoría con resultados reales y decidir el estado de M20: paso del
  orquestador. El implementador entrega el instrumento, jamás el dictamen.
- Ejecutar probes de gasto en CI o en el job semanal (mismo criterio que `doctor --smoke`).
- Registrar el servidor vía `claude mcp add`; multiplexación de seats ultra sobre un
  servidor compartido (pregunta de M20).
- Metadatos (orquestador); ninguna skill invoca el script todavía.

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Re-probar en vivo lo cerrado por código?** → No: 3 turnos, con (d) estático y (a)/(c)
   confirmatorios dentro de la secuencia.
2. **¿Probes independientes o secuencia compartida?** → Secuencia: el objeto de la prueba
   es la supervivencia del hilo.
3. **¿Veredicto para lo cerrado estáticamente?** → `STATIC`, de primera clase, con cita.
4. **¿Rama?** → `tandem/mcp-preflight-probes` desde el `main` ACTUAL, que debe contener
   el commit de fixtures `d735393` (NO desde e119557, su padre: esa base dejaría los
   fixtures fuera y haría imposible el test de conformance). Primera de la Cola 4.
5. **¿Versión?** → 0.26.0; metadatos del orquestador tras la implementación.
