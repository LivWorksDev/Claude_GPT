# Plan: mcp-transport-review — segundo salto de la Fase 2 (rol review sobre MCP)

**Backlog:** M20b (segundo tercio del M20/L) · **Fecha:** 2026-08-03 · **Modo:**
interactivo · **Base:** main **01b7ca4** (v0.27.0 + evidencia del run real de M20a).

## Goal

`TANDEM_TRANSPORT=mcp` se habilita también para el rol `review` — en sus DOS modos,
pipeline (`cr-<slug>`) y range (`range-review-<label>`), que comparten wrapper y gate —
con la misma paridad total de artefactos y contratos que M20a probó para `ask`:
mismos ficheros por turno, misma línea `USAGE:`, mismo heartbeat, mismos exit codes,
mismo guard anti-fallback, continuaciones por el híbrido `exec resume`. La pieza
nueva de diseño es el **watchdog por rol**: el default de 540s está atado al cap
foreground de Bash (600s) y dimensionado para `ask`; las reviews xhigh corren en
background precisamente porque superan los 10 minutos, así que `review` recibe su
propio default amplio (3600s) sin perder el carácter obligatorio e inescapable del
watchdog (hallazgo d de M19). `implement` e `image` siguen → 64 (M20c). Default
`exec` intacto byte a byte.

## Approach

1. **`scripts/_mcp.sh` — gate y watchdog, los dos únicos cambios de código real:**
   - `transport_resolve`: el gate pasa de `role != ask` a un case cerrado —
     `ask | review` continúan; cualquier otro valor bajo mcp → 64 con
     "supports roles ask and review in this hop (got: '<role>') — see
     docs/BACKLOG.md M20c". Misma posición (antes de dependencias y de mover
     estado), mismos efectos en ambos wrappers, contador de turno intacto.
   - Watchdog por rol: junto a `TANDEM_MCP_TIMEOUT_DEFAULT=540` se declara
     `TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW=3600` (literal top-level, anclable por el
     test estático con el mismo `sed`). `mcp_timeout_validate` recibe el rol desde
     `transport_resolve` y resuelve el default por rol; `TANDEM_MCP_TIMEOUT_SECONDS`
     sigue sobreescribiendo para cualquier rol con la misma validación fail-closed
     (entero positivo → si no, 64) Y ADEMÁS adopta la disciplina `${VAR+set}` de
     TANDEM_TURN_EFFORT/TANDEM_TRANSPORT: hoy `:-` trata definido-pero-vacío como
     unset (`scripts/_mcp.sh:97`) y el rechazo de vacío es inalcanzable — un
     `TANDEM_MCP_TIMEOUT_SECONDS=` caería en silencio al default nuevo de 3600s en
     vez de responder 64. Bug latente preexistente que este cambio cierra, con
     tests de override vacío contra ambos wrappers. La narración existente de
     codex-start.sh ("watchdog %ss") ya imprime el valor resuelto — sin cambios.
2. **`scripts/codex-start.sh` / `scripts/codex-resume.sh`:** sin cambios de código —
   los wrappers ya son transport-agnósticos y el cwd ya viaja absoluto
   (`mcp_turn_cwd` resuelve `TANDEM_CODEX_CWD`/PWD, así que worktrees y el pin de
   range funcionan por construcción). Solo se actualiza el comentario de cabecera
   que dice "role `ask` only in this hop".
3. **`skills/review/SKILL.md` — nota de opt-in, definida POR LANZAMIENTO (sin
   cambiar ningún comando):** `TANDEM_TRANSPORT=mcp` existe para este rol en ambos
   modos, default `exec`. La regla de background distingue los tres tipos de
   lanzamiento que el contrato ejecutable ya clasifica:
   - **Starts mcp** (pipeline Step 2 y range step 2 — los ÚNICOS turnos que arman
     el watchdog MCP): background SIEMPRE bajo mcp, sin excepción small-diff. El
     watchdog de review (3600s default) supera el cap foreground de Bash: un start
     foreground bajo mcp moriría a los 600s por la herramienta antes de que el
     watchdog clasifique — el turno se pierde con la quota gastada. Quien insista
     en foreground debe bajar `TANDEM_MCP_TIMEOUT_SECONDS` por debajo del cap.
   - **Resumes híbridos** (Step 3.3, range step 4): son turnos `exec resume` sin
     watchdog MCP — conservan el criterio existente EXACTO (background por
     defecto, foreground `timeout: 600000` solo para diffs pequeños).
   - **Nudges**: siguen en foreground (exec-resume a `low`, vuelven en segundos).
4. **`tests/mcp-transport-ask.test.sh`:** el caso de gate "mcp + review → 64" se
   MUEVE a `implement` (misma forma: rc 64 en ambos wrappers, cero invocaciones
   codex, contador de turno intacto) — el gate sigue cubierto, ahora sobre el rol
   que de verdad queda pendiente.
5. **`tests/mcp-transport-review.test.sh` (NUEVO, comportamental con stub):**
   - Start `review cr-<slug>` bajo mcp → paridad de artefactos
     (t<N>.prompt/reply/events/usage/meta, `USAGE:` en stderr, thread file con el
     id ecoado y verificado contra el stream, rollout realojado) y el call frame
     lleva los params del ROL: model `gpt-5.6-sol`, sandbox `read-only`, effort
     `xhigh` en el map config — la prueba de que los pins de review viajan.
   - meta.json del start: `transport_requested: "mcp", transport_effective: "mcp"`;
     el resume posterior continúa ESE hilo por el híbrido (`exec … resume` en el
     argv del stub, anti-fallback verde, meta `effective: "exec-resume"`).
   - Watchdog: la narración del start review dice `watchdog 3600s` (default por
     rol); un start ask en el mismo test sigue diciendo `watchdog 540s` (ancla de
     no-regresión); `TANDEM_MCP_TIMEOUT_SECONDS=7` gana sobre el default de rol.
   - Forma range: lanzamiento `review range-review-<label>` con
     `CLAUDE_PROJECT_DIR` pineado a una raíz distinta del cwd y `TANDEM_CODEX_CWD`
     a un tercer directorio → el estado del hilo aterriza bajo la raíz pineada y el
     frame de `tools/call` lleva el cwd ABSOLUTO pedido (el pin de la skill
     funciona bajo mcp).
   - Gate: `mcp + image` → 64 (el otro rol excluido, mismo assert que implement en
     el test de ask).
6. **`tests/skill-review-background-contract.test.sh`:** el contrato ejecutable
   por lanzamiento se extiende — el clasificador distingue starts de resumes por
   el script del comando (`codex-start.sh` vs `codex-resume.sh`), y las secciones
   de start exigen la regla mcp (background siempre bajo mcp) además de sus
   asserts actuales; las secciones de resume y nudge quedan EXACTAMENTE como
   están. La regla vive aquí, no en un grep de fichero: un ancla file-level
   pasaría con la skill contradictoria (la excepción small-diff sobrevive en las
   secciones de resume legítimamente).
7. **`tests/mcp-transport-parity.test.sh`:** el contrato estático del watchdog se
   re-ata por rol — el default de ask (540) sigue atado al `timeout: 600000` de
   las skills foreground (ancla existente intacta); ancla NUEVA del literal
   review (3600). La coherencia del texto de la skill la garantiza el contrato
   ejecutable del punto 6, no un grep aquí.
8. **Run real post-merge (paso del orquestador, como en M19/M20a):** una range
   review pequeña REAL vía `TANDEM_TRANSPORT=mcp` sobre el propio commit de M20b:
   1 turno xhigh de start en background; un resume solo como nudge de verdict
   ausente, si toca. Si el verdict trae hallazgos, los hallazgos SON el entregable
   y la invocación termina — semántica range intacta. La evidencia del resume
   híbrido con rol review solo por el camino legítimo (Range step 4: commits
   nuevos, mismo label, `resume-range.tpl`), y es opcional: el camino de resume es
   role-agnóstico y M20a ya lo probó end-to-end. Líneas y artefactos pegados a
   `docs/audits/fase2-mcp-parity.md` — el backlog exige un run real por rol.
9. **Metadatos (orquestador):** plugin.json → 0.28.0, CHANGELOG, BACKLOG (M20b
   hecha), ARCHITECTURE (párrafo de estado de la Fase 2).

## Key decisions & tradeoffs

- **Watchdog por rol en el script, no en la skill:** review corre en background sin
  cap de Bash y sus turnos xhigh legítimos superan los 10 minutos — mantener 540s
  mataría el caso de uso principal del rol, y delegar el valor a la skill
  ("exporta `TANDEM_MCP_TIMEOUT_SECONDS` alto en cada lanzamiento") convierte un
  olvido de documentación en reviews muertas a los 9 minutos: fail-open en la
  práctica. El default por rol es fail-closed aunque el llamante no configure nada.
- **La tensión foreground queda en el contrato ejecutable, no en un candado del
  wrapper:** con 3600s de default, un start foreground de review bajo mcp muere
  por el cap de Bash (600s) antes de que el watchdog actúe. El wrapper no puede
  saber si corre bajo el Bash tool (no hay señal fiable), así que la regla vive en
  la skill Y en su contrato ejecutable por lanzamiento — solo los STARTS mcp
  pierden la excepción small-diff; los resumes híbridos son turnos exec y la
  conservan. En los caminos atrapables (EXIT/INT/TERM — el kill ordinario del
  Bash tool incluido) los traps acotan el daño: grupo segado, home y credencial
  borrados; se pierde el turno, no la higiene. Un SIGKILL escalado NO ejecuta
  traps — ese residuo es un riesgo residual nombrado en Risks, no una garantía.
- **3600s como valor:** cota holgada para un turno xhigh real (los observados en
  este repo: ~10–25 min) sin dejar un cuelgue por elicitation bloqueando la barrera
  background indefinidamente. Es una cota elegida, no medida — el override env
  existe para el caso extremo.
- **Ambos modos del rol a la vez:** pipeline y range lanzan por el MISMO
  codex-start.sh con rol review; separarlos exigiría un gate artificial nuevo que
  distinga targets, y dejaría la combinación range+mcp permitida pero sin
  cobertura. El coste real de incluir range es solo de tests.
- **Cero ramas nuevas en los wrappers:** la paridad por adaptador de M20a hace que
  review viaje por el camino compartido existente — M20b es esencialmente gate +
  watchdog + cobertura. Si un test de M20b revelara que algo del camino compartido
  era ask-específico de facto, eso es un hallazgo, no un parche silencioso.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/_mcp.sh` | Gate `ask\|review`; default de watchdog por rol (literal nuevo 3600) |
| `scripts/codex-start.sh` | Solo el comentario de cabecera ("ask only" → ask/review) |
| `scripts/codex-resume.sh` | Solo el comentario de cabecera |
| `skills/review/SKILL.md` | Nota de opt-in por lanzamiento: starts mcp background siempre; resumes híbridos y nudges intactos |
| `tests/mcp-transport-ask.test.sh` | El caso de gate review→64 se mueve a implement (misma forma) |
| `tests/mcp-transport-review.test.sh` | NUEVO — comportamental: paridad review, params del rol, watchdog por rol (+ override vacío → 64), forma range, gate image |
| `tests/skill-review-background-contract.test.sh` | Clasificador start/resume; las secciones de start exigen la regla mcp; resumes/nudges intactos |
| `tests/mcp-transport-parity.test.sh` | Contrato estático del watchdog re-atado por rol (literales 540/3600) |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/ARCHITECTURE.md` | v0.28.0 — orquestador |

## Acceptance & proof

- Con `TANDEM_TRANSPORT=mcp`: `codex-start.sh review cr-<slug>` (stub) produce los
  mismos artefactos que exec, con model/sandbox/effort del rol review en el call
  frame; `codex-resume.sh` continúa ese hilo por el híbrido con anti-fallback verde
  y meta honesto (`exec-resume`).
- Watchdog: review resuelve 3600s por default, ask sigue en 540s, el override env
  gana en ambos; definido-pero-vacío → 64 en ambos wrappers (nunca el default en
  silencio); el contrato estático ata los dos literales y el contrato ejecutable
  por lanzamiento impone la regla mcp en las secciones de start de la skill.
- `mcp` + `implement` → 64 y `mcp` + `image` → 64, en ambos wrappers, sin
  invocaciones codex y con el contador de turno intacto.
- Forma range: con `CLAUDE_PROJECT_DIR` y `TANDEM_CODEX_CWD` pineados a rutas
  distintas, el estado aterriza en la raíz pineada y el cwd del call frame es el
  absoluto pedido.
- Sin la variable: el argv de exec del stub es byte-idéntico al actual (anclas
  existentes intactas).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **3600 es una cota elegida, no medida:** un turno de review legítimamente > 1h
  moriría por el watchdog — mitigado por el override env y por el mensaje de
  timeout, que nombra la variable.
- **El caso foreground+mcp+review es una regla de contrato, no un candado:** un
  orquestador que la ignore pierde el turno a los 600s. En los caminos atrapables
  (EXIT/INT/TERM) los traps limpian grupo, home y credencial; el contrato
  ejecutable por lanzamiento evita que la regla desaparezca en silencio.
- **Residuo bajo SIGKILL:** un kill escalado (9) no ejecuta traps — pueden
  sobrevivir el home efímero con la credencial copiada y descendientes del
  servidor. Riesgo preexistente del transporte (M20a), no introducido aquí, y no
  ejercitable por un test de script (el cap del Bash tool tampoco); se documenta
  como residual en vez de prometerse una limpieza que ese camino no puede dar.
- **Mover el assert del gate (review → implement) podría perder cobertura** si se
  hace mal: se exige la misma forma exacta (64 + cero invocaciones + contador
  intacto) sobre los DOS roles aún excluidos, implement en el test de ask e image
  en el nuevo.
- **El camino compartido podría tener supuestos ask-específicos no vistos** (p.ej.
  en el realojo o el adaptador): los tests de paridad de review con el stub, y el
  run real post-merge con un turno xhigh de verdad, existen para aflorarlos.

## Out of scope

- M20c (`implement`/swarm, workspace-write) — sigue → 64.
- Servidor MCP persistente (v2), `codex-reply` entre invocaciones.
- Cambios en el flujo exec, `_pins.sh`, doctor `--smoke` mcp, drift-probe.
- Cualquier cambio de comandos o de flujo en `skills/review/SKILL.md` más allá de
  la nota de opt-in (los dos modos siguen funcionando idénticos bajo exec).
