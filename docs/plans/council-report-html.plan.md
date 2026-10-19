# Plan: council-report-html — informe visual e interactivo del consejo (`informe.html`)

- **Backlog:** M40 (nueva) · **Slug:** `council-report-html` · **Versión objetivo:** 0.37.0
- **Base:** `main` en c0d8cf1 (v0.36.1)
- **Origen:** petición del mantenedor del 2026-10-19: entregar el resultado de `/tandem:council`
  de una forma más visual, en un HTML interactivo, con gráficos, énfasis visual y el contenido
  organizado. Se probó primero con el resultado del canario real (Recap90). El mantenedor vio el
  prototipo, lo dio por bueno y pidió integrarlo por el pipeline tandem, sin merge ni push hasta
  su OK.
- **Prototipo de partida (fuera del repo, solo lectura):**
  `~/Documents/LIVWORKS/council-canario-2026-10-18/prototipo-informe-html/`.
  - `build.sh`: bash + jq; empaqueta los .md del run y un run.json reducido.
  - `informe.tpl.html`: plantilla autocontenida con todo el JS y el CSS.
  - Su salida está en `docs/council/2026-10-18-recap90-redes-madrid/informe.html` de esa carpeta
    y se verificó en el navegador: escritorio, móvil y modo oscuro, sin errores de consola y sin
    scroll horizontal.

## Goal

Cada run de `/tandem:council` deja también `DOC_DIR/informe.html`: una sola página HTML
autocontenida y sin red que presenta el resultado de forma visual e interactiva. El lector
encuentra:
- un sello de veredicto;
- KPIs de objeciones, rondas, objetivo y fuentes;
- el calendario a escala de los primeros 30 días;
- el gráfico de hitos;
- el mapa del debate fase × asiento con los veredictos;
- las objeciones filtrables con su historia ronda a ronda;
- la estrategia plegable con índice;
- todos los documentos del run navegables;
- los tokens, los turnos y las fuentes.

La genera `council.sh report <run-id>` en el paso 6, después de escribir `informe.md`. Los
Markdown siguen siendo el registro con autoridad: el HTML es una vista derivada, regenerable y
nunca editada a mano. Todo hecho estructurado que muestra (objeciones, estados, historial,
registro, veredictos, consenso, fuentes, asientos, tokens y anomalías) lo calcula `council.sh`
con la MISMA gramática jq que ya usan `ledger` y `status`. El JavaScript de la página solo
presenta.

## Approach

### 1. `council.sh report <run-id>` — subcomando nuevo

- **Validación:** valida el run id; `council_paths`; `need_jq`; `run_require`; `state_load`.
  - Lee el estado una sola vez (`STATE`) y no lo escribe.
  - No toma el lock del run (D8).
- **Instantánea (D8):** antes de calcular nada, `report` copia UNA vez los documentos de la
  lista cerrada a un directorio privado (`mktemp -d` bajo RUN_DIR, borrado al salir también en
  error). TODO sale de esa copia:
  - los textos embebidos;
  - los hechos: `docs_json`, `registro_json`, `consensus_json`, las fuentes y la estrategia se
    calculan con `DOC_DIR` apuntando a la instantánea;
  - la huella, que es el hash de esos mismos bytes.

  El HTML es coherente consigo mismo por construcción. Una edición concurrente produce, como
  mucho, un HTML coherente con la versión anterior, que `status` ve desactualizado, nunca uno
  falsamente al día. `run.json` se lee una vez; los usage y los meta.json no cambian después
  del paso 6.
- **Precondiciones (exit 1, nombrando cada fichero que falta):** existen
  - `DOC_DIR/informe.md`;
  - `DOC_DIR/estrategia-final.md`;
  - `DOC_DIR/metadatos.md`.

  Son las tres salidas del paso 6. El HTML es la forma visual del informe terminado, nunca de un
  run a medias.
- **Plantilla:** `$PLUGIN_ROOT/skills/council/report/informe.tpl.html`.
  - Tiene que contener EXACTAMENTE una línea `<!-- COUNCIL_DATA -->`. Si no la hay o hay más de
    una, sale con 65.
  - Si la plantilla no existe, sale con 65.
- **Documentos embebidos (lista cerrada, D7):** `brief.md`, `informe.md`, `estrategia-final.md`,
  `metadatos.md`, `registro.md`, `sintesis-v<N>.md`, `auditoria-v<N>.md`,
  `1-propuestas/<L>.md`, `2-contrainterrogatorio/<L>.md` y `rondas/r<N>-<L>.md`.
  - Nunca `prompts/` ni nada de RUN_DIR.
  - Cada uno va con su texto íntegro, como cadena JSON (`jq --rawfile`), con la clave de su ruta
    relativa a DOC_DIR.
- **Payload (`schema: 1`)** — un objeto JSON:
  - `generated` (UTC).
  - `run`: `run_id`, `created`, `mode`, `max_rounds`, `letters`, `leader_model`.
  - `docs`: los documentos de la lista anterior.
  - `facts`, calculado en jq (§2): `objections`, `events`, `rows`, `rounds`, `status`,
    `strategy`, `sources`, `seats`, `tokens`, `astra_turns` y `anomalies`.
- **Incrustación:**
  - El payload se escribe dentro de
    `<script type="application/json" id="council-data">…</script>`, en lugar del marcador.
  - Va serializado con `tojson | gsub("<"; "\\u003c")`, así que en el payload no queda ningún
    byte `<`. Ningún texto de un asiento puede cerrar el `<script>` ni abrir `<!--`.
  - Justo después va una línea de huella `<!-- tandem-council-digest: <sha256> -->` (§3).
  - Se compone en un temp dentro de DOC_DIR y se instala con `write_atomic`.
  - Imprime `INFORME HTML: <ruta>` y sale con 0.
- **Uso y cabecera:** `council_usage` y la cabecera del script añaden `report <run-id>`.

### 2. Una sola gramática: hechos en jq, compartidos con `ledger`, `status` y `metadatos.md`

- **`objections`:** la definición `objections` de `COUNCIL_JQ` sobre `docs_json`, sin cambios
  (id, author, n, sev, title, phase, status, reason). Se le añade `detail`: las líneas sangradas
  que siguen a la línea de la objeción en su documento de origen (Escenario, Evidencia,
  Propuesta…), hasta la primera línea no sangrada que no sea un blanco seguido de más sangría.
  Es una def jq nueva, `detail_of`, sobre las mismas `rx_obj`.
- **`events` (nueva def en `COUNCIL_JQ`):** la secuencia, en orden de autor y fase (`order`), de
  cada línea propia que casa con `rx_obj` (`NUEVA`, con sev y título), `rx_st` (`RESUELTA` o
  `NO RESUELTA`, con el motivo) o `rx_re` (`REABRE`, con el argumento).
  - Rige la MISMA regla de letra propia que `objections`: un ID ajeno citado es una referencia,
    no una afirmación.
  - Cada evento lleva id, author, phase y kind, más text (y sev en `NUEVA`).
  - `objections` sigue siendo la fuente del estado final. `events` es su historia y no se usa
    para decidir nada.
- **`rows`:** la def `rows` sobre `registro_json`, sin cambios.
- **`rounds`:** por cada N con las dos respuestas revisoras publicadas, `{n, verdicts:[{letra,
  verdict, riesgo}]}`.
  - `verdict` es la def existente.
  - `riesgo` es el texto de la línea `RIESGO RESIDUAL:`, de la misma forma que `has_riesgo`.
- **`status`:** el `consensus_json` de la última ronda completa (o `null`), más `last_round` y
  `max_rounds`. Es exactamente lo que imprime `status`, así que el sello del HTML nunca contradice
  a `council.sh status`.
- **`strategy`:** `{last_round, synthesis, identical, consensus}`.
  - `identical` es la comparación byte a byte, en la instantánea, de `estrategia-final.md` con
    `sintesis-v<last_round>.md`.
  - `consensus` es `status.consensus`.
  - El texto que la página muestra lo decide una función pura, `strategyNote` (§4).
- **`sources`:** las líneas `- [F<n>] VERIFICADA|NO ACCESIBLE|NO CONFIRMA <resto>` de la
  `auditoria-v<N>.md` de mayor N.
  - Cada una se parte en `src` y `desc` por el primer ` — ` (raya con espacios). El formato es el
    que fija el paso 4 de la skill.
  - `offline: true` si la auditoría es `- OFFLINE: no aplica`.
- **`seats`, `tokens`, `astra_turns` y `anomalies`:** salen de las MISMAS funciones que escriben
  `metadatos.md`.
  - **Refactor de `write_metadata`:** se extraen `usage_facts_json` (sumas de Astra y de Fable,
    `nu` y `nf`, y la cota inferior `sin_usage_definitivo` / `mensajes`) y `astra_metas_json`
    (el meta.json de cada turno).
  - Las listas de evidencia de los asientos y de anomalías pasan a defs jq compartidas.
  - `write_metadata` las consume y su salida queda BYTE A BYTE igual; lo prueba un test de
    regresión sobre los fixtures existentes, A3.
  - `report` consume las mismas defs y funciones.
- **Lo que el JS sí interpreta, todo a la vista (D2):**
  - el Markdown, para mostrarlo;
  - los encabezados `##` de `informe.md`, cuyas secciones fija la skill en el paso 6;
  - las tablas dentro de esas secciones (Primeros 30 días, Métricas, Riesgos, Supuestos);
  - las fechas en español de esas tablas.

  Todo es «mejor esfuerzo con caída»:
  - una sección que no reconoce se muestra tal cual en el Resumen;
  - una tabla cuyas fechas no se dejan leer se muestra como tabla;
  - el texto completo de cada documento está siempre en la pestaña Documentos.

  Ningún byte de `informe.md` deja de estar visible.

### 3. Frescura: huella y `status`

- **La huella:** `report_digest` es el sha256 de la lista ordenada (`LC_ALL=C`) de líneas
  `<ruta relativa>\t<sha256 del fichero>` de los documentos embebidos, calculada sobre la
  instantánea. Usa `file_sha256` de `_common.sh`. `report` la escribe en la línea de huella.
  `status` la recalcula con la misma función sobre los ficheros vivos.
- **La fase de `status`** cuando existe `informe.md`. Hoy dice `informe (escrito)`; pasa a
  distinguir tres casos:
  - `informe (escrito; falta informe.html: council.sh report)`, si no existe;
  - `informe (escrito; informe.html desactualizado: council.sh report)`, si existe pero no trae
    la línea de huella o su huella no es la actual;
  - `informe (escrito)`, si está al día.
- **Qué no toca:** el `STATUS:` y el exit code de `status` no cambian. La frescura es
  informativa y no forma parte de las seis reglas del consenso.

### 4. La plantilla `skills/council/report/informe.tpl.html`

Parte del prototipo, con estos cambios.

**Datos.** Consume `facts` en lugar de reinterpretar con regex propias las respuestas de los
asientos, el registro, los metadatos y la auditoría:
- desaparecen del JS los regex de objeciones, estados, REABRE, VERDICT, RIESGO RESIDUAL y de las
  líneas `[F<n>]`;
- desaparece el análisis de `metadatos.md`.

**Estructura.**
- El JS va en dos bloques.
  - **Bloque puro**, delimitado por `/* tandem-report:pure:start */` y `/* …:end */`. Define un
    objeto `TandemReport` (`esc`, `inline`, `md`, `tables`, `sections`, `parseFecha`,
    `niceScale`) que NO toca `document` ni `window`.
  - **Bloque de construcción.** Solo corre si existe `document`.
- Hay un `<noscript>` que remite a `informe.md`.

**Sin red (D3).** No hay `<script src>`, `<link>`, `@import`, `url(` hacia http(s), `fetch`,
`XMLHttpRequest`, fuentes web ni librerías:
- las tipografías son pilas del sistema;
- los gráficos son SVG y HTML dibujados por la plantilla.

**Seguridad del render (D4).**
- Todo texto pasa por `esc` antes de cualquier marcado, y no hay HTML crudo en el Markdown.
- Enlaces:
  - `http(s)://` → `<a target="_blank" rel="noopener noreferrer">`;
  - una ruta relativa que resuelve a un documento embebido → navegación interna;
  - cualquier otro esquema (`javascript:`, `data:`, `file:`, `mailto:`…) o una ruta absoluta →
    texto, nunca `href`.

**Pestañas y vistas.** Se conservan las del prototipo:
- **Resumen:** sello, KPIs, resumen ejecutivo, los bloques de la estrategia, decisiones
  pendientes, disidencias por asiento, alternativas descartadas y estado.
- **Plan:** calendario a escala con la marca de hoy, gráfico de hitos con la regla de
  diagnóstico, puertas, riesgos en tarjetas y supuestos verificados frente a por validar.
- **Debate:** mapa fase × asiento con fichas de objeción y veredictos, y tarjetas ronda a ronda
  con el riesgo residual.
- **Objeciones:** barras asiento × disposición que filtran, filtros por asiento, severidad y
  disposición, búsqueda, y un diálogo con el planteamiento y la historia de cada objeción.
- **Estrategia:** índice y secciones plegables, y una nota de procedencia que da
  `strategyNote(facts.strategy)`:
  - con `consensus && identical`: «copia exacta de la síntesis vN, aprobada por los dos
    revisores en la ronda N»;
  - con `!consensus && identical`: «copia exacta de la síntesis vN, revisada en la ronda N, sin
    consenso»;
  - con `!identical`, en cualquier caso: un aviso de integridad visible, «no coincide con la
    síntesis vN de la última ronda».

  Ningún otro texto fijo de la plantilla afirma aprobación. El subtítulo de los bloques de la
  estrategia en el Resumen pasa a ser neutro, y el sello y el estado salen de `facts.status`.
- **Documentos:** todos los documentos, agrupados.
- **Proceso:** asientos y modelos, tokens a escala (entrada y salida, con la cota inferior
  marcada), turnos de Astra, fuentes de la última auditoría y anomalías.

Los arreglos visuales ya hechos sobre el prototipo se conservan, entre ellos los anchos del
mapa del debate por peso de fichas.

**Tema y diseño adaptable.**
- Modo claro y oscuro, con `prefers-color-scheme` y `data-theme`.
- Funciona a 375 px de ancho sin scroll horizontal. Solo el mapa del debate desborda, dentro de
  su propio contenedor con `overflow-x:auto`.

### 5. La skill

**Paso 6** de `skills/council/SKILL.md`: después de escribir `informe.md`, se ejecuta

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" report <run-id>
```

Después se le dicen al usuario las dos rutas: `informe.md` y `informe.html`. Si `informe.md`
cambia, se regenera; `status` avisa cuando el HTML está desactualizado.

**Línea roja nueva:** `informe.html` es una vista derivada. Nunca se edita a mano ni se
corrige allí nada que no esté en los Markdown. La descripción del frontmatter menciona el HTML.

### 6. Tests

- **`tests/council-report.test.sh` (nuevo).** Usa un run sembrado a mano, como hacen
  `council-ledger` y `council-run`: docs de propose, cross y rondas con objeciones, estados,
  REABRE, veredictos y RIESGO RESIDUAL; registro; auditoría; usage de Astra y de Fable;
  `status --metadata` e `informe.md`. Cubre A1–A4 y A6.
- **`tests/council-report-js.test.sh` (nuevo).**
  - Comprueba que `node` existe; si no, FALLA nombrando la dependencia (D9).
  - Extrae de la plantilla los dos bloques de script y pasa `node --check` a cada uno.
  - Ejecuta el bloque puro en `node:vm` sin `document` y aserta el render, los enlaces y las
    fechas (A5, A8).
- **`tests/council-spaces.test.sh` (ampliado).** `report` bajo las rutas con espacios (A7).
- **`tests/run.sh` (ampliado, D9).**
  - Resuelve `node` con `command -v` ANTES de limpiar el entorno y, si existe, lo enlaza como
    `$sb/tools/node`, igual que jq y git.
  - Sin `node` no hay enlace y no hay fatal del runner: el test JS falla solo, nombrando la
    dependencia.
  - El resto de la suite no lo ve ni lo necesita.
- **`tests/skill-council-contract.test.sh` (ampliado).** El paso 6 nombra `report` e
  `informe.html`, y está la línea roja de la vista derivada (A9).

### 7. Documentación y versión

- **README:** la sección de council menciona el HTML; la sección de tests, `node` como
  dependencia solo de los tests.
- **`docs/ARCHITECTURE.md`:** subsección «Informe HTML del consejo», con D2, D3, D4, D5 y D8.
- **CHANGELOG 0.37.0**, **`docs/BACKLOG.md` M40** y la versión 0.37.0 en
  `.claude-plugin/plugin.json` y `marketplace.json`. Esta parte la escribe el orquestador.

## Key decisions & tradeoffs

- **D1 — Subcomando propio en vez de plegarlo en `status --metadata`.** `informe.md` se escribe
  DESPUÉS de `status --metadata`, y el HTML lo incrusta. Plegarlo obligaría a regenerar o a
  dejar el HTML sin el informe. A cambio, la skill tiene un paso más, que `status` vigila (§3).
- **D2 — Hechos en jq, presentación en JS.** El prototipo reinterpretaba en JS la gramática de
  las respuestas, con regex que ya divergían de `COUNCIL_JQ`: aceptaba `NO RESUELTA` sin dos
  puntos. Con dos gramáticas, el HTML podría mostrar un estado que `ledger` y `status` no ven.
  El coste es refactorizar `write_metadata` y añadir dos defs jq. El JS conserva solo lo que no
  decide nada: el Markdown para mostrarlo, los encabezados fijos del informe y las fechas, todo
  con caída visible.
- **D3 — Autocontenido y sin red.** Un consejo puede ser confidencial (`--offline`). Una página
  que pide fuentes o librerías a un CDN filtra al menos que existe y cuándo se abre, y deja de
  funcionar sin conexión. El coste es tipografía del sistema y gráficos dibujados a mano, sin
  librería. Un test lo ancla con patrones prohibidos.
- **D4 — Incrustación JSON escapada y render que escapa todo.** El texto de los asientos es
  contenido no confiable dentro de un documento que se abre en un navegador. Hay dos barreras
  independientes:
  - `<` → `<` en el payload;
  - `esc` antes de cualquier marcado, con la lista de esquemas de enlace.

  No hay HTML crudo en el Markdown, aunque el Markdown lo permita: se pierde fidelidad en algún
  caso raro a cambio de cero ejecución de contenido.
- **D5 — Markdown con autoridad, HTML derivado, frescura por huella.** La alternativa era
  escribir el informe directamente en HTML. Eso perdería el diff legible, la herramienta de
  búsqueda y la regla «el informe resume, nunca reescribe». La huella cubre los documentos, no
  `run.json` ni los ficheros de usage, que no cambian tras el paso 6. Está documentado.
- **D6 — Precondiciones duras.** Sin `informe.md`, `estrategia-final.md` o `metadatos.md` no hay
  HTML (exit 1). Así nunca se genera un informe visual de un run a medias que pudiera pasar por
  final.
- **D7 — Lista cerrada de documentos.** Ni `prompts/`, que repite el brief y las respuestas y
  dobla el tamaño, ni RUN_DIR (capturas en bruto, sellos). Un fichero extraño en DOC_DIR no
  entra.
- **D8 — Instantánea propia en vez de lock** (corregido en la ronda 1). Los renames atómicos
  de cada fichero no bastan: `consensus_json` relee respuestas, registro y auditoría por su
  cuenta, y el moderador escribe Markdown sin garantía de atomicidad. Una lectura repartida
  podría mezclar versiones y fabricar una huella que dé por al día un HTML incoherente.
  - **Lo que se hace:** `report` copia una vez los documentos y deriva de esa copia los textos,
    los hechos y la huella.
  - **Garantía por construcción:** la huella describe exactamente los bytes embebidos. Una
    edición concurrente (incluido un fichero a medio escribir) da un HTML coherente con lo que
    se copió, y `status` lo ve desactualizado.
  - **Por qué no el lock:** no sirve, porque el moderador escribe sin él, y haría que `report`
    respondiera 75 sin ganar nada.
  - **Escrituras concurrentes del HTML:** dos `report` a la vez escriben cada uno su temp, y el
    último rename gana.
- **D9 — `node` como dependencia SOLO de los tests, visible en el sandbox.** El runner limpia
  el PATH, así que `tests/run.sh` enlaza `node` (si existe) como enlaza jq y git. La lógica del bloque puro (escape,
  enlaces, fechas) merece tests ejecutables, y el repo no tiene otro motor JS. Sin `node`, el
  test falla nombrándolo, con la misma política de verify.sh: «una capa que no puede correr es
  un fallo, nunca un salto silencioso». El plugin en uso no lo necesita. La alternativa, no
  probar el JS o probarlo solo a ojo, deja sin red el punto de seguridad D4.
- **D12 — La procedencia de la estrategia la dicta el estado, no la igualdad de textos**
  (añadido en la ronda 1). El paso 6 también corre con SIN_CONSENSO tras el tope. «Aprobada» se
  afirma solo con `consensus && identical`; la igualdad sola dice «revisada»; la desigualdad es
  un aviso de integridad.
- **D10 — La plantilla vive en `skills/council/report/`.** Va junto a la skill que la usa, igual
  que `prompts/`. No va en `scripts/`, porque no es ejecutable.
- **D11 — La verificación visual es manual (A10), no de CI.** No hay navegador en la suite. El
  contrato (payload, escape, sin red, sintaxis y funciones puras) lo prueba la suite. El aspecto
  y la interacción, el orquestador en un navegador real sobre el run del canario. No gasta
  cuota.

## Files to touch

- `scripts/council.sh`:
  - `cmd_report`, `report_docs`, `report_digest`, `usage_facts_json` y `astra_metas_json`;
  - las defs jq `detail_of`, `events`, la evidencia de asientos y las anomalías compartidas;
  - `write_metadata` refactorizado con la salida idéntica;
  - la fase de `status`, el uso, la cabecera y el dispatch.
- `skills/council/report/informe.tpl.html`: nuevo, adaptado del prototipo.
- `skills/council/SKILL.md`: el paso 6, una línea roja y la descripción.
- `tests/council-report.test.sh` y `tests/council-report-js.test.sh`: nuevos.
- `tests/council-spaces.test.sh` y `tests/skill-council-contract.test.sh`: ampliados.
- `tests/run.sh`: enlace opcional de `node` en el sandbox.
- `tests/fixtures/council/report/`: si el sembrado del run lo pide.
- `README.md` y `docs/ARCHITECTURE.md`.
- `CHANGELOG.md`, `docs/BACKLOG.md`, `.claude-plugin/plugin.json` y
  `.claude-plugin/marketplace.json`: los escribe el orquestador.

## Acceptance & proof

**A1 — Contrato de `report`.**
- Exit 64 sin argumentos o con uno de más.
- Exit 1 para un run inexistente.
- Exit 1 sin `informe.md`, sin `estrategia-final.md` o sin `metadatos.md`, nombrando cada
  ausente.
- Exit 65 con la plantilla sin marcador, con dos marcadores o inexistente. La ruta de la
  plantilla se puede sobrescribir solo en los tests, con una variable interna documentada.
- Exit 0 con todo presente, imprimiendo `INFORME HTML: <ruta>`.
- No queda ningún temp junto a `informe.html`.

**A2 — Forma del fichero.**
- Hay exactamente un `<script type="application/json" id="council-data">` y una línea de huella.
- El payload extraído es JSON válido con `schema == 1`.
- Las claves de `docs` son exactamente la lista cerrada presente en el run fixture: ninguna de
  `prompts/` y ningún fichero extraño sembrado a propósito.
- Cada texto es byte a byte igual al fichero.

**A3 — Paridad de hechos.**
- `facts.objections` tiene los mismos id, author, sev y status que el parser de `ledger`.
- `facts.rows` es igual a las filas del registro.
- `facts.status.consensus` concuerda con el exit code de `status`.
- `facts.rounds[].verdicts` son los veredictos publicados.
- `facts.events` incluye un `REABRE` y un `NO RESUELTA` sembrados, y NO incluye un ID ajeno
  citado por otro asiento.
- `facts.tokens` coincide con las sumas que imprime `metadatos.md`.
- `facts.sources` parte `src`/`desc` y marca `offline` en un run offline.
- **A3b — Procedencia de la estrategia.**
  - En un run fixture SIN_CONSENSO por tope: `facts.strategy.consensus == false` y
    `identical == true`.
  - Con `estrategia-final.md` modificada tras `status --metadata`: `identical == false`.
  - El test JS comprueba que `strategyNote` nunca contiene «aprobad» salvo con
    `consensus && identical`, y que con `!identical` devuelve el aviso de integridad.
- **Regresión:** `metadatos.md` del fixture es byte a byte igual antes y después del refactor.
  Lo compara contra un fichero esperado versionado, generado con el código de c0d8cf1.

**A4 — Inyección.** Una respuesta de asiento con `</script><script>alert(1)</script>`, `<!--`
y `<img src=x onerror=alert(1)>`:
- el payload no contiene ningún byte `<`;
- el fichero tiene exactamente las etiquetas `<script` de la plantilla.

**A5 — Sin red.** La plantilla no contiene:
- `<script src`, `<link`, `@import`, `url(http`;
- `fetch(`, `XMLHttpRequest`, `navigator.sendBeacon`, `new WebSocket`, `EventSource`;
- `<iframe`, `<img src="http`.

**A6 — Frescura.** `status` imprime las tres fases de §3:
- sin HTML;
- con el HTML al día;
- tras modificar `informe.md` o un documento de ronda, y también con un HTML sin línea de huella.

El `STATUS:` y el exit code no cambian en ninguno de los tres casos.

Además:
- **Contenido, no mtime:** modificar un documento y restaurar su contenido original devuelve
  `informe (escrito)`.
- **Invariantes de la instantánea:**
  - la huella recalculada desde los `docs` del payload es igual a la línea de huella;
  - `facts.objections`, recalculado con el parser de `ledger` sobre los `docs` del payload (no
    sobre DOC_DIR), es igual al embebido.

  Así se comprueba que hechos, textos y huella salen de los mismos bytes.

**A7 — Espacios.** `report` funciona con espacios en la ruta del proyecto y en
`TANDEM_COUNCIL_DIR`.

**A8 — JS puro (con node).**
- Corre por el runner normal (`bash tests/verify.sh`) en macOS, con el `node` enlazado por
  `tests/run.sh`.
- `node --check` pasa en los dos bloques.
- `md()`:
  - escapa todo HTML del texto fuente;
  - `[x](javascript:alert(1))`, `[x](data:…)` y `[x](/abs/ruta)` → sin `href`;
  - `[x](https://a.b)` → `rel="noopener noreferrer"` y `target="_blank"`;
  - cubre listas anidadas (también ordenadas con subviñetas), tablas, código vallado y sangrado,
    citas, negrita y cursiva.
- `parseFecha`:
  - `19–20 oct`, `26 oct–6 nov`, `16 y 18 nov`, `23 oct` y `16 ene 2027`;
  - el paso de año, `ene` tras un run de octubre;
  - una entrada ilegible → `null`.

**A9 — Contrato de la skill.**
- El paso 6 nombra `report` e `informe.html`.
- Existe la línea roja de la vista derivada.
- Las versiones de `plugin.json` y `marketplace.json` concuerdan.

**A10 — Manual, antes de la code review.** El orquestador regenera el HTML del canario real con
`council.sh report 2026-10-18-recap90-redes-madrid` en
`~/Documents/LIVWORKS/council-canario-2026-10-18`. Tiene run.json, usage y docs reales, y no
gasta cuota. Lo comprueba en un navegador real en escritorio, en móvil (375 px) y en oscuro:
- cero errores de consola y ningún scroll horizontal del body;
- las siete pestañas pintan;
- los filtros, el diálogo de una objeción y los enlaces internos funcionan.

El resultado queda anotado en la review.

**PROOF:** `bash tests/verify.sh`

## Risks

- **El refactor de `write_metadata` cambia un byte de `metadatos.md`.** Lo mitiga el test de
  regresión byte a byte, más las aserciones existentes de `council-run` y `council-capture`.
- **La plantilla es grande (unos 100 KB) y no tiene linter de JS en verify.sh.** Lo mitigan
  `node --check` y los tests del bloque puro. El resto, el DOM, solo lo cubre A10.
- **`informe.md` cambia de estructura** si la skill cambia los nombres de sección. Sus secciones
  caerían al render genérico (visible, sin componente especial). Ningún contenido se pierde.
- **Fechas ambiguas en las tablas del informe.** La caída es la tabla tal cual. El año se
  infiere del `created` del run, con salto a enero.
- **Tamaño:** del orden de 2–3 veces la suma de los .md del run (unos 480 KB en el canario), sin
  límite práctico para un navegador.
- **Confidencialidad:** el HTML contiene lo mismo que los .md de DOC_DIR, ni más ni menos, y
  hereda su regla: nunca se commitea ni se pushea desde la skill. No hace ninguna petición de red
  (A5).

## Out of scope

- Generar el HTML en runs anteriores a la 0.37.0 de forma automática. Basta ejecutar `report`
  a mano, que es lo que hace A10.
- Exportar a PDF o imprimir con diseño propio. Solo se añade una regla mínima de `@media print`
  que muestra todas las pestañas.
- Publicarlo como Artifact o en cualquier servicio.
- Editar el informe desde el HTML.
- Traducir la interfaz (va en español, como el resto del consejo).
- Un linter o formateador de JS en verify.sh.

## Assumptions

Modo autónomo: `TANDEM_AUTONOMOUS=1` en el entorno, y el mantenedor pidió el pipeline completo
sin gates intermedios. Merge y push siguen siendo suyos.

- **¿El HTML sustituye a `informe.md`?** No. Es una vista derivada; el Markdown sigue siendo el
  registro con autoridad (D5). Así queda intacta la regla de la skill de que el informe resume y
  nunca reescribe.
- **¿Diseño nuevo o el del prototipo?** El del prototipo, que el mantenedor vio y aprobó. Los
  cambios son de datos (D2) y de estructura testable (bloques puro y de construcción), no
  visuales.
- **¿Generación automática dentro de `status --metadata`?** No, por D1. Es un paso explícito de
  la skill, vigilado por `status`.
- **¿Tomar el lock?** No, por D8.
- **¿Dependencia de `node`?** Solo para los tests (D9). El mantenedor ya lo tiene instalado
  (v25.8.1), y los runners de CI lo traen.
