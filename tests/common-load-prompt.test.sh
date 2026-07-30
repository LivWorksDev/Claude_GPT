#!/usr/bin/env bash
# load_prompt: single left-to-right pass, values inserted LITERALLY.
# Two hazards are pinned here:
#   - sed/awk metacharacters in a diff ('&', '\1', '$\') must survive verbatim;
#   - a value that itself contains '{{NOTES}}' (tandem editing its own
#     templates) must NOT be re-scanned and expanded.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

render() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  TARGET="$1" EXTRA="$2" NOTES="$3"
  load_prompt "$4"
)

NASTY='a & b \1 $\ c ${x} `cmd` %s'

tpl "$SANDBOX/t.tpl" \
  'T=[{{TARGET}}]' \
  'E=[{{EXTRA}}]' \
  'N=[{{NOTES}}]' \
  'again T=[{{TARGET}}]'

render "$NASTY" 'x{{NOTES}}y' 'NN' "$SANDBOX/t.tpl" >"$SANDBOX/out.txt"

assert_file_contains "$SANDBOX/out.txt" "T=[$NASTY]"
assert_file_contains "$SANDBOX/out.txt" 'E=[x{{NOTES}}y]'
assert_file_contains "$SANDBOX/out.txt" 'N=[NN]'
assert_file_contains "$SANDBOX/out.txt" "again T=[$NASTY]"

# The placeholder that came in through EXTRA is still there, unexpanded.
assert_eq "1" "$(grep -c -F '{{NOTES}}' "$SANDBOX/out.txt")" "unexpanded placeholders"

# Empty values erase the placeholder rather than leaving it visible.
render '' '' '' "$SANDBOX/t.tpl" >"$SANDBOX/empty.txt"
assert_file_contains "$SANDBOX/empty.txt" 'T=[]'
assert_file_contains "$SANDBOX/empty.txt" 'E=[]'
assert_file_contains "$SANDBOX/empty.txt" 'N=[]'

# Order inside one line is left to right, whatever order the loop tries them in.
tpl "$SANDBOX/order.tpl" '{{NOTES}}|{{EXTRA}}|{{TARGET}}|{{EXTRA}}'
render TT EE NN "$SANDBOX/order.tpl" >"$SANDBOX/order.txt"
assert_file_contains "$SANDBOX/order.txt" 'NN|EE|TT|EE'

# A template with no placeholders is passed through unchanged.
tpl "$SANDBOX/plain.tpl" 'nothing to expand here' 'second line'
render TT EE NN "$SANDBOX/plain.tpl" >"$SANDBOX/plain.txt"
assert_file_contains "$SANDBOX/plain.txt" 'nothing to expand here'
assert_file_contains "$SANDBOX/plain.txt" 'second line'

# Multi-line values keep their line breaks.
render "$(printf 'line1\nline2')" EE NN "$SANDBOX/t.tpl" >"$SANDBOX/multi.txt"
assert_file_contains "$SANDBOX/multi.txt" 'T=[line1'
assert_file_contains "$SANDBOX/multi.txt" 'line2]'

# A missing template is a usage error, not an empty prompt.
run bash -c '. "$1"; load_prompt "$2"' _ "$SCRIPTS/_common.sh" "$SANDBOX/nope.tpl"
assert_rc 64 "missing template"
assert_file_contains "$ERR" "prompt template not found:"

# End to end: the bytes codex actually received.
make_repo "$CLAUDE_PROJECT_DIR"
printf '%s\n' "$NASTY" >"$SANDBOX/extra.txt"
printf 'plain notes\n' >"$SANDBOX/notes.txt"
export CODEX_STUB_SCENARIO=ok
run bash "$SCRIPTS/codex-start.sh" review "$NASTY" "$SANDBOX/t.tpl" \
  "$SANDBOX/extra.txt" "$SANDBOX/notes.txt"
assert_rc 0
assert_file_contains "$(stub_stdin 1)" "T=[$NASTY]"
assert_file_contains "$(stub_stdin 1)" "E=[$NASTY]"
assert_file_contains "$(stub_stdin 1)" "N=[plain notes]"
