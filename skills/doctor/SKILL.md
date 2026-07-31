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
| `CLAUDE_CODE_SUBAGENT_MODEL` is defined and is not exactly `opus` | it takes precedence over the implementer subagent's `model: opus`, so `tandem:implement`'s preflight would stop the run: unset it, set it to `opus`, or run with `TANDEM_IMPLEMENTER=sol` |

After a repair, re-run the script to confirm everything is green. If the user wants different models or efforts, explain the env overrides shown in the output (`TANDEM_REVIEW_MODEL`, `TANDEM_REVIEW_EFFORT`, `TANDEM_IMPLEMENT_MODEL`, `TANDEM_IMPLEMENT_EFFORT`, `TANDEM_CRITICAL`) — sandboxes are pinned by design and cannot be overridden.

## Model smoke (`--smoke`) — costs real turns

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/codex-doctor.sh" --smoke
```

Everything above is free. `--smoke` is not: it additionally spends **one real Codex turn per unique configured model** (two with the default policy: `gpt-5.6-sol` and `gpt-5.6-luna`) asking each one to reply `OK`, and reports per model whether it still answers — distinguishing "the CLI/API rejected the model name" (renamed, retired, not enabled for this account) from auth/network/quota failures, with the stderr shown. A failure of one model never stops the others, and a hung turn is cut by a watchdog (120 s by default, `TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS` to change it).

**Never run it without the user asking for it**, and say what it costs before you do. It never runs as part of the plain diagnosis. Each turn is `--ephemeral` in a private temp directory with no web search and no repository access, and leaves nothing under `.tandem/`. Use it when a run failed with a model error, after a Codex CLI upgrade, or before a long run on a machine whose overrides (`TANDEM_*_MODEL`) are custom.
