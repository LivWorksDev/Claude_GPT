#!/usr/bin/env bash
# hb_verdict: the LAST sentinel in the reply wins (a model that reconsiders
# mid-answer must not be scored on its first thought), the "VERDICT:" prefix and
# any amount of whitespace after it are stripped, and everything else is empty.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

verdict() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  hb_verdict "$1"
)

check() {
  # check <expected> <reply body…>
  local want="$1"
  shift
  printf '%s\n' "$@" >"$SANDBOX/reply.txt"
  assert_eq "$want" "$(verdict "$SANDBOX/reply.txt")" "verdict of [$*]"
}

check APPROVED 'VERDICT: APPROVED'
check REVISE 'VERDICT: REVISE'
check NEEDS_REWORK 'VERDICT: NEEDS_REWORK'
check REQUEST_CHANGES 'VERDICT: REQUEST_CHANGES'
check IMPLEMENTATION_COMPLETE 'IMPLEMENTATION_COMPLETE'
check IMPLEMENTATION_PARTIAL 'IMPLEMENTATION_PARTIAL'
check IMAGE_READY 'IMAGE_READY'
check IMAGE_BLOCKED 'IMAGE_BLOCKED'

# Whitespace variants after the colon.
check APPROVED 'VERDICT:  APPROVED'
check APPROVED "$(printf 'VERDICT:\tAPPROVED')"
check APPROVED 'VERDICT:APPROVED'

# Last one wins, across kinds.
check APPROVED 'VERDICT: NEEDS_REWORK' 'on reflection:' 'VERDICT:  APPROVED'
check NEEDS_REWORK 'VERDICT: APPROVED' 'wait, no' 'VERDICT: NEEDS_REWORK'
check IMAGE_BLOCKED 'IMAGE_READY' 'actually the backend is missing' 'IMAGE_BLOCKED'
check IMPLEMENTATION_PARTIAL 'IMPLEMENTATION_COMPLETE' 'IMPLEMENTATION_PARTIAL'

# Sentinels embedded mid-line are still found (models like to add prose).
check APPROVED 'The final answer is VERDICT: APPROVED — ship it.'

# No sentinel, unknown sentinel, empty file, missing file -> nothing.
check '' 'looks fine to me'
check '' 'VERDICT: MAYBE'
check '' ''
assert_eq "" "$(verdict "$SANDBOX/does-not-exist.txt")" "missing file"

# End to end: the verdict reaches the heartbeat.
make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=verdict-multi
run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" \
  '.status == "done" and .verdict == "APPROVED"'

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_REPLY="no sentinel in here"
run bash "$SCRIPTS/codex-start.sh" review demo2 "$SANDBOX/p.tpl"
assert_rc 0
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" '.verdict == null'
