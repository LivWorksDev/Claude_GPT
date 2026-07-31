# Plan: turn-effort-override — effort puntual para turnos-recordatorio

**Backlog:** M5 (P2/S) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 4/6)

## Goal

Cuando falta la línea `VERDICT:` o el sentinel, las skills reanudan el hilo "pidiendo solo
la línea que falta" — pero `resolve_role` fija el effort del rol (xhigh en review), así que
un turno cuyo único trabajo es re-emitir lo que faltó (la línea de veredicto; en implement,
el informe final ya hecho más su sentinel) paga el razonamiento más caro y lento y consume
cuota ChatGPT. Objetivo: override puntual de effort por invocación en
`codex-resume.sh` (`TANDEM_TURN_EFFORT`), usado por las skills SOLO en los nudges. El
sandbox sigue fijado por rol — esto solo toca effort.

## Approach

1. **`scripts/codex-resume.sh` — env `TANDEM_TURN_EFFORT`, sin cambiar la firma.** La
   VALIDACIÓN va donde los errores de uso: junto a `codex_cwd_validate`, ANTES de
   `need_codex`/`need_jq` — con un valor inválido y una dependencia ausente el exit debe
   ser 64, no 3 (mismo orden deliberado que el resto de validaciones de uso). Lista
   cerrada `minimal|low|medium|high|xhigh|max|ultra` (los dos últimos ya documentados como
   soportados en README:93 — excluirlos contradiría el override por rol que sí los
   acepta); cualquier otro valor, incluido vacío-definido, exit 64 nombrando la variable.
   La APLICACIÓN va tras `resolve_role`: sobreescribe `CODEX_EFFORT`, y al fluir por la
   variable existente el argv (`-c model_reasoning_effort=`), la línea narrada y el
   heartbeat llevan el effort real automáticamente. El sandbox no se toca.
1b. **Registro durable por turno — `$KEY.t$TURN.meta.json`.** El heartbeat es global y
   reemplazable: en cuanto otro turno lo pisa, no queda prueba durable de con qué effort
   corrió el nudge — y la aceptación del backlog exige "registrado con su effort real en
   el heartbeat y los ficheros por turno". `codex-start.sh` y `codex-resume.sh` escriben,
   junto a los demás artefactos del turno, un meta.json mínimo
   (`{"role","model","effort","sandbox"}`, printf atómico best-effort como el usage de
   M9). Swarm queda fuera (sus seats ya registran tier/modelo en la cabecera narrada y no
   aceptan la env — ver alcance).
2. **Alcance deliberado: SOLO resume.** `codex-start.sh` y `codex-swarm.sh` la IGNORAN
   (pre-registrado en la cola): un primer turno o un seat de enjambre nunca es un
   recordatorio. Un test lo fija para que el scope no se relaje en silencio.
3. **Skills — comandos de nudge DEDICADOS, con template propio.** Hoy las ramas de
   sentinel ausente son solo prosa: su único comando concreto es el de trabajo real
   (disposiciones/continuación), y prefijar ESE degradaría trabajo real a low, mientras
   que reutilizar su template relanzaría el trabajo caro completo. Cada rama gana su
   comando fenced propio con template de nudge dedicado:
   - `skills/plan/prompts/nudge.tpl` y `skills/review/prompts/nudge.tpl`: "tu última
     respuesta no terminó con la línea VERDICT:; re-emite SOLO esa línea" (sin re-review).
   - `skills/implement/prompts/nudge.tpl`: ídem para `IMPLEMENTATION_*` + informe final.
   - `skills/image/prompts/nudge.tpl`: ídem para `IMAGE_READY`/`IMAGE_BLOCKED` — la cuarta
     rama de nudge existente (skills/image/SKILL.md:58-61, rol image a high), omitida en
     el borrador y exactamente el mismo caso de turno-recordatorio caro.
   - Los cuatro comandos fenced, CONCRETOS y por rol — los de review e implement llevan
     OBLIGATORIAMENTE el pin de worktree además del effort (el contrato
     `skill-worktree-contract` rechaza cualquier lanzamiento sin `TANDEM_CODEX_CWD`, y sin
     él el nudge reanudaría el hilo en el checkout equivocado):
     plan → `TANDEM_TURN_EFFORT=low bash "$SCRIPTS/codex-resume.sh" review
     docs/plans/<slug>.plan.md .../plan/prompts/nudge.tpl`;
     review → `TANDEM_TURN_EFFORT=low TANDEM_CODEX_CWD="$WORK_ROOT" bash
     "$SCRIPTS/codex-resume.sh" review cr-<slug> .../review/prompts/nudge.tpl`;
     implement-sol → `TANDEM_TURN_EFFORT=low TANDEM_CODEX_CWD="$WORK_ROOT" bash
     "$SCRIPTS/codex-resume.sh" implement docs/plans/<slug>.plan.md
     .../implement/prompts/nudge.tpl`;
     image → `TANDEM_TURN_EFFORT=low bash "$SCRIPTS/codex-resume.sh" image <asset-label>
     .../image/prompts/nudge.tpl`.
     Las reanudaciones REALES quedan intactas y sin la variable.
   - **Contrato de salida por rol, no uniforme:** plan/review/image piden SOLO su línea de
     sentinel; el nudge de implement pide el INFORME FINAL + sentinel (el contrato del
     transporte sol exige el informe para entender leftovers y riesgos) prohibiendo
     explícitamente trabajo de implementación adicional.
4. **`README.md`** — la lista de overrides por entorno gana `TANDEM_TURN_EFFORT` (efímera,
   por invocación, solo resume, lista de valores válidos incluidos max/ultra, y que el
   sandbox jamás se ve afectado).
5. **Tests.**
   - `tests/resume-turn-effort.test.sh` (nuevo): resume con `TANDEM_TURN_EFFORT=low` → el
     argv registrado por el stub lleva `-c model_reasoning_effort=low`, el heartbeat lleva
     `effort: "low"` Y el `t<N>.meta.json` durable lleva `effort == "low"` (la prueba que
     sobrevive al siguiente heartbeat); `max` y `ultra` → aceptados y en el argv; sin la
     variable → effort del rol (xhigh) intacto en argv, heartbeat y meta; valor inválido
     (`turbo`) o vacío-definido → exit 64 nombrando la variable, sin turno lanzado — y
     TAMBIÉN 64 con `codex` AUSENTE del PATH (la validación precede a las dependencias);
     `codex-start.sh` y `codex-swarm.sh` con la variable definida → sus argv conservan el
     effort del rol/tier (el scope no se relaja) Y el meta.json de start registra el
     effort del ROL con los cuatro campos poblados (la env heredada no altera su registro);
     meta.json con un modelo custom cargado de caracteres JSON-significativos
     (`TANDEM_REVIEW_MODEL='mo"del\\n'`) → JSON válido con el valor exacto (jq -n --arg,
     nunca printf de strings del entorno).
   - `tests/skill-turn-effort-contract.test.sh` (nuevo, estático): las CUATRO ramas de
     nudge contienen `TANDEM_TURN_EFFORT=low` y su `nudge.tpl` (que debe existir); los de
     review e implement llevan ADEMÁS `TANDEM_CODEX_CWD="$WORK_ROOT"` (el contrato de
     worktree se cumple también en los nudges); anclas por rol: plan/review/image piden
     solo su línea, implement pide informe + sentinel prohibiendo trabajo extra; los
     comandos de resume REALES no llevan la variable — juicio por comando fenced lógico.
6. **Metadatos — orquestador tras la implementación:** `.claude-plugin/plugin.json` →
   `0.16.0`, `CHANGELOG.md`, `docs/BACKLOG.md` (M5 → `hecha (v0.16.0)`), fila de la cola.

## Key decisions & tradeoffs

- **Env por invocación, no argumento nuevo** (pre-registrado): la firma de los scripts está
  congelada por tests de aridad; una env efímera prefijada al comando es exactamente el
  patrón ya usado por `TANDEM_CODEX_CWD` y no toca ningún contrato de argv existente salvo
  el valor del effort.
- **Lista cerrada de valores, fail-closed:** el CLI acepta claves/valores desconocidos en
  silencio (lección de M1/M2: una clave muerta no avisa); validar aquí con exit 64 es la
  única forma de que `TANDEM_TURN_EFFORT=hgih` no lance un turno xhigh carísimo creyéndose
  low.
- **Solo resume, y fijado por test:** ampliar el scope a start/swarm sería trivial pero
  abriría la puerta a degradar turnos reales por accidente de entorno heredado; el caso de
  uso es el nudge y solo existe en resume.
- **`low`, no `minimal`, en los nudges:** re-emitir lo que faltó (la línea, o en implement
  el informe ya realizado) exige releer el contexto del hilo; minimal ahorra céntimos más
  pero arriesga otro turno incompleto — que costaría un tercero. low es el punto seguro.
- **El effort real fluye por `CODEX_EFFORT`** hacia argv, narración y heartbeat; el
  registro DURABLE exige además el meta.json por turno (heartbeat = global y reemplazable),
  construido con `jq -n --arg` — los valores de modelo vienen de overrides de entorno y
  pueden llevar comillas/backslashes; un printf de strings controladas por el entorno
  produciría JSON inválido — y persistido con el mismo tmp+mv best-effort del usage de M9.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/codex-resume.sh` | Validación temprana (pre-deps) + override de `CODEX_EFFORT` + meta.json por turno |
| `scripts/codex-start.sh` | meta.json por turno (simetría del registro durable) |
| `skills/plan/SKILL.md` · `skills/review/SKILL.md` | Comando fenced de nudge con prefijo + nudge.tpl |
| `skills/implement/SKILL.md` · `skills/image/SKILL.md` | Ídem (sol e image) |
| `skills/plan/prompts/nudge.tpl` · `skills/review/prompts/nudge.tpl` · `skills/implement/prompts/nudge.tpl` · `skills/image/prompts/nudge.tpl` | Nuevos templates de nudge |
| `README.md` | Documentar la env en la lista de overrides |
| `tests/resume-turn-effort.test.sh` | Nuevo, comportamental |
| `tests/skill-turn-effort-contract.test.sh` | Nuevo, estático |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.16.0 (orquestador) |

## Acceptance & proof

- Un nudge (resume con `TANDEM_TURN_EFFORT=low` + nudge.tpl) corre con
  `-c model_reasoning_effort=low` en el argv y deja el effort real en heartbeat Y en el
  `t<N>.meta.json` durable (que sobrevive al siguiente heartbeat); los turnos reales
  siguen al effort del rol, verificado sin la variable en el mismo hilo. `max`/`ultra`
  son valores válidos.
- Valor inválido o vacío → exit 64 nombrando la variable, sin gastar turno — también con
  `codex` ausente del PATH (usage antes que dependencias).
- `codex-start.sh` y `codex-swarm.sh` ignoran la variable (argv con el effort del
  rol/tier).
- Las CUATRO ramas de nudge llevan prefijo y template dedicado con contrato de salida POR
  ROL: plan/review/image piden solo su línea de sentinel; implement pide el informe final +
  sentinel prohibiendo trabajo de implementación adicional. Los resumes reales no llevan la
  variable (contrato estático).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Herencia accidental de la env en turnos reales:** mitigada por el contrato estático
  (los resumes reales no llevan el prefijo) y porque la env se pasa por invocación, nunca
  exportada por las skills.
- **Valores nuevos del CLI (p.ej. efforts futuros):** la lista cerrada exigirá tocarla —
  coste asumido; lo contrario (aceptar cualquier cosa) reintroduce la clase de bug de la
  clave muerta.

## Out of scope

- Effort configurable para start/swarm (los overrides por rol/tier ya existen:
  `TANDEM_REVIEW_EFFORT`, `TANDEM_ULTRA_*_EFFORT`).
- M6 (efecto real de `TANDEM_CRITICAL` bajo Opus).
- El resto de la cola (M7, M10).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Mecanismo?** → Env `TANDEM_TURN_EFFORT` leída solo por `codex-resume.sh`, sin cambiar
   firmas; sandbox intacto (pre-registrado en la cola).
2. **¿Effort del nudge?** → `low` (no `minimal`): el turno debe releer el hilo para emitir
   el veredicto correcto; el ahorro extra de minimal no compensa el riesgo de un tercer
   turno.
3. **¿Validación?** → Lista cerrada `minimal|low|medium|high|xhigh|max|ultra` (los que el
   repo documenta como soportados), exit 64 fail-closed ANTES de las dependencias (usage
   nunca degrada a 3 — contrato existente de los scripts).
4. **¿Rama?** → `tandem/turn-effort-override` apilada sobre `tandem/statusline-opus`
   (cadena de la cola), aprobada con `plan-approve.sh`.
5. **¿Versión?** → 0.16.0; metadatos del orquestador tras la implementación.
