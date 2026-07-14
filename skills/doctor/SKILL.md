---
name: doctor
description: Diagnose the tandem toolchain - Codex CLI installation and login, jq, git, and the resolved model policy. Use before the first tandem run in a project, or whenever a tandem script fails with a dependency error (exit code 3).
---

# tandem:doctor

Run:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/codex-doctor.sh"
```

Interpret the output for the user. Common repairs:

| Problem | Fix |
| --- | --- |
| codex not found / cannot run | `npm install -g @openai/codex@latest` |
| not logged in | `codex login` (browser) or `codex login --device-auth` (headless) — suggest the user run it via `! codex login` |
| jq missing | `brew install jq` (macOS) |

After a repair, re-run the script to confirm everything is green. If the user wants different models or efforts, explain the env overrides shown in the output (`TANDEM_REVIEW_MODEL`, `TANDEM_REVIEW_EFFORT`, `TANDEM_IMPLEMENT_MODEL`, `TANDEM_IMPLEMENT_EFFORT`, `TANDEM_CRITICAL`) — sandboxes are pinned by design and cannot be overridden.
