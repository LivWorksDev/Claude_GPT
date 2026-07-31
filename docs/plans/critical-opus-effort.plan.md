# Plan: critical-opus-effort — TANDEM_CRITICAL con efecto real bajo Opus

**Backlog:** M6 (P2/M) · **Fecha:** 2026-07-31 · **Modo:** autónomo (Cola 2, tarea 3/4)
**Reescrito íntegro en ronda 2 del red-team:** la vía Workflow del borrador original queda
RETIRADA (incompatible con el protocolo de identidad/continuación del transporte opus);
este documento es la única fuente.

## Goal

El tool Agent no expone effort por llamada, así que `TANDEM_CRITICAL=1` bajo el transporte
default (opus) no altera nada del implementador — documentado como limitación desde v0.9.0.
Pero el effort de un subagente SÍ sale del frontmatter de su definición (el frontmatter effort existe desde Claude Code 2.1.78, pero el VALOR `xhigh` solo desde
2.1.111 — el umbral del gate es 2.1.111): un agent type crítico con `effort: xhigh` da a
`TANDEM_CRITICAL=1` efecto REAL bajo Opus conservando intacto el protocolo existente
(SendMessage, attempt state durable, recovery). Complemento: mensajes de effort EFECTIVO
(nunca promesas falsas bajo overrides) y la recomendación de `TANDEM_IMPLEMENTER=sol` como
alternativa donde CRITICAL ya subía a xhigh.

## Approach

1. **`agents/implementer-critical.md` (nuevo)** — copia EXACTA de `agents/implementer.md`
   (mismo `model: opus`, misma allowlist `Read, Edit, Write, Glob, Grep, Bash`, mismo
   cuerpo byte a byte: prohibiciones git, sin red/MCP/agentes anidados, contrato de
   informe y sentinels) con SOLO estas diferencias de frontmatter: `name`
   (`implementer-critical` → agent type `tandem:implementer-critical`), `description`
   (menciona el uso bajo CRITICAL) y `effort: xhigh` (el campo nuevo que da el efecto).
2. **`skills/implement/SKILL.md`**:
   - Step 1 transporte opus: bajo `TANDEM_CRITICAL=1`, el agent type usado es
     `tandem:implementer-critical`; sin CRITICAL, `tandem:implementer` como siempre. La
     frase "TANDEM_CRITICAL=1 cannot raise effort for an Agent-tool Opus subagent" se
     sustituye por la semántica nueva.
   - **Preflight nuevo, junto al de CLAUDE_CODE_SUBAGENT_MODEL:** bajo `TANDEM_CRITICAL=1`
     + opus, si `CLAUDE_CODE_EFFORT_LEVEL` está definida con valor ≠ `xhigh`, STOP
     accionable (su precedencia documentada pisaría el frontmatter — el intento correría
     como "crítico" a effort degradado sin saberlo).
   - **Schema del attempt state:** el JSON durable gana `"agent_type"` — el agent type
     REALMENTE usado en el lanzamiento. Contrato de migración/validación: enum exacto
     {`tandem:implementer`, `tandem:implementer-critical`}; campo AUSENTE (estado legacy
     pre-0.21) = `tandem:implementer`, normalizado y persistido ANTES de cualquier
     recovery; valor desconocido o no-string = jamás despachar — STOP en interactivo,
     FAILED en autonomous. **Resolución del tipo EFECTIVO** (selección por flag y
     recovery por registro necesitan una regla única): tras validar la identidad del
     intento se deriva UN `effective_agent_type` — el REGISTRADO para toda
     recovery/continuación; el seleccionado por `TANDEM_CRITICAL` solo para intentos
     FRESCOS — y TODOS los gates críticos (preflight de EFFORT_LEVEL, gate de versión) se
     aplican al tipo EFECTIVO, no al flag del entorno. Si el modo pedido por el entorno
     DIFIERE del registrado (CRITICAL=1 sobre un intento normal/legacy, o sin flag sobre
     un intento crítico): consentimiento explícito en interactivo, terminal FAILED en
     autonomous — ninguna dirección se resuelve en silencio. Si el tipo registrado no está
     disponible, degradar exige el mismo consentimiento/FAILED — nunca una degradación
     silenciosa de un intento crítico.
3. **`skills/run/SKILL.md`** — la matriz de riesgo actualiza su línea CRITICAL: bajo opus
   ahora hay efecto real (implementer-critical/xhigh); `TANDEM_IMPLEMENTER=sol` sigue como
   alternativa equivalente. Sin promesas incondicionales: la frase remite al effort
   efectivo que muestra el doctor.
4. **`scripts/codex-doctor.sh` — efforts EFECTIVOS y gate de versión:**
   - Rama sol + CRITICAL=1: mostrar el effort EFECTIVO (`TANDEM_IMPLEMENT_EFFORT` definido
     pisa el xhigh de CRITICAL — con override, la línea lo dice y CUALIFICA: nada de
     "raises to xhigh" cuando correrá a `low`).
   - Rama opus + CRITICAL=1: (a) aviso/FAIL accionable si `CLAUDE_CODE_EFFORT_LEVEL` está
     definida ≠ xhigh (espejo del preflight); (b) **gate de versión ≥ 2.1.111** (el
     frontmatter effort llegó en 2.1.78, pero el VALOR `xhigh` solo en 2.1.111 — evidencia
     del changelog oficial): el doctor comprueba `claude --version` (binario `claude` en
     PATH); versión menor o indeterminable → FAIL accionable bajo CRITICAL+opus ("el
     effort xhigh del agente crítico no tendrá efecto; actualiza Claude Code o usa
     TANDEM_IMPLEMENTER=sol"), silencio sin CRITICAL. Comparación por campos en bash puro,
     stub de `claude` en tests con los límites exactos (2.1.110 → FAIL, 2.1.111 → ok).
     **El mismo gate se ESPEJA en el preflight de implement/SKILL.md**: /tandem:implement
     es invocable directamente sin pasar por el doctor del pipeline — un gate solo-doctor
     sería bypasseable.
5. **Tests.**
   - `tests/agent-critical-parity.test.sh` (nuevo): parsea AMBOS ficheros de agente —
     frontmatter normalizado y CUERPO COMPLETO; exige `model: opus` en ambos, tools
     idénticas, cuerpo byte a byte idéntico, y que las ÚNICAS diferencias de frontmatter
     sean la allowlist explícita {name, description, effort}; NOMBRES exactos asertados
     (`name: implementer` en el normal, `name: implementer-critical` en el crítico — el
     name es el identificador de invocación: un typo dejaría el agent type inexistente con
     la suite verde); `effort: xhigh` exacto en el crítico y AUSENTE en el normal. Un agente crítico que perdiera una prohibición del
     cuerpo falla el test.
   - `tests/skill-critical-contract.test.sh` (nuevo, estático): implement/SKILL.md ancla
     el uso de `tandem:implementer-critical` bajo CRITICAL, el preflight de
     `CLAUDE_CODE_EFFORT_LEVEL`, el `"agent_type"` en el schema JSON, el enum de
     validación con normalización legacy y la regla de recovery mismo-modo con
     degradación-consentida; run/SKILL.md sin promesas incondicionales; la frase vieja
     "cannot raise effort" ha desaparecido de implement (ancla negativa).
   - `tests/doctor-env-matrix.test.sh` (ampliar): sol + CRITICAL=1 +
     `TANDEM_IMPLEMENT_EFFORT=low` → la línea muestra `low` y ninguna promesa de xhigh;
     opus + CRITICAL=1 + `CLAUDE_CODE_EFFORT_LEVEL=medium` → FAIL; límites exactos del
     gate de versión con stub de `claude`: 2.1.110 → FAIL bajo CRITICAL+opus, 2.1.111 →
     ok, ausente/indeterminable → FAIL bajo CRITICAL+opus, todo silencioso sin CRITICAL.
   - El contrato estático ancla ADEMÁS: el gate de versión espejado en el preflight de
     implement (no solo doctor), la regla del effective_agent_type (recovery = registrado;
     fresco = flag) y la política de mismatch en AMBAS direcciones.
6. **Metadatos — orquestador tras la implementación:** plugin.json → 0.21.0, CHANGELOG,
   BACKLOG (M6 → hecha), fila de la cola. docs/ARCHITECTURE.md y README (limitación v1 de
   CRITICAL) los actualiza el orquestador en el mismo commit — los contratos estáticos
   siguen limitados a skills+scripts.

## Key decisions & tradeoffs

- **Agent type con effort en frontmatter, no Workflow** (redirigido en ronda 1 con
  evidencia del harness): conserva TODO el protocolo — task_id de background Agent,
  SendMessage, recovery por identidad — y hace real el efecto; la vía Workflow habría
  requerido un transporte nuevo con resume propio e identidad incompatible.
- **Enum + normalización legacy del agent_type:** los intentos en vuelo creados pre-0.21
  no tienen el campo — tratarlos como `tandem:implementer` y PERSISTIR la normalización
  evita la recovery indeterminista; despachar un string arbitrario del JSON sería un
  vector de lanzamiento de agentes no previstos (por eso enum cerrado, fail-closed).
- **Gate de versión ≥ 2.1.111, espejado en el preflight:** sin él, la garantía central
  sería mentira en instalaciones antiguas (2.1.78–2.1.110 aceptan el frontmatter pero no
  el valor xhigh). Solo FALLA bajo CRITICAL+opus — el resto de usuarios no paga el check;
  y vive también en implement porque la skill es invocable sin doctor.
- **Paridad de cuerpo completo, no solo tools:** las prohibiciones de seguridad viven en
  el CUERPO del agente; un crítico que las perdiera con la allowlist intacta pasaría un
  test de solo-tools. Byte a byte con allowlist de diferencias de frontmatter.
- **Efforts efectivos:** `TANDEM_IMPLEMENT_EFFORT` (sol) y `CLAUDE_CODE_EFFORT_LEVEL`
  (opus) tienen precedencia real — mostrarla es la diferencia entre diagnóstico y
  propaganda.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `agents/implementer-critical.md` | Nuevo — copia exacta + effort: xhigh en frontmatter |
| `skills/implement/SKILL.md` | Selección por CRITICAL, preflights EFFORT_LEVEL + versión ≥ 2.1.111 (espejo), agent_type en schema + migración/validación + effective_agent_type |
| `skills/run/SKILL.md` | Matriz de riesgo actualizada, sin promesas incondicionales |
| `scripts/codex-doctor.sh` | Efforts efectivos cualificados + gate de versión ≥ 2.1.111 |
| `tests/agent-critical-parity.test.sh` | Nuevo — paridad frontmatter+cuerpo con allowlist de diffs |
| `tests/skill-critical-contract.test.sh` | Nuevo — contrato estático completo |
| `tests/doctor-env-matrix.test.sh` | Ampliar — efforts efectivos, EFFORT_LEVEL, versión |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/ARCHITECTURE.md` · `README.md` | v0.21.0 — orquestador, post-implementación |

## Acceptance & proof

- Con `TANDEM_CRITICAL=1` + implementer opus, el lanzamiento usa
  `tandem:implementer-critical` (effort xhigh real vía frontmatter) y el JSON durable
  registra `agent_type`; la recovery relanza el MISMO tipo; degradación = consent/FAILED.
- Estado legacy sin `agent_type` → normalizado a `tandem:implementer` y persistido antes
  de recovery; valor desconocido → STOP/FAILED, jamás despachado.
- El agente crítico es byte a byte el implementer salvo {name, description, effort} — la
  paridad de cuerpo la fija el test.
- Doctor: sol+CRITICAL+override muestra el effort efectivo sin prometer xhigh;
  opus+CRITICAL con `CLAUDE_CODE_EFFORT_LEVEL`≠xhigh → FAIL; Claude Code < 2.1.111 o
  indeterminable → FAIL bajo CRITICAL+opus (límites exactos: 2.1.110 FAIL, 2.1.111 ok),
  silencio sin CRITICAL — el mismo gate espejado en el preflight de implement.
- La frase "cannot raise effort" ha desaparecido; ninguna promesa incondicional queda.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Precedencias del harness cambiantes:** CLAUDE_CODE_EFFORT_LEVEL/frontmatter son
  contrato del harness, no de este repo; el gate de versión y los mensajes cualificados
  acotan el daño a "aviso desactualizado", nunca a promesa falsa.
- **Deriva entre los dos ficheros de agente:** cubierta por el test de paridad (cualquier
  edición futura de implementer.md que no se replique falla la suite).
- **Detección de versión frágil:** `claude --version` puede cambiar de formato; el parser
  falla hacia "indeterminable" → FAIL accionable solo bajo CRITICAL+opus.

## Out of scope

- Cualquier transporte Workflow (retirado en ronda 1).
- Cambiar el default (sin CRITICAL, `tandem:implementer` intacto).
- Verificación runtime del effort dentro del subagente (no existe; autoatestación).
- M15 y el resto del backlog.

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Vía para el efecto real?** → Agent type crítico con `effort: xhigh` en frontmatter
   (redirigido por el red-team con evidencia del harness; la pre-registrada vía Workflow
   resultó incompatible con el protocolo y se retira).
2. **¿Effort del crítico?** → `xhigh`, espejando lo que CRITICAL hace bajo sol; `max` se
   menciona en la skill como escalón manual disponible, no como default.
3. **¿Contratos estáticos sobre docs/?** → No; skills+scripts solamente (como hasta ahora).
4. **¿Rama?** → `tandem/critical-opus-effort` apilada sobre `tandem/ultra-semaphore`,
   aprobada con `plan-approve.sh`.
5. **¿Versión?** → 0.21.0; metadatos del orquestador tras la implementación.
