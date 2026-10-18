# Review — council (M39, v0.36.0)

- **Fecha:** 2026-10-18
- **Plan:** `docs/plans/council.plan.md` (M39 — `/tandem:council`, consejo adversarial de tres
  modelos; origen: petición del mantenedor y entrevista de cuatro decisiones)
- **Rama:** `tandem/council`, apilada sobre `tandem/codex-models-v6` (15502e7, v0.35.0, aún sin
  mergear a main); plan commiteado en 488c961
- **Gate:** lint: OK (shellcheck 0.10.0 en scripts/ y tests/; actionlint 1.7.7) · typecheck: n/a
  (bash) · tests: 100 passed, 0 failed · proof (`bash tests/verify.sh`): OK, re-ejecutado tras
  cada arreglo
- **Plan review (Astra, xhigh, hilo persistente):** 5 rondas → `VERDICT: APPROVED` (justo en el
  tope)
- **Code review (Astra, xhigh, hilo fresco sin contexto previo):** 2 rondas →
  `VERDICT: APPROVED`
- **Implementación:** Opus 5.5 (`tandem:implementer`, transporte opus). El modelo quedó
  verificado en las 666 líneas `assistant` de su transcript: no es solo autodeclaración. El
  plan se le entregó por ruta + blob hash, en vez de pegado, para que recibiera una copia
  byte a byte del texto congelado. Versión, CHANGELOG, BACKLOG y manifiestos los escribió el
  orquestador, porque el contrato del implementador se los prohíbe.

## Hallazgos y disposiciones (condensado)

### Plan review — 5 rondas, 9 hallazgos, todos ACEPTADOS

- **R1 `REVISE` — 1 P1 + 4 P2:**
  - (P1-1) publicar por la mera presencia de un `reply.txt` habría promovido turnos que el
    wrapper rechazó → `council.sh astra` como único camino a un turno, con exit y número de
    turno registrados por máquina;
  - (P2-1) reconstruir tras perder la sesión chocaba con el «nunca sobreescribir» →
    intentos `.a<K>`;
  - (P2-2) un `TANDEM_TURN_EFFORT` heredado rebajaría en silencio los turnos sustantivos →
    FAIL en el preflight y `env -u` en cada lanzamiento;
  - (P2-3) la auditoría de fuentes iba después del consenso → pasa a antes de cada ronda;
  - (P2-4) la cota de turnos no contaba recordatorios ni reintentos → típico 12, techo 30.
- **R2 `REVISE` — 1 P1 + 1 P2:**
  - (P1-2) escrituras cruzadas de `run.json` → lock por run, con lectura dentro;
  - (P2-5) un pid muerto no prueba que el turno de codex parase → el driver es dueño del
    ciclo de vida: reenvía TERM y decide la liveness por pid + `lstart` y firmas de argv.
- **R3 `REVISE` — 1 P1 + 1 P2:**
  - (P1-3) la igualdad de bytes con `last.txt` no prueba el éxito (un rechazo puede repetir
    bytes) → recibo de éxito `t<N>.ok` escrito por el propio wrapper;
  - (P2-5 restante) quedaba una ventana entre lanzar y registrar → una sola sección crítica;
    una entrada sin wrapper registrado queda `bloqueada` hasta un `unblock` humano.
- **R4 `REVISE` — 1 P2:** (P2-6) el escaneo de argv se emparejaba con el propio comando que
  recupera → token único por lanzamiento (`exec -a council-astra-<token>`, verificado en bash
  3.2.57) y una instantánea de `ps` comparada en el propio proceso, excluyendo su pid.
- **R5 `APPROVED`** — sin hallazgos nuevos.

### Verificación del orquestador (antes de la code review)

- Hallazgo propio, medido en el transcript real y largo del implementador: el uso de un
  subagente se reparte en varias líneas por mensaje y, en los mensajes largos, solo la ÚLTIMA
  lleva el recuento definitivo (las anteriores, los parciales del streaming). Con la primera
  línea salían 6.514 tokens de salida; con la última, los 152.578 reales. `council.sh` ya se
  quedaba con la última, pero el test calculaba con la primera y su fixture no las distinguía.
- Arreglo: segunda fixture real de streaming, saneada, con aserciones literales, comprobada
  por mutación (con la regla «primera línea» el test falla); premisa corregida en ARCHITECTURE
  y en las fixtures.
- Además, notas de background y barrera dentro de los bloques de código de la skill.

### Code review — 2 rondas

- **R1 `REQUEST_CHANGES` — 2 Major, ACEPTADOS y corregidos:**
  - (1) `publish` recorría sin comillas una lista de rutas separada por espacios y se rompía
    con un proyecto o un `TANDEM_COUNCIL_DIR` con espacios → arrays con comillas. Test nuevo
    `council-spaces` (un `propose` completo con espacios en todas las rutas), que falla con
    el código anterior (`publish` → 65).
  - (2) la respuesta de Fable podía preceder al sello del líder (Fable lanzado, aún sin
    captura) → `stage` exige el sello de propose/cross, y `seal` responde 65 en cuanto hay
    un prompt preparado.
  - Al re-ejecutar el gate: un SC2010 en el test nuevo (corregido), y `council-lifecycle`
    superó el watchdog de 60 s por caso con la suite cargada. Se partió en `council-lifecycle`
    y `council-recovery` (18 s y 24 s) con un preámbulo común que el runner no ejecuta.
- **R2 `APPROVED`** — los dos Major confirmados y sin hallazgos nuevos en los arreglos, la
  partición ni los documentos.

## Pendiente

- **Canario real C1–C5 del plan:** cierre bloqueante antes del merge. Gasta cuota de los tres
  modelos en max, así que necesita el OK explícito del mantenedor, una sesión nueva con el
  plugin cargado (los agentes de plugin no se recargan en caliente) y una carpeta fuera de
  cualquier repo. Valida además las formas sintéticas de las fixtures (la continuación por
  `SendMessage` y la respuesta en bloques `text`).
