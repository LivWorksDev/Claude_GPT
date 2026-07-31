---
name: review
description: Independent final code review of the uncommitted diff by a FRESH GPT-5.6 Sol thread (read-only) that has no memory of the plan debate or the implementation. Use after tandem:implement and before committing. NOT for reviewing plans (use tandem:plan) and NOT for already-committed code.
argument-hint: "[slug of the implemented plan]"
---

# tandem:review — revisor final independiente

The final reviewer must arrive with **zero context contamination**: a brand-new Sol thread that never saw the plan debate or the implementation thread. You arbitrate its findings; the user approves the final diff; only then do YOU commit (Codex never commits).

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`. Log: `.tandem/log/<slug>.md`.
State key for this skill: `cr-<slug>` (distinct from the plan-review thread, which uses the plan path).

## Step 0 — Working root, then input gates

Resolve the working root **first**, before any gate: with `TANDEM_WORKTREE=1` the implementation lives in a linked worktree and `tandem/<slug>` is checked out only there, so an unqualified `git status`, an unqualified fix or — worst of all — an unqualified `git commit` in Step 4 would operate on the wrong tree.

```bash
WORK_ROOT="$(bash "$SCRIPTS/worktree-root.sh" <slug>)"
```

It prints the main checkout when `TANDEM_WORKTREE` is unset (nothing changes), and the absolute path of the worktree registered for `tandem/<slug>` when it is `1`; it fails loudly (exit 65) on zero/several/missing registrations and never falls back to the main checkout. A non-zero exit is a STOP.

**Contract for every step of this skill, 0 through 4** — `$WORK_ROOT` qualifies everything:
- every git command: `git -C "$WORK_ROOT" …`, **including the final commit**;
- every Read/Edit/Write of a project file (the fixes you apply by hand in Step 3, and `docs/reviews/<slug>.md` in Step 4): absolute `$WORK_ROOT/...` paths;
- every non-git command, the re-runs of the testing gate included: `cd "$WORK_ROOT" && …` in the same command;
- every Codex launch: `TANDEM_CODEX_CWD="$WORK_ROOT"`.

`.tandem/` (thread state, log, tmp context files) stays under the main checkout with `CLAUDE_PROJECT_DIR` untouched — that is what keeps the thread alive across a deleted worktree.

Then the input gates:

1. There is an uncommitted diff (`git -C "$WORK_ROOT" status --porcelain` non-empty). Nothing to review → stop.
2. The testing gate summary exists in `.tandem/log/<slug>.md`. Missing → run the gate first (see tandem:implement Step 4).

## Step 1 — Fresh-thread guarantee

If a thread already exists for `cr-<slug>` from a previous attempt of THIS review round-trip, resume it (same reviewer re-checking its own findings is correct). If it belongs to an older, different diff: `bash "$SCRIPTS/codex-reset.sh" review cr-<slug>` first.

## Step 2 — Start the review

Build the context file `.tandem/tmp/<slug>-cr-context.md` containing exactly:
- `Plan: docs/plans/<slug>.plan.md`
- The testing-gate summary line.
- Branch name and base (e.g. `tandem/<slug>` off `main`).
- The changed-file list from `git -C "$WORK_ROOT" status -s`; if any files are untracked (`??`), say so explicitly — they are invisible to `git diff HEAD` and the reviewer must read them directly.

```bash
TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-start.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/start.tpl" \
  .tandem/tmp/<slug>-cr-context.md
```

(Bash timeout: 600000.) `TANDEM_CODEX_CWD` starts the reviewer inside `$WORK_ROOT`, so the diff it reads is the one you are reviewing. If Codex's sandbox cannot run `git diff`, re-run passing the diff inline: append `git -C "$WORK_ROOT" diff` to the context file under a `DIFF:` heading.

## Step 3 — Loop (max $TANDEM_CR_ROUNDS or 3)

**Token accounting — every round, unconditionally, before reading the `VERDICT:` line.** Every Codex turn of this skill (Step 2's launch and each round's resume) prints exactly one `USAGE: {…}` line on stderr, absent only when the stream carried no `turn.completed`. Copy it into that round's line of `.tandem/log/<slug>.md` — `## Round <n> — code review · tokens: in <input_tokens> · out <output_tokens>`, or `tokens: n/a` when the line is absent — **before** you branch on the verdict. An APPROVED-at-the-first-attempt review costs quota exactly like a REQUEST_CHANGES one, so its round line is written too.

Read the final `VERDICT:` line:

- No `VERDICT:` line at all → resume the SAME thread asking only for the missing verdict line, with the dedicated nudge template and a cheap effort for that single invocation; this counts as a round. If it happens twice, treat the reply as REQUEST_CHANGES and note the anomaly in the log.

```bash
TANDEM_TURN_EFFORT=low TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/nudge.tpl"
```

The worktree pin is not optional here — a nudge is still a turn on this thread and must run in `$WORK_ROOT` like every other launch of this skill. `TANDEM_TURN_EFFORT` is ephemeral and applies to that one invocation only (only the resume wrapper reads it, nothing is exported, the sandbox is untouched, and the real review turns keep the role's `xhigh`).
- `VERDICT: APPROVED` → go to Step 4.
- `VERDICT: REQUEST_CHANGES` → arbitrate each finding by severity (Critical/Major must be fixed or explicitly rebutted with evidence; Minor/Suggestion at your judgment):
  1. Apply fixes yourself — every file by absolute `$WORK_ROOT/...` path — or resume the *implement* thread for large ones (that resume also carries `TANDEM_CODEX_CWD="$WORK_ROOT"`). Re-run the testing gate after any fix, `cd "$WORK_ROOT" && …`.
  2. Log the round's findings + dispositions in `.tandem/log/<slug>.md`, BENEATH the round heading the accounting step already wrote — never a second `## Round <n>` heading (one token-bearing entry per round); write dispositions to `.tandem/tmp/<slug>-cr-dispositions.md`. If Step 2 needed the inline-DIFF fallback, append the UPDATED diff (`git -C "$WORK_ROOT" diff`) under a `DIFF:` heading at the end of that same dispositions file — otherwise the reviewer cannot see your fixes.
  3. Resume the SAME reviewer thread (Bash timeout: 600000):

```bash
TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/resume.tpl" \
  "" .tandem/tmp/<slug>-cr-dispositions.md
```

- Cap reached without APPROVED → deadlock protocol: present both positions honestly to the user; never fake convergence. In autonomous mode this is a terminal DEADLOCK: report and stop — nothing gets committed.

## Step 4 — Human gate, then commit

Present: diff summary, gate summary, reviewer verdict, rounds used, this phase's token total (the sum of the per-round `tokens:` lines in the log, in and out), link to the log. Ask the user to approve the diff (AskUserQuestion).

**`TANDEM_AUTONOMOUS=1`**: the gate becomes policy — commit without asking ONLY when the reviewer's verdict is `APPROVED` **and** the testing-gate summary in the log is green (re-run after any fix). `TANDEM_PROMOTE_REVIEWS` was validated as set (0/1) at the run preflight — honor its value, never ask. The commit lands on `tandem/<slug>` and the run ends there: no push, no merge, no PR — those remain human.

**Optional review record** — `.tandem/` is ephemeral and gitignored; this step is the only way the review outcome survives in the repo. Controlled by `TANDEM_PROMOTE_REVIEWS`: `1` = always write it, `0` = never, unset = offer it as part of the approval question. When promoting, write `$WORK_ROOT/docs/reviews/<slug>.md` with: date, plan path, branch, gate summary, plan-review rounds + final verdict, code-review rounds + final verdict, and the condensed findings/dispositions taken from `.tandem/log/<slug>.md`. Never include thread ids (machine-local noise). Include this file in the approval commit.

Only after explicit approval: **you** write the commit (never Codex, never before approval), and you write it as `git -C "$WORK_ROOT" add …` + `git -C "$WORK_ROOT" commit …` — with a worktree, `tandem/<slug>` is checked out there and only there. Then offer next steps: merge/PR per the project's own conventions — tandem deliberately does not impose a release process.
