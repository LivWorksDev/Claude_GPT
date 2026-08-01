# Plan: status-approval-proof — PA_VALID certifica los invariantes reales

**Backlog:** M16 (P2/S) · **Fecha:** 2026-08-01 · **Modo:** autónomo (Cola 3, tarea 1/3)
**Origen:** hallazgo Major 1 de la primera range review real (`range-review-cola2`).

## Goal

`tandem-status.sh` marca `PA_VALID=1` con checks estructurales y, con git, solo existencia
del commit registrado y first-parent == source_head; omite los dos invariantes que
`plan-approve.sh` sí impone (el commit toca SOLO el plan registrado, y contiene ese blob).
Peor: sin git disponible, el bloque git entero se salta y `PA_VALID` queda en 1 — un
registro corrupto plausible se presenta como "plan aprobado" con `next: /tandem:implement`.
Objetivo: con git, verificar el diff plan-only y el blob (espejo exacto de plan-approve);
sin git, un estado explícito **"aprobación no verificada"** que jamás produce fase "plan
aprobado" ni recomienda implementar. El script sigue estrictamente read-only.

## Approach

1. **`scripts/tandem-status.sh` — `analyze()`:**
   - En el bloque de coherencia git del registro PA (hoy ~421-432), tras el check de
     parent, dos checks espejo de `plan-approve.sh:345-347`:
     (a) `pa_files="$(git -C "$GIT_ROOT" diff-tree --no-commit-id --name-only -r
     "$PLAN_COMMIT" 2>/dev/null)"` y `[ "$pa_files" = "$PLAN_REL" ] || PA_VALID=0`
     (diff plan-only; comparación de string multilínea, bash 3.2 safe);
     (b) `git -C "$GIT_ROOT" rev-parse --verify -q "$PLAN_COMMIT:$PLAN_REL" >/dev/null
     2>&1 || PA_VALID=0` (blob presente). Solo plumbing de LECTURA vía `$( )` — cero
     heredocs/mktemp (el guard estructural de status-degradation lo vigila).
   - Nuevo flag `PA_UNVERIFIED=0` junto a `PA_VALID`: cuando los checks estructurales
     pasaron pero `HAVE_GIT != 1` o `GIT_ROOT` vacío → `PA_UNVERIFIED=1; PA_VALID=0`
     (rama else del guard que hoy salta el bloque en silencio).
   - `PLAN_COMMIT` se vacía solo cuando el registro es INVÁLIDO (ni valid ni unverified),
     para poder mostrar el sha registrado en el estado no verificado.
   - Fila `plan:`: tercer brazo — unverified →
     `· aprobación registrada (commit <short>) · SIN VERIFICAR (<razón>)`, donde
     `<razón>` es exactamente una de `sin git` | `fuera de un repositorio git` (la razón
     registrada abajo — nunca un literal fijo); "aprobado: commit" queda reservado al
     estado PROBADO.
   - Escalera de fases: peldaño nuevo `aprobación no verificada` inmediatamente debajo de
     "plan aprobado" — toda evidencia superior (implementación, gate, cr, terminal) sigue
     ganando, así el caso sin-git existente de status-phases ("commit final (no
     verificado)") permanece verde.
   - `case` de NEXT: caso nuevo para "aprobación no verificada" → verificación manual que
     nombra los dos invariantes; el texto NO contiene el literal `/tandem:implement`.
     **Override global de NEXT:** con `PA_UNVERIFIED=1`, el `next:` es SIEMPRE el mensaje
     de verificación manual, aunque evidencia superior (implementación parcial, gate…)
     determine la fase — la fase informa de lo que hay, pero mientras la aprobación no
     esté verificada ningún camino recomienda `/tandem:implement` ni `/tandem:review`.
   - **Readiness de la rama, separado de la validez del registro:** el readiness es
     FALSE salvo que la rama `tandem/<slug>` exista Y contenga `PLAN_COMMIT`
     (`git merge-base --is-ancestor`) — cubre la rama reseteada a source_head
     (`PLAN_COMMIT..branch` en 0 sin contenerlo) Y la rama borrada a mitad de run. El
     bloqueo aplica a TODO `next:` que continuaría el pipeline — tanto los caminos que
     recomiendan `/tandem:implement` como los que recomiendan `/tandem:review` (fases de
     gate y code review): sin readiness, next envuelto en ATENCIÓN ("la rama no contiene
     el commit de aprobación" / "la rama no existe"), jamás `/tandem:implement` NI
     `/tandem:review`. Las fases TERMINALES quedan intactas — una rama
     borrada tras merge con registro terminal sigue siendo legítima y distinguible porque
     la evidencia terminal gana la escalera.
   - **Razón del unverified separada:** `PA_UNVERIFIED` distingue `sin git` (HAVE_GIT!=1)
     de `fuera de un repositorio git` (git presente, GIT_ROOT vacío) — como ya hace la
     fila de rama — y la fila `plan:` renderiza la razón real.
   - Guard de ATENCIÓN: dispara solo con `PA_PRESENT=1` y ni valid ni unverified (un
     registro sin git no es "no legible").
   - Comentarios del bloque actualizados ("the same two facts" → los cuatro;
     "degraded, never invented" → "unverified, never certified").
2. **`tests/status-degradation.test.sh` — sección PA:**
   - Caso commit hermano EVIL con parent `$PA_SRC` que toca solo un fichero no-plan
     (`checkout -q -b evil "$PA_SRC"` + commit + volver + `branch -D evil`),
     `write_pa` con ese sha → NO aprobado (sin el fix, hoy daría "plan aprobado" — el
     test nuevo no es vacuo por construcción).
   - Caso commit hermano que toca el plan MÁS otro fichero → NO aprobado.
   - Caso blob: padre con `PLAN_REL` + hijo que SOLO borra `PLAN_REL`, registrado
     (hijo, padre) → NO aprobado (prueba el guard de blob aisladamente).
   - Caso rama reseteada: aprobación real + `git branch -f` de la rama tandem a
     source_head → el next NO contiene `/tandem:implement` y sí la ATENCIÓN de rama.
   - Caso rama borrada sin terminal: aprobación válida + `git branch -D` (sin registro
     terminal) → sin `/tandem:implement`, ATENCIÓN de rama; el control positivo
     post-merge existente (terminal con rama borrada) permanece intacto.
   - Caso rama rota CON evidencia superior de pipeline: aprobación válida + evidencia de
     gate o code review + rama reseteada/borrada → el next NO contiene ni
     `/tandem:implement` ni `/tandem:review`, y sí la ATENCIÓN de readiness (cierra la
     vía de una implementación que aplique el readiness solo al camino de implement).
   - Caso sin-git CON evidencia superior: registro real + estado de implementación
     parcial, PATH sin git → la fase refleja el peldaño superior pero el `next:` no
     contiene ni `/tandem:implement` ni `/tandem:review` (override global).
   - Caso fuera-de-repo: git presente, estado fuera de un repositorio → razón
     `fuera de un repositorio git` renderizada (no "sin git").
   - Caso registro REAL evaluado con el PATH sin git ya existente (NOGIT): exit 0, fase
     exacta `aprobación no verificada` (assert_matches ancorado), contiene
     "SIN VERIFICAR (sin git)", NO contiene "plan aprobado" / "aprobado: commit" /
     "/tandem:implement", stderr vacío.
   - **Fix de la aserción vacua existente** (~línea 182): el needle `next:` + 10 espacios
     jamás matchea porque `row()` (`printf '%-14s'`) rellena con 9 — pasa a
     "/tandem:implement" a secas. Descubierto verificando el código para este plan.
3. **`tests/status-phases.test.sh` — bloque "sin git":** añadir
   `assert_not_contains "aprobado: commit"` y `assert_file_contains
   "SIN VERIFICAR (sin git)"` — la degradación PA convive con el peldaño terminal que el
   test ya ancla; el resto del ladder queda como contrato de no-regresión.
4. **`skills/status/SKILL.md`:** fila `plan:` de la tabla y bullet nuevo en "What each
   desconocido means" documentando `aprobación no verificada` (sin git no hay prueba de
   diff plan-only ni blob; nunca "plan aprobado"; el next: exige verificación manual).
5. **`tests/skill-status-contract.test.sh`:** anchor positivo sobre el skill aplanado para
   "aprobación no verificada" (ata la prosa del skill al string real del script).
6. **Metadatos (orquestador, fuera de este plan):** plugin.json → 0.23.0, CHANGELOG,
   BACKLOG M16 → hecha, fila de la cola.

## Key decisions & tradeoffs

- **Dos flags (`PA_VALID` probado / `PA_UNVERIFIED` estructural-sin-git), no un
  `PA_STATE` string:** diff mínimo y los tests existentes sobre `PA_VALID` conservan su
  semántica. Tradeoff: dos booleanos codifican los estados y el guard de ATENCIÓN lleva la
  condición compuesta.
- **La fase se llama "aprobación no verificada" y evita el substring "plan aprobado"** a
  propósito: la aceptación es demostrable con negativos `grep -F`. Tradeoff: string de
  fase nuevo — el SKILL lo documenta y el contract test lo ancla.
- **NEXT se bloquea globalmente bajo unverified, la fase no:** la fase es descriptiva
  (qué evidencia hay); el next: es prescriptivo (qué hacer) — solo el segundo puede
  inducir a cruzar un gate sin verificar. Tradeoff: un run avanzado sin git muestra fase
  alta con next de verificación, deliberadamente conservador.
- **Espejo EXACTO de los comandos de plan-approve** (`diff-tree --no-commit-id
  --name-only -r`; `rev-parse --verify -q "sha:path"`), no un equivalente semántico:
  paridad por construcción. Efecto lateral correcto: un merge commit registrado da
  diff-tree vacío → inválido (un merge nunca es commit de aprobación).
- **NO se replica la igualdad de blob con la copia de trabajo** (plan-approve.sh:358-393):
  es precondición de RESUME, no invariante durable — un run legítimamente avanzado la
  viola y status certificaría en falso al revés.
- **El check de blob SÍ es testeable** (corrección del borrador): un commit padre que
  contiene `PLAN_REL` y un hijo que SOLO lo borra — registrado como (hijo, padre) — pasa
  el check de parent y el de diff plan-only (el borrado toca exactamente ese path), pero
  `commit:PLAN_REL` falla → prueba directa del guard de blob.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/tandem-status.sh` | Checks plan-only+blob, flag PA_UNVERIFIED, fila/fase/next/guard nuevos |
| `tests/status-degradation.test.sh` | 3 casos nuevos + fix de la aserción vacua |
| `tests/status-phases.test.sh` | 2 aserciones en el bloque sin-git |
| `skills/status/SKILL.md` | Documentar el estado "aprobación no verificada" |
| `tests/skill-status-contract.test.sh` | Anchor del estado nuevo |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.23.0 — orquestador |

## Acceptance & proof

- Con git: registro cuyo plan_commit es un commit REAL de mismo parent que toca solo un
  fichero no-plan → registro corrupto (fase "plan (borrador)", next envuelto en ATENCIÓN,
  sin `/tandem:implement`). Hoy ese caso da "plan aprobado": el test no es vacuo.
- Con git: commit que toca el plan más otro fichero → misma forma inválida.
- Sin git: el registro REAL escrito por plan-approve, evaluado con PATH sin git → exit 0,
  fase exacta `aprobación no verificada`, la salida no contiene "plan aprobado" ni
  "aprobado: commit" ni "/tandem:implement", stderr vacío.
- Sin git + evidencia de implementación parcial: la fase puede ser superior, pero el
  `next:` jamás recomienda `/tandem:implement` ni `/tandem:review` (override global).
- Con git: rama tandem reseteada a source_head tras aprobación real → sin
  `/tandem:implement`; el registro (hijo que borra el plan, padre real) → NO aprobado.
- Controles positivos intactos: registro real con git → `^fase: +plan aprobado$` y
  `/tandem:implement demo`; el ladder completo de status-phases verde, incluida la prueba
  read-only byte a byte (ro_snap) sobre cada invocación — los comandos nuevos son
  plumbing de lectura.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- Cambio del string de fase en el caso sin-git: status es advisory y nada del repo parsea
  la fase (la statusline no la lee), pero scripts de usuario sobre la salida lo notarían.
- `ro_snap` compara byte a byte árbol y refs: `diff-tree`/`rev-parse` son lectura pura,
  y cualquier comando git nuevo debe mantener esa disciplina.
- Wording script↔skill acoplado por el contract test: renombrar el estado exige tocar
  ambos (intencionado).
- El override global de NEXT bajo unverified es deliberadamente conservador: un usuario
  sin git en runs avanzados verá siempre el next de verificación manual.

## Out of scope

- M17 (`resolve_state_root` y el orden de raíces candidatas quedan intactos) y M18.
- Cambios a `plan-approve.sh` (sus invariantes son la referencia, no el paciente).
- Replicar la igualdad de blob con la copia de trabajo (precondición de resume).
- `statusline.sh`; metadatos (orquestador).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Dos flags o un enum de estado?** → Dos flags (diff mínimo, semántica de tests
   existente intacta).
2. **¿Arreglar la aserción vacua encontrada en status-degradation:182?** → Sí, en este
   plan: está en un fichero ya tocado, es un bug de test real y dejarla sería perpetuar
   una garantía falsa.
3. **¿Nombre de la fase nueva?** → `aprobación no verificada` (sin el substring
   "plan aprobado", para negativos exactos).
4. **¿Rama?** → `tandem/status-approval-proof` desde main 333236f, primera de la cadena
   Cola 3; aprobación con `plan-approve.sh`.
5. **¿Versión?** → 0.23.0; metadatos del orquestador tras la implementación.
