# Review — implement-write-audit (M25, v0.33.0)

- **Fecha:** 2026-08-30
- **Plan:** `docs/plans/implement-write-audit.plan.md` (M25 — auditoría de
  escrituras en implement + hook anti-install para Opus; origen: informe de campo
  2026-08-21, hallazgo A2 + enmienda E-A2)
- **Rama:** `tandem/implement-write-audit` off `main` (base 5d41880, v0.32.0)
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean) · typecheck: n/a (bash) ·
  tests: 88 passed, 0 failed (incluye los tres tests nuevos) · actionlint: OK ·
  proof (`bash tests/verify.sh`): OK — ejecutado por el orquestador
- **Plan review (Sol, xhigh, hilo persistente):** 5 rondas → `VERDICT: APPROVED`
- **Code review (Sol, xhigh, hilo fresco sin contexto previo):** 1 ronda →
  `VERDICT: APPROVED`, cero hallazgos («los cambios implementan fielmente el plan,
  incluidos los archivos nuevos, lifecycle guard/censo, reset seguro, auditoría,
  hook y cobertura de aceptación»)
- **Transporte de implementación:** Sol a xhigh (`TANDEM_CRITICAL=1`; el agente
  crítico Opus no estaba registrado en la sesión y degradar en silencio está
  prohibido — vía Sol elegida por gate humano), sandbox `workspace-write` sin red.
  Un solo turno, `IMPLEMENTATION_COMPLETE`, sin desviaciones ni leftovers.
  CHANGELOG, version bump, fila del backlog y este registro: trabajo del
  orquestador (prohibidos al implementador por template, asignación explícita del
  plan tras el hallazgo P2-5 de la R1).
- **Smoke en vivo:** `implement-audit.sh check` sobre este mismo intento (legado,
  sin censo) → `WARN: census missing` + `AUDIT: OK`, exit 0 — la degradación
  honesta del caso legacy, observada de verdad antes del commit.

## Hallazgos y disposiciones (condensado)

### Plan review — 5 rondas, 14 hallazgos, todos aceptados

- **R1 `REVISE` — 3 P1 + 5 P2, todos ACEPTADOS:** (P1-1, el hallazgo capital) el
  marcador propuesto — `status: "running"` del JSON de intento — tiene semántica
  POR-TURNO: pasa a `terminal` entre turnos y dejaba el hook desarmado justo
  durante verificación y testing, con carrera al arrancar → guard dedicado
  `.tandem/state/implement-audit/<slug>.guard` con tres transiciones nombradas
  (snapshot ANTES de lanzar / close en el handoff / reset), crash fail-closed sin
  caducidad; (P1-2) el snapshot en resumes re-basaba intentos legacy y el reset no
  poseía el censo → snapshot solo en intento fresco, identidad
  (`plan_hash`/`base_head`/`work_root`) dentro del censo y validada, ambos resets
  amplían su alcance; (P1-3) el porcelain a secas colapsa directorios untracked →
  `--porcelain=v1 -z -uall --no-renames` + `quotePath=false`; (P2-1) deps de
  `package.json` también contra el INDEX (stagear no está impedido); (P2-2) el
  PROOF podía pasar con las integraciones ausentes → contract test de la skill +
  validación de forma/bit/entry-point del hook; (P2-3) censo por NOMBRES, no
  recuentos (purge-and-repopulate con el mismo cardinal); (P2-4) gramática del
  hook por segmentos (cubre `npm --prefix app install`); (P2-5) release metadata
  al orquestador.
- **R2 `REVISE` — 3 hallazgos ACEPTADOS:** (P1-1) `codex-reset.sh` usa
  `target_key`, no el slug — el mapeo se especifica exacto (slug solo de targets
  `docs/plans/<slug>.plan.md`) con test behavioral de slugs adyacentes; (P1-2) un
  `node_modules` aparecido de CERO era invisible → el censo registra también el
  conjunto de directorios (vacío incluido) y un directorio nuevo es violación;
  (P2-1) `git diff HEAD` deja ciego el estado staged+copia-restaurada → dos vistas
  `git diff --cached` + `git diff` en el Step 3.
- **R3 `REVISE` — 1 hallazgo ACEPTADO:** dos `mv` atómicos no hacen atómico el PAR
  censo+guard y la idempotencia ingenua podía devolver éxito sobre un snapshot
  parcial → los tres estados parciales quedan definidos (censo-sin-guard se
  recupera hacia el lado protegido si la identidad coincide, 65 si no;
  guard-sin-censo se conserva bloqueando) y el reset borra censo-primero.
- **R4 `REVISE` — 2 P2 de cobertura ACEPTADOS:** el par completo con identidad
  ajena → 65 entra en la matriz; el ORDEN del reset se verifica sobre el reset
  real con un shim de `rm` que registra los argv (censo → estado del intento →
  guard-último), no pre-sembrando el estado a mano.
- **R5 `APPROVED`** — «the revised plan is implementable and its proof now covers
  the identified lifecycle failures».

### Code review — 1 ronda

- **R1 `APPROVED`** — cero hallazgos (ni críticos, ni mayores, ni menores).
