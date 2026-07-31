#!/usr/bin/env bash
# The wrapper does exactly what it is told, so the whole point of
# TANDEM_TURN_EFFORT lives in Markdown: a nudge branch that lost its prefix
# silently pays the role's xhigh again, and — far worse — a REAL resume that
# gained one would downgrade actual review or implementation work to `low` with
# the behavioural suite fully green. Both directions are asserted here, on
# executable documentation, like the worktree and preamble contracts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# check_skill <skill-file> <needs-worktree-pin: 0|1> <role+target pattern>
# Only FENCED blocks are scanned — that is where the commands the skill really
# runs live, and prose naming a script is not a launch. The unit judged is one
# logical command (backslash continuations accumulated), never a whole block: a
# block with a nudge and a real resume in it must be judged twice.
check_skill() {
  local f="$1" want_cwd="$2" role_pat="$3"
  local nudges=0 real=0 line stripped cmd="" cont=0 fence=0
  [ -f "$f" ] || fail "skill not found: $f"

  check_cmd() {
    case "$1" in
      *codex-start.sh* | *codex-resume.sh*) : ;;
      *) return 0 ;;
    esac
    case "$1" in
      *prompts/nudge.tpl*)
        nudges=$((nudges + 1))
        case "$1" in
          *codex-resume.sh*) : ;;
          *) fail "$f: a nudge must resume the SAME thread, not start one: $1" ;;
        esac
        case "$1" in
          *TANDEM_TURN_EFFORT=low*) : ;;
          *) fail "$f: this nudge does not carry TANDEM_TURN_EFFORT=low: $1" ;;
        esac
        # Concrete and per role: a nudge that resumed another role's thread
        # would be a brand-new turn, not a reminder.
        case "$1" in
          *"$role_pat"*) : ;;
          *) fail "$f: this nudge does not name [$role_pat]: $1" ;;
        esac
        if [ "$want_cwd" = "1" ]; then
          case "$1" in
            *'TANDEM_CODEX_CWD="$WORK_ROOT"'*) : ;;
            *) fail "$f: this nudge has no TANDEM_CODEX_CWD=\"\$WORK_ROOT\": $1" ;;
          esac
        fi
        ;;
      *)
        real=$((real + 1))
        # The dangerous direction: real work must never inherit the cheap
        # effort of a reminder turn.
        case "$1" in
          *TANDEM_TURN_EFFORT*)
            fail "$f: this REAL codex launch carries TANDEM_TURN_EFFORT: $1"
            ;;
        esac
        ;;
    esac
  }

  while IFS= read -r line; do
    # Fence markers are not commands, but they do terminate one. Indented
    # fences are fences too (implement/SKILL.md nests one inside a list).
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
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
  done <"$f"
  [ -n "$cmd" ] && check_cmd "$cmd"

  # Never vacuously green: a skill with no nudge branch, or one that lost its
  # real launches, is a different bug — not a pass.
  [ "$nudges" -ge 1 ] || fail "$f: expected at least one nudge launch, found $nudges"
  [ "$real" -ge 1 ] || fail "$f: expected at least one real codex launch, found $real"
  note "$(basename "$(dirname "$f")")/SKILL.md — $nudges nudge(s), $real real launch(es)"
}

check_skill "$REPO_ROOT/skills/plan/SKILL.md" 0 "review docs/plans/<slug>.plan.md"
check_skill "$REPO_ROOT/skills/review/SKILL.md" 1 "review cr-<slug>"
check_skill "$REPO_ROOT/skills/implement/SKILL.md" 1 "implement docs/plans/<slug>.plan.md"
check_skill "$REPO_ROOT/skills/image/SKILL.md" 0 "image <asset-label>"

# --- the templates the four branches point at --------------------------------
PLAN_TPL="$REPO_ROOT/skills/plan/prompts/nudge.tpl"
REVIEW_TPL="$REPO_ROOT/skills/review/prompts/nudge.tpl"
IMPLEMENT_TPL="$REPO_ROOT/skills/implement/prompts/nudge.tpl"
IMAGE_TPL="$REPO_ROOT/skills/image/prompts/nudge.tpl"
for t in "$PLAN_TPL" "$REVIEW_TPL" "$IMPLEMENT_TPL" "$IMAGE_TPL"; do
  assert_file "$t"
done

# plan / review / image ask ONLY for the line that was missing: a nudge that
# re-ran the expensive work would cost more than the turn it replaces.
assert_file_contains "$PLAN_TPL" "Do NOT re-review the plan"
assert_file_contains "$PLAN_TPL" "VERDICT: APPROVED"
assert_file_contains "$PLAN_TPL" "VERDICT: REVISE"
assert_file_contains "$PLAN_TPL" "VERDICT: NEEDS_REWORK"

assert_file_contains "$REVIEW_TPL" "Do NOT re-review the diff"
assert_file_contains "$REVIEW_TPL" "VERDICT: APPROVED"
assert_file_contains "$REVIEW_TPL" "VERDICT: REQUEST_CHANGES"

assert_file_contains "$IMAGE_TPL" "Do NOT generate, edit or re-render anything"
assert_file_contains "$IMAGE_TPL" "IMAGE_READY:"
assert_file_contains "$IMAGE_TPL" "IMAGE_BLOCKED:"

for t in "$PLAN_TPL" "$REVIEW_TPL" "$IMAGE_TPL"; do
  assert_file_contains "$t" "exactly one line"
  # The output contract is per role, not uniform: only implement asks for a
  # report, because only implement's transport contract needs one.
  assert_not_contains "$t" "FINAL REPORT"
done

# implement asks for the final report PLUS the sentinel, while forbidding any
# further implementation work.
assert_file_contains "$IMPLEMENT_TPL" "Do NOT implement anything further"
assert_file_contains "$IMPLEMENT_TPL" "FINAL REPORT"
assert_file_contains "$IMPLEMENT_TPL" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$IMPLEMENT_TPL" "IMPLEMENTATION_PARTIAL"

# --- the variable the skills prefix is really read, and only by resume -------
# A contract asserted against Markdown alone could drift away from the wrappers.
assert_file_contains "$SCRIPTS/codex-resume.sh" "TANDEM_TURN_EFFORT"
assert_not_contains "$SCRIPTS/codex-start.sh" "TANDEM_TURN_EFFORT"
assert_not_contains "$SCRIPTS/codex-swarm.sh" "TANDEM_TURN_EFFORT"
assert_not_contains "$SCRIPTS/_common.sh" "TANDEM_TURN_EFFORT"
