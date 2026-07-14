#!/usr/bin/env bash
# tandem — diagnose the toolchain. Reports every problem found (does not stop
# at the first one) and exits non-zero if anything is broken.
# usage: codex-doctor.sh

set -uo pipefail

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
info() { printf '        %s\n' "$1"; }

printf 'tandem doctor\n\n'

# codex binary
if ! command -v codex >/dev/null 2>&1; then
  bad "codex CLI not found in PATH"
  info "install: npm install -g @openai/codex@latest"
elif ! ver="$(codex --version 2>/dev/null)"; then
  bad "codex is in PATH but cannot run (missing/removed native binary)"
  info "repair: npm install -g @openai/codex@latest"
else
  ok "codex runs: $ver"
  # login
  if codex login status >/dev/null 2>&1; then
    ok "codex is logged in"
  else
    bad "codex is not logged in"
    info "run: codex login   (or: codex login --device-auth)"
  fi
fi

# jq
if command -v jq >/dev/null 2>&1; then
  ok "jq available: $(jq --version 2>/dev/null)"
else
  bad "jq not found (needed to capture thread ids)"
  info "install: brew install jq"
fi

# git
if command -v git >/dev/null 2>&1; then
  ok "git available"
else
  bad "git not found"
fi

# model policy (mirrors _common.sh resolve_role)
printf '\nmodel policy (override via env):\n'
if [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
  impl_model="${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-sol}"
else
  impl_model="${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-luna}"
fi
info "review/ask:  model=${TANDEM_REVIEW_MODEL:-gpt-5.6-sol} effort=${TANDEM_REVIEW_EFFORT:-xhigh} sandbox=read-only (pinned)"
info "implement:   model=$impl_model effort=${TANDEM_IMPLEMENT_EFFORT:-high} sandbox=workspace-write (pinned)"
info "TANDEM_CRITICAL=${TANDEM_CRITICAL:-0} (1 switches implementation to gpt-5.6-sol)"

if [ "$fail" -ne 0 ]; then
  printf '\ntandem doctor: problems found — fix the FAIL lines above.\n'
  exit 1
fi
printf '\ntandem doctor: all good.\n'
