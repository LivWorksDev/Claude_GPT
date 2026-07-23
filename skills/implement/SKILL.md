---
name: implement
description: Delegate implementation of an approved tandem plan to Codex (GPT-5.6 Sol; effort high, or xhigh when TANDEM_CRITICAL=1) in a workspace-write sandbox on a dedicated branch, then personally verify the full diff and run the blocking testing gate. Use after a plan was approved via tandem:plan. NOT for trivial changes (implement those directly) and NOT without an approved plan.
argument-hint: "[slug of the approved plan]"
---

# tandem:implement — Codex implementa, tú verificas

You are the orchestrator. Codex implements; **you** read the diff, run the tests and own the result. Codex NEVER commits — and you commit no implementation changes until the user approves the final diff after `/tandem:review` (the plan file itself was already committed at the tandem:plan human gate).

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`. Log: `.tandem/log/<slug>.md`.

## Step 0 — Hard gates (all non-negotiable)

1. **Plan gate**: `docs/plans/<slug>.plan.md` exists and the user approved it. Missing/unapproved → stop, send them to `/tandem:plan`.
2. **Clean-tree gate**: `git status --porcelain` must be empty. Dirty → STOP and tell the user; never mix pre-existing changes into a delegated diff.
3. **Branch**: `git checkout -b tandem/<slug>` (skip if already on it).
   - Optional isolation for risky work (`TANDEM_WORKTREE=1`): first ensure `.worktrees/` is ignored in the *user's* project (`grep -qx '.worktrees/' .git/info/exclude 2>/dev/null || echo '.worktrees/' >> .git/info/exclude`), then `git worktree add .worktrees/<slug> -b tandem/<slug>` and run everything below with that directory as cwd.

## Step 1 — Delegate to Codex

For critical work (auth, migrations, concurrency, payments, tenant isolation) prefix the command with `TANDEM_CRITICAL=1` to raise Sol's reasoning effort from high to xhigh.

```bash
bash "$SCRIPTS/codex-start.sh" implement docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/implement.tpl"
```

Run with Bash `run_in_background: true` for any real feature (implementation regularly exceeds the 10-minute foreground cap); use foreground with `timeout: 600000` only for small plans. When a background run finishes, announce it clearly before doing anything else.

Exit 2 → a thread already exists for this plan: resume with `continue.tpl` (new scope) or reset first if starting the implementation over.

## Step 2 — Parse the report

The reply ends with `IMPLEMENTATION_COMPLETE` or `IMPLEMENTATION_PARTIAL`.
- Neither sentinel present → resume the SAME thread asking only for the missing status line plus the final report; if it happens twice, treat it as PARTIAL and log the anomaly.
- PARTIAL → read the report; either resume the SAME thread with `continue.tpl` describing what remains (max `$TANDEM_IMPL_ROUNDS` or 2 continuations), or take over and finish it yourself. Log the takeover.
- **`TANDEM_AUTONOMOUS=1`**: still PARTIAL after the continuation cap → take over yourself ONLY if what remains is small and squarely inside the plan; otherwise this is a terminal PARTIAL — report what was done vs. what remains and stop. Never proceed to review with a knowingly incomplete implementation, and never widen scope to force completeness.

```bash
bash "$SCRIPTS/codex-resume.sh" implement docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/continue.tpl" \
  .tandem/tmp/<slug>-continue.md
```

(the 4th arg fills `{{EXTRA}}` with your fix/scope list)

## Step 3 — Your verification (never delegated)

1. `git status -s` and read the **full diff** (`git diff`), like reviewing a contributor's PR: fidelity to the plan, unplanned deviations, plan checkboxes actually done. `git diff` does not show untracked files — Read every `??` entry in full; new files are usually the bulk of the change.
2. Fix small issues DIRECTLY yourself — ping-ponging trivia through delegation burns more than it saves. Large deviations → one resume with `continue.tpl`, then take over if still wrong.
3. Append to the log: files changed, deviations, your assessment.

## Step 4 — Testing gate (blocking)

Run yourself — Codex's pasted output never counts as proof:
1. Lint and typecheck (project's commands).
2. The plan's PROOF command and affected tests.
3. Add independent test cases where you see gaps the plan missed.

All green → write the gate summary line to the log: `gate — lint: OK · typecheck: OK · tests: N passed, M added · proof: OK`. Anything red → fix (yourself or Step 2) and re-run. The gate must pass before review.

## Step 5 — Handoff

Do NOT commit. Tell the user the implementation is verified and continue to `/tandem:review <slug>` (mandatory in the full pipeline; the user may explicitly skip it for low-risk work — except in autonomous mode, where the review phase is never skippable).
