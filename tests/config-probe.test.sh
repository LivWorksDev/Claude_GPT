#!/usr/bin/env bash
# scripts/config-probe.sh — the watchdog for a silently renamed config key.
# The CLI accepts an unknown `-c key=value` with rc 0, so a pin that stops
# existing stops applying without a word; the probe is what turns that silence
# into a red build.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROBE="$SCRIPTS/config-probe.sh"
KEYS="sandbox_workspace_write.network_access sandbox_workspace_write.writable_roots approval_policy approvals_reviewer web_search"

# --- every pinned key still rejects an invalid value --------------------------
export CODEX_STUB_CONFIG_REJECT="$KEYS"
run bash "$PROBE"
assert_rc 0 "all keys alive"
assert_file_contains "$OUT" "config probe OK"
for k in $KEYS; do
  assert_file_contains "$OUT" "ok    $k"
done

# It asked `codex debug`, never `codex exec`: a key that no longer exists must
# not be able to start a real turn. The stub only records argv for exec.
assert_no_file "$CODEX_STUB_LOG.argv.1"

# The throwaway CODEX_HOME is removed by the EXIT trap.
assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'tandem-probe.*' 2>/dev/null | head -n 1)" \
  "temporary CODEX_HOME cleaned up"

# --- one key renamed away: named, and the run fails --------------------------
export CODEX_STUB_CONFIG_REJECT="sandbox_workspace_write.network_access sandbox_workspace_write.writable_roots approval_policy approvals_reviewer"
run bash "$PROBE"
assert_rc 1 "web_search silently gone"
assert_file_contains "$OUT" "DRIFT web_search"
assert_file_contains "$OUT" "the key is gone or renamed"
assert_file_contains "$OUT" "config probe FAILED"
# The keys that survive are still reported as alive — the probe reports every
# key, it does not stop at the first casualty.
assert_file_contains "$OUT" "ok    approval_policy"

# --- nothing at all is rejected any more --------------------------------------
export CODEX_STUB_CONFIG_REJECT=""
run bash "$PROBE"
assert_rc 1 "every key gone"
for k in $KEYS; do
  assert_file_contains "$OUT" "DRIFT $k"
done

# --- the probe blames itself when the subcommand is the thing that moved -----
export CODEX_STUB_CONFIG_REJECT="$KEYS"
export CODEX_STUB_DEBUG_RC=2
run bash "$PROBE"
assert_rc 1 "debug prompt-input unusable"
assert_file_contains "$OUT" "the probe itself is broken"
assert_not_contains "$OUT" "DRIFT web_search"
unset CODEX_STUB_DEBUG_RC

# --- a broken codex install is a dependency error, not drift -----------------
export CODEX_STUB_SCENARIO=version-fail
run bash "$PROBE"
assert_rc 3 "codex cannot run"
