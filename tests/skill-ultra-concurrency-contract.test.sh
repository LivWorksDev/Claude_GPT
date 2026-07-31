#!/usr/bin/env bash
# M13 moved the concurrency limit from the workflow author's discipline into
# codex-swarm.sh. The behavioural suite cannot see the wrapper prompt (it is
# executable documentation read by a model, not code), so the contract is
# asserted statically here: the chunking instruction is GONE, not merely
# supplemented, and the seat launch is a background one because queue wait plus
# turn does not fit in the Bash tool's foreground cap.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$REPO_ROOT/skills/ultra/SKILL.md"
assert_file "$SKILL"

# Markdown wraps, so the prose anchors are judged on a whitespace-flattened
# copy: a re-wrapped sentence is the same contract, an absent one is not.
FLAT="$SANDBOX/ultra-skill.flat"
LC_ALL=C tr '\n' ' ' <"$SKILL" | LC_ALL=C tr -s ' ' >"$FLAT"

# --- where the limit lives now, and what it costs when it bites --------------
assert_file_contains "$FLAT" "TANDEM_ULTRA_CONCURRENCY"
assert_file_contains "$FLAT" ".slots"
assert_file_contains "$FLAT" "TANDEM_ULTRA_SLOT_TIMEOUT"
assert_file_contains "$FLAT" "no chunking"

# --- the seat launch is a background one, for the reason M10 established -----
assert_file_contains "$FLAT" "run_in_background: true"
assert_file_contains "$FLAT" "10-minute foreground cap"
assert_file_contains "$FLAT" "hard ceiling of the Bash tool"

# --- retired, not supplemented: a revert would restore these -----------------
assert_not_contains "$FLAT" "chunk every"
assert_not_contains "$FLAT" "Bash timeout: 600000"

# --- never vacuously green ----------------------------------------------------
lines="$(wc -l <"$SKILL" | tr -d ' ')"
[ "$lines" -ge 40 ] || fail "$SKILL looks truncated ($lines lines) — the anchors above prove nothing"
note "ultra/SKILL.md — semaphore documented, chunking retired, seats in background"
