#!/usr/bin/env bash
# statusline-install.sh writes into the USER's config, so every refusal has to
# be exact: it never clobbers a foreign statusLine without --force, and it never
# touches anything at all when settings.json is corrupt.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SHIM="$CLAUDE_CONFIG_DIR/tandem-statusline.sh"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
BACKUP="$SETTINGS.tandem-backup"
INSTALL="$SCRIPTS/statusline-install.sh"

# --- status on a virgin config ----------------------------------------------
run bash "$INSTALL" status
assert_rc 0 "status, nothing installed"
assert_file_contains "$OUT" "shim:     not installed"
assert_file_contains "$OUT" "settings: no statusLine configured"
assert_file_contains "$OUT" "source:   $REPO_ROOT/scripts/statusline.sh"

# --- install ------------------------------------------------------------------
run bash "$INSTALL" install
assert_rc 0 "install"
assert_file "$SHIM"
[ -x "$SHIM" ] || fail "the shim is not executable"
assert_file_contains "$SHIM" "tandem status line shim"
assert_file_contains "$SHIM" "$REPO_ROOT/scripts/statusline.sh"
assert_json "$SETTINGS" '.statusLine.type == "command"'
assert_json "$SETTINGS" '.statusLine.command == "'"$SHIM"'"'
assert_json "$SETTINGS" '.statusLine.refreshInterval == 2'
assert_file "$BACKUP"
assert_file_contains "$OUT" "tandem: status line installed."
assert_file_contains "$OUT" "Restart Claude Code"

run bash "$INSTALL" status
assert_rc 0 "status after install"
assert_file_contains "$OUT" "shim:     present"
assert_file_contains "$OUT" "settings: statusLine -> tandem shim"

# --- reinstalling is idempotent and preserves unrelated settings -------------
jq '.model = "opus" + ""' "$SETTINGS" >"$SANDBOX/s.json" && mv "$SANDBOX/s.json" "$SETTINGS"
run bash "$INSTALL" install
assert_rc 0 "reinstall"
assert_json "$SETTINGS" '.statusLine.command == "'"$SHIM"'"'
assert_json "$SETTINGS" '.model == "opus"'

# --- a foreign statusLine is refused with exit 2 -----------------------------
jq '.statusLine = {type:"command", command:"/opt/other/line.sh"}' "$SETTINGS" \
  >"$SANDBOX/s.json" && mv "$SANDBOX/s.json" "$SETTINGS"
cp "$SETTINGS" "$SANDBOX/settings.before"
rm -f "$SHIM"

run bash "$INSTALL" install
assert_rc 2 "foreign statusLine"
assert_file_contains "$ERR" "already has a statusLine that is not tandem's"
assert_file_contains "$ERR" "re-run with --force to replace it"
assert_no_file "$SHIM"
if ! cmp -s "$SETTINGS" "$SANDBOX/settings.before"; then
  fail "settings.json was modified by a refused install"
fi

# --- --force replaces it and keeps a backup ----------------------------------
run bash "$INSTALL" install --force
assert_rc 0 "install --force"
assert_json "$SETTINGS" '.statusLine.command == "'"$SHIM"'"'
assert_file "$SHIM"
assert_json "$BACKUP" '.statusLine.command == "/opt/other/line.sh"'

# --- a corrupt settings.json changes NOTHING ---------------------------------
# Regression: write_shim used to run BEFORE the validation, so the shim was
# rewritten while the die() claimed "nothing was changed".
rm -f "$SHIM"
printf '{ this is not json\n' >"$SETTINGS"
cp "$SETTINGS" "$SANDBOX/corrupt.before"

run bash "$INSTALL" install
assert_rc 1 "corrupt settings"
assert_file_contains "$ERR" "is not valid JSON — fix it by hand first (nothing was changed)"
assert_no_file "$SHIM"
if ! cmp -s "$SETTINGS" "$SANDBOX/corrupt.before"; then
  fail "a corrupt settings.json was modified"
fi

# …and with --force too: --force is about foreign status lines, not about
# overwriting broken JSON.
run bash "$INSTALL" install --force
assert_rc 1 "corrupt settings with --force"
assert_no_file "$SHIM"
if ! cmp -s "$SETTINGS" "$SANDBOX/corrupt.before"; then
  fail "a corrupt settings.json was modified under --force"
fi

# --- uninstall ----------------------------------------------------------------
printf '{}\n' >"$SETTINGS"
run bash "$INSTALL" install
assert_rc 0 "reinstall over a clean settings"
run bash "$INSTALL" uninstall
assert_rc 0 "uninstall"
assert_no_file "$SHIM"
assert_json "$SETTINGS" 'has("statusLine") | not'
assert_file_contains "$OUT" "statusLine entry removed"
assert_file_contains "$OUT" "shim removed"

# Uninstalling twice is harmless.
run bash "$INSTALL" uninstall
assert_rc 0 "uninstall twice"
assert_file_contains "$OUT" "not tandem's — left untouched"

# A foreign statusLine is left alone by uninstall.
jq '.statusLine = {type:"command", command:"/opt/other/line.sh"}' "$SETTINGS" \
  >"$SANDBOX/s.json" && mv "$SANDBOX/s.json" "$SETTINGS"
run bash "$INSTALL" uninstall
assert_rc 0 "uninstall with a foreign statusLine"
assert_json "$SETTINGS" '.statusLine.command == "/opt/other/line.sh"'
run bash "$INSTALL" status
assert_file_contains "$OUT" "statusLine present but NOT tandem's"

# --- usage ---------------------------------------------------------------------
# `--force` alone is not an action: it lands in $1 and must be rejected.
run bash "$INSTALL" --force
assert_rc 64 "--force alone"
assert_file_contains "$ERR" "usage: statusline-install.sh [install|uninstall|status] [--force]"

run bash "$INSTALL" reinstall
assert_rc 64 "unknown action"

# jq is a hard dependency here.
MINBIN="$(make_minbin)"
run env PATH="$MINBIN" bash "$INSTALL" status
assert_rc 3 "jq missing"
assert_file_contains "$ERR" "jq not found"
