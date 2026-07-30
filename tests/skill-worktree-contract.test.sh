#!/usr/bin/env bash
# The real failure mode of the worktree wiring lives in Markdown, not in bash:
# the wrappers do exactly what they are told, so an implement or review skill
# that forgets TANDEM_CODEX_CWD on a SINGLE launch anchors that turn to the
# wrong tree while the whole suite stays green. This is a static assertion on
# executable documentation — the only net under that.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# check_skill <skill-file> — EVERY launch of codex-start/codex-resume must carry
# TANDEM_CODEX_CWD. The unit checked is one logical command, never a whole
# fenced block: a block with two launches, only one of them anchored, has to
# fail. Commands are accumulated across backslash continuations so a launch
# split over several lines is judged as the single command it is.
check_skill() {
  local f="$1" launches=0 line cmd="" cont=0
  [ -f "$f" ] || fail "skill not found: $f"

  # check_cmd <command-text> — judges one logical command.
  check_cmd() {
    case "$1" in
      *codex-start.sh* | *codex-resume.sh*)
        launches=$((launches + 1))
        case "$1" in
          *TANDEM_CODEX_CWD*) : ;;
          *) fail "$f: this codex launch has no TANDEM_CODEX_CWD: $1" ;;
        esac
        ;;
    esac
  }

  while IFS= read -r line; do
    # Fence markers are not commands, but they do terminate one.
    case "$line" in
      '```'*)
        [ -n "$cmd" ] && check_cmd "$cmd"
        cmd="" cont=0
        continue
        ;;
    esac

    if [ "$cont" -eq 1 ]; then
      cmd="$cmd $line"
    else
      cmd="$line"
    fi

    # A trailing backslash means the command continues on the next line.
    case "$cmd" in
      *\\) cont=1; cmd="${cmd%\\}" ;;
      *)
        cont=0
        check_cmd "$cmd"
        cmd=""
        ;;
    esac
  done <"$f"
  [ -n "$cmd" ] && check_cmd "$cmd"

  # Never vacuously green: a skill that lost its launches altogether is a
  # different bug, not a pass.
  [ "$launches" -ge 2 ] \
    || fail "$f: expected at least 2 codex-start/codex-resume launches, found $launches"
  note "$(basename "$(dirname "$f")")/SKILL.md — $launches anchored launches"

  # …and the anchor has to come from the fail-closed resolver, not from a path
  # the skill guessed for itself.
  assert_file_contains "$f" "worktree-root.sh"
  assert_file_contains "$f" "WORK_ROOT"
}

check_skill "$REPO_ROOT/skills/implement/SKILL.md"
check_skill "$REPO_ROOT/skills/review/SKILL.md"

# The resolver the skills are required to call has to exist and be runnable.
assert_file "$SCRIPTS/worktree-root.sh"
run bash "$SCRIPTS/worktree-root.sh"
assert_rc 64 "worktree-root.sh usage"

# TANDEM_WORKTREE's scope is documented where a reader would otherwise assume
# isolation. Since 0.12 the flag also decides where the plan-approval commit
# lands, so the sentence names both phases: ask/image are still never anchored.
assert_file_contains "$REPO_ROOT/skills/implement/SKILL.md" \
  "plan approval and implement/review only"
