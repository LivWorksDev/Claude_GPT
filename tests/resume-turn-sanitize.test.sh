#!/usr/bin/env bash
# The .turn counter is attacker-adjacent state (a file on disk). Every shape it
# can take must produce a number, never a crash.
#
# '08' is the interesting one: it passes the all-digits sanitizer and then used
# to blow up in $((TURN + 1)) with bash's octal "value too great for base" — a
# raw error, before hb_begin, with no die() and no heartbeat. 10# fixed it.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "continue {{TARGET}}"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_turns

seed_thread review demo thr_turns
KEY="$(tkey demo)"
SD="$(state_dir review)"

turn_becomes() {
  # turn_becomes <content-of-.turn> <expected-new-turn>
  local want="$2"
  printf '%s' "$1" >"$SD/$KEY.turn"
  run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
  assert_rc 0 "resume with .turn=[$1]"
  assert_eq "$want" "$(cat "$SD/$KEY.turn")" ".turn=[$1] -> next turn"
  assert_file "$SD/$KEY.t$want.reply.txt"
}

# The regression: zero-padded values are base 10, not octal.
turn_becomes '08
' 9
turn_becomes '09
' 10
# …and the rest of the shapes.
turn_becomes '3
' 4
turn_becomes '0
' 1
turn_becomes '' 1
turn_becomes 'abc
' 1
turn_becomes ' 7
' 1
turn_becomes '-2
' 1
turn_becomes '007
' 8

# A missing .turn file starts at 1.
rm -f "$SD/$KEY.turn"
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "missing .turn"
assert_eq "1" "$(cat "$SD/$KEY.turn")" "missing .turn -> 1"

# Nothing ever leaked a raw bash arithmetic error.
assert_not_contains "$ERR" "value too great for base"
