---
name: plan
description: Interview the user, write an implementation plan, then have GPT-5.6 Sol (via Codex CLI, read-only, persistent thread) adversarially review it until APPROVED or the round cap. Use at the start of any non-trivial feature, refactor or migration. NOT for trivial edits (a few lines, docs, config tweaks), NOT for reviewing existing code (use tandem:review) and NOT for quick second opinions (use tandem:ask).
argument-hint: "[feature description]"
---

# tandem:plan — plan endurecido por adversario

You are the orchestrator and final arbiter. Codex/Sol is your adversarial reviewer — it critiques, you decide.

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`.
Artifacts: plan in `docs/plans/<slug>.plan.md` (versioned), append-only log in `.tandem/log/<slug>.md` (gitignored).
`<slug>` is a short kebab-case name for the feature; reuse it verbatim across every tandem skill for this piece of work.

## Act 1 — Interview (no Codex yet)

1. Explore the codebase first. Never ask the user something the code can answer.
2. Ask ONE question at a time (AskUserQuestion when options are enumerable), with your recommended answer. Cover: goal, constraints, priorities, out-of-scope. Typically 3–7 questions; stop when decisions are locked, not when questions run out.
3. Write `docs/plans/<slug>.plan.md` with exactly these sections:
   - **Goal** — one paragraph.
   - **Approach** — how, at file level where possible.
   - **Key decisions & tradeoffs** — name the contestable choices explicitly (this gives the reviewer something concrete to attack).
   - **Files to touch** — list with expected nature of change.
   - **Acceptance & proof** — the acceptance cases, and a single PROOF command (test/lint invocation) that must pass.
   - **Risks** — what could break.
   - **Out of scope** — explicit non-goals.
4. Initialize `.tandem/log/<slug>.md` with a header: feature, date, plan path, `MAX_ROUNDS`.

## Act 2 — Adversarial review loop (Sol, read-only)

`MAX_ROUNDS` = `$TANDEM_PLAN_ROUNDS` or 5. The same thread reviews every round so Sol remembers its findings.

**Round 1** (Bash timeout: 600000 — reviews with xhigh effort are slow; the default 2-minute timeout will kill them):

```bash
bash "$SCRIPTS/codex-start.sh" review docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/start.tpl"
```

Exit 2 means a thread already exists for this plan: resume it if you are continuing the same work, or `codex-reset.sh review docs/plans/<slug>.plan.md` if this is a fresh plan under a reused name.

**Each round**, read the reply's final `VERDICT:` line:

- No `VERDICT:` line at all → resume the SAME thread asking only for the missing verdict line; this counts as a round. If it happens twice, treat the reply as REVISE and note the anomaly in the log.
- `VERDICT: APPROVED` → break, go to Resolution.
- `VERDICT: NEEDS_REWORK` → stop the loop and escalate to the user with Sol's reasoning; do not silently rewrite everything.
- `VERDICT: REVISE` → you arbitrate every finding:
  1. For each finding decide ACCEPTED (revise the plan) or REJECTED (with a reason). Never accept everything blindly; never ignore the critic.
  2. Append to `.tandem/log/<slug>.md`: `## Round <n> — Sol` (full critique) and `### Dispositions` (finding → decision → reason/change).
  3. Write the dispositions block to `.tandem/tmp/<slug>-dispositions.md`.
  4. Resume the SAME thread (timeout: 600000). The 4th arg (extra-file) is unused here — pass `""`; the 5th arg fills `{{NOTES}}`:

```bash
bash "$SCRIPTS/codex-resume.sh" review docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/resume.tpl" \
  "" .tandem/tmp/<slug>-dispositions.md
```

- Round cap reached without APPROVED → **deadlock is a legitimate outcome**: present the unresolved disagreements and both positions to the user. Never fake convergence.

## Resolution — human gate

Present: final plan, 3-bullet summary, Sol's final verdict, rounds used. Ask the user (AskUserQuestion): approve and continue to `/tandem:implement`, revise further, or stop. Do not start implementing without explicit approval.

On approval, commit the plan — ONLY the plan file (`git add docs/plans/<slug>.plan.md && git commit`); this commit is sanctioned by the human gate and keeps the tree clean for tandem:implement's clean-tree gate. Implementation changes remain forbidden to commit until the final diff gate in tandem:review.
