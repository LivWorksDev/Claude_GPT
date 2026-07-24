# Review — opus-implementer (v0.9.0)

- **Fecha**: 2026-07-24
- **Plan**: `docs/plans/opus-implementer.plan.md`
- **Rama**: `tandem/opus-implementer` (base `main`, commit del plan)
- **Testing gate**: bash -n: OK · jq parse (plugin+marketplace): OK · doctor smoke (default→opus / sol→sol / gemini→FAIL+exit≠0 / vacío→FAIL+exit≠0): OK · proof: PROOF-OK

## Plan review (Sol, hilo persistente) — 5 rondas → `VERDICT: APPROVED`

12 hallazgos arbitrados (2×P1, 10×P2). Condensado por tema:

- **Frontera del implementador opus** (P1): sin sandbox OS ni restricción, un subagente hereda tools/MCP de la sesión → agent type restringido `tandem:implementer` con allowlist mínima; Bash queda como riesgo residual documentado. Mantener Sol de default fue rechazado como decisión humana explícita (rollback = `TANDEM_IMPLEMENTER=sol`).
- **Worktree** (P1): el subagente no hereda el cwd correcto → ruta absoluta fijada en el prompt y verificación/gate anclados.
- **Estado durable** (P2×4): espejo en `.tandem/state/implement-claude/` con identidad del intento; `plan_hash` = blob commiteado (los checkboxes de la working copy no invalidan continuaciones); ramas de reutilización sin ambigüedad; guard de liveness observacional — `SendMessage` prohibido como sonda (reanudaría al agente).
- **Fallback de modelo** (P2): preflight fail-closed de `CLAUDE_CODE_SUBAGENT_MODEL` + auto-atestación informativa.
- **Rigor del PROOF** (P2×3): smoke real de doctor con salida y exit status separados; jq sobre ambas descripciones del marketplace; greps por archivo. Lanzar subagentes reales como smoke se rechazó (no determinista, coste de modelo).
- **Coherencia de release** (P2): marketplace.json incluido.

## Code review (Sol, hilo fresco sin contexto) — 3 rondas → `VERDICT: APPROVED`

Ronda 1 (3 Major + 1 Minor, todos FIXED):

- Clean-tree gate incondicional bloqueaba el recovery de un PARTIAL → attempt-state gate antes del clean-tree gate; árbol sucio esperado en resume validado.
- Worktree contradictorio (checkout + `worktree add -b` de la misma rama, heredado de v0.8) y cwd no persistente entre llamadas Bash → in-place/worktree mutuamente excluyentes; cada comando del subagente con `cd … && …`/rutas absolutas/`git -C`.
- Guard de liveness sobre el namespace equivocado (task-list vs background tasks) → `task_id` + `status` running/terminal persistidos; estado ausente = ambiguo, nunca inactivo.
- Selector vacío tratado como opus en doctor → default solo si unset; vacío = FAIL.

Ronda 2 (1 Major + 1 Minor, ambos FIXED):

- Baseline de seguridad no durable (memoria de conversación) → `base_head` + `remote_snapshot` inmutables en el JSON; la verificación de rama/HEAD/remotos funciona tras recovery.
- Deriva documental (CHANGELOG/README describían protocolos superados) → alineados.

Ronda 3: sin hallazgos nuevos; el reviewer re-ejecutó proof, smokes, jq, bash -n y `git diff --check` de forma independiente → APPROVED.

## Resultado

Implementación: Sol (transporte v0.8 vigente durante esta run) + takeover del orquestador para versión/CHANGELOG (el contrato del implementador prohíbe release) + fixes de review aplicados por el orquestador. Desviación menor aceptada: Step 5 endurece el skip de review con `TANDEM_CRITICAL=1`.
