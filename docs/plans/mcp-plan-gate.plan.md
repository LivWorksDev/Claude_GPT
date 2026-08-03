# Plan: mcp-plan-gate — el gate mcp del rol review se restringe a sus targets del pipeline

**Backlog:** M21 (P2/S) · **Fecha:** 2026-08-03 · **Modo:** interactivo · **Base:** main
**658ad77** (v0.28.0 + evidencia del run real de M20b).

## Goal

Cerrar el hallazgo Major del run real de M20b: el gate de `transport_resolve` autoriza
el ROL `review` completo bajo `TANDEM_TRANSPORT=mcp`, pero ese rol tiene TRES familias
de lanzamiento y solo dos están soportadas — la plan review de `tandem:plan` (target =
ruta del plan) conserva legítimamente su excepción foreground para planes pequeños, y
un `mcp` heredado del entorno la enrutaría por MCP con watchdog 3600s: el cap de Bash
(600s) la mataría antes de que el watchdog clasifique, perdiendo el turno con la quota
gastada. Vía elegida (a): el gate gana el eje TARGET — `mcp` + rol `review` exige un
target `cr-*` (pipeline) o `range-review-*` (range); cualquier otro, el plan path
incluido, responde 64 fail-closed nombrando la razón, en AMBOS wrappers y antes de
mover un byte de estado. Las plan reviews siguen en `exec`, que es donde su contrato
foreground es correcto; soportarlas bajo mcp queda como posible entrada futura de
backlog con su propio run. `ask` no se restringe (sus targets son topics libres) y
`implement`/`image` siguen → 64 por rol (M20c).

## Approach

1. **`scripts/_mcp.sh` — el único cambio de código:** `transport_resolve` pasa de
   `<role> <kind>` a `<role> <kind> <target>`. Tras el case cerrado de roles y ANTES de
   `mcp_timeout_validate` (el orden importa: un target no soportado debe responder su
   64 aunque el timeout también fuera inválido, y los tests de timeout deben poder
   usar un target válido), nuevo case solo para `role = review`:
   - `cr-* | range-review-*` → continúa.
   - Cualquier otro → `die "TANDEM_TRANSPORT=mcp supports review targets cr-<slug>
     and range-review-<label> only (got: '<target>') — plan reviews stay on exec; see
     docs/BACKLOG.md M21" 64`.
   El comentario de cabecera de la función documenta el tercer eje (transporte → rol →
   target) y por qué: el rol no distingue a sus tres llamantes, y el único con
   contrato foreground legítimo no está migrado.
2. **`scripts/codex-start.sh` / `scripts/codex-resume.sh`:** los dos call sites pasan
   el target — `transport_resolve "$ROLE_ARG" start "$TARGET"` (línea 39) y
   `… resume "$TARGET"` (línea 47). `$TARGET` ya está asignado en ambos puntos y el
   validador sigue corriendo antes de dependencias y de estado. Sin más cambios.
3. **`skills/plan/SKILL.md` — una nota corta, cero cambios de comandos:** junto al
   lanzamiento de la Round 1, documentar que `TANDEM_TRANSPORT=mcp` NO aplica a las
   plan reviews — un valor heredado del entorno responde 64 fail-closed en vez de
   arriesgar el turno foreground — y que el transporte del rol review vive en
   `tandem:review` (targets `cr-*`/`range-review-*`).
4. **`tests/mcp-transport-review.test.sh`:**
   - Caso nuevo de gate: `mcp` + `review` + target con forma de plan path
     (`docs/plans/x.plan.md`) → 64 en AMBOS wrappers (hilo sembrado para el resume),
     mensaje ancla ("supports review targets", "plan reviews stay on exec", "M21"),
     cero invocaciones codex (ni exec ni mcp) y contador de turno intacto — la misma
     forma exacta que los casos de rol implement/image.
   - El caso de override vacío migra su target `seeded` → `cr-seeded`: bajo el gate
     nuevo, `seeded` moriría por target ANTES de llegar a la validación del timeout
     que ese caso existe para probar. Los casos existentes `cr-demo`, `cr-override` y
     `range-review-m20b` quedan como cobertura positiva sin tocar.
   - Ancla de orden: con target inválido Y `TANDEM_MCP_TIMEOUT_SECONDS=` vacío a la
     vez, el error es el de target — el gate de flujo decide antes que la validación
     de parámetros.
5. **`tests/skill-review-background-contract.test.sh`:** solo el comentario del
   `want_mcp=0` de plan/SKILL.md — deja de decir "no es parte de este salto" y pasa a
   citar la decisión de M21 (el gate por target refuta esos lanzamientos, no hay regla
   mcp que anclar en plan). Cero cambios de lógica.
6. **Metadatos (orquestador):** plugin.json → 0.29.0, CHANGELOG, BACKLOG (M21 hecha),
   ARCHITECTURE (una cláusula en el párrafo de la Fase 2: el gate es transporte → rol
   → target).

## Key decisions & tradeoffs

- **Gate por target, no soporte de plan bajo mcp (vía (a), decidida en entrevista):**
  conserva el alcance declarado de M20b y es el cambio mínimo que elimina el hazard;
  la vía (b) —soportar plan oficialmente— añadiría superficie de contrato justo antes
  de M20c y obligaría a decidir también allí la tensión foreground de planes pequeños.
  Si el soporte se quiere algún día, es una entrada de backlog con su propio run.
- **El gate mira el prefijo del target CRUDO,** no el state key sanitizado: las skills
  pasan `cr-<slug>`/`range-review-<label>` literales y el plan path llega con barras.
  Un usuario podría nombrar un topic de ask `cr-loquesea` — irrelevante: el gate solo
  aplica al rol review, y un target review `cr-*` inventado a mano obtiene exactamente
  el transporte que pide, con los contratos del pipeline. El riesgo real (perder un
  turno foreground de plan) queda cerrado.
- **Simetría start/resume:** el gate corre idéntico en ambos wrappers, como el de rol
  — un resume de plan review con mcp heredado también responde 64. La skill de plan
  nunca exporta la variable, así que esto solo dispara con un entorno heredado, que es
  exactamente el vector del hallazgo.
- **Orden target → timeout:** los errores de flujo (qué lanzamientos existen bajo mcp)
  responden antes que los de parámetros (cuánto watchdog). Permite además que los
  casos de timeout usen targets válidos sin ambigüedad sobre qué 64 están probando.
- **Sin run real:** M21 endurece un gate con cobertura de stub completa; el requisito
  de "run real por rol" del backlog aplica a las migraciones de M20, no a este cierre.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/_mcp.sh` | `transport_resolve` gana el eje target (review: `cr-*`/`range-review-*`, resto → 64) |
| `scripts/codex-start.sh` | El call site pasa `"$TARGET"` (una línea) |
| `scripts/codex-resume.sh` | El call site pasa `"$TARGET"` (una línea) |
| `skills/plan/SKILL.md` | Nota corta: mcp no aplica a plan reviews (64 fail-closed) |
| `tests/mcp-transport-review.test.sh` | Caso de gate por target + migración `seeded`→`cr-seeded` + ancla de orden |
| `tests/skill-review-background-contract.test.sh` | Solo el comentario del `want_mcp=0` de plan (cita M21) |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/ARCHITECTURE.md` | v0.29.0 — orquestador |

## Acceptance & proof

- `TANDEM_TRANSPORT=mcp` + `review` + target `docs/plans/x.plan.md` → 64 en ambos
  wrappers, mensaje nombrando los targets soportados y M21, cero invocaciones codex,
  contador de turno intacto.
- Los flujos soportados no cambian: `cr-*` y `range-review-*` bajo mcp siguen
  produciendo la paridad completa de M20b (casos existentes en verde sin tocar).
- Con target inválido y timeout vacío simultáneos, responde el 64 de target.
- `ask` sigue sin restricción de target; `implement`/`image` siguen → 64 por rol.
- Sin `TANDEM_TRANSPORT`: cero cambios de comportamiento (el eje target solo existe
  dentro de la rama mcp del validador).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Un target legítimo futuro del rol review que no empiece por `cr-`/`range-review-`**
  quedaría fuera del mcp hasta ampliar el case — coste consciente del fail-closed: el
  case es un punto único y testado, y ampliar es una línea con su cobertura.
- **El mensaje de error es contrato de tests:** las anclas del caso nuevo deben citar
  fragmentos estables ("supports review targets", "M21") para no acoplarse a la
  redacción entera.
- **La migración `seeded`→`cr-seeded`** debe conservar el propósito del caso (probar el
  64 del timeout vacío, no el de target) — el ancla de orden existe precisamente para
  que esa distinción quede probada y no dependa de la casualidad del nombre.

## Out of scope

- Soportar plan reviews bajo mcp (vía (b)) — posible entrada futura de backlog.
- M20c (`implement`/`image`/swarm) y cualquier cambio del gate por ROL.
- Cambios de comandos o flujo en `skills/plan/SKILL.md` (solo la nota) y en
  `skills/review/SKILL.md` (cero cambios).
- Turnos de modelo reales: cobertura de stub únicamente.
