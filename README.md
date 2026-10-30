# tandem — Fable orquesta, Opus implementa, Codex ataca

Plugin de Claude Code que convierte a **Claude (Fable 5)** en orquestador y árbitro, a **Claude Opus 5** en implementador por defecto y a **OpenAI Codex** (GPT-6 Astra por defecto) en red-team y revisor adversarial independiente, todo desde una sesión normal de Claude Code:

```
Fable planifica → Codex ataca el plan (read-only, hilo persistente)
    → gate humano → Opus 5 implementa (subagente restringido, rama dedicada)
    → Fable lee el diff completo y ejecuta el testing gate
    → un Codex NUEVO revisa el código (sin contexto previo)
    → gate humano → Fable hace el commit (el implementador nunca commitea)
```

> [!IMPORTANT]
> El implementador por defecto ahora es Opus 5. Para conservar el transporte anterior de implementación con Codex CLI, define `TANDEM_IMPLEMENTER=sol`. Codex sigue siendo el red-team del plan y el revisor final independiente en ambos casos.

## Instalación

Requisitos: [Codex CLI](https://github.com/openai/codex) con login activo (`npm install -g @openai/codex@latest && codex login`), `jq`, `git`.

**Como plugin (recomendado):**

```bash
# añade este repo como marketplace e instala
claude plugin marketplace add <ruta-o-git-de-este-repo>
claude plugin install tandem@claude-gpt
```

**Para desarrollo local:**

```bash
claude --plugin-dir /ruta/a/este/repo
```

Verifica el toolchain con `/tandem:doctor`. Ese diagnóstico es gratis (no gasta ni un turno) e incluye el conflicto de `CLAUDE_CODE_SUBAGENT_MODEL` que pararía el preflight de `/tandem:implement`. Si además quieres comprobar que los **nombres de modelo configurados siguen existiendo** — una deprecación descubierta a mitad de un run largo sale cara —, `bash scripts/codex-doctor.sh --smoke` lanza un turno real mínimo por modelo único (3 con la política default) y distingue "modelo retirado" de fallo de auth/red/timeout. Cuesta cuota, así que **nunca corre por defecto**: solo con el flag explícito.

## Skills

| Skill | Qué hace |
| --- | --- |
| `/tandem:run` | Pipeline completo: plan → red-team → implementación → verificación → review → commit |
| `/tandem:plan` | Entrevista + plan + revisión adversarial de Codex hasta APPROVED (cap de rondas) |
| `/tandem:implement` | Opus 5 implementa por defecto (`TANDEM_IMPLEMENTER=sol` usa Codex CLI); Fable verifica el diff y ejecuta el testing gate |
| `/tandem:review` | Code review final por un hilo Codex nuevo e independiente; con `<label> --range A..B`, review de un rango ya committeado fuera del pipeline (veredicto y hallazgos, nunca un commit) |
| `/tandem:ask` | Segunda opinión de Codex sobre cualquier tema, con follow-ups en el mismo hilo |
| `/tandem:image` | Genera assets de imagen con la herramienta nativa de Codex (gpt-image-2), con transparencia por chroma-key para sprites |
| `/tandem:ultra` | Enjambres multi-agente estilo ultracode dirigidos por Fable, con todos los asientos en Codex (read-only) |
| `/tandem:council` | Consejo adversarial de tres modelos frontera para valorar una idea y optimizar la estrategia hacia un objetivo: la sesión (Opus 5.5) lidera y sintetiza, Fable 5.1 y GPT-6 Astra (solo lectura) proponen a ciegas, se contrainterrogan y revisan hasta consenso o tope, los tres al nivel del perfil de esfuerzo que eliges (exploratorio = high, estándar = xhigh, crítico = max); informe + transcripción en `docs/council/` |
| `/tandem:status` | Dónde está un run y cómo se retoma, leyendo `.tandem/` — nunca gasta un turno |
| `/tandem:doctor` | Diagnóstico del toolchain (codex, login, jq, política de modelos, status line); `--smoke` añade un turno real por modelo único para verificar que los nombres siguen vivos, solo bajo demanda |
| `/tandem:statusline` | Instala/desinstala la status line (modelo, contexto, coste + puerta Codex en vivo) |

## Status line

Debajo del prompt puedes ver a la vez la sesión de Claude y lo que está haciendo Codex:

```
◈ Fable 5 xhigh✳ · ctx 34% ▓▓▓░░░░░░░ · $0.42 · mi-proyecto ⑂ tandem/auth-refactor
⚙ codex gpt-6-sol · implement high · t3 · workspace-write · exec pytest -q · 1m42s · auth-refactor
```

Cuando la ocupa un turno de Codex — en vuelo o recién terminado (15 min) — la segunda línea narra en vivo la actividad real (`exec …`, `edit …`, `thinking…`) leída del stream de eventos, y al acabar colorea el desenlace — verde `APPROVED`/`IMPLEMENTATION_COMPLETE`, ámbar `REVISE`, rojo `REQUEST_CHANGES` o fallo, gris si el proceso murió sin dejar rastro. Funciona también con `TANDEM_WORKTREE`: el heartbeat se escribe siempre en el checkout principal (resuelto vía `git rev-parse --git-common-dir`).

Durante una implementación Opus esa línea la ocupa el intento, leído del estado durable `.tandem/state/implement-claude/<slug>.json`: `⚒ opus implement · running · <slug>` en ámbar mientras trabaja, el sentinel coloreado durante 15 min al cerrar (`IMPLEMENTATION_COMPLETE` verde, `IMPLEMENTATION_PARTIAL` ámbar) y `⚠ sin señal` en gris si un `running` lleva más de 2 h sin cerrarse. Es presencia y desenlace, no actividad en vivo — el fichero solo se escribe al lanzar y al cerrar, así que narrar más sería inventarlo (queda para v2) y Claude Code ya muestra el progreso del subagente de forma nativa. Un turno de Codex vivo tiene prioridad absoluta sobre la fila; entre estados no vivos gana el más reciente, para que la review que acaba de terminar no tape la implementación que acaba de empezar.

Además, los turnos lanzados en background narran su progreso en el panel **Shell details** de Claude Code — cada comando que Codex ejecuta (`» exec …` → `✓ ok`/`✗ exit N`), cada fichero que toca (`» edit …`) y los tokens del turno, en tiempo real.

Cada turno `exec` tiene además un watchdog propio: un timeout mata por
TERM→KILL el grupo completo del turno, contabiliza cualquier `turn.completed`
que ya hubiera aterrizado y termina con fallo visible. En start/resume el
heartbeat queda en `failed`; en ultra no hay heartbeat compartido por diseño y
el observable equivalente es el mensaje de timeout más el slot liberado.

**Instalación: `/tandem:statusline`** (o `bash scripts/statusline-install.sh`). Claude Code no permite que un plugin aporte la status line principal (el `settings.json` de un plugin solo admite `agent` y `subagentStatusLine`), así que la skill la instala con tu consentimiento: escribe un shim en `~/.claude/tandem-statusline.sh` que re-resuelve el `statusline.sh` del plugin en cada render — sobrevive a las actualizaciones del plugin (cuya ruta de caché cambia por versión) y degrada a una línea mínima si tandem desaparece — y añade la entrada `statusLine` a tu `settings.json` (escritura atómica, backup en `settings.json.tandem-backup`, y nunca pisa una statusLine ajena sin `--force`). `refreshInterval: 2` mantiene vivo el cronómetro mientras un `codex exec` bloquea. `/tandem:statusline uninstall` lo deshace; `/tandem:doctor` comprueba si está instalada.

## Política de modelos y permisos

| Rol | Modelo (default) | Effort | Frontera de ejecución |
| --- | --- | --- | --- |
| Revisor / consultor | `gpt-6-astra` | `xhigh` | `read-only` (fijado, no sobreescribible) |
| Implementador (default) | Claude Opus 5 | Rol (frontmatter) | Allowlist harness `Read, Edit, Write, Glob, Grep, Bash`; sin MCP/web/Agent anidado |
| Implementador Opus crítico (`TANDEM_CRITICAL=1`) | Claude Opus 5 (`tandem:implementer-critical`) | `xhigh` (frontmatter; requiere Claude Code ≥ 2.1.111 — el doctor lo verifica) | Idéntica allowlist, cuerpo byte a byte (paridad fijada por test) |
| Implementador (`TANDEM_IMPLEMENTER=sol`) | `gpt-6-sol` | `high` | Sandbox OS `workspace-write` (fijado, no sobreescribible) |
| Implementador Sol crítico (`TANDEM_CRITICAL=1`) | `gpt-6-sol` | `xhigh` | Sandbox OS `workspace-write` |
| Generador de imágenes | `gpt-6-sol` | `high` | `workspace-write` (fijado, no sobreescribible) |
| Consejo (`/tandem:council`) | Asiento Codex `gpt-6-astra` (rol `council`) · asiento Claude `claude-fable-5-1` (`agents/council-fable*.md`, una pareja web/offline por nivel) · líder: la sesión, Opus 5.5 | el nivel del perfil elegido, el mismo para los tres: `high` (exploratorio), `xhigh` (estándar) o `max` (crítico) — Astra por `TANDEM_COUNCIL_EFFORT` que exporta `council.sh astra`; Fable por el frontmatter del agente del perfil; el líder por sesión | Astra `read-only` (fijado); Fable allowlist `Read, Grep, Glob, WebSearch, WebFetch` (modo confidencial: sin web) |

Política forzada en **todos** los turnos Codex (start, resume y asientos de enjambre), con el argv congelado byte a byte por la suite:

| Frontera | Cómo se fuerza | Alcance |
| --- | --- | --- |
| Config del usuario | `--ignore-user-config` + `--ignore-rules` | Todos: ni `config.toml` ni execpolicies `.rules` llegan al turno (el login sigue funcionando) |
| Sandbox | `--sandbox <modo>` + `-c sandbox_mode=<modo>` | Todos |
| Red de comandos | `-c sandbox_workspace_write.network_access=false` | Todos |
| Raíces escribibles | `-c sandbox_workspace_write.writable_roots=[]` | Todos (los roots del config se AÑADEN a la primaria: sin el pin, el checkout principal seguiría escribible) |
| Aprobaciones | `-c approval_policy=never -c approvals_reviewer=user` | Todos: un turno headless nunca auto-aprueba un escape de sandbox |
| Búsqueda web nativa | `-c web_search=disabled` | Roles de **escritura** (`implement`, `image`) siempre; todos los asientos con `TANDEM_WEB_SEARCH=off`. Sin la variable, `review`/`ask`/`ultra` conservan el default actual |
| Temp roots (`/tmp`, `$TMPDIR`) | sin pin, a propósito | Escribibles: las herramientas los necesitan y no son el árbol del proyecto |

`scripts/config-probe.sh` vigila que ninguna de esas claves se haya renombrado en silencio (la CLI acepta una clave desconocida con rc 0), y el smoke semanal lo ejecuta contra la CLI pineada y `@latest`.

La frontera Opus es una allowlist aplicada por Claude Code: elimina herramientas MCP, conectores, web y subagentes anidados, pero Bash no equivale a un sandbox OS y podría ejecutar comandos fuera de esa lista si la sesión los permite. El agent type y el prompt prohíben commits, pushes, cambios de rama/remotos y trabajo fuera de la ruta indicada; Fable comprueba después rama, `HEAD`, remotos y las dos vistas del diff. Además, todo intento fresco de implement publica un censo de escrituras y un guard antes del lanzamiento: la auditoría de cierre degrada a PARTIAL los lockfiles, manifests de dependencias, `patches/` o cambios de conjunto en `node_modules` no declarados por el plan commiteado. El transporte Sol conserva el sandbox OS existente y usa la misma auditoría. `CLAUDE_CODE_SUBAGENT_MODEL`, si está definida, debe valer exactamente `opus` o el preflight para; el modelo auto-reportado por el subagente es informativo, no una verificación runtime robusta.

El plugin incluye por ello un hook `PreToolUse` (Claude Code lo muestra en el prompt de confianza al instalar o actualizar). Mientras existe el guard de un intento, bloquea con exit 2 los segmentos Bash que invocan `npm`, `pnpm` o `yarn` seguidos de `install`, `i`, `ci`, `add`, `remove`, `rm`, `uninstall`, `un`, `update`, `up` o `upgrade`, además de `yarn` sin subcomando; opciones globales interpuestas también cuentan. `npm test`, `npm run build`, `pnpm exec …` y Bash sin esos patrones pasan. El guard cae únicamente tras gate+auditoría verdes o con el reset exacto; un crash lo deja fail-closed sin caducidad. Esto frena bucles accidentales, no a un implementador adversarial capaz de borrar el guard/censo; Git tampoco revela ficheros deny-listed ignorados, y el censo solo compara nombres de primer nivel de `node_modules`, no su contenido profundo.

Por encima de `xhigh` existen `max` y `ultra`; para una revisión final especialmente delicada puedes usar `TANDEM_REVIEW_EFFORT=ultra` puntualmente.

Overrides por entorno: `TANDEM_IMPLEMENTER` (`opus` default / `sol`; cualquier otro valor falla), `TANDEM_REVIEW_MODEL`, `TANDEM_REVIEW_EFFORT`, `TANDEM_IMPLEMENT_MODEL`, `TANDEM_IMPLEMENT_EFFORT` (estos dos últimos solo afectan al transporte Sol), `TANDEM_IMAGE_MODEL`, `TANDEM_IMAGE_EFFORT`, `TANDEM_PLAN_ROUNDS`, `TANDEM_CR_ROUNDS`, `TANDEM_IMPL_ROUNDS`, `TANDEM_WORKTREE` (**plan-approval + implement/review**: desde 0.12 decide también dónde aterriza el commit de aprobación del plan — checkout principal o `.worktrees/<slug>` — y debe llevar el mismo valor en todas las fases de un run; `ask` e `image` nunca se anclan a un worktree), `TANDEM_CODEX_CWD` (raíz de trabajo del turno; se reenvía literal como `codex exec --cd` y debe nombrar un directorio existente — vacío o inexistente falla con 64. Las skills la resuelven con `scripts/worktree-root.sh <slug>`, que falla cerrado en vez de caer al checkout principal), `TANDEM_TURN_EFFORT` (effort **efímero, por invocación**, leído SOLO por `codex-resume.sh`: las skills lo prefijan a los turnos-recordatorio — la reanudación que solo pide la línea `VERDICT:`/sentinel que faltó, con su `prompts/nudge.tpl` — para que re-emitir lo ya razonado no pague el effort caro del rol; valores válidos `minimal`, `low`, `medium`, `high`, `xhigh`, `max` y `ultra`, cualquier otro (vacío incluido) falla con 64 nombrando la variable y antes incluso de comprobar dependencias. `codex-start.sh` y `codex-swarm.sh` la ignoran a propósito, y el sandbox del rol nunca se ve afectado: esto solo toca effort), `TANDEM_WEB_SEARCH` (`off` cierra la búsqueda nativa en **todos** los asientos; `on` declara explícitamente el default read-only y nunca abre los roles de escritura; cualquier otro valor, vacío incluido, falla cerrado con 64 antes de dependencias o estado), `TANDEM_AUTONOMOUS`, `TANDEM_PROMOTE_REVIEWS` (`1` siempre / `0` nunca / sin definir: se ofrece en el gate), y para los enjambres `TANDEM_ULTRA_{JUDGE,WORKER,SCOUT}_MODEL`/`_EFFORT`, `TANDEM_ULTRA_CONCURRENCY` (default 4) y `TANDEM_ULTRA_SLOT_TIMEOUT` (segundos que un seat espera slot libre antes de fallar con 75 sin haber arrancado su turno; default 1800). Estas dos últimas las aplica el propio `codex-swarm.sh` con un semáforo por run: enteros positivos, y vacío o ≤ 0 falla con 64 nombrando la variable, antes incluso de comprobar dependencias. Los sandboxes Codex no se pueden sobreescribir y `danger-full-access`/`--yolo` no se usan nunca.

`TANDEM_EXEC_TIMEOUT_SECONDS` sobreescribe el watchdog de `codex exec` en
start, resume y ultra. Sin override, la matriz por modo de lanzamiento dominante
es 540 s para `ask`/`image` (foreground) y 3600 s para
`review`/`implement`/`ultra`/`council` (background), nunca por sandbox. El literal
foreground queda por debajo del cap de 600 s del tool Bash para que el wrapper
clasifique, reapee y contabilice antes de que muera la invocación exterior; por
eso las excepciones foreground documentadas de review/implement prefijan
`TANDEM_EXEC_TIMEOUT_SECONDS=540`. Vacío, texto o cero falla cerrado con 64 antes
de dependencias o estado. Es un mando independiente de
`TANDEM_MCP_TIMEOUT_SECONDS`: con `TANDEM_TRANSPORT=mcp`, el start obedece el
watchdog MCP y las continuaciones híbridas `exec resume` obedecen el exec; si se
amplía uno para un caso extremo, hay que ampliar también el que corresponda a
los otros turnos del hilo.

## Modo autonomous

`TANDEM_AUTONOMOUS=1` permite un `/tandem:run` de principio a fin sin interacción: el HITL se mueve a los bordes — un **brief completo** a la entrada (si no da para goal + aceptación sin inventar, el run ni empieza) y la revisión humana de la **rama commiteada** a la salida. Cada gate humano se convierte en política verificable:

| Gate | Política |
| --- | --- |
| Aprobación del plan | Solo `VERDICT: APPROVED` de Codex; se commitea el plan y se continúa |
| Gate final + commit | Solo review `APPROVED` **y** testing gate en verde; commit en `tandem/<slug>` |
| Preguntas de la entrevista | Sección **Assumptions** en el plan: decisión → default conservador → por qué (auditable) |
| `TANDEM_PROMOTE_REVIEWS` | Obligatorio definirlo (0/1) — se valida en el preflight, nada pregunta a mitad de run |

Estados terminales, siempre con informe final (assumptions, veredictos por ronda, diffstat, gate, rama, log): `COMPLETED` · `DEADLOCK` (ningún APPROVED — jamás se aprueba por agotamiento) · `PARTIAL` (implementación incompleta tras los caps) · `FAILED`. Cualquier estado no-COMPLETED se retoma con las skills interactivas normales.

Líneas rojas idénticas al modo interactivo: nunca push, nunca merge, nunca la rama por defecto; sandboxes, modelos y caps intactos. La autonomía recoloca los puntos de aprobación — no compra permisos. Antes de decidir lanzar, `bash scripts/codex-doctor.sh --autonomous` ejecuta gratis el preflight frío (promoción, HEAD + árbol limpio y flags efectivos) y muestra siempre el WARN de permisos: los permission prompts de la propia sesión de Claude Code son una capa aparte que tandem ni puede ni debe tocar, así que para un run realmente desatendido configura los permisos de la sesión en consecuencia.

## Modo ultra — enjambres dirigidos por Fable

`/tandem:ultra` lanza workflows multi-agente estilo ultracode (reviews adversariales multi-dimensión, paneles de jueces, cazas de bugs, barridos de investigación) donde **todos los asientos que razonan son Codex**: donde un workflow nativo sentaría a Fable va Astra `xhigh` (tier `judge`), donde iría Opus va Sol `high` (`worker`) y donde iría Haiku va Luna `high` (`scout`). Los agentes Claude del workflow son solo envoltorios `haiku` que lanzan cada turno vía `scripts/codex-swarm.sh` y estructuran la respuesta.

La skill empieza siempre con una deliberación dirigida por Fable — si el enjambre compensa, qué forma tiene y cuántos turnos costará — y no lanza nada sin tu aprobación (en autonomous, sin un brief que lo determine todo). Invariantes propias del modo: cada seat es un hilo fresco e independiente, `read-only` fijado y sin resume; el enjambre nunca escribe ni commitea — sus hallazgos alimentan el pipeline normal, nunca sustituyen el gate de `tandem:review`; concurrencia acotada por `TANDEM_ULTRA_CONCURRENCY` (default 4) y aplicada por el propio script — un semáforo por run bajo `.tandem/state/ultra/<run>/.slots/`, sin chunking en el workflow: los seats sobrantes hacen cola dentro del script y el que no consigue slot en `TANDEM_ULTRA_SLOT_TIMEOUT` s sale con 75 sin gastar cuota. El estado va a `.tandem/state/ultra/<run>/` y el informe del run a `.tandem/log/ultra-<run>.md`. Si la sesión no dispone del tool Workflow, la skill degrada al fan-out con `Agent` o a turnos secuenciales en background — mismos scripts, mismos prompts.

## Modo consejo — tres modelos valoran una idea

`/tandem:council` no ataca un plan ni un diff: valora una idea y optimiza el procedimiento con el que alcanzar un objetivo. Es un consejo adversarial de tres modelos frontera de dos familias. La **sesión** (Opus 5.5) lidera: entrevista al usuario, fija un brief, compite con su propia propuesta, modera y sintetiza — pero **no vota**. **Fable 5.1** (subagente Claude persistente, `tandem:council-fable*`) y **GPT-6 Astra** (hilo Codex persistente, rol `council`), de solo lectura, proponen a ciegas, se contrainterrogan y revisan la síntesis ronda a ronda hasta consenso o tope (`TANDEM_COUNCIL_ROUNDS`, 4 por defecto). El usuario interviene solo al principio (preguntas, perfil de esfuerzo y aprobación del brief); después el consejo corre solo hasta el final.

**Perfiles de esfuerzo.** Un perfil fija UN nivel para los tres asientos (líder, Fable y Astra): `exploratorio` (high) para tantear una idea o una decisión barata de revertir, `estandar` (xhigh) para una decisión relevante pero reversible o que necesita cifras contrastadas, `critico` (max) para una decisión irreversible o cara. Tras la entrevista la skill recomienda uno y **tú lo eliges** entre los viables (`council.sh profile <run-id> <perfil>`); se congela con el brief y no cambia durante el run ni en una recuperación (para otro perfil, un run nuevo). Queda medido, no solo declarado: el esfuerzo de Astra en el `meta.json` de cada turno y el de Fable en su transcript (otro nivel → FAILED), y el del líder en el transcript de la sesión, que `metadatos.md` muestra sin bloquear nunca.

El contrato ejecutable es `scripts/council.sh` (bash 3.2 + jq): letras A/B/C por permutación aleatoria (el moderador no las elige; se revelan al final), brief y aportaciones del líder **sellados** antes de lanzar a los asientos, canal fiel byte a byte (Astra por los ficheros del wrapper, con un recibo de éxito por turno; Fable por la captura de su transcript, con el modelo verificado línea a línea y el uso deduplicado por `message.id`), topes ejecutables por fase y asiento, registro de objeciones con formatos de línea estrictos y una regla de consenso que solo dictamina `council.sh status`. Toda cifra lleva fuente, y la síntesis se audita con WebFetch antes de cada ronda.

**Requisitos.** La sesión debe correr en Opus 5.5 al nivel del perfil elegido: el plugin no puede fijar el líder, así que la skill le pide autodeclararse y el usuario lo confirma en el gate del brief (`/effort <nivel>` o el selector; `max` solo se elige por sesión — no se acepta en `effortLevel` ni en `modelSettings` —, `high` y `xhigh` sí). Tras actualizar el plugin hace falta una **sesión nueva** para que Claude Code registre los agentes del consejo — en la 0.38.0, los cuatro nuevos de los perfiles `estandar` y `exploratorio` (los agentes de plugin no se recargan en caliente). `init` se lanza desde la raíz del proyecto e imprime `PROJECT`; la skill fija esa ruta (`CLAUDE_PROJECT_DIR`) en cada llamada posterior. `bash scripts/council.sh preflight` lo comprueba todo sin gastar un turno e informa de los **perfiles viables** (y del motivo de cada descartado): el catálogo de `codex debug models` para el modelo de Astra y los niveles que admite, el pin de Fable leído de los seis agentes, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, `CLAUDE_CODE_EFFORT_LEVEL` (solo deja viable el perfil de su nivel), `maxEffortLevel` en los settings en alcance (descarta los perfiles por encima), `TANDEM_COUNCIL_EFFORT` (definida es FAIL), `TANDEM_COUNCIL_PROFILE` y `TANDEM_TURN_EFFORT`. Falla solo si no queda ningún perfil viable o el entorno está roto.

**Coste.** Cada turno sustantivo corre al nivel del perfil elegido (high, xhigh o max): la cota típica es `2 × (2 + R)` turnos de los asientos a ese nivel (12 con R = 4) y el techo `5 × (2 + R)` (30 con R = 4) más `2 + R` recordatorios de Astra en `low`; el preflight la muestra por perfil y el gate del brief, para cada opción. Los tokens de Fable salen de su transcript y `metadatos.md` los marca como **cota inferior** cuando algún mensaje no trae su `usage` definitivo (en la práctica, sus mensajes de entrega). Según el plan de suscripción del usuario, Fable puede facturar a créditos de uso ([doc](https://code.claude.com/docs/en/model-config#fable-and-usage-credits)) — para subagentes no está documentado y el preflight no lo ve.

**Modo confidencial.** `council.sh init <run-id> --offline`: Astra sin búsqueda web (`TANDEM_WEB_SEARCH=off` en sus turnos) y Fable a través del gemelo offline del agente de su perfil (`tandem:council-fable-offline`, `-xhigh-offline` o `-high-offline`), cuya allowlist no tiene herramientas web — una garantía del harness, no de una instrucción. Las cifras que no vienen del usuario ni del proyecto quedan como SUPUESTO.

**Entregable.** Todo lo legible queda en `docs/council/<YYYY-MM-DD-slug>/` (o `TANDEM_COUNCIL_DIR`): brief, prompts de cada fase, propuestas, contrainterrogatorio, rondas, síntesis, auditorías de fuentes, registro, `estrategia-final.md` (copia byte a byte de la síntesis aprobada), `informe.md` y `metadatos.md` (perfil, letras → modelo/effort con su evidencia medida, veredictos, anomalías, tokens). El estado de máquina vive en `.tandem/state/council/` (gitignorado). **Nada se commitea ni se pushea**: decides tú qué hacer con `docs/council/` — cuidado con ideas confidenciales en un repo público.

**Informe visual.** Al final, `council.sh report <run-id>` deja también `informe.html`: una sola página autocontenida y sin red (ni CDN, ni fuentes web, ni librerías) con el sello del veredicto, KPIs, el calendario de los primeros 30 días, el gráfico de hitos, el mapa del debate fase × asiento, las objeciones filtrables con su historia ronda a ronda, la estrategia plegable, todos los documentos del run, los tokens, los turnos y las fuentes. Se abre con doble clic en cualquier navegador, también en el móvil y en modo oscuro. Es una **vista derivada**: los Markdown siguen siendo el registro con autoridad, los hechos que muestra (objeciones, estados, veredictos, consenso, fuentes, tokens) los calcula `council.sh` con la misma gramática que `ledger` y `status`, y nunca se edita a mano. Si cambia un documento del run, `status` lo avisa (`informe.html desactualizado`) y basta volver a ejecutar `report`; también sirve para generar el HTML de un run anterior a la 0.37.0.

Variables: `TANDEM_COUNCIL_ROUNDS` (tope de rondas, 4), `TANDEM_COUNCIL_INTAKE` (`ask` por defecto: entrevista; `auto`: sin preguntas, supuestos explícitos en el brief — no lee `TANDEM_AUTONOMOUS`), `TANDEM_COUNCIL_MODEL` (asiento Codex; `TANDEM_REVIEW_*` no le afecta), `TANDEM_COUNCIL_PROFILE` (el perfil de un intake `auto`; sin ella, `critico`), `TANDEM_COUNCIL_EFFORT` (ya no se fija a mano: el preflight falla si está definida, porque el perfil decide el esfuerzo de Astra; `ultra` deja de ser elegible en el consejo), `TANDEM_COUNCIL_LEADER_MODEL` (líder esperado, `claude-opus-5-5`), `TANDEM_COUNCIL_DIR` (`docs/council`) y `TANDEM_COUNCIL_LOCK_TIMEOUT` (segundos de espera del lock del run, 30). Definidas y vacías son error de uso (64), nunca «sin definir». El rol `council` solo existe en exec: con `TANDEM_TRANSPORT=mcp` responde 64.

## Modo imagen — assets generados por Codex

`/tandem:image` genera assets de imagen (iconos, sprites, ilustraciones, mockups) con la herramienta nativa de generación de Codex (gpt-image-2) y los guarda en rutas exactas del repo. El asiento lo lleva Sol `high` deliberadamente — los píxeles los pone gpt-image-2 en cualquier caso, pero el modelo de texto escribe el prompt de imagen real y dirige el flujo, y entender bien el brief es lo que sube la tasa de one-shot. Un hilo por asset (misma clave = refinamientos con memoria completa del render anterior) y gate visual de Fable: abre cada PNG producido con Read y lo juzga contra el brief antes de darlo por bueno — la descripción que Codex haga de su propia imagen nunca cuenta como prueba.

**Transparencia (chroma-key):** gpt-image-2 no emite fondos transparentes; cuando el caso de uso lo pide (sprites de videojuego, logos, assets sobre fondos variables) el brief activa el workaround — render sobre fondo plano `#00ff00` (o `#ff00ff` si el sujeto contiene verde) y `scripts/chroma-strip.sh` convierte el color clave en canal alfa. Con python3+Pillow aplica rampa de alfa graduada + despill de bordes (bordes de sprite limpios); sin Pillow degrada a ImageMagick (`-fuzz`/`-transparent`, alfa binario); sin ningún backend, `IMAGE_BLOCKED` honesto — `/tandem:doctor` informa el backend detectado y qué instalar. `chroma-strip.sh --check` verifica que el resultado tiene alfa real y la skill lo ejecuta como parte del gate.

<img src="assets/test-sprite/slime.png" width="128" height="128" alt="Sprite de slime morado en pixel art con fondo transparente, generado por /tandem:image">

*Ejemplo real: sprite 128×128 generado en un turno por `/tandem:image sprite-test` (Sol `high` + gpt-image-2, `transparency: yes`, recorte con `chroma-strip.sh`) — [assets/test-sprite/slime.png](assets/test-sprite/slime.png).*

Invariantes del modo: sandbox `workspace-write` fijado; los turnos de imagen solo AÑADEN ficheros (snapshot previo de `git status --porcelain` que audita cada escritura — nada existente se modifica, y sin rama dedicada porque no hay diff de código); nunca commit — el asset queda en el árbol y decides tú. Ojo con la cuota: los turnos de imagen consumen el plan de ChatGPT 3–5× más rápido que los de texto (resolución estable hasta 2K); para lotes o CI define `OPENAI_API_KEY` y Codex pasa a facturación por API.

## Invariantes de seguridad

- El revisor nunca escribe. El implementador Opus recibe una única ruta de trabajo y una allowlist mínima; Bash sin sandbox OS queda como riesgo residual explícito. El implementador Sol no sale de `workspace-write`.
- Todo implement fresco publica un guard y un censo de escrituras; el hook anti-install permanece armado hasta `close`/reset y la auditoría deny-list debe salir limpia antes del testing gate.
- El sandbox Codex se re-fija en **cada** turno, arranque y reanudación (`codex exec --sandbox …` + `-c sandbox_mode=…`), y el `config.toml` del usuario ni siquiera se carga (`--ignore-user-config` + `--ignore-rules`): ningún turno hereda red de comandos, raíces escribibles extra, auto-aprobaciones, servidores MCP ni execpolicies del entorno.
- En repos confidenciales, `TANDEM_WEB_SEARCH=off` cierra también en los asientos read-only el canal de la herramienta de búsqueda nativa, que no está gobernado por `network_access`.
- Árbol git limpio obligatorio antes de delegar escritura en un intento fresco; reanudar un intento coincidente (identidad validada contra el estado durable) llega legítimamente con su propio trabajo sin commitear. Rama dedicada siempre; worktree opcional.
- Thread IDs Codex persistidos en `.tandem/state/`; los intentos Opus reflejan identidad, agente, rondas, sentinel e informes en `.tandem/state/implement-claude/`. Ambos sobreviven a compactaciones de la sesión de Claude.
- Loops acotados con el deadlock como resultado legítimo: los desacuerdos se muestran, no se maquillan.
- El implementador jamás hace commit; Fable solo commitea tras la aprobación humana del diff (en modo autonomous, tras review `APPROVED` + testing gate en verde — siempre en la rama tandem, nunca push ni merge).
- Errores de Codex visibles (stderr capturado por turno, exit codes verificados, detección del fallback silencioso de `resume`); informes y sentinels Opus persistidos por turno.

## Estado y artefactos

- `docs/plans/<slug>.plan.md` — planes (versionados).
- `docs/reviews/<slug>.md` — registro final del review (versionado, opcional — ver `TANDEM_PROMOTE_REVIEWS`).
- `docs/BACKLOG.md` — backlog trazable de mejoras (auditoría 2026-07-30): hallazgo → plan → estado.
- `.tandem/` — estado por proyecto, auto-gitignorado y por-feature (clave = target + checksum; una feature nueva nunca pisa el estado de otra): hilos, y prompt/respuesta/eventos POR TURNO (`state/…tN.*`), log append-only del debate (`log/`).
- `.tandem/state/implement-claude/<slug>.json` + `<slug>.t<N>.report.md` — espejo durable del intento Opus; `plan_hash` es el blob commiteado, no la working copy que cambia al marcar checkboxes.
- `.tandem/state/implement-audit/<slug>.census` + `<slug>.guard` — línea de partida mecánica y marcador fail-closed de vida del intento; el censo sobrevive al handoff y el guard no.
- `.tandem/state/<rol>/<clave>.t<N>.ok` — recibo de éxito de cada turno Codex (`{turn, thread_id, reply_sha256}`), escrito solo cuando el turno pasó todas las comprobaciones del wrapper; `codex-reset.sh` lo borra con el resto.
- `docs/council/<run-id>/` — brief, prompts, respuestas publicadas, síntesis, registro, informe y metadatos de un consejo (versionable; nada se commitea solo). `.tandem/state/council/runs/<run-id>/run.json` es su estado de máquina: letras, sellos, intentos, turnos de Astra, capturas de Fable, procedencia y anomalías.
- `.tandem/state/current.json` — heartbeat de la status line (rol, modelo, effort, sandbox, turno, pid, estado, veredicto, y `tokens_in`/`tokens_out` del turno — null mientras `running`, poblados al cerrar; la status line los muestra humanizados, `1.2k→56`). Artefacto de presentación: se escribe de forma atómica y su fallo nunca aborta un turno.

## Tests

```sh
bash tests/run.sh                   # la suite completa (~44 casos, < 1 min)
bash tests/run.sh statusline        # filtra por subcadena del nombre del caso
bash tests/verify.sh                # PROOF: suite + shellcheck + actionlint pineados
```

`tests/run.sh` no necesita red, login ni un `codex` real: un stub del binario en
`tests/stub/codex` emite NDJSON realista y respeta los exit codes, y cada caso corre en su
propio sandbox bajo `env -i` con allowlist explícita (el `HOME`, el `CLAUDE_CONFIG_DIR` y un
`codex` de verdad de tu máquina son estructuralmente inalcanzables). Los sandboxes de los
casos en rojo se conservan para el post-mortem; los verdes se borran.

`node` es una dependencia **solo de los tests**: el runner lo enlaza en cada sandbox si lo
encuentra, para el caso `council-report-js`, que pasa `node --check` a los dos bloques de
JavaScript del informe HTML del consejo y ejecuta su bloque de funciones puras en `node:vm`.
Sin `node` ese caso falla nombrándolo (una capa que no puede correr es un fallo, nunca un
salto silencioso) y el resto de la suite ni lo ve. El plugin en uso no lo necesita.

En macOS los scripts se prueban contra el bash 3.2 del sistema, que es lo que corre el CI.
Si tu `bash` por defecto es el 5 de Homebrew el self-check del runner te lo dirá; replica el
CI con:

```sh
TESTS_BASH=/bin/bash bash tests/run.sh
```

`tests/verify.sh` es el punto de entrada único de verificación (el mismo que llama el CI):
ejecuta la suite y después `shellcheck` y `actionlint` con binarios **pineados por
checksum** que se auto-provisionan en `tests/.tools/` (gitignorado). Una capa que no puede
correr es un fallo explícito que se nombra a sí mismo, nunca un skip silencioso;
`TANDEM_VERIFY_OFFLINE=1 bash tests/verify.sh` es la única degradación permitida (solo
suite) y avisa a gritos de que no es la puerta completa. La primera ejecución necesita red
para descargar los binarios; después quedan cacheados. Los sha256 viven en
`tests/checksums.txt` y se rellenan una vez con `bash tests/verify.sh --record-checksums`.

CI (`.github/workflows/tests.yml`): `lint` (bloqueante, llama a `verify.sh`), `test`
(matriz `ubuntu-latest` + `macos-latest` con preflight de bash y subida de los sandboxes
rojos como artifact) y `codex-smoke` (semanal y manual, no bloqueante, nunca en PR: corre
los wrappers reales contra la CLI pineada y contra `@latest`, y pasa
`tests/fixtures/ndjson/check-drift.sh` para vigilar el drift entre el stub y la CLI real).

## Arquitectura y roadmap

Esquema completo, decisiones y la migración prevista a Codex MCP en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Créditos

Diseño inspirado en los patrones de [grill-me-codex](https://github.com/chaseai-yt/grill-me-codex) (MIT) — entrevista, veredicto de última línea, gates humanos, deadlock honesto — y en el reparto de roles de [TRIP-workflow](https://github.com/PiLastDigit/TRIP-workflow) (Sol revisa / Luna implementa, hilos por target, anti-nitpick). Todo el código y los prompts de este repo son implementaciones originales. Licencia MIT.
