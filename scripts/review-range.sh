#!/usr/bin/env bash
# tandem — prepare an OUT-OF-PIPELINE review of an ALREADY-COMMITTED range.
#
# usage: review-range.sh <label> <range>
#   label   [A-Za-z0-9._-], never starting with '-' or '.' (the charset of
#           plan-approve.sh: the label is a path component and a thread key).
#           It is also the LINEAGE of the review: the same label means the same
#           work, re-reviewed by the same thread.
#   range   <A>..<B> or <A>...<B>. Both endpoints are RESOLVED to full shas and
#           the specification handed to git is REBUILT from those shas — the
#           user's text never reaches a git command as a revision argument.
#
# What it prints on stdout, one parseable line each (all paths ABSOLUTE):
#   TARGET:        range-review-<label>   — the review thread's target
#   ENDPOINTS:     <shaA> <shaB>          — both endpoints, fully resolved
#   CONTEXT_FILE:  the context to hand to the reviewer
#   LOG_FILE:      .tandem/log/ranges/<label>.md
#   WORK_ROOT:     the MAIN checkout (this mode never runs the skill's Step 0,
#                  so the launch's TANDEM_CODEX_CWD comes from here)
# Everything else — progress, failures, git's own stderr — goes to stderr.
#
# Two namespaces are kept disjoint BY CONSTRUCTION, never by convention:
#   - the thread target `range-review-<label>` can never equal the pipeline's
#     `cr-<slug>`, whatever legal slug the pipeline uses (`cr-range-foo` is not
#     `range-review-foo`);
#   - the log lives in the `log/ranges/` SUBDIRECTORY, outside the top-level
#     `log/*.md` scan that tandem-status.sh reads as one pipeline run per file,
#     so a range is invisible to status instead of being listed as a bogus run.
#
# There is no clean-tree gate (this mode never touches the working tree) and no
# heartbeat of its own (the codex turn writes it).
#
# The context is published ATOMICALLY: it is built in a temporary file in the
# same directory and moved into place only once it is complete, and every git or
# filesystem failure is translated into exit 65 explicitly. A retry can never
# consume a truncated context, and a failed run leaves no half-written one.
#
# exit codes: 0 ok
#             2 the range is EMPTY — nothing to review, no turn spent
#             3 missing dependency
#             64 usage error (label, range shape, endpoint shape)
#             65 git or state failure (git's own stderr is left visible)

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

[ $# -eq 2 ] || die "usage: review-range.sh <label> <range>" 64
LABEL="$1"
RANGE="$2"

[ -n "$LABEL" ] || die "review-range.sh: empty label" 64
# The label becomes a path component and a state key. Anything outside this
# charset is rejected instead of escaped — the same rule plan-approve.sh applies
# to a slug.
case "$LABEL" in
  *[!A-Za-z0-9._-]*) die "invalid label '$LABEL' — use [A-Za-z0-9._-] only" 64 ;;
  [-.]*) die "invalid label '$LABEL' — must not start with '-' or '.'" 64 ;;
esac
[ -n "$RANGE" ] || die "review-range.sh: empty range — expected <A>..<B> or <A>...<B>" 64

command -v git >/dev/null 2>&1 || die "git not found in PATH" 3

# --- the range: parsed here, never handed to git verbatim --------------------
# A run of two or more dots is a separator candidate; single dots belong to the
# endpoints (`v1.0..v2.0` is one range, not three). Exactly one candidate, of
# length 2 or 3, is a range — anything else is a usage error rather than a guess.
EP_A=""
EP_B=""
SEP=""
parse_range() {
  local s="$1" n i c runlen runstart found sep_start sep_len
  n="${#s}"
  i=0
  runlen=0
  runstart=0
  found=0
  sep_start=0
  sep_len=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$c" = "." ]; then
      if [ "$runlen" -eq 0 ]; then runstart="$i"; fi
      runlen=$((runlen + 1))
    else
      if [ "$runlen" -ge 2 ]; then
        found=$((found + 1))
        sep_start="$runstart"
        sep_len="$runlen"
      fi
      runlen=0
    fi
    i=$((i + 1))
  done
  if [ "$runlen" -ge 2 ]; then
    found=$((found + 1))
    sep_start="$runstart"
    sep_len="$runlen"
  fi
  [ "$found" -eq 1 ] \
    || die "'$s' is not a range — expected exactly one '..' or '...' separator" 64
  case "$sep_len" in
    2 | 3) : ;;
    *) die "'$s' carries a $sep_len-dot separator — expected '..' or '...'" 64 ;;
  esac
  EP_A="${s:0:$sep_start}"
  EP_B="${s:$((sep_start + sep_len))}"
  if [ "$sep_len" -eq 3 ]; then SEP="..."; else SEP=".."; fi
  return 0
}

check_endpoint() {
  # check_endpoint <name> <value>
  [ -n "$2" ] \
    || die "the $1 endpoint of '$RANGE' is empty — expected <A>..<B> or <A>...<B>" 64
  case "$2" in
    -*) die "the $1 endpoint '$2' has the shape of an option — refusing to pass it to git" 64 ;;
    *[[:cntrl:]]*) die "the $1 endpoint of '$RANGE' carries control characters" 64 ;;
  esac
  return 0
}

parse_range "$RANGE"
check_endpoint A "$EP_A"
check_endpoint B "$EP_B"

# --- orientation: the MAIN checkout anchors every git command ----------------
# Same derivation worktree-root.sh and state_init use: the range is reviewed
# against the main checkout, which is also the WORK_ROOT the launch is pinned to.
COMMON="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$COMMON" ] || die "not inside a git repository: $PWD" 65
case "$COMMON" in /*) : ;; *) COMMON="$PWD/$COMMON" ;; esac
MAIN="$(CDPATH='' cd -- "$(dirname -- "$COMMON")" 2>/dev/null && pwd)" \
  || die "cannot resolve the main checkout from $COMMON" 65

# `--verify <ep>^{commit}` without -q on purpose: when it fails, git's own
# explanation is the most useful thing this script can show.
SHA_A="$(git -C "$MAIN" rev-parse --verify "$EP_A^{commit}")" \
  || die "cannot resolve the A endpoint '$EP_A' to a commit in $MAIN" 65
SHA_B="$(git -C "$MAIN" rev-parse --verify "$EP_B^{commit}")" \
  || die "cannot resolve the B endpoint '$EP_B' to a commit in $MAIN" 65

# THE specification: rebuilt from the resolved shas, never the user's text.
SPEC="$SHA_A$SEP$SHA_B"
SHORT_A="${SHA_A:0:7}"
SHORT_B="${SHA_B:0:7}"

# --- state bootstrap: a project with no .tandem/ works on the first use -------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$MAIN}"
mkdir -p "$PROJECT_DIR/.tandem/tmp" "$PROJECT_DIR/.tandem/log/ranges" 2>/dev/null \
  || die "cannot create the tandem state directories under $PROJECT_DIR/.tandem" 65
STATE_ROOT="$(CDPATH='' cd -- "$PROJECT_DIR/.tandem" && pwd)" \
  || die "cannot resolve the tandem state root under $PROJECT_DIR" 65
# Never overwrite an ignore policy that is already there: the user may have
# edited it to check one artefact in. Same guard state_init uses.
[ -f "$STATE_ROOT/.gitignore" ] || printf '*\n' >"$STATE_ROOT/.gitignore" \
  || die "cannot write $STATE_ROOT/.gitignore" 65

TMP_DIR="$STATE_ROOT/tmp"
LOG_FILE="$STATE_ROOT/log/ranges/$LABEL.md"
CONTEXT_FILE="$TMP_DIR/range-$LABEL-context.md"
TARGET="range-review-$LABEL"

[ -f "$LOG_FILE" ] || printf '# tandem range review — %s\n\n' "$LABEL" >"$LOG_FILE" \
  || die "cannot write the range log $LOG_FILE" 65

# --- is there anything to review at all? -------------------------------------
# `git diff --quiet` answers 0 (no difference), 1 (difference) or something else
# (a real failure). All three are handled: an empty range is an honest stop, and
# a broken repository is never mistaken for one.
set +e
git -C "$MAIN" diff --quiet "$SPEC" --
DIFF_RC=$?
set -e
case "$DIFF_RC" in
  0)
    printf 'tandem: %s..%s is empty — nothing to review (no turn spent)\n' \
      "$SHORT_A" "$SHORT_B" >&2
    exit 2
    ;;
  1) : ;;
  *) die "git diff failed on $SPEC (exit $DIFF_RC)" 65 ;;
esac

# --- the context, built atomically -------------------------------------------
CTX_TMP=""
cleanup() {
  if [ -n "$CTX_TMP" ]; then rm -f "$CTX_TMP" 2>/dev/null || true; fi
  return 0
}
trap 'cleanup' EXIT

CTX_TMP="$(mktemp "$TMP_DIR/.range-$LABEL-context.md.XXXXXX" 2>/dev/null)" \
  || die "cannot create a temporary context file under $TMP_DIR" 65

{
  printf '# Range review — %s\n\n' "$LABEL"
  printf 'This is an ALREADY-COMMITTED range, reviewed OUT of the tandem pipeline.\n'
  printf 'There is no uncommitted work here and nothing will be committed as a\n'
  printf 'result of this review: the verdict and the findings ARE the deliverable.\n\n'
  printf 'RANGE:      %s\n' "$SPEC"
  printf 'ENDPOINT A: %s  (%s)\n' "$SHORT_A" "$EP_A"
  printf 'ENDPOINT B: %s  (%s)\n' "$SHORT_B" "$EP_B"
  printf 'REPOSITORY: %s\n\n' "$MAIN"
} >"$CTX_TMP" || die "cannot write the context file under $TMP_DIR" 65

# The commit list is always the two-dot one: the commits contained in B and not
# in A, which is what "what this range adds" means in both modes.
{
  printf 'COMMITS:\n'
} >>"$CTX_TMP" || die "cannot write the context file under $TMP_DIR" 65
git -C "$MAIN" --no-pager log --no-color --oneline "$SHA_A..$SHA_B" >>"$CTX_TMP" \
  || die "git log failed for $SHA_A..$SHA_B" 65

{
  printf '\nSTAT:\n'
} >>"$CTX_TMP" || die "cannot write the context file under $TMP_DIR" 65
git -C "$MAIN" --no-pager diff --no-color --stat "$SPEC" -- >>"$CTX_TMP" \
  || die "git diff --stat failed on $SPEC" 65

# The mandatory reading rule. The diff carries hunks only, and the checkout can
# sit on a completely different version (reviewing a feature range from main is
# the normal case), so every file read is anchored at B instead of at the
# working tree.
{
  printf '\nMANDATORY — anchor every file read at B (%s), never at the checkout:\n' "$SHA_B"
  printf '  git show %s:<path>              # the file AS IT IS at B\n' "$SHA_B"
  printf '  git ls-tree -r --name-only %s   # the tree AS IT IS at B\n' "$SHA_B"
  printf 'The working tree of this repository may be on another version entirely.\n'
  printf 'The DIFF below is AUTHORITATIVE for what changed; the files at B are the\n'
  printf 'truth about the code those changes live in.\n\n'
  printf 'DIFF:\n'
} >>"$CTX_TMP" || die "cannot write the context file under $TMP_DIR" 65

# Last section of the file on purpose: the diff is appended verbatim and nothing
# follows it, so `DIFF:` marks it unambiguously.
git -C "$MAIN" --no-pager diff --no-color "$SPEC" -- >>"$CTX_TMP" \
  || die "git diff failed on $SPEC" 65

# A directory (or any non-regular file) squatting on the destination would make
# `mv -f` drop the temporary INSIDE it and return success — a false publication.
if [ -e "$CONTEXT_FILE" ] && [ ! -f "$CONTEXT_FILE" ]; then
  die "the context path $CONTEXT_FILE exists and is not a regular file" 65
fi
mv -f "$CTX_TMP" "$CONTEXT_FILE" 2>/dev/null \
  || die "cannot publish the context file $CONTEXT_FILE" 65
CTX_TMP=""
[ -f "$CONTEXT_FILE" ] \
  || die "the published context $CONTEXT_FILE is not a regular file" 65

printf 'tandem: range review prepared — %s (%s..%s)\n' "$TARGET" "$SHORT_A" "$SHORT_B" >&2

printf 'TARGET: %s\n' "$TARGET"
printf 'ENDPOINTS: %s %s\n' "$SHA_A" "$SHA_B"
printf 'CONTEXT_FILE: %s\n' "$CONTEXT_FILE"
printf 'LOG_FILE: %s\n' "$LOG_FILE"
printf 'WORK_ROOT: %s\n' "$MAIN"
