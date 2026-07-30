#!/usr/bin/env bash
# The heartbeat is shared by every role, so reset only drops it when it
# describes the exact (role, target) being reset — another role's turn may
# legitimately still be on screen.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
SD="$(state_dir review)"
mkdir -p "$SD"
KEY="$(tkey auth)"

reset_with_hb() {
  # reset_with_hb <hb-role> <hb-target> ; leaves $RC and the heartbeat state
  printf 'thr\n' >"$SD/$KEY.thread"
  write_hb "$HB" "role=$1" "target=$2" "status=done"
  run bash "$SCRIPTS/codex-reset.sh" review auth
  assert_rc 0 "reset with heartbeat role=$1 target=$2"
}

# Same role AND same target -> dropped.
reset_with_hb review auth
assert_no_file "$HB"

# Same target, different role -> kept.
reset_with_hb implement auth
assert_file "$HB"
assert_json "$HB" '.role == "implement" and .target == "auth"'

# Same role, different target -> kept.
reset_with_hb review billing
assert_file "$HB"
assert_json "$HB" '.target == "billing"'

# Neither -> kept.
reset_with_hb image other
assert_file "$HB"

# A heartbeat that is not valid JSON is left alone rather than deleted blindly.
printf 'not json at all\n' >"$HB"
printf 'thr\n' >"$SD/$KEY.thread"
run bash "$SCRIPTS/codex-reset.sh" review auth
assert_rc 0 "corrupt heartbeat"
assert_file "$HB"
assert_file_contains "$HB" "not json at all"

# No heartbeat at all is not an error.
rm -f "$HB"
run bash "$SCRIPTS/codex-reset.sh" review auth
assert_rc 0 "absent heartbeat"
assert_no_file "$HB"
