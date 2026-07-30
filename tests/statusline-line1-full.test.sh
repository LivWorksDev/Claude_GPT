#!/usr/bin/env bash
# Line 1: model, effort, thinking marker, context gauge with its urgency
# thresholds, cost, directory and branch.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

GREEN=$'\033[38;5;78m'
YELLOW=$'\033[38;5;179m'
RED=$'\033[38;5;168m'

render() {
  statusline_payload "$@" | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  return 0
}

# --- the full line ----------------------------------------------------------
REPO="$SANDBOX/work"
make_repo "$REPO"
printf 'x\n' >"$REPO/f.txt"
commit_all "$REPO"
git -C "$REPO" checkout -q -b feature/auth

render ".workspace.current_dir=$REPO" ".workspace.project_dir=$REPO" \
  '.thinking.enabled=true'
assert_rc 0
assert_file_contains "$OUT" "◈ Claude Fable 5"
assert_file_contains "$OUT" "high"
assert_file_contains "$OUT" "✳"
assert_file_contains "$OUT" "ctx 42% ▓▓▓▓░░░░░░"
assert_file_contains "$OUT" '$1.24'
assert_file_contains "$OUT" "work"
assert_file_contains "$OUT" "⑂ feature/auth"

# --- the gauge and its colour thresholds ------------------------------------
gauge() {
  # gauge <percentage> <expected bar> <expected colour>
  render ".context_window.used_percentage=$1"
  assert_rc 0 "gauge $1%"
  assert_file_contains "$OUT" "ctx ${1%%.*}% $2"
  assert_file_contains "$OUT" "$3"
}
gauge 0    '░░░░░░░░░░' "$GREEN"
gauge 5    '░░░░░░░░░░' "$GREEN"
gauge 10   '▓░░░░░░░░░' "$GREEN"
gauge 59   '▓▓▓▓▓░░░░░' "$GREEN"
gauge 60   '▓▓▓▓▓▓░░░░' "$YELLOW"
gauge 79   '▓▓▓▓▓▓▓░░░' "$YELLOW"
gauge 80   '▓▓▓▓▓▓▓▓░░' "$RED"
gauge 100  '▓▓▓▓▓▓▓▓▓▓' "$RED"
# Over 100 clamps to a full bar instead of overflowing the line.
gauge 130  '▓▓▓▓▓▓▓▓▓▓' "$RED"

# A non-numeric percentage degrades to 0 rather than breaking the arithmetic.
render '.context_window.used_percentage="oops"'
assert_rc 0 "non-numeric percentage"
assert_file_contains "$OUT" "ctx 0% ░░░░░░░░░░"

# An absent context window drops the gauge entirely.
render '.context_window=__DELETE__'
assert_rc 0 "no context window"
assert_not_contains "$OUT" "ctx "

# --- cost --------------------------------------------------------------------
render '.cost.total_cost_usd=0'
assert_rc 0
assert_not_contains "$OUT" '$'
render '.cost.total_cost_usd=12.3456'
assert_file_contains "$OUT" '$12.35'
render '.cost=__DELETE__'
assert_rc 0 "no cost object"
assert_not_contains "$OUT" '$'

# --- model / effort fallbacks ------------------------------------------------
render '.model=__DELETE__'
assert_rc 0 "no model object"
assert_file_contains "$OUT" "◈ ?"
render '.model.display_name=__DELETE__' '.model.id=claude-opus-5'
assert_file_contains "$OUT" "◈ claude-opus-5"
render '.effort=__DELETE__'
assert_rc 0 "no effort"
assert_not_contains "$OUT" "high"
render '.thinking.enabled=false'
assert_not_contains "$OUT" "✳"

# --- git: detached HEAD prints no branch, and a non-repo prints no branch ----
git -C "$REPO" checkout -q --detach
render ".workspace.current_dir=$REPO"
assert_rc 0 "detached HEAD"
assert_file_contains "$OUT" "work"
assert_not_contains "$OUT" "⑂"

mkdir -p "$SANDBOX/plain"
render ".workspace.current_dir=$SANDBOX/plain"
assert_rc 0 "not a git repo"
assert_file_contains "$OUT" "plain"
assert_not_contains "$OUT" "⑂"

# --- NO_COLOR strips every escape -------------------------------------------
export NO_COLOR=1
render ".workspace.current_dir=$REPO"
assert_rc 0 "NO_COLOR"
assert_no_escapes "$OUT"
assert_file_contains "$OUT" "◈ Claude Fable 5"
unset NO_COLOR

# Line 1 is always exactly one line when there is no heartbeat.
render
assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "line count without a heartbeat"
