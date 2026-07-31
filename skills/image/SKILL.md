---
name: image
description: Generate image assets (icons, sprites, illustrations, UI mockups) saved at exact repo paths using Codex's native gpt-image-2 tool, driven by GPT-5.6 Sol (effort high, workspace-write) — one thread per asset so refinements keep full context. Supports transparent backgrounds via the chroma-key workaround when the use case needs it (e.g. videogame sprites). Use when the user asks to generate an image or visual asset for the project. NOT for code changes (tandem:implement) and NOT part of the plan/review pipeline.
argument-hint: "[asset-label] [what to generate]"
---

# tandem:image — Codex genera, tú verificas

Codex renders with its native image tool (gpt-image-2); Sol at `high` drives the turn because the text model writes the actual image prompt and runs the transparency workflow — understanding the brief is what buys one-shot renders. **You** write the brief, look at the produced pixels and own the result. Image turns only ADD files, and Codex never commits.

Shared scripts: `SCRIPTS="${CLAUDE_SKILL_DIR}/../../scripts"`.

Quota note (tell the user when the request is more than a couple of assets): image turns consume the ChatGPT plan allowance 3–5× faster than text turns, and stable output tops out at 2K. For big batches or CI, setting `OPENAI_API_KEY` switches Codex to API billing.

## Step 0 — Brief

`asset-label` is a short kebab-case key (e.g. `sprite-hero-idle`, `icon-billing`). One thread per asset or per coherent set; reuse the label to refine with full memory.

Resolve with the user only what the request leaves genuinely open (with `TANDEM_AUTONOMOUS=1` never ask: derive from the request, take conservative defaults and record every assumption in the brief):

- **output** — exact repo-relative path(s), `.png`.
- **size** — per asset, e.g. `128x128` (stable up to 2K).
- **subject & style** — what appears, art direction, palette, references.
- **transparency** — only when the use case needs it (sprites, logos, assets rendered over variable backgrounds). gpt-image-2 has no native transparency; the workaround renders on a flat key colour and strips it. Key colour `#00ff00`; use `#ff00ff` when the subject itself contains green. Requires a backend (`/tandem:doctor` reports it).

Then:

1. `mkdir -p` every output directory.
2. Snapshot the tree: `git status --porcelain > .tandem/tmp/<label>-pre.txt`. A dirty tree is acceptable here — image turns only ADD files, and this snapshot is what proves it afterwards.
3. Write the brief to `.tandem/tmp/<label>-brief.md`:

```
asset: <label>
output: <repo-relative path>            # one line per asset
size: <WxH>
subject: <what exactly appears>
style: <art direction, palette, references>
transparency: yes | no
key-colour: #00ff00                     # only if transparency: yes
chroma-strip: <"$SCRIPTS/chroma-strip.sh" resolved to an ABSOLUTE path>   # only if transparency: yes
notes: <margins, what to avoid, negative space…>
```

## Step 1 — Generate

```bash
bash "$SCRIPTS/codex-start.sh" image <asset-label> \
  "${CLAUDE_SKILL_DIR}/prompts/generate.tpl" \
  .tandem/tmp/<label>-brief.md
```

Foreground with Bash `timeout: 600000` for 1–3 assets; `run_in_background: true` for larger sets (announce completion clearly before doing anything else).

Exit 2 → the label already has a thread: refine it (Step 3), or `codex-reset.sh image <asset-label>` if it is genuinely a new asset under an old name.

## Step 2 — Your verification (never delegated)

The reply's last line is the sentinel:

- `IMAGE_BLOCKED: <reason>` → relay the reason verbatim; fix the blocker (missing brief data, no chroma backend — `/tandem:doctor`) and refine or reset.
- Neither sentinel → resume once asking only for the missing status line, with the dedicated nudge template and a cheap effort for that single invocation; if it happens twice, treat as BLOCKED and log the anomaly.

```bash
TANDEM_TURN_EFFORT=low bash "$SCRIPTS/codex-resume.sh" image <asset-label> \
  "${CLAUDE_SKILL_DIR}/prompts/nudge.tpl"
```

The template forbids rendering or editing anything — a reminder must never burn another image generation — and `TANDEM_TURN_EFFORT` is ephemeral, applying to that one invocation only (only the resume wrapper reads it, nothing is exported, the sandbox is untouched, and the generate/refine turns keep the role's `high`).
- `IMAGE_READY: <paths>` → verify, in this order:

1. **Look at every produced file** with the Read tool and judge it against the brief: subject, style, composition, size. You are the visual gate — Codex's own description of the image never counts as proof.
2. Transparency: `bash "$SCRIPTS/chroma-strip.sh" --check <file>` per asset (exit 2 → no usable alpha → refine). Also judge the edges yourself when viewing: a green/magenta fringe means a re-render with cleaner margins, not a shrug.
3. Audit the writes: diff `git status --porcelain` against the Step-0 snapshot — every new entry must be a declared output path (or `.tandem/` internals). Anything else → show it to the user verbatim and offer to revert; never silently accept collateral writes.

## Step 3 — Refine (same thread)

Write only what must change to `.tandem/tmp/<label>-notes.md`, then:

```bash
bash "$SCRIPTS/codex-resume.sh" image <asset-label> \
  "${CLAUDE_SKILL_DIR}/prompts/refine.tpl" \
  .tandem/tmp/<label>-notes.md
```

Repeat Step 2 after every turn. Iterating burns quota fast — batch feedback into one round instead of one turn per nit.

## Step 4 — Handoff

Do NOT commit. Show the user the final paths and your verification verdict; committing — and whether many large binaries belong in git or LFS — is their call.
