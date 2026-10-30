# Plan: council-effort-profiles — perfiles de esfuerzo del consejo, elegidos por el usuario

## Goal

Hoy `/tandem:council` exige *max* a los tres asientos y el preflight falla si algo queda por
debajo. Eso hace caro y lento un consejo cuya pregunta es exploratoria. Este cambio introduce
**tres perfiles de esfuerzo** — `exploratorio` (high), `estandar` (xhigh) y `critico` (max) —
que fijan **un único nivel para los tres asientos** (líder, Fable y Astra). Fable y Astra van
SIEMPRE al mismo nivel: no hay asimetría ni modo personalizado por asiento, y el suelo es
`high`. La skill recomienda un perfil a partir de la entrevista y el **usuario lo elige** en el
gate del brief (human in the loop). El perfil se congela con el brief, no cambia durante el run
ni en una recuperación, y queda **medido y no solo declarado**: el esfuerzo real de Fable se
verifica en su transcript (fallo si no coincide), el de Astra en el `meta.json` de cada turno, y
el del líder se mide en el transcript de la sesión y se muestra (sin bloquear).

## Approach

### 1. Los perfiles: una sola tabla, en `council.sh`

Una función `profile_level <nombre>` → `high|xhigh|max` (`exploratorio|estandar|critico`;
cualquier otro nombre → 64), y `profile_agent <nombre> <mode>` → el tipo de agente de Fable:

| Perfil | Nivel | Agente web | Agente offline |
|---|---|---|---|
| `critico` | max | `tandem:council-fable` | `tandem:council-fable-offline` |
| `estandar` | xhigh | `tandem:council-fable-xhigh` | `tandem:council-fable-xhigh-offline` |
| `exploratorio` | high | `tandem:council-fable-high` | `tandem:council-fable-high-offline` |

Los nombres de máquina van sin tilde (`estandar`, `critico`); la skill y los documentos
humanos los muestran con tilde.

### 2. Agentes de Fable: uno por nivel (`agents/`)

Cuatro ficheros nuevos: `council-fable-xhigh.md`, `council-fable-high.md` y sus gemelos
`-offline`. Son copias de los dos actuales en las que solo cambian `name`, `description`
(que nombra el nivel) y `effort`; `tools` sigue la regla de hoy (web / offline). El cuerpo es
idéntico byte a byte en los seis. Los dos ficheros actuales mantienen su nombre y siguen siendo
el nivel `max`, así los runs creados con 0.37 siguen recuperándose con el mismo `subagent_type`.

`fable_pin` pasa a recibir el nivel: lee la pareja de ese nivel, comprueba que los gemelos
coinciden en `model` y `effort`, que `effort` es el nivel pedido, y además que los SEIS
ficheros declaran el mismo `model` (un ID completo, nunca un alias). El pin de modelo sigue
viviendo solo en el frontmatter.

### 3. `council.sh profile <run-id> <perfil>` (subcomando nuevo)

Con el lock del run: si el brief ya está sellado → 65 («el perfil se congela con el brief»).
Si no, comprueba la **viabilidad** del perfil (las mismas comprobaciones que el preflight,
restringidas a ese nivel: catálogo de Astra, pin de la pareja de Fable de ese nivel y modo,
`CLAUDE_CODE_EFFORT_LEVEL`, `maxEffortLevel`); si no es viable → 1, nombrando cada causa.
Si lo es, escribe en `run.json`:

```json
"perfil": {"nombre": "estandar", "esfuerzo": "xhigh", "agente": "tandem:council-fable-xhigh", "elegido": "<utc>"}
```

(con el agente del modo del run). Es idempotente y reemplazable mientras el brief no esté
sellado. Imprime `PERFIL: estandar (xhigh)` y `FABLE_AGENT: tandem:council-fable-xhigh`.

`seal <run-id> brief` exige un perfil en `run.json` (1 si falta: «elige el perfil primero:
council.sh profile …»). `status` imprime siempre `PERFIL:` y `FABLE_AGENT:`, para que una
recuperación tras una compactación sepa qué `subagent_type` usar.

**El perfil congelado se re-verifica antes de cada turno.** Una recuperación puede ocurrir en
otra sesión, con otro entorno. Ejemplo: un run `estandar` recuperado con
`CLAUDE_CODE_EFFORT_LEVEL=high` pondría a Fable en high y a Astra en xhigh, y `capture`
acabaría en 65 después de haber gastado turnos. El helper `profile_env_check <nivel> <modo>`
reúne las comprobaciones de entorno del perfil:

- `CLAUDE_CODE_EFFORT_LEVEL`;
- `maxEffortLevel` en los settings en alcance;
- `TANDEM_COUNCIL_EFFORT`;
- el pin de la pareja de Fable de ese nivel;
- en `astra`, además, el catálogo de Codex.

Lo ejecutan `stage` (que precede a TODO turno de Fable y de Astra) y `astra` **antes de
tomar ninguna decisión ni reservar nada**: si falla → 1, nombrando cada causa, sin cambiar
`run.json` ni consumir intentos. `status` imprime `PERFIL_VIABLE: sí` o
`PERFIL_VIABLE: no — <causas>`. En una recuperación, la skill para y enseña las causas al
usuario si dice `no`. El perfil nunca cambia por esto: se corrige el entorno.

**Runs heredados.** Un `run.json` sin `perfil` cuyo brief ya está sellado (creado con 0.37) se
trata como `critico` en todas partes (helper `run_profile`), y lo marca como «implícito (run
anterior a los perfiles)» en `metadatos.md`.

### 4. Preflight: de «todo a max» a «perfiles viables»

El preflight se ejecuta antes de la entrevista, sin perfil todavía. Deja de exigir *max* y pasa
a calcular qué perfiles son viables:

- **(c) Astra.** El modelo debe estar en el catálogo (FAIL si no). Para cada nivel de perfil,
  ¿lo admite? (`supported_reasoning_levels`). Un nivel no admitido descarta su perfil.
- **`TANDEM_COUNCIL_EFFORT` definida (con cualquier valor) → FAIL**: el perfil decide el
  esfuerzo de Astra y una variable global lo contradiría en silencio.
  `TANDEM_COUNCIL_MODEL` sigue valiendo.
- **(g) Fable.** Los seis agentes deben existir y declarar el mismo modelo (FAIL si no). Cada
  pareja incoherente descarta su perfil.
- **(e) `CLAUDE_CODE_EFFORT_LEVEL`.** Si está definida, solo es viable el perfil cuyo nivel
  coincide con ella (pisa el frontmatter y la sesión). Vacía o con un nivel que no es de
  ningún perfil → FAIL.
- **(f) `maxEffortLevel` L** en cualquier settings en alcance → descarta los perfiles de nivel
  mayor que L (orden low < medium < high < xhigh < max). Un JSON ilegible sigue siendo FAIL.
- **`TANDEM_COUNCIL_PROFILE`** (nueva, disciplina `${VAR+set}`): definida y vacía o con un
  nombre desconocido → FAIL; con un perfil no viable → FAIL.
- **Resumen.** Imprime `perfiles viables: …` y, por cada perfil descartado, el motivo. Lo
  mismo para la cota de turnos, por perfil:
  `estandar: típico 2 × (2 + R) = 12 turnos en xhigh · techo …`.
- **FAIL si ningún perfil es viable.** `(d)`, `(h)` e `(i)` no cambian.

### 5. Astra al nivel del perfil (`cmd_astra`, `cmd_publish`)

`cmd_astra` lee el perfil congelado (1 si el brief no está sellado y no hay perfil) y, en un
turno sustantivo, exporta en el proceso hijo `TANDEM_COUNCIL_EFFORT=<nivel>` (que lo aplica
`resolve_role council` en cada start/resume). El recordatorio sigue en `low` con
`TANDEM_TURN_EFFORT`. `_common.sh` no cambia: su valor por defecto `max` solo se usa fuera del
consejo, que no existe.

`publish`, al publicar la respuesta de Astra de un intento, lee el `meta.json` del turno
sustantivo de ese intento. Si su `effort` no es el nivel del perfil → **65 (FAILED
terminal)**. Si falta el `meta.json` → anomalía visible «esfuerzo de Astra no verificado», sin
bloquear.

### 6. Fable: modelo, esfuerzo y tipo de agente medidos en el transcript (`capture`)

Medido en tres runs reales del consejo (2.1.299–2.1.310): cada línea `assistant` del
transcript de un subagente lleva `effort`, `perTurnEffort` y `attributionAgent`
(`tandem:council-fable`), y en los tres casos `effort` coincidía con el frontmatter (`max`).

**Diagnóstico con niveles distintos** (2026-10-30, Claude Code 2.1.312):

| Turno | Sesión padre | `effort` / `perTurnEffort` del subagente | `attributionAgent` |
|---|---|---|---|
| Lanzamiento | `medium` (58 líneas) | `xhigh` (frontmatter de `tandem:implementer-critical`) | `tandem:implementer-critical` |
| Continuación por `SendMessage` | `medium` | `xhigh` (mismo valor) | `tandem:implementer-critical` |

El campo refleja el frontmatter del subagente, no el de la sesión, también en las
continuaciones. El `output_file` es un symlink a `<sesión>/subagents/agent-<id>.jsonl`.
No está documentado, así que la política es la que eligió el usuario:

- `CAPTURE_JQ` recibe `$effort` y `$agent`. Una línea con `effort` presente y distinto del nivel
  del perfil, o con `attributionAgent` presente y distinto del agente esperado → **65, nada
  capturado** («otro esfuerzo / otro tipo de agente: FAILED terminal»), igual que hoy con un
  modelo distinto.
- Líneas sin `effort` o sin `attributionAgent` → la captura procede y queda marcada:
  `esfuerzo: "no verificado"` / `agente: "no verificado"`, que `metadatos.md` muestra como
  anomalía.
- La entrada de `captures[]` gana `esfuerzos: [...]` y `agentes: [...]` (valores únicos
  vistos). `--manual` deja ambos en «no verificado», como hoy hace con el modelo.
- `tests/fixtures/council/sanitize.jq` conserva `effort`, `perTurnEffort` y
  `attributionAgent` (los añade a su lista de claves que no se anonimizan). Así los fixtures
  reales nuevos guardan lo que Claude Code registra de verdad, y no un `"<x>"`. Se añade un
  fixture real saneado del diagnóstico anterior (subagente `xhigh` bajo una sesión `medium`,
  lanzamiento y continuación).

### 7. El líder: medido, mostrado, nunca bloquea

`leader_effort_json` deriva el transcript de la sesión del líder a partir de los
`output_file` de `run.json.agents[]`. Resuelve el symlink con un bucle `readlink` portable
(BSD): `…/<sesión>/subagents/agent-<id>.jsonl` → `…/<sesión>.jsonl`. Ahí cuenta las líneas
`assistant` que no son sidechain, **deduplicadas por `message.id`** (la última línea de cada
id), y las agrupa por `effort`. Si hay varias sesiones (reconstrucciones), las suma; si
ninguna se resuelve → «no medido».

**Ventana cerrada, con dos tramos:**

- **Intake**: desde `run.created` hasta el sello del brief. Solo informativo, porque entonces
  aún no había perfil y la skill corre a max en el turno de invocación.
- **Debate**: desde el sello del brief hasta el `publish` de la última ronda completa. Es el
  único tramo que se compara con el perfil.

Ambos límites son marcas de tiempo guardadas en `run.json`: el sello ya lleva la suya, y
`publish` guarda `publicado` si aún no lo hace. Por eso volver a ejecutar el recuento da el
mismo resultado, aunque la sesión siga trabajando después.

**Una sola instantánea.** `status --metadata` escribe `RUN_DIR/lider-esfuerzo.json` (escritura
atómica, en la misma llamada que `metadatos.md`), y `metadatos.md` se compone a partir de ese
fichero. `report` **lee esa instantánea y nunca vuelve a escanear el transcript**; sin
instantánea → «no medido». La instantánea entra en la huella de frescura del informe
(`report_digest`), así que si cambia, `status` dice `informe.html desactualizado`.

Nunca bloquea un paso. Una desviación en el tramo de debate se lista como anomalía («líder
fuera del nivel del perfil durante el debate: xhigh ×12 de 40 mensajes»).

### 8. `metadatos.md` e `informe.html`

- `metadatos.md`: una línea nueva tras «Creado…»: `- Perfil: estándar (xhigh: líder, Fable y
  Astra)` (o `crítico (max) — implícito, run anterior a los perfiles`). En la tabla de letras,
  el líder pasa de `/ max` fijo a `/ <nivel>` con la evidencia «autodeclarado y confirmado en
  el gate; medido: max ×352, xhigh ×5» (o «no medido»). La fila de Fable añade los esfuerzos
  medidos en lugar del literal «frontmatter». Anomalías nuevas: esfuerzo/agente no verificado,
  líder fuera de nivel y meta de Astra ausente.
- `report`: `FACTS.run.perfil` y `FACTS.seats[*].esfuerzos`. La plantilla muestra el perfil
  como una insignia en la cabecera y el nivel medido en las fichas de «Asientos y modelos».
  Nada más cambia en el informe.

### 9. La skill (`skills/council/SKILL.md`)

- **Description y párrafo del líder.** «Both at max» pasa a «al nivel del perfil de esfuerzo
  que el usuario elige (high, xhigh o max, el mismo para los tres asientos)».
- **Paso 0.** El preflight muestra los perfiles viables; la declaración del modelo del líder no
  cambia.
- **Paso 1, tras la entrevista y antes del gate**, la recomendación con una rúbrica fija:
  - `critico`: decisión irreversible o cara (dinero, reputación, legal) o el usuario pide la
    máxima profundidad.
  - `estandar`: decisión relevante pero reversible, o que necesita cifras con fuente
    contrastadas.
  - `exploratorio`: tantear una idea, decisión barata de revertir, o prioridad de rapidez o
    presupuesto.
  - En caso de empate, el más alto.

  Una AskUserQuestion con **solo los perfiles viables**, el recomendado primero con
  «(Recommended)», y en cada opción su nivel, su cota de turnos y la nota de coste (Fable puede
  facturar créditos de uso). Después, `council.sh profile <run-id> <perfil>`.
- **Gate.** El usuario aprueba el brief y confirma que la sesión corre en el modelo líder al
  nivel del perfil (`/effort <nivel>` o el selector; *max* no se acepta en `effortLevel`, los
  otros niveles sí). Luego `seal brief`.
- **Intake `auto`.** El perfil es `TANDEM_COUNCIL_PROFILE` si está definida y, si no,
  `critico`; queda anotado en **Supuestos**.
- **Pasos 2–5.** `subagent_type` es el `FABLE_AGENT` que imprimieron `profile`/`status` (nunca
  uno escrito a mano). La regla de no pasar `model` ni `effort` en la llamada al Agent se
  mantiene: el nivel vive en el frontmatter del agente del perfil.
- **Cota de turnos y líneas rojas.** «max-effort turns» pasa a «turnos al nivel del perfil».
  Línea roja nueva: «el perfil no cambia tras sellar el brief; para otro perfil, un run
  nuevo».
- El `effort: max` del frontmatter de la skill se mantiene: solo dura el turno de invocación
  (la entrevista), cuando aún no hay perfil.

### 10. Documentación y versión

`README.md` (tabla de comandos, fila de modelos y esfuerzos, sección del consejo y requisitos),
`docs/ARCHITECTURE.md` (si describe el pin de esfuerzo del consejo), `CHANGELOG.md` (0.38.0) y
`.claude-plugin/plugin.json` → `0.38.0`. Nota en el README: tras actualizar hace falta una
sesión nueva para que se registren los cuatro agentes nuevos.

## Key decisions & tradeoffs

1. **Un agente por nivel frente a `effort` en la llamada al Agent.** La llamada tiene
   prioridad sobre el frontmatter (≥ 2.1.292), así que dos ficheros bastarían. Pero no está
   documentado si el `effort` de la llamada persiste en las continuaciones por `SendMessage`
   (el `model` sí persiste). Un asiento que vuelva a su frontmatter a mitad del debate
   rompería la simetría. Seis ficheros con el cuerpo idéntico, vigilados por el test de
   paridad, cuestan poco; además, el tipo de agente queda como evidencia en el transcript
   (`attributionAgent`).
2. **Los ficheros actuales siguen siendo `max`, sin renombrarlos** (en vez de
   `council-fable-max`). Así los runs de 0.37 siguen funcionando, a cambio de una nomenclatura
   asimétrica.
3. **Un nivel único para los tres asientos, líder incluido.** El usuario fijó la simetría para
   Fable y Astra. Extenderla al líder hace que el perfil sea una sola palabra y un solo
   `/effort`. La alternativa (líder siempre a max) encarece el perfil exploratorio sin una
   razón clara.
4. **Un campo no documentado como prueba.** `effort` y `attributionAgent` del transcript.
   Desajuste = fallo; ausencia = anomalía visible, no fallo. Así una versión de Claude Code que
   quite el campo degrada la evidencia sin inutilizar el consejo.
5. **El líder se mide, pero nunca bloquea.** La sesión puede cambiar de esfuerzo a mitad del
   run y no se tira un debate de horas por eso: se muestra.
6. **El perfil se elige con un subcomando aparte (`profile`), no en `init`.** `init` corre
   antes de la entrevista y la recomendación depende de ella. Congelarlo con `seal brief`
   reutiliza el punto de no retorno que ya existe.
7. **`TANDEM_COUNCIL_EFFORT` pasa a ser FAIL en el preflight.** Rompe a quien la usara (p. ej.
   `ultra`), pero dejarla conviviendo con el perfil daría dos fuentes de verdad, y una
   anularía a la otra en silencio. `ultra` deja de ser elegible en el consejo.
8. **El preflight informa de los perfiles viables en vez de fallar**, salvo que no haya
   ninguno. Un `maxEffortLevel: xhigh` corporativo deja de bloquear el consejo entero: solo
   bloquea `critico`.

## Files to touch

- `scripts/council.sh`: cabecera y uso (`profile`, `TANDEM_COUNCIL_PROFILE`),
  `profile_level`, `profile_agent`, `run_profile`, `fable_pin <nivel>`, `cmd_preflight`
  (perfiles viables), `cmd_profile` (nuevo), `cmd_seal brief` (exige perfil), `cmd_astra`
  (exporta el nivel), `cmd_publish` (verifica el meta de Astra), `CAPTURE_JQ` + `cmd_capture`
  (esfuerzo y agente), `leader_effort_json` (nuevo), `METADATA_JQ` / `write_metadata`,
  `cmd_status` (`PERFIL:` / `FABLE_AGENT:`), datos de `report`.
- `agents/council-fable-xhigh.md`, `agents/council-fable-high.md`,
  `agents/council-fable-xhigh-offline.md`, `agents/council-fable-high-offline.md` (nuevos);
  `agents/council-fable.md` y `agents/council-fable-offline.md` (solo la `description`, si
  hace falta nombrar el nivel).
- `skills/council/SKILL.md`: pasos 0, 1, 2–5, cota y líneas rojas.
- `skills/council/report/informe.tpl.html`: la insignia del perfil y el nivel medido en las
  fichas.
- Tests: `agent-council-parity.test.sh` (los seis ficheros), `council-preflight.test.sh`
  (matriz de perfiles), `council-capture.test.sh` (esfuerzo y agente), `council-run.test.sh` /
  `council-lifecycle*.sh` (`profile`, sello, congelación, herencia), `council-report*.test.sh`,
  `skill-council-contract.test.sh`, `doctor-env-matrix.test.sh` (si enumera agentes) y los
  fixtures de transcript que hagan falta.
- `README.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`.

## Acceptance & proof

**A1 — Agentes.** Existen los seis; el cuerpo es idéntico byte a byte; el frontmatter solo
difiere en `name`, `description`, `effort` (high/xhigh/max según la pareja) y `tools` (web /
offline, conjuntos exactos de hoy); los seis tienen el mismo `model` (ID completo).

**A2 — Preflight.**
- Sin restricciones: OK, los tres perfiles viables.
- `maxEffortLevel: xhigh` → OK, `critico` descartado con su motivo.
- `maxEffortLevel: medium` → FAIL (ninguno viable).
- `CLAUDE_CODE_EFFORT_LEVEL=xhigh` → solo `estandar`.
- `CLAUDE_CODE_EFFORT_LEVEL=low` o vacía → FAIL.
- `TANDEM_COUNCIL_EFFORT` definida → FAIL.
- `TANDEM_COUNCIL_PROFILE=critico` con `maxEffortLevel: xhigh` → FAIL.
- `TANDEM_COUNCIL_PROFILE=` o `foo` → FAIL.
- Un catálogo donde Astra solo admite `high` → solo `exploratorio`.
- Un gemelo `-xhigh` con `effort: max` → `estandar` descartado.
- Modelos distintos entre los seis → FAIL.
- La cota de turnos se imprime por perfil.

**A3 — `profile` y el sello.**
- `seal brief` sin perfil → 1.
- `profile` con un nombre desconocido → 64.
- Un perfil no viable → 1.
- `profile estandar` escribe `run.json.perfil`, con el agente correcto en modo web y offline,
  e imprime `PERFIL:` y `FABLE_AGENT:`.
- Repetirlo es idempotente; cambiarlo antes del sello, válido; después del sello → 65.
- `status` imprime `PERFIL:`, `FABLE_AGENT:` y `PERFIL_VIABLE:`.
- Un `run.json` heredado (sellado y sin perfil) → `critico` / `tandem:council-fable`.
- **Recuperación con un entorno incompatible.** Un run `estandar` sellado, recuperado con
  `CLAUDE_CODE_EFFORT_LEVEL=high`, con `maxEffortLevel: high` o con `TANDEM_COUNCIL_EFFORT`
  definida:
  - `stage` → 1 y `astra` → 1, nombrando la causa;
  - `run.json` queda byte a byte igual (sin intentos ni turnos reservados);
  - `status` → `PERFIL_VIABLE: no — …`.

**A4 — Astra.**
- Un turno sustantivo lanza el wrapper con `TANDEM_COUNCIL_EFFORT=<nivel>` en su entorno, y
  un recordatorio con `TANDEM_TURN_EFFORT=low` (con un codex falso que registra su entorno y
  sus argumentos).
- `publish` con un `meta.json` de `effort` distinto → 65.
- `publish` sin `meta.json` → publica y la anomalía aparece en `metadatos.md`.

**A5 — Fable.**
- Un transcript con `effort` y `attributionAgent` correctos → capturado, con `esfuerzos` y
  `agentes`.
- `effort: max` en un run `estandar` → 65, nada capturado.
- `attributionAgent: tandem:council-fable` en un run `estandar` → 65.
- Sin esos campos → capturado, «no verificado» y anomalía.
- `--manual` → «no verificado».

**A6 — Líder.**
- Con un transcript padre fixture (symlink a `subagents/agent-X.jsonl`) que tiene mensajes
  antes del sello (max), durante el debate y después del último `publish`:
  - `metadatos.md` muestra el tramo de intake y el de debate por separado, deduplicados por
    `message.id`;
  - los mensajes posteriores al último `publish` no cuentan;
  - un max del intake en un run `exploratorio` NO es anomalía; un xhigh durante el debate SÍ.
- Volver a ejecutar `status --metadata` tras añadir líneas al transcript da los mismos
  recuentos.
- Si no se puede resolver → «no medido».
- Nunca cambia un código de salida.

**A7 — Metadatos e informe.**
- `metadatos.md` lleva la línea del perfil y las filas nuevas.
- La regresión byte a byte se actualiza solo en las líneas descritas.
- `informe.html` lleva `FACTS.run.perfil` y la plantilla lo muestra (el test JS existente,
  ampliado).
- Los recuentos del líder en `informe.html` son idénticos a los de `metadatos.md`, aunque el
  transcript haya crecido entre los dos comandos (`report` lee la instantánea).
- Cambiar `lider-esfuerzo.json` → `informe.html desactualizado`.

**A8 — Contrato de la skill.**
- `SKILL.md` contiene la rúbrica, la llamada a `profile`, el `subagent_type` tomado de
  `FABLE_AGENT`, la confirmación del líder a nivel del perfil, la regla de `auto` y la línea
  roja de congelación.
- No contiene «both at max» como requisito ni ningún `effort` en la llamada al Agent.

**A9 — Canario real (manual, tras el merge, como en M39).** Un consejo `exploratorio` de una
ronda (`TANDEM_COUNCIL_ROUNDS=1`) en un proyecto de prueba, con **la sesión del líder
deliberadamente en max** (no en high). Es una desviación consciente, para que el canario
distinga el esfuerzo del subagente del de la sesión en el agente real del consejo, y no solo
en el diagnóstico.

Se espera:
- Fable captura con `esfuerzos: ["high"]` y el `attributionAgent` del agente `-high`, tanto
  en `propose` (lanzamiento) como en `cross` y en la ronda (continuaciones por
  `SendMessage`).
- El `meta.json` de Astra dice `high`.
- `metadatos.md` muestra el perfil y el líder medido en max, con la anomalía de desviación
  durante el debate.

Si Fable registrara `max` (el de la sesión), el cambio no se publica: la comprobación de
`capture` se degrada a anomalía antes de etiquetar la versión.

**PROOF:** `bash tests/verify.sh`

## Risks

- **El campo `effort` del transcript desaparece o cambia de semántica** (no documentado). La
  ausencia degrada a «no verificado». Un cambio de semántica (p. ej. que `effort` reflejara la
  sesión y no el subagente) daría falsos 65. Ya está medido con niveles distintos (sesión
  `medium`, subagente `xhigh`, lanzamiento y continuación: ver §6). A9 lo repite con el agente
  real del consejo antes de publicar la versión, y los fixtures reales conservan los campos.
- **Agentes nuevos sin registrar en una sesión vieja.** Los agentes de plugin no se recargan
  en caliente: un `subagent_type` desconocido falla en el lanzamiento, de forma visible.
  README y CHANGELOG lo avisan.
- **Rotura de `TANDEM_COUNCIL_EFFORT`** para quien la usara. Es deliberada y el mensaje del
  FAIL explica la alternativa.
- **Rutas de transcript del líder** distintas en terminal, escritorio y gateway. La medición es
  de mejor esfuerzo y nunca bloquea.
- **Más superficie en `council.sh`** (2.578 líneas). Mantener el cambio en helpers pequeños y
  los tests por subcomando.

## Out of scope

- Niveles distintos para Fable y Astra, o un modo «personalizado» por asiento (decisión del
  usuario: siempre simétricos).
- Niveles por debajo de `high` y `ultra` para Astra.
- Cambiar de perfil a mitad de un run.
- Fijar el esfuerzo del líder desde la skill (imposible: solo por sesión).
- Bloquear el run por el esfuerzo medido del líder.
- Perfiles en otros comandos de tandem (`ultra`, `plan`, `review`).
