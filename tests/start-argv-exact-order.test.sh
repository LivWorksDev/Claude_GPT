#!/usr/bin/env bash
# codex-start.sh: the argv handed to codex, byte for byte, for all four roles.
# One comparison pins the exact set AND the exact order — a reordered flag is a
# different command line even when every flag is still present.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt for {{TARGET}}"
export CODEX_STUB_SCENARIO=ok

N=0
check() {
  # check <role> <target> <model> <effort> <sandbox>
  local role="$1" target="$2" model="$3" effort="$4" sandbox="$5" key msg search=""
  # web_search is pinned off only where the turn can write — the roles whose
  # prompt promises the model that no network is available.
  [ "$sandbox" = "workspace-write" ] && search="${US}-c${US}web_search=disabled"
  N=$((N + 1))
  run bash "$SCRIPTS/codex-start.sh" "$role" "$target" "$SANDBOX/p.tpl"
  assert_rc 0 "$role/$target"
  key="$(tkey "$target")"
  msg="$(state_dir "$role")/$key.t1.reply.txt"
  assert_argv "$N" "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}${model}${US}--sandbox${US}${sandbox}${US}-c${US}model_reasoning_effort=${effort}${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=${sandbox}${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${search}${US}--output-last-message${US}${msg}${US}-"
}

# Role -> model / effort / sandbox table (scripts/_common.sh:resolve_role).
check implement t-implement gpt-5.6-sol high         workspace-write
check review    t-review    gpt-5.6-sol xhigh        read-only
check ask       t-ask       gpt-5.6-sol xhigh        read-only
check image     t-image     gpt-5.6-sol high         workspace-write

# Env overrides move model and effort…
export TANDEM_IMPLEMENT_MODEL=gpt-5.6-luna
export TANDEM_IMPLEMENT_EFFORT=low
check implement t-impl-ovr gpt-5.6-luna low workspace-write
unset TANDEM_IMPLEMENT_MODEL TANDEM_IMPLEMENT_EFFORT

export TANDEM_REVIEW_MODEL=custom-review
export TANDEM_REVIEW_EFFORT=medium
check review t-rev-ovr custom-review medium read-only
check ask    t-ask-ovr custom-review medium read-only
unset TANDEM_REVIEW_MODEL TANDEM_REVIEW_EFFORT

export TANDEM_IMAGE_MODEL=custom-image
export TANDEM_IMAGE_EFFORT=xhigh
check image t-img-ovr custom-image xhigh workspace-write
unset TANDEM_IMAGE_MODEL TANDEM_IMAGE_EFFORT

# …TANDEM_CRITICAL raises implement to xhigh, and only implement.
export TANDEM_CRITICAL=1
check implement t-crit gpt-5.6-sol xhigh workspace-write
check image     t-crit-img gpt-5.6-sol high workspace-write
unset TANDEM_CRITICAL

# …but nothing moves the sandbox: it is pinned per role on purpose.
export TANDEM_IMPLEMENT_SANDBOX=danger-full-access
export CODEX_SANDBOX=danger-full-access
check implement t-sandbox-pinned gpt-5.6-sol high workspace-write
unset TANDEM_IMPLEMENT_SANDBOX CODEX_SANDBOX

# `-c sandbox_mode=` is no longer resume's alone: start carries the same belt,
# so a start turn cannot inherit a sandbox from the user's config.toml either.
assert_file_contains "$CODEX_STUB_LOG.argv.1" "sandbox_mode=workspace-write"
assert_file_contains "$CODEX_STUB_LOG.argv.4" "sandbox_mode=workspace-write"
assert_file_contains "$CODEX_STUB_LOG.argv.2" "sandbox_mode=read-only"

# web_search=disabled, asserted in BOTH directions per role: present where the
# turn can write (1 implement, 4 image), absent where it cannot (2 review,
# 3 ask) — a read-only seat keeps the capability by design.
assert_file_contains "$CODEX_STUB_LOG.argv.1" "web_search=disabled"
assert_file_contains "$CODEX_STUB_LOG.argv.4" "web_search=disabled"
assert_not_contains "$CODEX_STUB_LOG.argv.2" "web_search"
assert_not_contains "$CODEX_STUB_LOG.argv.3" "web_search"

# Nothing anchors the working root unless TANDEM_CODEX_CWD asks for it.
assert_not_contains "$CODEX_STUB_LOG.argv.1" "--cd"

# Unknown role never reaches codex.
run bash "$SCRIPTS/codex-start.sh" auditor t-bad "$SANDBOX/p.tpl"
assert_rc 64 "unknown role"
assert_file_contains "$ERR" "unknown role 'auditor'"
assert_no_file "$CODEX_STUB_LOG.argv.$((N + 1))"
