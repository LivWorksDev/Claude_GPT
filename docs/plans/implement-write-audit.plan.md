# Plan: implement-write-audit — auditoría de escrituras en implement + hook anti-install para Opus

**Backlog:** M25 (P1/M) · **Origen:** informe de campo 2026-08-21, hallazgo A2 +
enmienda E-A2 (`docs/audits/informe-campo-2026-08-21.md`) · **Fecha:** 2026-08-30 ·
**Modo:** interactivo (entrevista de 4 decisiones) · **Base:** main **5d41880** (v0.32.0).

## Goal

Con `workspace-write`, dentro de la raíz escribible quedan tres vectores que hoy solo
prohíbe la prosa del template (`skills/implement/prompts/implement.tpl:11,13`):
reescribir el lockfile, purgar `node_modules` y copiar ficheros hacia dentro desde otro
árbol. En el implementador Opus por defecto no hay sandbox de SO (riesgo residual
declarado en el README), así que ahí la prosa es la única barrera también para las
instalaciones — y la lección del incidente de julio es que la prosa no para a un modelo
en bucle de auto-reparación. Este plan añade dos barreras mecánicas: (1) la auditoría
de escrituras del modo imagen (`skills/image/SKILL.md:29,75`), generalizada a
`tandem:implement` en AMBOS transportes — snapshot previo + diff de cierre contra una
deny-list, donde todo toque no declarado en el plan degrada el intento a
`IMPLEMENTATION_PARTIAL` con el hallazgo nombrado, nunca aceptación silenciosa; y
(2) un hook `PreToolUse` del plugin que bloquea los comandos mutadores de dependencias
de npm/pnpm/yarn mientras exista un intento activo, gobernado por un guard durable de
vida-de-intento propiedad del propio script de auditoría — el ciclo de vida del guard
es el diseño real de la pieza (E-A2) y aquí queda cerrado: lo publica `snapshot` antes
del lanzamiento, lo elimina `close` en el handoff (o el reset guardado), y un crash lo
deja puesto (fail-closed sin caducidad).

Cobertura declarada del vector «copiar hacia dentro»: los toques de deny-list llegan
por la enumeración git con untracked completos (`-uall`); a `node_modules` lo cubre el
censo por set-diff en dos niveles — el conjunto de directorios `node_modules` (uno
aparecido de cero también es violación) y los nombres de primer nivel de cada uno —;
el resto de ficheros copiados son entradas `??` que el Step 3 de la skill ya obliga a
leer íntegras. La mutación de
CONTENIDO dentro de una entrada existente de `node_modules` NO se detecta mecánicamente
— residual declarado, no fingido.

## Approach

1. **NUEVO `scripts/implement-audit.sh` — la auditoría como trabajo de máquina, con
   tres subcomandos.** Mismo principio que M32 enuncia («machine work, not something a
   wrapper model should retype»): el veredicto lo produce un script, la skill solo lo
   invoca y actúa. Artefactos durables en
   `"$PROJECT_DIR"/.tandem/state/implement-audit/` (anclado a `CLAUDE_PROJECT_DIR:-$PWD`
   como `state_init`, NUNCA al worktree — sobreviven a un `rm -rf .worktrees/<slug>`):
   `<slug>.census` y `<slug>.guard`.
   - **`snapshot <slug> <work_root>`** — lo invoca la skill SOLO en la ruta de intento
     FRESCO (el gate 5 ya distingue fresh/resume), inmediatamente antes del
     lanzamiento, en ambos transportes. Hace dos cosas, ambas atómicas (tmp + `mv`):
     1. Escribe el **censo**: la identidad del intento (`plan_hash` — el blob
        commiteado del plan —, `base_head`, `work_root`) y, para el vector
        git-invisible, DOS conjuntos: el CONJUNTO de rutas de directorios
        `node_modules` hasta profundidad 4 desde `$WORK_ROOT` (un `find` que poda el
        descenso DENTRO de cada `node_modules`) — conjunto vacío incluido, porque
        «no había ninguno» es exactamente el dato que el caso worktree-fresco
        necesita — y, por cada directorio, los NOMBRES ordenados de sus entradas de
        primer nivel (nombres, no recuentos — el set-diff detecta también reemplazos
        con el mismo cardinal).
     2. Publica el **guard** de vida-de-intento `<slug>.guard` — el marcador que arma
        el hook. Publicarlo aquí, antes de lanzar, elimina la carrera con el primer
        Bash del subagente.
     La idempotencia razona sobre el PAR censo+guard, nunca sobre el censo a solas
     (P1-1 ronda 3: dos `mv` atómicos no hacen atómico el par, y un «censo existe →
     éxito» ingenuo lanzaría al implementador sin protección tras un snapshot
     interrumpido). Estados definidos: (a) censo + guard presentes e identidad
     coincidente → exit 0, re-ejecución idempotente real (identidad ajena → 65);
     (b) censo SIN guard — lo que deja un snapshot interrumpido entre las dos
     publicaciones — → validar la identidad del censo contra el intento actual:
     coincide → republicar el guard atómicamente y exit 0 (recuperación hacia el
     lado protegido), no coincide → 65 exigiendo reset — nunca éxito a secas sobre
     un estado parcial; (c) guard SIN censo → escribir el censo y conservar el
     guard, exit 0 (el guard suelto solo bloquea de más: dirección fail-closed
     correcta). El censo nunca se re-basa (mismo principio que `base_head`), y la
     skill NO invoca `snapshot` en resumes: un intento legacy sin censo debe
     conservar su WARN de no-verificado, nunca recibir un «before» posterior a las
     escrituras.
   - **`check <slug> <work_root>`** — se ejecuta en el Step 3 de la skill, antes del
     testing gate. Valida primero la identidad del censo contra el intento actual
     (`plan_hash`/`base_head`/`work_root` — mismatch → 65: artefacto rancio, jamás se
     audita contra la línea de partida de otro intento). Enumera las escrituras con
     `git -C "$WORK_ROOT" -c core.quotePath=false status --porcelain=v1 -z -uall
     --no-renames` — `-uall` porque el modo `normal` colapsa un directorio untracked
     entero a `?? dir/` y ocultaría un lockfile anidado; `-z` + `quotePath=false` para
     rutas con espacios/no-ASCII; `--no-renames` para que un rename aparezca como A+D
     y ambas rutas se evalúen — y evalúa CADA entrada contra la deny-list:
     - **Match por ruta, a cualquier profundidad** (monorepos): `pnpm-lock.yaml`,
       `yarn.lock`, `package-lock.json`, `.npmrc`, cualquier entrada bajo un
       directorio `patches/`, y los lockfiles multi-ecosistema por decisión de
       entrevista: `Cargo.lock`, `poetry.lock`, `uv.lock`, `Gemfile.lock`, `go.sum`,
       `composer.lock`.
     - **`package.json` por contenido, no por ruta, index incluido:** para cada
       `package.json` con estado no limpio, comparar con jq el subconjunto de claves
       de dependencias en DOS pares — blob de HEAD (`git show HEAD:<path>`) contra
       blob del index (`git show :0:<path>`) y blob de HEAD contra copia de trabajo —
       porque el implementador tiene prohibido commitear pero no stagear, y un cambio
       solo-index escaparía del par HEAD↔worktree. Lista cerrada de claves:
       `dependencies`, `devDependencies`, `peerDependencies`, `optionalDependencies`,
       `bundledDependencies`, `resolutions`, `overrides`, `pnpm`, `packageManager`.
       Un cambio solo en `scripts` o `version` NO es toque de deny-list. Semántica de
       ausencia explícita: manifest AÑADIDO que contenga cualquiera de esas claves,
       manifest BORRADO, o renombrado (A+D) → toque. Sin jq disponible, o con un
       `package.json` imparseable, la degradación es **fail-closed**: toda
       modificación de `package.json` cuenta como toque, nombrando jq en el mensaje.
     - **`node_modules` por censo:** `check` re-ejecuta el MISMO `find` podado y
       set-diffea primero los directorios — un `node_modules` APARECIDO donde el
       censo no registraba ninguno (raíz o anidado) es violación por sí mismo, igual
       que uno desaparecido —; después, por cada directorio censado, el set-diff de
       nombres de primer nivel: entrada desaparecida, AÑADIDA o reemplazada →
       violación (una adición bajo `node_modules` durante un intento es una
       instalación o una copia desde otro árbol). Censo ausente (intento legacy): las
       comprobaciones por ruta corren igual y se emite
       `WARN: census missing — node_modules changes unverified` explícito;
       degradación honesta, nunca silencio.
     - **La válvula «declarado en el plan gana» (decisión de entrevista):** el path
       debe aparecer como token en la sección **Files to touch** del plan aprobado,
       leída SIEMPRE del blob commiteado — el `plan_hash` registrado en el censo —
       jamás de la copia de trabajo, que el implementador puede editar (marca
       checkboxes) y podría «auto-declarar» su propia violación. Para el vector
       `package.json`-deps la declaración es el path del `package.json` concreto;
       para `patches/` vale el directorio o el fichero.
   - **`close <slug>`** — elimina el guard (y solo el guard; el censo queda como
     registro del intento hasta el reset). Lo invoca la skill en el Step 5, tras gate
     verde y auditoría en OK. Es la ÚNICA salida ordinaria del guard; las otras dos
     son el reset guardado y ninguna (crash → fail-closed sin caducidad, decisión de
     entrevista).
   - **Salida y exit codes:** una línea `VIOLATION: <path> — <razón>` por hallazgo en
     stdout y resumen final; exit 0 = limpio o todo declarado, exit 20 = violaciones
     (distinto de la familia 0/1/2/64/65 en uso — verificar la no-colisión en la
     implementación), 64 = usage, 65 = precondición irrecuperable (sin git, blob del
     plan ilegible, identidad del censo en mismatch). Shellcheck-limpio, bash 3.2/BSD
     como el resto de `scripts/`.

2. **NUEVO `scripts/hook-implement-guard.sh` + NUEVO `hooks/hooks.json` — el guard
   anti-install.** El plugin gana su primer hook: `PreToolUse` con matcher `Bash`,
   comando `"${CLAUDE_PLUGIN_ROOT}/scripts/hook-implement-guard.sh"`. El contrato de
   plugins auto-carga `hooks/hooks.json` desde la raíz del plugin — no hace falta
   campo en `.claude-plugin/plugin.json` — y el script DEBE llevar bit ejecutable;
   ambas cosas quedan pineadas por test (punto 5), no por fe. El script, en orden de
   coste:
   1. Lee el payload de stdin y extrae `tool_input.command` (jq; sin jq, fallback de
      match sobre el payload crudo — decisión declarada abajo).
   2. **Patrón primero, marcador después** (la ruta del 99,9% de los Bash es salir 0
      sin tocar disco). La gramática es por SEGMENTOS de shell: se parte el comando en
      segmentos (`;`, `&&`, `||`, `|`) y, si un segmento invoca `npm|pnpm|yarn` como
      palabra, CUALQUIER token mutador posterior dentro del segmento dispara —
      decisión de entrevista sobre el conjunto: `install|i|ci|add|remove|rm|
      uninstall|un|update|up|upgrade`, más `yarn` a secas (equivale a install). Así
      `npm --prefix app install`, `pnpm -C app add x` y `yarn --cwd app` matchean
      (opciones globales entre gestor y subcomando), igual que prefijos de entorno y
      cadenas `&&`. Conservador a sabiendas: `npm run update` es un falso positivo
      aceptado — el mensaje de bloqueo explica el porqué y la reformulación. `npm
      test`, `pnpm exec vitest`, `npm run build` NO matchean.
   3. Solo si matchea, comprueba el marcador: existencia de algún
      `"$CLAUDE_PROJECT_DIR"/.tandem/state/implement-audit/*.guard`. Guard presente →
      **exit 2** con mensaje en stderr que nombra el slug, la razón (M25: intento
      activo — las instalaciones mutan lockfiles que la auditoría marcará) y las
      salidas legítimas: esperar al cierre del intento o, si está realmente muerto,
      el protocolo de reset existente de la skill (guard de vida observacional +
      artefactos a borrar, ahora incluidos los de auditoría). Un guard ilegible con
      comando matcheado también bloquea (fail-closed estrecho: solo muerde a quien ya
      intentaba instalar).
   4. Sin guard → exit 0. **Post-crash (decisión de entrevista): fail-closed sin
      caducidad** — un guard huérfano sigue bloqueando hasta que un humano ejecute el
      reset; nunca se destapa por tiempo.

   El hook dispara en CADA Bash de la sesión, incluidos los del subagente
   implementador — que es exactamente el punto de aplicación — y también los del
   orquestador y otras sesiones del mismo proyecto mientras dure el intento
   (aceptado: durante un intento nadie debería mutar dependencias del árbol). Como el
   guard lo publica `snapshot` en ambos transportes, el hook protege también durante
   intentos sol — ensanchamiento deliberado respecto al literal del backlog, inocuo
   (los comandos del propio Codex no pasan por el tool Bash y ya corren bajo sandbox
   de SO): lo que se bloquea es que la SESIÓN mute dependencias en paralelo.

3. **`skills/implement/SKILL.md` — integración en cinco puntos.**
   - **Step 1, ambos transportes, SOLO intento fresco:** inmediatamente antes del
     lanzamiento, `bash "$SCRIPTS/implement-audit.sh" snapshot <slug> "$WORK_ROOT"`.
     En resume NO se invoca (P1-2: un legacy sin censo conserva su WARN; el guard de
     un resume legítimo sigue puesto desde su lanzamiento — si falta por venir de una
     versión anterior, el hook simplemente no arma para ese intento: degradación
     declarada, no reparada a mitad).
   - **Step 3, nuevo paso de verificación antes del testing gate:**
     `bash "$SCRIPTS/implement-audit.sh" check <slug> "$WORK_ROOT"`. Exit 20 → el
     intento SE TRATA como `IMPLEMENTATION_PARTIAL` sea cual sea el sentinel que el
     implementador escribió: las violaciones se copian verbatim al log, y la
     continuación del Step 2 pide revertir los toques no declarados (la única
     justificación que la válvula acepta es la declaración en el plan, que ya se
     evaluó). En modo autonomous aplican las reglas PARTIAL existentes — nunca
     avanzar a review con violaciones abiertas, nunca aceptación silenciosa. Exit 65
     también bloquea el avance (fail-closed): se reporta, no se rodea. Tras una
     remediación, `check` se re-ejecuta y debe salir 0 antes del gate.
   - **Step 3, punto 1:** la lectura del diff pasa de `git -C "$WORK_ROOT" diff` a
     las DOS vistas `git -C "$WORK_ROOT" diff --cached` (HEAD↔index) MÁS
     `git -C "$WORK_ROOT" diff` (index↔worktree) — `git diff HEAD` a solas no basta:
     con index=B y copia de trabajo restaurada a A sale vacío aunque commitear ahora
     commitearía B (P2-1 rondas 1–2). Stagear está fuera del alcance del sandbox de
     prosa pero no es imposible; con las dos vistas el estado staged queda a la vista
     del revisor humano igual que del script.
   - **Step 5 (handoff):** con gate verde y auditoría OK,
     `bash "$SCRIPTS/implement-audit.sh" close <slug>` — el guard cae y las
     instalaciones vuelven a estar permitidas ANTES de la fase de review.
   - **Protocolo de reset:** «exact reset» pasa de «solo `<slug>.json` y sus
     `.t*.report.md`» a incluir `implement-audit/<slug>.guard` y
     `implement-audit/<slug>.census`. Espejo en `scripts/codex-reset.sh`, con el
     mapeo de claves EXPLÍCITO (P1-1 ronda 2: el estado de hilo usa `target_key`,
     que produce `docs_plans_x.plan.md.<checksum>`, no el slug): el estado de hilo
     conserva su clave intacta; para los artefactos de auditoría, cuando
     `ROLE=implement` Y el target tiene la forma exacta `docs/plans/<slug>.plan.md`,
     el script extrae el slug (basename sin el sufijo `.plan.md`, validado no-vacío)
     y borra exactamente esos dos ficheros; un target de `implement` con cualquier
     otra forma no toca nada de auditoría y lo dice en su salida. En AMBOS caminos de
     reset (esta prosa y el script) los borrados van ORDENADOS censo primero, DESPUÉS
     los artefactos de hilo/estado del intento (`<slug>.json` + reports en Opus; el
     estado de hilo por `target_key` en Sol), y el guard SIEMPRE como último borrado
     (P1-1 ronda 3 + P2-2 ronda 4): una interrupción a mitad deja guard-sin-censo —
     installs siguen bloqueados y el estado cae en el caso (c) de `snapshot` o se
     re-resetea — y nunca puede dejar un intento REANUDABLE sin guard (los resumes
     saltan `snapshot` a propósito, así que un guard borrado antes que el estado de
     hilo no se re-publicaría jamás). El estado peligroso (censo-sin-guard) no es
     alcanzable por el reset; solo lo produce un snapshot interrumpido, y el caso (b)
     lo recupera hacia el guard puesto.
   - **Log:** la línea del gate gana el campo de auditoría —
     `audit — escrituras: OK` o la lista de `VIOLATION:` — junto al resto del Step 4.
4. **Templates — informar al implementador de la regla mecánica.**
   `skills/implement/prompts/implement.tpl` y `implement-claude.tpl`: la prohibición
   en prosa existente gana una línea que nombra la deny-list y que el cierre se
   audita mecánicamente (reduce violaciones de buena fe; la barrera no depende de
   ello). Los agentes `agents/implementer.md`/`implementer-critical.md` NO se tocan
   (paridad byte a byte pineada por `tests/agent-critical-parity.test.sh`; el
   template ya viaja en el prompt).
5. **Tests.**
   - **NUEVO `tests/implement-audit.test.sh`** (repo git de fixture en el sandbox):
     limpio → 0; lockfile modificado no declarado → 20 nombrando el fichero;
     lockfile declarado en Files to touch del blob commiteado → 0; declaración solo
     en la copia de trabajo (plan editado post-commit) → 20 (la válvula lee el blob);
     `package.json` solo-`scripts` → 0; deps cambiadas no declaradas → 20; deps
     cambiadas con `package.json` declarado → 0; deps cambiadas SOLO en el index
     (staged, copia de trabajo restaurada) → 20; manifest añadido con deps / borrado
     / renombrado → 20; sin jq + `package.json` modificado → 20 nombrando jq;
     lockfile untracked ANIDADO bajo un directorio untracked nuevo → 20 (el caso que
     `-uall` existe para no perder), también con `status.showUntrackedFiles=no` en la
     config del fixture; rutas con espacios y no-ASCII → 20 con el path exacto;
     borrado, ADICIÓN y reemplazo de entradas de primer nivel bajo `node_modules`
     según censo → 20; un `node_modules` APARECIDO donde el censo no registraba
     ninguno — raíz y anidado (absent→new) → 20; censo ausente → WARN explícito +
     solo checks por ruta; censo con identidad en mismatch → 65; `Cargo.lock`
     (multi-eco) → 20; entrada bajo `patches/` borrada → 20; snapshot idempotente
     (segunda llamada no re-basa); snapshot publica el guard y `close` lo retira
     dejando el censo; **recuperación del par (P1-1 ronda 3):** censo-sin-guard
     pre-sembrado con identidad coincidente → `snapshot` republica el guard y sale 0;
     con identidad ajena → 65 sin tocar nada; guard-sin-censo → censo escrito y guard
     conservado, exit 0; par COMPLETO censo+guard con identidad ajena → `snapshot`
     65 dejando ambos byte a byte intactos (P2-1 ronda 4); **reset behavioral:**
     `codex-reset.sh implement
     docs/plans/x.plan.md` elimina `x.guard` + `x.census` y los artefactos del slug
     adyacente `y` sobreviven, con el estado de hilo reseteado por su `target_key`
     de siempre; el ORDEN de borrado verificado sobre el reset REAL con un shim de
     `rm` en PATH que registra los argv y delega en el real — censo primero,
     artefactos de hilo antes del guard, guard como último borrado (una
     implementación guard-primero falla; P2-2 ronda 4) — más el caso de recuperación
     pre-sembrada (con solo el censo borrado el guard sigue bloqueando y un segundo
     reset lo retira) como complemento; usage/preconditions → 64/65.
   - **NUEVO `tests/hook-implement-guard.test.sh`** (payloads JSON por stdin +
     `.tandem/state/implement-audit` de fixture): sin guard + `pnpm install` → 0;
     guard presente + cada mutador (`pnpm install`, `npm ci`, `pnpm add x`, `yarn` a
     secas, `yarn upgrade`, `npm --prefix app install`, `pnpm -C app add x`,
     `yarn --cwd app`, prefijo de env y cadena `&&`) → exit 2 nombrando el slug;
     guard presente + no-mutadores (`npm test`, `npm run build`, `pnpm exec vitest`,
     `git status`) → 0; sin jq + `pnpm install` con guard → 2 (fallback crudo);
     guard ilegible + comando matcheado → 2 (fail-closed estrecho); payload sin
     `command` → 0. **Registro:** `hooks/hooks.json` tiene la forma exacta
     (`PreToolUse`, matcher `Bash`, comando `${CLAUDE_PLUGIN_ROOT}/scripts/
     hook-implement-guard.sh`), el script tiene bit ejecutable, y el caso de bloqueo
     se ejecuta a través del comando configurado en el JSON (resuelto con
     `CLAUDE_PLUGIN_ROOT` del sandbox), no llamando al script por su ruta directa.
   - **NUEVO `tests/skill-implement-audit-contract.test.sh`** (patrón
     `skill-worktree-contract.test.sh`: el Markdown de la skill es comportamiento
     ejecutable): pinea que SKILL.md ordena `snapshot` antes del lanzamiento y solo
     en fresco, `check` antes del testing gate, exit 20 → PARTIAL con violaciones al
     log, exit 65 bloquea, re-check tras remediación, `close` en el Step 5, el reset
     ampliado con los artefactos de auditoría Y su orden (censo → estado del intento
     → guard último; P2-2 ronda 4), y las DOS vistas de diff
     (`git diff --cached` + `git diff`) en el Step 3.
   - **Suite existente intacta**; shellcheck cubre los dos scripts nuevos por vivir
     en `scripts/`.
6. **Docs y versión.**
   - `docs/ARCHITECTURE.md`: sección breve de las dos barreras M25 — ciclo de vida
     del guard (snapshot→close/reset, crash fail-closed) incluido — con sus
     residuales DECLARADOS: no son defensa adversarial (un implementador Opus sin
     sandbox de SO puede borrar el guard/censo o escribir a mano — el objetivo es
     parar bucles, no malicia); ediciones a ficheros deny-listed que estén gitignored
     son invisibles a `git status`; la mutación de contenido DENTRO de una entrada
     existente de `node_modules` no se detecta (el set-diff es de primer nivel).
   - `README.md`: el párrafo del riesgo residual Opus gana las dos mitigaciones
     mecánicas; nota de que el plugin ahora incluye un hook `PreToolUse` (visible en
     el prompt de confianza al instalar/actualizar) y qué bloquea exactamente.
   - **Trabajo del ORQUESTADOR, post-implementación, antes del gate final de review
     (P2-5: los templates prohíben al implementador tocar release metadata):**
     `CHANGELOG.md` entrada **0.33.0** · `.claude-plugin/plugin.json` `version`
     0.33.0 · `docs/BACKLOG.md` fila M25 → `hecha (v0.33.0)` (verdadera en el merge,
     convención M26).

## Key decisions & tradeoffs

- **El marcador de intento-activo es un guard dedicado del script de auditoría, no el
  `status` del JSON de intento.** E-A2 dice que el ciclo de vida del marcador es el
  diseño real; la ronda 1 (P1-1) demostró que el candidato obvio — `status: "running"`
  — tiene semántica POR-TURNO (pasa a `terminal` en cada retorno, dejando desarmado el
  hook entre turnos y durante verificación/testing, más una carrera «immediately
  upon»). El guard tiene exactamente tres transiciones, todas nombradas: lo publica
  `snapshot` atómicamente ANTES de lanzar (sin carrera), lo retira `close` en el
  handoff o el reset guardado, y un crash lo deja puesto (fail-closed sin caducidad,
  decisión de entrevista). Los estados PARCIALES del par censo+guard están definidos
  (ronda 3): censo-sin-guard se recupera republicando el guard si la identidad
  coincide (65 si no), guard-sin-censo se conserva bloqueando, y el reset borra en
  orden censo → estado del intento → guard-último para que su interrupción caiga
  siempre del lado que bloquea y nunca deje un intento reanudable sin guard.
  `status` conserva su semántica actual para la statusline.
- **El guard arma el hook en AMBOS transportes.** Consecuencia declarada del diseño
  (snapshot corre en ambos): el literal del backlog pedía el hook «para el transporte
  Opus», pero bloquear que la SESIÓN mute dependencias durante un intento sol es
  igual de coherente y cuesta cero — los comandos del propio Codex no pasan por el
  tool Bash, así que para sol esto solo cierra la puerta del orquestador distraído.
- **Post-crash fail-closed sin caducidad** (entrevista). Un guard huérfano bloquea
  las instalaciones hasta el reset explícito. Alternativas rechazadas: ventana de
  staleness (un intento largo legítimo se destaparía solo) y override por variable
  (una perilla más que validar, y la salida legítima — el reset — ya existe y es
  auditable).
- **El hook bloquea mutadores por segmento de shell, no solo `install` literal**
  (entrevista + P2-4): `install|i|ci|add|remove|rm|uninstall|un|update|up|upgrade` de
  npm/pnpm/yarn más `yarn` a secas, con la gramática «gestor en el segmento → todo
  token mutador posterior dispara», que cubre opciones globales interpuestas
  (`npm --prefix app install`). Conservador a sabiendas: `npm run update` bloquea en
  falso durante un intento — coste aceptado y explicado por el mensaje; la
  alternativa (parsear la gramática real de tres CLIs) es frágil y no auditable.
  Otros gestores (bun, pip/poetry, cargo) quedan fuera del hook — sus lockfiles SÍ
  están en la deny-list de la auditoría, que es la red de fondo.
- **Deny-list JS + lockfiles multi-ecosistema, fija, sin perilla** (entrevista).
  Añadir `Cargo.lock`/`poetry.lock`/`uv.lock`/`Gemfile.lock`/`go.sum`/`composer.lock`
  cuesta un patrón por ruta y cubre la misma clase de daño diferido. Sin
  `TANDEM_DENYLIST_EXTRA`: una superficie de configuración más solo paga cuando un
  repo real la pida (entrada futura de backlog).
- **La válvula lee SOLO la sección Files to touch del blob commiteado** (entrevista).
  Cualquier mención en el plan convertiría un «Risks: no tocar pnpm-lock.yaml» en
  declaración — lo contrario de su intención. El blob (no la copia de trabajo) porque
  el implementador edita legítimamente la copia (checkboxes) y no debe poder
  auto-declarar.
- **La enumeración es `--porcelain=v1 -z -uall --no-renames` con `quotePath=false`,
  no el porcelain a secas** (P1-3). El modo `normal` colapsa directorios untracked
  (`?? packages/` escondería `packages/new/package-lock.json`) y la config del repo
  puede suprimir untracked; los flags mandan sobre la config. `--no-renames` hace de
  un rename un A+D y ambas rutas se evalúan.
- **La comparación de deps mira el index además del worktree** (P2-1). Commitear está
  prohibido; stagear no está impedido por nada mecánico — un cambio solo-index
  escaparía de HEAD↔worktree y también del `git diff` del Step 3, que por lo mismo
  pasa a las DOS vistas `git diff --cached` + `git diff` (`git diff HEAD` a solas
  deja ciego el estado staged+copia-restaurada, ronda 2). Semántica de ausencia
  cerrada: manifest añadido con claves de deps, borrado o renombrado = toque.
- **La degradación sin jq es asimétrica a propósito.** En la auditoría (`check`),
  fail-closed: `package.json` modificado cuenta como toque — un falso positivo
  molesta una vez y se resuelve instalando jq; un falso negativo es el incidente de
  julio otra vez. En el hook, el fallback es match sobre el payload crudo — bloquear
  TODOS los Bash de todas las sesiones por falta de jq sería un brick, y el match
  crudo solo arriesga el falso positivo estrecho (un Bash que menciona
  `pnpm install` en un string durante un intento activo).
- **La degradación a PARTIAL la ejecuta el orquestador, no el implementador.** El
  sentinel lo escribe quien implementa, pero el veredicto de la auditoría llega
  después y manda: exit 20 → el intento ES PARTIAL a efectos del pipeline, con las
  violaciones nombradas. Un `IMPLEMENTATION_COMPLETE` con violaciones es exactamente
  la aceptación silenciosa que M25 prohíbe. La conversión exit-20→PARTIAL es contrato
  ejecutable de la skill, pineado por el contract test (P2-2), no prosa suelta.
- **Censo de CONJUNTOS — rutas de directorios `node_modules` Y nombres de primer
  nivel por directorio — no recuentos ni snapshot profundo** (P2-3 ronda 1 + P1-2
  ronda 2). El set-diff de directorios detecta un `node_modules` aparecido de cero
  (el caso común del worktree fresco, donde no hay ni directorio censado ni entrada
  de git status) o purgado entero; el de nombres detecta vaciados, adiciones y
  reemplazos de entrada — incluido purge-and-repopulate con el mismo cardinal, que
  un recuento no ve. Un snapshot profundo costaría minutos y millones de entradas en
  repos reales. Limitación declarada: la mutación de contenido dentro de una entrada
  existente no se ve (pero casi siempre viene de un install/update, que el hook y el
  resto de la deny-list cubren).
- **Exit 20 dedicado para «violaciones».** Distinto de 0 (limpio), 64/65 (errores):
  la skill y el modo autonomous necesitan distinguir «auditoría ejecutada con
  hallazgos» de «auditoría imposible» sin parsear prosa.

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `scripts/implement-audit.sh` | NUEVO — subcomandos `snapshot`/`check`/`close`, guard, censo con identidad, deny-list, válvula, exit 0/20/64/65 |
| `scripts/hook-implement-guard.sh` | NUEVO — guard PreToolUse: gramática por segmentos + guard-file, exit 2 al bloquear; bit ejecutable |
| `hooks/hooks.json` | NUEVO — registro del hook `PreToolUse` matcher `Bash` vía `${CLAUDE_PLUGIN_ROOT}` (auto-cargado; sin campo en el manifest) |
| `scripts/codex-reset.sh` | role `implement` + target con forma exacta `docs/plans/<slug>.plan.md` → borra `implement-audit/<slug>.guard` y `<slug>.census` (slug extraído y validado; el estado de hilo conserva su `target_key`) |
| `skills/implement/SKILL.md` | snapshot en Step 1 (fresco, ambos transportes), check + degradación a PARTIAL en Step 3, vistas `git diff --cached` + `git diff`, `close` en Step 5, reset ampliado, campo de auditoría en el log |
| `skills/implement/prompts/implement.tpl` | línea que nombra la deny-list y la auditoría mecánica de cierre |
| `skills/implement/prompts/implement-claude.tpl` | ídem |
| `tests/implement-audit.test.sh` | NUEVO — la matriz de casos del punto 5 |
| `tests/hook-implement-guard.test.sh` | NUEVO — matriz + forma del hooks.json, bit ejecutable, ejecución vía entry-point configurado |
| `tests/skill-implement-audit-contract.test.sh` | NUEVO — contrato ejecutable del Markdown de la skill |
| `docs/ARCHITECTURE.md` | sección de las dos barreras, ciclo de vida del guard, residuales declarados |
| `README.md` | mitigaciones en el párrafo del riesgo residual Opus + nota del hook |
| `CHANGELOG.md` · `.claude-plugin/plugin.json` · `docs/BACKLOG.md` | **orquestador, post-implementación** (P2-5): entrada y bump 0.33.0, fila M25 |

## Acceptance & proof

1. Un intento que toca la deny-list sin declararlo en la sección Files to touch del
   plan commiteado termina en `IMPLEMENTATION_PARTIAL` nombrando el fichero (exit 20
   de `check` + degradación en la skill), incluso si el implementador emitió
   `IMPLEMENTATION_COMPLETE` — y también cuando el toque vive solo en el index, en un
   lockfile untracked anidado, en una adición/reemplazo de primer nivel bajo
   `node_modules`, o en un `node_modules` aparecido de cero (raíz o anidado); el
   mismo toque declarado pasa limpio (válvula).
2. Un `pnpm install` — y cada mutador de la lista, `yarn` a secas y las variantes con
   opciones globales (`npm --prefix app install`) incluidos — bajo guard activo es
   bloqueado por el hook con exit 2, mensaje que nombra el slug y las salidas
   legítimas; sin guard (intento cerrado con `close`, reset, o nunca abierto), nada
   se bloquea; `npm test`/`npm run build`/`pnpm exec …` pasan siempre. El guard nace
   ANTES del lanzamiento (sin carrera), sobrevive turnos, continuaciones,
   verificación y testing gate, y solo cae en `close`/reset.
3. Un intento limpio no nota nada: `check` sale 0, el log gana una línea
   `audit — escrituras: OK`, `close` retira el guard en el handoff, y ningún Bash
   ajeno a mutadores paga más que el match de patrón del hook.
4. Sin jq: `check` trata todo `package.json` modificado como toque (nombrando jq) y
   el hook sigue bloqueando `pnpm install` por match crudo; sin censo (intento
   legado), `check` emite el WARN explícito y ejecuta los checks por ruta; censo de
   otro intento (identidad en mismatch) → 65, nunca un veredicto sobre línea de
   partida ajena.
5. El contract test pinea la orquestación de la skill (snapshot fresco→launch,
   check→gate, 20→PARTIAL, 65 bloquea, close, reset ampliado, vistas
   `git diff --cached` + `git diff`); el test del hook pinea la forma del
   `hooks/hooks.json`, el bit ejecutable y la ejecución vía el comando configurado;
   el reset de Sol elimina los artefactos de auditoría del slug exacto sin tocar los
   de slugs adyacentes (test behavioral). Ambos scripts nuevos pasan shellcheck; la
   suite existente pasa sin editar aserciones.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint, las
tres capas obligatorias).

## Risks

- **El hook añade latencia a CADA Bash de la sesión.** Mitigado por diseño
  patrón-primero (un grep sobre el comando; el disco solo se toca si matchea un
  mutador). Riesgo residual: un payload enorme por stdin — el match crudo es lineal.
- **Un guard huérfano de una versión futura/pasada del plugin** (intento lanzado con
  otra versión de los scripts): el hook solo mira existencia de fichero, así que la
  compatibilidad es máxima; el mensaje siempre nombra el slug y el protocolo de
  salida.
- **No es defensa adversarial** — el implementador Opus sin sandbox de SO puede
  borrar el guard, editar el censo o escribir directamente. El objetivo declarado
  es parar bucles de auto-reparación, no malicia; queda registrado como residual en
  ARCHITECTURE (mismo tratamiento honesto que el residual de `web_search`).
- **Ficheros deny-listed gitignored** (p. ej. un `.npmrc` local ignorado): sus
  ediciones son invisibles a `git status` y la auditoría no las ve. Residual
  declarado; cubrirlo exigiría hashes de ficheros ignorados en el censo (entrada
  futura si muerde).
- **Falsos positivos del hook en comandos legítimos** (`npm run update`, un
  `npm install` dentro de un heredoc): la gramática por segmentos es conservadora a
  propósito; el mensaje de bloqueo explica el porqué y la salida; el orquestador
  puede reformular el comando. Solo muerde mientras hay intento activo.
- **Deriva entre el patrón del hook y la deny-list de la auditoría** (dos listas
  relacionadas en dos scripts): mitigación por comentario cruzado en ambos y por las
  dos matrices de tests, que fijan cada lista literalmente.
- **Parser del porcelain:** los formatos de dos columnas XY, entradas `??` y pares
  A+D bajo `--no-renames` deben cubrirse con el parser NUL-separado; los casos de
  rutas raras están en la matriz de tests (promesa cumplida en la propia matriz, no
  solo enunciada aquí).
- **El contract test es estático:** pinea que el Markdown ordena lo correcto, no que
  un orquestador real lo obedezca — el mismo límite asumido por los contract tests
  existentes del repo; el hook y el `check` son las capas que no dependen de
  obediencia.

## Out of scope

- Bloquear los comandos internos del transporte sol vía hook: no pasan por el tool
  Bash de Claude Code (el hook no puede verlos) y ese asiento ya tiene sandbox de SO
  sin red; su cobertura M25 es la auditoría de cierre. (El hook SÍ queda armado
  durante un intento sol para los Bash de la sesión — ver Key decisions.)
- Extender el hook a otros gestores (bun, pip/poetry/uv, cargo) o a un perfil
  configurable de comandos; `TANDEM_DENYLIST_EXTRA` u otra perilla de deny-list.
- Auditar los asientos de swarm/ultra o `tandem:ask` (read-only por pin de sandbox).
- Endurecimiento adversarial del guard/censo (firmas, permisos): fuera del modelo
  de amenaza declarado.
- Integración en `tandem:doctor` del estado del hook (no verificable desde un script
  sin leer la config de la sesión); si se quiere, entrada nueva de backlog.
- Hashes de ficheros gitignored en el censo (residual declarado en Risks).
- Detección de mutación de contenido DENTRO de entradas existentes de `node_modules`
  (residual declarado en Goal/Risks).
