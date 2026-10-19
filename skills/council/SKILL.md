---
name: council
description: Adversarial council of three frontier models from two families that weighs an idea and optimises the procedure to reach a goal - this session (Opus 5.5, max) interviews the user, freezes a brief, competes with its own proposal, moderates and synthesises; Fable 5.1 (Claude subagent) and GPT-6 Astra (Codex thread), both at max and read-only, propose blind, cross-examine each other and review the synthesis round by round until consensus or the round cap. Leaves a Markdown report plus the full transcript under docs/council/. Use when the user wants an idea evaluated or a strategy optimised against a measurable goal. NOT for plans, diffs or code (use tandem:plan / tandem:review / tandem:ultra) and NOT for a quick second opinion (use tandem:ask).
argument-hint: "[idea y objetivo]"
effort: max
---

# tandem:council — consejo adversarial de tres modelos

You are the **leader**: Opus 5.5 at max effort. You interview the user, freeze a brief, compete with your own proposal, moderate and synthesise. The two reviewing seats are Fable 5.1 (agent type `tandem:council-fable`) and GPT-6 Astra (Codex role `council`), both at max and read-only. You compete and you synthesise, but **you do not vote**: consensus belongs to the two reviewers, and only `council.sh status` declares it.

Shared script: `COUNCIL="${CLAUDE_SKILL_DIR}/../../scripts/council.sh"`. Every subcommand except the Astra turns is fast and runs in the foreground. Exit codes: 0 ok · 1 condition not met · 2 already exists · 64 usage · 65 integrity · 75 congestion (run lock taken, or an Astra turn of the target still alive).

The user intervenes only at the start (questions + brief approval); after the brief gate the council runs on its own to the end. Nothing is ever committed or pushed: the user decides what to do with `docs/council/`.

## Step 0 — Preflight, self-declaration and run

The preflight goes first, before anything else, and spends no turn:

```bash
bash "$COUNCIL" preflight
```

Exit 1 → show the user every FAIL line and STOP. Then **declare the model ID your system prompt names**. If it is not `TANDEM_COUNCIL_LEADER_MODEL` (default `claude-opus-5-5`; the preflight summary prints the expected one), STOP and explain how to switch — the model selector or `/model` — and never continue with another leader: a plugin cannot pin the leader, and a skill-level `model:` would last only one turn of a debate that spans many.

Choose a run id `YYYY-MM-DD-<slug>` and create the run (`--offline` is the confidential mode: Astra without web search, Fable through its twin without web tools):

```bash
bash "$COUNCIL" init <run-id>
bash "$COUNCIL" init <run-id> --offline
```

Run `init` from the project root — this session's working directory at the start. It prints `PROJECT`, `DOC_DIR`, `RUN_DIR` and the letters drawn at random (`LETTERS: A=… B=… C=…`); the moderator never chooses them. **Every later command carries `CLAUDE_PROJECT_DIR="<project>"`**, with the `PROJECT` path `init` printed: your Bash working directory can move between calls, and a call from somewhere else would not find the run (real canary, 2026-10-18; `council.sh` also looks for it in the parents of the working directory, but the pin is the contract). Keep your letter, Astra's and Fable's: every `stage` names one. **Invoked with an existing run id**, run `CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" status <run-id>` instead (the project root where the run was created): its `PHASE:` line says where the run is, and it resumes from there.

## Step 1 — Interview and brief (gate)

With `TANDEM_COUNCIL_INTAKE=ask` — the default, and the user's choice — interview the user. The intake never reads `TANDEM_AUTONOMOUS`: that variable may be permanently on in this environment and would cancel the interview the user asked for. Use AskUserQuestion, up to four questions per call, each with a recommended answer, and ask only what changes the strategy: the measurable goal, horizon, resources, constraints, what was already tried, what is not negotiable, the success criterion, and which project files are context.

Write `DOC_DIR/brief.md` with these fixed sections: **Objetivo** · **Horizonte** · **Recursos** · **Restricciones** · **Ya probado** · **No negociable** · **Criterio de éxito** · **Contexto del proyecto** (files, read-only) · **Supuestos**.

Gate: the user approves the brief AND confirms that this session runs on the leader model at max effort (`max` is chosen per session — model selector or `/effort max`; it is not accepted in `effortLevel` settings). Show the turn bound the preflight printed and the cost note (Fable may bill usage credits). Only then freeze it:

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" seal <run-id> brief
```

With `TANDEM_COUNCIL_INTAKE=auto`: no questions; every gap becomes an explicit item under **Supuestos**; if the goal or the success criterion cannot be derived without inventing them, STOP and ask for a complete brief.

## Step 2 — Phase 1: blind proposals

1. Write YOUR proposal to `RUN_DIR/sealed/propose.md` (the structure of `prompts/phase-propose.md`, last line `ENTREGA: PROPUESTA`) and seal it BEFORE launching the seats — the seal is the executable proof that you wrote yours before seeing theirs (`stage` prepares no seat prompt of the phase before it, and `seal` answers 65 once one is staged: a Fable seat can answer before any capture exists):

   ```bash
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" seal <run-id> propose
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> propose <astra-letter>
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> propose <fable-letter>
   ```

   Each `stage` prints the absolute path of the prompt it wrote.
2. In the SAME message, launch both seats in the background:
   - **Astra** — Bash with `run_in_background: true`:

     ```bash
     CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" astra <run-id> propose
     ```

   - **Fable** — the Agent tool with `run_in_background: true`, `subagent_type: tandem:council-fable` (`tandem:council-fable-offline` in a run created with `--offline`), with **no `model` and no `effort` parameter** in the call: a value in the call would win over the frontmatter and persist into every continuation, and the frontmatter is the only source of the seat's pin. The prompt is exactly this fixed task text:

     «Eres el asiento `<L>` del consejo `<run-id>`. Lee completo el fichero `<ruta absoluta>` y responde exactamente como pide.»

     with Fable's letter and the absolute path `stage` printed. Then record the agent with the id and the `output_file` the launch returned:

     ```bash
     CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" record-agent <run-id> <agent-id> <output-file>
     ```

3. **Two hard synchronization barriers: the completion notification of the Astra Bash run, and Fable's final report — the `SubagentHandback` message (or the agent result) that carries its answer.** Before BOTH arrive you do not capture, publish, stage another phase, write a synthesis or message either seat. **Do NOT also wait for the Fable agent's separate completion notification**: in the desktop app it arrives after the handback and opens no turn, so a leader waiting for it stalls (real canary, 2026-10-18, 15 h stopped). Once both barriers are met, capture in the same turn; while one is still missing, end the turn.
4. Capture Fable's answer from its transcript (model verified, usage deduplicated):

   ```bash
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" capture <run-id> propose
   ```

5. If an answer lacks a line the machine reads (its sentinel, its `VERDICT:`, a `RIESGO RESIDUAL:` next to an APPROVED, a status line of its own P1/P2), send ONE reminder to that seat — `stage` computes exactly what is missing:

   ```bash
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> propose <letter> --reminder
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" astra <run-id> propose --reminder
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" capture <run-id> propose --reminder
   ```

   For Astra, the second line (Bash, background, same barrier). For Fable, `SendMessage` to the recorded agent naming the reminder file — «Lee completo el fichero `<ruta absoluta>` y responde exactamente como pide.» — and, after its `SubagentHandback`, the third line.
6. Publish — the barrier between phases. It moves only machine-verified answers of the current attempts; failed and interrupted turns never reach `DOC_DIR`:

   ```bash
   CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" publish <run-id> propose
   ```

## Step 3 — Phase 2: cross-examination

The same pattern: write `RUN_DIR/sealed/cross.md` (your cross-examination of the other two proposals, objections in the exact format with YOUR letter, last line `ENTREGA: CONTRAINTERROGATORIO`), then:

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" seal <run-id> cross
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> cross <astra-letter>
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> cross <fable-letter>
# Bash with run_in_background: true — and, in the same message, SendMessage to Fable:
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" astra <run-id> cross
# only after BOTH barriers — Astra's notification and Fable's SubagentHandback:
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" capture <run-id> cross
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" publish <run-id> cross
```

Each seat receives the other two proposals by letter. Astra runs in the background; Fable continues through `SendMessage` to the recorded agent naming its cross prompt. The same barriers, the same reminders.

## Step 4 — Synthesis v1 and its source audit

Write `DOC_DIR/sintesis-v1.md` with fixed sections (**Estrategia**, **Por qué esta y no las alternativas**, **Supuestos**, **Riesgos y mitigaciones**, **Métricas, umbrales y criterios de abandono**, **Primeros 30 días**) and `DOC_DIR/registro.md`, one row per objection of every published answer:

    | B-3 | P2 | ACEPTADA | <dónde / por qué> |

The disposition is `ACEPTADA`, `RECHAZADA` or `ABIERTA`, and the severity is ALWAYS the one its author declared — you cannot downgrade a P1. The register must pass:

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" ledger <run-id>
```

Then audit, with WebFetch, the sources of the figures that support decisions of the synthesis, and write `DOC_DIR/auditoria-v1.md`, one line per source: `- [F1] VERIFICADA <url> — <cifra o afirmación>` (or `NO ACCESIBLE`, or `NO CONFIRMA`). A `NO CONFIRMA` forces you to fix the synthesis and audit again before launching the round — `stage round-1` refuses an audit that still carries one. Offline: the audit is the single line `- OFFLINE: no aplica`, and every figure that comes neither from the user nor from the project stays a SUPUESTO.

## Step 5 — Rounds 1..R

For each round N (R = `TANDEM_COUNCIL_ROUNDS`, default 4):

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> round-<N> <astra-letter>
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" stage <run-id> round-<N> <fable-letter>
# Bash with run_in_background: true — and, in the same message, SendMessage to Fable:
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" astra <run-id> round-<N>
# only after BOTH barriers — Astra's notification and Fable's SubagentHandback:
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" capture <run-id> round-<N>
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" publish <run-id> round-<N>
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" ledger <run-id>
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" status <run-id>
```

The Astra turn (background) and the `SendMessage` to Fable naming its round prompt go out in parallel; both barriers hold before `capture`; a reminder goes out if the `VERDICT:`, the `RIESGO RESIDUAL:` or a status line is missing. After `publish`, dispose every NEW objection in `registro.md` and answer every `REABRE` (in the next synthesis), then `ledger` and `status`. `STATUS: CONSENSO` → Step 6. N = R → Step 6 with `SIN_CONSENSO`. Otherwise write `sintesis-v<N+1>.md`, its `auditoria-v<N+1>.md` and run the next round.

## Step 6 — The report

```bash
CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" status <run-id> --metadata
```

It copies, byte for byte, the synthesis reviewed in the last round to `DOC_DIR/estrategia-final.md` and writes `DOC_DIR/metadatos.md` (letters revealed → model/effort with their evidence, rounds and verdicts, anomalies, tokens). Its exit code is the status (0 CONSENSO, 1 SIN_CONSENSO): both files are written either way. Then write `DOC_DIR/informe.md` with these fixed sections: **Resumen ejecutivo** · **La estrategia** (a link to `estrategia-final.md`: the report summarises it and never rewrites or corrects it — a change after the last round would be a text no reviewer approved) · **Por qué esta y no las alternativas** · **Supuestos** (verified with source / to validate, with the minimal experiment) · **Riesgos y mitigaciones** · **Métricas, umbrales y criterios de abandono** · **Primeros 30 días** · **Decisiones pendientes** (the ABIERTA rows) · **Disidencias** (verbatim quotes of the seats) · **Estado** (CONSENSO or SIN_CONSENSO with the reasons `status` printed) · a link to `metadatos.md`.

## Failures, retries and the turn bound

Per phase and seat there are at most two substantive turns (the original and one retry) and one reminder, and the caps are executable: `stage` prepares no third attempt, `astra` launches no third substantive turn nor a second reminder, and `capture` captures nothing beyond the cap (65).

- **Astra failed and its thread is still valid** (or it has none yet: a failed start) → retry once with the same inputs: `stage <run-id> <phase> <astra-letter>` (the next attempt) and `astra` again.
- **The wrapper rejected Astra's thread** — its stderr says `codex resumed thread … instead of …`, or that the thread file is empty → rebuild: `stage <run-id> <phase> <astra-letter> --with-history` opens the next generation of the target (a NEW thread that receives its own published outputs), then `astra`. The wrapper's own hint to reset the state does not apply here: the generation replaces it.
- **Fable lost with its session, or its answer never arrives** → rebuild the same way: a NEW agent launched with the prompt of `stage <run-id> <phase> <fable-letter> --with-history`, then `record-agent` for it. A Fable seat whose session is no longer the current one is treated as lost (subagents do not survive their creating session) and rebuilt — never probed.
- **`capture` exits 1** (no answer in the transcript, or the format changed) → visible degradation: transcribe the Agent result into the reply file the error names and run `capture <run-id> <phase> --manual`; it is recorded as transcribed, model not verified.
- **`capture` exits 65** (another model answered: a forced model, a wrong agent type or a silent model switch) → **FAILED** terminal, state preserved.
- A second failure of the same seat in the same phase, or any cap that answers 65 → **FAILED** terminal with the state preserved. In the rounds, a format that still fails after its reminder counts as REVISE, with the anomaly shown.
- `astra` exiting **75** means an earlier turn of the target is still alive: wait for its notification. Any subcommand answering **75 on the run lock** names the lock and its owner; if that owner is gone, the lock is orphaned (only a kill inside a critical section leaves one) and it is never reclaimed automatically — show it to the user, who removes it by hand. **65 with `bloqueada`** means a turn's liveness cannot be established: only a person resolves it, with `CLAUDE_PROJECT_DIR="<project>" bash "$COUNCIL" unblock <run-id> <target>` — run it only if the user asks.

The bound shown at the brief gate: typical `2 × (2 + R)` max-effort seat turns (12 with R = 4); ceiling `5 × (2 + R)` max-effort turns (Fable: substantive, retry and reminder, all three at max because its effort lives in the frontmatter; Astra: substantive and retry) plus `2 + R` Astra reminders at `low` (30 + 6 with R = 4). The counters live in `run.json`, so they survive a recovery.

## Red lines

- The seats never write, and you never edit a seat's answer: only `capture` and `publish` move them (`--manual` is the one exception, and it is visible).
- Consensus comes only from `status`: never declare it without `STATUS: CONSENSO`.
- Never commit and never push anything: the user decides what to do with `docs/council/` (an idea can be confidential and the repo public).
- Astra's turns go ONLY through `council.sh astra`: never `codex-start.sh` or `codex-resume.sh` directly, never `TANDEM_TRANSPORT` nor `TANDEM_TURN_EFFORT` in this skill (the script alone decides each turn's effort: max, or low for a reminder), and never `codex-reset.sh` on a council target — a rejected thread is replaced by the next generation, because the reset would delete the usage ledger and the per-turn `meta.json`, the run's accounting and its evidence.
- Neither `model` nor `effort` in the Agent call, and every Fable turn names a prompt prepared by `stage`.
- Never use `SendMessage` as a probe: messaging a finished agent starts new background work (the same rule as `skills/implement/SKILL.md`).
- The two hard barriers are the Astra Bash run's completion notification and Fable's `SubagentHandback`; never wait for the Fable agent's separate completion notification on top of them.
- `capture` 65, or a cap of «Failures, retries and the turn bound» → FAILED terminal with the state preserved.
