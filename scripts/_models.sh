#!/usr/bin/env bash
# tandem — the DEFAULT Codex model of every seat, defined in exactly one place.
# Source this file, do not run it.
#
# CONTRACT — this helper has NO shell side effects, the same contract as
# _pins.sh. It defines exactly one function and does nothing else: no `set`, no
# `shopt`, no traps, no top-level assignments, no output. That contract is what
# makes it sourceable from scripts/codex-doctor.sh, which reports EVERY problem
# it finds and therefore must never inherit _common.sh's `set -euo pipefail` (an
# intermediate failure would abort the diagnosis half way through).
# tests/models-defaults.test.sh pins it.
#
# WHY ONE DEFINITION. The wrappers (resolve_role in _common.sh), the swarm, the
# doctor (the policy it displays AND its --smoke turns) and the MCP probe all
# need the same answer to "which model does this seat run when the user
# overrode nothing?". Each used to carry its own literal, so every change of
# model generation was a hunt through four scripts, and a site missed in that
# hunt is a doctor that reports a policy no wrapper runs. Now the next change of
# generation is an edit of THIS file alone, and a static sweep in
# tests/models-defaults.test.sh refuses a default model assigned anywhere else.
#
# Only the MODEL lives here. Efforts do NOT: they did not move with the
# generation and they stay next to their role (resolve_role, the swarm's tier
# case), where that role's sandbox is decided too.
#
# The user's TANDEM_*_MODEL overrides keep winning everywhere. Callers apply
# them first —
#   CODEX_MODEL="${TANDEM_REVIEW_MODEL:-$(tandem_default_model review)}"
# — so this function is consulted only when no override is set.
#
# Portable: bash 3.2+ (stock macOS), BSD userland.

# tandem_default_model <seat> — prints the default model of a seat, nothing else.
# Seats: review (also serves ask) · implement · image · ultra-judge · ultra-worker
# · ultra-scout. Unknown seat → no output, return 1.
#
# The split follows what each seat does: the read-only adversarial seats (the
# plan red-team, code review, ask, and the ultra judge) get the frontier model;
# the seats that write or analyse as the workhorse (the Codex implementer, image
# generation, the ultra worker) get Sol; the mechanical sweeps (the ultra scout)
# get the fast, cheap one.
tandem_default_model() {
  case "${1:-}" in
    review | ultra-judge) printf '%s' 'gpt-6-astra' ;;
    implement | image | ultra-worker) printf '%s' 'gpt-6-sol' ;;
    ultra-scout) printf '%s' 'gpt-6-luna' ;;
    *) return 1 ;;
  esac
}
