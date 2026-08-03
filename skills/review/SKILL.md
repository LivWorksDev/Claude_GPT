---
name: review
description: Independent code review by a FRESH GPT-5.6 Sol thread (read-only) that has no memory of the plan debate or the implementation. Pipeline mode reviews the uncommitted diff after tandem:implement and before committing, with a human gate and a commit; range mode (a label plus --range A..B) reviews an ALREADY-COMMITTED range out of the pipeline and produces only a verdict and findings, never a commit. NOT for reviewing plans (use tandem:plan).
argument-hint: "[slug of the implemented plan] | [<label> --range A..B]"
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

Run it with Bash `run_in_background: true` by default for any real diff: a review at `xhigh` effort regularly exceeds the 10-minute foreground cap, which is a hard ceiling of the Bash tool and not a parameter you can raise, so a foreground turn dies mid-flight with the quota already spent and nothing to show for it. Use foreground with `timeout: 600000` only for small diffs. When a background run finishes, announce it clearly before doing anything else.

**Transport (opt-in) — `TANDEM_TRANSPORT=mcp`.** The default is `codex exec` and nothing about the command above changes. With the variable set, this START turn is routed through `codex mcp-server`, with identical artefacts, `USAGE:` line, heartbeat, exit codes and guards; the transport serves every role — `review` only for its pipeline targets `cr-*`/`range-review-*` — and any other value, or an unknown role, is a usage error (64). Under `mcp` this launch is `run_in_background: true` ALWAYS — the small-diff exception above does not apply: the review watchdog defaults to 3600s, well over the foreground cap, so a foreground start would be killed by the Bash tool before the watchdog could classify the hang, reap the server group and account the turn, and the turn would be lost with its quota already spent. If you insist on the foreground, lower `TANDEM_MCP_TIMEOUT_SECONDS` below that cap first. The resume of Step 3.3 is unaffected: a continuation always runs through `codex exec resume` (a thread does not survive the server that created it), so it keeps the criterion stated there.

**The task-completion notification of that Bash run is a hard synchronization barrier.** Nothing happens before it arrives: you do not read the `VERDICT:` line, you do not copy the `USAGE:` line into the log — never a premature `tokens: n/a` out of impatience, the line is simply not there yet — and you launch no resume and no nudge. The thread is not even persisted before that point, and a concurrent resume over a live turn is exactly the class of corruption this barrier exists to forbid.

`TANDEM_CODEX_CWD` starts the reviewer inside `$WORK_ROOT`, so the diff it reads is the one you are reviewing. If Codex's sandbox cannot run `git diff`, re-run passing the diff inline: append `git -C "$WORK_ROOT" diff` to the context file under a `DIFF:` heading.

## Step 3 — Loop (max $TANDEM_CR_ROUNDS or 3)

**Token accounting — every round, unconditionally, before reading the `VERDICT:` line.** Every Codex turn of this skill (Step 2's launch and each round's resume) prints exactly one `USAGE: {…}` line on stderr, absent only when the stream carried no `turn.completed`. Copy it into that round's line of `.tandem/log/<slug>.md` — `## Round <n> — code review · tokens: in <input_tokens> · out <output_tokens>`, or `tokens: n/a` when the line is absent — **before** you branch on the verdict. An APPROVED-at-the-first-attempt review costs quota exactly like a REQUEST_CHANGES one, so its round line is written too.

Read the final `VERDICT:` line:

- No `VERDICT:` line at all → resume the SAME thread asking only for the missing verdict line, with the dedicated nudge template and a cheap effort for that single invocation; this counts as a round. If it happens twice, treat the reply as REQUEST_CHANGES and note the anomaly in the log.

```bash
TANDEM_TURN_EFFORT=low TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" review cr-<slug> \
  "${CLAUDE_SKILL_DIR}/prompts/nudge.tpl"
```

Run this one in the foreground — a one-line turn at `low` effort returns in seconds, so the background criterion above does not apply to it. The worktree pin is not optional here — a nudge is still a turn on this thread and must run in `$WORK_ROOT` like every other launch of this skill. `TANDEM_TURN_EFFORT` is ephemeral and applies to that one invocation only (only the resume wrapper reads it, nothing is exported, the sandbox is untouched, and the real review turns keep the role's `xhigh`).
- `VERDICT: APPROVED` → go to Step 4.
- `VERDICT: REQUEST_CHANGES` → arbitrate each finding by severity (Critical/Major must be fixed or explicitly rebutted with evidence; Minor/Suggestion at your judgment):
  1. Apply fixes yourself — every file by absolute `$WORK_ROOT/...` path — or resume the *implement* thread for large ones (that resume also carries `TANDEM_CODEX_CWD="$WORK_ROOT"`). Re-run the testing gate after any fix, `cd "$WORK_ROOT" && …`.
  2. Log the round's findings + dispositions in `.tandem/log/<slug>.md`, BENEATH the round heading the accounting step already wrote — never a second `## Round <n>` heading (one token-bearing entry per round); write dispositions to `.tandem/tmp/<slug>-cr-dispositions.md`. If Step 2 needed the inline-DIFF fallback, append the UPDATED diff (`git -C "$WORK_ROOT" diff`) under a `DIFF:` heading at the end of that same dispositions file — otherwise the reviewer cannot see your fixes.
  3. Resume the SAME reviewer thread — Bash `run_in_background: true` by default for any real diff, foreground with `timeout: 600000` only for small diffs, exactly as in Step 2. The same hard barrier applies: no `VERDICT:`, no `USAGE:` line in the log and no further turn before the task-completion notification arrives; when the background run finishes, announce it clearly before doing anything else.

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

Only after explicit approval: **you** write the commit (never Codex, never before approval), and you write it as `git -C "$WORK_ROOT" add …` + `git -C "$WORK_ROOT" commit …` — with a worktree, `tandem/<slug>` is checked out there and only there.

**Terminal record of the run — immediately after that commit lands.** Append one machine-parseable line to `.tandem/log/<slug>.md`: `final — commit: <sha completo>`, the full sha of the approval commit (`git -C "$WORK_ROOT" rev-parse HEAD`), and include it in the summary you present. It is the only durable, parseable proof that the run closed: the branch is not evidence forever — a legitimate merge deletes it — and without this line a later reader cannot tell an approved, committed run from an implementation that committed on its own, which this flow treats as a hard safety failure.

Then offer next steps: merge/PR per the project's own conventions — tandem deliberately does not impose a release process.

## Range mode (out of pipeline)

Everything above is the PIPELINE review: an uncommitted diff, a testing gate, a human gate and a commit. This section is the OTHER mode of this skill and it is deliberately outside that pipeline. The user asks for Sol's verdict on work that is ALREADY committed — a branch, a PR, a merge, a slice of history — and the answer is a verdict plus findings, nothing else. No working tree is touched and nothing is ever committed as a result: there is **no Step 4** here (no human gate to commit, no commit, no terminal run record) and **no fix loop** (no Step 3.1, no testing gate — there is no working tree to fix). Steps 0 and 1 do not apply either: the working root and the thread target both come from the helper below.

Entry: `/tandem:review <label> --range A..B` (three-dot `A...B` works too — the diff against the merge base). `<label>` names THIS review, it is not a plan slug: a range usually has no plan, and that is not a defect.

### Range step 1 — resolve the range, build the context

```bash
bash "$SCRIPTS/review-range.sh" <label> "A..B"
```

It validates the label and the range shape (exactly one `..`/`...` separator; empty, control-character or option-shaped endpoints are refused → exit 64), resolves BOTH endpoints to full shas and rebuilds the specification from them (an unresolvable endpoint → exit 65, with git's own message), bootstraps `.tandem/` when the project has none, and writes the context: resolved endpoints, commit list, stat, the mandatory rule that every file read is anchored at B, and the complete diff inline under a `DIFF:` heading. An empty range exits 2 — nothing to review, and no turn was spent. **Any non-zero exit is a STOP**: report it and stop, nothing has been launched yet.

Then read its stdout and use those five lines verbatim: `TARGET:` (always `range-review-<label>`), `CONTEXT_FILE:`, `LOG_FILE:` (this range's own log, under `.tandem/log/ranges/`), `ENDPOINTS:` (both full shas — put them in the log line so the review is reproducible) and `WORK_ROOT:`. This mode never runs Step 0, so `$WORK_ROOT` is that line and nothing else.

The whole diff travels inline, so a huge range makes a huge context. There is no hard limit in this version: prefer bounded ranges, and split a very large one into several labelled reviews rather than one that will not fit.

### Range step 2 — launch the reviewer

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$WORK_ROOT}" TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-start.sh" review range-review-<label> \
  "${CLAUDE_SKILL_DIR}/prompts/start-range.tpl" \
  <CONTEXT_FILE>
```

The launch mechanics are the pipeline's, reused verbatim. The `CLAUDE_PROJECT_DIR` pin is range-specific and NOT optional: the wrappers anchor the thread state to that variable, falling back to the shell's own working directory, while the helper anchored the context and the log to `WORK_ROOT` — from a subdirectory or a linked worktree, an unpinned launch would split the thread from its context and log, and a later invocation could start a FRESH thread for the same label, silently breaking the lineage rule below. Every launch of this mode carries it, the nudge included. Run it with Bash `run_in_background: true` by default for any real diff: a review at `xhigh` effort regularly exceeds the 10-minute foreground cap, which is a hard ceiling of the Bash tool and not a parameter you can raise, so a foreground turn dies mid-flight with the quota already spent. Use foreground with `timeout: 600000` only for small diffs. When a background run finishes, announce it clearly before doing anything else. **The task-completion notification of that Bash run is the same hard synchronization barrier**: before it arrives you do not read the `VERDICT:` line, you do not copy the `USAGE:` line into the log, and you launch no resume and no nudge.

**Transport (opt-in) — `TANDEM_TRANSPORT=mcp`.** The default is `codex exec` and nothing about the command above changes. With the variable set, this START turn is routed through `codex mcp-server`, with identical artefacts, `USAGE:` line, heartbeat, exit codes and guards; the transport serves every role — `review` only for its pipeline targets `cr-*`/`range-review-*` — and any other value, or an unknown role, is a usage error (64). Under `mcp` this launch is `run_in_background: true` ALWAYS — the small-diff exception above does not apply: the review watchdog defaults to 3600s, well over the foreground cap, so a foreground start would be killed by the Bash tool before the watchdog could classify the hang, reap the server group and account the turn, and the turn would be lost with its quota already spent. If you insist on the foreground, lower `TANDEM_MCP_TIMEOUT_SECONDS` below that cap first. The resume of Range step 4 is unaffected: a continuation always runs through `codex exec resume` (a thread does not survive the server that created it), so it keeps the criterion stated there.

**Token accounting — every turn of this mode, unconditionally, before reading the `VERDICT:` line.** Each turn here (this launch, each re-review resume, the nudge) prints exactly one `USAGE: {…}` line on stderr. Copy it into that turn's line of the range log — `## Round <n> — range review · tokens: in <input_tokens> · out <output_tokens>`, or `tokens: n/a` when the line is absent — **before** you branch on the verdict. An APPROVED-at-the-first-attempt range review costs quota exactly like a REQUEST_CHANGES one.

### Range step 3 — the verdict, and where it ends

This is the part that is NOT the pipeline's. Read the final `VERDICT:` line and apply this table:

| Reply | What you do |
| --- | --- |
| `VERDICT: APPROVED` | Report the verdict, the findings-free summary and the token total to the user, and FIN. |
| `VERDICT: REQUEST_CHANGES` | The findings ARE the deliverable: report them in full, with severities and evidence, and FIN. You do not fix anything, you do not resume the implementer, you do not re-run any gate. |
| No `VERDICT:` line | One single nudge, the existing mechanism (below). It counts as a round and its `USAGE:` line is accounted like any other. |
| The nudge also comes back with no `VERDICT:` | The invocation ends as REQUEST_CHANGES with the anomaly recorded in the range log, and the `USAGE:` lines of BOTH turns accounted. Never a second nudge, never an ending without a terminal state. |

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$WORK_ROOT}" TANDEM_TURN_EFFORT=low TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" review range-review-<label> \
  "${CLAUDE_SKILL_DIR}/prompts/nudge.tpl"
```

Run this one in the foreground — a one-line turn at `low` effort returns in seconds. The working-root pin is not optional: a nudge is still a turn on this thread.

Whatever the verdict, the invocation ENDS there. `TANDEM_PROMOTE_REVIEWS` does not apply in this mode: without a Step 4 there is no versioned record to write, so a run with promotion enabled must not wait for one. What survives is the range log the helper pointed you at, and the report you give the user.

### Range step 4 — re-review after the user lands more commits

The one supported way to re-review is a NEW invocation of the helper with the SAME label over the updated range, whose fresh context is then handed to the SAME thread as notes — the reviewer still remembers its own findings:

```bash
bash "$SCRIPTS/review-range.sh" <label> "A..B-updated"
```

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$WORK_ROOT}" TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" review range-review-<label> \
  "${CLAUDE_SKILL_DIR}/prompts/resume-range.tpl" \
  "" <CONTEXT_FILE>
```

Same rules as the launch: Bash `run_in_background: true` by default for any real diff, foreground with `timeout: 600000` only for small diffs; the same hard barrier applies — no `VERDICT:`, no `USAGE:` line in the log and no further turn before the task-completion notification arrives; when the background run finishes, announce it clearly before doing anything else. Then Range step 3 again, unchanged.

**Lineage rule — the same label is the same review lineage.** Reusing a label means "the same work, updated in answer to the findings of THAT thread". An UNRELATED range under a reused label would inherit another review's findings and destroy the independence this skill exists for: use a NEW label for unrelated work, or reset `range-review-<label>` explicitly first (the same reset script Step 1 uses, with this target). Mechanically you cannot miss it — an existing thread for this label is resumed, not restarted.
