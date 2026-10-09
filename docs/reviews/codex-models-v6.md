# Review — codex-models-v6 (M35a, v0.35.0)

- **Fecha:** 2026-10-01
- **Plan:** `docs/plans/codex-models-v6.plan.md` (M35a — política de modelos Codex 6:
  Astra revisa, Sol implementa, Luna explora; origen: revisión del 2026-10-01 y decisión
  del mantenedor)
- **Rama:** `tandem/codex-models-v6` off `main` (base 53fefd8, v0.34.0 + backlog M35–M38;
  commit solo-plan a550904)
- **Modo:** interactivo, con los dos gates humanos — primer run del pipeline sobre la
  familia de modelos 6 y la CLI de Codex 0.157.1, precedido de un smoke real en verde
  (start + resume de `ask` con gpt-6-astra por los wrappers exec; `doctor --smoke` con
  gpt-6-astra/sol/luna; deriva del stream de eventos solo aditiva)
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean) · typecheck: n/a (bash) ·
  tests: 90 passed, 0 failed (incluye `tests/models-defaults.test.sh` nuevo) ·
  actionlint: OK · proof (`bash tests/verify.sh`): OK; tras añadir la release metadata se
  re-ejecutó `models-defaults` (barre `plugin.json`): OK
- **Plan review (Codex · gpt-6-astra, xhigh, hilo persistente):** 2 rondas →
  `VERDICT: APPROVED` (override `TANDEM_REVIEW_MODEL`, porque el default nuevo era
  justamente lo que el plan introducía)
- **Code review (Codex · gpt-6-astra, xhigh, hilo fresco sin contexto previo):** 1 ronda
  → `VERDICT: APPROVED`, lanzado SIN override: el banner `model=gpt-6-astra` salió del
  `_models.sh` nuevo, así que el cambio quedó verificado por su propio lanzamiento
- **Transporte de implementación:** subagente Claude `tandem:implementer` con **Sonnet 5.5
  como modelo por invocación** (decisión del mantenedor; M35b formaliza el frontmatter).
  Un turno, `IMPLEMENTATION_COMPLETE`, sin desviaciones de fondo. Auditoría M25:
  snapshot + guard antes del lanzamiento, `check` OK, `close` tras el gate verde.

## Hallazgos y disposiciones (condensado)

### Plan review — 2 rondas, 1 hallazgo, aceptado

- **R1 `REVISE` — 1 P1:** el default propio de `scripts/mcp-probe.sh:179` no estaba en el
  plan, y el barrido estático que el propio plan exigía (`gpt-5.6` y `_MODEL:-gpt-` en
  `scripts/`) habría hecho fallar el PROOF de forma determinista → ACCEPTED: punto 4b
  (default vía `tandem_default_model review`; el script ya sourcea `_common.sh`), recuento
  corregido a 17 líneas en cuatro scripts y `tests/mcp-probe-verdicts.test.sh:62` al
  literal `gpt-6-astra`.
- **R2 `APPROVED`:** P1-1 resuelto, sin hallazgos nuevos.

### Verificación del orquestador

- Diff completo leído (35 modificados + 2 nuevos): fiel al plan; ninguna aserción
  debilitada (varias reforzadas); baseline intacta (sin commits, stage ni mutación de
  remoto por parte del implementador).
- **Caso independiente añadido:** el barrido de `gpt-5.6` se extiende a los documentos de
  la política vigente (README, ARCHITECTURE, `plugin.json`, `marketplace.json`) — hueco
  que el propio implementador señaló; la historia (CHANGELOG, BACKLOG, plans, reviews,
  audits) queda fuera a propósito. Verificado en ambas direcciones: verde en el repo y
  rojo en una copia con `gpt-5.6-sol` inyectado en el README.

### Code review — 1 ronda, sin hallazgos

- **R1 `APPROVED`:** «No actionable findings» — implementa el plan, preserva la
  precedencia de los overrides, los efforts y las restricciones de sandbox; los tests
  actualizados conservan sus aserciones sustantivas. Comprobaciones propias del revisor
  en read-only con Bash 3.2: sintaxis, mapping, side effects del helper y 20 casos de
  rol/override.

## Residuales declarados

- El comportamiento real de Astra con la disciplina de `VERDICT:` no es testeable con el
  stub; este run (tres turnos de revisión, todos con veredicto parseable y sin nudges) es
  la primera evidencia real.
- El hook anti-install de M25 no estaba cargado en la sesión que orquestó el run (plugin
  0.30.0 cargado al arrancar); el repo no tiene dependencias JS y el `check` post-hoc sí
  corrió.
- Los fixtures grabados de `tests/fixtures/` siguen siendo capturas de la generación 5.6:
  se regraban en M37 junto a la vigilancia de deriva local.
