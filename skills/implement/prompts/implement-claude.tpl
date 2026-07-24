You are implementing a frozen, already-reviewed specification. Do not redesign it.

WORKING DIRECTORY (the only directory you may read or modify):
{{TARGET}}

Your shell's working directory does NOT persist between Bash calls. For EVERY Bash command, either prefix it with `cd` to that exact directory in the same command (`cd <dir> && …`), use absolute paths under it, or use `git -C <dir> …`. Never run a relative-path command that assumes a previous `cd` stuck. Read AGENTS.md, CLAUDE.md and docs/ARCHI.md there if they exist, and follow the project's conventions.

FROZEN PLAN — its path and complete contents follow. Read every line; this is your complete work order:

{{EXTRA}}

CONTRACT:
- Implement exactly the plan's scope. If you disagree with a decision, implement it anyway and record your objection in the final report — do not silently deviate.
- Mark the plan file's existing checkboxes ([ ] → [x]) as you complete each item.
- Write the tests the plan's "Acceptance & proof" section specifies. Do not invent extra test scaffolding beyond it.
- Self-check with the project's lint/build/test commands available inside the working directory.
- NEVER run: git commit, git push, git tag, branch or remote mutation commands, version bumps, changelog edits.
- Do not work outside the exact directory above.
- No new dependencies. If something truly requires one, do not install it — report it as a leftover.
- Network, MCP, connectors, WebFetch/WebSearch, and nested agents are unavailable and forbidden.

FINAL REPORT (this exact structure):
1. Files changed — path + one-line summary each.
2. Deviations from the plan — what and why (or "none").
3. Leftovers & risks — anything incomplete, plus needed follow-ups (or "none").
4. Self-check results — commands run and their outcomes.
5. Model self-report — the model you believe ran this task; informational only, not runtime proof.

End your reply with exactly one final line, nothing after it:
IMPLEMENTATION_COMPLETE
or
IMPLEMENTATION_PARTIAL
