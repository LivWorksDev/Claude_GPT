# Review: critical-opus-effort (v0.21.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/critical-opus-effort.plan.md (M6; tarea 3/4 de la Cola 2 —
  REESCRITO íntegro en el red-team: la vía Workflow del borrador original resultó
  incompatible con el protocolo de identidad y se retiró)
- **Rama:** tandem/critical-opus-effort, apilada sobre tandem/ultra-semaphore. Aprobación
  vía `plan-approve.sh` (commit del plan dccfdbd; main intacta).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 70 passed, 0 failed (+2 ficheros) ·
  proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5, IMPLEMENTATION_COMPLETE en t1; fixes
  de review aplicados por el orquestador.
- **Tokens del run:** plan-review 5 rondas — in 21 787 379 · out 156 237; code review 2
  rondas — in 2 715 767 · out 18 035; implementación: n/a (transporte opus).

## Plan review — 5 rondas → APPROVED (4 → 4 → 3 → 1 → 0)

Ronda 1: la vía Workflow pre-registrada era incompatible con el protocolo
task_id/SendMessage/recovery — REDIRECCIÓN al agent type crítico con `effort: xhigh` en
frontmatter (evidencia del harness); el modo elevado se perdía en recovery; promesas
"xhigh de verdad" falsas bajo overrides (TANDEM_IMPLEMENT_EFFORT pisa a CRITICAL en sol;
CLAUDE_CODE_EFFORT_LEVEL precede al frontmatter en opus); contrato de test genérico.
Ronda 2: el plan aún contenía las dos implementaciones → reescritura íntegra; enum +
normalización legacy del agent_type; **gate de versión** (el frontmatter effort existe
desde Claude Code 2.1.78); paridad de cuerpo completo. Ronda 3: **el valor `xhigh` existe
solo desde 2.1.111** (changelog) y el gate solo-doctor era bypasseable → umbral 2.1.111
espejado en el preflight de implement; `effective_agent_type` (recovery = registrado,
fresco = flag, mismatch → consent/FAILED); nombres exactos asertados. Ronda 4: umbrales
2.1.78 residuales en tabla/Acceptance. Ronda 5: APPROVED.

## Code review — 2 rondas → APPROVED (hilo fresco)

Ronda 1 (1 Major + 1 Minor, ACCEPTED — fixes del orquestador): los preflights críticos
corrían ANTES de leer el estado que determina el tipo efectivo — una recovery de intento
normal con CRITICAL=1 pararía como crítica, saltándose la ruta de consentimiento (→ el
gate 3 difiere ambos checks cuando existe estado durable y los aplica solo al tipo
resuelto; ancla de orden en el contrato); la matriz de ARCHITECTURE aún decía "solo sube a
xhigh bajo sol". Ronda 2: APPROVED — "No new findings."

Nota de proceso: el implementador registró una objeción legítima (la promesa sol de
implement sin cualificar quedaba fuera del scope del plan) que el orquestador cerró con la
cláusula de precedencia antes de la review.
