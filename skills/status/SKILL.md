---
name: status
description: Show where a tandem run stands and how it is resumed - phase reached, verdicts and rounds per phase, branch, testing gate, implementation attempt, aggregated tokens and a deterministic next step, read from the state already on disk. Use when the user asks where a run is, what is left, how to resume it, or after a compaction that lost the run's context; with no slug it lists the known runs. NOT for launching or continuing any phase.
argument-hint: "[slug]"
---

# tandem:status — dónde está el run y cómo se retoma

Run it and interpret the report for the user:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/tandem-status.sh" <slug>
```

With no argument it lists every known run instead, one `<slug> — <phase>` line each:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/tandem-status.sh"
```

**This skill is strictly read-only and it never calls Codex.** It reads `.tandem/` and git, writes nothing at all — no state, no heartbeat, not a line in the log — and it never spends a turn: it is free, so it is the right first move after a compaction, at the start of a session, or whenever nobody remembers what a slug was up to. It is the phase-level view of a whole run; the detail of one thread (thread id, turns, last reply) belongs to the show script of the toolchain, which this skill does not replace.

## Reading the report

| Field | What it says |
| --- | --- |
| `plan:` | the plan's working copy, the approval commit and the mode recorded by `scripts/plan-approve.sh`; `aprobación interrumpida (pending)` means an approval died between the commit and its record |
| `rama:` | `tandem/<slug>`, its tip, how many commits sit on top of the plan commit, and the linked worktree when one is registered |
| `plan-review:` / `code-review:` | rounds and the verdict of each round, in order (`—` = that round left no reply) |
| `implement:` | the durable attempt state — `opus · <status> · <sentinel>` or `sol · t<N> · <verdict>`. While the status is `running` the sentinel describes a PREVIOUS turn, never the current one |
| `gate:` | the last testing-gate summary written to the log, normalized to one line |
| `tokens:` | the per-phase sum of the turn ledgers, plus the run's total. `n/a (transporte opus)` where there is no ledger to sum, `(+N ilegible)` when a ledger could not be read |
| `fase:` | the most advanced phase the evidence PROVES |
| `next:` | how the run is resumed from there |

## What each `desconocido` means

Nothing here is ever an error: absent or corrupt state degrades the field that needs it and the report still comes out.

- `desconocido (sin jq)` / `desconocido (sin git)` — the tool is missing from PATH. Everything that does not depend on it is still reported; install it (`brew install jq`) to get the rest.
- `desconocido (estado corrupto)` — the file is there but does not have the shape it should. Say so plainly; do not guess a value from it.
- `contradictorio — …` in `fase:` — the evidence disagrees with itself. Two cases matter: commits on the branch with no terminal record of the run (this flow treats a commit by the implementer as a hard safety failure), and a branch that moved on AFTER the run's final record. Both mean **stop and look by hand**; never present them as a finished run.
- `commit final (no verificado)` — a final record exists but git could not confirm it descends from the plan commit. Verify it by hand (`git log`) before any merge or PR; "run completo" is reserved for a record git verified.

## Exit codes

- `0` — report emitted (a partially `desconocido` report is still a report).
- `2` — that slug has no trace at all: no log, no state, no plan, no branch. The known runs are listed on stderr; the usual cause is a typo in the slug.
- `64` — usage error (an invalid slug, or more than one argument).

There is no other exit code: no hard dependency and no turn to spend.

## The `next:` line

It is a suggestion the script derives from the phase, and it names the skill that continues the run (`/tandem:plan`, `/tandem:implement <slug>`, `/tandem:review <slug>`, or the human gate in between). **Offer it, never run it on your own**: invoking the next phase spends real quota and belongs to the user's decision. When the line starts with `ATENCIÓN`, that is not a next step at all — surface the contradiction first.

## Known limits

- Runs in the `ultra-*` namespace are out of scope: the swarm keeps its own state.
- Under the opus transport there is no token ledger to sum, so that phase reports `n/a (transporte opus)` exactly like the log does.
- The list is built from sources that carry a plain slug (the log, the approval records, the attempt states and the `tandem/*` branches). A run that somehow had a thread and no log at all would not be listed — the log is created in the plan skill's Act 1, so in practice every run that started is there.
