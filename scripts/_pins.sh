#!/usr/bin/env bash
# tandem — the argv policy block EVERY codex turn carries. Source this file, do
# not run it.
#
# CONTRACT — this helper has NO shell side effects. It defines exactly one
# function and does nothing else: no `set`, no `shopt`, no traps, no top-level
# assignments, no output. That contract is what makes it sourceable from
# scripts/codex-doctor.sh, which reports EVERY problem it finds and therefore
# must never inherit _common.sh's `set -euo pipefail` (an intermediate failure
# would abort the diagnosis half way through).
#
# _common.sh sources this file for the three wrappers, so ONE definition governs
# the wrappers and the doctor's --smoke turns alike: a future change to the
# policy reaches both sides by construction instead of drifting in silence
# against a duplicated inline list.
#
# Portable: bash 3.2+ (stock macOS), BSD userland.

# codex_pins — fills the CODEX_PINS array with the policy block EVERY codex turn
# carries, in a fixed order (the suite asserts the argv byte for byte). Requires
# CODEX_SANDBOX; call it after resolve_role.
#
#   --ignore-user-config  the user's config.toml never reaches a tandem turn.
#     Pinning keys one by one can only cover what it enumerates, and a config
#     can add MCP servers with network capability, extra writable roots or
#     auto-approvals that no list anticipates — ignoring the file removes the
#     whole class. Auth still resolves through CODEX_HOME, so the login lives.
#   --ignore-rules        the same argument for the execpolicy `.rules` files.
#   -c …                  kept as defence in depth and as a verifiable
#     statement of intent: overrides are still applied AND validated with the
#     flag in place. An UNKNOWN key is accepted in silence by the CLI, so a
#     future rename would turn a pin into a no-op without a word:
#     scripts/config-probe.sh is the watchdog for exactly that.
#
# The temp roots (/tmp, $TMPDIR) stay writable on purpose (`exclude_*` left at
# their false defaults): tools need them and they are not the project tree.
# What forbids writing outside the working root is the prompt's language.
codex_pins() {
  CODEX_PINS=(
    --ignore-user-config
    --ignore-rules
    -c "sandbox_mode=$CODEX_SANDBOX"
    -c sandbox_workspace_write.network_access=false
    -c "sandbox_workspace_write.writable_roots=[]"
    -c approval_policy=never
    -c approvals_reviewer=user
  )
  # web_search is the NATIVE search tool and is NOT governed by network_access.
  # It is pinned off exactly where a turn can write (implement, image), because
  # implement.tpl promises the model that no network is available. Read-only
  # seats keep it unless TANDEM_WEB_SEARCH=off asks otherwise: a seat that
  # cannot write keeps a useful capability by default, while confidential repos
  # can close the extra channel explicitly. The value is validated by every
  # turn-spending executable in _common.sh; this read stays tolerant because
  # the doctor sources _pins.sh without die(). (The doctor's --smoke seat is
  # read-only and still pins it off explicitly: an ephemeral diagnostic turn
  # that only has to answer "OK" needs no capability at all.)
  if [ "$CODEX_SANDBOX" = "workspace-write" ] || [ "${TANDEM_WEB_SEARCH:-}" = "off" ]; then
    CODEX_PINS+=(-c web_search=disabled)
  fi
  case "${TANDEM_CODEX_CWD+set}" in
    set) CODEX_PINS+=(--cd "$TANDEM_CODEX_CWD") ;;
  esac
}
