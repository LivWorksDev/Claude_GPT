# Plan: mcp-transport-implement — tercer y último salto de la Fase 2 (implement + image)

**Backlog:** M20c (último tercio del M20/L) · **Fecha:** 2026-08-03 · **Modo:**
interactivo · **Base:** main **0afd288** (v0.29.0, gate de tres ejes ya en vigor).

## Goal

`TANDEM_TRANSPORT=mcp` se habilita para los dos roles workspace-write — `implement` e
`image` — cerrando la matriz de roles de los wrappers: el case del gate pasa a los
CUATRO roles conocidos (cualquier otro valor → 64), el eje target de `review` (M21)
queda intacto, y la matriz de watchdog se completa por el modo de lanzamiento DOMINANTE
de cada rol: `implement` recibe 3600s (sus turnos corren en background como los de
review, y con frecuencia son los más largos del sistema), `image` conserva 540s (su
contrato es foreground para 1–3 assets, exactamente el caso de ask: el watchdog debe
clasificar ANTES del cap del Bash tool). La paridad de artefactos viaja por el camino
compartido probado en M20a/M20b — cero ramas nuevas; lo específico de este salto es que
los pins de ESCRITURA (sandbox workspace-write, `network_access=false`,
`writable_roots=[]`, approval never — las promesas de M2) queden probados sobre el call
frame MCP. El swarm de ultra queda FUERA con razón documentada: `codex-swarm.sh` no
tiene superficie de transporte — migrarlo es construir soporte nuevo en un tercer
script con mecánica propia (N servidores efímeros bajo el semáforo), no abrir un gate.

## Approach

1. **`scripts/_mcp.sh`:**
   - Gate de rol: el case cerrado pasa a `ask | review | implement | image`; cualquier
     otro valor → 64 nombrando el conjunto válido (ya no hay "hop" pendiente que
     citar). El eje target de review (M21) no se toca; `implement`/`image` no ganan eje
     target (sus targets son el plan path y topic labels — no existe la familia
     foreground-ajena que motivó M21).
   - Watchdog: literal nuevo `TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT=3600` (explícito
     por rol y anclable por sed, como el de review; NO se reutiliza el literal
     `_REVIEW` para implement — un literal por rol mantiene los contratos estáticos
     legibles). `mcp_timeout_validate`: `review` → `_REVIEW`, `implement` →
     `_IMPLEMENT`, `*` (ask, image) → el default foreground 540. Comentario: la matriz
     se decide por el modo de lanzamiento dominante del rol, no por su sandbox.
2. **`scripts/codex-start.sh` / `scripts/codex-resume.sh`:** solo cabeceras — el
   transporte sirve los cuatro roles (review solo targets del pipeline, M21;
   implement con watchdog wide; image foreground con 540).
3. **`skills/implement/SKILL.md` — armonización al contrato ejecutable + nota de
   opt-in (cero comandos tocados):** las TRES secciones de lanzamiento sol se
   armonizan al lenguaje EXACTO que `check_skill` exige — start y continue:
   `` `run_in_background: true` by default `` + la excepción
   `` foreground with `timeout: 600000` only for small plans `` + "announce it
   clearly before doing anything else" + la frase de barrera de la task-completion
   notification; el nudge: explícitamente "in the foreground". Armonización valiosa
   por sí misma: implement comparte la realidad de los >10 minutos y quedó fuera del
   contrato cuando M10 lo estandarizó para plan/review. SOBRE esa base, la nota mcp
   en la sección de start: bajo mcp el START va SIEMPRE en background (watchdog 3600
   > cap foreground de Bash; quien insista, baja `TANDEM_MCP_TIMEOUT_SECONDS`); las
   continuaciones son el híbrido exec-resume y conservan su criterio; los nudges
   siguen foreground.
4. **`skills/image/SKILL.md` — nota de opt-in (cero comandos tocados):** bajo mcp el
   contrato foreground de 1–3 assets se mantiene TAL CUAL — el default 540 está por
   debajo del cap precisamente para que el watchdog clasifique primero; para sets
   grandes en background, subir `TANDEM_MCP_TIMEOUT_SECONDS` explícitamente (la línea
   de narración muestra el valor armado). Follow-ups: híbrido exec-resume, sin cambios.
5. **`skills/ask/SKILL.md` + `skills/review/SKILL.md` (2 notas) — retoque de la frase
   de roles:** las notas dicen hoy "serves the roles `ask` and `review`"; pasan a
   nombrar el conjunto completo con la restricción de review ("every role —
   `review` only for its pipeline targets `cr-*`/`range-review-*`"). El ancla
   compartida del parity test migra con ellas (punto 8).
6. **`tests/mcp-transport-implement.test.sh` (NUEVO, comportamental con stub):**
   - Start `implement docs/plans/x.plan.md` bajo mcp → paridad de artefactos completa
     (t<N>.*, `USAGE:`, thread file verificado contra el stream, rollout realojado,
     meta `transport_effective: "mcp"`) y el call frame lleva los params de ESCRITURA:
     model `gpt-5.6-sol`, sandbox `workspace-write`, effort `high`, y el map `config`
     comparado como OBJETO COMPLETO contra el conjunto exacto de pins del rol —
     `sandbox_mode=workspace-write`, `sandbox_workspace_write.network_access=false`,
     `sandbox_workspace_write.writable_roots=[]`, `approval_policy=never`,
     `approvals_reviewer=user` (quien impide que un auto-review apruebe escapes) y el
     `web_search` OFF que `_pins.sh` fija exactamente en los roles de escritura
     (`network_access=false` NO gobierna la búsqueda nativa). Comparación de objeto
     entero, no lista de campos: un pin perdido O sobrante falla. Las promesas de M2
     sobreviviendo el transporte son LA prueba de este salto — y lo mismo para image.
   - `TANDEM_CRITICAL=1` → effort `xhigh` en el frame; `TANDEM_IMPLEMENT_EFFORT=low`
     gana sobre CRITICAL (la precedencia documentada, ahora sobre mcp).
   - Watchdog: narración `watchdog 3600s` para implement; resume híbrido con
     anti-fallback verde y meta `exec-resume`; `TANDEM_CODEX_CWD` absoluto en el frame.
   - Image: start bajo mcp → frame con sandbox `workspace-write` + effort `high` +
     narración `watchdog 540s` (el default foreground, ancla de la decisión de matriz).
   - Gate: rol desconocido (`bogus`) bajo mcp → 64 nombrando el conjunto válido, cero
     invocaciones, contador intacto.
7. **Los casos de gate que FLIPAN (bookkeeping explícito):**
   `tests/mcp-transport-ask.test.sh` pierde su caso `mcp + implement → 64` y
   `tests/mcp-transport-review.test.sh` pierde su caso `mcp + image → 64` (ambos roles
   pasan ahora). El caso de rol desconocido del punto 6 hereda la forma exacta
   (64 + cero invocaciones + contador intacto) para que el gate de rol siga teniendo
   cobertura negativa; la positiva vive en el test nuevo.
8. **`tests/mcp-transport-parity.test.sh`:** el contrato estático del watchdog gana el
   literal implement (3600, > foreground, == review por la misma razón de fondo) y el
   de image queda documentado como el foreground compartido; el ancla de la frase de
   roles migra a la redacción nueva y se extiende a las CUATRO skills que documentan
   el transporte (ask, review, implement, image).
9. **`tests/skill-review-background-contract.test.sh`:** `check_skill` se aplica
   también a `skills/implement/SKILL.md` (sus lanzamientos sol: start + continue +
   nudge, sin modo range) con `want_mcp=1` — la regla mcp anclada en su sección de
   start, resumes/nudges intactos. `skills/image/SKILL.md` queda FUERA del contrato de
   lanzamientos (su contrato foreground es distinto por diseño y su nota mcp queda
   anclada por el parity test); la exclusión se documenta en el comentario.
10. **Metadatos (orquestador, ANTES de lanzar la code review — lección M21), con la
    secuencia de declaración HONESTA:** plugin.json → 0.30.0 y CHANGELOG en el commit
    de M20c, pero el estado que ese commit escribe es "M20c hecha (v0.30.0) —
    **evidencia real pendiente**": ni la fila M20 del backlog se cierra ni
    ARCHITECTURE declara los wrappers completos ahí. El canario de M20b encontró un
    Major real que la verificación pre-merge no vio — la declaración de completitud
    es POSTERIOR a los canarios por diseño, no un descuido de orden.
11. **Runs reales post-merge (orquestador, decididos en entrevista) — condición
    BLOQUEANTE de la declaración de cierre:**
    (a) implement: una tarea pequeña REAL vía `TANDEM_IMPLEMENTER=sol` +
    `TANDEM_TRANSPORT=mcp` en una rama tandem de alcance mínimo — verifica escritura
    real en workspace, artefactos, realojo y el watchdog wide armado;
    (b) image: 1 asset mínimo real bajo mcp (coste asumido: un turno de imagen).
    Evidencia de ambos pegada a `docs/audits/fase2-mcp-parity.md`. SOLO ese commit de
    evidencia cierra la fila M20 (→ hecha) y declara en ARCHITECTURE los wrappers
    COMPLETOS; si un canario falla, el hallazgo entra al backlog y la Fase 2 queda
    honestamente abierta — exactamente el camino que M21 ya recorrió.

## Key decisions & tradeoffs

- **La matriz de watchdog se decide por el modo de lanzamiento dominante, no por el
  sandbox:** implement comparte con review el perfil background-largo (3600); image
  comparte con ask el perfil foreground-corto (540) aunque su sandbox sea de
  escritura. La alternativa (todos los workspace-write a 3600) rompería el contrato
  foreground de image: un cuelgue en un turno de 1 asset esperaría una hora en vez de
  ser clasificado a los 9 minutos, y el caso legítimo largo de image (sets grandes en
  background) tiene el override documentado.
- **Un literal por rol (`_IMPLEMENT` nuevo) en vez de reutilizar `_REVIEW`:** el valor
  coincide (3600) pero el contrato estático queda legible y cada rol puede divergir
  mañana sin renombrar nada. Coste: un literal más que anclar.
- **implement/image sin eje target:** el eje de M21 existe porque el rol review tiene
  una familia de lanzamiento foreground-legítima no migrada (plan reviews). implement
  e image no tienen familia equivalente: todos sus lanzamientos pasan por sus skills
  con el contrato mcp documentado. Añadirles eje target sería simetría vacía.
- **El swarm queda fuera:** cero superficie de transporte hoy; migrarlo = diseño nuevo
  (homes efímeros por seat × semáforo × concurrencia) en un script que no comparte el
  camino de los wrappers. Meterlo convertiría el cierre S/M en una L nueva. Se
  documenta en ARCHITECTURE como decisión, no como omisión.
- **Contrato de lanzamientos para implement sí, para image no:** implement tiene el
  mismo hazard foreground que review (planes pequeños) y su regla mcp merece el
  contrato ejecutable; image tiene el contrato INVERSO (foreground es lo correcto) y
  meterla en check_skill exigiría un perfil nuevo para anclar una regla que no
  existe — su nota queda anclada estáticamente por el parity test.
- **Metadatos antes de la code review:** la ronda extra de M21 la causó exactamente
  este orden invertido; se corrige el proceso, no solo el resultado.
- **CI prueba el CONTRATO, los canarios prueban el COMPORTAMIENTO:** se rechazó
  extender el stub con escritura observable de ficheros/assets — un artefacto escrito
  por el stub prueba que el stub escribe, no que el sandbox de codex o gpt-image-2 se
  comporten. El frame completo (objeto de pins entero) es el contrato verificable en
  CI; el comportamiento real es de los canarios, y por eso la declaración de cierre
  es bloqueante sobre ellos (no un stub que fabricaría la evidencia que dice tener).
- **La sección sol de implement se armoniza al contrato, no se le hace un checker a
  medida:** un checker implement-específico duplicaría el contrato para esquivar tres
  frases; el lenguaje estándar es correcto también para implement (misma realidad de
  >10 min) y su ausencia era deuda de M10, no una diferencia de diseño.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/_mcp.sh` | Case de rol completo (4 roles); literal `TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT=3600`; matriz en `mcp_timeout_validate` |
| `scripts/codex-start.sh` · `scripts/codex-resume.sh` | Solo cabeceras (cuatro roles + matriz) |
| `skills/implement/SKILL.md` | Armonización de las 3 secciones sol al contrato ejecutable + nota opt-in mcp en el start |
| `skills/image/SKILL.md` | Nota opt-in: foreground 1–3 assets intacto (540 < cap); override para sets grandes |
| `skills/ask/SKILL.md` · `skills/review/SKILL.md` | Frase de roles migrada al conjunto completo |
| `tests/mcp-transport-implement.test.sh` | NUEVO — paridad workspace-write, pins M2 en el frame, CRITICAL/effort, image, gate bogus |
| `tests/mcp-transport-ask.test.sh` · `tests/mcp-transport-review.test.sh` | Retiran sus casos de gate flipados (implement/image ya pasan) |
| `tests/mcp-transport-parity.test.sh` | Literal implement anclado; ancla de frase de roles en las 4 skills |
| `tests/skill-review-background-contract.test.sh` | check_skill sobre implement/SKILL.md con want_mcp=1; exclusión de image comentada |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` · `docs/ARCHITECTURE.md` | v0.30.0 — orquestador, ANTES de la code review |

## Acceptance & proof

- Con `TANDEM_TRANSPORT=mcp`: `codex-start.sh implement <plan>` (stub) produce paridad
  completa y el map config del call frame es EXACTAMENTE el objeto de pins del rol de
  escritura — `network_access=false`, `writable_roots=[]`, `approval_policy=never`,
  `approvals_reviewer=user` y `web_search` off incluidos, comparado como objeto entero
  (pin perdido O sobrante → fallo) — en implement e image.
- Las tres secciones sol de implement/SKILL.md pasan el contrato ejecutable
  (`check_skill` con want_mcp=1): start/continue con el lenguaje estándar de
  background+barrera, nudge explícitamente foreground, y la regla mcp en el start.
- `TANDEM_CRITICAL=1` → `xhigh` en el frame; `TANDEM_IMPLEMENT_EFFORT` gana sobre
  CRITICAL; el resume es el híbrido con anti-fallback verde y meta honesto.
- Watchdog: implement narra 3600s, image narra 540s, review sigue en 3600s y ask en
  540s; el override env gana en los cuatro; contratos estáticos re-anclados.
- Rol desconocido bajo mcp → 64 nombrando el conjunto válido, cero invocaciones,
  contador intacto; el eje target de review (M21) sigue intacto (casos existentes).
- Sin `TANDEM_TRANSPORT`: argv exec byte-idéntico (anclas existentes intactas).
- El contrato ejecutable cubre los lanzamientos sol de implement con la regla mcp en
  su start; plan/review quedan exactamente como estaban.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Workspace-write bajo un transporte nuevo es el salto de más riesgo de la Fase 2:**
  un desajuste de pins daría a un turno de escritura más permisos de los prometidos.
  Mitigación: los pins viajan por el MISMO map config genérico ya probado en dos
  roles, y el test nuevo los verifica campo a campo sobre el frame real del stub; el
  run real post-merge ejercita la escritura de verdad.
- **El flip de los casos de gate** (implement/image dejan de ser 64) puede perder
  cobertura negativa si se hace mal — el caso bogus hereda la forma exacta y el plan
  lo nombra como bookkeeping explícito.
- **La elicitation colgante (hallazgo d de M19) es más probable en roles de
  escritura** (apply-patch approvals): approval never viaja pineado y el watchdog es
  inescapable — pero 3600s de espera ante un cuelgue real en implement es un coste
  aceptado (la barrera background lo contiene; el override permite acortarlo).
- **Image bajo mcp con sets grandes en foreground** sigue siendo posible por error del
  orquestador — mismo perfil de riesgo que hoy bajo exec (el cap de Bash mata igual);
  la nota lo documenta y no se inventa un candado que exec tampoco tiene.

## Out of scope

- El swarm de ultra (`codex-swarm.sh`) — sigue exec por diseño; entrada de backlog
  propia solo si se demanda.
- Servidor MCP persistente (v2), `codex-reply` entre invocaciones, correlación de IDs
  del procesador oficial (límite declarado desde M20a).
- Cambios de comandos o flujo en las cuatro skills (solo notas); `_pins.sh` y el
  flujo exec intactos.
- doctor `--smoke` sobre mcp; drift-probe del map config (vive en CI de M19).
