# Plan: token-accounting — contabilidad de tokens por turno, ronda y run

**Backlog:** M9 (P2/M) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 2/6)

## Goal

Cada `turn.completed` del NDJSON que ya se persiste trae `usage` (`input_tokens`,
`output_tokens`); hoy solo se narra en vivo por `stream_milestones` y se descarta. La cuota
ChatGPT es la restricción operativa real y no hay forma de saber cuánto costó un turno, una
ronda o un run. Objetivo: persistir el usage por turno junto a los demás artefactos del
turno, llevarlo en el heartbeat para que la statusline lo muestre al terminar, y que las
skills lo agreguen en las líneas de ronda del log del slug y en los informes finales
(interactivo, autonomous y run report de ultra). Sin dependencias nuevas.

## Approach

1. **`scripts/_common.sh` — helper `turn_usage <events-file>`.** Extrae con jq TODOS los
   `turn.completed` del NDJSON y emite un objeto JSON compacto que es la SUMA campo a campo
   de sus `.usage` (campos numéricos sumados; con un solo evento la suma es el objeto
   verbatim). Base empírica documentada en el propio helper: 36/36 streams reales de la CLI
   0.144.4 archivados en `.tandem/state/review/` contienen exactamente UN `turn.completed`,
   así que la suma es la identidad en el caso universal observado, y si el CLI emitiera
   varios eventos por-intento, sumar captura el gasto total en vez de descartar los
   reintentos — el caso que la contabilidad existe para exponer. Los nombres de campo son
   los de codex, verbatim (el objeto real trae `input_tokens`, `cached_input_tokens`,
   `output_tokens`, `reasoning_output_tokens`; campos futuros viajan gratis). Sin
   `turn.completed` o con líneas malformadas intercaladas → imprime nada y retorna 0.
2. **`scripts/codex-start.sh` y `scripts/codex-resume.sh` — persistencia INMEDIATA tras el
   pipeline + heartbeat + footer.**
   - **Cuándo:** justo después de capturar `rc="${PIPESTATUS[0]}"` y ANTES de cualquier
     check (`rc`, `$MSG_FILE`, thread id, guard anti-fallback): un turno que quemó cuota se
     contabiliza AUNQUE el wrapper luego falle — reply vacía, thread ausente o fallback
     rechazado ya pagaron sus tokens. "Turno sin usage" significa "el stream no contiene
     ningún `turn.completed` válido", nunca "el wrapper salió con código ≠ 0".
   - **Persistencia:** `$STATE_DIR/$KEY.t$TURN.usage.json` (solo si `turn_usage` emitió
     algo), escrito de forma atómica y blindada — fichero temporal en el mismo directorio +
     `mv`, con TODOS los fallos de escritura tragados (`|| true`): bajo `set -euo pipefail`
     una redirección fallida abortaría un turno exitoso, y la contabilidad jamás cambia el
     exit code documentado ni deja JSON truncado visible.
   - **Heartbeat:** `hb_write` gana `tokens_in`/`tokens_out` (null sin datos; en `running`
     SIEMPRE null), poblados vía `HB_TOKENS_IN`/`HB_TOKENS_OUT` antes del `hb_end` — también
     en los caminos de FALLO posteriores al pipeline (el heartbeat `failed` de una reply
     vacía lleva los tokens que ese turno quemó).
   - **Footer parseable en TODOS los caminos:** exactamente UNA línea `USAGE: <json
     compacto>` emitida por stderr inmediatamente tras la extracción/persistencia y ANTES de
     cualquier check post-pipeline (omitida solo si no hay datos) — así existe también cuando
     el wrapper muere después (reply vacía, thread ausente, fallback rechazado), que es
     exactamente cuando los informes FAILED/DEADLOCK la necesitan. Es lo que las skills
     copian a la línea de ronda del log sin derivar rutas con `target_key`. Los tres tests
     de fallo la asertan.
3. **`scripts/codex-swarm.sh` — ledger por INTENTO de seat.** Un retry de seat sobreescribe
   sus ficheros por contrato, pero el usage es un ledger de cuota ya quemada: se persiste
   por intento como `$SEAT_KEY.t<N>.usage.json` (N = siguiente índice libre, derivado de los
   ficheros existentes — los retries de un seat son secuenciales, no hay carrera), con la
   misma atomicidad blindada y la misma regla de momento (tras el pipeline, antes de los
   checks). Footer `USAGE: <json>` + `USAGE_FILE: <ruta>` emitidos por stderr en el MISMO
   punto (tras la persistencia, antes de los checks — presentes también en seats fallidos).
   La agregación suma TODOS los intentos de todos los seats.
4. **`scripts/statusline.sh` — tokens al terminar, saneados.** El transporte `\x1f` del
   heartbeat gana los dos campos nuevos (al FINAL de la lista, para que un heartbeat viejo
   sin ellos degrade a vacío sin desplazar campos) y los estados terminales (`done`/`failed`)
   los renderizan humanizados (`· 1.2k→56`; k/M con una decimal máxima, aritmética entera de
   bash sin `bc`) solo cuando AMBOS son enteros no negativos — cualquier otra cosa (string,
   decimal, negativo, campo corrupto) omite el segmento entero, igual que ya se sanean pid y
   timestamps antes de cualquier aritmética. El estado `running` no los muestra (null por
   contrato).
5. **Skills — paso de contabilidad INCONDICIONAL, antes de ramificar por veredicto.**
   - `skills/plan/SKILL.md` y `skills/review/SKILL.md`: nuevo paso fijo tras CADA
     invocación de start/resume y ANTES de leer el `VERDICT:` — copiar la línea `USAGE:` del
     output del turno a la línea de ronda del log (una ronda APPROVED a la primera o un
     NEEDS_REWORK también se contabilizan; hoy el log solo se escribía en la rama
     REVISE/REQUEST_CHANGES). El resumen final (Resolution / Step 4) incluye el total
     agregado de la fase sumando las líneas de ronda.
   - `skills/implement/SKILL.md`: bajo transporte `sol`, el mismo paso incondicional por
     turno/continuación; bajo `opus` no hay turnos codex — se anota
     `tokens: n/a (transporte opus)` para que la ausencia sea explícita y no un olvido.
   - `skills/run/SKILL.md`: el informe final del run (TODOS los estados terminales,
     DEADLOCK/PARTIAL/FAILED incluidos — sus turnos también costaron cuota) incluye el
     agregado por fase y el total del run.
   - `skills/ultra/SKILL.md`: el paso 3 del wrapper pasa a extraer TAMBIÉN las líneas
     `USAGE:`/`USAGE_FILE:` y su schema gana los campos `usage`/`usage_file`, AMBOS
     nullables (un `turn.failed` genuino no emite footer) y devueltos por CADA seat
     incluidos los de exit ≠ 0. **Algoritmo de agregación único y autoritativo:** el TOTAL
     se computa sumando cada fichero `.t<N>.usage.json` del ledger EXACTAMENTE UNA VEZ por
     seat — el `usage` devuelto por el wrapper es metadato de display por invocación y NUNCA
     se añade al total (el intento vigente ya está en su ledger; sumarlo dos veces es el
     double-count que esta regla prohíbe). El `usage_file` sirve SOLO para casar el prefijo
     del ledger de cada seat con la asignación seat→tier que el propio workflow autoró —
     nunca reconstruyendo hashes de `target_key` (el checksum no es reversible) — y el
     metadato de un intento anterior exitoso se retiene cuando un retry posterior falla sin
     footer.
6. **Tests.**
   - `tests/common-turn-usage.test.sh` (nuevo): fixture con UN `turn.completed` → objeto
     verbatim (igualdad jq exacta); sin `turn.completed` → salida vacía rc 0; DOS
     `turn.completed` → suma campo a campo; líneas malformadas intercaladas → se ignoran;
     campos no numéricos en usage → no rompen la suma.
   - `tests/start-happy.test.sh` / `tests/resume-happy-argv-repin.test.sh` (ampliar): el
     turno ok deja `$KEY.t$TURN.usage.json` con exactamente el usage del stub
     (`input_tokens:1234, output_tokens:56` — igualdad jq, no "contiene"), el heartbeat
     `done` lleva `tokens_in:1234, tokens_out:56`, y el output contiene la línea `USAGE:`.
   - **Turnos que queman cuota y luego fallan** (ampliar `start-empty-reply-exit1`,
     `start-no-thread-event-exit1`, `resume-fallback-guard-full`): el exit code documentado
     NO cambia, pero el `.usage.json` del turno EXISTE con los tokens del stub y el
     heartbeat `failed` los lleva — la cuota quemada por un turno rechazado se contabiliza.
     El escenario `fail` del stub (sin `turn.completed`) no deja fichero.
   - **Persistencia blindada** (caso nuevo): destino de usage no escribible → el turno
     conserva su rc y su heartbeat originales, sin JSON truncado visible.
   - `tests/hb-running-snapshot.test.sh` y `tests/common-hb-write-nulls.test.sh` (ampliar):
     `running` → `tokens_in:null, tokens_out:null`; null JSON real sin datos.
   - `tests/swarm-parallel-seats.test.sh` (ampliar) + casos de retry en el test que toque:
     cada seat ok deja `.t1.usage.json`; retry exitoso del mismo seat añade `.t2.usage.json`
     sin pisar el t1 (éxito→éxito suma dos intentos); retry con escenario `fail` no añade
     fichero y el t1 previo queda intacto (éxito→fallo no confunde el ledger). Footer
     `USAGE_FILE:` presente.
   - `tests/statusline-verdict-icons.test.sh` / `tests/statusline-x1f-empty-fields.test.sh`
     (ampliar): `done` con `1234/56` renderiza `1.2k→56`; campos ausentes/vacíos no
     desplazan nada; heartbeat VIEJO sin los campos renderiza la línea completa sin tokens.
   - `tests/statusline-never-fail.test.sh` (ampliar): `tokens_in`/`tokens_out` malformados
     (string, decimal, negativo) → exit 0, stderr vacío, segmento de tokens omitido.
   - `tests/skill-token-accounting-contract.test.sh` (nuevo, estático): las cinco skills
     contienen su instrucción — ancla del paso incondicional "antes de leer el VERDICT" y
     `USAGE:` en plan/review; `USAGE:` y `tokens: n/a (transporte opus)` en implement;
     agregado por fase y total (todos los estados terminales) en run; en ultra, el wrapper
     extrae `USAGE:`/`USAGE_FILE:` con `usage`/`usage_file` nullables también en el camino
     de fallo, el total sale del ledger exactamente una vez por seat y el `usage` devuelto
     jamás se suma (anclas de la regla anti-double-count).
7. **Metadatos — orquestador tras la implementación:** `.claude-plugin/plugin.json` →
   `0.14.0`, `CHANGELOG.md`, `docs/BACKLOG.md` (M9 → `hecha (v0.14.0)`), fila de la cola.

## Key decisions & tradeoffs

- **Suma campo a campo, no "last wins".** La forma de múltiples `turn.completed` no está
  documentada por el CLI; la evidencia local (36/36 streams reales con exactamente uno) hace
  la suma idéntica al verbatim en el caso universal, y si aparecieran eventos por-intento,
  sumar contabiliza los reintentos en vez de descartarlos — descartar es el único error
  irrecuperable aquí. Los campos son los de codex verbatim (`input_tokens`,
  `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens` observados); los
  consumidores solo asumen dos claves y toleran su ausencia.
- **Extracción tras el pipeline, ANTES de los checks.** Una reply vacía o un fallback
  rechazado ya quemaron su cuota: contabilizar solo turnos "exitosos" infracontaría
  exactamente los casos caros. "Sin usage" = "sin `turn.completed` en el stream", nunca
  "wrapper salió ≠ 0".
- **Best-effort, nunca un gate.** La contabilidad no puede tumbar un turno que costó cuota
  real: escritura atómica (tmp + mv en el mismo directorio) con fallos tragados — bajo
  `set -euo pipefail` una redirección fallida abortaría el turno. Mismo contrato que el
  heartbeat.
- **Footer `USAGE:` parseable en el output del turno.** Las skills copian una línea, no
  derivan rutas con `target_key` (que lleva un checksum que Fable tendría que recomputar).
  El fichero durable queda como fuente de verdad; el footer es el transporte hacia el log.
- **Ledger por intento en swarm.** El retry de un seat sobreescribe sus artefactos por
  contrato, pero la cuota del intento anterior ya se gastó: `.t<N>.usage.json` acumula,
  nunca pisa.
- **Campos nuevos al FINAL del transporte `\x1f`.** Un heartbeat escrito por una versión
  vieja no desplaza los campos existentes de la statusline nueva (degrada a tokens vacíos);
  el precedente del bug de campos desplazados (v0.5.0) es exactamente lo que esto evita.
- **`running` lleva tokens null SIEMPRE.** El usage solo existe al cerrar el turno;
  mostrar tokens de un turno anterior mientras corre otro sería mentir (la regla
  "last_sentinel describe un turno PREVIO" del attempt state, aplicada aquí).
- **La agregación vive en las skills (Fable), no en los scripts.** Los scripts persisten el
  dato crudo; quién lo suma y dónde lo escribe es el orquestador — los scripts no conocen
  rondas ni runs, y el log del slug lo escribe Fable por contrato existente.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/_common.sh` | Helper `turn_usage` + campos `tokens_in`/`tokens_out` en `hb_write` |
| `scripts/codex-start.sh` | Persistir `.t<N>.usage.json` + tokens en `hb_end` |
| `scripts/codex-resume.sh` | Ídem |
| `scripts/codex-swarm.sh` | Ledger `.t<N>.usage.json` por intento de seat + footer stderr |
| `scripts/statusline.sh` | Transporte ampliado + render humanizado en estados terminales |
| `skills/plan/SKILL.md` · `skills/review/SKILL.md` · `skills/implement/SKILL.md` · `skills/run/SKILL.md` · `skills/ultra/SKILL.md` | Instrucciones de contabilidad por ronda/fase/run |
| `tests/common-turn-usage.test.sh` · `tests/skill-token-accounting-contract.test.sh` | Nuevos |
| `tests/start-happy.test.sh` · `tests/resume-happy-argv-repin.test.sh` · `tests/start-empty-reply-exit1.test.sh` · `tests/start-no-thread-event-exit1.test.sh` · `tests/resume-fallback-guard-full.test.sh` · `tests/hb-running-snapshot.test.sh` · `tests/common-hb-write-nulls.test.sh` · `tests/hb-term-vs-kill.test.sh` (si aserta el JSON completo) · `tests/swarm-parallel-seats.test.sh` · `tests/statusline-verdict-icons.test.sh` · `tests/statusline-x1f-empty-fields.test.sh` · `tests/statusline-never-fail.test.sh` | Ampliar contratos |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.14.0 (orquestador) |

## Acceptance & proof

- Un turno start/resume exitoso deja `$KEY.t<N>.usage.json` con el usage del stub (igualdad
  jq exacta), heartbeat `done` con `tokens_in`/`tokens_out` numéricos, y línea `USAGE:` en
  el output; el snapshot `running` los lleva null.
- Un turno que quema cuota y LUEGO falla (reply vacía, thread ausente, fallback rechazado)
  conserva su exit code documentado pero deja su `.usage.json`, un heartbeat `failed` con
  los tokens Y la línea `USAGE:` en su salida (aserción en los tres tests de fallo); el
  escenario `fail` (sin `turn.completed`) no deja fichero ni línea.
- Un seat de swarm exitoso deja `.t1.usage.json`; su retry exitoso añade `.t2` sin pisar el
  t1; un retry fallido no añade ni corrompe. Footers `USAGE:`/`USAGE_FILE:` presentes en
  seats que quemaron cuota (también fallidos); ausentes en `turn.failed` genuino, y el
  schema del wrapper los declara nullables. El total ultra = suma del ledger, una vez por
  seat; el `usage` devuelto no se re-suma.
- Un destino de usage no escribible no altera rc ni heartbeat del turno.
- La statusline renderiza `1.2k→56` en `done`, nada en `running`, la línea completa sin
  tokens con un heartbeat pre-M9, y ante tokens malformados (string/decimal/negativo) exit
  0 con stderr vacío y segmento omitido.
- `.tandem/log/<slug>.md` de un run muestra tokens en CADA línea de ronda (incluidas rondas
  APPROVED-a-la-primera) y total por fase; el informe final de run los agrega en todos los
  estados terminales (contrato fijado estáticamente en las cinco skills).
- Eventos sin `turn.completed`, malformados o vacíos → sin fichero, sin error, turno intacto.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Contratos de heartbeat existentes:** varios tests asertan el JSON del heartbeat campo a
  campo; se amplían en la misma pasada (listados arriba) — un olvido lo caza la suite, no
  producción.
- **Desplazamiento de campos `\x1f`:** mitigado poniendo los nuevos al final + test
  explícito de heartbeat viejo.
- **Portabilidad:** humanización k/M en bash 3.2 sin `bc` (aritmética entera + printf).

## Out of scope

- M12 (statusline durante implementaciones Opus) — aquí solo se tocan estados de heartbeat
  Codex existentes.
- Presupuestos, límites o alertas de cuota (solo contabilidad).
- Persistir usage de runs pasados retroactivamente.
- El resto de la cola (M12, M5, M7, M10).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Fuente del dato?** → El `turn.completed` del NDJSON ya persistido (pre-registrado en
   la cola); SUMA campo a campo de todos los `turn.completed` del stream — campos numéricos
   se suman con sus nombres codex verbatim, campos NO numéricos se descartan (regla
   explícita con test de salida exacta; la afirmación de forward-compatibility aplica a
   campos numéricos futuros). Con un evento (36/36 observados), la suma es el objeto
   numérico verbatim.
2. **¿Dónde se persiste?** → `.t<N>.usage.json` junto a los demás artefactos del turno
   (pre-registrado); seats de swarm: ledger `.t<N>.usage.json` por INTENTO, nunca un único
   fichero que un retry pisaría.
3. **¿Heartbeat y statusline?** → Sí, campos `tokens_in`/`tokens_out` (null en `running`,
   pre-registrado "para que la statusline pueda mostrarlos al terminar") y render humanizado
   solo en estados terminales.
4. **¿Quién agrega?** → Fable vía instrucciones en las cinco skills; los scripts solo
   persisten el dato crudo. Bajo transporte opus: `tokens: n/a` explícito.
5. **¿Rama?** → `tandem/token-accounting` apilada sobre `tandem/swarm-preamble` (la cadena
   de la cola, mergeada en orden), aprobada con `plan-approve.sh`.
6. **¿Versión?** → 0.14.0; metadatos del orquestador tras la implementación.
