---
name: ask
description: Get a grounded second opinion from GPT-5.6 Sol (via Codex, read-only) on architecture, debugging hypotheses, tradeoffs or research — consultative, never a gate. Follow-ups continue the same thread per topic. Use for "what would Sol say about X", red-teaming a decision, or a debugging second opinion. NOT for reviewing plans or diffs (use tandem:plan / tandem:review).
argument-hint: "[topic-label] [question]"
---

# tandem:ask — segunda opinión

Sol answers from inside the repository (read-only). Its opinion is **advisory**: disagreement between you and Sol is the valuable signal — show it to the user verbatim, never resolve it silently, and never treat the answer as an approval of anything.

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`.

## Usage

`topic-label` is a short kebab-case key (e.g. `auth-strategy`, `flaky-upload-test`). One thread per topic; reuse the label to continue the conversation with full memory.

**New topic** — write the question (plus your own current position, if red-teaming) to `.tandem/tmp/<topic>-q.md`, then (Bash timeout: 600000):

```bash
bash "$SCRIPTS/codex-start.sh" ask <topic-label> \
  "${CLAUDE_SKILL_DIR}/prompts/ask.tpl" \
  .tandem/tmp/<topic>-q.md
```

Exit 2 → the topic already has a thread; use the follow-up form below (or reset if it is genuinely a new subject under an old name).

**Transport (opt-in).** The default is `codex exec` and nothing about the commands below changes. Setting `TANDEM_TRANSPORT=mcp` routes the *new-topic* turn through `codex mcp-server` instead, with identical artefacts, `USAGE:` line and exit codes; follow-ups always continue through `codex exec resume`, because a thread does not survive the server that created it. The transport serves the roles `ask` and `review` (the review skill documents its own background rule); any other value, or `mcp` on any other role, is a usage error (64).

**Follow-up** — write it to `.tandem/tmp/<topic>-q.md` and (Bash timeout: 600000):

```bash
bash "$SCRIPTS/codex-resume.sh" ask <topic-label> \
  "${CLAUDE_SKILL_DIR}/prompts/followup.tpl" \
  .tandem/tmp/<topic>-q.md
```

## After each reply

Relay Sol's "Bottom line" and reasoning to the user, and state clearly where you agree and where you differ, with your reasons. Do not gate any workflow on this answer.
