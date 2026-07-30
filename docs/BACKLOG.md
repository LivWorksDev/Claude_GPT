# Backlog de mejoras — auditoría 2026-07-30

Origen: revisión integral del proyecto (workflows, flows, selección de modelos, paso de
mensajes, scripts y skills) realizada el 2026-07-30 sobre v0.9.0. Cada entrada es un
hallazgo accionable, autocontenido: se puede abordar sin releer la conversación de origen.

**Cómo se traza:** cada mejora que se aborde entra por el propio pipeline
(`/tandem:plan <slug sugerido>`); al aprobarse el plan se actualiza aquí el estado a
`planificada`, y al mergear, a `hecha (vX.Y.Z)`. Descartar también se registra, con la razón —
mismo principio que el deadlock honesto: las decisiones se muestran, no se borran.

Estados: `pendiente` · `planificada` · `en curso` · `hecha (vX.Y.Z)` · `descartada (razón)`.
Severidad: `P1` corrección/seguridad · `P2` robustez o valor alto · `P3` pulido.
Esfuerzo: `S` (< 1 h) · `M` (media jornada) · `L` (> 1 día).

## Vista rápida

| ID | Mejora | Área | Sev. | Esf. | Estado |
| --- | --- | --- | --- | --- | --- |
| M1 | Worktree cableado también para transporte sol y review | Transporte | P1 | M | pendiente |
| M2 | Pin de `network_access` en sandboxes de escritura | Seguridad | P1 | S | pendiente |
| M3 | Commit del plan en la rama tandem, nunca en la del usuario | Workflow | P1 | S | pendiente |
| M4 | `-c sandbox_mode=` también en start y swarm | Seguridad | P3 | S | pendiente |
| M5 | Override de effort para turnos-recordatorio | Modelos | P2 | S | pendiente |
| M6 | `TANDEM_CRITICAL` con efecto real bajo Opus | Modelos | P2 | M | pendiente |
| M7 | Doctor: `CLAUDE_CODE_SUBAGENT_MODEL` + smoke de modelos | Diagnóstico | P2 | S | pendiente |
| M8 | Concatenación del preámbulo ultra en el script, no en haiku | Mensajería | P2 | S | pendiente |
| M9 | Contabilidad de tokens por turno/ronda/run | Observabilidad | P2 | M | pendiente |
| M10 | Reviews largas en background por defecto | Workflow | P2 | S | pendiente |
| M11 | Nueva skill `/tandem:status` | UX | P2 | M | pendiente |
| M12 | Statusline visible durante implementaciones Opus | Observabilidad | P2 | S | pendiente |
| M13 | Semáforo de concurrencia dentro de `codex-swarm.sh` | Ultra | P2 | M | pendiente |
| M14 | Suite de tests con stub de codex + shellcheck + CI | Infraestructura | P1 | L | hecha (v0.10.0) |
| M15 | Review de rangos ya commiteados | Workflow | P3 | M | pendiente |

## Orden de ataque recomendado

1. **M14** — protege todo lo demás: cada mejora posterior aterriza con red de seguridad.
2. **M1, M2** — los únicos con riesgo de ejecutar código en el sitio equivocado o con red no prevista.
3. **M3** — incoherencia de política barata de cerrar (M4 puede ir en el mismo cambio que M2).
4. **M8, M9, M11** — mejor relación coste/valor en robustez y UX (M9 alimenta a M11).
5. **M5, M6, M7, M10, M12, M13, M15** — pulido incremental, sin dependencias entre sí.

---

## M1 — Worktree cableado también para transporte sol y review

- **Severidad/Esfuerzo:** P1 / M · **Slug sugerido:** `worktree-sol-review`
- **Problema:** `TANDEM_WORKTREE=1` solo está completo para el transporte Opus dentro de
  `tandem:implement`. Con `TANDEM_IMPLEMENTER=sol`, la skill lanza
  `codex-start.sh implement …` sin anclar el cwd al worktree y ni el script ni
  `implement.tpl` reciben la ruta de trabajo: Codex ejecuta con el cwd de la sesión (checkout
  principal) y su `workspace-write` escribiría allí, no en `.worktrees/<slug>`. En
  `tandem:review` no hay mención alguna al worktree: el gate de Step 0
  (`git status --porcelain`) miraría el checkout principal limpio y concluiría "nada que
  revisar" (falla cerrado, pero falla).
- **Evidencia:** `skills/implement/SKILL.md:86` (comando sol sin `cd`),
  `skills/implement/prompts/implement.tpl` (sin placeholder de workdir),
  `skills/review/SKILL.md` (cero manejo de worktree).
- **Propuesta:** anclar el cwd explícitamente en los pasos sol y review
  (`cd <abs-worktree> && bash …` en el mismo comando). Mejor aún: si la versión instalada de
  la CLI soporta `codex exec --cd <dir>` (verificar con `codex exec --help`, como el resto de
  flags verificados contra la fuente), aceptar un workdir explícito en los scripts y pasarlo —
  elimina la dependencia del cwd heredado.
- **Aceptación:** un run con `TANDEM_WORKTREE=1` + `TANDEM_IMPLEMENTER=sol` escribe
  exclusivamente dentro de `.worktrees/<slug>`; `tandem:review` detecta y revisa el diff del
  worktree, no el árbol principal.

## M2 — Pin de `network_access` en sandboxes de escritura

- **Severidad/Esfuerzo:** P1 / S · **Slug sugerido:** `sandbox-network-pin`
- **Problema:** la filosofía "ninguna reanudación hereda el default del config.toml" se cumple
  para `sandbox_mode`, pero no para su sub-ajuste de red: un
  `sandbox_workspace_write.network_access = true` en el `~/.codex/config.toml` del usuario da
  red al implementador Sol y al modo imagen, contradiciendo el "Network access is
  unavailable" que promete `implement.tpl`.
- **Evidencia:** `scripts/codex-start.sh:59-66`, `scripts/codex-resume.sh:63-70` (ningún pin
  del sub-ajuste); `skills/implement/prompts/implement.tpl` (promesa de sin-red).
- **Propuesta:** añadir `-c sandbox_workspace_write.network_access=false` a los turnos de
  roles de escritura (implement/image) en start y resume. En la misma pasada, decidir
  explícitamente si los seats read-only (review, ask, ultra) deben tener `web_search`
  (`stream_milestones` ya anticipa el evento, pero hoy depende de la config del usuario):
  fijarlo con `-c` o documentar la decisión en ARCHITECTURE.
- **Aceptación:** con un config.toml que habilite red en workspace-write, un turno implement
  no puede alcanzar la red (verificable con el stub de M14 o con un turno real que intente
  `curl`).

## M3 — Commit del plan en la rama tandem, nunca en la del usuario

- **Severidad/Esfuerzo:** P1 / S · **Slug sugerido:** `plan-commit-branch`
- **Problema:** el plan se commitea en la rama actual (típicamente `main`) y la rama
  `tandem/<slug>` no se crea hasta `implement` Step 0.6. En interactivo deja un commit
  huérfano en main si el run se abandona; en autonomous es una escritura no supervisada en la
  rama por defecto — violando la línea roja "never touch the default branch" del propio modo.
- **Evidencia:** `skills/plan/SKILL.md:67-69` (commit del plan en Resolution),
  `skills/implement/SKILL.md:20-22` (creación de rama posterior),
  `skills/run/SKILL.md:43` (línea roja autonomous).
- **Propuesta:** crear `tandem/<slug>` en el momento de la aprobación del plan y commitear el
  plan ya dentro de la rama; `implement` Step 0.6 pasa a verificar/reutilizar la rama. El
  camino de worktree con rama existente ya está contemplado (path "resume" de
  `git worktree add`). El clean-tree gate no se ve afectado.
- **Aceptación:** tras un run completo, main no tiene commits nuevos; un DEADLOCK posterior a
  la aprobación del plan deja main intacta (el plan vive solo en `tandem/<slug>`).

## M4 — `-c sandbox_mode=` también en start y swarm

- **Severidad/Esfuerzo:** P3 / S · **Slug sugerido:** junto a M2 (`sandbox-network-pin`)
- **Problema:** `codex-resume.sh` lleva el cinturón-y-tirantes `-c sandbox_mode=` además de
  `--sandbox`; `codex-start.sh` y `codex-swarm.sh` solo llevan `--sandbox`. La asimetría es
  gratuita.
- **Evidencia:** `scripts/codex-resume.sh:68` vs `scripts/codex-start.sh:59-66` y
  `scripts/codex-swarm.sh:81-88`.
- **Propuesta:** añadir la misma línea `-c sandbox_mode="$CODEX_SANDBOX"` en ambos scripts.
- **Aceptación:** los tres scripts pasan sandbox por flag y por `-c` de forma idéntica.

## M5 — Override de effort para turnos-recordatorio

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `turn-effort-override`
- **Problema:** cuando falta la línea `VERDICT:` o el sentinel, las skills reanudan el hilo
  "pidiendo solo la línea que falta" — pero `resolve_role` fija el effort del rol (xhigh en
  review), así que un turno cuyo único trabajo es escribir una línea paga el razonamiento más
  caro y lento, y consume cuota ChatGPT.
- **Evidencia:** `scripts/_common.sh:33-63` (`resolve_role` fija effort);
  `skills/plan/SKILL.md:46`, `skills/review/SKILL.md:43`, `skills/implement/SKILL.md:98`
  (los nudges).
- **Propuesta:** override puntual de effort por invocación en `codex-resume.sh` (argumento
  opcional o `TANDEM_TURN_EFFORT`), usado por las skills solo en los nudges. El sandbox sigue
  fijado por rol — esto solo toca effort.
- **Aceptación:** un nudge corre a effort bajo y queda registrado con su effort real en el
  heartbeat y los ficheros por turno; los turnos de review reales siguen al effort del rol.

## M6 — `TANDEM_CRITICAL` con efecto real bajo Opus

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `critical-opus-effort`
- **Problema:** el tool Agent no expone effort, así que `TANDEM_CRITICAL=1` bajo el transporte
  default no altera nada del implementador (documentado como limitación).
- **Evidencia:** `skills/implement/SKILL.md:37`, `docs/ARCHITECTURE.md:50`.
- **Propuesta:** dos vías, no excluyentes: (a) el tool Workflow sí expone `effort` y
  `agentType` en `agent()` — un lanzamiento de un solo agente `tandem:implementer` con
  `effort` elevado devuelve significado a CRITICAL; requiere opt-in explícito del usuario a
  orquestación, así que se documenta como oferta de la skill en trabajo crítico, no como
  default. (b) Cero-código: la matriz de riesgo recomienda `TANDEM_IMPLEMENTER=sol` cuando
  CRITICAL esté activo, porque ahí el effort sí sube a xhigh.
- **Aceptación:** con `TANDEM_CRITICAL=1` el usuario tiene un camino documentado (y ofrecido
  por la skill) para que la implementación corra con esfuerzo elevado.

## M7 — Doctor: `CLAUDE_CODE_SUBAGENT_MODEL` + smoke de modelos

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `doctor-preflight-gaps`
- **Problema:** el preflight de implement para si `CLAUDE_CODE_SUBAGENT_MODEL` vale otra cosa
  que `opus`, pero `codex-doctor.sh` — el diagnóstico que se corre antes de cada run — no lo
  avisa. Y nada verifica que `gpt-5.6-sol`/`gpt-5.6-luna` sigan siendo nombres de modelo
  válidos: una deprecación se descubre a mitad de un run largo.
- **Evidencia:** `scripts/codex-doctor.sh:73-105` (política de modelos sin esos checks);
  `skills/implement/SKILL.md:16` (el preflight que doctor no refleja).
- **Propuesta:** línea FAIL en doctor cuando implementer=opus y `CLAUDE_CODE_SUBAGENT_MODEL`
  está definida con otro valor; flag opcional `--smoke` que lance un turno mínimo por modelo
  configurado (coste: un turno barato por modelo, solo bajo demanda).
- **Aceptación:** doctor detecta ambas condiciones; `--smoke` distingue "modelo válido" de
  "modelo desaparecido" con mensaje accionable.

## M8 — Concatenación del preámbulo ultra en el script, no en haiku

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `swarm-preamble`
- **Problema:** el wrapper `haiku` de cada seat debe escribir un fichero con "el contenido
  completo del preámbulo, verbatim" — un modelo pequeño reproduciendo texto largo literalmente
  es exactamente donde aparecen mutaciones silenciosas. La concatenación es trabajo de
  máquina.
- **Evidencia:** `skills/ultra/SKILL.md:39-51` (paso 1 del wrapper).
- **Propuesta:** `codex-swarm.sh --preamble <file>` (o quinto argumento) que haga
  `cat preamble brief > prompt` él mismo; el wrapper solo escribe su brief.
- **Aceptación:** el prompt final de cada seat contiene el preámbulo byte a byte idéntico al
  fichero fuente; el wrapper queda reducido a brief + ejecución + extracción.

## M9 — Contabilidad de tokens por turno/ronda/run

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `token-accounting`
- **Problema:** cada `turn.completed` en `events.ndjson` trae `input_tokens`/`output_tokens`;
  hoy solo se narran en vivo y se descartan. La cuota ChatGPT es la restricción operativa real
  (el README avisa del 3–5× en imagen) y no hay forma de saber cuánto costó un run.
- **Evidencia:** `scripts/_common.sh:155-156` (los tokens se imprimen y se pierden);
  `.tandem/state/*/…events.ndjson` (el dato ya persiste en disco).
- **Propuesta:** tras cada turno, extraer el usage con jq y añadirlo a la línea de ronda del
  log del slug; total agregado en el informe final (interactivo y autonomous) y en el run
  report de ultra. Opcional: incluirlo en el heartbeat para que la statusline lo muestre al
  terminar el turno.
- **Aceptación:** `.tandem/log/<slug>.md` muestra tokens por ronda y total por run; el informe
  final de un run autonomous incluye el agregado.

## M10 — Reviews largas en background por defecto

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `review-background`
- **Problema:** las skills fijan `timeout: 600000` para reviews en foreground — que es también
  el máximo del tool Bash. Una review xhigh de un diff grande puede exceder los 10 minutos y
  morir a mitad de turno. Para implement ya se recomienda background; para plan-review y
  code-review no.
- **Evidencia:** `skills/plan/SKILL.md:35`, `skills/review/SKILL.md:37` (timeout al máximo del
  tool); `skills/implement/SKILL.md:91` (el precedente de background).
- **Propuesta:** extender la recomendación de `run_in_background: true` a las reviews (el
  panel de shell y la statusline ya narran el progreso, no se pierde visibilidad), con
  foreground solo para diffs/planes pequeños.
- **Aceptación:** las skills de plan y review documentan el criterio background/foreground
  igual que implement; una review > 10 min completa sin morir por timeout.

## M11 — Nueva skill `/tandem:status`

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `status-skill`
- **Problema:** todo el estado existe (`codex-show.sh`, `implement-claude/<slug>.json`,
  `.turn`, el log del slug) pero ninguna skill lo expone: tras una compactación o al retomar
  un run PARTIAL/DEADLOCK hay que saberse los scripts de memoria.
- **Evidencia:** `scripts/codex-show.sh` (sin skill que lo envuelva);
  `skills/run/SKILL.md:51` ("resumable con las skills interactivas" — sin herramienta de
  orientación).
- **Propuesta:** skill de solo lectura que pinte el run completo por slug: fase alcanzada,
  veredictos y rondas por fase, rama, gate de testing, estado del intento Opus, y tokens
  (cuando M9 esté). Complemento natural de los estados terminales de autonomous.
- **Aceptación:** `/tandem:status <slug>` responde en un vistazo "dónde está este run y cómo
  se retoma", sin llamar a Codex.

## M12 — Statusline visible durante implementaciones Opus

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `statusline-opus`
- **Problema:** la línea 2 queda muda durante implementaciones Opus (limitación v1
  documentada). Pero `.tandem/state/implement-claude/<slug>.json` ya contiene
  `status: running|terminal` y el último sentinel — presencia y desenlace, el 80% del valor.
- **Evidencia:** `scripts/statusline.sh:86-105` (solo lee el heartbeat Codex);
  `skills/implement/SKILL.md:41-64` (el JSON durable con status y sentinel).
- **Propuesta:** fallback en la statusline: sin heartbeat Codex activo, leer el JSON
  implement-claude más reciente y renderizar `⚒ opus implement · running · <slug>` (ámbar) /
  sentinel coloreado al terminar. Sin actividad en vivo — eso sigue siendo v2.
- **Aceptación:** durante una implementación Opus la línea 2 muestra presencia y, al acabar,
  el sentinel; nunca interfiere con un heartbeat Codex real (que tiene prioridad).

## M13 — Semáforo de concurrencia dentro de `codex-swarm.sh`

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `ultra-semaphore`
- **Problema:** el límite `TANDEM_ULTRA_CONCURRENCY` se aplica chunkeando los `parallel()` del
  workflow: cada tanda espera a su seat más lento (barreras que el propio diseño desaconseja)
  y el tope depende de que el autor del workflow chunkee bien — si lo olvida, no hay límite.
- **Evidencia:** `skills/ultra/SKILL.md:55` (chunking manual como único mecanismo).
- **Propuesta:** semáforo dentro del script — lock por `mkdir` (portable a BSD/macOS, sin
  `flock`) en `.tandem/state/ultra/<run>/.slots/`, leyendo `TANDEM_ULTRA_CONCURRENCY`
  directamente del entorno. El `pipeline()` fluye sin barreras y el límite se aplica aunque
  la orquestación se equivoque.
- **Aceptación:** N seats lanzados a la vez ejecutan como máximo `TANDEM_ULTRA_CONCURRENCY`
  turnos codex simultáneos, sin chunking en el workflow; un seat que muere libera su slot
  (trap EXIT).

## M14 — Suite de tests con stub de codex + shellcheck + CI

- **Severidad/Esfuerzo:** P1 / L · **Slug sugerido:** `test-harness-ci`
- **Problema:** ~1.100 líneas de bash endurecido (portabilidad bash 3.2/BSD, `PIPESTATUS`,
  separadores `\x1f`, traps EXIT) sin regresión automática. El patrón de test con stub de
  codex que emite NDJSON realista ya se diseñó y validó (2026-07-20) pero quedó en un
  scratchpad no versionado — el coste se pagó y no se cosecha. Bugs de esta clase ya mordieron
  una vez (colapso de `@tsv`, `patsub_replacement`).
- **Evidencia:** ausencia de `tests/` y de `.github/workflows/`; los patrones frágiles en
  `scripts/_common.sh` y `scripts/statusline.sh`.
- **Propuesta:** directorio `tests/` con el stub de codex (reconstruirlo del patrón conocido:
  binario falso en PATH que emite NDJSON de eventos + last-message y respeta exit codes);
  casos para start/resume/swarm/reset (thread id, fallback silencioso, sandbox flags,
  heartbeat, verdicts) y para statusline (payloads con campos vacíos); `shellcheck` sobre
  `scripts/`; GitHub Actions con matriz `macos-latest`/`ubuntu-latest` (BSD vs GNU userland es
  objetivo declarado del proyecto).
- **Aceptación:** `bash tests/run.sh` pasa en local; CI verde en ambas plataformas; un cambio
  que rompa el contrato de exit codes o el formato del heartbeat falla en PR.

## M15 — Review de rangos ya commiteados

- **Severidad/Esfuerzo:** P3 / M · **Slug sugerido:** `review-range`
- **Problema:** `tandem:review` solo revisa diff sin commitear; el caso "quiero el revisor Sol
  sobre esta rama/PR ya commiteada" obliga a improvisar con `tandem:ask`.
- **Evidencia:** `skills/review/SKILL.md:15-17` (gate de diff sin commitear).
- **Propuesta:** extensión pequeña — aceptar un rango (`tandem:review --range main..feature`);
  el context file ya soporta el fallback de DIFF inline, así que el reviewer recibe
  `git diff <range>` por esa vía. Fuera del pipeline (sin gate de commit): produce veredicto y
  hallazgos, no un commit.
- **Aceptación:** una rama commiteada obtiene review completa de Sol con veredicto, sin
  requerir árbol sucio ni tocar el flujo del pipeline normal.
