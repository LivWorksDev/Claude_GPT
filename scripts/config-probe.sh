#!/usr/bin/env bash
# tandem — drift watch for the config keys the wrappers pin.
#
# The CLI accepts an UNKNOWN `-c key=value` in complete silence (rc 0). So the
# day a release renames one of our pins, the pin stops applying and every test,
# every smoke and every real turn stays green while the guarantee is gone. The
# only way to tell a live key from a dead one is to hand it a deliberately
# INVALID value and require the CLI to reject it naming the key.
#
# usage: config-probe.sh
# exit codes: 0 every pinned key is alive · 1 drift (or the probe itself broke)
#             3 missing dependency
#
# Two deliberate choices:
#   - `codex debug prompt-input`, NEVER `codex exec`: the very case this exists
#     to catch — a key that no longer exists — would make `exec` accept the
#     override and start a REAL turn, burning quota and dressing the diagnosis
#     up as a network or auth failure. `debug prompt-input` validates the
#     config and exits without calling the model.
#   - a throwaway CODEX_HOME: `debug prompt-input` does not accept
#     `--ignore-user-config` (that flag is exclusive to `codex exec`), so the
#     only way to keep the developer's own config.toml out of the answer is to
#     point the CLI at an empty home for the duration of the probe.

set -uo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
set +e

need_codex

PROBE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tandem-probe.XXXXXX")" \
  || die "cannot create a temporary CODEX_HOME" 3
trap 'rm -rf "$PROBE_HOME"' EXIT
export CODEX_HOME="$PROBE_HOME"

PROMPT="tandem config probe"
fail=0

ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  DRIFT %s\n' "$1"; fail=1; }
info() { printf '        %s\n' "$1"; }

printf 'tandem config probe — %s\n\n' "$(codex --version 2>/dev/null || printf 'unknown version')"

# Preflight: with no override at all the subcommand must succeed. Without this,
# a renamed or removed `debug prompt-input` would make every key below look
# dead at once, and the report would blame the pins instead of the probe.
if ! codex debug prompt-input "$PROMPT" >/dev/null 2>&1; then
  bad "codex debug prompt-input does not run — the probe itself is broken"
  info "re-check the subcommand: codex debug prompt-input 'hello'"
  exit 1
fi

# probe <key> <invalid-value> — the key is alive when the CLI refuses the value
# AND says which key it refused. rc alone is not enough: any unrelated failure
# (missing subcommand, broken install) also exits non-zero.
probe() {
  local key="$1" bad_value="$2" out rc=0 leaf="${1##*.}"
  out="$(codex debug prompt-input -c "$key=$bad_value" "$PROMPT" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$key — accepted '$key=$bad_value' in silence: the key is gone or renamed"
    info "the pin in scripts/_pins.sh (codex_pins) no longer applies"
    return 0
  fi
  case "$out" in
    *"$key"* | *"$leaf"*)
      ok "$key"
      info "$(printf '%s' "$out" | LC_ALL=C tr '\n' ' ' | cut -c1-120)"
      ;;
    *)
      bad "$key — rejected the value but never named the key (rc $rc)"
      info "$(printf '%s' "$out" | LC_ALL=C tr '\n' ' ' | cut -c1-120)"
      ;;
  esac
}

# Keep this list in lockstep with codex_pins() in scripts/_pins.sh.
# `sandbox_mode` is not probed here: it is the one key whose effect is already
# asserted by the `--sandbox` flag it doubles, and it predates this watch.
probe sandbox_workspace_write.network_access nonsense
probe sandbox_workspace_write.writable_roots nonsense
probe approval_policy nonsense
probe approvals_reviewer nonsense
probe web_search nonsense

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'config probe FAILED — at least one pinned key no longer exists.\n'
  exit 1
fi
printf 'config probe OK — every pinned key still rejects an invalid value.\n'
exit 0
