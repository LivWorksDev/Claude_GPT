#!/usr/bin/env bash
# The generated shim is what actually runs on every status line refresh, so it
# is EXECUTED here in all four resolution configurations. It must always exit 0:
# the plugin's cache path changes on every update and tandem may be uninstalled
# entirely, and neither may leave the user without a status line.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# Install from a COPY of the plugin so the baked path can be deleted without
# touching the checkout.
PLUGIN="$SANDBOX/plugin"
mkdir -p "$PLUGIN"
cp -R "$REPO_ROOT/scripts" "$PLUGIN/scripts"

SHIM="$CLAUDE_CONFIG_DIR/tandem-statusline.sh"
run bash "$PLUGIN/scripts/statusline-install.sh" install
assert_rc 0 "install from the plugin copy"
assert_file_contains "$SHIM" "$PLUGIN/scripts/statusline.sh"

PAYLOAD="$(statusline_payload)"
render() {
  printf '%s' "$PAYLOAD" | bash "$SHIM" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0 "$1"
}

REG_DIR="$CLAUDE_CONFIG_DIR/plugins"
REG="$REG_DIR/installed_plugins.json"

# --- 1. TANDEM_STATUSLINE_SCRIPT wins over everything ------------------------
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "OVERRIDE LINE\\n"\n' \
  >"$SANDBOX/override.sh"
export TANDEM_STATUSLINE_SCRIPT="$SANDBOX/override.sh"
render "env override"
assert_file_contains "$OUT" "OVERRIDE LINE"

# An override pointing at nothing falls through instead of dying.
export TANDEM_STATUSLINE_SCRIPT="$SANDBOX/absent.sh"
render "override pointing at a missing file"
assert_file_contains "$OUT" "◈ Claude Fable 5"
unset TANDEM_STATUSLINE_SCRIPT

# --- 2. the installed-plugins registry ---------------------------------------
INSTALLED="$SANDBOX/installed"
mkdir -p "$INSTALLED/scripts" "$REG_DIR"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "REGISTRY LINE\\n"\n' \
  >"$INSTALLED/scripts/statusline.sh"
jq -n --arg p "$INSTALLED" \
  '{plugins: {"other@market": [{installPath: "/nope"}],
              "tandem@market": [{installPath: $p}]}}' >"$REG"
render "registry"
assert_file_contains "$OUT" "REGISTRY LINE"

# A registry entry whose path no longer has the script is skipped, not trusted.
jq -n '{plugins: {"tandem@market": [{installPath: "/gone"}]}}' >"$REG"
render "stale registry entry"
assert_file_contains "$OUT" "◈ Claude Fable 5"

# Registry entries for other plugins are ignored.
jq -n --arg p "$INSTALLED" '{plugins: {"notandem@market": [{installPath: $p}]}}' >"$REG"
render "registry without a tandem entry"
assert_file_contains "$OUT" "◈ Claude Fable 5"

# A corrupt registry is survivable.
printf 'not json\n' >"$REG"
render "corrupt registry"
assert_file_contains "$OUT" "◈ Claude Fable 5"
rm -f "$REG"

# --- 3. BAKED: the path the installer ran from -------------------------------
render "baked path"
assert_file_contains "$OUT" "◈ Claude Fable 5"
assert_file_contains "$OUT" "ctx 42%"

# --- 4. nothing resolves -> the built-in minimal render ----------------------
rm -rf "$PLUGIN"
render "tandem uninstalled"
assert_file_contains "$OUT" "◈ Claude Fable 5 · ctx 42%"
assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "minimal render is one line"

# The minimal render also copes with a payload that has no context window…
printf '%s' "$(statusline_payload '.context_window=__DELETE__')" \
  | bash "$SHIM" >"$OUT" 2>"$ERR"
assert_rc 0 "minimal render without a context window"
assert_file_contains "$OUT" "◈ Claude Fable 5"
assert_not_contains "$OUT" "ctx"

# …and with no usable payload at all.
printf 'garbage' | bash "$SHIM" >"$OUT" 2>"$ERR"
assert_rc 0 "minimal render with garbage on stdin"
printf '' | bash "$SHIM" >"$OUT" 2>"$ERR"
assert_rc 0 "minimal render with empty stdin"

# --- 5. without jq the shim still exits 0 ------------------------------------
MINBIN="$(make_minbin)"
printf '%s' "$PAYLOAD" | env PATH="$MINBIN" bash "$SHIM" >"$OUT" 2>"$ERR"
assert_rc 0 "no jq, nothing to resolve"
assert_eq "0" "$(wc -c <"$OUT" | tr -d ' ')" "no jq means no output"
