# Review — council-report-html (M40, v0.37.0)

- **Fecha:** 2026-10-19
- **Plan:** `docs/plans/council-report-html.plan.md`. M40 es el informe visual e interactivo del
  consejo; nace de una petición del mantenedor tras ver el prototipo sobre el canario Recap90.
- **Rama:** `tandem/council-report-html`, sobre `main` en c0d8cf1 (v0.36.1). El plan está
  commiteado en b1bdaeb.
- **Gate:**
  - lint: OK (shellcheck 0.10.0 en `scripts/` y `tests/`; actionlint 1.7.7);
  - typecheck: n/a (bash);
  - tests: 104 passed, 0 failed (3 casos nuevos);
  - proof (`TESTS_BASH=/bin/bash bash tests/verify.sh`): OK, repetido después de cada arreglo.
- **Plan review (Astra, xhigh, hilo persistente):** 2 rondas → `VERDICT: APPROVED`.
- **Code review (Astra, xhigh, hilo fresco):** 3 rondas → `VERDICT: APPROVED`, justo en el
  tope.
- **Implementación:** Opus 5.5 (`tandem:implementer`, transporte opus). El plan se le pasó por
  ruta + blob hash. Versión, CHANGELOG y BACKLOG los escribió el orquestador.
- **Tokens Codex:** plan, in 2.800.054 / out 11.727; code review, in 10.917.198 / out 37.954.

## Hallazgos y disposiciones (condensado)

### Plan review — 2 rondas, 3 hallazgos, todos ACEPTADOS

- **R1 `REVISE` — 1 P1 + 2 P2:**
  - **(P1)** El test de JS no podía correr: el runner limpia el PATH y `node` no se veía en el
    sandbox. Arreglo: `tests/run.sh` enlaza `node` cuando existe, como jq y git; sin `node`,
    el caso falla nombrándolo.
  - **(P2)** Un rename atómico por fichero no da una instantánea coherente: `consensus_json`
    relee los documentos por su cuenta, y el moderador escribe sin atomicidad. Arreglo:
    `report` copia una vez los documentos y saca de esa copia textos, hechos y huella. Una
    edición concurrente da, como mucho, un HTML viejo que `status` ve desactualizado, nunca uno
    falsamente al día.
  - **(P2)** Que el texto sea igual no prueba que se aprobara: el paso 6 también corre con
    SIN_CONSENSO. Arreglo: `facts.strategy` y `strategyNote`; «aprobada» solo con consenso y
    copia exacta.
- **R2 `APPROVED`**, sin hallazgos nuevos.

### Verificación del orquestador (antes de la code review)

- **Arreglos propios:**
  - Payload con `split("<") | join("\\u003c")` en lugar de `gsub`. Da los mismos bytes en
    tiempo lineal; `gsub` era cuadrático en el número de `<`. Era una objeción del propio
    implementador.
  - Aserción nueva: la versión de `plugin.json` es la primera entrada del CHANGELOG.
- **A10, comprobación manual sobre el canario real** (`council.sh report`, sin cuota):
  - Escritorio, móvil (375 px) y oscuro: las 7 pestañas, filtros, diálogo y enlaces.
  - Cero errores de consola y cero peticiones externas.
  - «Aprobada» solo aparece con consenso y copia exacta.
  - Encontró un desbordamiento horizontal en la pestaña Estrategia, por una URL larga sin
    cortes. Se corrigió con `overflow-wrap` en enlaces, rutas y código; después, ninguna de
    las 7 pestañas ni de los 27 documentos desborda.
- **Gate:** un primer intento tuvo un fallo transitorio (`mcp-probe-gating`, `setpgid`), y
  otro, tras la ronda 1 de la code review, un timeout de `status-multi-root` con la máquina
  cargada. Ninguno de los dos casos lo toca este diff: pasaron aislados y en la repetición
  completa.

### Code review — 3 rondas

- **R1 `REQUEST_CHANGES` — 1 Major + 1 Minor, ACEPTADOS:**
  - **(Major)** Las conversiones de tablas (riesgos, métricas, calendario, supuestos)
    suponían columnas fijas: una tabla con otra forma perdía contenido. Arreglo: `tableFits`,
    que exige el ancho exacto en la cabecera y en cada fila, y fechas legibles; si no, la
    tabla se muestra tal cual.
  - **(Minor)** El tramo «sin disposición válida» no filtraba. Arreglo: `dispMatches`.
  - Los dos arreglos son puros, tienen tests en node y están comprobados por mutación.
- **R2 `REQUEST_CHANGES` — el Major, parcial:** el ancho no es el significado
  (`Mitigación | Riesgo` cambiaba los papeles). Arreglo: `SHAPES`, `headsFit` y
  `fitsShape`. Cada componente exige sus cabeceras por significado y en su orden, y todas las
  conversiones pasan por ahí. El caso de solo reordenar las columnas tiene test, comprobado por
  mutación. Las cuatro tablas del canario siguen encajando.
- **R3 `APPROVED`:** los dos hallazgos confirmados, sin nada nuevo.
