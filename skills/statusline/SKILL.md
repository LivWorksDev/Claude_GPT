---
name: statusline
description: Install, remove or check tandem's status line - session model, effort, context %, cost and branch on line 1; on line 2, the live Codex gate (role, model, turn, sandbox, timer, verdict, tokens) or the Opus implement attempt (presence and outcome from the durable state). Works in every project once installed; line 2 only appears where .tandem/ exists.
argument-hint: "[install|uninstall|status]"
---

# tandem:statusline

Manages the status line integration. Claude Code does not let a plugin provide
the main status line, so this edits the **user's** `~/.claude/settings.json` —
which is why installing and uninstalling require explicit consent.

Argument (default `status` if none given): `install`, `uninstall` or `status`.

## status

Run and report as-is:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/statusline-install.sh" status
```

## install

1. First show the user what will happen and **ask for confirmation**:
   - a shim is written to `~/.claude/tandem-statusline.sh` (it re-resolves the
     plugin's `statusline.sh` on every render, so plugin updates never break it,
     and it degrades to a minimal model+context line if tandem is uninstalled);
   - `~/.claude/settings.json` gets a `statusLine` entry pointing at the shim
     (atomic write, backup kept at `settings.json.tandem-backup`).
2. Only after the user agrees:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/statusline-install.sh" install
```

3. Exit 2 means the user already has a **different** statusLine configured; the
   script printed it. Show it and ask whether to replace it — only then re-run
   with `--force`. Never pass `--force` on the first attempt.
4. Remind the user the status line appears on the next session (or restart).

## uninstall

Confirm with the user, then:

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/statusline-install.sh" uninstall
```

Removes the settings entry only if it is tandem's, and deletes the shim.
