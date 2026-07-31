# Plan: review-range — review de rangos ya committeados

**Backlog:** M15 (P3/M) · **Fecha:** 2026-07-31 · **Modo:** autónomo (Cola 2, tarea 4/4)
**Reescrito íntegro en ronda 1 del red-team:** el diseño solo-documentación del borrador
resultó insuficiente (bootstrap, colisiones de namespace, integración con status, rango
verbatim inseguro); la mecánica de git pasa a un helper testeable — la lección de
plan-approve.sh. Este documento es la única fuente.

## Goal

`tandem:review` solo revisa diff sin commitear; "quiero el revisor Sol sobre esta rama/PR
ya committeada" obliga a improvisar con tandem:ask. Objetivo: modo rango explícitamente
FUERA del pipeline — produce veredicto y hallazgos, jamás un commit — con un helper
`scripts/review-range.sh` que valida y resuelve el rango, arranca el estado y construye el
contexto (diff inline anclado a shas resueltos), y una sección de la skill que reutiliza
SOLO la mecánica de lanzamiento/barrera/contabilidad del pipeline con una tabla de
decisión propia. Namespace disjunto por construcción; invisible para /tandem:status.

## Approach

1. **`scripts/review-range.sh <label> <rango>` (nuevo) — toda la mecánica testeable.**
   - **Validación del label:** charset de plan-approve (`[A-Za-z0-9._-]`, sin `-`/`.`
     inicial) → 64.
   - **Validación y resolución del RANGO (nunca verbatim a un comando):** parsear
     EXACTAMENTE un separador `..` o `...`; rechazar endpoints vacíos, con caracteres de
     control o con forma de opción (`-*`) → 64; resolver cada endpoint con
     `git rev-parse --verify "<ep>^{commit}"` (fallo → 65 con mensaje); reconstruir la
     especificación del diff CITADA desde los SHAs completos resueltos — lo que viaja a
     git es siempre `<shaA>..<shaB>`/`<shaA>...<shaB>`, jamás el texto del usuario.
   - **Bootstrap del estado:** `STATE_ROOT="${CLAUDE_PROJECT_DIR:-<checkout principal via
     git-common-dir>}/.tandem"`; crear `tmp/`, `log/ranges/` y el `.gitignore` ANTES de
     escribir nada (primer uso en un repo sin tandem funciona); todas las rutas emitidas
     son ABSOLUTAS.
   - **Namespace disjunto por construcción:** target del hilo `range-review-<label>` (un
     slug de pipeline legal `range-foo` produce `cr-range-foo` — distinto siempre); log en
     `.tandem/log/ranges/<label>.md` (subdirectorio: fuera del scan top-level de
     tandem-status, que trata cada `log/*.md` como slug de pipeline — P1-3 resuelto por
     construcción, con aserción).
   - **Contexto:** escribe `.tandem/tmp/range-<label>-context.md` (absoluto) con:
     endpoints resueltos (sha corto + ref original), `git log --oneline shaA..shaB`,
     `git diff --stat`, la instrucción OBLIGATORIA al reviewer de leer el código
     circundante ANCLADO a B — `git show <shaB>:<path>` y `git ls-tree` — porque el
     checkout actual puede estar en otra versión (el diff solo lleva hunks; los ficheros
     como están en B son la verdad del rango), y el diff completo inline bajo `DIFF:`
     (`git diff shaA..shaB`, la vía inline que la skill ya contempla). Rango VACÍO
     (`git diff --quiet` 0) → exit 2 honesto "nada que revisar"; 128 u otros errores git →
     65.
   - **Salida parseable:** `TARGET:`, `CONTEXT_FILE:`, `LOG_FILE:`, `ENDPOINTS:` y
     **`WORK_ROOT:`** (el checkout principal absoluto resuelto vía git-common-dir — el
     modo rango no pasa por el Step 0 normal que definía `$WORK_ROOT`, así que el helper
     lo emite y la skill lo parsea para el `TANDEM_CODEX_CWD` del lanzamiento). Exit: 0
     ok · 2 rango vacío · 64 uso · 65 git/estado.
   - **Contrato de fallos COMPLETO y contexto atómico:** el contexto se construye en un
     fichero temporal del mismo directorio y se publica con `mv` atómico SOLO al
     completarse; CADA fallo de git (log/stat/diff, no solo el quiet) o de filesystem se
     traduce a 65 explícitamente (nunca se filtra un 1/128 crudo de set -e) y el temporal
     se limpia con trap — un retry jamás consume un contexto truncado. Test con fallo
     forzado (directorio no escribible) asertando que NO queda contexto final.
   - **`.gitignore` preservado:** el patrón existente `[ -f ] || printf` — jamás
     sobreescribir una política de ignore ya presente. Test con centinela pre-existente
     byte-idéntico.
   - Sin gate de árbol sucio (irrelevante: no se toca el working tree) y sin heartbeat
     propio (el turno codex ya lo escribe).
1a. **Frontmatter de la skill actualizado** — la descripción actual dice "NOT for
   already-committed code" y el argument-hint solo acepta un slug de plan: instrucción
   directa de NO usar la skill para el caso que este cambio añade. La descripción pasa a
   distinguir la review de pipeline (diff sin commitear, con gate y commit) del modo rango
   fuera de pipeline; `argument-hint` gana `[<label> --range A..B]`. Ancla negativa en el
   contrato: la prohibición obsoleta ha desaparecido.
1b. **Templates de rango propios** — los del pipeline instruyen "review the UNCOMMITTED
   changes", exigen un plan y mandan `git status -s`/`git diff HEAD`: contradicen el modo
   rango de frente. Nuevos `skills/review/prompts/start-range.tpl` (framing de rango
   committeado: el `DIFF:` inline del contexto es AUTORITATIVO, plan opcional, lecturas
   ancladas a B obligatorias, mismo contrato de veredicto `VERDICT:`) y
   `resume-range.tpl` (re-review: el contexto ACTUALIZADO llega por `{{NOTES}}`; el
   reviewer re-examina sus hallazgos contra el rango nuevo, sin instrucciones de estado
   sin commitear).
2. **`skills/review/SKILL.md` — sección "Range mode (out of pipeline)" con tabla de
   decisión propia, no "Steps 1-3 tal cual":**
   - Entrada: `/tandem:review <label> --range A..B`. Paso 1: ejecutar el helper y usar sus
     líneas de salida. Paso 2: lanzamiento con la MISMA mecánica del Step 2 normal
     (background por defecto + barrera dura + contabilidad USAGE — las tres se reutilizan
     verbatim), target `range-review-<label>`, contexto del helper, y
     `TANDEM_CODEX_CWD="$WORK_ROOT"` como todo lanzamiento de esta skill.
   - Tabla de decisión del veredicto (lo que NO se reutiliza): `APPROVED` → informar y
     FIN; `REQUEST_CHANGES` → los hallazgos SON el entregable — informar y FIN (sin loop
     de fixes, sin Step 3.1, sin testing gate: no hay working tree que arreglar);
     sin `VERDICT:` → un solo nudge (la mecánica existente); si TAMBIÉN el nudge vuelve sin
     `VERDICT:`, la invocación termina como `REQUEST_CHANGES` con la anomalía registrada
     en el log del rango (el paralelo exacto de la regla del pipeline) y los USAGE de
     AMBOS turnos contabilizados — jamás un segundo nudge ni un final sin estado terminal;
     NUNCA Step 4 (ni gate humano de commit, ni commit, ni registro terminal
     `final — commit:`). Ancla de la rama del doble-sin-veredicto en el contrato.
   - Rango actualizado tras arreglos del usuario: nueva invocación del helper con el
     MISMO label → mismo hilo (resume con el contexto nuevo por `{{NOTES}}` — el reviewer
     recuerda sus hallazgos), documentado como el único camino de "re-review". **Regla de
     linaje:** mismo label = mismo linaje de review (el rango actualizado que responde a
     los hallazgos de ESE hilo). Un rango NO relacionado bajo un label reutilizado hereda
     hallazgos ajenos y viola la independencia: exige label nuevo o reset explícito de
     `range-review-<label>` antes de empezar — la skill lo dice y el exit 2 del hilo
     existente es el recordatorio mecánico.
   - `TANDEM_PROMOTE_REVIEWS` NO aplica en modo rango (sin Step 4 no hay promoción; la
     skill lo dice para que PROMOTE=1 no espere registro versionado).
   - La prosa de la sección NO nombra los wrappers fuera de bloques fenced (el contrato de
     worktree escanea toda línea física de este fichero — P1-6); el exit 2 del hilo
     existente se explica sin nombrar el script ("an existing thread for this label is
     resumed, not restarted").
3. **Tests.**
   - `tests/review-range.test.sh` (nuevo, comportamental contra repos temporales):
     bootstrap desde repo SIN `.tandem/` (helper crea tmp/log/ranges/.gitignore); rangos
     dos-puntos y tres-puntos con endpoints resueltos a shas completos en el contexto —
     el tres-puntos sobre un grafo GENUINAMENTE divergente (ramas con commits propios a
     ambos lados del merge-base), asertando que su `DIFF:` es byte a byte igual a
     `git diff "$shaA...$shaB"` Y distinto del resultado dos-puntos `git diff "$shaA..$shaB"`;
     endpoints inválidos/vacíos/con forma de opción → 64; refs inexistentes → 65; rango
     vacío → 2; el `DIFF:` inline byte a byte igual a `git diff shaA..shaB`; la
     instrucción `git show <shaB>:` presente; árbol SUCIO no bloquea (modo fuera de
     pipeline); **no-colisión**: un slug de pipeline `range-foo` (target `cr-range-foo`)
     y un label de rango `foo` (target `range-review-foo`) producen claves de estado
     distintas (aserción sobre target_key) y logs en rutas distintas; el listado de
     `tandem-status.sh` NO muestra los ranges (subdirectorio fuera del scan — aserción).
   - `tests/skill-range-contract.test.sh` (nuevo, estático): la sección de rango existe
     con sus anclas — helper invocado, tabla de decisión (`APPROVED → FIN`,
     `REQUEST_CHANGES` terminal, "no Step 4", "no fix loop"), barrera y USAGE reutilizados,
     PROMOTE no aplica, re-review por mismo label CON la regla de linaje (abajo); anclas
     NEGATIVAS: la sección no contiene `git commit`, ni `final — commit:`, ni promoción, y
     el frontmatter ya NO contiene "NOT for already-committed code"; los lanzamientos
     fenced llevan `TANDEM_CODEX_CWD`. **Y los templates**: ambos ficheros existen,
     start-range con `{{EXTRA}}`, DIFF autoritativo, lecturas ancladas a B y el contrato
     `VERDICT:` completo; resume-range con `{{NOTES}}`; negativas en ambos: ni
     `UNCOMMITTED` ni `git diff HEAD` (la regresión al framing de pipeline).
4. **Metadatos — orquestador tras la implementación:** plugin.json → 0.22.0, CHANGELOG,
   BACKLOG (M15 → hecha), fila de la cola, README (fila de la skill actualizada con el
   modo rango).

## Key decisions & tradeoffs

- **Helper testeable, no prosa** (redirigido en ronda 1): validación de rangos, bootstrap
  y namespaces son comportamiento de git — la lección exacta de plan-approve.sh; un
  contrato estático sobre prosa habría dejado el flujo real sin probar.
- **`range-review-<label>` y `log/ranges/`:** disjuntos POR CONSTRUCCIÓN de `cr-<slug>` y
  del scan de status — no por convención que un slug legal pueda violar.
- **Código circundante anclado a B:** el diff no es el programa; leer el checkout actual
  revisaría la versión equivocada en el caso de uso primario (checkout en main, rango de
  una feature). `git show <shaB>:` es obligatorio en el contexto, no un caveat.
- **REQUEST_CHANGES terminal:** fuera del pipeline los hallazgos son el entregable; un
  loop de fixes sobre commits ya hechos sería reescritura de historia o trabajo sin gate.
  El re-review es una invocación nueva del helper sobre el rango actualizado, mismo hilo.
- **Sin registro terminal ni promoción:** `final — commit:` es la prueba de que un RUN DE
  PIPELINE cerró; un rango no cierra nada. PROMOTE=1 tampoco aplica — una segunda clase de
  registro versionado sin gate contaminaría la primera.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/review-range.sh` | Nuevo — validación/resolución del rango, bootstrap, contexto |
| `skills/review/SKILL.md` | Sección "Range mode" con tabla de decisión propia |
| `tests/review-range.test.sh` | Nuevo — comportamental contra repos temporales |
| `tests/skill-range-contract.test.sh` | Nuevo — contrato estático de la sección |
| `skills/review/prompts/start-range.tpl` · `skills/review/prompts/resume-range.tpl` | Nuevos templates de rango |
| `tests/skill-review-background-contract.test.sh` | Mode-aware: grupos pipeline y rango validados por separado (conteos exactos, background/barrera/CWD por grupo) |
| `tests/skill-turn-effort-contract.test.sh` | Mode-aware: el nudge de rango con su target `range-review-` propio, low-effort igual |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `README.md` | v0.22.0 — orquestador |

## Acceptance & proof

- Una rama committeada obtiene review completa de Sol con veredicto, desde un repo sin
  `.tandem/` previo, sin exigir árbol sucio ni tocar el pipeline: helper → contexto con
  DIFF inline byte-exacto y lecturas ancladas a B → lanzamiento con barrera y USAGE →
  veredicto informado y FIN.
- Rango inválido/vacío/malicioso → 64/2/65 del helper, sin turno gastado.
- Cero colisiones con el pipeline: claves y logs disjuntos por construcción (asertado);
  /tandem:status no lista ni recomienda nada sobre ranges.
- La sección de la skill no contiene camino alguno a commit/promoción (anclas negativas).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Contratos existentes sobre review/SKILL.md:** seis tests estáticos la escanean; DOS
  requieren cambio explícito (background-contract exige hoy exactamente 2 lanzamientos
  reales + 1 nudge en TODO el fichero, y turn-effort exige el target literal `cr-<slug>`
  en cada nudge — ambos pasan a validar los grupos pipeline y rango por separado, con las
  mismas garantías por grupo); el resto queda intacto por construcción (prosa sin
  wrappers, CWD en fenced). La suite completa es el PROOF.
- **Diffs enormes inline:** el contexto puede crecer con rangos grandes; se documenta en
  la skill (rangos acotados, o dividir) sin límite duro en v1.
- **Repos sin git/objetos parciales:** el helper falla 65 con el stderr de git visible.

## Out of scope

- Integración positiva con /tandem:status (los ranges son invisibles para status en v1;
  una vista propia sería otra mejora).
- Promoción a docs/reviews/ en modo rango (decidido: nunca).
- Loop de fixes sobre rangos (el re-review por mismo label es el único camino).
- Cambios en codex-start/resume (la mecánica existente basta).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Helper o solo docs?** → Helper testeable (redirigido en ronda 1; el pre-registro
   "sin cambios de código" del borrador resultó insostenible con la evidencia del
   red-team — misma clase de corrección que la vía Workflow de M6).
2. **¿README?** → Orquestador, con los metadatos.
3. **¿PROMOTE en rango?** → Nunca (fuera del pipeline no hay registro versionado).
4. **¿Rama?** → `tandem/review-range` apilada sobre `tandem/critical-opus-effort` (cierre
   de la cadena Cola 2), aprobada con `plan-approve.sh`.
5. **¿Versión?** → 0.22.0; metadatos del orquestador tras la implementación.
