#!/usr/bin/env bash
# The behavioural half of M8 (swarm-preamble) cannot see the bug it exists to
# prevent: an implementation that adds --preamble to the wrapper command AND
# keeps "write the full contents of <PREAMBLE>" in step 1 sends every seat the
# preamble TWICE, with the whole suite green. The wrapper is executable
# documentation, so the contract is asserted statically, here.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$REPO_ROOT/skills/ultra/SKILL.md"
assert_file "$SKILL"

# Markdown wraps, so the prose anchors are judged on a whitespace-flattened
# copy: a re-wrapped sentence is the same contract, an absent one is not.
FLAT="$SANDBOX/ultra-skill.flat"
LC_ALL=C tr '\n' ' ' <"$SKILL" | LC_ALL=C tr -s ' ' >"$FLAT"

# --- positive anchor: step 1 writes the BRIEF and nothing else ---------------
assert_file_contains "$FLAT" "containing ONLY the BRIEF below, verbatim"

# --- negative anchor: the manual copy is gone, not merely supplemented -------
# Any surviving instruction to reproduce the preamble is the duplication bug.
assert_not_contains "$FLAT" "the full contents of <PREAMBLE>"
assert_not_contains "$FLAT" "contents of <PREAMBLE>"

# --- the flag really is on the launch, before the positionals ----------------
# Only fenced blocks are scanned — that is where the wrapper prompt lives, and
# prose that merely names the script is not a launch. Judged per logical
# command (backslash continuations accumulated), so a wrapper with two launches
# and only one flag has to fail.
launches=0
check_cmd() {
  case "$1" in
    *codex-swarm.sh*)
      launches=$((launches + 1))
      # The order matters: --preamble is a flag, never a fifth positional, and
      # the parser stops at the first non-flag word.
      case "$1" in
        *codex-swarm.sh*--preamble*'<tier>'*'<run-id>'*) : ;;
        *) fail "$SKILL: this seat launch has no --preamble before the positionals: $1" ;;
      esac
      ;;
  esac
}

cmd="" cont=0 fence=0
while IFS= read -r line; do
  case "$line" in
    '```'*)
      [ -n "$cmd" ] && check_cmd "$cmd"
      cmd="" cont=0
      if [ "$fence" -eq 1 ]; then fence=0; else fence=1; fi
      continue
      ;;
  esac
  [ "$fence" -eq 1 ] || continue
  if [ "$cont" -eq 1 ]; then cmd="$cmd $line"; else cmd="$line"; fi
  case "$cmd" in
    *\\)
      cont=1
      cmd="${cmd%\\}"
      ;;
    *)
      cont=0
      check_cmd "$cmd"
      cmd=""
      ;;
  esac
done <"$SKILL"
[ -n "$cmd" ] && check_cmd "$cmd"

# --- never vacuously green ---------------------------------------------------
# A skill that lost its wrapper altogether is a different bug, not a pass.
[ "$launches" -ge 1 ] || fail "$SKILL: expected at least one codex-swarm.sh launch, found $launches"
assert_file_contains "$FLAT" 'PREAMBLE="${CLAUDE_SKILL_DIR}/prompts/seat-preamble.md"'
assert_file "$REPO_ROOT/skills/ultra/prompts/seat-preamble.md"
lines="$(wc -l <"$SKILL" | tr -d ' ')"
[ "$lines" -ge 40 ] || fail "$SKILL looks truncated ($lines lines) — the anchors above prove nothing"
note "ultra/SKILL.md — wrapper reduced to brief + launch + extraction ($launches launch(es))"
