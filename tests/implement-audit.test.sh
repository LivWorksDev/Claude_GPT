#!/usr/bin/env bash
# Mechanical write audit: committed-plan valve, package/index checks,
# node_modules census lifecycle, and exact reset behaviour.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

AUDIT="$SCRIPTS/implement-audit.sh"
HOOK="$SCRIPTS/hook-implement-guard.sh"
FIXTURES="$SANDBOX/fixtures"
AUDIT_STATE="$CLAUDE_PROJECT_DIR/.tandem/state/implement-audit"
mkdir -p "$FIXTURES"
make_repo "$CLAUDE_PROJECT_DIR"
printf 'root\n' >"$CLAUDE_PROJECT_DIR/.seed"
commit_all "$CLAUDE_PROJECT_DIR" root

write_plan() {
  local repo="$1" slug="$2" declared="${3:-src/app.js}"
  mkdir -p "$repo/docs/plans"
  printf '%s\n' \
    '# Fixture plan' \
    '' \
    '## Files to touch' \
    '' \
    '| File | Change |' \
    '| --- | --- |' \
    "| \`$declared\` | fixture |" \
    '' \
    '## Acceptance & proof' \
    '' \
    '- fixture' \
    >"$repo/docs/plans/$slug.plan.md"
}

new_repo() {
  local slug="$1" declared="${2:-src/app.js}"
  REPO="$FIXTURES/$slug"
  make_repo "$REPO"
  write_plan "$REPO" "$slug" "$declared"
  printf 'seed\n' >"$REPO/README.md"
  commit_all "$REPO" seed
}

snapshot() {
  local slug="$1" repo="$2"
  run bash "$AUDIT" snapshot "$slug" "$repo"
  assert_rc 0 "snapshot $slug"
}

check_audit() {
  local slug="$1" repo="$2" expected="$3"
  run bash "$AUDIT" check "$slug" "$repo"
  assert_rc "$expected" "check $slug"
}

seed_package() {
  local repo="$1" json="$2"
  printf '%s\n' "$json" >"$repo/package.json"
  commit_all "$repo" package
}

# Clean is invisible to the attempt.
new_repo clean
snapshot clean "$REPO"
check_audit clean "$REPO" 0
assert_file_contains "$OUT" 'AUDIT: OK'

# A deny-listed lockfile is rejected unless its exact path is in Files to touch.
new_repo lock_bad
printf 'lockfileVersion: 1\n' >"$REPO/package-lock.json"
commit_all "$REPO" lock
snapshot lock_bad "$REPO"
printf 'lockfileVersion: 2\n' >"$REPO/package-lock.json"
check_audit lock_bad "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package-lock.json'

new_repo lock_declared package-lock.json
printf 'lockfileVersion: 1\n' >"$REPO/package-lock.json"
commit_all "$REPO" lock
snapshot lock_declared "$REPO"
printf 'lockfileVersion: 2\n' >"$REPO/package-lock.json"
check_audit lock_declared "$REPO" 0

# A working-copy plan edit cannot self-authorize; the valve reads the blob.
new_repo plan_worktree
snapshot plan_worktree "$REPO"
write_plan "$REPO" plan_worktree package-lock.json
printf 'lockfileVersion: 1\n' >"$REPO/package-lock.json"
check_audit plan_worktree "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package-lock.json'

# package.json compares only dependency-management keys, but compares both the
# index and the worktree to HEAD.
new_repo package_scripts
seed_package "$REPO" '{"scripts":{"test":"old"},"dependencies":{"a":"1"}}'
snapshot package_scripts "$REPO"
printf '%s\n' '{"scripts":{"test":"new"},"dependencies":{"a":"1"}}' >"$REPO/package.json"
check_audit package_scripts "$REPO" 0

new_repo package_deps
seed_package "$REPO" '{"dependencies":{"a":"1"}}'
snapshot package_deps "$REPO"
printf '%s\n' '{"dependencies":{"a":"2"}}' >"$REPO/package.json"
check_audit package_deps "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package.json'

new_repo package_declared package.json
seed_package "$REPO" '{"dependencies":{"a":"1"}}'
snapshot package_declared "$REPO"
printf '%s\n' '{"dependencies":{"a":"2"}}' >"$REPO/package.json"
check_audit package_declared "$REPO" 0

new_repo package_index
seed_package "$REPO" '{"dependencies":{"a":"1"}}'
snapshot package_index "$REPO"
printf '%s\n' '{"dependencies":{"a":"2"}}' >"$REPO/package.json"
git -C "$REPO" add package.json
git -C "$REPO" show HEAD:package.json >"$REPO/package.json"
check_audit package_index "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package.json'

# Added-with-deps, deleted and renamed manifests have closed absence semantics.
new_repo package_added
snapshot package_added "$REPO"
mkdir -p "$REPO/app"
printf '%s\n' '{"devDependencies":{"a":"1"}}' >"$REPO/app/package.json"
check_audit package_added "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: app/package.json'

new_repo package_deleted
seed_package "$REPO" '{"scripts":{"test":"x"}}'
snapshot package_deleted "$REPO"
rm "$REPO/package.json"
check_audit package_deleted "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package.json'

new_repo package_renamed
seed_package "$REPO" '{"scripts":{"test":"x"}}'
snapshot package_renamed "$REPO"
mv "$REPO/package.json" "$REPO/renamed.json"
check_audit package_renamed "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: package.json'

# Without jq, every package.json modification fails closed and names jq.
new_repo package_nojq
seed_package "$REPO" '{"scripts":{"test":"old"}}'
snapshot package_nojq "$REPO"
printf '%s\n' '{"scripts":{"test":"new"}}' >"$REPO/package.json"
NOJQ="$SANDBOX/nojq"
mkdir -p "$NOJQ"
for utility in bash git find awk sort mv rm mkdir mktemp cat cp cmp comm wc tr; do
  utility_path="$(command -v "$utility")"
  ln -s "$utility_path" "$NOJQ/$utility"
done
run env PATH="$NOJQ" CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  bash "$AUDIT" check package_nojq "$REPO"
assert_rc 20 "package audit without jq"
assert_file_contains "$OUT" 'VIOLATION: package.json'
assert_file_contains "$OUT" 'jq unavailable'

# -uall must override repository config and expose nested untracked lockfiles.
new_repo nested_untracked
snapshot nested_untracked "$REPO"
git -C "$REPO" config status.showUntrackedFiles no
mkdir -p "$REPO/packages/new"
printf 'lockfileVersion: 1\n' >"$REPO/packages/new/package-lock.json"
check_audit nested_untracked "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: packages/new/package-lock.json'

# Porcelain -z plus quotePath=false preserves spaces and non-ASCII exactly.
new_repo unusual_paths
snapshot unusual_paths "$REPO"
mkdir -p "$REPO/carpeta con espacio/niño"
printf 'lockfileVersion: 1\n' >"$REPO/carpeta con espacio/niño/package-lock.json"
check_audit unusual_paths "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: carpeta con espacio/niño/package-lock.json'

# First-level set diffs catch deletion, addition and same-cardinality replacement.
new_repo node_deleted
mkdir -p "$REPO/node_modules/a" "$REPO/node_modules/b"
snapshot node_deleted "$REPO"
rm -rf "$REPO/node_modules/a"
check_audit node_deleted "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: node_modules/a'

new_repo node_added
mkdir -p "$REPO/node_modules/a"
snapshot node_added "$REPO"
mkdir -p "$REPO/node_modules/b"
check_audit node_added "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: node_modules/b'

new_repo node_replaced
mkdir -p "$REPO/node_modules/a"
snapshot node_replaced "$REPO"
rm -rf "$REPO/node_modules/a"
mkdir -p "$REPO/node_modules/b"
check_audit node_replaced "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: node_modules/a'
assert_file_contains "$OUT" 'VIOLATION: node_modules/b'

# A whole node_modules directory appearing from an empty census is itself a
# violation, at the root or nested within the bounded census depth.
new_repo node_new_root
snapshot node_new_root "$REPO"
mkdir -p "$REPO/node_modules/a"
check_audit node_new_root "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: node_modules'

new_repo node_new_nested
snapshot node_new_nested "$REPO"
mkdir -p "$REPO/packages/app/node_modules/a"
check_audit node_new_nested "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: packages/app/node_modules'

# Legacy attempts have no node proof but still run the Git path checks.
new_repo legacy
printf 'seed\n' >"$REPO/Cargo.lock"
commit_all "$REPO" cargo
printf 'changed\n' >"$REPO/Cargo.lock"
check_audit legacy "$REPO" 20
assert_file_contains "$OUT" 'WARN: census missing — node_modules changes unverified'
assert_file_contains "$OUT" 'VIOLATION: Cargo.lock'

# A census from another identity is never used as a verdict baseline.
new_repo mismatch
snapshot mismatch "$REPO"
printf 'later\n' >"$REPO/later.txt"
commit_all "$REPO" later
check_audit mismatch "$REPO" 65
assert_file_contains "$ERR" 'census identity mismatch'

new_repo cargo
snapshot cargo "$REPO"
printf 'lock\n' >"$REPO/Cargo.lock"
check_audit cargo "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: Cargo.lock'

new_repo patches_deleted
mkdir -p "$REPO/patches"
printf 'patch\n' >"$REPO/patches/fix.patch"
commit_all "$REPO" patch
snapshot patches_deleted "$REPO"
rm "$REPO/patches/fix.patch"
check_audit patches_deleted "$REPO" 20
assert_file_contains "$OUT" 'VIOLATION: patches/fix.patch'

# snapshot is idempotent and never re-bases the census.
new_repo idempotent
mkdir -p "$REPO/node_modules/a"
snapshot idempotent "$REPO"
cp "$AUDIT_STATE/idempotent.census" "$SANDBOX/idempotent.before"
mkdir -p "$REPO/node_modules/b"
snapshot idempotent "$REPO"
cmp -s "$SANDBOX/idempotent.before" "$AUDIT_STATE/idempotent.census" \
  || fail "second snapshot re-based the census"
assert_file "$AUDIT_STATE/idempotent.guard"

# close removes only the guard and preserves the audit record.
run bash "$AUDIT" close idempotent
assert_rc 0 "close"
assert_no_file "$AUDIT_STATE/idempotent.guard"
assert_file "$AUDIT_STATE/idempotent.census"

# census-without-guard repairs toward the protected side when identity matches.
new_repo repair_census
snapshot repair_census "$REPO"
run bash "$AUDIT" close repair_census
assert_rc 0
assert_no_file "$AUDIT_STATE/repair_census.guard"
snapshot repair_census "$REPO"
assert_file "$AUDIT_STATE/repair_census.guard"

# A foreign census without a guard returns 65 and remains byte-identical.
new_repo repair_foreign
snapshot repair_foreign "$REPO"
run bash "$AUDIT" close repair_foreign
assert_rc 0
awk -F '\t' 'BEGIN { OFS="\t" } $1 == "plan_hash" { $2="foreign" } { print }' \
  "$AUDIT_STATE/repair_foreign.census" >"$SANDBOX/foreign.census"
mv "$SANDBOX/foreign.census" "$AUDIT_STATE/repair_foreign.census"
cp "$AUDIT_STATE/repair_foreign.census" "$SANDBOX/foreign.before"
run bash "$AUDIT" snapshot repair_foreign "$REPO"
assert_rc 65 "foreign census without guard"
cmp -s "$SANDBOX/foreign.before" "$AUDIT_STATE/repair_foreign.census" \
  || fail "foreign census changed"
assert_no_file "$AUDIT_STATE/repair_foreign.guard"

# A guard without a census stays byte-identical while snapshot writes the census.
new_repo repair_guard
mkdir -p "$AUDIT_STATE"
printf 'pre-existing guard bytes\n' >"$AUDIT_STATE/repair_guard.guard"
cp "$AUDIT_STATE/repair_guard.guard" "$SANDBOX/guard.before"
snapshot repair_guard "$REPO"
assert_file "$AUDIT_STATE/repair_guard.census"
cmp -s "$SANDBOX/guard.before" "$AUDIT_STATE/repair_guard.guard" \
  || fail "guard-only recovery rewrote the guard"

# A complete foreign pair returns 65 without changing either byte.
new_repo complete_foreign
snapshot complete_foreign "$REPO"
awk -F '\t' 'BEGIN { OFS="\t" } $1 == "base_head" { $2="foreign" } { print }' \
  "$AUDIT_STATE/complete_foreign.census" >"$SANDBOX/complete.census"
mv "$SANDBOX/complete.census" "$AUDIT_STATE/complete_foreign.census"
cp "$AUDIT_STATE/complete_foreign.census" "$SANDBOX/complete.census.before"
cp "$AUDIT_STATE/complete_foreign.guard" "$SANDBOX/complete.guard.before"
run bash "$AUDIT" snapshot complete_foreign "$REPO"
assert_rc 65 "foreign complete pair"
cmp -s "$SANDBOX/complete.census.before" "$AUDIT_STATE/complete_foreign.census" \
  || fail "foreign complete census changed"
cmp -s "$SANDBOX/complete.guard.before" "$AUDIT_STATE/complete_foreign.guard" \
  || fail "foreign complete guard changed"

# Real reset: slug mapping is distinct from target_key, adjacent artifacts
# survive, and rm invocation order is census -> thread state -> guard last.
RESET_AUDIT="$CLAUDE_PROJECT_DIR/.tandem/state/implement-audit"
RESET_STATE="$CLAUDE_PROJECT_DIR/.tandem/state/implement"
mkdir -p "$RESET_AUDIT" "$RESET_STATE"
XKEY="$(tkey docs/plans/x.plan.md)"
YKEY="$(tkey docs/plans/y.plan.md)"
printf 'thread x\n' >"$RESET_STATE/$XKEY.thread"
printf 'thread y\n' >"$RESET_STATE/$YKEY.thread"
printf 'x census\n' >"$RESET_AUDIT/x.census"
printf 'x guard\n' >"$RESET_AUDIT/x.guard"
printf 'y census\n' >"$RESET_AUDIT/y.census"
printf 'y guard\n' >"$RESET_AUDIT/y.guard"

SHIM_BIN="$SANDBOX/rm-shim"
RM_LOG="$SANDBOX/rm.log"
REAL_RM="$(command -v rm)"
mkdir -p "$SHIM_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >>"$RM_LOG"' \
  'exec "$REAL_RM" "$@"' \
  >"$SHIM_BIN/rm"
chmod +x "$SHIM_BIN/rm"
run env PATH="$SHIM_BIN:$PATH" RM_LOG="$RM_LOG" REAL_RM="$REAL_RM" \
  bash "$SCRIPTS/codex-reset.sh" implement docs/plans/x.plan.md
assert_rc 0 "implement reset"
assert_no_file "$RESET_AUDIT/x.census"
assert_no_file "$RESET_AUDIT/x.guard"
assert_no_file "$RESET_STATE/$XKEY.thread"
assert_file "$RESET_AUDIT/y.census"
assert_file "$RESET_AUDIT/y.guard"
assert_file "$RESET_STATE/$YKEY.thread"

CENSUS_LINE="$(grep -nF 'x.census' "$RM_LOG" | head -n 1 | cut -d: -f1)"
STATE_LINE="$(grep -nF "$XKEY.thread" "$RM_LOG" | head -n 1 | cut -d: -f1)"
GUARD_LINE="$(grep -nF 'x.guard' "$RM_LOG" | head -n 1 | cut -d: -f1)"
[ "$CENSUS_LINE" -lt "$STATE_LINE" ] || fail "reset did not delete census before thread state"
[ "$STATE_LINE" -lt "$GUARD_LINE" ] || fail "reset did not delete guard last"
assert_eq "$(wc -l <"$RM_LOG" | tr -d ' ')" "$GUARD_LINE" "guard is final rm"

# If reset is interrupted immediately after deleting the census, the guard
# still blocks. A second real reset completes the cleanup.
ZKEY="$(tkey docs/plans/z.plan.md)"
printf 'thread z\n' >"$RESET_STATE/$ZKEY.thread"
printf 'z census\n' >"$RESET_AUDIT/z.census"
printf 'z guard\n' >"$RESET_AUDIT/z.guard"
FAIL_SHIM="$SANDBOX/rm-fail-shim"
mkdir -p "$FAIL_SHIM"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '"$REAL_RM" "$@"' \
  'exit 99' \
  >"$FAIL_SHIM/rm"
chmod +x "$FAIL_SHIM/rm"
run env PATH="$FAIL_SHIM:$PATH" REAL_RM="$REAL_RM" \
  bash "$SCRIPTS/codex-reset.sh" implement docs/plans/z.plan.md
assert_rc 99 "interrupted reset"
assert_no_file "$RESET_AUDIT/z.census"
assert_file "$RESET_AUDIT/z.guard"
printf '%s' '{"tool_input":{"command":"pnpm install"}}' \
  | bash "$HOOK" >"$OUT" 2>"$ERR" || RC=$?
assert_rc 2 "guard after interrupted reset"
run bash "$SCRIPTS/codex-reset.sh" implement docs/plans/z.plan.md
assert_rc 0 "second reset"
assert_no_file "$RESET_AUDIT/z.guard"
assert_no_file "$RESET_STATE/$ZKEY.thread"

# Non-plan implement targets leave audit state alone and say so.
printf 'keep\n' >"$RESET_AUDIT/keep.census"
printf 'keep\n' >"$RESET_AUDIT/keep.guard"
run bash "$SCRIPTS/codex-reset.sh" implement feature-label
assert_rc 0 "non-plan implement reset"
assert_file "$RESET_AUDIT/keep.census"
assert_file "$RESET_AUDIT/keep.guard"
assert_file_contains "$OUT" 'implement audit state unchanged'

# Usage errors and irrecoverable preconditions keep their dedicated families.
run bash "$AUDIT"
assert_rc 64 "audit usage"
run bash "$AUDIT" snapshot bad/slug "$CLAUDE_PROJECT_DIR"
assert_rc 64 "invalid slug"
NOT_REPO="$SANDBOX/not-a-repo"
mkdir -p "$NOT_REPO"
run bash "$AUDIT" snapshot precondition "$NOT_REPO"
assert_rc 65 "snapshot outside git"
run bash "$AUDIT" check precondition "$NOT_REPO"
assert_rc 65 "check outside git"

note "implement audit — deny-list, committed valve, census lifecycle and reset matrix green"
