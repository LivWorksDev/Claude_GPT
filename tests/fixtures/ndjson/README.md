# NDJSON fixtures

Event shapes consumed by the two jq filters in the codebase:

- `scripts/_common.sh` → `stream_milestones()` (the shell-panel narration)
- `scripts/statusline.sh` → the live-activity block of line 2

Both read `codex exec --json` output. These files pin the field shapes those
filters depend on, so a filter rewrite that silently stops matching an event is
caught by a test instead of by a user staring at an empty progress panel.

## Origin

Captured against **codex-cli 0.144.4** (the version pinned by the weekly
`codex-smoke` CI job). Regenerate with a real, logged-in CLI:

```sh
cd "$(mktemp -d)" && git init -q .
codex exec --json --skip-git-repo-check --color never \
  --model gpt-5.6-sol --sandbox read-only \
  -c model_reasoning_effort=high \
  --output-last-message /dev/null \
  - <<<'List the files here, then summarise.' > raw.ndjson
```

Then trim `raw.ndjson` to the events of interest and re-check with
`./check-drift.sh raw.ndjson`.

## Validation status

| Fixture | Status |
| --- | --- |
| `happy.ndjson` | validated against the real CLI (0.144.4): `thread.started`, `turn.started`, `item.{started,completed}` for `reasoning` / `command_execution` / `file_change` / `web_search` / `agent_message`, `turn.completed.usage` |
| `multi-thread.ndjson` | **best-effort** — a second `thread.started` in one stream has not been observed in the wild; it exists to pin the "first one wins" contract of `codex-start.sh` and the fallback guard of `codex-resume.sh` |
| `corrupt.ndjson` | best-effort — models a truncated write and the non-JSON preamble the CLI prints on stderr-to-stdout mixups; pins `fromjson?` tolerance |
| `turn-failed.ndjson` | validated shape (`turn.failed.error.message`) |
| `error-event.ndjson` | validated shape (`error.message`) |
| `file-change-4.ndjson` | validated shape; 4 paths exercise the `+N more` branch (`length > 3`) |
| `truncated-head.ndjson` | best-effort — models what `tail -c 100000` produces when it cuts a line in half; the status line must tolerate it |

Fields the fixtures deliberately carry beyond what the filters read
(`id`, `status`, `aggregated_output`, `cached_input_tokens`, `kind`, `query`)
are there so `check-drift.sh` can notice when the real CLI drops or renames
them — a filter that starts depending on one should not be the first to find out.

## Drift

`check-drift.sh <real.ndjson>` compares the `(type, item_type)` pairs and the
key sets of a freshly captured stream against these fixtures and prints what is
new, missing or retyped. The weekly `codex-smoke` job runs it against
`@openai/codex@latest`; it is advisory (the job is non-blocking) but a diff
there is the signal to re-record the fixtures.
