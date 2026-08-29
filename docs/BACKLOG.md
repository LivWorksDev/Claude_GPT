# Backlog de mejoras

Origen: revisión integral del proyecto (workflows, flows, selección de modelos, paso de
mensajes, scripts y skills) realizada el 2026-07-30 sobre v0.9.0. Cada entrada es un
hallazgo accionable, autocontenido: se puede abordar sin releer la conversación de origen.
Las entradas M24–M33 proceden de un informe de campo externo del 2026-08-21 sobre
v0.30.0, verificado cita a cita por el mantenedor y con enmiendas ya incorporadas —
informe íntegro, verificación y razonamiento en `docs/audits/informe-campo-2026-08-21.md`.

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
| M1 | Worktree cableado también para transporte sol y review | Transporte | P1 | M | hecha (v0.11.0) |
| M2 | Pin de `network_access` en sandboxes de escritura | Seguridad | P1 | S | hecha (v0.11.0) |
| M3 | Commit del plan en la rama tandem, nunca en la del usuario | Workflow | P1 | S | hecha (v0.12.0) |
| M4 | `-c sandbox_mode=` también en start y swarm | Seguridad | P3 | S | hecha (v0.11.0) |
| M5 | Override de effort para turnos-recordatorio | Modelos | P2 | S | hecha (v0.16.0) |
| M6 | `TANDEM_CRITICAL` con efecto real bajo Opus | Modelos | P2 | M | hecha (v0.21.0) |
| M7 | Doctor: `CLAUDE_CODE_SUBAGENT_MODEL` + smoke de modelos | Diagnóstico | P2 | S | hecha (v0.17.0) |
| M8 | Concatenación del preámbulo ultra en el script, no en haiku | Mensajería | P2 | S | hecha (v0.13.0) |
| M9 | Contabilidad de tokens por turno/ronda/run | Observabilidad | P2 | M | hecha (v0.14.0) |
| M10 | Reviews largas en background por defecto | Workflow | P2 | S | hecha (v0.18.0) |
| M11 | Nueva skill `/tandem:status` | UX | P2 | M | hecha (v0.19.0) |
| M12 | Statusline visible durante implementaciones Opus | Observabilidad | P2 | S | hecha (v0.15.0) |
| M13 | Semáforo de concurrencia dentro de `codex-swarm.sh` | Ultra | P2 | M | hecha (v0.20.0) |
| M14 | Suite de tests con stub de codex + shellcheck + CI | Infraestructura | P1 | L | hecha (v0.10.0) |
| M15 | Review de rangos ya commiteados | Workflow | P3 | M | hecha (v0.22.0) |
| M16 | Status: `PA_VALID` verifica los invariantes reales de la aprobación | UX | P2 | S | hecha (v0.23.0) |
| M17 | Status: resolución multi-raíz con reconciliación o contradicción explícita | UX | P2 | M | hecha (v0.25.0) |
| M18 | Doctor: parser de versión estricto en el gate crítico | Diagnóstico | P2 | S | hecha (v0.24.0) |
| M19 | Fase 2: probes de comportamiento del transporte MCP | Transporte | P2 | M | hecha (v0.26.0) |
| M20 | Fase 2: `TANDEM_TRANSPORT=mcp` en los wrappers | Transporte | P2 | L | hecha (v0.30.0) — M20a `ask` (v0.27.0), M20b `review` (v0.28.0), M20c `implement`+`image` (v0.30.0); canarios reales de los 4 roles en verde (evidencia en docs/audits/fase2-mcp-parity.md); swarm sigue exec por diseño |
| M21 | Plan reviews bajo `mcp`: cerrar el gate o completar el contrato | Transporte | P2 | S | hecha (v0.29.0) — vía (a): gate por target |
| M22 | Transporte v2: servidor MCP persistente entre invocaciones | Transporte | P3 | L | pendiente — prioridad BAJA deliberada (complejidad alta, aporte marginal) |
| M23 | Swarm de ultra sobre el transporte MCP | Ultra | P3 | L | pendiente — prioridad BAJA deliberada (complejidad alta, aporte marginal) |
| M24 | Watchdog de turno para el transporte exec (start, swarm y resume) | Transporte | P2 | M | pendiente |
| M25 | Auditoría de escrituras en implement + hook anti-install para Opus | Seguridad | P1 | M | pendiente |
| M26 | Interruptor de confidencialidad para `web_search` | Seguridad | P2 | S | pendiente |
| M27 | Vista de runs ultra en `tandem:status` | UX | P2 | M | pendiente |
| M28 | Rollup de tokens entre runs (`--tokens [--since]`) | Observabilidad | P2 | S | pendiente |
| M29 | Salvage de contrato JSON en asientos de enjambre | Ultra | P2 | S | pendiente |
| M30 | `codex-swarm.sh --reap <run>` para slots huérfanos tras SIGKILL | Ultra | P3 | S | pendiente |
| M31 | `TANDEM_PLANS_DIR` configurable | Workflow | P3 | S | pendiente |
| M32 | Campos del log derivados de fuente máquina, no transcritos | Observabilidad | P3 | S | pendiente |
| M33 | Guía de adopción + snippet de CLAUDE.md para repos con políticas previas | Documentación | P3 | S | pendiente |

## Orden de ataque recomendado

1. **M14** — protege todo lo demás: cada mejora posterior aterriza con red de seguridad.
2. **M1, M2** — los únicos con riesgo de ejecutar código en el sitio equivocado o con red no prevista.
3. **M3** — incoherencia de política barata de cerrar (M4 puede ir en el mismo cambio que M2).
4. **M8, M9, M11** — mejor relación coste/valor en robustez y UX (M9 alimenta a M11).
5. **M5, M6, M7, M10, M12, M13, M15** — pulido incremental, sin dependencias entre sí.
6. **M16, M17, M18** — hardening de status/doctor, sin dependencias entre sí; los tres
   nacieron de la primera range review real (`range-review-cola2`, sobre la Cola 2
   completa): hallazgos de interacción que las reviews individuales no podían ver.
7. **Cohorte del informe de campo (M24–M33):** M26 → M24 → M25 → M30 → M28 → M27 →
   M29 → M31/M32/M33. M26 es el mejor coste/valor (S, cierra un canal de datos); M24
   elimina el modo de fallo operativo más común y de rebote reduce la incidencia de M30;
   M25 es el de más valor absoluto (la clase del incidente que motivó el plugin) pero
   exige diseñar el ciclo de vida del marcador de intento-activo; el resto es
   incremental y sin dependencias entre sí.

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

## M16 — Status: `PA_VALID` verifica los invariantes reales de la aprobación

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `status-approval-proof`
- **Problema:** `tandem-status.sh` marca `PA_VALID=1` con campos estructurales y, con git
  disponible, solo comprueba que el commit registrado existe y tiene el padre esperado.
  Omite los invariantes que `plan-approve.sh` sí impone al aprobar: que el commit toca
  SOLO el plan esperado y contiene ese path. Peor: sin git disponible, esos checks se
  saltan pero `PA_VALID` queda true — la fase pasa a "plan aprobado" y el `next:`
  recomienda `/tandem:implement` para un registro corrupto plausible. Status es advisory
  (los gates ejecutables siguen fail-closed por su cuenta), pero certifica en falso ante
  el humano que consulta.
- **Evidencia:** hallazgo Major 1 de la primera range review real (`range-review-cola2`,
  2026-08-01, log en `.tandem/log/ranges/cola2.md`); `scripts/tandem-status.sh:416-432`
  (validación), `:636-637` y `:679-680` (recomendación); invariantes de la aprobación en
  `scripts/plan-approve.sh:343-347`.
- **Propuesta:** con git, verificar el diff plan-only del commit (toca exactamente el plan
  registrado) y el blob del plan antes de poner `PA_VALID`; sin git, degradar a un estado
  explícito "aprobación NO verificada — verificación manual necesaria" que jamás
  recomienda avanzar de fase.
- **Aceptación:** un commit válido del mismo padre que toca un fichero no-plan →
  `PA_INVALID`; un registro estructuralmente válido evaluado sin git → estado "no
  verificado", nunca "plan aprobado" ni `next: /tandem:implement`.

## M17 — Status: resolución multi-raíz con reconciliación o contradicción explícita

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `status-multi-root`
- **Problema:** `resolve_state_root` recorre `CLAUDE_PROJECT_DIR` → `PWD` → checkout
  principal y se detiene en la PRIMERA raíz que contenga cualquier evidencia del slug;
  log, aprobación, implementación y review se leen después solo de esa raíz. Como los
  wrappers anclan deliberadamente el estado de hilos a `CLAUDE_PROJECT_DIR`, un log rancio
  o estado parcial del mismo slug en un worktree enlazado enmascara el run completo y
  autoritativo del checkout principal → fase y `next:` incorrectos.
- **Evidencia:** hallazgo Major 2 de `range-review-cola2`;
  `scripts/tandem-status.sh:132-143` (orden de candidatas), `:169-184` (primera con
  evidencia gana), `:362-373` (lectura exclusiva); anclaje de estado en
  `scripts/_common.sh:99-109`.
- **Propuesta:** inspeccionar TODAS las raíces candidatas para el slug pedido; si la
  evidencia es consistente, reconciliar (la más avanzada); si se contradicen, reportar la
  contradicción explícitamente — ambas raíces, ambas fases — sin recomendar acción.
- **Aceptación:** test dual-root con el mismo slug en dos raíces y el principal más
  avanzado → status refleja el run del principal o declara contradicción; jamás presenta
  la fase del estado rancio como la verdad a secas.

## M18 — Doctor: parser de versión estricto en el gate crítico

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `doctor-version-strict`
- **Problema:** `claude_dotted` acepta el primer token que empiece por dígito y recorta lo
  no numérico ("Claude Code build 123 version 2.1.110" → "123") y `version_ge` rellena
  componentes ausentes con cero → `123 >= 2.1.111` pasa. El gate de M6 (Claude Code ≥
  2.1.111 para effort crítico), que existe para ser fail-closed, certificaría en falso
  ante un cambio de formato de `claude -v`. Con el formato actual no se dispara; un gate
  fail-closed no puede depender de que el formato nunca cambie. Verificado en código por
  el orquestador.
- **Evidencia:** hallazgo Major 3 de `range-review-cola2`; `scripts/codex-doctor.sh:78-90`
  (`claude_dotted`), `:105-120` (`version_ge`), gate en `:214-224`; el mismo parser está
  espejado en el preflight de `skills/implement/SKILL.md` (gate 3).
- **Propuesta:** exigir un token puntuado estricto — exactamente tres componentes
  decimales — y tratar cualquier salida ambigua como indeterminable → FAIL (el "never
  assume new" que el comentario del propio parser ya promete); aplicar el criterio en el
  doctor y en el preflight espejado.
- **Aceptación:** salidas con número de build delante y con fechas → FAIL por
  indeterminable, nunca pass; `2.1.111` y superiores con formato normal siguen ok;
  `2.1.110` sigue FAIL.

## M19 — Fase 2: probes de comportamiento del transporte MCP

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `mcp-preflight-probes`
- **Problema:** la auditoría de paridad (docs/audits/fase2-mcp-parity.md, 2026-08-02)
  dejó cuatro desconocidos que deciden la viabilidad de la Fase 2 y que solo un
  comportamiento observado puede cerrar: (a) si `codex mcp-server` escribe rollouts que
  `codex exec resume <threadId>` pueda levantar (de esto depende la durabilidad de hilos
  — sin ella, los deadlocks resumibles días después dejan de existir); (b) si un
  CODEX_HOME propiedad de tandem (config.toml nuestro + auth del usuario) autentica un
  turno real — la única mitigación de que el servidor NO tenga `--ignore-user-config`;
  (c) si la herencia congelada de `codex-reply` resiste un config.toml hostil cambiado
  entre llamadas; (d) qué pasa de verdad con una elicitation bajo `approval-policy:
  never` en headless (riesgo de turno colgado sin timeout).
- **Evidencia:** hallazgos 1, 3, 6 y 7 de la auditoría de fuente (tag rust-v0.144.4,
  commit 8c68d4c) con fichero:línea del código Rust; superficie confirmada por JSON-RPC
  real (tools/list capturado).
- **Propuesta:** script de probes gateado (algunos gastan UN turno de modelo cada uno —
  jamás en CI por defecto, mismo criterio que `doctor --smoke`), con veredicto por probe
  y registro en docs/audits/. Si (a) o (b) fallan, la Fase 2 se descarta con razón
  documentada y M20 pasa a `descartada`.
- **Aceptación:** cada probe produce un veredicto reproducible pass/fail con su evidencia
  capturada; el documento de auditoría se actualiza con los resultados; cero turnos
  gastados fuera del flag explícito.

## M20 — Fase 2: `TANDEM_TRANSPORT=mcp` en los wrappers (contingente a M19)

- **Severidad/Esfuerzo:** P2 / L · **Slug sugerido:** `mcp-transport-wrappers`
- **Problema:** migrar el transporte conservando TODAS las garantías de la matriz de
  paridad. Forma decidida por la auditoría: los wrappers bash se vuelven clientes MCP
  (ndjson JSON-RPC contra un proceso `codex mcp-server` con CODEX_HOME de tandem) y
  conservan su interfaz completa — exit codes, artefactos por turno, línea USAGE (desde
  las notificaciones TokenCount), heartbeat, semáforo. La forma "registrar el servidor y
  llamar tools directamente" queda descartada (pierde usage, artefactos y aislamiento).
- **Evidencia:** docs/audits/fase2-mcp-parity.md (matriz completa con severidades).
- **Propuesta:** flag `TANDEM_TRANSPORT` con doble vía y default `exec`; stub de servidor
  MCP para la suite; migración rol a rol (ask → review → implement, cada salto con su
  run tandem); drift-probe equivalente para el map `config` (additionalProperties:true =
  clave renombrada muda); auto-deny de elicitations; híbrido de resume vía CLI si M19(a)
  lo permite; pins por llamada como cinturón sobre el CODEX_HOME aislado.
- **Aceptación:** con `TANDEM_TRANSPORT=mcp`, la suite completa pasa con el stub; un run
  tandem real por rol migrado con paridad de artefactos byte-compatible donde aplique;
  `TANDEM_TRANSPORT` inválido → fail-closed 64; default intacto.
- **Estado tras M19 (2026-08-02):** DESBLOQUEADA. El run real cerró en verde los dos
  bloqueantes — auth desde un CODEX_HOME de tandem autoriza, y el hilo creado por MCP
  revive con `codex exec resume` (probado end-to-end con el codeword). Resultados y
  evidencia en docs/audits/fase2-mcp-parity.md.
- **REQUISITO NUEVO Y DURO** (del cierre estático del probe d): una aprobación de
  MCP-tool bajo `never` cuelga el turno sin timeout y el cliente MCP NO puede resolverla
  (el runner descarta el `ElicitationRequest`). El transporte de producción necesita su
  propio watchdog por turno; `approval-policy: never` no basta.

## M21 — Plan reviews bajo `mcp`: cerrar el gate o completar el contrato

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `mcp-plan-gate`
- **Problema:** hallazgo Major del run real de M20b (range review `m20b`, ejecutada por
  el propio transporte MCP). El gate de `transport_resolve` autoriza el ROL `review`
  completo, pero `skills/plan/SKILL.md` también lanza ese rol (la plan review) y conserva
  legítimamente su excepción foreground para planes pequeños; el contrato ejecutable
  excluye a plan de la regla mcp (`want_mcp=0` — decisión consciente de M20b: el fichero
  estaba fuera de Files to touch). Un `TANDEM_TRANSPORT=mcp` heredado del entorno enruta
  una plan review foreground por MCP con watchdog 3600s: el cap de Bash (600s) la mata
  antes de que el watchdog clasifique — exactamente la pérdida que la regla de background
  existe para impedir.
- **Evidencia:** `.tandem/log/ranges/m20b.md` (round 1, 2026-08-03);
  `scripts/_mcp.sh:95` (gate por rol); `skills/plan/SKILL.md:35` (foreground para planes
  pequeños); `tests/skill-review-background-contract.test.sh:254` (`want_mcp=0` de plan).
- **Propuesta:** decidir UNA de las dos vías del revisor: (a) restringir el gate mcp del
  rol review a los targets del pipeline (`cr-*`/`range-review-*`), fail-closed para el
  resto — más pequeña y conserva el alcance declarado de M20b; o (b) soportar
  oficialmente la plan review bajo mcp — `want_mcp=1` para plan/SKILL.md, nota de opt-in
  equivalente y cobertura — más útil. Decidir en el plan.
- **Aceptación:** con `TANDEM_TRANSPORT=mcp` exportado, una plan review foreground o bien
  es imposible (64 del gate) o bien está oficialmente soportada con su regla de
  background anclada; el contrato ejecutable cubre la vía elegida.

## M22 — Transporte v2: servidor MCP persistente entre invocaciones

- **Severidad/Esfuerzo:** P3 / L · **Slug sugerido:** `mcp-persistent-server`
- **Prioridad BAJA deliberada (decisión 2026-08-03, cierre de la Fase 2):** la
  complejidad es demasiado alta para lo poco que aporta. El valor real de la migración
  MCP — pins por llamada, errores tipados de hilo, watchdog inescapable, aislamiento
  del CODEX_HOME — ya se cobra entero con el servidor-por-turno de v1. Lo único que v2
  añade es `codex-reply` nativo en las continuaciones (hoy cubiertas por el híbrido
  `exec resume`, probado real en los cuatro roles) y ahorrarse un arranque de servidor
  por turno.
- **Problema (lo que costaría):** los wrappers son procesos bash efímeros; hablar con
  UN servidor vivo exige un puente fifo/socket con un problema duro conocido: los
  frames JSON-RPC con diffs inline superan `PIPE_BUF`, así que dos clientes
  concurrentes pueden entrelazar bytes a mitad de frame. Resolverlo bien = multiplexor
  real (demonio con framing propio, locking, ciclo de vida — quién arranca/para el
  servidor, crashes, hilos huérfanos — y seguridad del socket).
- **Evidencia:** docs/audits/fase2-mcp-parity.md (forma decidida y límites declarados);
  plan de M20a (alternativa v2 analizada y descartada para v1).
- **Disparadores que justificarían retomarla:** que las continuaciones por híbrido se
  vuelvan un cuello real (frecuencia o latencia), o que upstream añada resume de hilos
  al propio mcp-server (eliminaría el puente como problema).
- **Aceptación (si se hace):** continuaciones por `codex-reply` sobre un servidor
  compartido sin corrupción de frames bajo concurrencia, con la paridad de artefactos y
  la contabilidad intactas; el híbrido queda como fallback.

## M23 — Swarm de ultra sobre el transporte MCP

- **Severidad/Esfuerzo:** P3 / L · **Slug sugerido:** `mcp-swarm`
- **Prioridad BAJA deliberada (decisión 2026-08-03, cierre de la Fase 2):** misma razón
  que M22 — el swarm sigue `exec` POR DISEÑO (documentado en ARCHITECTURE). Sus seats
  son turnos one-shot read-only: no tienen continuaciones (el valor del hilo se
  pierde), ni el hazard de approvals de los roles de escritura, así que las ganancias
  del transporte apenas les aplican.
- **Problema (lo que costaría):** `codex-swarm.sh` no comparte el camino de los
  wrappers (sin `transport_resolve`, sin superficie `TANDEM_TRANSPORT`). Migrarlo no es
  abrir un gate sino diseño nuevo: N servidores MCP efímeros concurrentes, cada uno con
  su CODEX_HOME + copia de credencial + realojo de rollout, coordinados bajo el
  semáforo de M13.
- **Evidencia:** `scripts/codex-swarm.sh` (cero menciones de transporte);
  docs/ARCHITECTURE.md (decisión "sigue exec por diseño").
- **Disparadores que justificarían retomarla:** que los seats necesiten las garantías
  específicas del transporte (p.ej. errores tipados de hilo en swarms con re-consulta,
  o un watchdog por seat que el semáforo no cubra), o que M22 se haga y abarate el
  camino.
- **Aceptación (si se hace):** un run ultra completo por MCP con el semáforo
  respetado, cero corrupción entre seats concurrentes y el run report idéntico.

## M24 — Watchdog de turno para el transporte exec (start, swarm y resume)

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `exec-watchdog`
- **Origen:** informe de campo 2026-08-21, hallazgo A1 + enmienda E-A1
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** `codex exec` se lanza sin deadline en `codex-start.sh`, `codex-swarm.sh`
  y `codex-resume.sh`, y las skills mandan `run_in_background: true` para el trabajo
  real — donde el tope de 600 s del tool Bash no aplica: un turno colgado es ilimitado y
  su único observador es humano (la statusline). En un enjambre, además, retiene uno de
  los slots del semáforo (el timeout de 1800 s acota la espera de slot, no al ocupante).
  El hueco alcanza también al transporte MCP: sus continuaciones viajan SIEMPRE por el
  híbrido `exec resume`, así que el watchdog de `_mcp.sh` solo protege el primer turno
  de cada hilo — las rondas 2+ de una review a xhigh, los turnos más largos del sistema,
  quedan sin observador.
- **Evidencia:** `scripts/codex-start.sh:143-153`, `scripts/codex-swarm.sh:281-290`,
  `scripts/codex-resume.sh:157` (los tres `codex exec` sin deadline);
  `scripts/_mcp.sh:35,48` — el watchdog por rol (540 s / 3600 s) con TERM→KILL y reaping
  de grupo ya existe: esto es una generalización, no una pieza nueva.
- **Propuesta:** portar el watchdog del transporte MCP al exec en los tres wrappers:
  mismo deadline por rol, misma familia de variables (`TANDEM_*_TIMEOUT_SECONDS`,
  validación fail-closed), TERM→KILL con grupo de proceso, heartbeat cerrando en
  `failed`. Restricción que documenta `_mcp.sh:29-36`: el default de foreground debe
  quedar por debajo de los 600 s del tool Bash para que el wrapper clasifique el cuelgue
  y contabilice el turno antes de morir. Sinergias: el TERM dispara el trap EXIT del
  seat → libera el slot (reduce la incidencia de M30) y desactiva uno de los
  disparadores declarados de M23 a coste M en vez de L.
- **Aceptación:** un turno colgado en cualquiera de los tres wrappers muere por
  TERM→KILL dentro del deadline de su rol, con heartbeat en `failed`, quota
  contabilizada, y (en swarm) el slot liberado; test que pinee el comportamiento con el
  stub de codex.

## M25 — Auditoría de escrituras en implement + hook anti-install para Opus

- **Severidad/Esfuerzo:** P1 / M · **Slug sugerido:** `implement-write-audit`
- **Origen:** informe de campo 2026-08-21, hallazgo A2 + enmienda E-A2
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** con `workspace-write`, dentro de la raíz escribible quedan tres vectores
  que solo prohíbe la prosa del template: reescribir el lockfile, purgar `node_modules`
  y copiar ficheros hacia dentro desde otro árbol. En el implementador Opus por defecto
  no hay sandbox de SO (riesgo residual declarado en el README), así que ahí la prosa es
  la única barrera también para las instalaciones. La lección del incidente de campo
  (julio, bucle de auto-reparación del entorno) es que la prosa no para a un modelo en
  bucle — y el daño es el más caro de diagnosticar: un lockfile regenerado o un parche
  pnpm perdido falla semanas después, en otra máquina.
- **Evidencia:** `skills/implement/prompts/implement.tpl:11,13` (prohibiciones en
  prosa); `agents/implementer.md:4-5` (Opus con Bash, sin sandbox SO);
  `skills/image/SKILL.md:29,75` — el patrón ya implementado en el modo imagen: snapshot
  `git status --porcelain` previo + auditoría posterior; toda escritura no declarada se
  enseña verbatim y se ofrece revertir.
- **Propuesta:** generalizar la auditoría de escrituras del modo imagen a `implement`
  (ambos transportes): snapshot previo y, al cierre, diff de escrituras contra una
  deny-list por defecto (`pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, sección de
  dependencias de `package.json`, `.npmrc`, `patches/`, borrados bajo `node_modules`) —
  cualquier toque NO declarado en el plan produce `IMPLEMENTATION_PARTIAL` con el
  hallazgo nombrado, nunca aceptación silenciosa (lo declarado en el plan gana). Para el
  transporte Opus, además, un hook `PreToolUse` que bloquee `pnpm|npm|yarn install`
  durante un intento. Cuidado de diseño (E-A2): un hook de plugin dispara en CADA Bash
  de toda la sesión — debe consultar un marcador durable de intento-activo en
  `.tandem/state`, y el ciclo de vida de ese marcador (set/clear/crash) es el diseño
  real de la pieza.
- **Aceptación:** un intento que toca la deny-list sin declararlo en el plan termina en
  `IMPLEMENTATION_PARTIAL` nombrando el fichero; un `pnpm install` bajo intento activo
  con transporte Opus es bloqueado por el hook; un intento limpio no nota nada.

## M26 — Interruptor de confidencialidad para `web_search`

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `web-search-switch`
- **Origen:** informe de campo 2026-08-21, hallazgo A3 + enmienda E-A3
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** `web_search` solo se pinea off en asientos de escritura; los read-only
  lo conservan (decisión documentada, residual registrado). Visto desde un repo privado,
  la inversión es incómoda: los asientos que más contenido del repo leen — refutadores,
  revisores, jueces de enjambre — son los que tienen un canal de salida adicional, y el
  usuario del plugin no tiene mando para cerrarlo. El trade-off correcto depende del
  repo (open source: puro valor; comercial: decisión de tratamiento de datos).
- **Evidencia:** `scripts/_pins.sh:56-58` (pin condicionado a `workspace-write`);
  `docs/ARCHITECTURE.md:76` (el residual, registrado honestamente).
- **Propuesta:** `TANDEM_WEB_SEARCH=off` que pinee `web_search=disabled` en TODOS los
  asientos, validada fail-closed como el resto de `TANDEM_*` (set-pero-vacía o valor
  desconocido = usage error); el default actual se queda. Estado efectivo visible en
  `tandem:doctor` y también en la línea de banner que cada seat de swarm ya imprime
  (`codex-swarm.sh:270-271`) — cuesta cero y es donde un run vivo se observa.
- **Aceptación:** con la variable puesta, el argv de todo asiento (start, swarm, resume,
  MCP) contiene el pin off — pineado por test literal como los tiers; sin ella, nada
  cambia; doctor y banner muestran el estado efectivo.

## M27 — Vista de runs ultra en `tandem:status`

- **Severidad/Esfuerzo:** P2 / M · **Slug sugerido:** `status-ultra`
- **Origen:** informe de campo 2026-08-21, hallazgo M1
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** el escáner de runs filtra `ultra-*` explícitamente: para el caso de uso
  «descargar la verificación adversarial a Sol» — el que más cuota mueve — la máquina de
  estados que responde «¿dónde estaba?» no responde. El run más caro es el único
  invisible.
- **Evidencia:** `scripts/tandem-status.sh:1361-1365` (`case "$s" in ultra-*) return 0`);
  `.tandem/state/ultra/<run>/` — seats, prompts, `*.usage.json` por seat y slots ya
  están en disco.
- **Propuesta:** una vista mínima con la misma disciplina de no inventar: seats
  lanzados/completados/fallidos (derivables de slots y usage), suma de tokens del run, y
  la ruta del informe `.tandem/log/ultra-<run>.md`. No hace falta la escalera de 12
  fases. Coherente con «status nunca gasta».
- **Aceptación:** `tandem:status` sobre un run ultra real muestra seats, tokens y ruta
  del informe reconstruidos solo desde disco; un run contradictorio degrada a
  «desconocido», nunca inventa.

## M28 — Rollup de tokens entre runs (`--tokens [--since]`)

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `token-rollup`
- **Origen:** informe de campo 2026-08-21, hallazgo M2 + enmienda E-M2
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** la contabilidad por turno es sólida pero por-slug: nada responde
  «cuánto descargué esta semana». La statusline muestra la sesión Claude en USD y el
  turno Sol en tokens — unidades incomparables.
- **Evidencia:** `scripts/tandem-status.sh` (tokens por slug, sin ventana temporal);
  `scripts/statusline.sh` (línea 1 USD · línea 2 tokens).
- **Propuesta:** `tandem:status --tokens [--since <fecha>]`: rollup sobre los ledgers
  `*.usage.json` ya persistidos (incluidos ultra), por rol y por día. Alcance acotado a
  propósito (E-M2): tokens con tokens, nunca conversión a dólares — exigiría tablas de
  precios de ambos proveedores que quedarían rancias dentro del repo. Sin turno de
  modelo: agregación de ficheros que ya existen.
- **Aceptación:** el rollup suma exactamente los ledgers en disco (verificable a mano
  con jq), respeta `--since`, incluye los runs ultra y no lanza ningún turno.

## M29 — Salvage de contrato JSON en asientos de enjambre

- **Severidad/Esfuerzo:** P2 / S · **Slug sugerido:** `swarm-salvage`
- **Origen:** informe de campo 2026-08-21, hallazgo M3 + enmienda E-M3
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** plan, review, implement e image tienen `nudge.tpl` (turno-recordatorio
  barato con `TANDEM_TURN_EFFORT`); ultra no — sus asientos son hilos frescos sin resume
  por diseño, así que un seat que razona bien pero rompe el contrato JSON de salida se
  relanza a coste completo.
- **Evidencia:** `skills/ultra/prompts/` (solo `seat-preamble.md`);
  `skills/{plan,review,implement,image}/prompts/nudge.tpl` (el patrón existente).
- **Propuesta:** por orden (E-M3): (1) salvage tolerante en el wrapper — extraer el
  último bloque JSON válido de la respuesta antes de declarar el seat fallido; cero
  tokens, cero cambio de diseño. (2) Solo si datos reales muestran que el salvage no
  basta, escalar a un resume solo-nudge (`TANDEM_TURN_EFFORT=minimal`) — que exigiría
  empezar a persistir thread ids del enjambre, tocando el invariante documentado en la
  cabecera de `codex-swarm.sh` («No thread persistence and no resume … deliberate»).
- **Aceptación:** un seat cuya respuesta contiene un bloque JSON válido rodeado de
  narrativa se acepta con el bloque extraído (test con stub); un seat sin bloque válido
  sigue siendo fallo explícito, nunca aceptación de basura.

## M30 — `codex-swarm.sh --reap <run>` para slots huérfanos tras SIGKILL

- **Severidad/Esfuerzo:** P3 / S · **Slug sugerido:** `slot-reap`
- **Origen:** informe de campo 2026-08-21, hallazgo M4 + enmienda E-M4
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** un seat muerto por SIGKILL (lo único que salta el trap EXIT) deja su
  `.slots/slot.N` ocupado y el heartbeat en `running`; la limpieza es manual («borra el
  directorio a mano»). El no-reclaim automático está bien razonado — probar el pid del
  holder para robar el slot en caliente añadiría las carreras rm/mkdir que el semáforo
  existe para eliminar — pero la salida manual merece una herramienta.
- **Evidencia:** `scripts/codex-swarm.sh:210-218` (no-reclaim documentado), `:246` (el
  mensaje de error que hoy manda a cirugía manual); `tests/hb-term-vs-kill.test.sh:2-6`
  (la asimetría TERM/KILL, pineada). Descartada la variante «reap al arranque del run»
  del informe (E-M4): el semáforo es por-run y cada seat una invocación independiente —
  un run nuevo nace con slots vacíos, y en los reintentos dentro del mismo run no existe
  un «arranque» al que anclar el reap sin volver a depender de prosa.
- **Propuesta:** `codex-swarm.sh --reap <run>` explícito: recorre los slots del run,
  comprueba la vida del pid del `holder`, elimina solo los muertos y reporta lo hecho;
  el mensaje de error de `:246` pasa a nombrarlo. Mismo control humano, mejor
  herramienta. Nota: M24 reduce la incidencia por sí solo (TERM del watchdog → trap
  EXIT → slot liberado).
- **Aceptación:** tras un SIGKILL simulado, `--reap <run>` libera el slot huérfano y
  deja intactos los slots con holder vivo; el mensaje de «no free ultra slot» nombra el
  comando.

## M31 — `TANDEM_PLANS_DIR` configurable

- **Severidad/Esfuerzo:** P3 / S · **Slug sugerido:** `plans-dir`
- **Origen:** informe de campo 2026-08-21, hallazgo B1
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** la ruta `docs/plans/<slug>.plan.md` es fija; un repo con convención de
  planning propia (el banco de pruebas del informe lleva `docs/planning/` con numeración
  y ciclo de vida propios) no puede adoptar el pipeline sin que las dos convenciones se
  pisen.
- **Evidencia:** `scripts/plan-approve.sh:77` (`PLAN_REL="docs/plans/$SLUG.plan.md"`)
  sobre la transición fail-closed de `:17-24`; la ruta aparece también en la skill de
  plan y en status — el cambio debe cubrir todas las referencias.
- **Propuesta:** `TANDEM_PLANS_DIR` (default `docs/plans`), validada fail-closed como el
  resto de `TANDEM_*`, y una nota de interop en el README para repos con planning
  preexistente.
- **Aceptación:** un run completo con `TANDEM_PLANS_DIR=docs/tandem-plans` aprueba,
  implementa y status-ea el plan bajo esa ruta; sin la variable, nada cambia; valor
  vacío o ruta absoluta fuera del repo = usage error.

## M32 — Campos del log derivados de fuente máquina, no transcritos

- **Severidad/Esfuerzo:** P3 / S · **Slug sugerido:** `log-machine-fields`
- **Origen:** informe de campo 2026-08-21, hallazgo B2 + enmienda E-B2
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** el `USAGE:` por ronda en el log del slug, el bloque del gate y la línea
  final con el sha del commit los escribe el modelo siguiendo prosa — cuando el usage ya
  está en los ledgers y el sha en git. Una transcripción mala no rompe nada, pero
  ensucia el registro que status luego lee. El repo ya enuncia el principio aplicable:
  «machine work, not something a wrapper model should retype verbatim» (comentario del
  preámbulo en `codex-swarm.sh`).
- **Evidencia:** `skills/review/SKILL.md:65,135` (la copia manual del `USAGE:` como
  contrato de prosa); ledgers `*.usage.json` y `git rev-parse` como fuentes máquina ya
  existentes.
- **Propuesta:** derivar esos campos de la fuente máquina al escribir el log (ledger
  para usage, `git rev-parse` para el sha — vía script o snippet que la skill invoque) y
  dejar la copia del modelo como narrativa, no como registro.
- **Aceptación:** las líneas de tokens y sha del log de un run real coinciden byte a
  byte con ledger y git; un modelo que transcribe mal ya no puede ensuciar esos campos.

## M33 — Guía de adopción + snippet de CLAUDE.md para repos con políticas previas

- **Severidad/Esfuerzo:** P3 / S · **Slug sugerido:** `adoption-guide`
- **Origen:** informe de campo 2026-08-21, hallazgo B3
  (`docs/audits/informe-campo-2026-08-21.md`).
- **Problema:** hallazgo de campo literal: el CLAUDE.md del banco de pruebas aún decía
  «Codex retirado» por un incidente anterior — y un agente fresco que lee eso rehúsa
  usar el plugin aunque esté instalado y sea precisamente la respuesta a aquel
  incidente. La política del proyecto y la existencia del plugin no se encuentran:
  estado «instalado pero inutilizable por política fantasma».
- **Evidencia:** cualitativa (campo); no hay fichero del repo que citar — ese es el
  hueco.
- **Propuesta:** sección de adopción en el README con un snippet de CLAUDE.md listo para
  pegar: qué asientos están sancionados (read-only), cuáles requieren decisión
  (implement), y que el sandbox lo garantiza el plugin, no la memoria del proyecto.
  Cuesta un párrafo.
- **Aceptación:** el README contiene la sección y el snippet; el snippet menciona
  explícitamente que las garantías son estructurales (pins re-aplicados por turno), para
  que una política previa anti-delegación pueda relajarse con criterio y no por fe.
