#!/usr/bin/env bash
# The 10-minute foreground cap is a ceiling of the Bash TOOL, not of the
# wrappers: no script can be tested for it, so the only place the fix can live
# — and the only place it can silently rot — is the executable documentation of
# the review launches. A skill that went back to a foreground default would keep
# the whole behavioural suite green while every xhigh review of a real plan or
# diff died mid-turn with the quota already spent.
#
# The unit judged is the LAUNCH, not the file: each fenced block that runs
# codex-start/codex-resume is classified by its template — `prompts/nudge.tpl`
# is a nudge (a one-line turn at `low` effort, which must STAY in the
# foreground), anything else is a real review launch (which must carry the
# background recommendation) — and the file is partitioned into one section per
# launch, so the negative assertions are sectioned too: adding the new sentence
# without retiring the old "Bash timeout: 600000" default would leave the
# behaviour ambiguous with a file-level test perfectly green.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# split_launches <skill-file> <prefix> — partitions the file into one section
# per codex launch and writes:
#   <prefix>.<n>         the section, whitespace-flattened (Markdown wraps; a
#                        re-wrapped sentence is the same contract)
#   <prefix>.launches    one "<kind> <mode> <script> <section-path>" record per
#                        launch, in order
# Every line of the file belongs to exactly ONE section: the launch block it is
# closest to (ties go to the earlier block). Commands are accumulated across
# backslash continuations, like the worktree and turn-effort contracts, so a
# launch split over several lines is judged as the single command it is.
#
# The MODE comes from the launch's own target, because review/SKILL.md carries
# two of them: the pipeline (`cr-<slug>`) and the out-of-pipeline range review
# (`range-review-<label>`). Each group is then counted and judged on its own —
# a file-wide total would let a lost pipeline launch be masked by a range one.
#
# The SCRIPT (`codex-start.sh` vs `codex-resume.sh`) is the third axis, and the
# only one that can express the mcp rule: a START is the one turn that arms the
# MCP watchdog, so under that transport it loses the small-input exception,
# while a continuation is a plain `codex exec resume` turn that keeps it. A
# file-level grep could not tell them apart — the exception legitimately
# survives in the resume sections — so the rule is judged per launch here.
split_launches() {
  local f="$1" pfx="$2"
  local line stripped cmd="" cont=0 fence=0 n=0 i=0 k=0 nl=0
  local blk_start=0 blk_real=0 blk_nudge=0 blk_cmd=""
  local best=0 bestd=0 d=0

  [ -f "$f" ] || fail "skill not found: $f"

  LINES=()
  BSTART=()
  BEND=()
  BKIND=()
  BMODE=()
  BSCRIPT=()

  # classify_cmd <command-text> — counts the launches of the block being read.
  classify_cmd() {
    case "$1" in
      *codex-start.sh* | *codex-resume.sh*) : ;;
      *) return 0 ;;
    esac
    blk_cmd="$1"
    case "$1" in
      *prompts/nudge.tpl*) blk_nudge=$((blk_nudge + 1)) ;;
      *) blk_real=$((blk_real + 1)) ;;
    esac
  }

  while IFS= read -r line || [ -n "$line" ]; do
    nl=$((nl + 1))
    LINES[nl]="$line"
    # Fence markers are not commands, but they do terminate one. Indented
    # fences are fences too.
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '```'*)
        if [ "$fence" -eq 1 ]; then
          [ -n "$cmd" ] && classify_cmd "$cmd"
          cmd="" cont=0 fence=0
          if [ "$blk_real" -gt 0 ] && [ "$blk_nudge" -gt 0 ]; then
            fail "$f: the block at line $blk_start mixes a nudge and a real launch — one section cannot describe both"
          fi
          # One LOGICAL launch per block, strictly: counting blocks instead of
          # launches would let a duplicated start/resume of the same kind hide
          # inside one block while the totals still read "2 real + 1 nudge" —
          # a duplicate turn burns quota and races the persistent thread.
          if [ $((blk_real + blk_nudge)) -gt 1 ]; then
            fail "$f: the block at line $blk_start carries $((blk_real + blk_nudge)) launches — exactly one logical launch per block"
          fi
          if [ "$blk_real" -gt 0 ] || [ "$blk_nudge" -gt 0 ]; then
            n=$((n + 1))
            BSTART[n]=$blk_start
            BEND[n]=$nl
            if [ "$blk_nudge" -gt 0 ]; then BKIND[n]="nudge"; else BKIND[n]="real"; fi
            case "$blk_cmd" in
              *range-review-*) BMODE[n]="range" ;;
              *) BMODE[n]="pipeline" ;;
            esac
            case "$blk_cmd" in
              *codex-start.sh*) BSCRIPT[n]="start" ;;
              *codex-resume.sh*) BSCRIPT[n]="resume" ;;
              *) BSCRIPT[n]="unknown" ;;
            esac
          fi
        else
          fence=1 blk_start=$nl blk_real=0 blk_nudge=0 blk_cmd="" cmd="" cont=0
        fi
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
        classify_cmd "$cmd"
        cmd=""
        ;;
    esac
  done <"$f"

  [ "$fence" -eq 0 ] || fail "$f: unterminated fenced block — the sections would be guesswork"
  # Never vacuously green: a skill emptied of its launches is a different bug.
  [ "$nl" -ge 40 ] || fail "$f looks truncated ($nl lines) — the anchors would prove nothing"
  [ "$n" -ge 1 ] || fail "$f: no codex launch found inside any fenced block"

  k=1
  while [ "$k" -le "$n" ]; do
    : >"$pfx.$k.raw"
    k=$((k + 1))
  done

  i=1
  while [ "$i" -le "$nl" ]; do
    best=1 bestd=-1
    k=1
    while [ "$k" -le "$n" ]; do
      if [ "$i" -lt "${BSTART[k]}" ]; then
        d=$((BSTART[k] - i))
      elif [ "$i" -gt "${BEND[k]}" ]; then
        d=$((i - BEND[k]))
      else
        d=0
      fi
      if [ "$bestd" -lt 0 ] || [ "$d" -lt "$bestd" ]; then
        bestd=$d
        best=$k
      fi
      k=$((k + 1))
    done
    printf '%s\n' "${LINES[i]}" >>"$pfx.$best.raw"
    i=$((i + 1))
  done

  : >"$pfx.launches"
  k=1
  while [ "$k" -le "$n" ]; do
    LC_ALL=C tr '\n' ' ' <"$pfx.$k.raw" | LC_ALL=C tr -s ' ' >"$pfx.$k"
    printf '%s %s %s %s\n' "${BKIND[k]}" "${BMODE[k]}" "${BSCRIPT[k]}" "$pfx.$k" \
      >>"$pfx.launches"
    k=$((k + 1))
  done
}

# check_skill <skill-file> <prefix> <small-input-noun>
#             <pipeline-real> <pipeline-nudges> <range-real> <range-nudges>
#             <mcp-start-rule>
# The four counts are EXACT and per group: the launches this contract knows how
# to reason about, in the mode they belong to. A lost pipeline launch, a nudge
# that became a fourth launch, or a range branch that quietly disappeared are
# all different bugs — and none of them may be absorbed by another group's count.
#
# <mcp-start-rule> is 1 for the skill whose role the mcp transport supports: its
# real START launches must carry the mcp background rule as well as everything
# below. Resume and nudge launches are judged EXACTLY as before either way —
# they are `codex exec resume` turns, with no MCP watchdog to outlive.
check_skill() {
  local f="$1" pfx="$2" noun="$3"
  local want_pr="$4" want_pn="$5" want_rr="$6" want_rn="$7" want_mcp="${8:-0}"
  local kind mode script sec real=0 nudges=0 rreal=0 rnudges=0
  # Single quotes: the phrase carries backticks and must never be re-evaluated.
  local exception='foreground with `timeout: 600000` only for small '"$noun"

  split_launches "$f" "$pfx"

  while read -r kind mode script sec; do
    [ -n "$kind" ] || continue
    case "$mode" in
      pipeline | range) : ;;
      *) fail "$f: unknown launch mode [$mode]" ;;
    esac
    case "$script" in
      start | resume) : ;;
      *) fail "$f: a launch runs neither codex-start.sh nor codex-resume.sh [$script]" ;;
    esac
    case "$kind" in
      real)
        if [ "$mode" = "range" ]; then rreal=$((rreal + 1)); else real=$((real + 1)); fi
        # Background is the DEFAULT, with the size criterion as the exception…
        assert_file_contains "$sec" '`run_in_background: true` by default'
        assert_file_contains "$sec" "$exception"
        # …the completion of a background run is announced before anything else…
        assert_file_contains "$sec" 'announce it clearly before doing anything else'
        # …and the notification is a barrier, not a hint.
        assert_file_contains "$sec" 'task-completion notification'
        assert_file_contains "$sec" 'barrier'
        # SECTIONED NEGATIVE: inside a real launch's section the only surviving
        # `timeout: 600000` may be the small-input exception. Supplementing the
        # old foreground default instead of removing it fails here.
        LC_ALL=C sed "s|$exception||g" <"$sec" >"$sec.noexc"
        assert_not_contains "$sec.noexc" 'timeout: 600000'
        assert_not_contains "$sec" 'Bash timeout: 600000'
        # …and, for the role the mcp transport serves, a START loses that
        # exception entirely under `mcp`: it is the only turn that arms the MCP
        # watchdog, whose review default sits ABOVE the foreground cap, so a
        # foreground start would be killed by the tool before the watchdog could
        # classify the hang and account the turn. The escape hatch is named, so
        # the rule is actionable instead of merely prohibitive.
        if [ "$want_mcp" = "1" ] && [ "$script" = "start" ]; then
          assert_file_contains "$sec" '`TANDEM_TRANSPORT=mcp`'
          assert_file_contains "$sec" 'Under `mcp` this launch is `run_in_background: true` ALWAYS'
          assert_file_contains "$sec" 'TANDEM_MCP_TIMEOUT_SECONDS'
        fi
        ;;
      nudge)
        if [ "$mode" = "range" ]; then rnudges=$((rnudges + 1)); else nudges=$((nudges + 1)); fi
        # A one-line turn at `low` effort: foreground, explicitly, and never
        # promoted to background by a careless sweep of the file.
        assert_file_contains "$sec" 'in the foreground'
        assert_not_contains "$sec" 'run_in_background'
        ;;
      *) fail "$f: unknown launch kind [$kind]" ;;
    esac
  done <"$pfx.launches"

  assert_eq "$want_pr" "$real" "$f: pipeline real review launches"
  assert_eq "$want_pn" "$nudges" "$f: pipeline nudge launches"
  assert_eq "$want_rr" "$rreal" "$f: range real review launches"
  assert_eq "$want_rn" "$rnudges" "$f: range nudge launches"

  # The legacy foreground default is GONE from the file, not merely supplemented.
  assert_not_contains "$f" 'Bash timeout: 600000'
  note "$(basename "$(dirname "$f")")/SKILL.md — pipeline: $real real + $nudges nudge · range: $rreal real + $rnudges nudge"
}

# plan launches the `review` ROLE too, but its opt-in note is not part of this
# hop (docs/plans/mcp-transport-review.plan.md, Files to touch): 0.
check_skill "$REPO_ROOT/skills/plan/SKILL.md" "$SANDBOX/plan" "plans" 2 1 0 0 0
# review carries both modes: the pipeline review (start + resume + nudge) and
# the out-of-pipeline range review (start-range + resume-range + nudge), each
# with the same background/barrier guarantees — and, in both modes, the mcp rule
# on the START launch alone.
check_skill "$REPO_ROOT/skills/review/SKILL.md" "$SANDBOX/review" "diffs" 2 1 2 1 1

# --- the barrier language itself, once per skill -----------------------------
# Markdown wraps, so the prose anchors are judged on a flattened copy.
flatten() {
  local f="$1" out
  [ -f "$f" ] || fail "skill not found: $f"
  out="$SANDBOX/$(basename "$(dirname "$f")").flat"
  LC_ALL=C tr '\n' ' ' <"$f" | LC_ALL=C tr -s ' ' >"$out"
  printf '%s' "$out"
}

PLAN_FLAT="$(flatten "$REPO_ROOT/skills/plan/SKILL.md")"
REVIEW_FLAT="$(flatten "$REPO_ROOT/skills/review/SKILL.md")"

for flat in "$PLAN_FLAT" "$REVIEW_FLAT"; do
  # Why background is the default at all: the cap is a hard property of the tool.
  assert_file_contains "$flat" '10-minute foreground cap'
  assert_file_contains "$flat" 'hard ceiling of the Bash tool'
  # The barrier, and every impatience it forbids by name.
  assert_file_contains "$flat" 'hard synchronization barrier'
  assert_file_contains "$flat" 'you do not read the `VERDICT:` line'
  assert_file_contains "$flat" 'never a premature `tokens: n/a`'
  assert_file_contains "$flat" 'you launch no resume and no nudge'
  assert_file_contains "$flat" 'not even persisted'
  assert_file_contains "$flat" 'concurrent resume over a live turn'
done

# The exact legacy phrasings this change retires: a revert would restore them.
assert_not_contains "$PLAN_FLAT" 'the default 2-minute timeout will kill them'
assert_not_contains "$PLAN_FLAT" 'Resume the SAME thread (timeout: 600000)'
assert_not_contains "$REVIEW_FLAT" '(Bash timeout: 600000.)'
assert_not_contains "$REVIEW_FLAT" 'Resume the SAME reviewer thread (Bash timeout: 600000)'

# --- anti-regression: implement keeps the recommendation it already had ------
# The criterion extended here was implement's; if it disappeared there, the two
# skills would be documenting a rule with no origin.
IMPLEMENT_FLAT="$(flatten "$REPO_ROOT/skills/implement/SKILL.md")"
assert_file_contains "$IMPLEMENT_FLAT" 'run_in_background: true'
assert_file_contains "$IMPLEMENT_FLAT" '10-minute foreground cap'
assert_file_contains "$IMPLEMENT_FLAT" 'only for small plans'
assert_file_contains "$IMPLEMENT_FLAT" 'announce it clearly before doing anything else'

note "plan/review/implement SKILL.md — background default anchored per launch"
