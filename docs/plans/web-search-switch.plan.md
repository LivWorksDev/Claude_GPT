# Plan: web-search-switch — interruptor de confidencialidad para `web_search`

**Backlog:** M26 (P2/S) · **Origen:** informe de campo 2026-08-21, hallazgo A3 +
enmienda E-A3 (`docs/audits/informe-campo-2026-08-21.md`) · **Fecha:** 2026-08-29 ·
**Modo:** interactivo · **Base:** main **e6c30df** (v0.30.0).

## Goal

Hoy `web_search` — la herramienta nativa de búsqueda de Codex, NO gobernada por
`network_access` — solo se pinea off donde el turno puede escribir
(`scripts/_pins.sh:56-58`); los asientos read-only la conservan por decisión
documentada, con el residual registrado en `docs/ARCHITECTURE.md:76`: un asiento que
lee mucho repo (refutadores, revisores, jueces de enjambre) tiene un canal de salida
adicional hacia terceros vía queries de búsqueda, y el usuario del plugin no tiene
mando para cerrarlo. Este plan añade ese mando: `TANDEM_WEB_SEARCH=off` pinea
`web_search=disabled` en TODOS los asientos (start, swarm, resume y transporte MCP),
validado fail-closed como el resto de la familia `TANDEM_*` (set-pero-vacía o valor
desconocido = usage error 64, antes de dependencias), con el estado efectivo visible
en `tandem:doctor` y en la línea de banner que cada seat de swarm ya imprime (E-A3).
El default actual no cambia: sin la variable, ningún argv se mueve un byte.

## Approach

1. **`scripts/_common.sh` — el validador, nueva función `web_search_validate()`.**
   Patrón exacto de `codex_cwd_validate`/`TANDEM_TURN_EFFORT`: disciplina
   `${VAR+set}` (nunca `:-`, para que definida-pero-vacía sea inválida y no «unset»),
   conjunto cerrado `off | on`, cualquier otro valor →
   `die "TANDEM_WEB_SEARCH is not a valid value: '<v>' (expected: off or on)" 64`.
   Solo valida; no decide nada más.
2. **`scripts/_pins.sh` — el único cambio de política, en `codex_pins()`.** La rama
   condicional existente pasa de «solo escritura» a «escritura O interruptor»:

   ```bash
   if [ "$CODEX_SANDBOX" = "workspace-write" ] || [ "${TANDEM_WEB_SEARCH:-}" = "off" ]; then
     CODEX_PINS+=(-c web_search=disabled)
   fi
   ```

   Una sola rama → el pin aparece exactamente UNA vez también cuando ambas
   condiciones son ciertas, y en la MISMA posición de argv que hoy (tras
   `-c approvals_reviewer=user`, antes del `--cd` opcional): los literales byte a
   byte existentes de los roles de escritura no cambian. La lectura es TOLERANTE a
   propósito (sin `die`): `_pins.sh` mantiene su contrato de cero side effects
   porque `codex-doctor.sh` lo sourcea sin `_common.sh` y un diagnóstico no puede
   morir a mitad — los CUATRO ejecutables que gastan turnos vía `codex_pins()`
   (`codex-start.sh`, `codex-resume.sh`, `codex-swarm.sh` y `mcp-probe.sh`) validan
   antes de llegar aquí (punto 3), y el doctor denuncia el valor inválido por su
   propio canal (punto 5). Se actualiza el comentario del bloque (la decisión
   «read-only seats keep it» gana la coletilla «unless TANDEM_WEB_SEARCH=off asks
   otherwise»).
3. **`scripts/codex-start.sh`, `scripts/codex-resume.sh`, `scripts/codex-swarm.sh` y
   `scripts/mcp-probe.sh` — llamada al validador y visibilidad.** Los tres wrappers
   llaman `web_search_validate` inmediatamente después de `codex_cwd_validate`
   (posición usage-error: antes de `transport_resolve` donde exista, de
   `need_codex`/`need_jq` y de mover un byte de estado). `mcp-probe.sh` — el cuarto
   consumidor real de `codex_pins()`, que gasta hasta tres turnos con
   `"${CODEX_PINS[@]}"` — la llama junto a la validación de
   `TANDEM_MCP_PROBE_TIMEOUT_SECONDS`, antes de `need_codex` y de
   `state_init`/`RUN_DIR`: un valor inválido responde 64 sin crear estado del probe
   ni emitir una sola llamada (hallazgo P2-1 de la ronda 1). Su header documenta la
   variable; el pin llega a sus turnos por construcción, vía `CODEX_PINS`.
   Visibilidad:
   - **swarm (E-A3):** el banner de `codex-swarm.sh:270-271` gana el campo
     ` web_search=on|off` AL FINAL de la línea (tras `concurrency=`) — apéndice, no
     inserción, para que la aserción de substring existente en
     `tests/swarm-tiers-readonly-literal.test.sh:69` sobreviva sin ediciones. `off`
     cuando el pin viaja (interruptor activo; el sandbox de swarm es siempre
     read-only), `on` en el default.
   - **start/resume:** una línea condicional al estilo de la de transporte
     (`codex-start.sh:116-119`), solo cuando el interruptor está activo:
     `tandem: web_search pinned off on every seat (TANDEM_WEB_SEARCH=off)`. La
     salida por defecto queda byte a byte idéntica.
   - Los tres headers documentan la variable en su bloque `env:`.
4. **`scripts/_mcp.sh` — CERO cambios, y un test que lo demuestra.**
   `mcp_write_config` y `mcp_pins_config_json` derivan ambos de `CODEX_PINS`
   (`_mcp.sh:235-284`), así que el pin nuevo llega al `config.toml` efímero
   (`web_search = "disabled"`, vía `mcp_toml_value`) y al map `config` del tool call
   (`"web_search": "disabled"`) por construcción. La paridad se fija con test, no
   con prosa (punto 6).
5. **`scripts/codex-doctor.sh` — estado efectivo y denuncia del valor inválido.**
   Junto al bloque de roles/env (~línea 296): (a) si `TANDEM_WEB_SEARCH` está
   definida con valor fuera de `off|on` (vacía incluida) →
   `bad "TANDEM_WEB_SEARCH='<v>' is invalid — every wrapper would exit 64 (expected: off or on)"`,
   espejo del tratamiento de `TANDEM_ULTRA_*` (`codex-doctor.sh:315-320`); (b) línea
   `info` con el estado efectivo por clase de asiento, p. ej.
   `web_search:  write seats=off (pinned always) · read-only seats=off (TANDEM_WEB_SEARCH=off)`
   o `· read-only seats=on (default; TANDEM_WEB_SEARCH=off closes them)`. Nota: el
   turno `--smoke` ya pinea `-c web_search=disabled` explícito
   (`codex-doctor.sh:424`) además de `CODEX_PINS`; con el interruptor activo el pin
   aparecería dos veces con el MISMO literal — inocuo (última gana, valor idéntico)
   y autoconsistente en `tests/doctor-smoke.test.sh`, cuyo `pins_of` reconstruye
   desde el propio `codex_pins()`. Se documenta con un comentario, no se toca.
6. **Tests.**
   - **NUEVO `tests/web-search-switch.test.sh`:**
     - Con `TANDEM_WEB_SEARCH=off`: argv completo byte a byte (`assert_argv`) para
       `codex-start.sh` rol `review` (read-only con pin, en la posición fija), para
       `codex-resume.sh` (el re-pin del resume) y para un tier de swarm; bucle
       `assert_file_contains … web_search=disabled` sobre los tres tiers.
     - Con `TANDEM_WEB_SEARCH=off` y rol de escritura (`implement`): el pin aparece
       exactamente UNA vez (guardia contra una implementación con dos ramas `+=`).
     - Con `TANDEM_WEB_SEARCH=on`: read-only SIN pin (no-op explícito) y escritura
       CON pin (el interruptor nunca abre).
     - Banner swarm: `web_search=off` con el interruptor, `web_search=on` sin él.
     - Validación en los tres wrappers: vacía y valor desconocido → rc 64 nombrando
       la variable, cero invocaciones de codex (`assert_no_file …argv.N`), contador
       de turno intacto, y ANTES de dependencias (mismo criterio que
       `TANDEM_TURN_EFFORT`: usage error, nunca «missing dependency»).
   - **`tests/mcp-transport-ask.test.sh`:** caso nuevo con el interruptor activo —
     el map `config` del tool call contiene `web_search=disabled` (comparación de
     OBJETO ENTERO, convención M20c: un pin perdido O SOBRANTE falla) y el
     `config.toml` efímero lleva la clave TOML.
   - **`tests/mcp-probe-gating.test.sh`:** en su bloque «usage errors: 64, and
     nothing is launched» — `TANDEM_WEB_SEARCH` vacía/bogus → 64 nombrando la
     variable, cero tools/call y cero `codex exec` (los dos contadores del stub),
     sin estado de probe creado; y un caso `--spend` con `off` que fija
     `web_search=disabled` en el argv/frame que el stub registra (ningún test de
     probe inspecciona hoy el config.toml efímero — el punto de aserción idiomático
     de la suite es el stub, y el TOML del probe deriva del mismo `CODEX_PINS` ya
     cubierto por la paridad de `mcp-transport-ask`).
   - **`tests/doctor-env-matrix.test.sh`:** casos `TANDEM_WEB_SEARCH` — `off`/`on` →
     línea info del estado efectivo; vacía/bogus → `bad`.
   - **Suite existente: intacta.** `start-argv-exact-order.test.sh`,
     `resume-happy-argv-repin.test.sh` y `swarm-tiers-readonly-literal.test.sh`
     corren sin la variable (el runner aísla con `env -i`) y sus aserciones —
     incluidas las negativas `assert_not_contains … web_search` en read-only —
     siguen siendo exactamente la especificación del default. No se edita ninguna.
7. **Docs y versión.**
   - `docs/ARCHITECTURE.md`: la fila del pin en la tabla (§«Pins de argv») pasa de
     «solo roles de escritura» a «roles de escritura; todos con
     `TANDEM_WEB_SEARCH=off`», y el párrafo del residual (línea 76) registra que el
     residual por defecto se mantiene pero ahora tiene mando.
   - `README.md`: la variable en el párrafo de overrides por entorno (semántica,
     valores válidos, fail-closed) y una mención breve en la parte de
     sandbox/seguridad: para repos confidenciales, `TANDEM_WEB_SEARCH=off` cierra el
     canal de búsqueda también en los asientos read-only.
   - `CHANGELOG.md`: entrada **0.31.0** · `.claude-plugin/plugin.json`: `version`
     0.31.0.
   - `docs/BACKLOG.md`: la fila M26 pasa a `planificada` al aprobarse este plan y a
     `hecha (v0.31.0)` dentro del diff de implementación (verdadera en el momento
     del merge, como las filas M20/M21 precedentes).

## Key decisions & tradeoffs

- **Conjunto cerrado `{off, on}` y no `{off}` a solas.** `on` es el no-op explícito
  (documentado): permite a un entorno/CI declarar la decisión sin ambigüedad y deja
  la puerta de la validación cerrada por los dos lados. Coste: dos valores que
  documentar. Alternativa rechazada: aceptar solo `off` obligaría a «expresar el
  default borrando la variable», que es exactamente la ambigüedad set-vs-unset que
  la disciplina `${VAR+set}` del repo existe para eliminar.
- **`on` NUNCA re-habilita `web_search` en asientos de escritura.** El interruptor
  solo cierra, jamás abre: el pin de escritura es incondicional como hoy, porque
  `implement.tpl` promete «sin red» y esa promesa no puede depender de una variable
  de entorno. Es la decisión más contestable si alguien espera simetría — se declara
  aquí para que el revisor la ataque.
- **Variable dedicada `TANDEM_WEB_SEARCH`, no un perfil `TANDEM_CONFIDENTIAL=1`.**
  El informe ofrecía ambas; un mando = una cosa. El perfil agregado solo paga cuando
  existan varios mandos de confidencialidad que agrupar — hoy sería una indirección
  sobre un único booleano. Queda como posible entrada futura de backlog.
- **Validación en `_common.sh`, lectura tolerante en `_pins.sh`.** La separación no
  es estética: `_pins.sh` tiene contrato de cero side effects porque el doctor lo
  sourcea sin `die` disponible y un diagnóstico debe reportar todos los problemas,
  no morir en el primero. El riesgo de divergencia (validador y lector desacoplados)
  se mitiga con comentario cruzado en ambos ficheros.
- **El pin cae en la MISMA posición de argv que el pin de escritura actual.** Los
  tests literales existentes de escritura no cambian; los nuevos fijan la posición
  para read-only. Un pin en otra posición sería otra línea de comandos (la suite
  compara byte a byte, y esa es la garantía que M26 pide: «pineado por test literal
  como los tiers»).
- **Banner de swarm siempre muestra el estado (`on|off`); start/resume solo una
  línea condicional cuando `off`.** E-A3 pide observar el run vivo: en swarm el
  estado viaja SIEMPRE (es donde se mira), como campo final para no romper la
  aserción de substring existente. Esto es, deliberadamente, el ÚNICO cambio de
  salida del default (hallazgo P2-2 de la ronda 1): el banner default gana
  ` web_search=on`, declarado como intencional y fijado por aserción positiva en el
  test nuevo — nunca un efecto colateral que la aceptación finja no existir. En
  start/resume, la línea extra solo bajo el interruptor deja la salida default byte
  a byte idéntica (cero churn en tests y en logs reales).

## Files to touch

| Fichero | Cambio |
| --- | --- |
| `scripts/_pins.sh` | condición del pin ampliada (una rama), comentario del bloque |
| `scripts/_common.sh` | nueva `web_search_validate()` |
| `scripts/codex-start.sh` | llamada al validador, línea condicional, header env |
| `scripts/codex-resume.sh` | ídem |
| `scripts/codex-swarm.sh` | llamada al validador, campo final del banner, header env |
| `scripts/codex-doctor.sh` | check del valor + línea info de estado efectivo, comentario del duplicado inocuo en smoke |
| `scripts/mcp-probe.sh` | llamada al validador junto a la de `TANDEM_MCP_PROBE_TIMEOUT_SECONDS` (antes de `need_codex` y de `state_init`), header env |
| `scripts/_mcp.sh` | SIN cambios (paridad por construcción, fijada por test) |
| `tests/web-search-switch.test.sh` | NUEVO — argv literal, no-op de `on`, unicidad del pin, banner, validación 64×3 |
| `tests/mcp-transport-ask.test.sh` | caso con interruptor: config map objeto entero + config.toml |
| `tests/mcp-probe-gating.test.sh` | vacía/bogus → 64 sin lanzar nada ni crear estado; `--spend` con `off` → pin en el registro del stub |
| `tests/doctor-env-matrix.test.sh` | casos `TANDEM_WEB_SEARCH` |
| `docs/ARCHITECTURE.md` | fila de la tabla de pins + párrafo del residual |
| `README.md` | overrides por entorno + mención en seguridad |
| `CHANGELOG.md` · `.claude-plugin/plugin.json` | entrada y bump 0.31.0 |
| `docs/BACKLOG.md` | estado M26 |

## Acceptance & proof

1. Con `TANDEM_WEB_SEARCH=off`, el argv de todo asiento — start (read-only), resume,
   swarm (tres tiers) — contiene `-c web_search=disabled` en la posición fija del
   bloque de pins, fijado byte a byte por `assert_argv`; en el transporte MCP, el
   map `config` del tool call lo contiene (comparación de objeto entero) y el
   `config.toml` efímero lleva la clave.
2. Sin la variable, el argv y la política efectiva de todo asiento no cambian y la
   suite existente pasa sin editar una sola aserción (las negativas de read-only
   incluidas). El ÚNICO cambio de salida del default es el banner de swarm, que
   gana el campo final `web_search=on` — intencional, y fijado por aserción
   positiva explícita en el test nuevo.
3. `TANDEM_WEB_SEARCH=on` es no-op en read-only y NO retira el pin de escritura.
4. Definida-pero-vacía o valor desconocido → 64 nombrando la variable, en los
   CUATRO ejecutables que gastan turnos (start, resume, swarm y `mcp-probe.sh`),
   sin invocar codex (ni exec ni tools/call), sin crear estado y con el contador de
   turno intacto.
5. El banner del seat de swarm muestra `web_search=off|on`; el doctor muestra el
   estado efectivo por clase de asiento y denuncia el valor inválido con `bad`.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint, las
tres capas obligatorias).

## Risks

- **Renombrado silencioso de la clave `web_search` en la CLI:** un rename convierte
  el pin en no-op sin ruido (la CLI acepta claves desconocidas con rc 0). Mitigación
  ya existente: `scripts/config-probe.sh` + job semanal `config-drift` vigilan
  exactamente eso; la clave ya está en su conjunto por el pin de escritura.
- **Divergencia validador/lector:** `web_search_validate` (en `_common.sh`) y la
  lectura en `codex_pins()` (en `_pins.sh`) deben reconocer el mismo conjunto; un
  valor que el validador acepte y el lector ignore sería un pin fantasma.
  Mitigación: comentario cruzado en ambos + el caso `on` del test nuevo (no-op
  explícito verificado en ambas direcciones).
- **Tests bajo `env -i`:** los casos nuevos deben exportar la variable DENTRO del
  caso (patrón ya usado por `TANDEM_ULTRA_*` en los tests de tiers); una exportación
  fuera del sandbox del runner no llega jamás al wrapper.
- **Churn accidental de literales:** cualquier desviación en la posición del pin
  rompería los literales de escritura existentes — la suite lo detecta, ese es su
  trabajo; el riesgo real es solo iteración extra, no regresión silenciosa.

## Out of scope

- Re-habilitar `web_search` en asientos de escritura (por ningún valor de ninguna
  variable): la promesa «sin red» de `implement.tpl` no se negocia aquí.
- Cambiar el default (los read-only conservan la búsqueda sin la variable).
- El perfil agregado `TANDEM_CONFIDENTIAL=1` (rechazado en Key decisions).
- Registrar el estado de `web_search` en `meta.json`/heartbeat/statusline: ningún
  criterio de aceptación lo pide y es derivable de env + rol; si se quiere como
  registro durable, es entrada nueva de backlog.
- Tocar `_mcp.sh` o el turno `--smoke` del doctor más allá de comentarios.

## Assumptions

Entrevista omitida: el brief (entrada M26 + enmienda E-A3, verificadas contra el
árbol) fija goal, mecanismo, validación, visibilidad y aceptación; las decisiones que
quedaban se derivaron con defaults conservadores y están razonadas en Key decisions:

- **Valores aceptados `{off, on}`** (el backlog solo nombra `off`; `on` añadido como
  no-op explícito, nunca como apertura).
- **Ubicación del validador en `_common.sh`** y lectura tolerante en `_pins.sh`
  (derivado del contrato de cero side effects que el doctor exige).
- **Formato del banner** (`web_search=on|off` como campo final) y **línea
  condicional** en start/resume (derivado de E-A3 + coste cero en el default).
- **Versión 0.31.0** (siguiente minor, convención del CHANGELOG).
