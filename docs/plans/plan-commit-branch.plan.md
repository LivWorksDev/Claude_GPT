# Plan: plan-commit-branch — commit del plan en la rama tandem, nunca en la del usuario

**Backlog:** M3 (P1/S→M tras revisión) · **Fecha:** 2026-07-30 · **Modo:** autónomo (TANDEM_AUTONOMOUS=1)

## Goal

Hoy el plan aprobado se commitea en la rama actual del usuario (típicamente `main`) y la rama
`tandem/<slug>` no nace hasta `tandem:implement` Step 0.6. Eso deja un commit huérfano en main
si el run se abandona y, en modo autónomo, es una escritura no supervisada en la rama por
defecto — violando la línea roja "never touch the default branch" del propio modo. El objetivo
es que la rama `tandem/<slug>` se cree en el momento de la aprobación del plan y que el commit
del plan aterrice ya dentro de ella, de forma que main (o la rama del usuario) no reciba
ningún commit nuevo durante un run tandem, ni siquiera uno abandonado tras la aprobación.

## Approach

La transición de git vive en un script nuevo y testeable (`scripts/plan-approve.sh`), no en
Markdown: todos los modos de fallo detectados en revisión (colisiones, resumes, planes
trackeados, mismatch de modo) son comportamiento de git que un test estático no puede cubrir.
Las skills invocan el script; los gates de implement se ajustan en Markdown con su test de
contrato.

1. **`scripts/plan-approve.sh <slug>` (nuevo).** Ejecuta la aprobación completa, fail-closed,
   idempotente. Entradas: slug; `TANDEM_WORKTREE` opcional. Comportamiento, en orden:
   - **Orientación primero:** determinar rama actual y rama objetivo antes de cualquier
     guard. Si la sesión ya está en `tandem/<slug>` (retry in-place tras una aprobación
     completada), entrar directamente al predicado de resume — el plan trackeado AHÍ es el
     resultado esperado de la aprobación anterior, no un slug reutilizado.
   - **Guard de plan trackeado (solo en rama origen/usuario):** si
     `docs/plans/<slug>.plan.md` está trackeado en la rama del usuario
     (`git ls-files --error-unmatch`), STOP (exit 65): slug reutilizado de un plan ya
     mergeado — elegir otro slug (p.ej. `<slug>-v2`) o retirar el plan viejo a mano. Nunca
     mover un fichero trackeado (dejaría una deleción en el checkout del usuario).
   - **Rama nueva (caso normal):**
     - in-place (`TANDEM_WORKTREE` unset): `git checkout -b tandem/<slug>` desde HEAD +
       `git add docs/plans/<slug>.plan.md && git commit`. La sesión queda en la rama tandem.
     - worktree (`TANDEM_WORKTREE=1`): sin tocar el checkout principal — `.worktrees/` en
       `.git/info/exclude`, `git worktree add .worktrees/<slug> -b tandem/<slug>`, mover el
       plan (untracked, verificado por el guard) dentro y commitearlo con
       `git -C .worktrees/<slug> …`. El checkout del usuario queda limpio y en su rama.
     - **Estado durable de aprobación, publicado transaccionalmente:** el ancla de identidad
       del resume es `.tandem/state/plan-approve/<slug>.json` con `branch`, `plan_commit`
       (sha del commit del plan), `source_head` (su primer parent = HEAD del usuario en la
       aprobación; nombre distinto de `base_head` a propósito — ese pertenece al attempt
       state de implement y designa el TIP de la rama tandem) y `mode`
       (`in-place`/`worktree`). La publicación es parte de la transacción, no un apéndice:
       (1) ANTES de mutar git, escribir el registro pending
       (`<slug>.json.pending`: branch, mode, `source_head`, hash del working plan);
       (2) mutar y commitear; (3) finalizar con fichero temporal + `mv` atómico y borrar el
       pending. Si la finalización falla (permisos, disco), rollback de git — el commit
       aterrizado se deshace igual que uno fallido — y el pending queda como evidencia. Un
       resume que encuentra pending sin estado final y un commit que concuerda con el
       pending lo recupera: finaliza el estado y continúa idempotente.
     - **Rollback ante commit fallido (identidad git ausente, hook que rechaza…):** ninguna
       mutación sobrevive a un commit que no aterrizó (ni a una finalización de estado que no
       aterrizó — ver arriba). In-place: volver a la rama original y borrar `tandem/<slug>`;
       worktree: devolver el plan al checkout principal, `git worktree remove --force` y
       borrar la rama. El working copy del plan se preserva SIEMPRE (es el único artefacto
       insustituible; si ya estaba committeado al deshacer, se restaura de
       `tandem/<slug>:docs/plans/<slug>.plan.md` antes de borrar la rama). El retry tras
       arreglar la causa parte de cero limpiamente.
   - **Rama `tandem/<slug>` pre-existente — resume anclado al estado durable, no a
     heurísticas:** la aprobación es resume idempotente SOLO si el estado durable existe y
     concuerda: tip de la rama == `plan_commit` registrado, primer parent del tip ==
     `source_head` registrado, el diff del tip toca únicamente `docs/plans/<slug>.plan.md`
     (cinturón y tirantes) y el plan de referencia concuerda con el blob committeado — el
     working file del checkout principal si existe, o, en modo worktree, su AUSENCIA en el
     checkout principal es válida cuando el plan trackeado del worktree registrado coincide
     con el blob (tras una aprobación worktree completada, el duplicado primario ya no debe
     existir). En el caso válido: reconciliar el working copy (borrar el duplicado untracked
     tras verificar identidad; nunca borrar uno divergente) y checkout/reuso del worktree
     según el modo.
     Cualquier otra cosa — sin estado durable (p.ej. `.tandem/` borrado), tip distinto del
     registrado, historia de implementación en la rama, blob distinto, working copy
     divergente — es STOP (exit 65) con las salidas explicadas; en autonomous, terminal
     FAILED. Una rama con historia de implementación se retoma vía `tandem:implement`
     (attempt state), jamás re-aprobando el plan; sin estado que dé confianza, no se adivina.
   - **Validación de mismatch de modo:** el modo real se deriva de git, no del entorno —
     si `git worktree list` muestra `tandem/<slug>` en un worktree enlazado pero
     `TANDEM_WORKTREE` no es `1`, o la rama está checked out en el checkout principal bajo
     `TANDEM_WORKTREE=1`, STOP con mensaje explícito (re-ejecutar con el modo correcto o
     deshacer el estado a mano). Nunca adivinar.
2. **`skills/plan/SKILL.md` — Resolution.** Sustituir el commit sin rama por la invocación de
   `plan-approve.sh` (gate humano e interactivo idénticos a autonomous; solo cambia quién
   aprueba). Documentar que in-place deja la sesión en la rama tandem y que bajo worktree el
   plan deja de ser visible en el checkout principal hasta el merge.
3. **`skills/implement/SKILL.md` — gates.**
   - §0.0: la ruta "fresh attempt" ya no implica "no existe worktree" — con un plan aprobado
     bajo el flujo nuevo, rama (y worktree, si aplica) existen desde la aprobación; un fresh
     attempt con rama existente resuelve `WORK_ROOT` antes de los gates. El camino "gate 6
     crea rama/worktree" queda como legacy (plan aprobado pre-0.12).
   - Gate 3 (plan gate): el plan vive en la rama tandem; verificarlo en `$WORK_ROOT` (o vía
     `git cat-file -e tandem/<slug>:docs/plans/<slug>.plan.md`), no asumir el checkout
     principal.
   - Gate 5 (clean-tree, fresh attempts): exigir limpieza en el checkout principal **y** en
     el `$WORK_ROOT` resuelto (deduplicado cuando son el mismo directorio). Un worktree
     pre-existente sucio sin attempt state que lo explique es STOP — nunca mezclar cambios
     desconocidos en un diff delegado.
   - Gate 6: pasar de "crear" a "verificar/reutilizar"; crear solo en el caso legacy. La
     validación de mismatch de modo es la misma que en plan-approve (derivar de
     `git worktree list`, nunca del entorno a ciegas).
   - **Baseline de seguridad tras la resolución, nunca antes:** `base_head` y
     `remote_snapshot` se capturan DESPUÉS de resolver rama/worktree y SIEMPRE anclados —
     `git -C "$WORK_ROOT" rev-parse HEAD` (= tip con el commit del plan) y
     `git -C "$WORK_ROOT" remote -v`. Capturarlos del checkout principal marcaría como
     violación de seguridad cualquier implementación worktree legítima.
   - `plan_hash` anclado: `git -C "$WORK_ROOT" rev-parse HEAD:docs/plans/<slug>.plan.md`.
   - §0.0/54-55: el contrato "implement/review-only" de `TANDEM_WORKTREE` se amplía —
     gobierna también dónde aterriza el commit de aprobación del plan; `ask`/`image` siguen
     sin anclarse nunca.
   - Línea 9: precisar que el commit del plan vive en `tandem/<slug>`.
4. **`skills/run/SKILL.md`.** "Plan gate → plan auto-committed ONLY on `VERDICT: APPROVED`"
   pasa a nombrar la rama; DEADLOCK gana "…on `tandem/<slug>`; main intacta".
5. **Tests.**
   - `tests/plan-approve.test.sh` (nuevo, comportamental): contra repos temporales reales —
     aprobación in-place fresca (rama creada, plan committeado, main sin commits nuevos,
     estado durable escrito con `plan_commit` y `source_head` exactos); aprobación worktree
     fresca (checkout principal limpio y en la rama del usuario, plan dentro del worktree);
     **segunda invocación inmediata en AMBOS modos** (idempotente, exit 0, sin commit nuevo —
     en worktree, con el duplicado primario correctamente ausente); colisión con plan distinto (exit 65, nada
     tocado); resume con estado durable concordante (exit 0, working copy reconciliado);
     rama cuyo tip no es el `plan_commit` registrado (exit 65); **commit de implementación
     anterior a un tip plan-only** (exit 65 — el ancla es el estado, no la forma del tip);
     rama pre-existente sin estado durable (exit 65); plan trackeado en la rama del usuario
     (exit 65); mismatch de modo en ambas direcciones (exit 65); **commit fallido por hook
     que rechaza, en ambos modos** (rollback completo: rama/worktree ausentes, plan
     preservado en el checkout, retry posterior exitoso); **fallo forzado de la escritura del
     estado final** (directorio de estado no escribible tras el pending: rollback de git, el
     retry tras restaurar permisos completa — y un pending con commit concordante se recupera
     finalizando el estado).
   - `tests/skill-plan-branch-contract.test.sh` (nuevo, estático): plan/SKILL.md invoca
     `plan-approve.sh` y ya no contiene el commit sin rama viejo (ancla negativa: "keeps the
     tree clean for tandem:implement's clean-tree gate"); implement/SKILL.md contiene el
     `plan_hash` anclado y el baseline anclado (`git -C "$WORK_ROOT" rev-parse HEAD`);
     run/SKILL.md conserva "never touch the default branch". Nunca verde por vacuidad.
   - `tests/skill-worktree-contract.test.sh` (actualizar): la aserción de la frase
     "implement/review-only" se sustituye por el contrato ampliado (frase nueva exacta que
     nombre plan-approval + implement/review).
6. **Metadatos — trabajo del orquestador, nunca del implementador delegado** (los templates
   de implement prohíben bumps de versión y ediciones de changelog): tras la implementación
   y antes del testing gate, Fable edita `.claude-plugin/plugin.json` → `0.12.0`,
   `CHANGELOG.md` (entrada v0.12.0) y `docs/BACKLOG.md` (M3 → `hecha (v0.12.0)`), todo en la
   rama tandem.

## Key decisions & tradeoffs

- **Script testeable en vez de danza en Markdown.** Decisión revertida en revisión: los modos
  de fallo reales (colisión, resume, tracked plan, mismatch) son comportamiento de git que un
  test estático mantendría verde estando rotos. El precedente es `worktree-root.sh`: la
  resolución fail-closed se movió a bash precisamente para testearla. Coste: esfuerzo S→M y
  una pieza más de superficie bash — pagado por tests comportamentales contra repos reales.
- **Invariante de resume = estado durable concordante, no heurísticas de forma.** Ni el blob
  ni el "tip plan-only" bastan: una rama `base → implementación → tip plan-only` pasaría
  ambos. El ancla es `.tandem/state/plan-approve/<slug>.json` (tip == `plan_commit`, parent
  == `source_head`), con el diff plan-only y el blob idéntico como cinturón y tirantes. Sin
  estado que dé confianza (`.tandem/` es efímero), fail-closed — la rama se retoma vía
  tandem:implement o se retira a mano, nunca se re-aprueba a ciegas.
- **Rollback total ante commit fallido.** La transición muta rama/worktree/índice antes del
  commit; una identidad git ausente o un hook que rechaza no puede dejar estado varado que el
  propio predicado de resume rechazaría después. Se deshace todo, se preserva el working copy
  del plan, y el retry parte de cero.
- **Worktree creado ya en la aprobación del plan.** La alternativa (checkout -b en el
  checkout principal también bajo worktree) rompe implement 0.6: `git worktree add` rechaza
  una rama ya checked out. Reutiliza el path "resume" existente. Coste: un worktree con solo
  el commit del plan si el run muere entre fases — exactamente el estado resumable que gate 6
  contempla.
- **El plan se MUEVE al worktree, no se copia — con guard de tracked.** Una copia untracked
  rompería el clean-tree gate y crearía dos fuentes de verdad. Un plan trackeado (slug
  reutilizado de un plan mergeado) no se mueve jamás: fail-closed con instrucción de renombrar.
- **Modo derivado de git, no del entorno.** `TANDEM_WORKTREE` decide solo en la creación;
  después, la verdad es `git worktree list`. Un mismatch entre entorno y estado real es STOP
  explícito, nunca una adivinanza — es lo que mantiene los runs resumables entre sesiones y
  shells con entornos distintos.
- **Baseline de seguridad anclado al árbol de trabajo.** `base_head` capturado en el checkout
  principal produciría falsos "implementer commit" en cada run worktree (la rama tandem va un
  commit por delante). Capturar tras resolver, con `git -C "$WORK_ROOT"`.
- **Base de la rama = HEAD en la aprobación.** Misma semántica que el gate 6 actual, antes en
  el tiempo. Sin rebase sobre remotos — fuera de alcance.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/plan-approve.sh` | Nuevo: transición de aprobación fail-closed e idempotente |
| `skills/plan/SKILL.md` | Resolution invoca plan-approve.sh; documenta efectos por modo |
| `skills/implement/SKILL.md` | §0.0 rutas, gates 3/5/6, baseline y `plan_hash` anclados, contrato TANDEM_WORKTREE ampliado, línea 9 |
| `skills/run/SKILL.md` | Política del plan gate y DEADLOCK nombran `tandem/<slug>` |
| `tests/plan-approve.test.sh` | Nuevo test comportamental contra repos temporales |
| `tests/skill-plan-branch-contract.test.sh` | Nuevo test estático de contrato |
| `tests/skill-worktree-contract.test.sh` | Aserción del contrato TANDEM_WORKTREE ampliado |
| `.claude-plugin/plugin.json` | `version` → `0.12.0` (orquestador, post-implementación) |
| `CHANGELOG.md` | Entrada v0.12.0 (orquestador) |
| `docs/BACKLOG.md` | M3 → `hecha (v0.12.0)` (orquestador) |

## Acceptance & proof

- Tras un run completo bajo el flujo nuevo, la rama del usuario no tiene commits nuevos: plan
  e implementación viven ambos en `tandem/<slug>`.
- Un DEADLOCK posterior a la aprobación del plan deja main intacta.
- Con `TANDEM_WORKTREE=1`, la aprobación deja el checkout principal limpio y en la rama del
  usuario; el plan queda committeado dentro de `.worktrees/<slug>`; el `base_head` del
  attempt state de implement = tip de la rama tandem — nombre reservado a implement; el
  estado de aprobación usa `source_head` para el parent del commit del plan — (ninguna
  implementación worktree limpia dispara el safety check).
- Una `tandem/<slug>` pre-existente detiene la aprobación (exit 65 / FAILED) salvo resume con
  estado durable concordante (tip == `plan_commit`, parent == `source_head`, diff plan-only,
  blob concordante), que reconcilia el working copy y continúa. Una segunda invocación inmediata
  tras una aprobación in-place exitosa es un no-op exit 0.
- Un commit fallido (hook que rechaza, identidad ausente) no deja rama, worktree ni estado
  varados: rollback completo con el plan preservado, y el retry posterior funciona.
- Un slug cuyo plan ya está trackeado en la rama del usuario detiene la aprobación con
  instrucción de renombrar.
- Un mismatch entre `TANDEM_WORKTREE` y el estado real de `git worktree list` detiene con
  mensaje explícito, en ambas direcciones.
- Este mismo run es el primer caso de aceptación: su commit de plan aterriza en
  `tandem/plan-commit-branch`, no en main.

**PROOF:** `bash tests/run.sh` (suite completa: `plan-approve.test.sh` comportamental,
`skill-plan-branch-contract.test.sh` estático, `skill-worktree-contract.test.sh` actualizado,
más todas las regresiones existentes).

## Risks

- **Regresión de texto load-bearing:** implement/SKILL.md es contrato para otros tests
  (launches anclados). Mitigación: ediciones quirúrgicas + suite completa como PROOF.
- **Caso legacy:** un plan aprobado bajo el flujo viejo (committeado en main, sin rama) debe
  seguir siendo implementable — gate 6 conserva el camino de creación.
- **Sesión interactiva dejada en la rama tandem (in-place):** comportamiento que ya tenía
  implement 0.6, ahora en la aprobación; se documenta en Resolution.
- **Portabilidad bash 3.2/BSD del script nuevo:** mismo listón que el resto de `scripts/`;
  cubierto por shellcheck pineado y la matriz CI macOS/ubuntu existentes.

## Out of scope

- Cambios en los scripts de transporte Codex (`codex-start/resume/reset/swarm`).
- Rebase/actualización de la base de la rama tandem sobre un remoto.
- El resto del backlog (M5–M13, M15), incluido M10 aunque este plan use reviews largas.
- Push, merge o PR — siguen siendo humanos.

## Assumptions

Modo autónomo: cada pregunta que habría hecho, con la decisión conservadora tomada.

1. **¿Dogfooding en este mismo run?** → Sí. La línea roja autonomous ya prohíbe el commit del
   plan en main; este run aplica el flujo nuevo (su plan aterriza en
   `tandem/plan-commit-branch`) y sirve de caso de aceptación. Como el script aún no existe
   en el momento de la aprobación, la danza de este run la ejecuta el orquestador a mano con
   los mismos pasos que luego quedan codificados en `plan-approve.sh`.
2. **¿Base de la rama?** → HEAD actual en la aprobación (semántica del gate 6, antes en el
   tiempo).
3. **¿Rama pre-existente?** → Fail-closed salvo resume anclado al estado durable de
   aprobación (tip == `plan_commit`, parent == `source_head`, más diff plan-only y blob
   concordante). Historia de implementación → tandem:implement, nunca re-aprobación; sin
   estado, nunca se adivina; un pending con commit concordante se recupera finalizando.
4. **¿Worktree en la aprobación o checkout -b siempre?** → Worktree en la aprobación bajo
   `TANDEM_WORKTREE=1`; la alternativa rompe `git worktree add` en implement.
5. **¿Metadatos (versión/CHANGELOG/BACKLOG) — quién y dónde?** → El orquestador, en la rama
   tandem, tras la implementación delegada (los templates del implementador se los prohíben)
   y antes del testing gate. Llegan a main con el merge humano; el estado intermedio
   "planificada" se salta porque plan e implementación aterrizan en el mismo run.
6. **¿Helper script o Markdown?** → Script + tests comportamentales (decisión cambiada en
   revisión: los modos de fallo son de git, no de texto).
7. **¿Versión?** → 0.12.0 (minor bump, como 0.10.0/0.11.0 para cambios de workflow).
