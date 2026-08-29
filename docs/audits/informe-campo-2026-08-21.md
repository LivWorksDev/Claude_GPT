# Informe de campo — evaluación externa de tandem v0.30.0

**Fecha del informe:** 2026-08-21 · **Recibido y verificado:** 2026-08-29
**Objeto:** tandem@0.30.0 (este repo) · **Banco de pruebas:** monorepo Electron/pnpm
comercial, en producción · **Método del evaluador:** lectura estática del código + 3
lectores adversariales; cada cita verificada a mano
**Origen:** informe externo hecho llegar al mantenedor como artifact
(`claude.ai/code/artifact/95041886-0f30-4a4a-adf5-59075541bd34`); este documento es el
registro durable — el artifact puede desaparecer, esto no.

**Verificación local (2026-08-29):** las 10 citas `file:line` del informe se comprobaron
una a una contra el árbol de este repo en v0.30.0 (HEAD `8e14367`) y **todas son
correctas**. Ninguno de los hallazgos ha sido corregido entre el informe y la
verificación. Las enmiendas del §Verificación amplían o corrigen matices, nunca
contradicen la evidencia.

Cada hallazgo está registrado como entrada accionable en `docs/BACKLOG.md` (M24–M33),
con las enmiendas ya incorporadas. Este documento conserva el informe íntegro y el
razonamiento; el backlog es lo que se ejecuta.

| Informe | Backlog | Slug sugerido |
| --- | --- | --- |
| A1 | M24 | `exec-watchdog` |
| A2 | M25 | `implement-write-audit` |
| A3 | M26 | `web-search-switch` |
| M1 | M27 | `status-ultra` |
| M2 | M28 | `token-rollup` |
| M3 | M29 | `swarm-salvage` |
| M4 | M30 | `slot-reap` |
| B1 | M31 | `plans-dir` |
| B2 | M32 | `log-machine-fields` |
| B3 | M33 | `adoption-guide` |

---

## El informe, transcrito

### §1 — Por qué este banco de pruebas estresa el diseño

El proyecto usado reúne, sin buscarlo, casi todos los rasgos que el diseño de tandem
trata de contener: un monorepo pnpm con hoisting dirigido donde dependencias que parecen
redundantes son load-bearing; un parche vivo vía `patchedDependencies` que una
instalación con flags equivocados regenera en silencio; una app con red de tests casi
nula en el renderer; código comercial privado; y un incidente previo real — un agente
delegado con `workspace-write` y aprobaciones en `never` que entró en bucle de
auto-reparación del entorno (instalaciones con la versión equivocada de pnpm, purgas de
`node_modules`, saqueo de módulos de otros árboles) en lugar de parar e informar. Ese
incidente es exactamente la clase de fallo que los pins de tandem existen para impedir.

### §2 — Lo que no hay que tocar (invariantes confirmados como load-bearing)

- Re-pin del sandbox en cada turno más `--ignore-user-config --ignore-rules`: elimina la
  clase entera de escapes vía configuración heredada, en lugar de enumerarlos.
- El argv congelado byte a byte por la suite, con aserciones negativas
  (`danger-full-access` y `workspace-write` no aparecen en asientos read-only) —
  `tests/swarm-tiers-readonly-literal.test.sh:21`.
- `config-probe.sh`: tratar «la CLI aceptó una clave desconocida con rc 0» como amenaza
  real es la pieza más inusual y valiosa del repo.
- Contabilidad antes del éxito: el usage se persiste aunque el wrapper rechace el turno
  después — los reintentos cuentan.
- Fail-closed por defecto (`worktree-root.sh`, `plan-approve.sh`, la validación de cada
  variable de entorno): parar antes que adivinar, en todas partes.
- PRESENTE ≠ VÁLIDO ≠ PROBADO en `tandem:status`: reconstruir desde disco, degradar a
  «desconocido», y exit 2 ante contradicción en vez de elegir un ganador en silencio.

### §3 — Hallazgos

#### A1 (Alta) — El transporte exec — el default — no tiene watchdog de turno

**Qué.** `codex exec` se lanza sin deadline, y las skills mandan
`run_in_background: true` para el trabajo real — donde el tope de 600 s del tool Bash no
aplica. Un turno colgado es ilimitado. En un enjambre, además, retiene uno de los 4
slots del semáforo: el timeout de 1800 s acota la espera de slot, no al que lo ocupa.

**Evidencia.** `scripts/codex-swarm.sh:281-290` (`codex exec …` sin timeout);
`scripts/codex-start.sh:143-153` (ídem); `scripts/_mcp.sh:35,48` — el transporte MCP SÍ
tiene deadline por rol (540 s / 3600 s) con TERM→KILL y reaping de grupo: la pieza ya
existe.

**Por qué en cualquier proyecto.** El modo de fallo más común de una CLI headless no es
el error: es el cuelgue. Hoy el único observador es humano (la statusline), y el coste
de un cuelgue crece con la concurrencia.

**Propuesta.** Portar el watchdog del transporte MCP al exec: mismo deadline por rol,
misma familia de variables (`TANDEM_*_TIMEOUT_SECONDS`, validación fail-closed),
TERM→KILL con grupo de proceso, y el heartbeat cerrando en `failed`. Es una
generalización, no una pieza nueva.

#### A2 (Alta) — Los vectores de escritura que quedan tras el sandbox los frena solo la prosa

**Qué.** Con `workspace-write` la red está bloqueada por flag (bien), pero dentro de la
raíz escribible quedan tres vectores que solo prohíbe el template: reescribir el
lockfile, purgar `node_modules`, y copiar ficheros hacia dentro desde otro árbol (leer
fuera de la raíz está permitido). En el implementador Opus por defecto ni siquiera hay
sandbox de SO — el README lo declara como riesgo residual explícito — así que ahí la
prosa es la única barrera también para las instalaciones.

**Evidencia.** `skills/implement/prompts/implement.tpl:11,13` (prohibiciones en prosa);
`agents/implementer.md:4-5` (Opus: allowlist con Bash, sin sandbox SO);
`skills/image/SKILL.md:29,75` — el patrón que falta, ya implementado: snapshot
`git status --porcelain` previo + auditoría posterior de cada escritura; toda entrada no
declarada se enseña verbatim y se ofrece revertir.

**Por qué en cualquier proyecto.** La lección del incidente de julio es que la prosa no
para a un modelo en bucle de reparación. Y el daño de esos vectores es el más caro de
diagnosticar: un lockfile regenerado o un parche pnpm perdido no falla en el momento —
falla semanas después, en otra máquina.

**Propuesta.** Generalizar la auditoría de escrituras del modo imagen a `implement`
(ambos transportes): snapshot previo, y al cierre un diff de escrituras contra una
deny-list por defecto — `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, la sección
de dependencias de `package.json`, `.npmrc`, `patches/`, borrados bajo `node_modules` —
donde cualquier toque no declarado en el plan produce `IMPLEMENTATION_PARTIAL` con el
hallazgo nombrado, nunca aceptación silenciosa. Para el transporte Opus, además, un hook
`PreToolUse` que bloquee mecánicamente `pnpm|npm|yarn install` durante un intento.

#### A3 (Alta) — Los asientos read-only conservan `web_search`: falta un interruptor de confidencialidad

**Qué.** `web_search` solo se apaga en asientos de escritura; los read-only lo conservan
a propósito (decisión documentada, con el residual registrado en `ARCHITECTURE.md`). El
resultado, invertido desde la óptica de un repo privado: los asientos que más contenido
del repo leen — refutadores, revisores, jueces de enjambre — son los que tienen un canal
de salida adicional, porque fragmentos de código pueden acabar en queries de búsqueda
hacia terceros, más allá del propio OpenAI.

**Evidencia.** `scripts/_pins.sh:56-58`; `docs/ARCHITECTURE.md:76` (el residual,
registrado honestamente).

**Por qué en cualquier proyecto.** El trade-off correcto depende del repo: en uno open
source, búsqueda activa en el revisor es puro valor; en uno comercial es una decisión de
tratamiento de datos que hoy el usuario del plugin no puede tomar — no hay mando.

**Propuesta.** `TANDEM_WEB_SEARCH=off` (o un perfil `TANDEM_CONFIDENTIAL=1`) que pinee
`web_search=disabled` en todos los asientos, validado fail-closed como el resto de
variables, y con el estado efectivo visible en `tandem:doctor`. El default actual puede
quedarse; lo que falta es el interruptor.

#### M1 (Media) — `tandem:status` excluye los runs de ultra

**Qué.** El escáner de runs filtra `ultra-*` explícitamente. Para el caso de uso
«descargar la verificación adversarial a Sol» — el que más cuota mueve — la máquina de
estados que responde «¿dónde estaba?» no responde.

**Evidencia.** `scripts/tandem-status.sh:1361-1365` (`case "$s" in ultra-*) return 0`);
`.tandem/state/ultra/<run>/` — los datos ya están en disco: seats, prompts, usage.json
por seat, slots.

**Propuesta.** Una vista mínima, con la misma disciplina de no inventar: seats
lanzados/completados/fallidos (derivables de los ficheros de slot y usage), suma de
tokens del run, y la ruta del informe `.tandem/log/ultra-<run>.md`.

#### M2 (Media) — No hay agregación de tokens entre runs; las dos mitades de la statusline usan unidades incomparables

**Qué.** La contabilidad por turno es sólida, pero es por-slug: nada suma «cuánto
descargué esta semana». Y la statusline muestra la sesión Claude en dólares y el turno
Sol en tokens.

**Evidencia.** `scripts/tandem-status.sh` (tokens por slug, sin ventana temporal);
`scripts/statusline.sh` (línea 1 en USD · línea 2 en tokens).

**Propuesta.** `tandem:status --tokens [--since <fecha>]`: un rollup sobre los ledgers
`*.usage.json` ya persistidos (incluidos los de ultra), por rol y por día. Un agregador
de ficheros que ya existen — sin turno de modelo, coherente con la filosofía de que
status nunca gasta.

#### M3 (Media) — Los asientos de enjambre no tienen reparación de contrato

**Qué.** `plan`, `review`, `implement` e `image` tienen `nudge.tpl` — el
turno-recordatorio barato que pide solo la línea que faltó, con `TANDEM_TURN_EFFORT`
para no re-pagar el razonamiento. `ultra` no: sus asientos son hilos frescos sin resume
por diseño, así que un seat que razona bien pero rompe el contrato JSON de salida se
relanza a coste completo.

**Evidencia.** `skills/ultra/prompts/` (solo `seat-preamble.md` — no hay nudge);
`skills/*/prompts/nudge.tpl` existe en plan, review, implement, image.

**Propuesta (del informe).** Un resume solo-nudge para el seat que ya produjo respuesta
pero sin contrato (`TANDEM_TURN_EFFORT=minimal`, mismo hilo). Alternativa más barata:
salvage tolerante en el wrapper (extraer el último bloque JSON válido) antes de declarar
el seat fallido. *(Ver enmienda E-M3: el orden correcto es el inverso.)*

#### M4 (Media) — El slot huérfano tras SIGKILL exige cirugía manual

**Qué.** Un seat muerto por SIGKILL (lo único que salta el trap EXIT) deja su
`.slots/slot.N` ocupado y el heartbeat en `running`; la limpieza es manual. El
comentario del código explica por qué no hay auto-reclaim — probar el pid del holder
para robar el slot añadiría las carreras rm/mkdir que el semáforo existe para eliminar —
y esa razón es correcta para el reclaim concurrente.

**Evidencia.** `scripts/codex-swarm.sh:210-218` (el no-reclaim, documentado);
`tests/hb-term-vs-kill.test.sh:2-6` (la asimetría TERM/KILL, pineada).

**Propuesta (del informe).** (a) reap solo al arranque del run, antes de lanzar ningún
seat; (b) un `codex-swarm.sh --reap <run>` explícito que el mensaje de error pueda
nombrar. *(Ver enmienda E-M4: la variante (a) es más débil de lo que aparenta.)*

#### B1 (Baja) — `docs/plans/` fijo colisiona con repos que ya tienen convención de planning

**Evidencia.** `scripts/plan-approve.sh:17-24` (transición fail-closed sobre ruta fija;
la ruta literal en `:77`, `PLAN_REL="docs/plans/$SLUG.plan.md"`).

**Propuesta.** `TANDEM_PLANS_DIR` (default `docs/plans`), validada fail-closed, y una
nota de interop en el README para repos con planning preexistente.

#### B2 (Baja) — Parte del registro durable depende de que el modelo copie bien datos que ya existen a máquina

**Qué.** El `USAGE:` por ronda en el log del slug, el bloque del gate y la línea final
con el sha del commit los escribe el modelo siguiendo prosa — cuando el usage ya está en
los ledgers y el sha en git. Un modelo que transcribe mal no rompe nada, pero ensucia el
registro que status luego lee.

**Propuesta.** Derivar esos campos de la fuente máquina al escribir el log (ledger para
usage, `git rev-parse` para el sha) y dejar la copia del modelo como narrativa, no como
registro.

#### B3 (Baja) — Falta guía de adopción para repos con políticas previas de delegación

**Qué.** Hallazgo de campo literal: el CLAUDE.md del banco de pruebas aún dice «Codex
retirado» por el incidente anterior — y un agente fresco que lee eso rehúsa usar el
plugin aunque esté instalado y sea precisamente la respuesta a aquel incidente.

**Propuesta.** Una sección de adopción en el README con un snippet de CLAUDE.md listo
para pegar: qué asientos están sancionados (read-only), cuáles requieren decisión
(implement), y que el sandbox lo garantiza el plugin, no la memoria del proyecto.

### §5 — Cierre del informe

El núcleo del diseño — estructural antes que prometido: sandbox re-pineado por turno,
config del usuario fuera, argv congelado por tests, fail-closed en cada borde — es el
correcto. Los diez puntos no proponen otra filosofía: proponen extender esa misma
filosofía a los rincones donde hoy la última barrera sigue siendo prosa (A2), un humano
mirando una statusline (A1, M4), o un mando que no existe (A3). Las tres piezas más
caras ya están escritas dentro del propio repo: el watchdog vive en `_mcp.sh`, la
auditoría de escrituras en el modo imagen, y el nudge barato en los otros cuatro skills.

---

## Verificación y enmiendas (mantenedor, 2026-08-29)

Toda cita comprobada contra HEAD `8e14367` (v0.30.0). Las enmiendas siguientes están
**ya incorporadas** en las entradas M24–M33 del backlog; se registran aquí con su
razonamiento completo.

### E-A1 — El alcance de A1 se queda corto: falta `codex-resume.sh`, y eso alcanza también al transporte MCP

El informe cita los wrappers de arranque, pero `scripts/codex-resume.sh:157` lanza
`codex exec resume` igualmente sin deadline. Importa más de lo que parece: bajo
`TANDEM_TRANSPORT=mcp` las continuaciones viajan **siempre** por el híbrido
`exec resume` (un hilo no sobrevive al servidor que lo creó), así que hoy el watchdog
solo protege el primer turno de cada hilo — las rondas 2+ de una review a xhigh, los
turnos más largos del sistema, quedan sin observador incluso en el transporte «bueno».
M24 incluye `codex-resume.sh` en su alcance explícitamente.

Dos efectos colaterales a favor: (1) el watchdog con TERM primero dispara el trap EXIT
del seat, que libera el slot — M24 reduce de rebote la incidencia de M30; (2) desactiva
a coste S–M uno de los disparadores declarados de M23 («un watchdog por seat que el
semáforo no cubra») sin pagar la migración L del swarm a MCP.

Restricción a respetar (la documenta `_mcp.sh:29-36`): el default de foreground debe
quedar por debajo del tope de 600 s del tool Bash, o el orquestador mata al wrapper
antes de que el watchdog clasifique el cuelgue y contabilice el turno.

### E-A2 — El hook `PreToolUse` es de sesión completa; el diseño real es el marcador de intento-activo

Un hook que envía un plugin dispara en **cada** llamada Bash de toda la sesión, no solo
dentro del intento del subagente Opus. Para acotar «durante un intento», el script del
hook tiene que consultar un marcador durable de intento-activo en `.tandem/state`, y el
ciclo de vida de ese marcador (quién lo pone, quién lo limpia, qué pasa tras un crash)
es el diseño real de la pieza — no un detalle. La deny-list en sí está bien planteada:
ya incluye la válvula «declarado en el plan gana».

### E-M3 — Invertir el orden: salvage primero, nudge solo si el salvage no basta

El salvage tolerante en el wrapper cuesta cero tokens y cero discusión de diseño. El
nudge-resume choca con un invariante documentado en la propia cabecera de
`codex-swarm.sh` («No thread persistence and no resume … deliberate») y exigiría
empezar a persistir thread ids del enjambre. M29 registra salvage como propuesta
principal y el nudge como escalada condicionada a datos reales de insuficiencia.

### E-M4 — La variante (a) del informe es más débil de lo que aparenta; priorizar `--reap`

El semáforo es por-run (`.tandem/state/ultra/<run>/.slots/`) y cada seat es una
invocación independiente del script: un run nuevo nace con el directorio de slots vacío,
así que los huérfanos solo muerden al **reintentar seats del mismo run**, donde no
existe un momento «arranque del run» al que anclar el reap — la precondición «antes de
lanzar ningún seat» sería prosa, justo lo que el informe critica en A2. M30 prioriza la
variante (b): `--reap <run>` explícito con comprobación de vida del pid del holder,
nombrado en el mensaje de error de `codex-swarm.sh:246`. Con M24 dentro, la incidencia
baja además por sí sola.

### E-M2 — Acotar la expectativa: tokens con tokens, nunca conversión a dólares

El «ratio de descarga» no se puede calcular sin tablas de precios de ambos proveedores
(que cambian y quedarían rancias dentro del repo). El rollup por rol y día sobre los
ledgers ya persistidos es el alcance correcto; M28 lo fija así explícitamente.

### E-A3 — Además del doctor, el banner del seat

El estado efectivo de `web_search` debería verse también en la línea de banner que cada
seat de swarm ya imprime (`codex-swarm.sh:270-271`) — cuesta cero y es donde un run en
vivo se observa. Incorporado a M26.

### E-B2 — El repo ya enuncia el principio

El comentario del preámbulo en `codex-swarm.sh` dice literalmente «machine work, not
something a wrapper model should retype verbatim». M32 es aplicar la casa a la casa.

### Orden de ataque recomendado para la cohorte

**M26 → M24 → M25 → M30 → M28 → M27 → M29 → M31/M32/M33** — riesgo real ponderado con
esfuerzo: M26 es el mejor coste/valor (S y cierra un canal de datos); M24 elimina la
clase de fallo operativo más común y de rebote reduce M30; M25 es el de más valor
absoluto (la clase del incidente motivador) pero exige diseñar el ciclo de vida del
marcador de intento; el resto es incremental y sin dependencias entre sí.

---

## Retomar esto desde otra máquina

Todo lo necesario está en el repo: este documento (contexto y razonamiento) y
`docs/BACKLOG.md` M24–M33 (entradas accionables, autocontenidas). El proceso es el
documentado en el backlog: cada mejora entra por `/tandem:plan <slug>`, y su estado se
traza allí. Prompt sugerido para arrancar en un cliente nuevo:

> Estamos en el repo del plugin tandem. Lee `docs/audits/informe-campo-2026-08-21.md`
> (un informe de campo externo sobre v0.30.0, verificado cita a cita, con enmiendas del
> mantenedor) y las entradas M24–M33 de `docs/BACKLOG.md`, que son su forma accionable.
> Quiero empezar a implementarlas siguiendo el proceso del propio repo: por el pipeline
> tandem (`/tandem:plan <slug>` → gate → `/tandem:implement` → `/tandem:review`), en el
> orden recomendado M26 → M24 → M25 → M30 → M28 → M27 → M29 → M31/M32/M33, actualizando
> el estado de cada entrada en el backlog al avanzar. Empieza por M26
> (`web-search-switch`): lánzame `/tandem:plan web-search-switch` con el contenido de la
> entrada M26 y su enmienda E-A3 como material de partida.
