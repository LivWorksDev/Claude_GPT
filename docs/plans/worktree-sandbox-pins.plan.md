# Plan: worktree-sandbox-pins — M1 + M2 + M4 del backlog

Cierra los tres hallazgos de transporte/seguridad de `docs/BACKLOG.md`: **M1** (worktree
cableado también para el transporte sol y la review), **M2** (pin de red en los sandboxes de
escritura) y **M4** (`-c sandbox_mode=` también en start y swarm).

Endurecido por un enjambre ultra previo (3 workers + judge, run `m1m2-plan`): 9 hallazgos,
7 confirmados tras refutación, 2 refutados. La v1 de este plan era **insuficiente para su
propio goal** — pinear `network_access` deja abiertos otros canales de escape.

## Hechos verificados (no supuestos)

Comprobados en la CLI 0.144.4 instalada, sin gastar cuota de modelo, con
`codex debug prompt-input -c <k>=<v> hola` (valida la config y sale sin llamar al modelo):

- `codex exec -C/--cd <DIR>` existe (`--help`).
- `codex exec --ignore-user-config` existe: "Do not load `$CODEX_HOME/config.toml`; auth
  still uses `CODEX_HOME`" — el login sobrevive. Existe también `--ignore-rules` (no cargar
  los ficheros execpolicy `.rules` de usuario o proyecto).
- Los `-c` **siguen aplicándose y validándose** junto a `--ignore-user-config`: con el flag,
  `-c web_search=nonsense` sigue dando el error de variante desconocida. Flag y pins son
  complementarios, no excluyentes.
- Parsean como válidos: `sandbox_workspace_write.network_access=false`,
  `sandbox_workspace_write.writable_roots=[]`, `approval_policy=never`,
  `approvals_reviewer=user`, `web_search=disabled`.
- La clave de web search es **`web_search`** con variantes `disabled|cached|indexed|live`
  (un valor inválido da rc 1 nombrándolas). `web_search_mode` **no** es la clave de usuario.
- **Una clave desconocida se acepta EN SILENCIO** (rc 0): `-c web_search_mode=disabled` no
  falla, simplemente no hace nada. Consecuencia de diseño: cada clave nueva que este plan
  introduzca debe validarse por el error de **valor**, no por la aceptación de la clave.
- Existen en el binario `writable_roots`, `exclude_tmpdir_env_var`, `exclude_slash_tmp`,
  `ApprovalsReviewer{user,auto_review}`, `WebSearchMode{disabled,cached,indexed,live}`.

## Goal

Que ningún turno Codex de tandem pueda (a) ejecutarse o escribir fuera del árbol previsto
del proyecto, ni (b) heredar del entorno del usuario **ninguna** capacidad — red de
comandos, auto-aprobaciones, raíces escribibles extra, servidores MCP o execpolicies — con
el workdir fijado por flag explícito, el config de usuario ignorado por completo, los pins
explícitos como defensa en profundidad, y el contrato de argv congelado byte a byte.

**Alcance preciso de la promesa** (evita la sobrepromesa que el red-team detectó): esto
elimina la *herencia* de configuración y la red de los comandos del sandbox. La herramienta
nativa de búsqueda web queda en el **default de la CLI** — determinista, ya no dependiente
del config del usuario — y NO se pinea en los roles read-only por decisión de gate humano:
un seat que no puede escribir conserva capacidad útil. Los roles de escritura sí la pinean
en `disabled`, porque `implement.tpl` promete al modelo que no hay red. Se documenta el
residual: un seat read-only con búsqueda activa podría transmitir contenido del repo en una
query.

## Approach

### 1. Pins de sandbox y política (M2 + M4 + hallazgos del enjambre y del red-team)

En los tres scripts (`codex-start.sh`, `codex-resume.sh`, `codex-swarm.sh`), en todos los
roles, con posición fija en el argv:

- [x] `--ignore-user-config` y `--ignore-rules` — **hallazgo P1 del red-team**: pinear
  claves una a una nunca puede cubrir lo que no se enumera (servidores MCP con capacidad de
  red, execpolicies, claves futuras). Ignorar el fichero de config del usuario elimina la
  clase entera; el login sigue funcionando (auth usa `CODEX_HOME`). Los pins explícitos de
  abajo **se mantienen** como defensa en profundidad y como declaración de intención
  verificable: se ha comprobado que `-c` sigue aplicándose y validándose con el flag puesto.
  Coste aceptado y documentado: la personalización legítima del usuario (modelo por
  defecto, MCP propios) no llega a los turnos de tandem — que es exactamente el objetivo.

- [x] `-c sandbox_mode="$CODEX_SANDBOX"` — cinturón que hoy solo lleva resume (M4).
- [x] `-c sandbox_workspace_write.network_access=false` (M2).
- [x] `-c sandbox_workspace_write.writable_roots=[]` — **hallazgo P1**: `--cd` aporta la
  raíz primaria pero los roots configurados por el usuario se AÑADEN; sin este pin, un
  `writable_roots` hostil mantiene escribible el checkout principal desde un turno anclado
  al worktree.
- [x] `-c approval_policy=never -c approvals_reviewer=user` — **hallazgo P1**: con
  `approvals_reviewer=auto_review` en el config del usuario, un turno headless deja de
  forzar `never` y las peticiones de escape de sandbox o de red pasan a ser auto-aprobables.
- [x] `-c web_search=disabled` **solo en roles de escritura** (implement, image) —
  `network_access` gobierna la red de los comandos del sandbox, no la herramienta nativa de
  búsqueda; sin este pin, `implement.tpl` promete "Network access is unavailable" en falso.
  Los roles read-only (review, ask, ultra) conservan la **postura sin pin** aprobada en gate
  humano; con `--ignore-user-config` su comportamiento pasa a ser el default de la CLI,
  determinista, en vez de depender del config del usuario.
- [x] Los temp roots (`/tmp`, `$TMPDIR`) siguen escribibles a propósito (defaults
  `exclude_*=false`): las herramientas los necesitan y no son el árbol del proyecto. El
  lenguaje de aceptación y el prompt dicen exactamente eso — prohibido escribir en el
  proyecto fuera del worktree, permitido lo efímero.

### 2. Workdir explícito (M1, mecanismo)

- [x] Nueva env opcional `TANDEM_CODEX_CWD`: si está **definida**, los tres scripts la
  validan (debe nombrar un directorio existente; vacío o no-directorio → `die` 64) y añaden
  `--cd "$TANDEM_CODEX_CWD"` al argv, como UN solo token. Sin la variable, argv idéntico al
  actual.
- [x] La validación va **antes de `need_codex`**, para que el fallo sea del argumento y no
  dependa del toolchain.
- [x] Sin normalización propia (no `pwd -P`): el contrato es "un directorio existente,
  reenviado literal"; las skills pasan siempre rutas absolutas. Codex resuelve el `--cd`
  preservando symlinks; imponer canonicalización sería un contrato semántico nuevo
  (hallazgo `test-ci-2`, REFUTADO por el judge, se recoge como decisión explícita).

### 3. Estado durable vs directorio de ejecución (M1, corrección P2 del enjambre)

- [x] `CLAUDE_PROJECT_DIR` **NO** se reapunta al worktree. El estado de hilos sigue bajo el
  checkout principal, junto al heartbeat: si viviera en el worktree, `codex-show`/`codex-reset`
  desde el principal no lo verían y borrar el worktree destruiría el hilo y su historial de
  turnos.
- [x] El anclaje se hace **solo** con `TANDEM_CODEX_CWD=<abs-worktree>`: ejecución en el
  worktree, estado y heartbeat en el principal. Un worktree borrado y recreado reanuda el
  mismo hilo.
- [x] `state_init` no cambia.

### 4. Resolución del worktree como helper ejecutable (M1, corrección P2 del red-team)

**El fallo real de M1 vive en Markdown**, así que un test que le pase `TANDEM_CODEX_CWD` ya
correcto solo probaría el wrapper: una implementación que olvide cablear una skill pasaría
`verify.sh` en verde con M1 abierto. Por eso la lógica sale de las skills a un script:

- [x] `scripts/worktree-root.sh <slug>` — resuelve y valida la raíz de trabajo, y es lo que
  ambas skills invocan:
  - Sin `TANDEM_WORKTREE=1` → imprime la raíz del checkout principal.
  - Con `TANDEM_WORKTREE=1` → localiza el worktree **registrado** para
    `refs/heads/tandem/<slug>` con `git worktree list --porcelain` (no asume
    `.worktrees/<slug>`: la skill de implement permite reutilizar uno ya registrado en otra
    ruta), valida que existe y que su rama es la esperada, e imprime su ruta absoluta.
  - Cero o más de una coincidencia → `die` con mensaje explícito (**fail closed**), nunca
    un fallback silencioso al checkout principal.
- [x] Tests propios del helper: sin worktree, con worktree en ruta no-default, worktree
  registrado pero borrado del disco, rama ausente, y ambigüedad — cubriendo el modo de fallo
  que los tests de argv no pueden ver.
- [x] **Test de contrato de las skills** (el helper no basta: invocarlo sigue siendo una
  instrucción en Markdown, y olvidar UN solo bloque de comando deja M1 abierto con la suite
  en verde). `tests/skill-worktree-contract.test.sh` parsea
  `skills/implement/SKILL.md` y `skills/review/SKILL.md` y exige que **cada** invocación de
  `codex-start.sh`/`codex-resume.sh` en ellas aparezca acompañada de `TANDEM_CODEX_CWD`, y
  que ambas skills invoquen `worktree-root.sh`. Es una aserción estática sobre documentación
  ejecutable, pero es la única que cubre el modo de fallo real de M1.

### 5. Cableado en las skills (M1)

- [x] `skills/implement/SKILL.md`, transporte sol: resuelve `WORK_ROOT` con el helper y
  lanza todo `codex-start.sh`/`codex-resume.sh` (incluidas las continuaciones con
  `continue.tpl`) con `TANDEM_CODEX_CWD="$WORK_ROOT"`. Sin worktree, `WORK_ROOT` es el
  checkout principal y nada cambia.
- [x] `skills/review/SKILL.md`: contrato de worktree para **todos** los pasos 0–4, no solo
  el arranque (**hallazgo P1**: hoy el reset del hilo viejo, los fixes, el DIFF actualizado
  del fallback inline, las re-ejecuciones del gate, la promoción del review y **el commit
  final** son operaciones sin cualificar — con `tandem/<slug>` checked out solo en el
  worktree, el commit final podría ir al árbol equivocado). Contrato concreto: se resuelve
  `WORK_ROOT` una vez con el helper y a partir de ahí **todo** se ancla —
  `git -C "$WORK_ROOT"` en cada operación git incluido el commit; rutas absolutas
  `$WORK_ROOT/...` en cada Read/Edit/Write de ficheros del proyecto (los fixes que Fable
  aplica a mano son parte del hueco que el red-team señaló); `cd "$WORK_ROOT" && …` en cada
  comando no-git, incluido el testing gate; y `TANDEM_CODEX_CWD` en cada lanzamiento.
- [x] `skills/implement/prompts/implement.tpl`: la promesa de red se ajusta a la verdad
  (sin red de comandos y sin búsqueda web, ambas forzadas por pin) y se añade la línea de
  working root: el directorio inicial es la única raíz de trabajo del proyecto.
- [x] `ask` e `image` quedan **fuera** del anclaje automático (hallazgo `worktree-4`,
  REFUTADO por el judge): M1 cubre implementación sol + review final, e `image` está por
  diseño fuera del pipeline plan→review. Se documenta explícitamente que `TANDEM_WORKTREE`
  es implement/review-only, para que nadie espere aislamiento en esas dos skills.

### 6. Documentación

- [x] `docs/ARCHITECTURE.md`: los pins nuevos con su porqué; la decisión de web search
  (pin en roles de escritura, postura documentada en read-only, con la clave correcta
  `web_search`); el alcance implement/review-only de `TANDEM_WORKTREE`; y el truco de
  verificación `codex debug prompt-input` con la advertencia de que las claves desconocidas
  se ignoran en silencio.
- [x] `README.md`: tabla de política (frontera de red y aprobaciones forzadas) y
  `TANDEM_CODEX_CWD` en los overrides.
- [x] **Propiedad del orquestador, NO del implementador** (hallazgo P2-4 del red-team: ambos
  transportes prohíben explícitamente editar changelog y versiones, así que pedírselo obliga
  a violar su contrato o a reportar el plan incompleto): `CHANGELOG.md` 0.11.0,
  `.claude-plugin/plugin.json` a `0.11.0` y `docs/BACKLOG.md` (M1/M2/M4 → estado) los
  escribe Fable tras la implementación y antes de la verificación y el review.

### 7. Tests (lockstep con el argv)

- [x] Actualizar los tres tests de argv byte a byte (`start-argv-exact-order`,
  `resume-happy-argv-repin`, `swarm-tiers-readonly-literal`) con los pins nuevos y su orden;
  **revisar además las aserciones negativas** de `sandbox_mode` en start/swarm, que ahora se
  invierten.
- [x] `web_search=disabled` presente en implement/image y **ausente** en review/ask/ultra
  (aserción en ambos sentidos, por rol).
- [x] Caso nuevo `cwd-pin`: `--cd` presente y posicionado con valor válido; **inválido y
  vacío → 64 exacto**, con `CODEX_STUB_SCENARIO=version-fail` para probar que la validación
  ocurre ANTES de `need_codex` (el stub no registra las sondas `--version`, así que "sin
  argv" por sí solo no probaría nada); un directorio con espacios llega como un solo token;
  ausente → sin `--cd`.
- [x] Caso nuevo/extendido `worktree-sol-anchored`: lanzamiento con
  `TANDEM_CODEX_CWD=<worktree>` sin tocar `CLAUDE_PROJECT_DIR` → `--cd` en el argv, estado
  del hilo y heartbeat en el checkout principal, y `codex-show`/`codex-resume` desde el
  principal encuentran el hilo tras borrar y recrear el worktree.
- [x] Caso nuevo `worktree-root` para el helper de la §4: sin `TANDEM_WORKTREE` → checkout
  principal; worktree registrado en ruta NO-default → esa ruta; registrado pero ausente del
  disco, rama inexistente, o ambigüedad → fallo explícito (nunca fallback silencioso).
- [x] Caso nuevo `config-probe` para `scripts/config-probe.sh` (§8): clave cuyo valor
  inválido es rechazado → OK; clave que acepta cualquier valor (renombrada o desaparecida)
  → fallo nombrándola. Requiere **extender `tests/stub/codex`**: hoy todo lo que no es
  `--version`/`login` cae en la rama exec y no sabe simular ni el subcomando
  `debug prompt-input` ni el rechazo de un `-c`. Se añade al stub un escenario de rechazo de
  config (dispatch de `debug`, y salida rc 1 con el mensaje de variante desconocida cuando
  el escenario lo pide), manteniendo su contrato actual intacto para el resto de casos.

### 8. Vigilancia del drift de claves (hallazgo P2-3 del red-team)

Los pins son silenciosos si una versión futura renombra una clave, y el smoke actual solo
lanza un turno `ask` normal — seguiría verde. Sin esto, la mitigación que el plan afirma
tener no existe:

- [x] `scripts/config-probe.sh` — para cada clave pineada, lanza
  **`codex debug prompt-input`** (NO `codex exec`) con un valor deliberadamente inválido y
  exige que la CLI la rechace nombrándola; una clave que acepta cualquier cosa es una clave
  que ya no existe. El subcomando importa: con `codex exec`, el caso que el probe existe
  para detectar — la clave desaparecida — aceptaría el override y entraría en un turno real,
  gastando cuota y confundiendo un fallo de red o de auth con el diagnóstico.
  Aislamiento del entorno: `debug prompt-input` **no acepta `--ignore-user-config`** (ese
  flag es exclusivo de `codex exec`; verificado: rc 2 `unexpected argument`), así que el
  probe corre bajo un `CODEX_HOME` temporal vacío creado con `mktemp -d` y borrado con un
  `trap EXIT`. Verificado extremo a extremo con la 0.144.4: bajo ese CODEX_HOME, las cinco
  claves pineadas rechazan su valor inválido con rc 1 nombrando el campo y sus variantes
  (`network_access` espera boolean, `writable_roots` sequence, `approval_policy`,
  `approvals_reviewer` y `web_search` enumeran sus variantes), mientras que una clave
  inexistente devuelve rc 0 en silencio — que es justo la señal de drift.
- [x] `.github/workflows/tests.yml` entra en el alcance: el job `codex-smoke` ejecuta el
  probe contra la CLI **pineada y `@latest`**, de modo que un rename silencioso salga en el
  informe semanal.

## Key decisions & tradeoffs

- **Pins uniformes salvo `web_search`**: un solo contrato de argv, menos ramas; el pin de
  búsqueda sí es por rol porque en read-only aporta capacidad sin riesgo de escritura
  (decisión de gate humano) y en escritura sostiene una promesa del prompt.
- **Temp roots conservados**: pinear `exclude_slash_tmp`/`exclude_tmpdir_env_var` rompería
  herramientas legítimas; se acota el lenguaje en vez de la capacidad.
- **Estado en el principal, ejecución en el worktree**: separa dos contratos que la v1
  mezclaba; hace la reanudación robusta a la destrucción del worktree.
- **Sin normalización de `TANDEM_CODEX_CWD`**: contrato mínimo y predecible; las skills ya
  pasan rutas absolutas.
- **`ask`/`image` fuera de M1**: mantener el alcance del backlog; se documenta el límite en
  vez de ampliarlo en silencio.

## Files to touch

| Ruta | Cambio |
| --- | --- |
| `scripts/codex-start.sh`, `codex-resume.sh`, `codex-swarm.sh` | pins + `--cd` opcional validado antes de `need_codex` |
| `scripts/_common.sh` | helper de pins compartido si evita triplicar el bloque |
| `scripts/worktree-root.sh` | nuevo — resolución fail-closed de la raíz de trabajo (§4) |
| `scripts/config-probe.sh` | nuevo — vigilancia de renombrado silencioso de claves (§8) |
| `.github/workflows/tests.yml` | el smoke semanal ejecuta el probe contra CLI pineada y @latest |
| `skills/implement/SKILL.md` | anclaje worktree del transporte sol (incl. continuaciones) |
| `skills/review/SKILL.md` | contrato worktree en los pasos 0–4, commit incluido |
| `skills/implement/prompts/implement.tpl` | promesa de red veraz + working root |
| `docs/ARCHITECTURE.md`, `README.md` | pins, web search, alcance de TANDEM_WORKTREE, verificación de config |
| `CHANGELOG.md`, `.claude-plugin/plugin.json`, `docs/BACKLOG.md` | 0.11.0 y estados — **los escribe el orquestador**, no el implementador (§6) |
| `tests/start-argv-exact-order.test.sh`, `tests/resume-happy-argv-repin.test.sh`, `tests/swarm-tiers-readonly-literal.test.sh` | argv nuevo + aserciones negativas invertidas |
| `tests/cwd-pin.test.sh`, `tests/worktree-sol-anchored.test.sh`, `tests/worktree-root.test.sh`, `tests/config-probe.test.sh`, `tests/skill-worktree-contract.test.sh` | nuevos |
| `tests/stub/codex` | escenario de rechazo de config + dispatch de `debug` (§8) |

## Acceptance & proof

PROOF (debe pasar): `bash tests/verify.sh`

1. Argv byte a byte en los tres scripts con `--ignore-user-config`, `--ignore-rules` y los
   pins de sandbox, red, writable_roots y aprobaciones, en orden fijado; las aserciones
   negativas de `sandbox_mode` invertidas.
2. `web_search=disabled` en implement/image; ausente en review/ask/ultra.
3. `TANDEM_CODEX_CWD` válido → `--cd` posicionado y un solo token con espacios; inválido o
   vacío → 64 exacto incluso con `version-fail` (validación antes de `need_codex`); ausente
   → sin `--cd`.
4. Anclaje worktree: ejecución en el worktree, estado e heartbeat en el principal,
   reanudación desde el principal tras recrear el worktree.
4b. `worktree-root.sh` resuelve la ruta registrada real (incluida una no-default) y falla
   cerrado ante ausencia o ambigüedad — el modo de fallo que los tests de argv no ven.
4c. `config-probe.sh` marca como perdida cualquier clave pineada que deje de rechazar un
   valor inválido — usando `codex debug prompt-input` bajo un `CODEX_HOME` temporal, de modo
   que una clave desaparecida NUNCA arranca un turno real ni depende del entorno del
   usuario — y el smoke semanal lo ejecuta contra la CLI pineada y `@latest`.
4d. El test de contrato de skills falla si cualquier invocación de codex-start/resume en las
   skills de implement o review pierde su `TANDEM_CODEX_CWD`, o si dejan de invocar el
   helper — la única red contra el modo de fallo real de M1.
5. Las cinco claves nuevas se verifican con `codex debug prompt-input` en la implementación
   (comprobando el rechazo de un valor inválido por clave, dado que una clave desconocida se
   acepta en silencio) y el resultado se registra en el log del run.
6. Suite completa + shellcheck + actionlint en verde.
7. CHANGELOG, `plugin.json` y BACKLOG actualizados por el orquestador tras la
   implementación y antes de la verificación — nunca pedidos al implementador, cuyo
   contrato los prohíbe.

## Risks

- **`--ignore-user-config` descarta la personalización del usuario**: modelo por defecto,
  MCP propios y ajustes de UI dejan de aplicarse a los turnos de tandem. Es el objetivo, no
  un efecto colateral, pero se documenta en CHANGELOG como cambio de comportamiento visible;
  quien necesite un MCP en un turno tandem tendrá que pedirlo como feature, no heredarlo.
- **Un pin puede romper flujos legítimos**: `web_search=disabled` quita búsqueda al
  implementador sol y `approval_policy=never` fuerza el fallo en vez de la escalada — ambos
  son el comportamiento deseado y quedan en CHANGELOG como cambio deliberado.
- **Claves desconocidas silenciosas**: si una versión futura renombra una clave, el pin deja
  de aplicar sin avisar. Mitigación: la verificación por valor inválido de la aceptación 5,
  y el smoke semanal como vigía.
- **La reescritura de la review toca un flujo crítico**: mitigado por los tests de v0.10.0 y
  por el hecho de que sin worktree el comportamiento es idéntico al actual.
- **Cascada en los tests de argv**: esperada; el diff de tests va en el mismo commit.

## Out of scope

- El resto del backlog (M3, M5–M13, M15).
- Anclaje worktree de `ask`/`image` (documentado como límite, no implementado).
- Pin de `web_search` en roles read-only (postura documentada, decisión de gate humano).
- Pin de los temp roots del sandbox.
- Migración a `codex mcp-server` (fase 2 del roadmap).
