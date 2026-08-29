#!/usr/bin/env bash
# The range mode of tandem:review is a MODE, not a script: the helper resolves
# the range and builds the context, but what happens with the verdict — report
# and stop, never a fix loop, never a commit, never a promoted record — lives
# only in the skill and in the two range templates. No behavioural test can see
# a range section that grew a path to commit, or templates that drifted back to
# the pipeline's "review the uncommitted changes" framing, so both are asserted
# statically here, exactly like the worktree and turn-effort contracts.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$REPO_ROOT/skills/review/SKILL.md"
START_TPL="$REPO_ROOT/skills/review/prompts/start-range.tpl"
RESUME_TPL="$REPO_ROOT/skills/review/prompts/resume-range.tpl"

assert_file "$SKILL"

# --- the section, extracted and flattened ------------------------------------
# `## Range mode` up to the next level-2 heading (or the end of the file). Its
# own `### Range step N` headings are not boundaries. Markdown wraps, so prose
# anchors are judged on a whitespace-flattened copy.
SEC="$SANDBOX/range.section"
LC_ALL=C awk '/^## / { insec = ($0 ~ /^## Range mode/) } insec { print }' \
  "$SKILL" >"$SEC"
SEC_LINES="$(wc -l <"$SEC" | tr -d ' ')"
[ "$SEC_LINES" -ge 30 ] \
  || fail "the range section of $SKILL looks truncated ($SEC_LINES lines) — the anchors prove nothing"
FLAT="$SANDBOX/range.flat"
LC_ALL=C tr '\n' ' ' <"$SEC" | LC_ALL=C tr -s ' ' >"$FLAT"

# --- the frontmatter: the prohibition this mode retires is GONE --------------
# The old description forbade exactly the case this mode adds; leaving it there
# would tell the model not to use the section below.
assert_not_contains "$SKILL" "NOT for already-committed code"
assert_matches "$SKILL" '^argument-hint:.*--range A\.\.B'
assert_matches "$SKILL" '^description:.*range mode'
# …and the pipeline mode is still described as what it is.
assert_matches "$SKILL" '^description:.*uncommitted diff'

# --- step 1: the helper does the git work, and every exit is honoured --------
assert_file_contains "$FLAT" "review-range.sh"
assert_file_contains "$FLAT" "resolves BOTH endpoints to full shas"
assert_file_contains "$FLAT" "exit 64"
assert_file_contains "$FLAT" "exit 65"
assert_file_contains "$FLAT" "An empty range exits 2"
assert_file_contains "$FLAT" "non-zero exit is a STOP"
# The five lines the skill reads back, including the one that replaces Step 0.
for line in "TARGET:" "CONTEXT_FILE:" "LOG_FILE:" "ENDPOINTS:" "WORK_ROOT:"; do
  assert_file_contains "$FLAT" "$line"
done
assert_file_contains "$FLAT" "range-review-<label>"
assert_file_contains "$FLAT" ".tandem/log/ranges/"
assert_file_contains "$FLAT" "This mode never runs Step 0"
# The inline-diff cost is documented rather than silently unbounded.
assert_file_contains "$FLAT" "no hard limit"

# --- step 2: the pipeline's launch mechanics, reused verbatim ----------------
assert_file_contains "$FLAT" '`run_in_background: true` by default'
assert_file_contains "$FLAT" "10-minute foreground cap"
assert_file_contains "$FLAT" "hard synchronization barrier"
assert_file_contains "$FLAT" "task-completion notification"
assert_file_contains "$FLAT" "announce it clearly before doing anything else"
# …and the accounting, unconditional and BEFORE the verdict branch.
assert_file_contains "$FLAT" "USAGE:"
assert_file_contains "$FLAT" "unconditionally, before reading the \`VERDICT:\` line"
assert_file_contains "$FLAT" "before** you branch on the verdict"
assert_file_contains "$FLAT" "range review · tokens: in"
assert_file_contains "$FLAT" "tokens: n/a"

# --- step 3: the decision table, which is what this mode does NOT reuse ------
assert_file_contains "$FLAT" "VERDICT: APPROVED"
assert_file_contains "$FLAT" "Report the verdict"
assert_file_contains "$FLAT" "VERDICT: REQUEST_CHANGES"
assert_file_contains "$FLAT" "The findings ARE the deliverable"
assert_file_contains "$FLAT" "and FIN"
assert_file_contains "$FLAT" "You do not fix anything"
assert_file_contains "$FLAT" "no Step 4"
assert_file_contains "$FLAT" "no fix loop"
assert_file_contains "$FLAT" "the invocation ENDS there"
# One nudge, and the double-no-verdict branch that terminates it.
assert_file_contains "$FLAT" "One single nudge"
assert_file_contains "$FLAT" "ends as REQUEST_CHANGES with the anomaly recorded in the range log"
assert_file_contains "$FLAT" "BOTH turns accounted"
assert_file_contains "$FLAT" "Never a second nudge"
assert_file_contains "$FLAT" "without a terminal state"

# --- step 4: re-review by the same label, and the lineage rule ---------------
assert_file_contains "$FLAT" "NEW invocation of the helper with the SAME label"
assert_file_contains "$FLAT" "the SAME thread"
assert_file_contains "$FLAT" "Lineage rule"
assert_file_contains "$FLAT" "the same label is the same review lineage"
assert_file_contains "$FLAT" "use a NEW label"
# The mechanical reminder, stated WITHOUT naming a wrapper in prose: the
# worktree contract scans every physical line of this file for those names.
assert_file_contains "$FLAT" "an existing thread for this label is resumed, not restarted"

# --- promotion does not apply ------------------------------------------------
assert_file_contains "$FLAT" 'TANDEM_PROMOTE_REVIEWS` does not apply'
assert_file_contains "$FLAT" "no versioned record to write"

# --- the negatives: there is no path from here to a commit -------------------
for needle in "git commit" "final — commit:" "docs/reviews/" "AskUserQuestion"; do
  assert_not_contains "$SEC" "$needle"
done

# --- the launches of the section --------------------------------------------
# Only FENCED blocks are commands; the unit judged is one logical command, with
# backslash continuations accumulated (the parser the other skill contracts use).
CMDS="$SANDBOX/range.cmds"
: >"$CMDS"
fence=0
cmd=""
cont=0
while IFS= read -r line || [ -n "$line" ]; do
  stripped="${line#"${line%%[![:space:]]*}"}"
  case "$stripped" in
    '```'*)
      [ -n "$cmd" ] && printf '%s\n' "$cmd" >>"$CMDS"
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
      [ -n "$cmd" ] && printf '%s\n' "$cmd" >>"$CMDS"
      cmd=""
      ;;
  esac
done <"$SEC"
[ "$fence" -eq 0 ] || fail "$SKILL: unterminated fenced block inside the range section"

HELPERS=0
LAUNCHES=0
FOREGROUND=0
BACKGROUND=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  case "$c" in
    *review-range.sh*) HELPERS=$((HELPERS + 1)) ;;
  esac
  case "$c" in
    *codex-start.sh* | *codex-resume.sh*)
      LAUNCHES=$((LAUNCHES + 1))
      case "$c" in
        *TANDEM_EXEC_TIMEOUT_SECONDS=540*) FOREGROUND=$((FOREGROUND + 1)) ;;
        *TANDEM_EXEC_TIMEOUT_SECONDS*)
          fail "$SKILL: a foreground range launch does not pin TANDEM_EXEC_TIMEOUT_SECONDS=540: $c"
          ;;
        *) BACKGROUND=$((BACKGROUND + 1)) ;;
      esac
      case "$c" in
        *'TANDEM_CODEX_CWD="$WORK_ROOT"'*) : ;;
        *) fail "$SKILL: a range launch is not pinned to \$WORK_ROOT: $c" ;;
      esac
      # The thread state must land where the helper put the context and the
      # log: an unpinned launch anchors it to the shell's own cwd instead, and
      # a later invocation from elsewhere would start a FRESH thread for the
      # same label — a silent lineage break.
      case "$c" in
        *'CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$WORK_ROOT}"'*) : ;;
        *) fail "$SKILL: a range launch does not pin CLAUDE_PROJECT_DIR to the helper's root: $c" ;;
      esac
      case "$c" in
        *range-review-\<label\>*) : ;;
        *) fail "$SKILL: a range launch does not target range-review-<label>: $c" ;;
      esac
      ;;
  esac
done <"$CMDS"

# The helper twice; the three original turns remain, and the two real launches
# each have a separately executable small-diff foreground variant. Exactly
# those two variants plus the nudge carry the 540 s foreground override.
[ "$HELPERS" -ge 2 ] || fail "$SKILL: expected the helper in at least 2 blocks, found $HELPERS"
[ "$LAUNCHES" -eq 5 ] || fail "$SKILL: expected exactly 5 range launches, found $LAUNCHES"
assert_eq "3" "$FOREGROUND" "$SKILL: foreground range launches"
assert_eq "2" "$BACKGROUND" "$SKILL: background range launches"
# The negative that really bites: not one EXECUTABLE line of this mode stages or
# commits anything, whatever `git -C …` shape it might be dressed in.
assert_not_contains "$CMDS" "commit"
assert_not_contains "$CMDS" "git add"
assert_file_contains "$CMDS" "prompts/start-range.tpl"
assert_file_contains "$CMDS" "prompts/resume-range.tpl"
assert_file_contains "$CMDS" "prompts/nudge.tpl"
note "review/SKILL.md — range section: $HELPERS helper block(s), $LAUNCHES anchored launches ($FOREGROUND foreground)"

# --- the templates the section points at -------------------------------------
assert_file "$START_TPL"
assert_file "$RESUME_TPL"

# start-range: the context is the review's material, the diff is authoritative,
# and every read is anchored at B.
assert_file_contains "$START_TPL" "{{EXTRA}}"
assert_file_contains "$START_TPL" "ALREADY part of the history"
assert_file_contains "$START_TPL" 'The `DIFF:` section of CONTEXT is AUTHORITATIVE'
assert_file_contains "$START_TPL" "git show <shaB>:<path>"
assert_file_contains "$START_TPL" "git ls-tree -r --name-only <shaB>"
assert_file_contains "$START_TPL" "the checkout may sit on a completely different version"
# A plan is optional here — demanding one would make every plan-less range a
# finding.
assert_file_contains "$START_TPL" "There may be none"

# resume-range: the UPDATED context arrives as notes, and the thread re-checks
# its own findings.
assert_file_contains "$RESUME_TPL" "{{NOTES}}"
assert_file_contains "$RESUME_TPL" "For EACH of your previous findings"
assert_file_contains "$RESUME_TPL" "git show <shaB>:<path>"

# The verdict contract, complete, in both.
for t in "$START_TPL" "$RESUME_TPL"; do
  assert_file_contains "$t" "exactly one final line, nothing after it"
  assert_file_contains "$t" "VERDICT: APPROVED"
  assert_file_contains "$t" "VERDICT: REQUEST_CHANGES"
  # The regression these templates exist to prevent: the pipeline's framing.
  assert_not_contains "$t" "UNCOMMITTED"
  assert_not_contains "$t" "git diff HEAD"
  assert_not_contains "$t" "git status -s"
done

note "review/SKILL.md + range templates — out-of-pipeline contract anchored"
