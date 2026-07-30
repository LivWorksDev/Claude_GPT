# Plan: swarm-preamble — concatenación del preámbulo ultra en el script, no en haiku

**Backlog:** M8 (P2/S) · **Fecha:** 2026-07-30 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 1/6)

## Goal

El wrapper `haiku` de cada seat ultra debe hoy escribir un fichero con "el contenido completo
del preámbulo, verbatim" antes del brief — un modelo pequeño reproduciendo texto largo
literalmente es exactamente donde aparecen mutaciones silenciosas, y la concatenación es
trabajo de máquina. El objetivo: `codex-swarm.sh` acepta el preámbulo como fichero y hace la
concatenación él mismo; el wrapper queda reducido a escribir su brief, lanzar y extraer. El
prompt final de cada seat debe contener el preámbulo byte a byte idéntico al fichero fuente.

## Approach

1. **`scripts/codex-swarm.sh` — flag `--preamble <file>`.**
   - Firma nueva: `codex-swarm.sh [--preamble <file>] <tier> <run-id> <seat> <prompt-file>`.
     El flag es OPCIONAL y va antes de los posicionales; la aridad de posicionales sigue
     siendo exactamente 4 (el contrato `argc extra → 64` que fija `swarm-usage-and-fail` se
     conserva, con y sin flag).
   - Validación fail-closed: `--preamble` sin valor → 64; fichero inexistente → 64; flag
     desconocido (`--*`) → 64 con el usage. Sin flag, comportamiento idéntico al actual.
   - Concatenación en el script: el fichero staged `$STATE_DIR/$SEAT_KEY.prompt.txt` (hoy un
     `cp` del prompt) pasa a construirse como `cat <preamble> <brief> >` — SIN inyectar
     ningún byte separador: el prompt final es preámbulo byte a byte + brief byte a byte
     (quien autora el preámbulo controla su newline final, como en cualquier fichero de
     texto). `codex exec` lee stdin desde ese staged file, que sigue siendo el registro
     durable de lo enviado. El argv de codex no cambia en nada.
2. **`skills/ultra/SKILL.md` — wrapper reducido.** El paso 1 del wrapper pasa de "escribe
   preámbulo completo + brief" a "escribe SOLO el BRIEF, verbatim"; el paso 2 añade
   `--preamble <PREAMBLE>` al comando. `<PREAMBLE>` se sigue resolviendo a ruta absoluta al
   autorar el workflow — ahora viaja como ruta, no como contenido reproducido por haiku.
3. **Alimentación de codex desde el staged, en AMBOS modos.** `codex exec` pasa a leer
   stdin del staged `$STATE_DIR/$SEAT_KEY.prompt.txt` (hoy lee el `$PROMPT_FILE` original y
   el staged es solo una copia): con la concatenación dentro del script, el registro durable
   y lo que codex recibe son EL MISMO fichero, y la verificación byte a byte del test prueba
   lo enviado, no una copia paralela.
4. **Tests.**
   - `tests/swarm-usage-and-fail.test.sh` (ampliar): `--preamble` sin valor → 64;
     `--preamble` con fichero ausente → 64; flag desconocido → 64; y el caso de aridad con
     flag presente (`--preamble f` + 5 posicionales → 64) para que el contrato de firma no
     se relaje por la puerta del flag.
   - `tests/swarm-preamble.test.sh` (nuevo, comportamental con el stub): seat con
     `--preamble`: exit 0, y TANTO el staged `.prompt.txt` COMO el stdin registrado por el
     stub (`$CODEX_STUB_LOG.stdin.N`) comparados con `cmp` contra la concatenación de
     referencia `cat preamble brief` — nunca aserciones de "contiene"; seat SIN flag: los
     mismos dos `cmp` contra el brief solo; el preámbulo vive en una ruta CON espacios y
     caracteres de glob (caza un filename sin comillas) y su contenido lleva backslashes,
     `%s` y tabs (caza expansiones de printf) — los dos vectores de mutación silenciosa que
     motivan M8.
   - `tests/skill-ultra-preamble-contract.test.sh` (nuevo, estático): el wrapper de
     `skills/ultra/SKILL.md` escribe SOLO el brief (ancla positiva), invoca
     `codex-swarm.sh` con `--preamble` antes de los posicionales, y la instrucción vieja de
     reproducir "the full contents of <PREAMBLE>" ha desaparecido (ancla negativa) — sin
     esto, una implementación podría añadir el flag y conservar la copia manual, produciendo
     preámbulo duplicado con todos los tests comportamentales en verde.
5. **Metadatos — orquestador, tras la implementación:** `.claude-plugin/plugin.json` →
   `0.13.0`, `CHANGELOG.md` (entrada v0.13.0), `docs/BACKLOG.md` (M8 → `hecha (v0.13.0)`),
   y la fila de la cola autónoma → `hecha (<commit>)`. Coherente porque la rama se apila
   sobre v0.12.0 (ver Assumptions 5).

## Key decisions & tradeoffs

- **Flag opcional, nunca quinto posicional** (pre-registrada en la cola autónoma): el test
  `swarm-usage-and-fail` afirma deliberadamente que la aridad extra es 64 para cazar
  relajaciones accidentales de la firma; un flag con validación propia añade la capacidad
  sin tocar ese contrato.
- **`cat` sin separador inyectado:** la aceptación del backlog exige el preámbulo byte a
  byte idéntico; cualquier "mejora" (newline de cortesía, cabecera) rompería la
  verificabilidad con `cmp` y volvería a introducir mutación — esta vez del script. El
  newline final del preámbulo es responsabilidad de su autor (los ficheros de texto del
  repo ya terminan en newline por convención).
- **El staged `.prompt.txt` sigue siendo el registro durable:** auditar qué recibió un seat
  es un `cat` de un fichero; con la concatenación dentro del script, ese registro pasa a
  contener exactamente lo que codex leyó, preámbulo incluido.
- **Compatibilidad:** sin `--preamble` no cambia ni un byte del comportamiento actual — los
  workflows ultra ya escritos siguen funcionando mientras migran al wrapper reducido.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/codex-swarm.sh` | Flag `--preamble <file>` + concatenación staged con `cat` |
| `skills/ultra/SKILL.md` | Wrapper reducido a brief + ejecución + extracción |
| `tests/swarm-usage-and-fail.test.sh` | Casos de validación del flag y aridad con flag |
| `tests/swarm-preamble.test.sh` | Nuevo: concatenación byte a byte con el stub (staged Y stdin) |
| `tests/skill-ultra-preamble-contract.test.sh` | Nuevo: contrato estático del wrapper reducido |
| `.claude-plugin/plugin.json` | `version` → `0.13.0` (orquestador) |
| `CHANGELOG.md` | Entrada v0.13.0 (orquestador) |
| `docs/BACKLOG.md` | M8 → `hecha (v0.13.0)` (orquestador) |

## Acceptance & proof

- Un seat lanzado con `--preamble <file>` recibe como prompt exactamente
  `contenido(preamble) + contenido(brief)`, verificado byte a byte (`cmp`) en DOS puntos: el
  staged `.prompt.txt` y el stdin que el stub registró (lo realmente enviado a codex, del
  mismo fichero).
- Un preámbulo en una ruta con espacios/glob y con contenido backslashes/`%s`/tabs llega
  intacto (sin word-splitting del filename ni expansión de printf).
- Sin `--preamble`, staged y stdin son byte a byte el brief (comportamiento actual).
- `--preamble` sin valor, con fichero ausente, o un flag desconocido → exit 64 con usage;
  la aridad de 4 posicionales exactos se mantiene con y sin flag.
- El wrapper de la skill ya no contiene la instrucción de reproducir el preámbulo (contrato
  fijado estáticamente); solo brief + ejecución + extracción.

**PROOF:** `bash tests/verify.sh` (el punto de entrada único de verificación: suite completa
+ shellcheck + actionlint pineados — el mismo gate bloqueante del CI y el que exige la cola
autónoma; `bash tests/run.sh` queda como check intermedio rápido durante el desarrollo). En
particular `swarm-parallel-seats` y `swarm-tiers-readonly-literal` deben seguir verdes sin
cambios.

## Risks

- **Relajación accidental de la firma:** mitigada con los casos de aridad con flag.
- **Orden de parsing en bash 3.2:** el parsing del flag es un `while case` simple antes de
  los posicionales; sin `getopts` largo (no existe en bash 3.2 para long options), sin
  arrays asociativos.
- **Workflows ultra en vuelo escritos con el patrón viejo:** siguen funcionando (el flag es
  opcional y el wrapper viejo escribía él mismo la concatenación completa).

## Out of scope

- M13 (semáforo de concurrencia en el script) — el chunking manual sigue como está.
- Cambios en `codex-start.sh`/`codex-resume.sh` (el preámbulo es un concepto ultra).
- El resto de la cola (M9, M12, M5, M7, M10).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Flag o quinto posicional?** → Flag `--preamble`, pre-registrado en la cola autónoma
   por la razón del contrato de aridad; no es una elección nueva de este plan.
2. **¿Separador entre preámbulo y brief?** → Ninguno: byte a byte, la aceptación del
   backlog lo exige y `cmp` lo verifica. El autor del preámbulo controla su newline final.
3. **¿Dónde queda el registro durable?** → En el staged `.prompt.txt` del seat, como hoy;
   ahora contiene la concatenación completa que codex realmente leyó.
4. **¿Metadatos?** → Orquestador tras la implementación (contrato de ambos transportes),
   versión 0.13.0, en la rama tandem.
5. **¿Rama y orden de merge?** → `tandem/swarm-preamble` se APILA sobre
   `tandem/plan-commit-branch` (v0.12.0, run COMPLETED con review APPROVED), declarando la
   dependencia: la cola produce un run por tarea y cada run bumpa versión y toca
   plugin.json/CHANGELOG/BACKLOG, así que N ramas independientes desde main colisionarían
   TODAS entre sí en los metadatos — la forma natural de la cola es una cadena tipo serie de
   parches, mergeada en orden (M3 → M8 → …). Beneficio adicional: la aprobación de este plan
   usa el `plan-approve.sh` real (dogfooding del flujo recién aprobado) en vez de la danza
   manual. Si el usuario rechaza M3 en su revisión, M8 se rebasa — coste asumido y visible,
   no un conflicto silencioso.
