# Review: status-skill (v0.19.0)

- **Fecha:** 2026-07-31
- **Plan:** docs/plans/status-skill.plan.md (M11 del backlog; tarea 1/4 de la Cola 2 —
  borrador inicial del enjambre ultracode, arbitrado por el orquestador)
- **Rama:** tandem/status-skill, desde main v0.18.0 (primera de la cadena de la Cola 2).
  Aprobación vía `plan-approve.sh` (commit del plan 3cae823; main intacta).
- **Gate:** lint: OK (shellcheck 0.10.0 pineado) · typecheck: n/a (bash) · tests: 64
  passed, 0 failed (+4 ficheros de test) · proof: OK (`bash tests/verify.sh` → VERIFY OK)
- **Modo:** autónomo; implementador: Claude Opus 5 (tandem:implementer),
  IMPLEMENTATION_COMPLETE en t1 + 1 continuación de review (t2)
- **Tokens del run:** plan-review 4 rondas — in 6 981 373 · out 94 372; code review 2
  rondas — in 2 511 653 · out 38 088; implementación: n/a (transporte opus). Todas las
  rondas Sol lanzadas EN BACKGROUND (contrato M10, dogfood desde el día uno).

## Plan review — 4 rondas → APPROVED (6 → 4 → 1 → 0)

Ronda 1 (3 P1 + 3 P2, ACCEPTED): contrato de test imposible (la skill debía nombrar los
wrappers que el test prohíbe → ancla genérica + negativas solo en bloques ejecutables); un
commit post-plan no prueba completitud Y el merge legítimo borra la rama — el estado de
ESTE repo hoy habría hecho retroceder los 7 runs completados → registro terminal
`final — commit: <sha>` escrito por review Step 4; `next:` sin las dos pausas de gate
humano; raíz doble por evidencia; gate multilínea real; promesa de solo-lectura probada
con snapshots. Ronda 2 (2 P1 + 2 P2): contradicción de fixtures 6/9; `branch -D` sobre
rama checked-out; selección de raíz POR SLUG y unión en listado; validación del sha por
descendencia (uno válido pero ajeno no verifica). Ronda 3 (1 P1): con rama viva, tip ==
sha exigido (un descendiente = commits post-gate = contradictorio). Ronda 4: APPROVED.

## Code review — 2 rondas → APPROVED (hilo fresco)

Ronda 1 (3 Major + 1 Minor, ACCEPTED — arreglados vía 1 continuación del implementador):

- **CR1 Major — el script fallaba en un entorno realmente read-only:** los heredocs de bash
  materializan TEMPORALES; el revisor EJECUTÓ el script en su sandbox y obtuvo un informe
  falso-válido con exit 0. Fix: cero heredocs/here-strings/mktemp (arrays + pipes +
  expansión de parámetros), test dinámico con TMPDIR/HOME no escribibles + aserción
  estructural mutation-verificada (bash cae a /tmp: el test dinámico solo no bastaba —
  honestidad del implementador registrada).
- **CR2 Major — un registro de aprobación corrupto activaba "plan aprobado"** y el `next:`
  recomendaba implementar, saltándose el gate humano. Fix: PA_PRESENT/PA_VALID con los 4
  campos sha40, rama, modo y coherencia git (primer parent == source_head); la fixture se
  reconstruyó con commits reales para lograr 4 kills de mutación independientes.
- **CR3 Major — la validación terminal certificaba el PROPIO plan_commit como run
  completo** (prefijos hex con basura + is-ancestor no estricto). Fix: línea exacta en
  columna 0 + sha40 completo + descendencia ESTRICTA.
- **CR4 Minor — la raíz git salía de PWD:** desde otro repo validaría contra el repositorio
  equivocado. Fix: raíz git del candidato dueño de la evidencia; refs de todas las raíces
  en el listado; test desde repo ajeno.

Ronda 2: APPROVED — "No encontré regresiones ni hallazgos nuevos accionables."

Dogfood: el propio script reportó ESTE run en vivo (`fase: code review · next:
/tandem:review status-skill (retomar)`) durante la continuación.
