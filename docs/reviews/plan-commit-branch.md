# Review: plan-commit-branch (v0.12.0)

- **Fecha:** 2026-07-30
- **Plan:** docs/plans/plan-commit-branch.plan.md (M3 del backlog)
- **Rama:** tandem/plan-commit-branch (off main; el commit del plan 9a17af0 inauguró el
  flujo nuevo — main no recibió ningún commit durante el run)
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 51 passed,
  0 failed (+2 ficheros de test nuevos) · proof: OK (`bash tests/run.sh`) · verify.sh:
  VERIFY OK (tests + shellcheck + actionlint)
- **Modo:** autónomo (TANDEM_AUTONOMOUS=1); implementador: Claude Opus 5
  (tandem:implementer), IMPLEMENTATION_COMPLETE en t1 sin continuaciones

## Plan review — 5 rondas → APPROVED

Ronda 1 (REVISE, 4 P1 + 4 P2, los 8 ACCEPTED): contrato "implement/review-only" de
TANDEM_WORKTREE contradicho y fijado por test; base_head capturado en el checkout principal
→ falsos safety failures en worktree; gate 5 sin cubrir worktrees pre-existentes sucios;
igualdad de blob insuficiente como invariante de resume; plan trackeado (slug reutilizado)
rompía el mv; modo worktree como estado cross-fase sin derivar; PROOF solo estático (→ la
danza pasó de Markdown a `scripts/plan-approve.sh` con tests comportamentales); metadatos
asignados al implementador que los tiene prohibidos (→ orquestador).

Ronda 2 (REVISE, 3): el predicado "tip plan-only" aceptaba ramas con implementación previa
(→ estado durable `plan-approve/<slug>.json` como ancla); el guard de tracked rompía el
retry in-place (→ orientación antes de guards); transiciones interrumpidas sin rollback
(→ rollback total con plan preservado).

Ronda 3 (REVISE, 3): publicación del estado fuera de la transacción (→ pending atómico →
commit → finalización tmp+mv, con recuperación de pending concordante); colisión de nombre
`base_head` entre estados (→ renombrado a `source_head` en aprobación); idempotencia
worktree sin especificar (→ la ausencia del duplicado primario es válida cuando el plan del
worktree coincide con el blob).

Ronda 4 (REVISE, 1): dos referencias residuales a `base_head` que debían decir
`source_head` (→ corregidas). Ronda 5: APPROVED.

## Code review — 3 rondas → APPROVED (hilo fresco, sin memoria del plan ni de la implementación)

Ronda 1 (REQUEST_CHANGES, 1 Critical + 2 Major, los 3 ACCEPTED y arreglados por Fable):

- **CR1 Critical — rollback podía `rm -rf` un directorio ajeno:** ante un
  `.worktrees/<slug>` pre-existente no registrado, el fallo de `git worktree add`
  disparaba un rollback que lo destruía. Fix: flag de propiedad `WT_CREATED` (solo se
  deshace un worktree creado por este run) + guard temprano exit 65 antes de cualquier
  mutación. Test con fichero centinela.
- **CR2 Major — el resume worktree releía el blob committeado, no el fichero real:** un plan
  modificado/staged/borrado dentro del worktree pasaba como idempotente. Fix: fichero
  presente + `status --porcelain` del path vacío + `hash-object` == blob del tip. Tests de
  las tres derivas y del resume limpio posterior.
- **CR3 Major — re-attach documentado inalcanzable:** el resolver fail-closed corría antes
  del gate 6 que prometía re-attachear un worktree podado. Fix: el re-attach se hace en §0.0
  ANTES del resolver (path pre-existente sin registrar → STOP); gate 6 lo trata como error.

Ronda 2 (REQUEST_CHANGES, 1 Major ACCEPTED): el re-attach decidía el modo solo por
`TANDEM_WORKTREE`, pudiendo voltear en silencio el modo registrado de la aprobación
exactamente cuando el registry queda vacío. Fix: el campo `mode` del estado durable de
aprobación es autoritativo (mismatch → STOP, misma regla que plan-approve.sh); en resumes
el `worktree` del attempt state también debe concordar; contrato anclado en el test
estático. Ronda 3: APPROVED sin hallazgos restantes.
