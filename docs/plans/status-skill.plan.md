# Plan: status-skill — nueva skill de solo lectura /tandem:status

**Backlog:** M11 (P2/M) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola 2 de `.tandem/autonomous/queue.md`, tarea 1/4)


## Goal

Todo el estado de un run tandem ya existe en disco — hilos y turnos por rol bajo `.tandem/state/<role>/` (`scripts/codex-start.sh:57-59,133-136`), el registro de aprobación `.tandem/state/plan-approve/<slug>.json` (`scripts/plan-approve.sh:84-87,155-158`), el intento Opus `.tandem/state/implement-claude/<slug>.json` (`skills/implement/SKILL.md:112-135`), los ledgers `*.t<N>.usage.json`/`*.t<N>.meta.json` (`scripts/codex-start.sh:72-80,111-119`) y el log `.tandem/log/<slug>.md` — pero ninguna skill lo expone: tras una compactación o al retomar un run PARTIAL/DEADLOCK hay que saberse `codex-show.sh` y los ficheros de memoria (`docs/BACKLOG.md:205-218`). Objetivo: un script testeable `scripts/tandem-status.sh` (precedente `plan-approve.sh`: el parseo de estado es comportamiento, no prosa) envuelto por una nueva skill `skills/status/SKILL.md`, que por slug pinta en un vistazo fase alcanzada, veredictos y rondas por fase, rama, gate de testing, intento Opus y tokens agregados, y sugiere cómo se retoma — **sin llamar jamás a Codex**. Estado ausente o corrupto degrada a `desconocido` explícito, nunca a error; sin slug, lista los runs conocidos.

## Approach

1. **`scripts/tandem-status.sh` (nuevo) — el parser de estado, toda la lógica testeable.**
   - **Cabecera y modo de fallo:** `set -uo pipefail` SIN `-e`; sourcea `scripts/_common.sh` para reutilizar `target_key` (`scripts/_common.sh:330-337` — el checksum `cksum` no es reconstruible a mano) y `hb_verdict` (`scripts/_common.sh:319-324` — la única regex de sentinels del repo), y ejecuta `set +e` inmediatamente después (el `set -euo pipefail` de `_common.sh:5` mataría la degradación; `_pins.sh` no tiene efectos por contrato, `_common.sh:91-94`). jq y git son dependencias BLANDAS como en `statusline.sh:34`: su ausencia degrada campos concretos a `desconocido`, nunca aborta (contraste deliberado con el exit 3 de `need_jq` en los wrappers que gastan cuota, `tests/no-jq-degradation.test.sh:25-34`).
   - **Anclaje de estado — resolución de raíz DOBLE, como la statusline (`scripts/statusline.sh:119`):** candidatos en orden `CLAUDE_PROJECT_DIR`, `PWD`, y el checkout principal vía `git rev-parse --git-common-dir`; en modo SLUG gana la primera raíz con evidencia DE ESE SLUG concretamente (una evidencia ajena — un run viejo en el `.tandem/` del worktree — no puede enmascarar al slug pedido que vive bajo el principal); en modo LISTADO se hace la UNIÓN deduplicada de runs de TODAS las raíces candidatas (no la primera con algo). Fixtures: evidencia ajena en el worktree + evidencia del slug bajo el principal. `${CLAUDE_PROJECT_DIR:-$MAIN}` a secas daría precedencia al entorno: con `CLAUDE_PROJECT_DIR` apuntando a un worktree enlazado, el estado del principal sería invisible y un run válido se reportaría inexistente. Sin git o fuera de repo, `${CLAUDE_PROJECT_DIR:-$PWD}/.tandem`. Test con sesión-en-worktree (`CLAUDE_PROJECT_DIR` al worktree, estado bajo el principal).
   - **Validación del slug:** mismo charset que `plan-approve.sh:58-61` (`[A-Za-z0-9._-]`, sin `-`/`.` inicial) → exit 64 con `usage:`. Sin argumentos → modo listado (abajo).
   - **Claves de estado por fase** — reconstruidas con los MISMOS labels literales que usan las skills: plan-review = rol `review`, target `docs/plans/<slug>.plan.md` (`skills/plan/SKILL.md:38`); code-review = rol `review`, target `cr-<slug>` (`skills/review/SKILL.md:12,50`); implement Sol = rol `implement`, target `docs/plans/<slug>.plan.md` (`skills/implement/SKILL.md:158`). De cada clave: `<key>.thread` (existencia), `<key>.turn` (rondas; saneado `case … *[!0-9]*` como `codex-start.sh:53-54`, corrupto → `?`), y veredicto por ronda pasando cada `<key>.t<N>.reply.txt` en orden por `hb_verdict` (ausente → `—`).
   - **Hechos por sección del informe** (formato `clave:  valor` alineado, como `codex-show.sh:27-28` y `summary()` de `plan-approve.sh:248-257`; stdout es el informe, stderr solo para exit 2/64):
     - `slug:` y `plan:` — working copy `docs/plans/<slug>.plan.md`, y/o registro de aprobación leído con el MISMO `json_str` sed de `plan-approve.sh:143-146` (formato de una clave por línea garantizado por `write_state`, `plan-approve.sh:155-158`, sin jq): `plan_commit` corto, `mode`, más `<slug>.json.pending` presente → `aprobación interrumpida (pending)`.
     - `rama:` — `git show-ref --verify refs/heads/tandem/<slug>`; si existe, tip corto y `N commit(s) sobre el plan` vía `git rev-list --count <plan_commit>..refs/heads/tandem/<slug>` (solo si hay `plan_commit` verificable; si no, `desconocido`); registro de worktree con el mismo scan porcelain de `plan-approve.sh:119-134`. Sin git → `desconocido (sin git)`.
     - `plan-review:` / `code-review:` — `N rondas · veredictos: V1, V2, …` o `sin hilo`.
     - `implement:` — el JSON Opus se parsea con jq con la MISMA desconfianza tipada que `statusline.sh:250-266` (status string, `last_sentinel` string|null; si no valida → `desconocido (estado corrupto)`, nunca exit): `opus · <status> · <last_sentinel|—> · continuaciones: <continuation_rounds>`; semántica de `status: running` = "el sentinel describe un turno ANTERIOR" (`skills/implement/SKILL.md:135`) reflejada en el texto. Sin JSON pero con hilo implement Sol → `sol · t<N> · <último veredicto/sentinel>`. Nada → `sin intento`. Sin jq → los campos del JSON degradan a `desconocido (sin jq)`.
     - `gate:` — el ÚLTIMO bloque lógico `gate — ` del log, incluyendo sus líneas de continuación (los logs reales lo parten en varias líneas físicas — evidencia: `.tandem/log/review-background.md:71`): se lee desde la línea que empieza por `gate — ` hasta la primera línea en blanco o heading, y se normaliza a una línea para el informe. `sin registro` si no hay bloque. Fixture con gate multi-línea en los tests.
     - `tokens:` — suma por fase de los ledgers `state/<role>/<key>.t*.usage.json` (bucle `for` con `[ -f ]` — glob sin match en bash 3.2 — y `jq -s` sobre `input_tokens`/`output_tokens`, mismo criterio numérico que `usage_number`, `scripts/_common.sh:168-172`; un fichero corrupto se salta y se anota `(+1 ilegible)`): `plan in X · out Y | cr in X · out Y | implement in X · out Y (o «n/a (transporte opus)» si hay JSON Opus y no hay hilo Sol, `skills/implement/SKILL.md:172`) | total in Σ · out Σ`. Sin jq → `desconocido (sin jq)`.
     - `log:` — ruta y `wc -l`, o `ausente`.
     - `fase:` — escalera de evidencia, la MÁS avanzada gana: `commit final` SOLO con el
       REGISTRO TERMINAL del run — la línea machine-parseable `final — commit: <sha>` que
       el Step 4 de review pasa a escribir en el log tras el commit aprobado (ver punto
       nuevo 2b) — con el sha validado contra git en DOS pasos: existe como commit Y desciende de
       `plan_commit` (`git merge-base --is-ancestor <plan_commit> <sha>` — un sha válido
       pero ajeno al run, p.ej. `source_head` o el commit de otro run, NO verifica), y
       cuando la rama tandem aún existe, su tip debe ser EXACTAMENTE el sha registrado —
       un tip descendiente significa commits añadidos DESPUÉS del gate final, y bendecirlo
       con `run completo — merge/PR` mergearía código sin revisar: eso es
       `contradictorio — rama avanzó tras registro final`, con aviso de revisión manual. Sin git,
       sin `plan_commit` verificable, o sha no descendiente → `commit final (no
       verificado)` y el `next:` recomienda verificación manual (`git log`) en vez de
       `run completo — merge/PR` — "run completo" queda RESERVADO al registro verificado. Una rama con >0
       commits sobre `plan_commit` SIN registro terminal es **`contradictorio — commits
       sin registro final`** (nunca `commit final`): el flujo trata un commit del
       implementador como fallo duro de seguridad (`skills/implement/SKILL.md:205`), y el
       status no puede bendecirlo. El registro en el log además SOBREVIVE al borrado de la
       rama tandem tras el merge (el estado real de este repo hoy: cero refs tandem/ y
       runs completados) — la rama deja de ser evidencia necesaria. Escalera restante:
       `code review` (hilo `cr-<slug>`) → `gate de testing` (bloque gate) →
       `implementación` (JSON Opus o hilo Sol) → `plan aprobado` (registro plan-approve) →
       `plan en revisión` (hilo plan-review) → `plan (borrador)` (solo working copy).
       Evidencia contradictoria no bloquea: cada sección muestra su propio `desconocido`.
     - `next:` — sugerencia determinista derivada de la fase (testeable): en revisión sin APPROVED → `/tandem:plan` (retomar el hilo); **plan-review APPROVED pero SIN registro de aprobación → `/tandem:plan (Resolution: aprobar con plan-approve.sh)` — la pausa natural del gate humano del plan**; aprobado sin intento → `/tandem:implement <slug>`; implement running → `verificar el intento vivo antes de nada (tandem:implement paso 1, guard de liveness)`; PARTIAL/sin sentinel → `/tandem:implement <slug> (continuación)`; COMPLETE sin gate → `gate de testing (tandem:implement paso 4)`; gate sin cr → `/tandem:review <slug>`; cr sin APPROVED → `/tandem:review <slug> (retomar)`; **cr APPROVED pero SIN registro terminal → `/tandem:review <slug> (Step 4: gate final y commit)` — la segunda pausa del gate humano**; commits sin registro final → `ATENCIÓN: commits no registrados — verificar el safety check de implement antes de nada`; commit final → `run completo — merge/PR manual`. La skill narra encima, pero el hecho lo imprime el script.
   - **Exit codes:** 0 = informe emitido (aunque todo sea desconocido parcial); 2 = slug sin NINGUNA evidencia (ni log, ni estado, ni plan, ni rama) — mensaje en stderr + lista de runs conocidos (paralelo al exit 2 «no thread» de `codex-show.sh:22-25`); 64 = uso. Jamás 1/3: no hay dependencia dura ni llamada a codex.
   - **Modo listado (sin slug), exit 0:** unión deduplicada de slugs desde `.tandem/log/*.md` (menos `ultra-*` — namespace de `skills/ultra`, README:116; el log se inicializa en el Act 1 de plan, `skills/plan/SKILL.md:29`, así que cubre todo run que arrancó), `state/plan-approve/*.json` (menos `*.pending`), `state/implement-claude/*.json` (menos `*.t*.report.md`) y `git for-each-ref refs/heads/tandem/*`; una línea `slug — fase` por run (la escalera es barata), o `(ningún run conocido)`.
2. **`skills/status/SKILL.md` (nueva)** — envoltorio fino, patrón `skills/doctor/SKILL.md:8-14`: frontmatter (name `status`, description con triggers «dónde está este run / cómo se retoma / tras compactación», argument-hint `[slug]`), un único comando `bash "${CLAUDE_SKILL_DIR}/../../scripts/tandem-status.sh" [slug]`, y guía de interpretación: qué significa cada `desconocido`, que exit 2 lista los runs, que la skill es SOLO lectura y **nunca lanza `codex-start.sh`/`codex-resume.sh` ni gasta un turno** (frase-ancla para el test de contrato), y que el `next:` se ofrece con la skill correspondiente sin ejecutarla sin confirmación.
2b. **`skills/review/SKILL.md` — registro terminal del run.** El Step 4, inmediatamente
   después del commit de aprobación, escribe en `.tandem/log/<slug>.md` una línea
   machine-parseable `final — commit: <sha completo>` (y la incluye en su resumen). Es el
   único hecho que hoy no persiste de forma parseable — el commit final se conocía solo
   por la rama, que el merge legítimo borra. Edición quirúrgica: las anclas de los cinco
   contratos estáticos existentes sobre ese fichero quedan intactas, y el contrato nuevo
   de status ancla la instrucción.
3. **`skills/run/SKILL.md:51`** — la frase «resumable with the normal interactive skills — the state in `.tandem/` is the same» gana la orientación que le faltaba: «… — `/tandem:status <slug>` shows where the run stands and how to resume it». Solo se añade; las anclas de `skill-token-accounting-contract.test.sh:63-65` sobre ese fichero quedan intactas.
4. **`README.md:40-48`** — nueva fila en la tabla de comandos: `/tandem:status` · «Dónde está un run y cómo se retoma, leyendo `.tandem/` — nunca gasta un turno».
5. **Tests (patrón real de la suite: sandbox `env -i` con allowlist, `tests/run.sh:73-91`; stub de codex en PATH; aserciones exactas de `tests/lib.sh`).** Detalle en «Acceptance & proof». Nuevos: `tests/status-phases.test.sh`, `tests/status-degradation.test.sh`, `tests/status-list.test.sh`, `tests/skill-status-contract.test.sh`. `tests/verify.sh:239,244-246` recoge script y tests en shellcheck automáticamente.
6. **Metadatos — SIEMPRE del orquestador, post-implementación:** `.claude-plugin/plugin.json` → 0.19.0, `CHANGELOG.md`, `docs/BACKLOG.md` (M11 → hecha). No forman parte de esta implementación.

## Key decisions & tradeoffs

- **Script + skill fina, no skill-solo-prosa** (pre-registrado, diseñado así): la escalera de fases, el saneado de `.turn`, la suma de ledgers y la degradación a `desconocido` son comportamiento verificable — en prosa serían un `skill-*-contract` gigante sin suite detrás. Precedente directo: `plan-approve.sh` + gate humano de `skills/plan`.
- **Sourcear `_common.sh` y `set +e` inmediato**, en vez del aislamiento de `statusline.sh` (que no sourcea nada): status necesita `target_key` (checksum no reconstruible sin duplicar el algoritmo — exactamente lo que `tkey` en `tests/lib.sh:186-192` existe para evitar) y `hb_verdict`. Coste: acoplamiento al contrato «sin efectos» de `_pins.sh` (ya declarado en `_common.sh:91-94`).
- **jq y git blandos** (statusline, `statusline.sh:34`) y no duros (wrappers, exit 3): un tool de orientación debe responder también en una máquina rota — es cuando más se necesita. `codex-show.sh` ya funciona sin jq (`tests/no-jq-degradation.test.sh:80-87`).
- **Tokens desde los `*.usage.json`, no desde las líneas `tokens:` del log:** los ledgers los escribe el wrapper incondicionalmente en cada turno, incluso fallido (`codex-start.sh:104-119`); las líneas del log dependen de la disciplina de la skill. Contra: bajo transporte opus no hay ledger — se informa `n/a (transporte opus)` igual que el log (`skills/implement/SKILL.md:172`).
- **Slug totalmente desconocido → exit 2 con lista**, no informe todo-`desconocido`: un typo silenciosamente «desconocido» es peor que un stop honesto; «estado ausente degrada» aplica a estado PARCIAL de un run que existe. Paralelo exacto del exit 2 de `codex-show.sh`.
- **`next:` lo imprime el script** (determinista, testeable) y la skill lo narra: duplica una pizca de conocimiento del pipeline en bash, pero un `next:` solo-prosa sería invisible para la suite.
- **Solo lectura estricta:** el script no escribe NADA — ni `state_init` (que hace mkdir, `_common.sh:103`), ni heartbeat, ni log. Un tool de orientación que mutara el estado que describe rompería su única promesa.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/tandem-status.sh` | Nuevo — parser/reporter de estado, solo lectura, exit 0/2/64 |
| `skills/status/SKILL.md` | Nueva — envoltorio e interpretación; nunca llama a Codex |
| `skills/run/SKILL.md` | Una frase: puntero a `/tandem:status` en la nota de resumibilidad (L51) |
| `README.md` | Fila `/tandem:status` en la tabla de comandos |
| `tests/status-phases.test.sh` | Nuevo — escalera de fases, veredictos, rondas, tokens, `next:` |
| `tests/status-degradation.test.sh` | Nuevo — corrupto/ausente → `desconocido`; sin jq; sin git |
| `tests/status-list.test.sh` | Nuevo — listado sin slug; exit 2 con slug inexistente |
| `tests/skill-status-contract.test.sh` | Nuevo — contrato estático de la skill (nunca codex) |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.19.0 — orquestador, post-implementación |

## Acceptance & proof

- **`tests/status-phases.test.sh`** — un repo real (`make_repo` + `commit_all`, `tests/lib.sh:170-183`) que atraviesa el ciclo de vida y asserta el informe en cada peldaño: (1) solo `docs/plans/demo.plan.md` → `fase:` contiene `plan (borrador)`, `next:` contiene `/tandem:plan`; (2) hilo plan-review sembrado con `seed_thread review docs/plans/demo.plan.md thr1 2` (`tests/lib.sh:208-215`) + `t1.reply.txt` con `VERDICT: REVISE` y `t2.reply.txt` con `VERDICT: APPROVED` → `plan-review:` contiene `2 rondas` y `REVISE, APPROVED`; (3) aprobación con el `plan-approve.sh` REAL (patrón `tests/plan-approve.test.sh:26-35`, `env CLAUDE_PROJECT_DIR=…`) → `fase:` `plan aprobado`, `rama:` `tandem/demo`, `next:` `/tandem:implement demo`; (4) JSON Opus `running` escrito con jq → `implement:` contiene `opus` y `running`; `terminal`+`IMPLEMENTATION_PARTIAL` → `next:` contiene `continuación`; (5) línea `gate — lint: OK …` en el log → `gate:` la reproduce verbatim; (6) hilo `cr-demo` con `VERDICT: APPROVED` + un commit extra en la rama SIN registro terminal → `fase:` `contradictorio — commits sin registro final` (la coherencia con el caso 9 es deliberada: el commit solo se bendice con registro); (6b) se añade la línea `final — commit: <sha del commit extra>` al log → `fase:` `commit final` y `next:` `run completo`. Tokens: sembrar `<key>.t1.usage.json` = `{"input_tokens":100,"output_tokens":10}` y `t2` = `{…:200,…:20}` en plan-review y `{…:50,…:5}` en cr → `assert_file_contains "$OUT" 'plan in 300 · out 30'`, `'cr in 50 · out 5'`, `'total in 350 · out 35'`. Casos de gate humano y registro terminal: (7) plan-review con APPROVED y SIN registro de aprobación → `next:` contiene `plan-approve.sh` (pausa 1); (8) cr APPROVED sin registro terminal → `next:` contiene `Step 4` (pausa 2); (9) commit extra en la rama SIN línea `final — commit:` → `fase:` contiene `contradictorio` y `next:` contiene `ATENCIÓN`; (10) con el registro terminal del caso 6b: se replica el merge legítimo — `git checkout <rama origen>` + `git merge --ff-only tandem/demo` + `git branch -d tandem/demo` (un `-D` directo fallaría: la aprobación in-place deja la rama checked out) — y la fase SIGUE siendo `commit final`; (10c) commit añadido a la rama DESPUÉS del registro terminal → `fase:` `contradictorio — rama avanzó tras registro final` con aviso; (10b) sha válido pero AJENO al run (p.ej. `source_head`) → `commit final (no verificado)` con `next:` de verificación manual, nunca `run completo`; sha inexistente → ídem; sin git → ídem. Gate multi-línea (fixture envuelto en dos líneas físicas) → `gate:` lo reproduce completo normalizado. Cierre obligado: `assert_no_file "$CODEX_STUB_LOG.argv.1"` y `assert_no_file "$CODEX_STUB_LOG.n"` — codex jamás invocado — y **prueba de solo-lectura estricta: snapshot recursivo de `.tandem/` y del repo (listado ordenado + cksum por fichero) ANTES y DESPUÉS de cada invocación de status (modo slug, listado, degradación y exit 2), byte a byte idéntico; en el fixture de solo-plan, `.tandem/` ausente SIGUE ausente** (sourcear `_common.sh` expone `state_init`, que hace mkdir — la aserción caza cualquier llamada accidental).
- **`tests/status-degradation.test.sh`** — con run sembrado: JSON Opus corrupto (`printf 'garbage{'`) → `assert_rc 0`, `implement:` contiene `desconocido`, y `assert_not_contains "$ERR" 'integer expression'` / sin traza bash; `.turn` con basura → rondas `?`; `usage.json` corrupto → esa fase anota `ilegible` y el total suma el resto; sin jq (`make_minbin`, PATH `"$SANDBOX/bin:$MINBIN"`, guard «jq is still reachable», `tests/no-jq-degradation.test.sh:11-17`) → `assert_rc 0`, informe estructural presente, `tokens:` contiene `sin jq`; sin git (minbin con el symlink `git` borrado) → `assert_rc 0`, `rama:` contiene `desconocido`; `.tandem/` ausente por completo pero plan presente → `assert_rc 0`, `plan (borrador)`.
- **`tests/status-list.test.sh`** — sin argumentos y sin estado → `assert_rc 0` + `(ningún run conocido)`; sembrando `log/a.md`, `state/plan-approve/b.json`, `state/implement-claude/c.json`, rama `tandem/d` y `log/ultra-x.md` → exit 0, contiene `a`, `b`, `c`, `d` una vez cada uno y `assert_not_contains "$OUT" ultra-x`; slug inexistente `run bash "$SCRIPTS/tandem-status.sh" nope` → `assert_rc 2` y stderr lista los runs conocidos; slug inválido `../x` → `assert_rc 64`.
- **`tests/skill-status-contract.test.sh`** — patrón flatten (guard anti-truncado incluido): `skills/status/SKILL.md` contiene `tandem-status.sh` y la ancla genérica de solo-lectura («nunca llama a Codex», sin turno); las aserciones NEGATIVAS (`codex-start.sh`, `codex-resume.sh`, `codex-swarm.sh`, `codex exec`) se aplican SOLO a los bloques fenced ejecutables extraídos con el parser de comandos lógicos de los contratos existentes — nunca al fichero completo, que DEBE poder mencionar la política en prosa (la contradicción assert-contains/assert-not-contains sobre el mismo fichero es imposible de satisfacer); `skills/review/SKILL.md` contiene la instrucción del registro terminal `final — commit:`; `skills/run/SKILL.md` contiene `/tandem:status`; el script existe y responde `assert_rc 64` a un slug inválido. La garantía dinámica (cero invocaciones codex) vive en los tests comportamentales: `assert_no_file "$CODEX_STUB_LOG.argv.1"` en modo slug Y en modo listado.
- **PROOF:** `bash tests/verify.sh` (suite completa + shellcheck pineado sobre el script y los tests nuevos + actionlint).

## Risks

- **Deriva entre la escalera de fases y el pipeline real:** si una skill futura cambia dónde escribe su estado, el status mentiría. Mitigación: cada fuente leída es un contrato ya testeado en la suite (plan-approve, attempt state vía statusline, claves de hilo vía show-states), y `status-phases` recorre el ciclo completo con el `plan-approve.sh` real, no con fixtures inventadas.
- **Sourcear `_common.sh` con `set +e`:** un helper futuro con efectos al cargar rompería la promesa de solo lectura. Mitigación: el contrato «sin efectos de shell» ya está documentado (`_common.sh:91-94`) y el test de degradación detectaría un abort.
- **`next:` como lógica duplicada del pipeline en bash:** riesgo de desalineamiento con las skills. Mitigación: es una SUGERENCIA de una línea, la skill arbitra; los casos están fijados por test.
- **Reversión de claves con checksum en el listado:** deliberadamente NO se intenta (los slugs del listado salen de fuentes con slug plano); un run que solo tuviera hilo y ni log ni aprobación no aparecería en el listado — imposible en el pipeline real (el log se inicializa en el Act 1 de plan) y aceptado como límite documentado en la skill.
- **Colisión de filtro de tests:** `bash tests/run.sh status` también ejecuta los `statusline-*` (filtro por subcadena, `tests/run.sh:159-162`) — inofensivo, solo ruido.

## Out of scope

- Llamar a Codex o modificar CUALQUIER estado (ni mkdir, ni heartbeat, ni log) — solo lectura estricta.
- Liveness real del intento Opus (task_id/agent vivo): eso pertenece al guard de `tandem:implement` (`skills/implement/SKILL.md:151`); status solo reporta el JSON y su semántica.
- Estado de runs `ultra-*` (namespace propio, `state/ultra/<run>/`).
- Reemplazar `codex-show.sh` (sigue siendo el detalle por hilo; status es la vista por run) o envolverlo en skill.
- Tokens de transporte opus (no hay ledger; `n/a (transporte opus)` es el contrato existente).
- Cambios en statusline, wrappers o formato del log.
- Metadatos (plugin.json/CHANGELOG/BACKLOG): orquestador, post-implementación.

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default (incluye las preguntas
abiertas del borrador del enjambre, resueltas por el orquestador).

1. **¿Slug sin NINGUNA evidencia?** → Exit 2 con lista de runs conocidos en stderr
   (paralelo al "no thread" exit 2 de codex-show.sh). El pre-registro "nunca error" aplica
   a la DEGRADACIÓN de estado presente-pero-corrupto, no a preguntar por un run que no
   existe — ahí el error honesto y accionable es mejor que un informe vacío.
2. **¿La línea `next:` la imprime el script o la skill?** → El script: determinista y
   testeable (cada caso fijado por test); la skill narra encima y arbitra, pero el hecho
   crudo sale del parser. El riesgo de duplicar pizcas de lógica de pipeline se acepta y
   está listado en Risks.
3. **¿Fallback de tokens sin jq?** → No: "desconocido (sin jq)", precedente exacto de la
   statusline. Un fallback grep/awk sobre las líneas del log sería una segunda fuente de
   verdad menos fiable — la clase de duplicación que este repo evita.
4. **¿Rama?** → `tandem/status-skill` apilada según la cola (primera de la Cola 2: parte
   del main recién mergeado), aprobada con `plan-approve.sh`.
5. **¿Versión?** → 0.19.0; metadatos del orquestador tras la implementación.
