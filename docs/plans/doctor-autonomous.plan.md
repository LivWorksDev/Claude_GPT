# Plan: doctor-autonomous — `doctor --autonomous`: preflight frío del modo desatendido

**Backlog:** M34 (P2/S) · **Origen:** revisión del modo autonomous con el mantenedor
(2026-08-29), tras el primer run completo del pipeline sobre M26 · **Fecha:**
2026-08-30 · **Modo:** AUTONOMOUS (`TANDEM_AUTONOMOUS=1`; sin entrevista — ver
Assumptions) · **Base:** tandem/implement-write-audit **f01830a** (v0.33.0, sin
mergear — ver Assumptions).

## Goal

El conocimiento para preparar un run desatendido está repartido (README §autonomous,
`skills/run/SKILL.md:34-37`) y solo se valida al lanzar: no hay forma de preguntar
«¿está esta sesión lista para un run autonomous?» en frío, gratis, antes de decidir
lanzarlo. Peor: la única capa cuyo fallo NO es fail-fast — los permission prompts de
la propia sesión de Claude Code, que tandem «ni puede ni debe tocar» (README) — hoy
no se avisa proactivamente en ningún sitio ejecutable: un usuario nuevo la descubre
volviendo horas después con el run bloqueado a mitad, esperando un prompt que nadie
va a responder. Este plan añade `codex-doctor.sh --autonomous`: un preflight GRATIS
(cero turnos de modelo, mismo criterio que el doctor base) que agrupa los requisitos
verificables del modo — `TANDEM_PROMOTE_REVIEWS` estricto, árbol limpio, estado
efectivo de los flags que cambian el run — más un WARN informativo SIEMPRE presente
sobre la capa de permisos, emitido como aviso honesto, nunca como PASS, porque
tandem no puede leerla. Duplicación deliberada, como en el gate crítico de M18: el
preflight de `tandem:run` sigue validando por su cuenta — el doctor es invocable u
omisible.

## Approach

1. **`scripts/codex-doctor.sh` — flag `--autonomous` y su sección.**
   - **Parsing:** `--autonomous` se acepta en el bucle de argumentos existente,
     combinable con `--smoke` (secciones independientes; el smoke conserva su
     contrato de coste). La línea de `usage()` pasa a
     `usage: codex-doctor.sh [--smoke] [--autonomous]`. Sin argumentos, el
     default se preserva con la garantía ACOTADA que tests y aceptación exigen
     (P2-2 ronda 2): la sección va gateada por el flag, la suite existente del
     doctor pasa sin editar una sola aserción y el test nuevo afirma en negativo
     que sin el flag no aparecen ni la sección ni el WARN; un argumento
     desconocido sigue siendo 64 antes de imprimir nada.
   - **Nuevo helper `warn()`** junto a `ok`/`bad`/`info`: imprime
     `  WARN  <texto>` y NO toca `fail` — un aviso honesto no es un problema
     encontrado, pero tampoco un `ok`.
   - **La sección**, impresa tras el bloque de model policy (encabezado
     `autonomous preflight (--autonomous):`), todo sin gastar un turno:
     1. **`TANDEM_PROMOTE_REVIEWS` estricto:** sin definir → `bad` nombrando la
        variable («autonomous runs must not ask mid-run; set it to 0 or 1»);
        definida con valor fuera de `{0,1}` (vacía incluida) → `bad` con el valor;
        `0`/`1` → `ok` con el efecto («1 — review record always written» /
        «0 — never written»). El check global existente (líneas ~342-344, que solo
        dispara bajo `TANDEM_AUTONOMOUS=1` y solo detecta unset) queda INTACTO —
        el estricto vive en la sección nueva, que valida en frío sin exigir que
        `TANDEM_AUTONOMOUS` esté puesta todavía.
     2. **Árbol limpio Y con HEAD:** sobre `${CLAUDE_PROJECT_DIR:-$PWD}`, DOS
        condiciones — `git rev-parse --verify HEAD` debe resolver (un repo unborn
        tiene status vacío pero `plan-approve.sh` exige HEAD y el run moriría
        FAILED tras gastar la fase de plan; P1-2 ronda 1) y
        `git status --porcelain` vacío. Con entradas → `bad` con el recuento y la
        instrucción (commit/stash antes de lanzar); sin HEAD → `bad` propio; git
        ausente o el directorio no es un repo → `bad`. Sin git no se degrada a
        `ok`: certificar en falso es exactamente lo que M16 enseñó a no hacer.
     3. **Flags efectivos del run**, en líneas `ok`/`bad` compactas que REUTILIZAN
        lo ya calculado por el bloque de policy (la variable `implementer` y las
        validaciones de `TANDEM_WEB_SEARCH` ya existen; los gates críticos de
        opus+CRITICAL ya corrieron arriba y no se duplican):
        `implementer=opus|sol`, `critical=0|1`, `worktree=in-place|worktree`,
        `web_search=default|off|on`. Validación nueva solo donde hoy no existe,
        acotada a la sección `--autonomous` para que el default no cambie:
        - `TANDEM_WORKTREE` definida con valor distinto de `1` (vacía incluida) →
          `bad` fail-closed (las skills solo reconocen unset y `1`; cualquier otra
          cosa es una config rota que hoy se ignoraría en silencio).
        - **`TANDEM_TRANSPORT` (P1-1 ronda 1):** unset o `exec` → `ok`; `mcp`,
          vacía-definida o desconocida → `bad` — la plan review del pipeline corre
          SIEMPRE por exec y un valor heredado respondería 64 fail-closed en el
          PRIMER lanzamiento del run: exactamente la clase de muerte-post-doctor
          que este preflight existe para atrapar.
        - **`TANDEM_AUTONOMOUS` tri-estado (P2-1 ronda 1):** unset o `0` → `ok`
          «ready (not enabled — export TANDEM_AUTONOMOUS=1 to launch unattended)»;
          `1` → `ok` activo; vacía-definida u otro valor → `bad` con el valor (un
          `TANDEM_AUTONOMOUS=bogus` lanzaría un run INTERACTIVO creyéndose
          desatendido).
        - **`TANDEM_EXEC_TIMEOUT_SECONDS` (P1-1 ronda 2):** unset → `ok` (defaults
          por rol); entero decimal positivo → `ok` con el valor; vacía,
          no-numérica o `0` → `bad` — `codex-start.sh` la valida antes de
          dependencias y estado (`_common.sh`, `exec_timeout_validate`) y el
          lanzamiento estándar de la plan review respondería 64 tras un doctor
          verde.
        - **`TANDEM_TURN_EFFORT` — debe estar UNSET (rondas 2–3):** unset → `ok`;
          CUALQUIER valor definido → `bad`, el inválido y el válido por razones
          distintas que el mensaje separa: un inválido mata todos los resumes de
          la ronda 2+ con 64 (`codex-resume.sh:65-70`), y un VÁLIDO exportado
          (p. ej. `low`) es peor — la variable es efímera por diseño, las skills
          la fijan inline solo en los nudges, así que un export global degrada en
          silencio toda ronda sustantiva 2+ al effort exportado en vez del xhigh
          del rol, con el preflight en verde.
        - **`TANDEM_CODEX_CWD` (P1-2 ronda 3):** unset → `ok`; definida → debe
          existir como directorio y resolver físicamente al MISMO directorio que
          `${CLAUDE_PROJECT_DIR:-$PWD}` resuelto. La resolución `pwd -P` de AMBOS
          lados es la regla de comparación PROPIA de esta sección — nueva, y
          necesaria precisamente porque `codex_cwd_validate` NO normaliza
          (comprueba existencia y pasa el path tal cual a `--cd`); el comentario
          del código lo dice para que nadie la «simplifique» a igualdad literal.
          Vacía-definida o inexistente → `bad` (64 de los wrappers en el primer
          lanzamiento); directorio existente que resuelve a OTRO sitio → `bad`
          nombrando el riesgo real: la plan review hereda la variable y su revisor
          inspeccionaría otro repositorio. Las skills la fijan inline por
          lanzamiento — el hazard es el export global.
     4. **El WARN de permisos, SIEMPRE presente e incondicional** — el corazón de
        M34: `warn` con dos líneas `info` de instrucción — los permission prompts
        de la sesión de Claude Code son una capa que tandem no puede leer ni tocar;
        antes de lanzar, configura los permisos de la sesión (allowlist de los
        comandos que el run usará, p. ej. vía `/permissions` o settings) para que
        ningún prompt bloquee el run sin humano delante. Nunca un `ok`: no es
        verificable desde un script.
     5. **Exit code:** la sección comparte `fail` — cualquier `bad` → exit 1; todo
        bien → exit 0 con el WARN presente igualmente.
2. **`skills/doctor/SKILL.md` — documentar el modo.** Nueva sección
   `## Autonomous preflight (--autonomous) — free`, espejo estructural de la de
   `--smoke` pero remarcando el contraste: cero turnos, cuándo usarlo (antes de
   decidir lanzar un run desatendido — es la respuesta ejecutable a «¿está esta
   sesión lista?»), qué NO cubre (la completitud del brief es juicio del
   orquestador al lanzar, y el WARN de permisos es un aviso que el humano debe
   resolver, no un check que pueda salir verde), y la tabla de reparaciones
   ampliada con la fila de `TANDEM_PROMOTE_REVIEWS`.
3. **`skills/run/SKILL.md` — una mención, sin cambiar el contrato.** El punto 3
   del preflight autonomous («Doctor + clean tree, as always») gana la forma
   invocable: `bash "$SCRIPTS/codex-doctor.sh" --autonomous` cubre ambos en una
   pasada. El preflight de run sigue validando por su cuenta (duplicación
   deliberada); ninguna otra línea de la skill cambia.
4. **`README.md` — una línea en §autonomous:** el preflight frío existe y cómo
   invocarlo, con la advertencia de permisos como su razón de ser.
5. **Tests — NUEVO `tests/doctor-autonomous.test.sh`** (stub de codex del runner,
   patrón `doctor-env-matrix.test.sh`; el runner NO provee repo git — el fixture
   se inicializa explícito, P2-2 ronda 1: `make_repo "$CLAUDE_PROJECT_DIR"` +
   seed commit antes de los casos «limpios»):
   - `--autonomous` con `TANDEM_PROMOTE_REVIEWS` sin definir → rc 1, `FAIL`
     nombrando la variable; el WARN de permisos presente TAMBIÉN en el fallo.
   - `TANDEM_PROMOTE_REVIEWS=1` (y `=0`), árbol limpio → rc 0, líneas `ok` de
     promote/árbol/flags, WARN de permisos presente, `tandem doctor: all good.`
   - `TANDEM_PROMOTE_REVIEWS=2` y vacía → rc 1, `FAIL` con el valor.
   - Árbol sucio (fichero nuevo en el repo del sandbox) → rc 1, `FAIL` del árbol.
   - **Anclaje (P2-2):** invocación desde OTRO directorio con solo el repo de
     `CLAUDE_PROJECT_DIR` sucio → rc 1 con el `FAIL` del árbol — una
     implementación anclada a `$PWD` saldría 0 y este caso la caza.
   - **Estados git separados (P1-2):** directorio no-repo → FAIL; repo unborn
     (`git init` sin commit, status vacío) → FAIL nombrando HEAD; PATH sin git
     (shim, patrón nojq de M25) → FAIL; repo commiteado y limpio → ok.
   - `TANDEM_WORKTREE=bogus` y vacía → rc 1; `TANDEM_WORKTREE=1` y unset → rc 0
     con el modo efectivo correcto.
   - **`TANDEM_TRANSPORT` (P1-1):** unset y `exec` → rc 0; `mcp`, vacía y bogus →
     rc 1 con el `FAIL` explicando el 64 del primer lanzamiento.
   - **`TANDEM_AUTONOMOUS` (P2-1):** unset y `0` → ok «ready (not enabled)»;
     `1` → ok activo; vacía y `bogus` → rc 1 con el valor.
   - **`TANDEM_EXEC_TIMEOUT_SECONDS` (P1-1 R2):** unset y `540` → rc 0; vacía,
     `abc` y `0` → rc 1 nombrando la variable.
   - **`TANDEM_TURN_EFFORT` (R2+R3):** unset → rc 0; vacía, `bogus` Y `low` (valor
     válido para el wrapper, pero un export global degrada las rondas
     sustantivas) → rc 1 nombrando la variable.
   - **`TANDEM_CODEX_CWD` (R3+R4):** unset → rc 0; igual al project root → rc 0;
     un SYMLINK que resuelve físicamente al project root → rc 0 (el pin de la
     equivalencia física: una comparación de strings literales falla aquí);
     vacía, inexistente y directorio existente AJENO → rc 1 (el ajeno con el
     mensaje del repo equivocado).
   - **Cero turnos (acotado, P1-3):** en TODOS los casos `--autonomous` SIN
     `--smoke`, ningún `codex exec` en el registro del stub (los
     `codex --version`/`login status` del doctor base no son turnos y se
     permiten).
   - Combinación `--autonomous --smoke`: la sección autonomous se imprime y el
     smoke gasta exactamente sus turnos de contrato — uno por modelo único
     configurado, ni uno más (contados en el stub).
   - Argumento desconocido → 64, y el string de usage COMPLETO asertado:
     `usage: codex-doctor.sh [--smoke] [--autonomous]` (P2-3: la aserción de
     prefijo existente pasaría sin el flag nuevo; esta es la exigente).
   - **Default intacto (afirmación acotada, P2-3):** sin el flag, la salida no
     contiene `autonomous preflight` ni el WARN (aserciones negativas del test
     nuevo), y la suite existente (`doctor-env-matrix`, `doctor-smoke`) pasa sin
     editar una sola aserción. No se reclama «byte a byte»: sin snapshot
     normalizado esa frase probaría más de lo que los tests demuestran.
6. **Docs y versión — trabajo del ORQUESTADOR, post-implementación, antes del
   gate final de review** (convención M25/P2-5, prohibido al implementador por
   template): `CHANGELOG.md` entrada **0.34.0** · `.claude-plugin/plugin.json`
   `version` 0.34.0 · `docs/BACKLOG.md` fila M34 → `hecha (v0.34.0)`.

## Key decisions & tradeoffs

- **El WARN de permisos es incondicional y jamás un PASS.** Es la decisión que
  define la pieza: tandem no puede leer la config de permisos de la sesión, así
  que cualquier `ok` sería certificar en falso (la lección de M16). El coste es
  que un usuario con los permisos perfectamente configurados verá el aviso
  igualmente — aceptado y deseado: el aviso es la documentación ejecutable de la
  única capa no fail-fast del modo.
- **Validación estricta `{0,1}` de `TANDEM_PROMOTE_REVIEWS` solo en la sección
  nueva; el check global existente queda intacto.** El existente (bajo
  `TANDEM_AUTONOMOUS=1`, solo unset, acepta `2` en silencio) es contrato pineado
  por la suite; endurecerlo cambiaría el default y el alcance de M34 es el
  preflight frío. La sección nueva sí valida el conjunto cerrado — es su razón de
  existir. Riesgo de divergencia asumido y documentado con comentario cruzado.
- **`TANDEM_WORKTREE` gana validación fail-closed SOLO bajo `--autonomous`.** Hoy
  un `TANDEM_WORKTREE=yes` se ignora en silencio (las skills comparan con `1`);
  en un run desatendido esa config rota merece FAIL antes de lanzar. Extender la
  validación a los wrappers sería otra mejora (entrada nueva de backlog si
  interesa) — aquí rompería el contrato byte-a-byte del default.
- **Árbol anclado a `${CLAUDE_PROJECT_DIR:-$PWD}`, con HEAD exigido.** El mismo
  anclaje que `state_init`: el preflight juzga el proyecto donde el run va a
  arrancar, no el cwd casual de quien invoca el script — y el test lo fija con el
  caso «invocado desde otro directorio». Un repo unborn no certifica: su status
  vacío es limpieza vacua y `plan-approve.sh` exigirá HEAD igualmente (ronda 1).
  Sin git → FAIL, nunca skip-como-ok.
- **`TANDEM_TRANSPORT` entra en el preflight; `mcp` es FAIL, no un modo.** La plan
  review del pipeline corre SIEMPRE por exec (gate por target de M21): un `mcp`
  exportado mata el PRIMER lanzamiento del run con 64 después de que el doctor
  hubiera dicho «all good» — la muerte-post-doctor que el preflight frío existe
  para atrapar (ronda 1). El mensaje del FAIL lo explica en vez de solo prohibir.
- **`TANDEM_AUTONOMOUS` tri-estado, no booleano ingenuo.** unset/`0` es «listo
  pero no activado» (el preflight frío se corre ANTES de decidir lanzar, exigir
  el flag ya puesto sería absurdo); `1` es activo; cualquier otra cosa es FAIL —
  un `bogus` lanzaría un run interactivo creyéndose desatendido (ronda 1).
- **Sección nueva tras el bloque de policy, reutilizando sus cálculos.** Los
  gates críticos (versión de Claude Code, `CLAUDE_CODE_EFFORT_LEVEL`,
  `CLAUDE_CODE_SUBAGENT_MODEL`) ya corren en el bloque de policy cuando aplican —
  duplicarlos en la sección sería una segunda fuente de verdad que derivaría. La
  sección añade solo lo que NO existe (promote estricto, árbol, worktree, WARN) y
  resume lo demás en líneas de estado efectivo.
- **Test nuevo dedicado, no ampliar `doctor-env-matrix`.** El fichero de matriz
  ya es largo y pinea el default; un modo nuevo con su propio contrato merece su
  fichero (convención de los runs recientes: un test por pieza), y «la suite
  existente pasa sin editar» se convierte en la aserción de no-regresión del
  default.
- **Cero turnos como aserción ACOTADA, no como promesa insatisfacible.** «Cero
  turnos» aplica a `--autonomous` sin `--smoke`; la combinación gasta exactamente
  el contrato del smoke (la ronda 1 cazó que la versión anterior exigía ambas
  cosas a la vez). El test cuenta ambos lados en el registro del stub — el mismo
  criterio ejecutable que ya protege el gating de `--smoke`.

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `scripts/codex-doctor.sh` | flag `--autonomous`, helper `warn()`, sección de preflight frío (promote estricto, árbol, flags efectivos, WARN de permisos); usage actualizado |
| `skills/doctor/SKILL.md` | sección del modo `--autonomous` + fila de reparación de `TANDEM_PROMOTE_REVIEWS` |
| `skills/run/SKILL.md` | una línea en el preflight autonomous nombrando la forma invocable |
| `README.md` | una línea en §autonomous |
| `tests/doctor-autonomous.test.sh` | NUEVO — la matriz del punto 5 |
| `CHANGELOG.md` · `.claude-plugin/plugin.json` · `docs/BACKLOG.md` | **orquestador, post-implementación:** entrada y bump 0.34.0, fila M34 |

## Acceptance & proof

1. Con `TANDEM_PROMOTE_REVIEWS` sin definir, `codex-doctor.sh --autonomous` sale
   distinto de 0 con una línea `FAIL` que nombra la variable; con valor fuera de
   `{0,1}` (vacía incluida), ídem con el valor mostrado.
2. Con todo definido, repo con HEAD y árbol limpio, emite el resumen (promote,
   árbol, flags efectivos — transporte y tri-estado de `TANDEM_AUTONOMOUS`
   incluidos) con el WARN de permisos SIEMPRE presente — también en los casos de
   fallo — y sale 0.
3. Árbol sucio (también cuando solo `CLAUDE_PROJECT_DIR` está sucio y se invoca
   desde otro cwd), repo unborn, no-repo, sin git, `TANDEM_WORKTREE` fuera de
   `{unset,1}`, `TANDEM_TRANSPORT` fuera de `{unset,exec}`, `TANDEM_AUTONOMOUS`
   fuera de `{unset,0,1}`, `TANDEM_EXEC_TIMEOUT_SECONDS` definida sin ser entero
   positivo, `TANDEM_TURN_EFFORT` definida con CUALQUIER valor (válido incluido),
   o `TANDEM_CODEX_CWD` definida sin resolver al project root → FAIL.
4. Cero turnos de modelo en toda invocación `--autonomous` SIN `--smoke` (ningún
   `codex exec` en el registro del stub); `--autonomous --smoke` gasta exactamente
   los turnos del contrato del smoke — uno por modelo único — y ni uno más.
5. Sin el flag, la salida por defecto no gana la sección ni el WARN (aserciones
   negativas) y la suite existente del doctor pasa sin editar una sola aserción;
   argumento desconocido sigue en 64 y el string de usage completo
   (`[--smoke] [--autonomous]`) queda asertado.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint).

## Risks

- **Alguna aserción existente que pinee la línea de `usage`:** cambia de
  `[--smoke]` a `[--smoke] [--autonomous]`. Verificar en la implementación
  (grep en `tests/`) y, si algún test la fija, actualizar ESA aserción es parte
  del cambio — nombrado aquí para que no sea un ajuste silencioso.
- **El sandbox de tests y el árbol limpio:** el caso «árbol sucio» debe ensuciar
  el repo del SANDBOX (`CLAUDE_PROJECT_DIR` del runner), nunca el checkout real —
  el guard de `tests/lib.sh` ya lo hace fatal si se intenta.
- **Divergencia entre el check global de promote y el estricto de la sección**
  (dos validaciones relacionadas): mitigado con comentario cruzado y con los
  casos `=2`/vacía del test nuevo, que fijan al estricto como el exigente.
- **Doctor sin `_common.sh`:** la sección debe seguir la disciplina local del
  script (sin `die`, reportarlo todo, `set -uo pipefail` sin `-e`) — cualquier
  helper nuevo se escribe en ese dialecto, no se importa.

## Out of scope

- La completitud del brief (juicio semántico del orquestador al lanzar; no se
  scripta).
- Leer o verificar la configuración real de permisos de la sesión de Claude Code
  (imposible desde un script; por eso el WARN existe y nunca es PASS).
- Endurecer el check global existente de `TANDEM_AUTONOMOUS+PROMOTE` o validar
  `TANDEM_WORKTREE` en los wrappers/skills (cambiaría el default; entrada nueva
  de backlog si interesa).
- Cambiar la lógica del preflight de `tandem:run` (la duplicación es deliberada).
- Turnos de modelo ADICIONALES causados por `--autonomous`: sin `--smoke` la
  invocación gasta cero; con él, exactamente el contrato del smoke y ni uno más.

## Assumptions

Modo autonomous: sin entrevista. Cada decisión que habría sido pregunta, con su
default conservador y su porqué:

- **Transporte de implementación de ESTE run: `TANDEM_IMPLEMENTER=sol`.**
  `TANDEM_CRITICAL=1` está en el entorno y el agente crítico Opus no está
  registrado en esta sesión (`.claude/agents/` solo tiene `implementer.md`);
  degradar en silencio está prohibido y en autonomous el mismatch sería un FAILED
  terminal. El mantenedor eligió explícitamente Sol para esta misma situación hoy
  (run M25): bajo sol, CRITICAL conserva su efecto completo (effort xhigh) y hay
  sandbox de SO. Es el default conservador con precedente humano directo.
- **Base del run: `tandem/implement-write-audit` (f01830a, v0.33.0), no main.**
  M25 está commiteado pero SIN mergear: arrancar desde main (v0.32.0) haría que
  este run reclamara la versión 0.33.0 y su entrada de CHANGELOG — colisión
  directa con la rama de M25 en el merge. Apilar sobre f01830a da 0.34.0 limpia;
  el orden de merge documentado es `implement-write-audit` → `doctor-autonomous`.
- **`TANDEM_PROMOTE_REVIEWS=1` ya estaba definido en el entorno** (verificado en
  el preflight): no es asunción — se registra que el registro de review se
  escribirá sin preguntar, como en M25.
- **Fichero de test nuevo dedicado** en vez de ampliar `doctor-env-matrix`
  (razonado en Key decisions; habría sido pregunta de estilo).
- **Alcance de la mención en `skills/run/SKILL.md`: una línea.** El backlog dice
  «expuesto en la skill» (la del doctor); la línea en run es el mínimo que hace
  descubrible el modo desde donde se lanza un run desatendido, sin tocar su
  contrato.
- **Versión 0.34.0** (siguiente minor tras la 0.33.0 de la rama base, convención
  del CHANGELOG).
