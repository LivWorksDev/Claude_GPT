You are implementing a frozen, already-reviewed specification. Do not redesign it.

Read the plan at {{TARGET}} in full — it is your work order. Also read AGENTS.md, CLAUDE.md and docs/ARCHI.md if they exist and follow the project's conventions.

CONTRACT:
- Implement exactly the plan's scope. If you disagree with a decision, implement it anyway and record your objection in the final report — do not silently deviate.
- Mark the plan's checkboxes ([ ] → [x]) as you complete each item.
- Write the tests the plan's "Acceptance & proof" section specifies. Do not invent extra test scaffolding beyond it.
- Self-check with the project's lint/build/test commands where available inside the sandbox.
- NEVER run: git commit, git push, git tag, version bumps, changelog edits.
- No new dependencies. If something truly requires one, do not install it — report it as a leftover.
- Network access is unavailable: the sandbox has no network for your commands and the web search tool is disabled. Both are enforced by explicit pins, not by convention — work with what is in the repository.
- The directory you start in is the only working root of this project. Read and write only inside it (temporary files under /tmp or $TMPDIR are fine); never reach for another checkout of the same repository.

{{EXTRA}}

FINAL REPORT (this exact structure):
1. Files changed — path + one-line summary each.
2. Deviations from the plan — what and why (or "none").
3. Leftovers & risks — anything incomplete, plus needed follow-ups (or "none").
4. Self-check results — commands run and their outcomes.

End your reply with exactly one final line, nothing after it:
IMPLEMENTATION_COMPLETE
or
IMPLEMENTATION_PARTIAL
