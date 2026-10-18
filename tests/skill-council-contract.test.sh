#!/usr/bin/env bash
# The council's protocol is executable documentation: the leader runs it by
# reading skills/council/SKILL.md, and nothing in the behavioural suite can see
# whether the preflight still comes first, whether the seal still precedes the
# launch, or whether an Astra launch has gone back to calling a wrapper
# directly. Same technique as the other skill contracts: static anchors on a
# whitespace-flattened copy (a re-wrapped sentence is the same contract, an
# absent one is not), plus a parse of the fenced code blocks — the commands
# the leader actually copies.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$REPO_ROOT/skills/council/SKILL.md"
assert_file "$SKILL"
LINES="$(wc -l <"$SKILL" | tr -d ' ')"
[ "$LINES" -ge 80 ] || fail "$SKILL looks truncated ($LINES lines) — the anchors would prove nothing"

FLAT="$SANDBOX/council.flat"
LC_ALL=C tr '\n' ' ' <"$SKILL" | LC_ALL=C tr -s ' ' >"$FLAT"

# pos <needle> — the byte offset of the first occurrence in the flattened text.
pos() {
  local p
  p="$(LC_ALL=C awk -v n="$1" '{ i = index($0, n); if (i > 0) { print i; exit } }' "$FLAT")"
  [ -n "$p" ] || fail "anchor not found: $1"
  printf '%s' "$p"
}

# --- frontmatter --------------------------------------------------------------
FM="$SANDBOX/council.fm"
LC_ALL=C awk 'NR == 1 { next } /^---$/ { exit } { print }' "$SKILL" >"$FM"
assert_file_contains "$FM" "name: council"
assert_file_contains "$FM" 'argument-hint: "[idea y objetivo]"'
assert_file_contains "$FM" "effort: max"
assert_file_contains "$FM" "tandem:plan / tandem:review / tandem:ultra"
assert_file_contains "$FM" "tandem:ask"
# No `model:`: it would last only the current turn, and the debate spans many.
if LC_ALL=C grep -Eq '^model:' "$FM"; then fail "the council skill must not pin a model in its frontmatter"; fi

# --- the code blocks: what the leader really runs -----------------------------
CODE="$SANDBOX/council.code"
LC_ALL=C awk '/^[[:space:]]*```/ { inb = !inb; next } inb { print }' "$SKILL" >"$CODE"
[ -s "$CODE" ] || fail "no fenced code block found in $SKILL"
for forbidden in codex-start.sh codex-resume.sh codex-reset.sh TANDEM_TRANSPORT TANDEM_TURN_EFFORT; do
  if LC_ALL=C grep -q -- "$forbidden" "$CODE"; then
    LC_ALL=C grep -n -- "$forbidden" "$CODE" >&2
    fail "a code block of the council skill names $forbidden — Astra's turns go only through council.sh astra"
  fi
done
assert_file_contains "$CODE" 'bash "$COUNCIL" astra <run-id> propose'
assert_file_contains "$CODE" 'bash "$COUNCIL" astra <run-id> cross'
assert_file_contains "$CODE" 'bash "$COUNCIL" astra <run-id> round-<N>'
assert_file_contains "$CODE" 'bash "$COUNCIL" astra <run-id> propose --reminder'
# Every launch-looking line of a block goes through the council script.
if LC_ALL=C grep -E 'codex[[:space:]]+(exec|mcp)' "$CODE" >/dev/null; then
  fail "a code block launches codex directly"
fi
assert_file_contains "$FLAT" 'COUNCIL="${CLAUDE_SKILL_DIR}/../../scripts/council.sh"'
assert_file "$REPO_ROOT/scripts/council.sh"

# --- 1. the preflight goes first ----------------------------------------------
FIRST_BLOCK="$(LC_ALL=C awk '/^[[:space:]]*```/ { if (inb) exit; inb = 1; next } inb { print }' "$SKILL")"
assert_eq 'bash "$COUNCIL" preflight' "$FIRST_BLOCK" "the first code block of the skill"
[ "$(pos 'bash "$COUNCIL" preflight')" -lt "$(pos 'bash "$COUNCIL" init <run-id>')" ] \
  || fail "the preflight must come before init"
assert_file_contains "$FLAT" "The preflight goes first, before anything else, and spends no turn"

# --- 2. the leader declares itself --------------------------------------------
assert_file_contains "$FLAT" "**declare the model ID your system prompt names**"
assert_file_contains "$FLAT" 'If it is not `TANDEM_COUNCIL_LEADER_MODEL` (default `claude-opus-5-5`'
assert_file_contains "$FLAT" "never continue with another leader"

# --- 3. the interview does not read TANDEM_AUTONOMOUS --------------------------
assert_file_contains "$FLAT" 'The intake never reads `TANDEM_AUTONOMOUS`'
assert_eq "1" "$(LC_ALL=C grep -o 'TANDEM_AUTONOMOUS' "$SKILL" | wc -l | tr -d ' ')" \
  "TANDEM_AUTONOMOUS is named once, in the sentence that excludes it"
assert_file_contains "$FLAT" 'With `TANDEM_COUNCIL_INTAKE=ask` — the default'
assert_file_contains "$FLAT" "the user approves the brief AND confirms that this session runs on the leader model at max effort"

# --- 4. the seal precedes the launch of the seats -----------------------------
assert_file_contains "$FLAT" "seal it BEFORE launching the seats"
[ "$(pos 'bash "$COUNCIL" seal <run-id> propose')" -lt "$(pos 'bash "$COUNCIL" astra <run-id> propose')" ] \
  || fail "seal propose must come before the first Astra launch"
[ "$(pos 'bash "$COUNCIL" seal <run-id> propose')" -lt "$(pos 'subagent_type: tandem:council-fable')" ] \
  || fail "seal propose must come before the Fable dispatch"
[ "$(pos 'bash "$COUNCIL" seal <run-id> cross')" -lt "$(pos 'bash "$COUNCIL" astra <run-id> cross')" ] \
  || fail "seal cross must come before the Astra cross launch"

# --- 5. the Fable dispatch: the agent type, never model nor effort ------------
assert_file_contains "$FLAT" '`subagent_type: tandem:council-fable` (`tandem:council-fable-offline` in a run created with `--offline`)'
assert_file_contains "$FLAT" 'with **no `model` and no `effort` parameter** in the call'
assert_file_contains "$FLAT" "Neither \`model\` nor \`effort\` in the Agent call"
assert_file_contains "$FLAT" '«Eres el asiento `<L>` del consejo `<run-id>`. Lee completo el fichero `<ruta absoluta>` y responde exactamente como pide.»'
assert_file_contains "$FLAT" "every Fable turn names a prompt prepared by \`stage\`"
assert_file "$REPO_ROOT/agents/council-fable.md"
assert_file "$REPO_ROOT/agents/council-fable-offline.md"

# --- 6. the barrier -----------------------------------------------------------
assert_file_contains "$FLAT" "**The completion notification of the Astra Bash run and the Fable agent's completion notification are hard synchronization barriers.**"
assert_file_contains "$FLAT" "Before BOTH arrive you do not capture, publish, stage another phase, write a synthesis or message either seat."

# --- 7. consensus comes only from status --------------------------------------
assert_file_contains "$FLAT" 'only `council.sh status` declares it'
assert_file_contains "$FLAT" 'Consensus comes only from `status`: never declare it without `STATUS: CONSENSO`.'
assert_file_contains "$FLAT" "**you do not vote**"

# --- 8. never commit, never push ----------------------------------------------
assert_file_contains "$FLAT" "Never commit and never push anything"
if LC_ALL=C grep -Eq 'git (commit|push)' "$CODE"; then fail "a code block of the council skill commits or pushes"; fi

# --- 9. capture 65 is FAILED --------------------------------------------------
assert_file_contains "$FLAT" '**`capture` exits 65** (another model answered: a forced model, a wrong agent type or a silent model switch) → **FAILED** terminal, state preserved.'
assert_file_contains "$FLAT" "\`capture\` 65, or a cap of «Failures, retries and the turn bound» → FAILED terminal with the state preserved."

# --- 10. SendMessage is never a probe -----------------------------------------
assert_file_contains "$FLAT" 'Never use `SendMessage` as a probe'
assert_file_contains "$FLAT" "A Fable seat whose session is no longer the current one is treated as lost"

# --- the red line on the wrappers and the rebuild by generation ---------------
assert_file_contains "$FLAT" 'never `codex-start.sh` or `codex-resume.sh` directly, never `TANDEM_TRANSPORT` nor `TANDEM_TURN_EFFORT` in this skill'
assert_file_contains "$FLAT" 'never `codex-reset.sh` on a council target'
assert_file_contains "$FLAT" 'opens the next generation of the target'

# --- the bound the brief gate shows -------------------------------------------
assert_file_contains "$FLAT" 'typical `2 × (2 + R)` max-effort seat turns (12 with R = 4); ceiling `5 × (2 + R)` max-effort turns'
assert_file_contains "$FLAT" 'plus `2 + R` Astra reminders at `low` (30 + 6 with R = 4)'

# --- the report links the approved text and never rewrites it -----------------
assert_file_contains "$FLAT" 'the report summarises it and never rewrites or corrects it'

# --- every prompt the skill and the script rely on exists ---------------------
for p in seat-rules.md phase-propose.md phase-cross.md phase-round.md nudge.md astra.tpl; do
  assert_file "$REPO_ROOT/skills/council/prompts/$p"
done
assert_eq '{{EXTRA}}' "$(cat "$REPO_ROOT/skills/council/prompts/astra.tpl")" "astra.tpl holds only {{EXTRA}}"

# --- the documentation that describes the mode (A10, the parts in README and
# ARCHITECTURE; the version, CHANGELOG and BACKLOG entries live elsewhere) ---
README="$REPO_ROOT/README.md"
ARCH="$REPO_ROOT/docs/ARCHITECTURE.md"
assert_file_contains "$README" '| `/tandem:council` |'
assert_file_contains "$README" "## Modo consejo — tres modelos valoran una idea"
assert_file_contains "$README" '| Consejo (`/tandem:council`) |'
assert_file_contains "$README" "**Nada se commitea ni se pushea**"
assert_file_contains "$README" "init <run-id> --offline"
assert_file_contains "$ARCH" '## Consejo (`/tandem:council`)'
assert_file_contains "$ARCH" "Opus compite y sintetiza, pero no vota."

note "skills/council/SKILL.md — preflight first, self-declared leader, seal before launch, council.sh astra only, barriers and red lines anchored"
