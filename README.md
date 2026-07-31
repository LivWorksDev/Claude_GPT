# tandem — Fable orquesta, Opus implementa, Sol ataca

Plugin de Claude Code que convierte a **Claude (Fable 5)** en orquestador y árbitro, a **Claude Opus 5** en implementador por defecto y a **OpenAI Codex** (GPT-5.6 Sol) en red-team y revisor adversarial independiente, todo desde una sesión normal de Claude Code:

```
Fable planifica → Sol ataca el plan (read-only, hilo persistente)
    → gate humano → Opus 5 implementa (subagente restringido, rama dedicada)
    → Fable lee el diff completo y ejecuta el testing gate
    → un Sol NUEVO revisa el código (sin contexto previo)
    → gate humano → Fable hace el commit (el implementador nunca commitea)
```

> [!IMPORTANT]
> El implementador por defecto ahora es Opus 5. Para conservar el transporte anterior de implementación con Codex CLI, define `TANDEM_IMPLEMENTER=sol`. Sol sigue siendo el red-team del plan y el revisor final independiente en ambos casos.

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

Verifica el toolchain con `/tandem:doctor`.

## Skills

| Skill | Qué hace |
| --- | --- |
| `/tandem:run` | Pipeline completo: plan → red-team → implementación → verificación → review → commit |
| `/tandem:plan` | Entrevista + plan + revisión adversarial de Sol hasta APPROVED (cap de rondas) |
| `/tandem:implement` | Opus 5 implementa por defecto (`TANDEM_IMPLEMENTER=sol` usa Codex CLI); Fable verifica el diff y ejecuta el testing gate |
| `/tandem:review` | Code review final por un hilo Sol nuevo e independiente |
| `/tandem:ask` | Segunda opinión de Sol sobre cualquier tema, con follow-ups en el mismo hilo |
| `/tandem:image` | Genera assets de imagen con la herramienta nativa de Codex (gpt-image-2), con transparencia por chroma-key para sprites |
| `/tandem:ultra` | Enjambres multi-agente estilo ultracode dirigidos por Fable, con todos los asientos en Codex (read-only) |
| `/tandem:doctor` | Diagnóstico del toolchain (codex, login, jq, política de modelos, status line) |
| `/tandem:statusline` | Instala/desinstala la status line (modelo, contexto, coste + puerta Codex en vivo) |

## Status line

Debajo del prompt puedes ver a la vez la sesión de Claude y lo que está haciendo Codex:

```
◈ Fable 5 xhigh✳ · ctx 34% ▓▓▓░░░░░░░ · $0.42 · mi-proyecto ⑂ tandem/auth-refactor
⚙ codex gpt-5.6-sol · implement high · t3 · workspace-write · exec pytest -q · 1m42s · auth-refactor
```

Cuando la ocupa un turno de Codex — en vuelo o recién terminado (15 min) — la segunda línea narra en vivo la actividad real (`exec …`, `edit …`, `thinking…`) leída del stream de eventos, y al acabar colorea el desenlace — verde `APPROVED`/`IMPLEMENTATION_COMPLETE`, ámbar `REVISE`, rojo `REQUEST_CHANGES` o fallo, gris si el proceso murió sin dejar rastro. Funciona también con `TANDEM_WORKTREE`: el heartbeat se escribe siempre en el checkout principal (resuelto vía `git rev-parse --git-common-dir`).

Durante una implementación Opus esa línea la ocupa el intento, leído del estado durable `.tandem/state/implement-claude/<slug>.json`: `⚒ opus implement · running · <slug>` en ámbar mientras trabaja, el sentinel coloreado durante 15 min al cerrar (`IMPLEMENTATION_COMPLETE` verde, `IMPLEMENTATION_PARTIAL` ámbar) y `⚠ sin señal` en gris si un `running` lleva más de 2 h sin cerrarse. Es presencia y desenlace, no actividad en vivo — el fichero solo se escribe al lanzar y al cerrar, así que narrar más sería inventarlo (queda para v2) y Claude Code ya muestra el progreso del subagente de forma nativa. Un turno de Codex vivo tiene prioridad absoluta sobre la fila; entre estados no vivos gana el más reciente, para que la review que acaba de terminar no tape la implementación que acaba de empezar.

Además, los turnos lanzados en background narran su progreso en el panel **Shell details** de Claude Code — cada comando que Codex ejecuta (`» exec …` → `✓ ok`/`✗ exit N`), cada fichero que toca (`» edit …`) y los tokens del turno, en tiempo real.

**Instalación: `/tandem:statusline`** (o `bash scripts/statusline-install.sh`). Claude Code no permite que un plugin aporte la status line principal (el `settings.json` de un plugin solo admite `agent` y `subagentStatusLine`), así que la skill la instala con tu consentimiento: escribe un shim en `~/.claude/tandem-statusline.sh` que re-resuelve el `statusline.sh` del plugin en cada render — sobrevive a las actualizaciones del plugin (cuya ruta de caché cambia por versión) y degrada a una línea mínima si tandem desaparece — y añade la entrada `statusLine` a tu `settings.json` (escritura atómica, backup en `settings.json.tandem-backup`, y nunca pisa una statusLine ajena sin `--force`). `refreshInterval: 2` mantiene vivo el cronómetro mientras un `codex exec` bloquea. `/tandem:statusline uninstall` lo deshace; `/tandem:doctor` comprueba si está instalada.

## Política de modelos y permisos

| Rol | Modelo (default) | Effort | Frontera de ejecución |
| --- | --- | --- | --- |
| Revisor / consultor | `gpt-5.6-sol` | `xhigh` | `read-only` (fijado, no sobreescribible) |
| Implementador (default) | Claude Opus 5 | No expuesto por Agent | Allowlist harness `Read, Edit, Write, Glob, Grep, Bash`; sin MCP/web/Agent anidado |
| Implementador (`TANDEM_IMPLEMENTER=sol`) | `gpt-5.6-sol` | `high` | Sandbox OS `workspace-write` (fijado, no sobreescribible) |
| Implementador Sol crítico (`TANDEM_CRITICAL=1`) | `gpt-5.6-sol` | `xhigh` | Sandbox OS `workspace-write` |
| Generador de imágenes | `gpt-5.6-sol` | `high` | `workspace-write` (fijado, no sobreescribible) |

Política forzada en **todos** los turnos Codex (start, resume y asientos de enjambre), con el argv congelado byte a byte por la suite:

| Frontera | Cómo se fuerza | Alcance |
| --- | --- | --- |
| Config del usuario | `--ignore-user-config` + `--ignore-rules` | Todos: ni `config.toml` ni execpolicies `.rules` llegan al turno (el login sigue funcionando) |
| Sandbox | `--sandbox <modo>` + `-c sandbox_mode=<modo>` | Todos |
| Red de comandos | `-c sandbox_workspace_write.network_access=false` | Todos |
| Raíces escribibles | `-c sandbox_workspace_write.writable_roots=[]` | Todos (los roots del config se AÑADEN a la primaria: sin el pin, el checkout principal seguiría escribible) |
| Aprobaciones | `-c approval_policy=never -c approvals_reviewer=user` | Todos: un turno headless nunca auto-aprueba un escape de sandbox |
| Búsqueda web nativa | `-c web_search=disabled` | Solo roles de **escritura** (`implement`, `image`), donde el prompt promete que no hay red. `review`/`ask`/`ultra` la conservan: no pueden escribir y el default deja de depender del config del usuario |
| Temp roots (`/tmp`, `$TMPDIR`) | sin pin, a propósito | Escribibles: las herramientas los necesitan y no son el árbol del proyecto |

`scripts/config-probe.sh` vigila que ninguna de esas claves se haya renombrado en silencio (la CLI acepta una clave desconocida con rc 0), y el smoke semanal lo ejecuta contra la CLI pineada y `@latest`.

La frontera Opus es una allowlist aplicada por Claude Code: elimina herramientas MCP, conectores, web y subagentes anidados, pero Bash no equivale a un sandbox OS y podría ejecutar comandos fuera de esa lista si la sesión los permite. El agent type y el prompt prohíben commits, pushes, cambios de rama/remotos y trabajo fuera de la ruta indicada; Fable comprueba después rama, `HEAD`, remotos y diff. El transporte Sol conserva el sandbox OS existente. `CLAUDE_CODE_SUBAGENT_MODEL`, si está definida, debe valer exactamente `opus` o el preflight para; el modelo auto-reportado por el subagente es informativo, no una verificación runtime robusta.

Por encima de `xhigh` existen `max` y `ultra`; para una revisión final especialmente delicada puedes usar `TANDEM_REVIEW_EFFORT=ultra` puntualmente.

Overrides por entorno: `TANDEM_IMPLEMENTER` (`opus` default / `sol`; cualquier otro valor falla), `TANDEM_REVIEW_MODEL`, `TANDEM_REVIEW_EFFORT`, `TANDEM_IMPLEMENT_MODEL`, `TANDEM_IMPLEMENT_EFFORT` (estos dos últimos solo afectan al transporte Sol), `TANDEM_IMAGE_MODEL`, `TANDEM_IMAGE_EFFORT`, `TANDEM_PLAN_ROUNDS`, `TANDEM_CR_ROUNDS`, `TANDEM_IMPL_ROUNDS`, `TANDEM_WORKTREE` (**plan-approval + implement/review**: desde 0.12 decide también dónde aterriza el commit de aprobación del plan — checkout principal o `.worktrees/<slug>` — y debe llevar el mismo valor en todas las fases de un run; `ask` e `image` nunca se anclan a un worktree), `TANDEM_CODEX_CWD` (raíz de trabajo del turno; se reenvía literal como `codex exec --cd` y debe nombrar un directorio existente — vacío o inexistente falla con 64. Las skills la resuelven con `scripts/worktree-root.sh <slug>`, que falla cerrado en vez de caer al checkout principal), `TANDEM_AUTONOMOUS`, `TANDEM_PROMOTE_REVIEWS` (`1` siempre / `0` nunca / sin definir: se ofrece en el gate), y para los enjambres `TANDEM_ULTRA_{JUDGE,WORKER,SCOUT}_MODEL`/`_EFFORT` y `TANDEM_ULTRA_CONCURRENCY`. Los sandboxes Codex no se pueden sobreescribir y `danger-full-access`/`--yolo` no se usan nunca.

## Modo autonomous

`TANDEM_AUTONOMOUS=1` permite un `/tandem:run` de principio a fin sin interacción: el HITL se mueve a los bordes — un **brief completo** a la entrada (si no da para goal + aceptación sin inventar, el run ni empieza) y la revisión humana de la **rama commiteada** a la salida. Cada gate humano se convierte en política verificable:

| Gate | Política |
| --- | --- |
| Aprobación del plan | Solo `VERDICT: APPROVED` de Sol; se commitea el plan y se continúa |
| Gate final + commit | Solo review `APPROVED` **y** testing gate en verde; commit en `tandem/<slug>` |
| Preguntas de la entrevista | Sección **Assumptions** en el plan: decisión → default conservador → por qué (auditable) |
| `TANDEM_PROMOTE_REVIEWS` | Obligatorio definirlo (0/1) — se valida en el preflight, nada pregunta a mitad de run |

Estados terminales, siempre con informe final (assumptions, veredictos por ronda, diffstat, gate, rama, log): `COMPLETED` · `DEADLOCK` (ningún APPROVED — jamás se aprueba por agotamiento) · `PARTIAL` (implementación incompleta tras los caps) · `FAILED`. Cualquier estado no-COMPLETED se retoma con las skills interactivas normales.

Líneas rojas idénticas al modo interactivo: nunca push, nunca merge, nunca la rama por defecto; sandboxes, modelos y caps intactos. La autonomía recoloca los puntos de aprobación — no compra permisos. Ojo: los permission prompts de la propia sesión de Claude Code son una capa aparte que tandem ni puede ni debe tocar; para un run realmente desatendido configura los permisos de la sesión en consecuencia.

## Modo ultra — enjambres dirigidos por Fable

`/tandem:ultra` lanza workflows multi-agente estilo ultracode (reviews adversariales multi-dimensión, paneles de jueces, cazas de bugs, barridos de investigación) donde **todos los asientos que razonan son Codex**: donde un workflow nativo sentaría a Fable va Sol `xhigh` (tier `judge`), donde iría Opus va Sol `high` (`worker`) y donde iría Haiku va Luna `high` (`scout`). Los agentes Claude del workflow son solo envoltorios `haiku` que lanzan cada turno vía `scripts/codex-swarm.sh` y estructuran la respuesta.

La skill empieza siempre con una deliberación dirigida por Fable — si el enjambre compensa, qué forma tiene y cuántos turnos costará — y no lanza nada sin tu aprobación (en autonomous, sin un brief que lo determine todo). Invariantes propias del modo: cada seat es un hilo fresco e independiente, `read-only` fijado y sin resume; el enjambre nunca escribe ni commitea — sus hallazgos alimentan el pipeline normal, nunca sustituyen el gate de `tandem:review`; concurrencia acotada por `TANDEM_ULTRA_CONCURRENCY` (default 4). El estado va a `.tandem/state/ultra/<run>/` y el informe del run a `.tandem/log/ultra-<run>.md`. Si la sesión no dispone del tool Workflow, la skill degrada al fan-out con `Agent` o a turnos secuenciales en background — mismos scripts, mismos prompts.

## Modo imagen — assets generados por Codex

`/tandem:image` genera assets de imagen (iconos, sprites, ilustraciones, mockups) con la herramienta nativa de generación de Codex (gpt-image-2) y los guarda en rutas exactas del repo. El asiento lo lleva Sol `high` deliberadamente — los píxeles los pone gpt-image-2 en cualquier caso, pero el modelo de texto escribe el prompt de imagen real y dirige el flujo, y entender bien el brief es lo que sube la tasa de one-shot. Un hilo por asset (misma clave = refinamientos con memoria completa del render anterior) y gate visual de Fable: abre cada PNG producido con Read y lo juzga contra el brief antes de darlo por bueno — la descripción que Codex haga de su propia imagen nunca cuenta como prueba.

**Transparencia (chroma-key):** gpt-image-2 no emite fondos transparentes; cuando el caso de uso lo pide (sprites de videojuego, logos, assets sobre fondos variables) el brief activa el workaround — render sobre fondo plano `#00ff00` (o `#ff00ff` si el sujeto contiene verde) y `scripts/chroma-strip.sh` convierte el color clave en canal alfa. Con python3+Pillow aplica rampa de alfa graduada + despill de bordes (bordes de sprite limpios); sin Pillow degrada a ImageMagick (`-fuzz`/`-transparent`, alfa binario); sin ningún backend, `IMAGE_BLOCKED` honesto — `/tandem:doctor` informa el backend detectado y qué instalar. `chroma-strip.sh --check` verifica que el resultado tiene alfa real y la skill lo ejecuta como parte del gate.

<img src="assets/test-sprite/slime.png" width="128" height="128" alt="Sprite de slime morado en pixel art con fondo transparente, generado por /tandem:image">

*Ejemplo real: sprite 128×128 generado en un turno por `/tandem:image sprite-test` (Sol `high` + gpt-image-2, `transparency: yes`, recorte con `chroma-strip.sh`) — [assets/test-sprite/slime.png](assets/test-sprite/slime.png).*

Invariantes del modo: sandbox `workspace-write` fijado; los turnos de imagen solo AÑADEN ficheros (snapshot previo de `git status --porcelain` que audita cada escritura — nada existente se modifica, y sin rama dedicada porque no hay diff de código); nunca commit — el asset queda en el árbol y decides tú. Ojo con la cuota: los turnos de imagen consumen el plan de ChatGPT 3–5× más rápido que los de texto (resolución estable hasta 2K); para lotes o CI define `OPENAI_API_KEY` y Codex pasa a facturación por API.

## Invariantes de seguridad

- El revisor nunca escribe. El implementador Opus recibe una única ruta de trabajo y una allowlist mínima; Bash sin sandbox OS queda como riesgo residual explícito. El implementador Sol no sale de `workspace-write`.
- El sandbox Codex se re-fija en **cada** turno, arranque y reanudación (`codex exec --sandbox …` + `-c sandbox_mode=…`), y el `config.toml` del usuario ni siquiera se carga (`--ignore-user-config` + `--ignore-rules`): ningún turno hereda red de comandos, raíces escribibles extra, auto-aprobaciones, servidores MCP ni execpolicies del entorno.
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
