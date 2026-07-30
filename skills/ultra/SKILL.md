---
name: ultra
description: Fable-directed multi-agent swarms (ultracode-style) where every reasoning seat is a Codex model - Sol xhigh in seats that would need a frontier judge, Sol high in standard analysis seats, Luna high in mechanical sweeps; all read-only. Use when the user asks for a swarm, panel, or comprehensive adversarial pass over a plan, diff, codebase or question. NOT for writing code (tandem:implement), NOT a replacement for the pipeline's final review gate (tandem:review), and NOT for a simple second opinion (tandem:ask).
argument-hint: "[task description]"
---

# tandem:ultra — enjambres dirigidos por Fable

You direct; Codex reasons. Every seat of the swarm is a Codex turn launched through `codex-swarm.sh` — fresh context, read-only, no thread persistence. The user invoking this skill is their explicit opt-in to multi-agent orchestration: use the **Workflow** tool for the fan-out.

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`. Seat preamble: `PREAMBLE="${CLAUDE_SKILL_DIR}/prompts/seat-preamble.md"`.

## Step 0 — Deliberation (what makes this "dirigido")

A swarm is a decision, not a reflex. Before launching anything:

1. **Is a swarm warranted?** Factual questions, trivial checks, single-perspective doubts → decline and recommend `tandem:ask` (or just answer). A swarm earns its cost when the task needs *coverage* (many dimensions/files), *independent verification* (adversarial findings), or *diverse judgment* (competing designs).
2. **Pick a shape** from the catalog below and size it. Default sizes are small (≤5 seats per phase); scale up only if the user explicitly asked for exhaustiveness.
3. **Present the proposal**: shape, seats with their tiers, total Codex turns, what the synthesis will look like. Get approval via AskUserQuestion. With `TANDEM_AUTONOMOUS=1` do not ask: proceed only if the brief already determines shape and scope without inventing; otherwise stop and request a complete brief (before launching anything, as in tandem:run).
4. Choose a kebab-case `<run-id>` unique to this run.

## Seat tiers — the model mapping

Where a native ultracode workflow would seat a Claude model, seat Codex instead:

| Seat purpose | Tier | Model (default) | Effort |
| --- | --- | --- | --- |
| Frontier judge: arbitration, adversarial verify, final synthesis | `judge` | `gpt-5.6-sol` | `xhigh` |
| Standard analysis: per-dimension review, deep reads, design attempts | `worker` | `gpt-5.6-sol` | `high` |
| Mechanical sweeps: triage, inventories, pattern hunts | `scout` | `gpt-5.6-luna` | `high` |

Env overrides: `TANDEM_ULTRA_{JUDGE,WORKER,SCOUT}_MODEL` / `_EFFORT`. The sandbox is `read-only` for every tier and is NOT overridable: seats reason and report, they never write. Implementation always goes through the tandem pipeline.

## Mechanics — the wrapper pattern

Workflow `agent()` seats are Claude models, so each seat is a **cheap Claude wrapper** (`model: 'haiku'`) whose only job is to run the Codex turn and structure the result. Embed this wrapper prompt in every `agent()` call (with `schema` so the result comes back validated):

```
You are a mechanical seat runner. Do exactly this and nothing else:
1. Write .tandem/tmp/ultra-<run-id>-<seat>.md containing ONLY the BRIEF below,
   verbatim. Do not copy, summarize or restate the preamble: the script
   prepends it.
2. Run (Bash timeout: 600000):
   bash <SCRIPTS>/codex-swarm.sh --preamble "<PREAMBLE>" <tier> <run-id> <seat> .tandem/tmp/ultra-<run-id>-<seat>.md
3. From the script output between the '--- codex reply' and '--- end ---'
   markers, extract the seat's final output contract and return it as your
   structured result. Add nothing of your own. If the script fails, return
   the error field filled with its last stderr lines.

BRIEF:
<the seat's brief>
```

Resolve `<PREAMBLE>`/`<SCRIPTS>` to absolute paths when authoring the script. The preamble travels as a **path**, never as text a wrapper retypes: `codex-swarm.sh` concatenates it ahead of the brief byte for byte, and the staged `.tandem/state/ultra/<run-id>/<seat>.prompt.txt` is what the seat actually received. Seat briefs must be **self-contained** (a seat sees nothing else: name concrete paths, paste the diff hunk or plan section it must judge) and must end by demanding the output contract — a fenced JSON object matching the wrapper's schema as the last thing in the reply.

Concurrency: read `TANDEM_ULTRA_CONCURRENCY` (default 4) in the session and pass it into the script via `args`; chunk every `parallel()` batch to that size. Each seat is a live `codex exec` against the user's OpenAI account — the harness cap (~16) is too high a ceiling for this.

## Shapes

- **Adversarial review swarm** — `worker` seats review one dimension each (correctness, security, tests, simplification…); every finding goes to 2–3 `judge` seats prompted to REFUTE it; majority-refuted findings die. Pipeline, not barrier: a dimension's findings verify while others still review.
- **Judge panel** — N `worker` seats attack the same design/plan question from assigned angles; `judge` seats score the attempts; you synthesize from the winner, grafting the runners-up's best ideas.
- **Bug hunt (loop-until-dry)** — `scout` seats sweep by different lenses (by-module, by-pattern, by-recent-change); fresh findings go to `worker` confirmation; stop after 2 consecutive dry rounds. Dedupe against everything *seen*, not just confirmed.
- **Research sweep** — `scout` seats inventory (files, usages, conventions); `worker` seats deep-read the shortlist; one `judge` seat synthesizes with a completeness check ("what did no seat cover?").

## Results

- Append a run report to `.tandem/log/ultra-<run-id>.md`: shape, seats and tiers, per-seat outcome, dropped/refuted findings, final synthesis. Seat replies persist under `.tandem/state/ultra/<run-id>/` (gitignored, like all of `.tandem/`).
- Present the synthesis with disagreements **visible**: split judge votes are reported as split — the deadlock-honesty rule applies to swarms too.
- An ultra review feeds the pipeline, it never replaces it: its output is a finding list or plan feedback, not an approval. `tandem:review`'s independent gate (and the human/autonomous commit policy) stands untouched.

## Red lines & degradation

- Seats never write, never commit, never resume another seat's thread; sandbox pinned `read-only`.
- Never launch without Step 0's deliberation and approval (or a complete autonomous brief).
- Workflow tool unavailable → same seats via parallel `Agent` calls; Agent unavailable → sequential `codex-swarm.sh` runs in background Bash. Script, preamble and briefs are identical in all three modes — only the harness changes.
