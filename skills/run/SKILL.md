---
name: run
description: Run the full tandem pipeline for a feature - plan with adversarial Sol review, human gate, Codex implementation, personal verification and testing gate, independent Sol code review, human gate, commit. Use for any non-trivial feature when the user wants the complete adversarial workflow. NOT for trivial changes and NOT for partial phases (invoke tandem:plan / tandem:implement / tandem:review directly instead).
argument-hint: "[feature description]"
---

# tandem:run — pipeline completo

Execute the phases below in order by invoking the sibling skills with the Skill tool. One `<slug>` for the whole run; carry it through every phase.

```
plan (Sol red-team) → HUMAN GATE → implement (Sol) + your verification
    → review (fresh Sol) → HUMAN GATE → you commit
```

1. **Preflight** — invoke `tandem:doctor`. Broken toolchain → stop and help the user fix it first.
2. **Plan** — invoke `tandem:plan` with the feature description. Ends with a human gate; without explicit approval, stop here.
3. **Implement** — invoke `tandem:implement` with the slug. Includes your diff verification and the blocking testing gate.
4. **Review** — invoke `tandem:review` with the slug. Fresh Sol thread; ends with the human diff gate and, on approval, your commit.

Risk calibration (recommend to the user, they decide):
- Trivial change → skip tandem entirely; just do it.
- Normal feature → this full pipeline with defaults (Sol implements at effort high).
- Auth / migrations / payments / multi-tenancy / concurrency → `TANDEM_CRITICAL=1` (raises implementation effort to xhigh) and never skip the review phase.

Rules that hold across all phases: deadlock is presented, never papered over; Codex never commits; nothing is committed without the user's explicit approval; every phase appends to `.tandem/log/<slug>.md`.
