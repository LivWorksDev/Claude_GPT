---
name: run
description: Run the full tandem pipeline for a feature - plan with adversarial Sol review, human gate, Opus 5 implementation by default (Sol optional), personal verification and testing gate, independent Sol code review, human gate, commit. With TANDEM_AUTONOMOUS=1, runs end-to-end unattended - human gates become machine-checkable policy (APPROVED verdicts + green testing gate) and the result is a committed tandem branch plus a final report. Use for any non-trivial feature when the user wants the complete adversarial workflow. NOT for trivial changes and NOT for partial phases (invoke tandem:plan / tandem:implement / tandem:review directly instead).
argument-hint: "[feature description]"
---

# tandem:run — pipeline completo

Execute the phases below in order by invoking the sibling skills with the Skill tool. One `<slug>` for the whole run; carry it through every phase.

```
plan (Sol red-team) → HUMAN GATE → implement (Opus 5 default; Sol optional)
    + your verification
    → review (fresh Sol) → HUMAN GATE → you commit
```

1. **Preflight** — invoke `tandem:doctor`. Broken toolchain → stop and help the user fix it first.
2. **Plan** — invoke `tandem:plan` with the feature description. Ends with a human gate; without explicit approval, stop here.
3. **Implement** — invoke `tandem:implement` with the slug. Includes your diff verification and the blocking testing gate.
4. **Review** — invoke `tandem:review` with the slug. Fresh Sol thread; ends with the human diff gate and, on approval, your commit.

Risk calibration (recommend to the user, they decide):
- Trivial change → skip tandem entirely; just do it.
- Normal feature → this full pipeline with defaults (Opus 5 implements; fresh Sol reviews).
- Need the previous Codex CLI implementation transport → `TANDEM_IMPLEMENTER=sol` (Sol implements at effort high).
- Auth / migrations / payments / multi-tenancy / concurrency → `TANDEM_CRITICAL=1` and never skip the review phase. With the default Opus transport, Agent exposes no effort control, so the flag does not alter implementation effort; with `TANDEM_IMPLEMENTER=sol`, it raises Sol to xhigh.

Rules that hold across all phases: deadlock is presented, never papered over; the implementer never commits; nothing is committed without the user's explicit approval (in autonomous mode that approval is delegated to the policies below, and commits still land only on the tandem branch); every phase appends to `.tandem/log/<slug>.md`.

## Autonomous mode — `TANDEM_AUTONOMOUS=1`

End-to-end without mid-run interaction. HITL moves to the edges: a complete brief at t=0, and the human reviews the committed branch afterwards. Autonomy repositions the approval points — it never buys extra permissions.

**Preflight (fail fast, BEFORE any model delegation):**
1. **Brief completeness** — the feature description must let you fill goal, constraints, acceptance and out-of-scope without asking. Too thin → stop and request a complete brief. This is the only permitted interaction, and it happens before the run starts.
2. **`TANDEM_PROMOTE_REVIEWS` must be set** (`0` or `1`) — nothing may ask mid-run. Unset → stop at preflight.
3. Doctor + clean tree, as always. Doctor rejects unknown `TANDEM_IMPLEMENTER` values; `tandem:implement` also fails closed before touching anything.

**Policy replacing each human gate** (details live in the phase skills):
- Plan gate → plan auto-committed ONLY on `VERDICT: APPROVED`, and ONLY on `tandem/<slug>` (via `scripts/plan-approve.sh`, which creates that branch at the approval): the user's branch receives no commit at any point of the run.
- Final gate → auto-commit on `tandem/<slug>` ONLY on review `APPROVED` + green testing gate. The review phase is never skippable in autonomous mode.

**Red lines (identical to interactive mode):** never push, never merge, never touch the default branch; sandboxes, models and round caps unchanged; deadlock is terminal — an APPROVED that never arrived is never synthesized, overridden or "approved by exhaustion".

**Terminal states** — every autonomous run ends in exactly one, with a final report (assumptions applied, verdict + rounds per phase, diffstat, testing-gate summary, branch name, log path):
- `COMPLETED` — committed on `tandem/<slug>`, ready for human review and merge.
- `DEADLOCK` — plan or review never reached APPROVED (including NEEDS_REWORK); nothing committed beyond an already-approved plan, and that one lives on `tandem/<slug>`; main is left intact.
- `PARTIAL` — implementation incomplete after the continuation cap; nothing committed.
- `FAILED` — toolchain or selected-transport error; state preserved.

Any non-COMPLETED outcome is resumable with the normal interactive skills — the state in `.tandem/` is the same.
