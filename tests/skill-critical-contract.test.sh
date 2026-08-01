#!/usr/bin/env bash
# TANDEM_CRITICAL under the opus transport is decided entirely in Markdown: the
# orchestrator picks the agent type, runs the two preflights and validates the
# durable `agent_type` by reading skills/implement/SKILL.md. Nothing in the
# behavioural suite can see any of it, so a skill that lost the critical agent
# type, the EFFORT_LEVEL preflight, the mirrored version gate or the
# same-mode-recovery rule would keep every other test green while
# `TANDEM_CRITICAL=1` went back to meaning nothing — the exact bug this change
# exists to fix. Same technique as the worktree, token-accounting and
# turn-effort contracts: static assertions on executable documentation.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

IMPL="$REPO_ROOT/skills/implement/SKILL.md"
RUN="$REPO_ROOT/skills/run/SKILL.md"
assert_file "$IMPL"
assert_file "$RUN"

# Markdown wraps, so prose anchors are judged on a whitespace-flattened copy: a
# re-wrapped sentence is the same contract, an absent one is not.
flatten() {
  local f="$1" out lines
  [ -f "$f" ] || fail "skill not found: $f"
  out="$SANDBOX/$(basename "$(dirname "$f")").flat"
  LC_ALL=C tr '\n' ' ' <"$f" | LC_ALL=C tr -s ' ' >"$out"
  lines="$(wc -l <"$f" | tr -d ' ')"
  [ "$lines" -ge 40 ] || fail "$f looks truncated ($lines lines) — the anchors would prove nothing"
  printf '%s' "$out"
}

IMPL_FLAT="$(flatten "$IMPL")"
RUN_FLAT="$(flatten "$RUN")"

# --- 1. the agent type CRITICAL really selects -------------------------------
assert_file_contains "$IMPL_FLAT" '`tandem:implementer-critical` (`agents/implementer-critical.md`)'
assert_file_contains "$IMPL_FLAT" 'Under `TANDEM_CRITICAL=1` a FRESH attempt uses `tandem:implementer-critical`'
assert_file_contains "$IMPL_FLAT" 'without the flag it uses `tandem:implementer`'
assert_file_contains "$IMPL_FLAT" '`effort: xhigh`'
# …and the definition the skill names has to exist.
assert_file "$REPO_ROOT/agents/implementer-critical.md"
assert_file "$REPO_ROOT/agents/implementer.md"

# The retired limitation, gone rather than supplemented: while that sentence
# survives, the skill documents two contradictory behaviours at once.
assert_not_contains "$IMPL_FLAT" "cannot raise effort"
assert_not_contains "$IMPL_FLAT" "Agent exposes no effort control"
assert_not_contains "$IMPL_FLAT" "it therefore does not change implementation effort"

# --- 2. the CLAUDE_CODE_EFFORT_LEVEL preflight -------------------------------
# Its precedence would silently degrade a "critical" attempt, so the gate is
# fail-closed and names its ways out.
assert_file_contains "$IMPL_FLAT" '**`CLAUDE_CODE_EFFORT_LEVEL`**: if it is defined and its exact value is not `xhigh`, STOP'
assert_file_contains "$IMPL_FLAT" 'overrides the critical agent type'"'"'s frontmatter `effort: xhigh`'
assert_file_contains "$IMPL_FLAT" 'unset it, set it to exactly `xhigh`, or re-run with `TANDEM_IMPLEMENTER=sol`'

# --- 3. the version gate, MIRRORED here and not only in the doctor -----------
# /tandem:implement is invocable directly, so a doctor-only gate is bypassable.
assert_file_contains "$IMPL_FLAT" '**Claude Code `>= 2.1.111`**'
assert_file_contains "$IMPL_FLAT" 'the VALUE `xhigh` only since 2.1.111'
assert_file_contains "$IMPL_FLAT" 'Read `claude --version` and compare the dotted version field by field'
assert_file_contains "$IMPL_FLAT" 'no `claude` on PATH are all a STOP'
assert_file_contains "$IMPL_FLAT" 'a doctor-only gate would be bypassable'
# The doctor runs the same threshold: two copies of one number that could drift
# apart are pinned to each other here.
assert_file_contains "$SCRIPTS/codex-doctor.sh" 'CRITICAL_MIN_CLAUDE="2.1.111"'

# …and the same is true of the PARSE, which is where the gate was fail-open: a
# build number in front of the version passed it. The pin is one complete
# normative sentence, not a slogan — every rule of the parse is inside it — and
# it must be present verbatim in BOTH prose copies: the skill the model executes
# and the `claude_dotted` comment the script implements.
VERSION_CRITERION='the version is ONLY a strict three-component dotted token N.N.N taken from the first digit-leading token; a trailing non-numeric suffix is trimmed; build numbers, dates, two or four components are undeterminable — never assume new, no later token is rescued'
assert_file_contains "$IMPL_FLAT" "$VERSION_CRITERION"
assert_file_contains "$SCRIPTS/codex-doctor.sh" "$VERSION_CRITERION"
# The lax phrase it replaced cannot survive alongside it: while that sentence is
# in the doctor, the script documents a parser that accepts a build number.
assert_not_contains "$SCRIPTS/codex-doctor.sh" 'the first dotted-numeric token'

# --- 4. agent_type in the durable schema, with its validation contract -------
# The schema itself (raw file: this one is JSON, not prose).
assert_file_contains "$IMPL" '"agent_type": "tandem:implementer",'
assert_file_contains "$IMPL_FLAT" '**closed enum**: exactly `tandem:implementer` or `tandem:implementer-critical`'
# Legacy states have no field: normalized AND persisted before any recovery.
assert_file_contains "$IMPL_FLAT" '**Field absent** (legacy state written before 0.21) → it means `tandem:implementer`'
assert_file_contains "$IMPL_FLAT" 'PERSIST the rewritten JSON **before** the recovery'
# Anything else is never a launch instruction.
assert_file_contains "$IMPL_FLAT" '**Unknown value, or anything that is not a string** → never dispatched'
assert_file_contains "$IMPL_FLAT" 'STOP in interactive mode, terminal `FAILED` in autonomous mode'

# --- 5. the effective_agent_type rule ----------------------------------------
# Recovery follows the RECORD, a fresh attempt follows the FLAG, and the gates
# follow the effective type — one rule, no silent third behaviour.
assert_file_contains "$IMPL_FLAT" '`effective_agent_type`'
assert_file_contains "$IMPL_FLAT" '**Recovery or continuation of an existing attempt** → the RECORDED `agent_type`, always'
assert_file_contains "$IMPL_FLAT" 'Selection by flag applies **only to a FRESH attempt**'
assert_file_contains "$IMPL_FLAT" 'are evaluated against the EFFECTIVE type, never against the environment flag alone'
# BOTH mismatch directions, and the degradation that is never silent.
assert_file_contains "$IMPL_FLAT" '**Mismatch in EITHER direction**'
assert_file_contains "$IMPL_FLAT" '`TANDEM_CRITICAL=1` over an attempt recorded (or normalized) as `tandem:implementer`, or no flag over an attempt recorded as `tandem:implementer-critical`'
assert_file_contains "$IMPL_FLAT" '**explicit user consent** in interactive mode and is a terminal `FAILED` in autonomous mode'
assert_file_contains "$IMPL_FLAT" 'a critical attempt is never silently downgraded'
# The recovery launch obeys the record, not the current environment.
assert_file_contains "$IMPL_FLAT" 'launch a fresh agent of the recorded `effective_agent_type` — never the type the current environment would select'

# --- 6. run: the risk matrix tells the truth, and promises nothing -----------
assert_file_contains "$RUN_FLAT" '`tandem:implementer-critical`'
assert_file_contains "$RUN_FLAT" '`TANDEM_IMPLEMENTER=sol` remains the equivalent alternative'
assert_file_contains "$RUN_FLAT" 'Neither is an unconditional promise'
assert_file_contains "$RUN_FLAT" 'trust the effective effort `tandem:doctor` reports'
# The stale claim is gone from the matrix, not merely qualified somewhere else.
assert_not_contains "$RUN_FLAT" 'Agent exposes no effort control'
assert_not_contains "$RUN_FLAT" 'the flag does not alter implementation effort'

note "implement/run SKILL.md — critical agent type, preflights, agent_type contract anchored"

# --- ordering: the critical preflights defer to the resolved type ------------
# Judging the raw flag before reading the attempt state would stop a
# normal-attempt recovery as if it were critical, bypassing the mismatch
# consent path — the exact inversion the effective-type rule forbids.
assert_file_contains "$IMPL_FLAT" "cannot run before the effective agent type is KNOWN"
assert_file_contains "$IMPL_FLAT" "DEFER both checks"
