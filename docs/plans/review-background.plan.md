# Plan: review-background — reviews largas en background por defecto

**Backlog:** M10 (P2/S) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 6/6)

## Goal

Las skills de plan y review fijan `timeout: 600000` para sus turnos de review en foreground
— que es también el MÁXIMO del tool Bash: una review xhigh de un diff o plan grande puede
exceder los 10 minutos y morir a mitad de turno, sin salida posible por timeout. Para
implement ya se recomienda `run_in_background: true`; para plan-review y code-review no.
Objetivo: extender el criterio background/foreground de implement a los cuatro lanzamientos
de review (start y resume de plan y de code review), con foreground solo para diffs/planes
pequeños. Cambio de documentación ejecutable — sin cambios de código (pre-registrado).

## Approach

1. **`skills/plan/SKILL.md`** — las dos invocaciones de review (Round 1 en la línea 35 y el
   resume de disposiciones en la 62) pasan de "Bash timeout: 600000" a la recomendación de
   implement: `run_in_background: true` por defecto para cualquier plan real (las reviews
   xhigh superan con regularidad el cap de 10 minutos de foreground, que es un techo duro
   del tool, no un parámetro), foreground con `timeout: 600000` SOLO para planes pequeños.
   Al terminar un run en background, anunciarlo claramente antes de seguir — la frase
   contrato ya usada por implement — y, NUEVO y explícito: **la notificación de
   finalización del task de Bash es una barrera dura** — nada de leer el `VERDICT:`, copiar
   la línea `USAGE:` al log (jamás un `tokens: n/a` prematuro por impaciencia) ni lanzar
   resume/nudge alguno hasta que llegue; el hilo ni siquiera está persistido antes, y un
   resume concurrente sobre un turno vivo es exactamente la clase de corrupción que la
   barrera prohíbe. Los nudges (`TANDEM_TURN_EFFORT=low`) quedan en foreground: son turnos
   de una línea.
2. **`skills/review/SKILL.md`** — ídem para el start del Step 2 (línea 55) y el resume del
   Step 3 (línea 75): background por defecto para cualquier diff real, foreground solo para
   diffs pequeños; nudge en foreground.
3. **`tests/skill-review-background-contract.test.sh`** (nuevo, estático): reutiliza el
   parser de comandos lógicos por bloque fenced de los contratos existentes y CLASIFICA por
   template — un lanzamiento con `prompts/nudge.tpl` es un nudge (debe quedar en
   foreground, y su garantía también se aserta); cualquier otro codex-start/resume de
   review es un lanzamiento real (debe llevar la recomendación de background). Aserciones:
   exactamente 2 lanzamientos reales + 1 nudge por skill (plan y review); ancla de la
   barrera dura ("nada antes de la notificación de finalización"); **anclas NEGATIVAS
   seccionadas sobre el wording legacy** — "Bash timeout: 600000" como instrucción de
   default desaparece de los cuatro lanzamientos reales y `timeout: 600000` solo puede
   aparecer dentro de la frase de excepción para lo pequeño (añadir la nueva frase sin
   retirar la vieja dejaría el comportamiento ambiguo con el test verde);
   implement/SKILL.md conserva su recomendación existente (anti-regresión). Nunca verde por
   vacuidad.
4. **Metadatos — orquestador tras la implementación:** `.claude-plugin/plugin.json` →
   `0.18.0`, `CHANGELOG.md`, `docs/BACKLOG.md` (M10 → `hecha (v0.18.0)`), fila de la cola.

## Key decisions & tradeoffs

- **Documentación ejecutable, sin código** (pre-registrado en la cola): el timeout es un
  límite del tool Bash de la sesión, no de los scripts; el fix correcto es que el
  orquestador lance en background, y eso vive en las skills.
- **Background por DEFECTO, foreground como excepción** (no al revés): el coste de
  background es solo visibilidad inmediata — y la statusline (línea 2) más el panel de
  shell ya narran el turno en vivo, así que no se pierde nada; el coste de foreground es un
  turno xhigh muerto a los 10 minutos con la cuota ya gastada. La asimetría decide.
- **Los nudges quedan en foreground:** un turno a effort low que re-emite una línea termina
  en segundos; pasarlo a background añadiría una espera de notificación sin beneficio.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `skills/plan/SKILL.md` | Round 1 y resume: background por defecto, foreground solo pequeño |
| `skills/review/SKILL.md` | Step 2 y Step 3: ídem |
| `tests/skill-review-background-contract.test.sh` | Nuevo contrato estático |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.18.0 (orquestador) |

## Acceptance & proof

- Las cuatro invocaciones de review (plan start/resume, code review start/resume)
  documentan `run_in_background: true` como default con el criterio de tamaño, la frase de
  anuncio al terminar y la BARRERA dura (sin verdict, sin USAGE al log, sin resumes antes
  de la notificación); los nudges siguen en foreground explícitamente y el wording legacy
  del foreground-default desaparece (solo sobrevive en la excepción de lo pequeño).
- implement/SKILL.md conserva su recomendación intacta (anti-regresión en el contrato).
- El contrato estático nuevo falla si cualquiera de las anclas desaparece o si el
  foreground vuelve a ser el default.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).
**Aceptación operativa (dogfood, una vez):** dos piezas complementarias registradas en el
log del run — (1) la code review de ESTE run se lanza en background siguiendo el texto
nuevo y el log registra la secuencia completa barrera → notificación → USAGE → verdict
(la semántica); (2) una SONDA de coste cero cruza el umbral real: una tarea Bash en
background que duerme 601+ segundos y emite un marcador — el techo de 10 minutos es una
propiedad del tool Bash en foreground, no de codex, así que la notificación llegando
después de >600 s demuestra la supervivencia larga sin quemar un turno xhigh esperando (la
duración de una review real no se puede forzar; la de la sonda sí).

## Risks

- **Interacción con los contratos estáticos existentes:** las skills de plan/review están
  ancladas por skill-worktree-contract, skill-plan-branch-contract,
  skill-token-accounting-contract y skill-turn-effort-contract — las ediciones deben ser
  quirúrgicas y la suite completa es el PROOF.
- **Regresión de claridad:** el texto debe seguir dando el timeout de foreground (600000)
  para el caso pequeño — quitarlo del todo rompería al usuario que revisa un plan de 40
  líneas.

## Out of scope

- Cambios en scripts (el límite es del tool Bash, no de los wrappers).
- Cualquier mecanismo de espera/polling nuevo (el panel de shell y la statusline ya narran).
- El resto del backlog (M6, M11, M13, M15 siguen pendientes fuera de esta cola).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Alcance?** → Solo documentación de las skills de plan y review (pre-registrado:
   "sin cambios de código"), más el contrato estático que lo fija.
2. **¿Default?** → Background para cualquier plan/diff real; foreground `timeout: 600000`
   solo para lo pequeño; nudges siempre foreground.
3. **¿Rama?** → `tandem/review-background` apilada sobre `tandem/doctor-preflight-gaps`
   (cadena de la cola), aprobada con `plan-approve.sh`.
4. **¿Versión?** → 0.18.0; metadatos del orquestador tras la implementación.
