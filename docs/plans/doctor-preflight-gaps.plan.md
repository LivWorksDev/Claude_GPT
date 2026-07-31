# Plan: doctor-preflight-gaps — CLAUDE_CODE_SUBAGENT_MODEL y smoke de modelos

**Backlog:** M7 (P2/S) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 5/6)

## Goal

El preflight de `tandem:implement` para en seco si `CLAUDE_CODE_SUBAGENT_MODEL` vale otra
cosa que `opus` — pero `codex-doctor.sh`, el diagnóstico que se corre antes de cada run, no
lo avisa: el usuario lo descubre a mitad de pipeline. Y nada verifica que los nombres de
modelo configurados (`gpt-5.6-sol`, `gpt-5.6-luna`, overrides) sigan siendo válidos: una
deprecación se descubre a mitad de un run largo. Objetivo: línea FAIL en doctor para el
conflicto de `CLAUDE_CODE_SUBAGENT_MODEL`, y un flag explícito `--smoke` que lance un turno
mínimo real por modelo configurado — NUNCA en la ejecución por defecto (gasta un turno por
modelo).

## Approach

1. **`scripts/codex-doctor.sh` — check de `CLAUDE_CODE_SUBAGENT_MODEL` en la rama opus.**
   Dentro del `case "$implementer"` existente, rama `opus`: si `CLAUDE_CODE_SUBAGENT_MODEL`
   está definida y su valor exacto NO es `opus` (vacío-definido incluido), `bad` con mensaje
   accionable — la variable tiene precedencia sobre el `model: opus` del agent type, el
   preflight de implement parará, y las salidas son des-definirla, fijarla a `opus`, o
   `TANDEM_IMPLEMENTER=sol`. Definida como `opus` → `ok` informativo. Bajo `sol` el check no
   aplica (el transporte no usa el subagente) y no se emite nada.
2. **`scripts/codex-doctor.sh` — flag `--smoke`.**
   - Parsing de argumentos (hoy no acepta ninguno): sin args → comportamiento actual
     intacto; `--smoke` → añade la sección de smoke al final; cualquier otro argumento →
     usage error exit 64 (nuevo contrato de usage en la cabecera).
   - **Conjunto de modelos:** los ÚNICOS configurados tras overrides — review/ask; implement
     SOLO si `implementer=sol` (el transporte opus no usa codex); image; ultra
     judge/worker/scout. Deduplicados (la política default produce exactamente 2:
     `gpt-5.6-sol` y `gpt-5.6-luna`).
   - **Turno mínimo por modelo:** aviso de coste ANTES de lanzar nada ("N turnos reales,
     uno por modelo"); por cada modelo, un `codex exec` directo — SIN pasar por
     `codex-start.sh` ni tocar `.tandem/` — con:
     - **La política de pins COMPLETA de los wrappers, por paridad estructural:**
       `codex_pins()` se EXTRAE a un helper sourceable sin efectos de shell
       (`scripts/_pins.sh`, solo la función y su documentación — ni `set` ni side effects);
       `_common.sh` lo sourcea (los wrappers no cambian de comportamiento ni de argv) y el
       doctor lo sourcea también. Así el smoke lleva sandbox_mode, network_access,
       writable_roots, approval_policy y approvals_reviewer — no una lista duplicada que
       driftaría en silencio — y un cambio futuro de la política llega a ambos lados por
       construcción.
     - **Aislamiento del propio diagnóstico:** `--ephemeral` (el CLI persiste sesión por
       defecto — un diagnóstico no puede dejar historia huérfana; verificar el flag contra
       `codex exec --help` de la CLI pineada y reportar si no existe), `--cd` a un
       `mktemp -d` propio limpiado con trap (el smoke NO corre sobre el repo del usuario:
       un turno que solo debe responder "OK" no tiene por qué poder leer el proyecto) y
       `-c web_search=disabled` también en el smoke (asiento efímero de diagnóstico: la
       excepción read-only de los seats de trabajo no aplica).
     - **SIN override de effort:** `minimal` NO está soportado por los modelos default
       (verificado contra la CLI pineada: Sol acepta low…ultra, Luna low…max — el parsing
       global del CLI solo valida el string, no el soporte por modelo); forzar un effort
       podría hacer fallar un modelo sano y el smoke informaría "retirado" en falso. Cada
       modelo corre con su default determinista (config del usuario ignorado). Prompt de
       una línea ("Reply with exactly: OK").
     - **Watchdog por modelo:** cada turno acotado con kill del grupo de procesos (patrón
       del runner de tests, bash puro); límite por defecto 120 s, con override VALIDADO
       `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS` (entero positivo; otra cosa → 64) — necesario
       además para que el caso de cuelgue sea testeable bajo el timeout de 60 s por caso
       del runner. Un timeout se clasifica como fallo NO-de-modelo y el smoke CONTINÚA con
       los siguientes modelos.
     - **Un solo `--cd`:** `codex_pins()` ya añade `--cd` cuando `TANDEM_CODEX_CWD` está
       definida, y la CLI pineada rechaza dos `--cd` (exit 2) — el smoke NO añade el suyo
       aparte: fija `TANDEM_CODEX_CWD` al directorio temporal ANTES de llamar a
       `codex_pins()` (pisando cualquier valor heredado, vacío o no) y deja que el helper
       emita el único `--cd`. Tests con la env heredada no vacía y definida-vacía.
     - **Sonda de capacidad `--ephemeral`:** se comprueba contra `codex exec --help` de la
       CLI instalada; si el flag NO existe, FAIL accionable y CERO turnos reales (un CLI
       que persistiera sesiones convertiría el diagnóstico en residuo — mejor no smokear).
       El stub gana manejo explícito de `exec --help` (no cuenta como turno pagado, con un
       modo de help sin `--ephemeral` para el caso negativo).
     El doctor NO sourcea `_common.sh` (su `set -euo pipefail` rompería el "reporta todo");
     sourcea solo `_pins.sh`, que no tiene efectos.
   - **Interpretación:** exit 0 + reply no vacía → `ok "model <m> answers"`; fallo → `bad`
     distinguiendo "modelo desconocido/retirado" por SEMÁNTICA de modelo-no-disponible en el
     stderr (patrones tipo "model … not found/unknown/unsupported" — nunca la mera presencia
     del nombre, que también aparece en metadatos de errores de auth/cuota) de "otro fallo"
     (auth, red, timeout — con el tail del stderr mostrado), siempre con acción sugerida y
     SIEMPRE continuando con el resto de modelos. Cualquier fallo → exit 1 del doctor.
3. **`skills/doctor/SKILL.md` y `README.md`.** La skill menciona `--smoke` (qué hace, que
   cuesta un turno real por modelo y que jamás corre por defecto); README ídem en la fila
   del doctor y/o la sección de diagnóstico.
4. **Tests.**
   - `tests/doctor-env-matrix.test.sh` (ampliar): `CLAUDE_CODE_SUBAGENT_MODEL` unset → sin
     FAIL nuevo; `=opus` → sin FAIL; `=sonnet` con implementer opus (default) → FAIL que
     nombra la variable y las tres salidas; vacío-definido → FAIL; `=sonnet` con
     `TANDEM_IMPLEMENTER=sol` → sin FAIL (el check no aplica bajo sol).
   - `tests/doctor-smoke.test.sh` (nuevo, con el stub): ejecución por defecto → NINGUNA
     invocación `codex exec` en el log del stub; `--smoke` con la política default → 2
     invocaciones exec (dedupe sol/luna probado), cada argv con su modelo, el bloque de
     pins COMPLETO (paridad con `_pins.sh`: sandbox_mode, network_access, writable_roots,
     approval_policy, approvals_reviewer), `--ephemeral`, `--cd` a un directorio temporal
     (nunca el repo), `-c web_search=disabled` y SIN `-c model_reasoning_effort`; overrides
     que suben el set a 3 modelos → 3 invocaciones; **fallo selectivo por modelo** (el stub
     gana selectividad por env — p.ej. `CODEX_STUB_FAIL_MODEL=<nombre>` con
     `CODEX_STUB_FAIL_KIND=model|other` — hoy su escenario es global por proceso): el
     modelo marcado falla con semántica de modelo-desconocido → FAIL que lo nombra con
     acción, Y los modelos POSTERIORES corren igualmente (la continuación es aserción, no
     cortesía); mismo caso con kind=other (stderr de auth) → FAIL clasificado como
     no-de-modelo; **cuelgue SELECTIVO** (`CODEX_STUB_HANG_MODEL=<nombre>` — el escenario
     hang global colgaría también a los posteriores) con
     `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS=2` → el watchdog corta SOLO ese modelo, FAIL de
     timeout no-de-modelo, y un modelo posterior corre y responde (aserción); timeout
     override inválido → 64; `exec --help` del stub NO cuenta como turno (los conteos de 2
     y 3 son de turnos REALES); modo de help sin `--ephemeral` → FAIL accionable y cero
     turnos reales; `--cd` ÚNICO apuntando al directorio temporal, también con
     `TANDEM_CODEX_CWD` heredada (no vacía y definida-vacía); argumento desconocido →
     exit 64 con usage; el smoke no crea nada bajo `.tandem/` (aserción sobre el árbol).
5. **Metadatos — orquestador tras la implementación:** `.claude-plugin/plugin.json` →
   `0.17.0`, `CHANGELOG.md`, `docs/BACKLOG.md` (M7 → `hecha (v0.17.0)`), fila de la cola.

## Key decisions & tradeoffs

- **`--smoke` explícito y NUNCA por defecto** (pre-registrado en la cola): cada modelo es
  un turno real contra la cuota del usuario; un diagnóstico que gasta dinero sin pedirlo
  rompería el contrato del doctor. El test lo fija asertando cero `exec` sin el flag.
- **`codex exec` directo, sin wrappers ni estado:** el smoke pregunta "¿existe este
  modelo?", no "¿funciona el pipeline?"; pasar por codex-start crearía hilos y heartbeats
  fantasma en `.tandem/` que codex-show/reset luego mostrarían. La política viaja por
  `_pins.sh` compartido — nunca una lista inline.
- **Sin sourcear `_common.sh`:** su `set -euo pipefail` de primera línea rompería el
  "reporta todo" del doctor (un fallo intermedio abortaría el diagnóstico). El doctor
  sourcea SOLO `scripts/_pins.sh`, que por contrato no tiene efectos de shell.
- **Sin override de effort en el smoke** (decisión corregida en revisión con evidencia de
  la CLI pineada: `minimal` no existe para sol/luna — el parsing global del CLI valida el
  string, no el soporte por modelo): forzar un effort podría reportar "retirado" un modelo
  sano, el falso negativo exacto que el smoke existe para evitar. El default determinista
  por modelo (config ignorado) es la única opción que funciona para cualquier override.
- **Paridad de pins por construcción, no por duplicado:** `codex_pins()` extraída a
  `scripts/_pins.sh` sourceable sin efectos — la lista inline habría driftado en silencio
  respecto a `codex_pins()` y el test estático solo habría congelado el duplicado.
- **`--ephemeral` + `--cd` temporal + sin web_search:** un diagnóstico no deja historia de
  sesión huérfana, no lee el repo del usuario y no puede exfiltrar nada por búsqueda — el
  smoke es la única pieza que puede permitirse el aislamiento total porque no necesita
  contexto ninguno.
- **Watchdog y continuación:** un cuelgue o un fallo de un modelo jamás deja a los demás
  sin diagnóstico; la continuación es parte del contrato testeado.
- **Implement solo bajo sol:** con el transporte opus no hay turno codex de implementación;
  smokear `gpt-5.6-sol` de más solo duplicaría el coste sin informar nada nuevo (ya entra
  por review/ask).

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/codex-doctor.sh` | Check de CLAUDE_CODE_SUBAGENT_MODEL + parsing de args + sección --smoke |
| `scripts/_pins.sh` | Nuevo: `codex_pins()` extraída, sourceable sin efectos |
| `scripts/_common.sh` | Sourcea `_pins.sh` (comportamiento y argv de los wrappers intactos) |
| `tests/stub/codex` | Selectividad de fallo por modelo (env), preservando los escenarios globales |
| `skills/doctor/SKILL.md` | Documentar --smoke y su coste |
| `README.md` | Ídem en la sección del doctor |
| `tests/doctor-env-matrix.test.sh` | Matriz ampliada con CLAUDE_CODE_SUBAGENT_MODEL |
| `tests/doctor-smoke.test.sh` | Nuevo: cero exec por defecto, dedupe, argv, fallo, 64, sin .tandem |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.17.0 (orquestador) |

## Acceptance & proof

- Con `TANDEM_IMPLEMENTER` opus (default) y `CLAUDE_CODE_SUBAGENT_MODEL=<≠opus>` (o
  vacío-definido), el doctor emite FAIL accionable y sale 1; con `=opus` o unset, ninguna
  línea nueva de FAIL; bajo `sol`, el check no aplica.
- `codex-doctor.sh` sin argumentos jamás invoca `codex exec` (cero coste, fijado por test);
  `--smoke` lanza exactamente un turno por modelo ÚNICO configurado (2 con la política
  default; dedupe probado), con el bloque de pins completo de `_pins.sh`, `--ephemeral`,
  `--cd` temporal, sin web_search y sin override de effort, sin crear nada bajo `.tandem/`.
- Un modelo rechazado por SEMÁNTICA de no-disponible produce FAIL que lo nombra con acción
  y exit 1, distinguido de auth/red/timeout (stderr mostrado); en TODOS los casos los
  modelos restantes se smokean igualmente, y un cuelgue lo corta el watchdog de 120 s.
- Los argv de los wrappers (start/resume/swarm) quedan byte a byte idénticos tras la
  extracción de `_pins.sh` (los tests de argv existentes son la prueba).
- Argumento desconocido → exit 64 con usage.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Un smoke real cuesta cuota:** mitigado por diseño (flag explícito + aviso de coste
  previo + cero exec por defecto fijado por test).
- **Formato del error "modelo desconocido" del CLI:** la distinción modelo-vs-otro se basa
  en el stderr; si la release cambia el texto, el FAIL degrada a "otro fallo" con el stderr
  visible — menos específico pero nunca silencioso.
- **Extracción de `codex_pins()` a `_pins.sh`:** el riesgo de regresión en los wrappers lo
  cubren los tests de argv byte a byte existentes (deben quedar intactos sin tocarlos);
  el helper queda con contrato "sin efectos de shell" documentado en su cabecera.

## Out of scope

- Smoke automático o periódico (el job semanal `codex-smoke` del CI ya existe para eso).
- Verificación runtime del modelo del subagente Opus (documentado como no fiable; la
  autoatestación del informe sigue siendo informativa).
- M10 (última tarea de la cola) y el resto del backlog.

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Cuándo corre el smoke?** → Solo con `--smoke` explícito (pre-registrado); cero coste
   por defecto, fijado por test.
2. **¿Qué modelos?** → Los únicos configurados tras overrides; implement solo bajo sol;
   dedupe (default = 2 turnos).
3. **¿Transporte del smoke?** → `codex exec` directo con los pins del helper compartido
   `_pins.sh` (extraído de `_common.sh`, sourceable sin efectos — el doctor no puede
   sourcear `_common.sh` porque su `set -e` rompería el "reporta todo"), `--ephemeral`,
   `--cd` único vía `TANDEM_CODEX_CWD` fijada al temporal, y sin estado en `.tandem/`.
4. **¿Effort?** → SIN override (corregido en revisión: `minimal` no está soportado por los
   defaults — evidencia de `codex debug models --bundled` en la CLI pineada); el default
   determinista por modelo.
5. **¿Rama?** → `tandem/doctor-preflight-gaps` apilada sobre `tandem/turn-effort-override`
   (cadena de la cola), aprobada con `plan-approve.sh`.
6. **¿Versión?** → 0.17.0; metadatos del orquestador tras la implementación.
