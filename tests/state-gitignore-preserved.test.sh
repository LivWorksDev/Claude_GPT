#!/usr/bin/env bash
# state_init writes .tandem/.gitignore only when it is ABSENT. A user who edited
# it (to check one artefact in, say) must not have that silently reverted on the
# next turn — the guard is `[ -f … ] ||`, and it has to stay that way.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

ROOT="$CLAUDE_PROJECT_DIR/.tandem"
GI="$ROOT/.gitignore"
USER_CONTENT="$(printf '*\n!log/\n!log/*.md\n# kept by hand\n')"

mkdir -p "$ROOT"
printf '%s\n' "$USER_CONTENT" >"$GI"

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0
assert_eq "$USER_CONTENT" "$(cat "$GI")" ".gitignore after codex-start"

# hb_write has its own copy of the guard (it can create the tree on its own).
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume"
assert_eq "$USER_CONTENT" "$(cat "$GI")" ".gitignore after codex-resume"

# codex-swarm.sh writes it too.
printf 'seat\n' >"$SANDBOX/seat.txt"
run bash "$SCRIPTS/codex-swarm.sh" worker run-1 seat-a "$SANDBOX/seat.txt"
assert_rc 0 "swarm"
assert_eq "$USER_CONTENT" "$(cat "$GI")" ".gitignore after codex-swarm"

# …and codex-reset.sh / codex-show.sh go through state_init as well.
run bash "$SCRIPTS/codex-reset.sh" review demo
assert_rc 0 "reset"
assert_eq "$USER_CONTENT" "$(cat "$GI")" ".gitignore after codex-reset"

# When it is genuinely absent, the default is written.
rm -f "$GI"
run bash "$SCRIPTS/codex-start.sh" review demo2 "$SANDBOX/p.tpl"
assert_rc 0 "start with no .gitignore"
assert_eq "*" "$(cat "$GI")" "default .gitignore"

# An empty .gitignore is still a file the user owns: left exactly as found.
: >"$GI"
run bash "$SCRIPTS/codex-start.sh" review demo3 "$SANDBOX/p.tpl"
assert_rc 0 "start with an empty .gitignore"
assert_eq "0" "$(wc -c <"$GI" | tr -d ' ')" "empty .gitignore preserved"

# The heartbeat root gets one too, even when hb_write creates it alone.
rm -rf "$SANDBOX/hbroot"
(
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  ROLE=review
  HB_ROOT="$SANDBOX/hbroot"
  hb_write "running"
)
assert_eq "*" "$(cat "$SANDBOX/hbroot/.gitignore")" "heartbeat root .gitignore"
printf 'user owned\n' >"$SANDBOX/hbroot/.gitignore"
(
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  ROLE=review
  HB_ROOT="$SANDBOX/hbroot"
  hb_write "done"
)
assert_eq "user owned" "$(cat "$SANDBOX/hbroot/.gitignore")" "heartbeat .gitignore preserved"
