#!/usr/bin/env bash
# codex-reset.sh removes one target's files and nothing else. The prefix is
# "<key>." — 'auth' must never take 'auth-v2' with it.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
SD="$(state_dir review)"
mkdir -p "$SD"

AUTH="$(tkey auth)"
AUTHV2="$(tkey auth-v2)"
OTHER="$(tkey billing)"

seed() {
  local k="$1"
  printf 'thr_%s\n' "$k" >"$SD/$k.thread"
  printf '3\n' >"$SD/$k.turn"
  printf 'last reply\n' >"$SD/$k.last.txt"
  printf 'prompt\n' >"$SD/$k.t1.prompt.txt"
  printf 'reply\n' >"$SD/$k.t1.reply.txt"
  printf '{}\n' >"$SD/$k.t1.events.ndjson"
  printf 'err\n' >"$SD/$k.t1.events.ndjson.stderr"
}
seed "$AUTH"
seed "$AUTHV2"
seed "$OTHER"
# A file whose name is the bare key with no dot must survive: the glob is
# "<key>.*", not "<key>*".
printf 'not state\n' >"$SD/${AUTH}_sidecar"

run bash "$SCRIPTS/codex-reset.sh" review auth
assert_rc 0
assert_file_contains "$OUT" 'tandem: state reset for "auth" (role review).'

for suffix in thread turn last.txt t1.prompt.txt t1.reply.txt t1.events.ndjson t1.events.ndjson.stderr; do
  assert_no_file "$SD/$AUTH.$suffix"
  assert_file "$SD/$AUTHV2.$suffix"
  assert_file "$SD/$OTHER.$suffix"
done
assert_file "$SD/${AUTH}_sidecar"

# Another role's state for the same label is a different namespace.
ISD="$(state_dir implement)"
mkdir -p "$ISD"
printf 'thr_impl\n' >"$ISD/$AUTHV2.thread"
run bash "$SCRIPTS/codex-reset.sh" review auth-v2
assert_rc 0
assert_no_file "$SD/$AUTHV2.thread"
assert_file "$ISD/$AUTHV2.thread"

# Resetting something that was never started is success, not an error.
run bash "$SCRIPTS/codex-reset.sh" review never-existed
assert_rc 0 "reset of unknown target"
assert_file_contains "$OUT" 'state reset for "never-existed"'

# Unknown role and unusable label are still usage errors.
run bash "$SCRIPTS/codex-reset.sh" auditor auth
assert_rc 64 "unknown role"
run bash "$SCRIPTS/codex-reset.sh" review "..."
assert_rc 64 "empty state key"
