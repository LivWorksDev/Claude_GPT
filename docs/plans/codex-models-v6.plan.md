# Plan: codex-models-v6 — política de modelos Codex 6: Astra revisa, Sol implementa, Luna explora

**Backlog:** M35a (P2/M) · **Origen:** revisión del 2026-10-01; decisión del mantenedor
(«Astra para review adversarial y Sol para implementar») · **Fecha:** 2026-10-01 ·
**Modo:** interactivo (gates humanos) · **Base:** main **53fefd8** (v0.34.0 + backlog M35–M38).

## Goal

Todos los defaults de modelo Codex apuntan hoy a la generación 5.6: `gpt-5.6-sol` en los roles
review/ask, implement e image y en los tiers judge y worker de ultra, y `gpt-5.6-luna` en el
tier scout. El catálogo de la CLI instalada (0.157.1, `codex debug models`) ya describe esa
generación como «older generation» y ofrece la familia 6: `gpt-6-astra` («frontier
intelligence for the most demanding work»), `gpt-6-sol` («workhorse») y `gpt-6-luna` («fast
and affordable»), con los mismos niveles de effort que usa tandem (`low`…`xhigh`; Luna sin
`ultra`). Este plan mueve los defaults a la familia 6 con el reparto decidido por el
mantenedor: el asiento adversarial read-only (red-team del plan, code review y `ask`) y el
juez de ultra → `gpt-6-astra`; el implementador Codex (`TANDEM_IMPLEMENTER=sol`), la
generación de imágenes y el worker de ultra → `gpt-6-sol`; el scout de ultra → `gpt-6-luna`.
Los efforts no cambian. Los defaults pasan a vivir en UNA sola definición compartida por los
wrappers, el swarm, el doctor y el probe MCP (hoy están duplicados en diecisiete líneas de
cuatro scripts — 3 en `_common.sh`, 3 en `codex-swarm.sh`, 10 en `codex-doctor.sh` y 1 en
`mcp-probe.sh` —, y esa duplicación es lo que hace caro y arriesgado cada cambio de
generación). La documentación y
las descripciones de las skills dejan de afirmar que el revisor es GPT-5.6 Sol. Los
overrides `TANDEM_*_MODEL`/`TANDEM_*_EFFORT` siguen ganando, sin cambio de semántica.

Smoke previo con la CLI real (2026-10-01, en verde): start + resume de `ask` con
gpt-6-astra por los wrappers exec — hilo persistido, `USAGE:` emitida, formas
imprescindibles del stream intactas (`check-drift.sh`: deriva solo aditiva,
`usage.cache_write_input_tokens`); `doctor --smoke` con overrides: gpt-6-astra, gpt-6-sol
y gpt-6-luna responden.

## Approach

1. **`scripts/_models.sh` (nuevo) — la única fuente de los defaults.** Mismo contrato que
   `scripts/_pins.sh` (su cabecera, líneas 4-15): CERO side effects — define exactamente una
   función y nada más: sin `set`, sin `shopt`, sin traps, sin asignaciones de nivel
   superior y sin salida al sourcearlo. Ese contrato es el que permite que
   `codex-doctor.sh` lo sourcee sin `_common.sh` (el doctor no puede heredar
   `set -euo pipefail`). La función:

   ```bash
   # tandem_default_model <seat> — prints the default model of a seat, nothing else.
   # Seats: review (also serves ask) · implement · image · ultra-judge · ultra-worker
   # · ultra-scout. Unknown seat → no output, return 1.
   tandem_default_model() {
     case "${1:-}" in
       review | ultra-judge) printf '%s' 'gpt-6-astra' ;;
       implement | image | ultra-worker) printf '%s' 'gpt-6-sol' ;;
       ultra-scout) printf '%s' 'gpt-6-luna' ;;
       *) return 1 ;;
     esac
   }
   ```

   Bash 3.2 portable (sin namerefs ni arrays asociativos). La cabecera explica el porqué
   (una definición para wrappers, swarm y doctor; el próximo cambio de generación es una
   edición de un solo fichero) y que los efforts NO viven aquí (no cambian y siguen junto a
   cada rol).

2. **`scripts/_common.sh`** — sourcea `_models.sh` en el mismo bloque y con el mismo patrón
   que `_pins.sh` (líneas 181-190, `_TANDEM_SCRIPT_DIR`), con su directiva
   `# shellcheck source=_models.sh`. `resolve_role` (líneas 33-60) cambia SOLO el default de
   cada rol: `CODEX_MODEL="${TANDEM_REVIEW_MODEL:-$(tandem_default_model review)}"`, y lo
   análogo para `implement` e `image`. `resolve_role` se define antes del `source`, pero solo
   se LLAMA cuando `_common.sh` ya se cargó entero, así que la función existe en el momento
   de uso. El comentario del rol image («Sol at high on purpose…») sigue siendo cierto con
   gpt-6-sol y solo se ajusta si nombra la generación.

3. **`scripts/codex-swarm.sh`** — el `case "$TIER"` (líneas 132-148) usa
   `tandem_default_model ultra-judge|ultra-worker|ultra-scout` como default de cada tier
   (llega vía `_common.sh`, que el swarm ya sourcea en la línea 63). La tabla «Tier policy»
   de la cabecera (líneas 20-23) pasa a gpt-6-astra/xhigh, gpt-6-sol/high y gpt-6-luna/high.

4. **`scripts/codex-doctor.sh`** — sourcea `_models.sh` junto a `_pins.sh` (líneas 28-30) y
   las doce apariciones literales del default (en diez líneas) pasan a la función: las
   cuatro líneas de política mostrada (216, 285, 301 y 345 — esta última con los tres
   tiers) y los seis `smoke_add` (696-705). La lógica del
   smoke no cambia (deduplica modelos únicos); con los defaults nuevos pasa de dos turnos a
   TRES (astra, sol y luna), así que la cabecera del script («two with the default
   policy») y `skills/doctor/SKILL.md:42` se corrigen a tres con los nombres nuevos.

4b. **`scripts/mcp-probe.sh`** (hallazgo P1-1 de la ronda 1) — la línea 179
   (`MCP_MODEL="${TANDEM_REVIEW_MODEL:-gpt-5.6-sol}"`) es el cuarto sitio con default propio:
   pasa a `${TANDEM_REVIEW_MODEL:-$(tandem_default_model review)}`. El script ya sourcea
   `_common.sh` (línea 53), así que la función está disponible sin source adicional. Se
   retira entero en M36, pero hasta entonces debe respetar la fuente única y el barrido
   estático del punto 7; su test `tests/mcp-probe-verdicts.test.sh:62`
   (`model = "gpt-5.6-sol"` en el snapshot de config de la llamada 1) es de clase (a) y pasa
   al literal `gpt-6-astra`.

5. **Skills — modelos actualizados y vocabulario por ROL, no por modelo.** Hasta hoy la
   prosa llamaba «Sol» al revisor; con el reparto nuevo Sol es el implementador Codex y el
   revisor es Astra, así que mantener nombres de modelo como nombres de papel dejaría
   instrucciones falsas ahora y volvería a romperse en la próxima generación.
   - **`description` del frontmatter** de `ask`, `plan`, `review`, `run`, `implement`,
     `ultra` e `image`: nombran el asiento por su papel y el modelo por defecto actual
     (p. ej. plan: «the Codex red-team — GPT-6 Astra by default, read-only, persistent
     thread»; ultra: «Astra xhigh in judge seats, Sol high in standard analysis seats, Luna
     high in mechanical sweeps»; implement: «Codex GPT-6 Sol with TANDEM_IMPLEMENTER=sol»).
   - **Cuerpos de las skills:** el revisor se nombra por su papel («Codex», «the reviewer»,
     «the red-team»); el modelo solo aparece donde se documenta la política. El encabezado
     de ronda que el orquestador escribe en el log del plan pasa de
     `## Round <n> — Sol · tokens: …` a `## Round <n> — Codex · tokens: …`
     (`skills/plan/SKILL.md:56`); es el único encabezado que nombraba un modelo —
     review usa `— code review ·`/`— range review ·`. Verificado: ningún script lee ese
     nombre (`tandem-status.sh` y `statusline.sh` solo lo mencionan en comentarios), y
     `tests/status-phases.test.sh:166` lo usa como dato de un log sintético, sin aserción
     sobre el nombre.
   - El valor `TANDEM_IMPLEMENTER=sol` y la expresión «Sol transport» conservan su nombre:
     designan el transporte Codex de implementación, cuyo modelo ES gpt-6-sol. Por eso
     `tests/skill-implement-audit-contract.test.sh:21` («…before either Sol start transport
     launches») sigue siendo cierto y no se toca.
   - Los prompts que reciben los modelos (`skills/*/prompts/*`) no nombran ningún modelo
     (verificado con grep): no se tocan.

6. **README, ARCHITECTURE y manifiestos — solo la parte Codex.** README: la tabla de
   §«Política de modelos y permisos» (líneas 78-83), el ejemplo de statusline (línea 57) y
   las menciones del revisor como «Sol»; ARCHITECTURE: los nodos S1, B y S2 del diagrama
   mermaid (líneas 10, 17 y 21) y la prosa del revisor; `plugin.json` y `marketplace.json`:
   la parte Codex de sus descripciones. La parte Claude (Fable orquesta, Opus implementa)
   NO se toca aquí: es M35b, y mezclarlas haría este diff más difícil de revisar.

7. **Tests — dos clases, tratadas distinto.**
   - **(a) Tests que fijan el DEFAULT** (argv exacto de start/resume/swarm, política
     mostrada por el doctor, deduplicación de `--smoke`, tiers de swarm, call frames MCP
     cuando aserten el default): se actualizan al literal nuevo, ESCRITO en el test y nunca
     leído de `_models.sh` — un test que leyera la fuente no cazaría un cambio accidental
     del default. Candidatos por el grep (25 ficheros con `gpt-5.6`); la lista definitiva
     sale de la suite: un test de clase (a) es uno que falla con el cambio.
   - **(b) Tests que usan el literal como DATO arbitrario** (heartbeats y fixtures de
     statusline, `tests/lib.sh:226`, logs sintéticos): se quedan como están — no prueban el
     default, y moverlos añade churn sin señal.
   - **Nuevo `tests/models-defaults.test.sh`:** (1) el mapping completo de
     `tandem_default_model` (seis seats) y seat desconocido/vacío → rc 1 sin salida;
     (2) contrato sin side effects: sourcear `_models.sh` en un shell limpio no altera
     `set -o`, `shopt`, traps ni el conjunto de variables, y no imprime nada;
     (3) barrido estático: ningún `gpt-5.6` en `scripts/` ni `skills/` (los fixtures de
     `tests/fixtures/` quedan fuera: son capturas reales), y ninguna asignación de default
     de modelo fuera de `_models.sh` (`grep -E '_MODEL:-gpt-'` vacío en `scripts/`);
     (4) sin overrides, `resolve_role` de cada rol produce el modelo del mapping (vía
     `_common.sh` sourceado en subshell).

8. **Release metadata (orquestador, no implementador):** `plugin.json` 0.35.0, entrada de
   CHANGELOG y fila M35a del BACKLOG → `hecha (v0.35.0)`.

## Key decisions & tradeoffs

1. **Reparto por asiento.** review/ask (red-team del plan, code review, `ask`) → Astra y
   implementador Codex → Sol son decisión explícita del mantenedor. El resto lo infiere el
   orquestador por coherencia: el juez de ultra hace el mismo trabajo que el revisor →
   Astra; la imagen es un asiento de ESCRITURA que redacta el prompt de gpt-image y conduce
   el flujo chroma, el mismo perfil que «Sol para implementar» → Sol; el worker de ultra
   son asientos de análisis estándar → Sol, el «workhorse»; el scout son barridos
   mecánicos → Luna, «fast and affordable». Alternativa rechazada: Astra también en worker
   — el tier judge existe precisamente para los asientos que necesitan un juez frontera, y
   subir todos los workers multiplicaría el coste de cada enjambre.
2. **Efforts sin cambios** (review/ask xhigh; implement high, o xhigh con
   `TANDEM_CRITICAL=1`; image high; judge xhigh; worker y scout high). Astra admite hasta
   `ultra`, pero `ultra` es «maximum reasoning with automatic task delegation» — delegación
   automática dentro de un asiento read-only que debe razonar él mismo — y `max` dispara
   coste y latencia. Quedan como opt-in vía `TANDEM_REVIEW_EFFORT` y compañía.
3. **Fuente única en `_models.sh` como FUNCIÓN.** Alternativas: (a) constantes en
   `_pins.sh` — rompe su contrato escrito («exactly one function… no top-level
   assignments»); (b) constantes de nivel superior en un `_models.sh` — también serían
   asignaciones al sourcear, y un `TANDEM_DEFAULT_*` exportado por el usuario se
   confundiría con un mando; (c) dejar los literales duplicados — es el statu quo que
   convierte cada cambio de generación en una caza de sitios. La función mantiene el
   contrato del doctor y deja los mandos de usuario como únicos `TANDEM_*`.
4. **Vocabulario por rol en las instrucciones.** Alternativa: renombrar la persona
   Sol→Astra en toda la prosa — el mismo churn hoy y de nuevo en la próxima generación, y
   el log seguiría atando un papel a un modelo que el usuario puede sobreescribir.
5. **Los literales nuevos van escritos en los tests**, no leídos de `_models.sh`: la
   función de los tests de argv es cazar un cambio NO intencionado del default.
6. **Los modelos 5.6 siguen siendo utilizables** vía overrides; este plan no añade
   avisos de deprecación ni valida contra el catálogo — eso es M37.
7. **Tests MCP:** solo se actualizan donde fijan el default; no se añade cobertura MCP
   (el transporte se retira en M36).

## Files to touch

- `scripts/_models.sh` — NUEVO: `tandem_default_model`, cabecera con el contrato.
- `scripts/_common.sh` — source de `_models.sh`; defaults de `resolve_role` vía la función.
- `scripts/codex-swarm.sh` — defaults de tier vía la función; tabla «Tier policy».
- `scripts/codex-doctor.sh` — source de `_models.sh`; 4 líneas de política y 6 `smoke_add`;
  cabecera («three with the default policy»).
- `scripts/mcp-probe.sh` — default de `MCP_MODEL` (línea 179) vía la función.
- `tests/mcp-probe-verdicts.test.sh` — la aserción de la línea 62 al literal `gpt-6-astra`.
- `skills/ask/SKILL.md`, `skills/plan/SKILL.md`, `skills/review/SKILL.md`,
  `skills/run/SKILL.md`, `skills/implement/SKILL.md`, `skills/ultra/SKILL.md`,
  `skills/image/SKILL.md`, `skills/doctor/SKILL.md` — `description` y prosa por rol; el
  encabezado de ronda del plan; el texto del smoke.
- `README.md`, `docs/ARCHITECTURE.md` — política de modelos, ejemplo de statusline,
  diagrama mermaid, prosa del revisor (solo la parte Codex).
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — parte Codex de las
  descripciones (la versión la sube el orquestador).
- Tests de clase (a) entre los 25 con `gpt-5.6` (la suite los señala); `tests/models-defaults.test.sh` — NUEVO.
- `CHANGELOG.md`, `docs/BACKLOG.md` — orquestador.

## Acceptance & proof

1. Sin overrides, el argv exacto de cada lanzamiento lleva el modelo nuevo: review/ask →
   `--model gpt-6-astra` con effort xhigh; implement → `gpt-6-sol` high (xhigh con
   `TANDEM_CRITICAL=1`); image → `gpt-6-sol` high; swarm judge → `gpt-6-astra` xhigh,
   worker → `gpt-6-sol` high, scout → `gpt-6-luna` high. Pineado por los tests de argv
   existentes, actualizados.
2. Con `TANDEM_*_MODEL` definido, gana el override en cada rol y tier (los tests de
   override existentes pasan sin cambiar su semántica).
3. `codex-doctor.sh` muestra la política nueva; `--smoke` con defaults lanza exactamente
   tres turnos del stub (`gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`), deduplicados.
4. `tests/models-defaults.test.sh` en verde: mapping, rc 1 sin salida para seat
   desconocido, cero side effects al sourcear, barridos estáticos y `resolve_role`.
5. Ningún `gpt-5.6` en `scripts/` ni en `skills/`; ninguna `description` de skill nombra
   GPT-5.6; la tabla del README coincide con `_models.sh`; ningún encabezado de log
   prescrito por una skill nombra un modelo.
6. shellcheck y actionlint limpios (el `_models.sh` nuevo entra solo en el glob
   `scripts/*.sh` de `tests/verify.sh`).

**PROOF:** `bash tests/verify.sh`

## Risks

- **Un sitio de default olvidado** → los tests de argv lo cazan (fijan el default) y el
  barrido estático de `_MODEL:-gpt-` lo cierra.
- **`$(tandem_default_model …)` bajo `set -euo pipefail`:** una sustitución que fallara
  abortaría el wrapper; solo se usan seats conocidos y el test cubre los seis. Un seat mal
  escrito en el código sería un fallo inmediato y ruidoso, nunca un modelo vacío
  silencioso (el test (4) lo fija).
- **El doctor sourcea un segundo helper:** si `_models.sh` rompiera el contrato sin side
  effects, el doctor podría abortar a mitad; el test (2) lo fija.
- **La reescritura de prosa puede romper tests de contrato de skills** que fijan frases;
  se actualizan deliberadamente y en el mismo sentido, nunca debilitando una aserción
  (aflojar una aserción para que pase es un hallazgo).
- **Comportamiento real de Astra** (verbosidad, disciplina con la línea `VERDICT:`): el
  stub no lo prueba. Este mismo run, con Astra como red-team, es el canario; el
  nudge-turn existente cubre la ausencia de veredicto.
- **Coste:** un turno xhigh de Astra probablemente cuesta más que uno de 5.6-sol;
  aceptado por la decisión del mantenedor (los efforts no suben).

## Out of scope

- La parte Claude: Sonnet 5.5 implementa, Opus 5.5 orquesta, la deriva de
  `CLAUDE_CODE_SUBAGENT_MODEL` y las menciones de «Fable»/«Opus» → **M35b**.
- Retirar el transporte MCP → **M36** (sus tests solo se tocan donde fijen el default).
- Validar modelos y efforts contra `codex debug models`, regrabar los fixtures de NDJSON y
  la vigilancia de deriva local → **M37**.
- Los fixtures grabados (`tests/fixtures/**`): capturas reales, nunca se editan.
- Cualquier cambio de la política de efforts o de sandbox.
