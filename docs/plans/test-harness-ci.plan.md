# Plan: test-harness-ci — suite de tests con stub de codex + shellcheck + CI

Backlog: M14 (`docs/BACKLOG.md`). Diseño derivado de un inventario exhaustivo de contratos
observables de `scripts/` y de dos pasadas adversariales sobre el diseño (17 hallazgos
incorporados, 2 de ellos bugs reales del código actual — ver "Fixes de código").

## Goal

Dar regresión automática a las ~1.100 líneas de bash endurecido del plugin: una suite de
tests locales sin dependencias nuevas (stub del binario `codex` + runner en bash puro),
`shellcheck` pineado, y CI en GitHub Actions con matriz macOS (bash 3.2 real) + Ubuntu
(bash 5 + GNU userland) — de modo que un cambio que rompa el contrato de exit codes, el
argv de codex, el formato del heartbeat o la portabilidad BSD/GNU falle en PR, no en
producción.

## Approach

### 1. Stub del binario codex — `tests/stub/codex`

- [ ] Un solo fichero bash 3.2-compatible. El runner lo COPIA a `$SANDBOX/bin/codex` por
  test (nunca symlink) y antepone `$SANDBOX/bin` al PATH.
- [ ] Dispatch: `--version` primero (imprime `codex-cli 0.0.0-stub`, exit
  `$CODEX_STUB_VERSION_RC`, default 0 — `need_codex` lo sondea); `login` → exit
  `$CODEX_STUB_LOGIN_RC`; resto → rama exec.
- [ ] Selección de escenario 100 % por env (`CODEX_STUB_SCENARIO`, `_THREAD_ID`,
  `_THREAD_ID_2`, `_REPLY`/`_REPLY_FILE`, `_EXIT`, `_FIXTURE`, `_SLEEP`, `_LOG`
  obligatoria). Nada de ficheros de escenario compartidos.
- [ ] Registro por invocación N: `$CODEX_STUB_LOG.argv.$N` (argv completo unido con `\x1f`
  — aserción de orden exacto con una comparación) y `$CODEX_STUB_LOG.stdin.$N` (prompt
  drenado con `cat` antes de emitir eventos).
- [ ] Snapshot del heartbeat EN FASE RUNNING: antes de emitir eventos, la rama exec copia
  el heartbeat a `$CODEX_STUB_LOG.hb.$N` — cubre el contrato "el heartbeat running lleva la
  ruta del NDJSON" que ningún assert final puede ver. La ruta del heartbeat viene de
  `CODEX_STUB_HB_FILE` (default `$CLAUDE_PROJECT_DIR/.tandem/state/current.json`): en los
  tests de worktree `HB_ROOT` apunta al checkout PRINCIPAL, no a `CLAUDE_PROJECT_DIR`, y el
  test exporta la ruta resuelta — un snapshot incondicional de la ruta por defecto fallaría
  o saltaría en silencio la aserción.
- [ ] NDJSON inline solo si vio `--json` en argv; honra `--output-last-message` salvo en los
  escenarios `empty-reply` y `fail` (que no escriben, haciendo observable el pre-borrado).
- [ ] Escenarios: `ok`, `multi-thread-started` (primero-vs-último), `resume-fallback`,
  `fail` (exit forzable ≠1 para distinguir "exit fijo 1" del rc de codex), `empty-reply`,
  `no-thread-event`, `corrupt-ndjson`, `verdict-multi` (último sentinel gana, prefijo con
  doble espacio), `hang` (para el watchdog), `version-fail`.

### 2. Runner y librería — `tests/run.sh`, `tests/lib.sh`

- [ ] Bash puro 3.2 (sin mapfile/arrays asociativos/`${var,,}`). Descubrimiento
  `tests/*.test.sh` con orden `LC_ALL=C sort`; argumento opcional filtra por subcadena.
- [ ] Aislamiento TOTAL por test (regla dura post-incidente 2026-07-20): sandbox propio con
  `bin/ home/ tmp/ project/ claude-config/ tools/`; ejecución con `env -i` y allowlist
  explícita (PATH, HOME, TMPDIR, CLAUDE_PROJECT_DIR, CLAUDE_CONFIG_DIR, CODEX_STUB_LOG,
  REPO_ROOT, TESTS_DIR, TERM=dumb, LC_ALL=C). `$SANDBOX/tools/` contiene symlinks SOLO a
  los binarios `jq` y `git` concretos — nunca directorios enteros (el dir de Homebrew
  contiene bash 5 y potencialmente el codex real del desarrollador).
- [ ] Self-check al arranque, dentro del env scrubbed: `command -v codex` debe resolver al
  stub y `bash -c 'echo $BASH_VERSION'` debe casar con `$TESTS_BASH`; FATAL si no.
- [ ] Guard anti-checkout en `lib.sh`: si `$PWD` o `$CLAUDE_PROJECT_DIR` caen dentro de
  `$REPO_ROOT` → `FATAL` exit 99 (state_init escribiría `.tandem/` real).
- [ ] Watchdog por test en bash puro: un background job ordinario COMPARTE el grupo de
  procesos del runner (verificado en bash 3.2), así que el runner lanza cada test con job
  control activo (`set -m` en el subshell que lo lanza) para que reciba su propio grupo,
  verifica que el grupo existe (`kill -0 -- -$PID`) antes de armar el watchdog, y el timeout
  mata el grupo completo (`kill -- -$PID`) — un stub colgado no deja huérfanos (tee/jq)
  vivos. `TEST_TIMEOUT` default 60 s. Aserciones de orden y rc, nunca de duración en
  segundos.
- [ ] `RUNNER_TMP` bajo `${RUNNER_TEMP:-${TMPDIR:-/tmp}}`, canonicalizado con `pwd -P` una
  sola vez (macOS: `/var` vs `/private/var`); todo lo esperado se deriva de la forma física.
- [ ] `lib.sh`: `fail` (con file:LINENO), `assert_rc` (igualdad EXACTA, nunca `!= 0`),
  `assert_eq`, `assert_file_contains` (grep -F), `assert_not_contains`, `assert_argv`
  (cmp contra la cadena `\x1f` esperada), `assert_json` (jq -e), `assert_no_escapes`
  (`if grep -q; then fail; fi` — jamás `grep -c` en negativas), `make_repo`, `seed_key`,
  `write_hb`.
- [ ] Salida: `ok <nombre>` / `FAIL <nombre> rc=<rc>` + últimas 40 líneas del log; resumen
  final; exit 0 sii 0 fallos. Sandboxes rojos se conservan (CI los sube como artifact).
- [ ] `tests/verify.sh` — punto de entrada único de verificación: ejecuta `tests/run.sh` y
  después las capas de lint con binarios PINEADOS auto-provisionados en `tests/.tools/`
  (shellcheck y actionlint, descargados por `uname -m` con checksum verificado y cacheados).
  `/tests/.tools/` entra en el `.gitignore` del repo — el PROOF no puede dejar binarios sin
  trackear que bloqueen clean-tree gates ni colarse en el empaquetado del plugin.
  Sin binario y sin red → fallo EXPLÍCITO nombrando la capa que no pudo correr, nunca skip
  silencioso (`TANDEM_VERIFY_OFFLINE=1` permite el modo solo-tests de forma deliberada y
  ruidosa). CI llama a este mismo script; la matriz de OS queda como evidencia separada.

### 3. Fixtures — `tests/fixtures/ndjson/`

- [ ] Fixtures NDJSON con las formas de campo EXACTAS que consumen los filtros jq de
  `_common.sh:141-160` y `statusline.sh:158-174`, incluidos multi-`thread.started`, basura
  intercalada, `turn.failed`, `error` y `file_change` con 4 paths (rama "+N more").
- [ ] `README.md`: versión de codex-cli de origen (0.144.4), comando exacto de
  regeneración, y qué shapes están validados contra la CLI real vs best-effort.
- [ ] `check-drift.sh`: compara claves/tipos de eventos reales vs fixtures (lo usa el smoke).

### 4. Casos de test — `tests/<id>.test.sh` (~38)

- [ ] Los 35 casos del diseño: `start-happy` (con extra/notes files reales asertados en el
  stdin grabado), `start-argv-exact-order` (parametrizado en tabla rol→model/effort/sandbox
  para las CUATRO filas implement/review/ask/image + overrides de env), `start-thread-exists-exit2`,
  `start-codex-fails-exit1-not-rc`, `start-empty-reply-exit1`, `start-no-thread-event-exit1`,
  `start-first-thread-started-wins`, `start-missing-codex-exit3`, `start-usage-exit64`,
  `resume-happy-argv-repin` (con `-c sandbox_mode=` presente SOLO en resume y su posición),
  `resume-no-thread-exit2`, `resume-empty-threadfile-exit1`, `resume-fallback-guard-full`
  (exit 1 + last.txt intacto + .turn incrementado + .thread intacto),
  `resume-no-thread-event-tolerated`, `resume-turn-sanitize` (incluida la pasada `08` — ver
  Fixes), `swarm-tiers-readonly-literal`, `swarm-usage-and-fail`, `swarm-parallel-seats`
  (2 seats concurrentes, log por seat), `reset-scoped-glob` (`auth` no toca `auth-v2`),
  `reset-heartbeat-conditional`, `show-states`, `common-target-key`, `common-load-prompt`
  (inserción literal de `& \1 $\` y no-reexpansión de `{{...}}`), `common-hb-verdict-last-wins`
  (+ REQUEST_CHANGES, IMAGE_READY/BLOCKED), `common-hb-write-nulls` (null JSON real, no `""`),
  `common-stream-milestones` (+ `✓ ok`, `✗ stream broke`, usage ausente),
  `statusline-x1f-empty-fields`, `statusline-never-fail`, `statusline-line1-full` (gauge,
  umbrales, coste, rama, detached HEAD, ✳), `statusline-verdict-icons`,
  `statusline-orphaned-pid` (pid de hijo propio ya cosechado, jamás inventado),
  `statusline-stale-suppression`, `statusline-live-activity`, `worktree-hb-root`,
  `doctor-env-matrix` (unset vs set-vacío de TANDEM_IMPLEMENTER vía `env -u`),
  `statusline-install-lifecycle` (+ reinstalación idempotente, `--force` solo → 64).
- [ ] Añadidos de la revisión adversarial: `hb-running-snapshot` (status running + ruta
  events + turn + pid en el snapshot del stub), `hb-term-vs-kill` (SIGTERM → trap EXIT corre
  → status `failed` + rc 143; SIGKILL → queda `running` y statusline lo pinta `orphaned` —
  contrato empíricamente verificado), `shim-runtime` (ejecutar el shim generado con las 4
  configuraciones de resolución: env override, installed_plugins.json falso, BAKED, nada →
  render mínimo, siempre rc 0), `no-jq-degradation` (codex-start → 3; statusline → rc 0 con
  mensaje; codex-reset → heartbeat sobrevive — este caso NO puede correr con `/usr/bin` en
  el PATH porque los runners y macOS moderno traen `/usr/bin/jq`: usa un symlink farm
  mínimo `$SANDBOX/minbin/` con TODAS las utilidades que los scripts necesitan EXCEPTO jq,
  y `PATH=$SANDBOX/bin:$SANDBOX/minbin` a secas), `runner-watchdog-hang` (meta-test del
  harness vía runner ANIDADO: lanza `tests/run.sh` contra un directorio de fixtures aparte
  que contiene un único test colgado con `TEST_TIMEOUT` corto, y aserta que ESA invocación
  anidada reporta TIMEOUT, sale ≠0 y no deja ningún descendiente vivo; el meta-test exterior
  sale 0 — el caso colgado NO puede vivir en el inventario normal o la suite entera nunca
  estaría verde), y siembra de `.tandem/.gitignore` con contenido de usuario que debe
  sobrevivir a `state_init`.

### 5. Fixes de código descubiertos al fijar contratos (mínimos, con test cada uno)

- [ ] `scripts/codex-resume.sh:44` — `TURN=$((10#$TURN + 1))`: hoy un `.turn` con `08`/`09`
  pasa el saneador `case` (todo dígitos) pero la aritmética octal revienta con "value too
  great for base" — error crudo de bash, sin `die`, antes de `hb_begin`. El test lo
  consagra: `08` → turno 9.
- [ ] `scripts/statusline-install.sh` — `write_shim` corre ANTES de la validación de
  settings, así que con un settings corrupto el shim SÍ se (re)escribe aunque el `die` diga
  "nothing was changed". Fix: mover `write_shim` tras la validación; el test fija el
  contrato (settings corrupto → ni settings ni shim tocados).
- [ ] `scripts/codex-start.sh:85` y `scripts/codex-resume.sh:93` — `hb_end done …` pasa el
  literal `done` sin comillas: ShellCheck lo marca SC1010 (verificado localmente con 0.11.0)
  y el job de lint bloqueante nacería en rojo. Fix: `hb_end "done" …` en ambos; cubierto por
  la aceptación "shellcheck limpio".

### 6. CI — `.github/workflows/tests.yml`

- [ ] Triggers completos: `push`, `pull_request`, `schedule` (cron semanal) y
  `workflow_dispatch` — sin los dos últimos el smoke jamás se ejecutaría. Guard por evento a
  nivel de job (contexto `github`, que SÍ es válido en `jobs.<id>.if`): `lint` y `test`
  corren en push/PR; `codex-smoke` solo en schedule/dispatch. `concurrency` con
  cancel-in-progress, `timeout-minutes: 15`.
- [ ] Job `lint` (ubuntu, bloqueante): llama a `tests/verify.sh` (capa lint) — shellcheck
  v0.10.0 y actionlint v1.7.7, AMBOS binarios precompilados con sha256 verificado y asset
  elegido por `uname -m` (actionlint no viene en los runners hosted: sin provisión pineada,
  el paso muere con `command not found` o introduce una descarga sin verificar);
  `--source-path=SCRIPTDIR` y `-x` (sigue el `. _common.sh`), dos invocaciones separadas
  (scripts/ y tests/); actionlint valida el propio workflow.
- [ ] Job `test`, matriz `[ubuntu-latest, macos-latest]`, `fail-fast: false`. Preflight de
  bash: en macOS `/bin/bash -c 'echo $BASH_VERSION'` debe empezar por `3.2` (falla el job si
  Apple lo cambia — `env bash` resolvería al bash 5 de Homebrew y probaríamos el bash
  equivocado); en ubuntu debe ser 5.x. Ejecución: macOS `env TESTS_BASH=/bin/bash /bin/bash
  tests/run.sh`; ubuntu `bash tests/run.sh`.
- [ ] `if: failure()` → upload-artifact de `${{ runner.temp }}/tandem-tests.*` por OS.
- [ ] Job `codex-smoke` (semanal + manual, `continue-on-error`, NUNCA en PR): el gating por
  secret va DENTRO del job a nivel de step (el contexto `secrets` no está disponible en
  `jobs.<id>.if` — usarlo ahí invalida el workflow ENTERO al parsear); autentica de verdad
  con el secret y ejecuta `codex-start.sh` rol `ask` (read-only) por los wrappers reales.
  DOS pasadas: (a) baseline con la CLI PINEADA (0.144.4, la de los fixtures) — regresión
  reproducible; (b) `@openai/codex@latest`, registrando la versión resuelta en el summary y
  corriendo `check-drift.sh` — el README instruye instalar `@latest`, así que un smoke solo
  pineado quedaría verde para siempre mientras una CLI nueva incompatible rompe producción.
  Cada pasada usa su PROPIO `CLAUDE_PROJECT_DIR` temporal (estado y thread separados): la
  segunda invocación de `codex-start.sh` contra el mismo estado saldría con exit 2 — "thread
  already exists" — y la pasada latest moriría antes del drift check. Independencia entre
  pasadas: cada step de pasada lleva su propio `continue-on-error: true` (el
  `continue-on-error` del JOB no evita que un step fallido se salte los siguientes — un
  fallo del baseline suprimiría el drift check de latest) y un step agregador final con
  `if: always()` registra ambos desenlaces en el summary y sale ≠0 si cualquiera falló; el
  job entero sigue siendo no bloqueante. Sin secret → skip limpio.

### 7. Documentación y cierre

- [ ] `README.md`: sección breve "Tests" (cómo correr, `TESTS_BASH=/bin/bash` para replicar
  el CI de macOS en local).
- [ ] `CHANGELOG.md`: entrada 0.10.0 y `.claude-plugin/plugin.json` a `"version": "0.10.0"`
  — el manifiesto es la versión autoritativa del plugin instalado y debe coincidir con la
  entrada más nueva del changelog.
- [ ] `docs/BACKLOG.md`: M14 → estado actualizado.

## Key decisions & tradeoffs

- **Runner bash puro, sin bats**: cero dependencias nuevas y compatibilidad 3.2 garantizada;
  a cambio, aserciones caseras (mitigado: `lib.sh` mínima y fail-fast con file:LINENO).
- **Stub gobernado por env vars, no por ficheros de escenario**: dos tests no pueden
  pisarse; a cambio, cada test declara su entorno completo — deliberado, hace visible el
  contrato.
- **`env -i` con allowlist**: garantía estructural de que HOME/CLAUDE_CONFIG_DIR reales son
  inalcanzables (post-incidente 2026-07-20); a cambio, una env nueva consumida por los
  scripts exige tocar el runner — feature, no bug: el contrato de entorno queda explícito.
- **Micro-fixes de código dentro de este plan**: los tests no deben consagrar bugs; la
  alternativa (documentar el bug en el test y arreglar en plan aparte) es burocracia sin
  beneficio para dos one-liners con test propio.
- **Smoke job semanal no bloqueante**: el drift stub↔CLI real se vigila sin romper PRs; a
  cambio exige un secret y mantenimiento de la versión pineada.
- **shellcheck binario pineado (no brew/apt)**: findings reproducibles entre runs; a cambio,
  bump manual de versión.
- **Tests secuenciales** (contador plano del stub, sin flock): simplicidad BSD-safe; la
  concurrencia real de swarm se prueba con logs POR SEAT en `swarm-parallel-seats`.

## Files to touch

| Ruta | Cambio |
| --- | --- |
| `tests/stub/codex` | nuevo — stub del binario |
| `tests/lib.sh`, `tests/run.sh`, `tests/verify.sh` | nuevos — aserciones, runner y punto de entrada de verificación |
| `tests/fixtures/ndjson/*` + `README.md` + `check-drift.sh` | nuevos — fixtures y drift |
| `tests/<id>.test.sh` (~39) | nuevos — casos |
| `scripts/codex-resume.sh` | fix — aritmética base 10 del turno + `"done"` citado (SC1010) |
| `scripts/codex-start.sh` | fix 1 línea — `"done"` citado (SC1010) |
| `scripts/statusline-install.sh` | fix orden — shim tras validación de settings |
| `.github/workflows/tests.yml` | nuevo — lint + matriz + smoke opcional |
| `.claude-plugin/plugin.json` | bump — `version: 0.10.0` |
| `.gitignore` | añadir `/tests/.tools/` (caché de binarios de verify) |
| `README.md`, `CHANGELOG.md`, `docs/BACKLOG.md` | doc — sección tests, 0.10.0, estado M14 |

## Acceptance & proof

PROOF (debe pasar): `bash tests/verify.sh` — tests + shellcheck + actionlint pineados
(auto-provisionados con checksum en `tests/.tools/`; sin binarios y sin red el comando FALLA
nombrando la capa ausente — nunca pasa saltándose una capa).

Casos de aceptación:
1. Exit codes EXACTOS por escenario (0/1/2/3/64), incluida la distinción "exit fijo 1 ≠ rc
   de codex" y "64 nunca degrada a 1".
2. Argv de codex byte a byte para start/resume/swarm y los cuatro roles, incluida la
   posición y exclusividad de `-c sandbox_mode=` en resume y los sandboxes pineados.
3. El guard anti-fallback de resume deja el estado exacto documentado (exit 1, last.txt
   intacto, .turn incrementado, .thread intacto).
4. Heartbeat: snapshot en running con ruta de events; TERM → `failed` con rc preservado;
   KILL → `running` huérfano que statusline pinta `orphaned`; verdict/events como null JSON.
5. `.turn` con `08` produce turno 9 (tras el fix) — sin error de base octal.
6. El shim de statusline EJECUTADO en sus 4 configuraciones de resolución rinde siempre
   rc 0 con el render esperado.
7. Ningún test puede escribir fuera de su sandbox: guards de checkout (exit 99) activos y
   `env -i` verificado por el self-check del runner.
8. `tests/verify.sh` en verde cubre las tres capas locales: suite completa, `shellcheck`
   limpio sobre `scripts/` y `tests/` (incluye los `"done"` citados), y `actionlint` limpio
   sobre el workflow — con binarios pineados por checksum.
9. Meta-test del watchdog: un escenario `hang` con timeout corto termina reportado como
   TIMEOUT sin dejar ningún proceso descendiente vivo.
10. En CI (tras push): matriz verde en ubuntu y macOS con `/bin/bash` 3.2 verificado por
    preflight; los sandboxes rojos llegan como artifact desde `runner.temp`.

## Risks

- **Drift stub↔CLI real**: el stub fija el contrato de HOY (0.144.4); si la CLI cambia el
  shape NDJSON o el parsing de flags, la suite sigue verde. Mitigación: fixtures
  documentados + smoke semanal por los wrappers reales; riesgo residual asumido.
- **Runners de CI lentos**: aserciones de duración flakean — por diseño solo se aserta
  orden y rc; el watchdog es el único límite temporal.
- **bash local ≠ bash CI**: en máquinas macOS de desarrollo `bash` puede ser el 5 de
  Homebrew; `TESTS_BASH=/bin/bash` replica el CI y el self-check lo hace visible.
- **Los dos fixes tocan scripts en producción**: diffs de una línea/reordenación, cada uno
  con test que fija el contrato nuevo.
- **Duración de la suite**: ~39 sandboxes con git init; presupuesto < 2 min por plataforma
  (timeout 15 min de margen).
- **Primera ejecución de `verify.sh` requiere red** para provisionar shellcheck/actionlint
  pineados (después quedan cacheados en `tests/.tools/`); `TANDEM_VERIFY_OFFLINE=1` existe
  como degradación explícita y ruidosa a solo-tests.

## Out of scope

- Tests de `chroma-strip.sh` (requiere Pillow/ImageMagick en CI) y cobertura profunda de
  `codex-doctor.sh` más allá de la matriz de env del implementador — candidatos a v2.
- E2E contra el codex real fuera del smoke opcional; nada en PR depende de red o login.
- Cobertura de `skills/*.md` y prompts (los consumen modelos, no son ejecutables).
- El resto de ítems del backlog (M1–M13, M15) — planes propios.
