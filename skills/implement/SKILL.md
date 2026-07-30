---
name: implement
description: Delegate implementation of an approved tandem plan to Claude Opus 5 by default, or to Codex GPT-5.6 Sol with TANDEM_IMPLEMENTER=sol, on a dedicated branch; then personally verify the full diff and run the blocking testing gate. Use after a plan was approved via tandem:plan. NOT for trivial changes (implement those directly) and NOT without an approved plan.
argument-hint: "[slug of the approved plan]"
---

# tandem:implement — implementador seleccionable, tú verificas

You are the orchestrator. Claude Opus 5 implements by default; Sol is the opt-in Codex CLI transport. **You** read the diff, run the tests and own the result. The implementer NEVER commits — and you commit no implementation changes until the user approves the final diff after `/tandem:review` (the plan file itself was already committed at the tandem:plan human gate).

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`. Log: `.tandem/log/<slug>.md`.

## Step 0 — Working root, selector and hard gates (all non-negotiable)

### 0.0 — Working root: which route you are on decides WHEN you resolve it

`WORK_ROOT` is the one variable everything downstream is anchored to, and an unset one
silently means "the main checkout". But the resolver is fail-closed: with
`TANDEM_WORKTREE=1` it exits 65 while the branch or the worktree does not exist yet — which
is precisely the state a fresh attempt starts in. So branch **first**, on the durable
attempt state (gate 4's check, which reads a file and touches nothing):

- **Resume or recovery** (durable state exists and its identity matches) — the worktree
  already exists, so resolve **now, before the gates**, and use `$WORK_ROOT` for gate 4's
  dirty-path check and everything after:

  ```bash
  WORK_ROOT="$(bash "$SCRIPTS/worktree-root.sh" <slug>)"
  ```

- **Fresh attempt** (no state, or state discarded via the reset protocol) — the gates below
  run against the **main checkout** (that is what the clean-tree gate is about), gate 6
  creates the branch and, under `TANDEM_WORKTREE=1`, the worktree; resolve **immediately
  after gate 6**, before Step 1 delegates anything.

Never call the resolver before the worktree exists and never continue past a non-zero exit:
it is a STOP, not a reason to guess a path.

`worktree-root.sh` prints the main checkout when `TANDEM_WORKTREE` is unset (the default:
nothing changes), and the absolute path of the worktree **registered** for `tandem/<slug>`
when it is `1` — read from `git worktree list`, not from the `.worktrees/<slug>`
convention, so a worktree you reused elsewhere still resolves. Zero matches, several
matches, or a registered path missing from disk are hard errors (exit 65): it never falls
back to the main checkout, because a silent fallback is exactly how work lands in the wrong
tree.

Once resolved, **everything** is anchored to `$WORK_ROOT`: `git -C "$WORK_ROOT" …` for every
git command, absolute `$WORK_ROOT/...` paths for every Read/Edit/Write of a project file,
`cd "$WORK_ROOT" && …` in the same command for every non-git command including the testing
gate, and `TANDEM_CODEX_CWD="$WORK_ROOT"` on every Codex launch. The implementer prompt
names that path as the **only** working directory. Do not assume a subagent — or your own
shell — inherits the right cwd between calls.

`TANDEM_WORKTREE` is **implement/review-only**. `tandem:ask` and `tandem:image` are never
anchored to a worktree: expect no isolation there.

### 0.1 onwards — the gates

1. **Selector, before touching anything**: read `TANDEM_IMPLEMENTER`, defaulting to the exact value `opus` **only when the variable is unset**. The only valid values are `opus` and `sol`; a set-but-empty value is invalid like any other unknown value. Any invalid value is a hard error: report `TANDEM_IMPLEMENTER=<value> is invalid; expected opus or sol` and STOP. Never silently fall back.
2. **Opus model preflight, also before touching anything**: when the selector is `opus`, if `CLAUDE_CODE_SUBAGENT_MODEL` is defined and its exact value is not `opus`, STOP. That environment variable takes precedence over the agent type's `model: opus`, so continuing would violate the selected transport. There is no reliable in-agent runtime model verification; the report's model field is an informative self-attestation only.
3. **Plan gate**: `docs/plans/<slug>.plan.md` exists and the user approved it. Missing/unapproved → stop, send them to `/tandem:plan`.
4. **Attempt-state gate, BEFORE the clean-tree gate**: check for durable state (`.tandem/state/implement-claude/<slug>.json` for `opus`; the thread state key for `sol`). A matching in-progress attempt (identity rules in Step 1) is a **resume**: its uncommitted implementation work is expected, so the clean-tree requirement below does not apply — verify instead that the dirty paths plausibly belong to the attempt — `git -C "$WORK_ROOT" status --porcelain`, using the `WORK_ROOT` you resolved in §0.0 on the resume branch — consistent with its last report and the plan's files-to-touch, and continue to Step 2's continuation/recovery flow. Only a fresh attempt (no state, or state discarded via the reset protocol) falls through to the next gate.
5. **Clean-tree gate (fresh attempts only)**: `git status --porcelain` in the **main checkout** must be empty — a fresh attempt has no worktree yet, and this gate exists to keep pre-existing changes out of the delegated diff. Dirty → STOP and tell the user; never mix pre-existing changes into a delegated diff.
6. **Branch — in-place and worktree are mutually exclusive**: record the absolute plan path, `git rev-parse HEAD`, and `git remote -v` for the later safety check — under `opus`, persist these into the durable JSON as `base_head`/`remote_snapshot` the moment the attempt starts (Step 1), so the baseline survives session loss — then:
   - `TANDEM_WORKTREE` unset (default, in-place): `git checkout -b tandem/<slug>` (skip if already on it).
   - `TANDEM_WORKTREE=1`: do **NOT** check the branch out in the main checkout — `git worktree add` refuses a branch that is already checked out. First ensure `.worktrees/` is ignored in the *user's* project (`grep -qx '.worktrees/' .git/info/exclude 2>/dev/null || echo '.worktrees/' >> .git/info/exclude`); then, if `tandem/<slug>` does not exist yet: `git worktree add .worktrees/<slug> -b tandem/<slug>`; if it already exists (resume): `git worktree add .worktrees/<slug> tandem/<slug>`, or reuse the already-registered worktree.

Fresh attempts resolve the working root **here**, now that the branch and (under `TANDEM_WORKTREE=1`) the worktree exist — `WORK_ROOT="$(bash "$SCRIPTS/worktree-root.sh" <slug>)"` — before Step 1 delegates anything. Resumes already resolved it in §0.0.

## Step 1 — Delegate through the selected transport

### Transport `opus` (default)

Use agent type `tandem:implementer` from `agents/implementer.md`. Its harness-enforced tool allowlist is `Read, Edit, Write, Glob, Grep, Bash`: no MCP, WebFetch/WebSearch, or nested Agent. Bash is still a residual risk rather than an OS sandbox, so the prompt and agent definition both prohibit commits, pushes, branch/remote changes, and work outside the named directory.

Read `prompts/implement-claude.tpl` directly and replace its placeholders yourself; do **not** pass it through the Bash `load_prompt` infrastructure:

- `{{TARGET}}` → the absolute working directory (the checkout, or the absolute `.worktrees/<slug>` path).
- `{{EXTRA}}` → a `PLAN PATH: docs/plans/<slug>.plan.md` line followed by the complete approved plan text. On recovery, append the recovery context described below after the complete plan.

Launch `tandem:implementer` with the rendered prompt using the Agent tool and `run_in_background: true` for any real feature. Keep the returned agent name/id. The prompt contains the complete plan, exact work directory, required acceptance tests, report contract, model self-attestation, and final `IMPLEMENTATION_COMPLETE` / `IMPLEMENTATION_PARTIAL` sentinel.

`TANDEM_CRITICAL=1` cannot raise effort for an Agent-tool Opus subagent because Agent exposes no effort control. Under `opus` it therefore does not change implementation effort; it still means that the mandatory review phase may never be omitted. Under `sol` it retains its full behavior below.

#### Durable Opus attempt state

The state mirror is `.tandem/state/implement-claude/<slug>.json`. Reports are `.tandem/state/implement-claude/<slug>.t<N>.report.md`. Fable writes the report and rewrites the JSON after **every** launch and continuation; conversation memory is never the source of truth for round caps.

The JSON records at least:

```json
{
  "agent": {"name": "returned name", "id": "returned id"},
  "task_id": "<background task id of the CURRENT launch/continuation>",
  "status": "running",
  "continuation_rounds": 0,
  "last_sentinel": null,
  "last_report": null,
  "worktree": null,
  "plan_path": "docs/plans/<slug>.plan.md",
  "plan_hash": "<committed blob id>",
  "branch": "tandem/<slug>",
  "base_head": "<git rev-parse HEAD at attempt start>",
  "remote_snapshot": "<git remote -v output at attempt start>"
}
```

`base_head` and `remote_snapshot` are written ONCE when the attempt starts and are immutable for its lifetime: they are the durable safety baseline, so a recovery in a fresh session can still detect an implementer commit or remote mutation without relying on conversation memory.

Write `status: "running"` (with the new `task_id`) **before or immediately upon** every launch and every `SendMessage` continuation, and rewrite it to `"terminal"` together with the sentinel and report path when the turn's result arrives. While `status` is `running`, `last_sentinel` describes a PREVIOUS turn — never treat it as the current turn's outcome.

Compute `plan_hash` only as the committed plan blob:

```bash
git rev-parse HEAD:docs/plans/<slug>.plan.md
```

Never hash the working copy: the implementer marks plan checkboxes, which must not invalidate a legitimate continuation. Attempt identity is the recorded `plan_hash` + `branch`; `plan_path` is also retained for audit.

Before launch, if state already exists:

- Matching identity → resume that attempt, or perform a deliberate reset only if the user explicitly wants to start over. In autonomous mode, resume.
- Mismatched identity → never resume it. The only choices are discard/reset or STOP.
- Exact reset means removing only `<slug>.json` and that slug's `<slug>.t*.report.md`.

Before **any** reset, run the observational liveness guard, keyed on the **recorded `task_id`** — background Agent runs are tracked as background tasks, which is a different namespace from structured task-list entries, so the task id persisted in the JSON is the only reliable key. In order of preference: (1) the JSON already says `status: "terminal"` — the attempt's last turn finished; (2) observe the background task for the recorded `task_id` (its completion notification or output stream) without interacting with the agent; (3) the recorded task/agent belongs to a previous session — subagents and their background tasks do not survive their creating session, so a foreign-session record whose turn result was persisted is inactive. Never use `SendMessage` as a probe: messaging a completed agent starts new background work. Missing or unreadable state is **ambiguous, never "inactive"**. If a worktree is recorded, also require `git -C <worktree> status --porcelain` to be empty. If inactivity cannot be established, do not reset: interactive mode explains the ambiguity and asks; autonomous mode terminates as `FAILED` with state preserved. Autonomous auto-reset is allowed only for mismatch + verified inactive agent + clean recorded worktree, and must be logged. Never launch a second implementer against the same live attempt.

### Transport `sol`

This is the existing Codex CLI flow, unchanged. For critical work (auth, migrations, concurrency, payments, tenant isolation) prefix the command with `TANDEM_CRITICAL=1` to raise Sol's reasoning effort from high to xhigh.

```bash
TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-start.sh" implement docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/implement.tpl"
```

`TANDEM_CODEX_CWD` is what makes the turn run inside the worktree (`codex exec --cd`). It deliberately does **not** move `CLAUDE_PROJECT_DIR`: the thread state and the heartbeat stay under the main checkout, so `codex-show`/`codex-reset` keep working from there and deleting the worktree never destroys the thread. Without `TANDEM_WORKTREE`, `WORK_ROOT` is the main checkout and the command is what it always was.

Run with Bash `run_in_background: true` for any real feature (implementation regularly exceeds the 10-minute foreground cap); use foreground with `timeout: 600000` only for small plans. When a background run finishes, announce it clearly before doing anything else.

Exit 2 → a thread already exists for this plan: resume with `continue.tpl` (new scope) or reset first if starting the implementation over.

## Step 2 — Parse the report

The reply ends with `IMPLEMENTATION_COMPLETE` or `IMPLEMENTATION_PARTIAL`.
- Neither sentinel present → continue the SAME implementer asking only for the missing status line plus the final report; if it happens twice, treat it as PARTIAL and log the anomaly.
- PARTIAL → read the report; either continue the SAME implementer describing what remains (max `$TANDEM_IMPL_ROUNDS` or 2 continuations), or take over and finish it yourself. Log the takeover.
- **`TANDEM_AUTONOMOUS=1`**: still PARTIAL after the continuation cap → take over yourself ONLY if what remains is small and squarely inside the plan; otherwise this is a terminal PARTIAL — report what was done vs. what remains and stop. Never proceed to review with a knowingly incomplete implementation, and never widen scope to force completeness.

For `opus`, use `SendMessage` on the recorded agent id/name for every continuation; never launch a fresh agent while it still exists. Read `continuation_rounds` from the durable JSON, increment it after each PARTIAL continuation, save the new `.t<N>.report.md`, and update the JSON even when the sentinel is missing or the turn fails — including the continuation's new `task_id` with `status: "running"` at send time and `status: "terminal"` when its result arrives. The cap never resets on compaction or a new orchestrator session.

If the recorded Opus agent no longer exists, launch a fresh `tandem:implementer` only as recovery of the same matching attempt. Render the Claude template with the complete plan and a recovery appendix containing: `git -C "$WORK_ROOT" status -s`, the full tracked `git -C "$WORK_ROOT" diff HEAD`, an explicit order to open and read every `??` file in full **by absolute `$WORK_ROOT/...` path** because it is absent from `git diff`, and the pending items from the last persisted report. Unqualified git here would read the main checkout and hand the recovered agent someone else's context. Store the new agent identity without resetting `continuation_rounds`.

For `sol`, continue with the existing command and template, unchanged:

```bash
TANDEM_CODEX_CWD="$WORK_ROOT" bash "$SCRIPTS/codex-resume.sh" implement docs/plans/<slug>.plan.md \
  "${CLAUDE_SKILL_DIR}/prompts/continue.tpl" \
  .tandem/tmp/<slug>-continue.md
```

(the 4th arg fills `{{EXTRA}}` with your fix/scope list)

## Step 3 — Your verification (never delegated)

1. `git -C "$WORK_ROOT" status -s` and read the **full diff** (`git -C "$WORK_ROOT" diff`), like reviewing a contributor's PR: fidelity to the plan, unplanned deviations, plan checkboxes actually done. `git diff` does not show untracked files — Read every `??` entry in full, by absolute `$WORK_ROOT/...` path; new files are usually the bulk of the change.
2. Compare the current branch, `HEAD`, and `git -C "$WORK_ROOT" remote -v` with the attempt's baseline — under `opus`, the durable `base_head`/`remote_snapshot` from the JSON (never conversation memory, so this works after recovery too); under `sol`, the pre-launch snapshot. Any implementer commit, branch change, or remote mutation is a hard safety failure; stop and surface it. This check mitigates the Opus transport's unsandboxed Bash and applies identically to Sol.
3. Fix small issues DIRECTLY yourself — ping-ponging trivia through delegation burns more than it saves. Large deviations → one continuation of the selected transport, then take over if still wrong.
4. Append to the log: transport, files changed, deviations, your assessment. With Opus, note that its status-line second row is intentionally absent in v1; Claude Code's native subagent progress is the progress display.

## Step 4 — Testing gate (blocking)

Run yourself, every command anchored (`cd "$WORK_ROOT" && …` in the same command) — Codex's pasted output never counts as proof:
1. Lint and typecheck (project's commands).
2. The plan's PROOF command and affected tests.
3. Add independent test cases where you see gaps the plan missed.

All green → write the gate summary line to the log: `gate — lint: OK · typecheck: OK · tests: N passed, M added · proof: OK`. Anything red → fix (yourself or Step 2) and re-run. The gate must pass before review.

## Step 5 — Handoff

Do NOT commit. Tell the user the implementation is verified and continue to `/tandem:review <slug>` (mandatory in the full pipeline; the user may explicitly skip it only for low-risk work with `TANDEM_CRITICAL!=1` — in autonomous mode the review phase is never skippable).
