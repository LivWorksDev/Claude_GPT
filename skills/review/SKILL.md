---
name: review
description: Independent final code review of the uncommitted diff by a FRESH GPT-5.6 Sol thread (read-only) that has no memory of the plan debate or the implementation. Use after tandem:implement and before committing. NOT for reviewing plans (use tandem:plan) and NOT for already-committed code.
argument-hint: "[slug of the implemented plan]"
---

# tandem:review — revisor final independiente

The final reviewer must arrive with **zero context contamination**: a brand-new Sol thread that never saw the plan debate or the implementation thread. You arbitrate its findings; the user approves the final diff; only then do YOU commit (Codex never commits).

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`. Log: `.tandem/log/<slug>.md`.
State key for this skill: `cr-<slug>` (distinct from the plan-review thread, which uses the plan path).

## Step 0 — Input gates

1. There is an uncommitted diff (`git status --porcelain` non-empty). Nothing to review → stop.
2. The testing gate summary exists in `.tandem/log/<slug>.md`. Missing → run the gate first (see tandem:implement Step 4).

## Step 1 — Fresh-thread guarantee

If a thread already exists for `cr-<slug>` from a previous attempt of THIS review round-trip, resume it (same reviewer re-checking its own findings is correct). If it belongs to an older, different diff: `bash "$SCRIPTS/codex-reset.sh" review cr-<slug>` first.

## Step 2 — Start the review

Build the context file `.tandem/tmp/<slug>-cr-context.md` containing exactly:
- `Plan: docs/plans/<slug>.plan.md`
- The testing-gate summary line.
- Branch name and base (e.g. `tandem/<slug>` off `main`).
- The changed-file list from `git status -s`; if any files are untracked (`??`), say so explicitly — they are invisible to `git diff HEAD` and the reviewer must read them directly.

```bash
bash "$SCRIPTS/codex-start.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/start.tpl" \
  .tandem/tmp/<slug>-cr-context.md
```

(Bash timeout: 600000.) If Codex's sandbox cannot run `git diff`, re-run passing the diff inline: append it to the context file under a `DIFF:` heading.

## Step 3 — Loop (max $TANDEM_CR_ROUNDS or 3)

Read the final `VERDICT:` line:

- No `VERDICT:` line at all → resume the SAME thread asking only for the missing verdict line; this counts as a round. If it happens twice, treat the reply as REQUEST_CHANGES and note the anomaly in the log.
- `VERDICT: APPROVED` → go to Step 4.
- `VERDICT: REQUEST_CHANGES` → arbitrate each finding by severity (Critical/Major must be fixed or explicitly rebutted with evidence; Minor/Suggestion at your judgment):
  1. Apply fixes yourself, or resume the *implement* thread for large ones. Re-run the testing gate after any fix.
  2. Log round + dispositions in `.tandem/log/<slug>.md`; write dispositions to `.tandem/tmp/<slug>-cr-dispositions.md`. If Step 2 needed the inline-DIFF fallback, append the UPDATED diff under a `DIFF:` heading at the end of that same dispositions file — otherwise the reviewer cannot see your fixes.
  3. Resume the SAME reviewer thread (Bash timeout: 600000):

```bash
bash "$SCRIPTS/codex-resume.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/resume.tpl" \
  "" .tandem/tmp/<slug>-cr-dispositions.md
```

- Cap reached without APPROVED → deadlock protocol: present both positions honestly to the user; never fake convergence. In autonomous mode this is a terminal DEADLOCK: report and stop — nothing gets committed.

## Step 4 — Human gate, then commit

Present: diff summary, gate summary, reviewer verdict, rounds used, link to the log. Ask the user to approve the diff (AskUserQuestion).

**`TANDEM_AUTONOMOUS=1`**: the gate becomes policy — commit without asking ONLY when the reviewer's verdict is `APPROVED` **and** the testing-gate summary in the log is green (re-run after any fix). `TANDEM_PROMOTE_REVIEWS` was validated as set (0/1) at the run preflight — honor its value, never ask. The commit lands on `tandem/<slug>` and the run ends there: no push, no merge, no PR — those remain human.

**Optional review record** — `.tandem/` is ephemeral and gitignored; this step is the only way the review outcome survives in the repo. Controlled by `TANDEM_PROMOTE_REVIEWS`: `1` = always write it, `0` = never, unset = offer it as part of the approval question. When promoting, write `docs/reviews/<slug>.md` with: date, plan path, branch, gate summary, plan-review rounds + final verdict, code-review rounds + final verdict, and the condensed findings/dispositions taken from `.tandem/log/<slug>.md`. Never include thread ids (machine-local noise). Include this file in the approval commit.

Only after explicit approval: **you** write the commit (never Codex, never before approval). Then offer next steps: merge/PR per the project's own conventions — tandem deliberately does not impose a release process.
