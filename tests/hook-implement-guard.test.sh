#!/usr/bin/env bash
# PreToolUse anti-install guard, including the registered plugin entry point.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
assert_file "$HOOKS_JSON"
assert_json "$HOOKS_JSON" '
  (.hooks | keys) == ["PreToolUse"] and
  (.hooks.PreToolUse | length) == 1 and
  .hooks.PreToolUse[0].matcher == "Bash" and
  (.hooks.PreToolUse[0].hooks | length) == 1 and
  .hooks.PreToolUse[0].hooks[0] == {
    "type":"command",
    "command":"${CLAUDE_PLUGIN_ROOT}/scripts/hook-implement-guard.sh"
  }
'

ENTRY="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS_JSON")"
ENTRY="${ENTRY/'${CLAUDE_PLUGIN_ROOT}'/$REPO_ROOT}"
[ -x "$ENTRY" ] || fail "configured hook is not executable: $ENTRY"

run_payload() {
  local payload="$1"
  RC=0
  printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$ENTRY" \
    >"$OUT" 2>"$ERR" || RC=$?
  return 0
}

payload() {
  jq -nc --arg command "$1" '{tool_input:{command:$command}}'
}

AUDIT_DIR="$CLAUDE_PROJECT_DIR/.tandem/state/implement-audit"
mkdir -p "$AUDIT_DIR"

# Pattern match alone never blocks without a live-attempt guard.
run_payload "$(payload 'pnpm install')"
assert_rc 0 "mutator without guard"

printf 'active\n' >"$AUDIT_DIR/demo.guard"

# Every mutator token in the closed grammar, bare yarn, global options,
# environment prefixes and a later shell segment are blocked.
for command in \
  'pnpm install' \
  'npm i' \
  'npm ci' \
  'pnpm add x' \
  'npm remove x' \
  'npm rm x' \
  'npm uninstall x' \
  'npm un x' \
  'npm update' \
  'pnpm up' \
  'yarn upgrade' \
  'yarn' \
  'npm --prefix app install' \
  'pnpm -C app add x' \
  'yarn --cwd app' \
  'NODE_ENV=production pnpm install' \
  'git status && pnpm install'; do
  run_payload "$(payload "$command")"
  assert_rc 2 "guarded mutator: $command"
  assert_file_contains "$ERR" 'active implement attempt "demo"'
  assert_file_contains "$ERR" 'Wait for Step 5'
  assert_file_contains "$ERR" 'exact reset protocol'
done

# Non-mutating package-manager commands and unrelated Bash always pass.
for command in 'npm test' 'npm run build' 'pnpm exec vitest' 'git status'; do
  run_payload "$(payload "$command")"
  assert_rc 0 "non-mutator: $command"
done

# Without jq the raw-payload fallback remains narrowly fail-closed for a match.
NOJQ="$SANDBOX/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v bash)" "$NOJQ/bash"
ln -s "$(command -v cat)" "$NOJQ/cat"
RC=0
printf '%s' '{"tool_input":{"command":"pnpm install"}}' \
  | env PATH="$NOJQ" CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" bash "$ENTRY" \
    >"$OUT" 2>"$ERR" || RC=$?
assert_rc 2 "hook fallback without jq"
assert_file_contains "$ERR" 'active implement attempt "demo"'

# An unreadable marker still blocks a command that already matched.
rm "$AUDIT_DIR/demo.guard"
printf 'unreadable\n' >"$AUDIT_DIR/opaque.guard"
chmod 000 "$AUDIT_DIR/opaque.guard"
run_payload "$(payload 'npm ci')"
assert_rc 2 "unreadable guard"
assert_file_contains "$ERR" 'active implement attempt "opaque"'
chmod 600 "$AUDIT_DIR/opaque.guard"

# No command means no pattern and therefore no filesystem gate.
run_payload '{"tool_input":{"description":"no command here"}}'
assert_rc 0 "payload without command"

note "hook guard — registration, executable entry point and command matrix green"
