#!/usr/bin/env bash
# council.sh preflight — the free check before a council spends max-effort
# turns of three models. Every check (a)–(i) has its positive and its negative
# case; several problems are ALL reported in one pass (exit 1, never a stop at
# the first); an unavailable catalog is a FAIL (fail-closed: it is the only free
# check before the first max turn); the summary shows the typical bound and the
# ceiling; and not one exec turn is spent — the stub's counter is the meter.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
# Hermetic: never the managed settings file of the machine running the suite.
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"

pf() { run env "$@" bash "$COUNCIL" preflight; }
pf_ok_line() { assert_file_contains "$OUT" "  ok    $1"; }
pf_fail_line() { assert_file_contains "$OUT" "  FAIL  $1"; }
no_fail() { assert_not_contains "$OUT" "FAIL"; }

# --- baseline: everything in order --------------------------------------------
pf
assert_rc 0 "baseline"
pf_ok_line "TANDEM_COUNCIL_ROUNDS=4"
pf_ok_line "TANDEM_COUNCIL_INTAKE=ask"
pf_ok_line "Astra: gpt-6-astra supports effort max (codex debug models)"
pf_ok_line "Fable seat: model=claude-fable-5-1 effort=max"
pf_ok_line "no forced subagent model"
pf_ok_line "CLAUDE_CODE_EFFORT_LEVEL unset"
pf_ok_line "no maxEffortLevel below max in the settings in scope"
pf_ok_line "TANDEM_TURN_EFFORT unset"
pf_ok_line "sha256 tool available"
no_fail
assert_file_contains "$OUT" "council preflight: ready."
# (j) the summary: leader, both seats, rounds, intake, web mode and the bound.
assert_file_contains "$OUT" "leader expected: claude-opus-5-5 at effort max"
assert_file_contains "$OUT" "Astra: model=gpt-6-astra effort=max sandbox=read-only (role council)"
assert_file_contains "$OUT" "Fable: model=claude-fable-5-1 effort=max (agents/council-fable.md)"
assert_file_contains "$OUT" "rounds=4 · intake=ask"
assert_file_contains "$OUT" "web mode: web by default"
assert_file_contains "$OUT" "turn bound: typical 2 × (2 + R) = 12 max-effort seat turns · ceiling 5 × (2 + R) = 30 max-effort turns + 6 Astra reminders at low (R = 4)"

# The bound follows R, and the leader follows its variable.
pf TANDEM_COUNCIL_ROUNDS=2 TANDEM_COUNCIL_LEADER_MODEL=claude-other-1-0
assert_rc 0 "two rounds"
assert_file_contains "$OUT" "typical 2 × (2 + R) = 8 max-effort seat turns · ceiling 5 × (2 + R) = 20 max-effort turns + 4 Astra reminders at low (R = 2)"
assert_file_contains "$OUT" "leader expected: claude-other-1-0"

# --- (a) rounds ---------------------------------------------------------------
pf TANDEM_COUNCIL_ROUNDS=0
assert_rc 1 "rounds 0"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='0' is not a positive integer"
pf TANDEM_COUNCIL_ROUNDS=abc
assert_rc 1 "rounds abc"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='abc' is not a positive integer"
assert_file_contains "$OUT" "turn bound: unknown until TANDEM_COUNCIL_ROUNDS is valid"
# The ${VAR+set} discipline: defined and empty is a usage error, never "unset".
pf TANDEM_COUNCIL_ROUNDS=
assert_rc 64 "rounds set but empty"
assert_file_contains "$ERR" "TANDEM_COUNCIL_ROUNDS is set but empty"

# --- (b) intake ---------------------------------------------------------------
pf TANDEM_COUNCIL_INTAKE=auto
assert_rc 0 "intake auto"
pf_ok_line "TANDEM_COUNCIL_INTAKE=auto"
pf TANDEM_COUNCIL_INTAKE=maybe
assert_rc 1 "intake maybe"
pf_fail_line "TANDEM_COUNCIL_INTAKE='maybe' is invalid — expected ask or auto"

# --- (c) Astra against the catalog of `codex debug models` --------------------
pf TANDEM_COUNCIL_MODEL=gpt-6-luna TANDEM_COUNCIL_EFFORT=max
assert_rc 0 "luna at max exists in the catalog"
pf_ok_line "Astra: gpt-6-luna supports effort max"
pf TANDEM_COUNCIL_MODEL=gpt-ghost
assert_rc 1 "unknown model"
pf_fail_line "Astra model 'gpt-ghost' is not in the catalog of 'codex debug models' — fix TANDEM_COUNCIL_MODEL"
pf TANDEM_COUNCIL_MODEL=gpt-6-luna TANDEM_COUNCIL_EFFORT=ultra
assert_rc 1 "luna has no ultra"
pf_fail_line "Astra model 'gpt-6-luna' does not support effort 'ultra' (supported: low, medium, high, xhigh, max) — fix TANDEM_COUNCIL_EFFORT"
pf TANDEM_COUNCIL_EFFORT=minimal
assert_rc 1 "astra has no minimal"
pf_fail_line "Astra model 'gpt-6-astra' does not support effort 'minimal'"
# A catalog of our own shape, from a file.
printf '{"models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"high"}]}]}\n' >"$SANDBOX/catalog.json"
pf CODEX_STUB_MODELS_JSON="$SANDBOX/catalog.json"
assert_rc 1 "a catalog where astra stops at high"
pf_fail_line "Astra model 'gpt-6-astra' does not support effort 'max' (supported: high) — fix TANDEM_COUNCIL_EFFORT"
# Catalog unavailable → FAIL, in all three ways it can be unavailable.
pf CODEX_STUB_DEBUG_RC=3
assert_rc 1 "catalog command fails"
pf_fail_line "Astra model catalog unavailable: 'codex debug models' failed or did not print"
printf 'not json at all\n' >"$SANDBOX/garbage.json"
pf CODEX_STUB_MODELS_JSON="$SANDBOX/garbage.json"
assert_rc 1 "catalog is garbage"
pf_fail_line "Astra model catalog unavailable"
# make_minbin always answers the same directory: everything below adds to it.
MINI="$(make_minbin)"
ln -sf "$(command -v jq)" "$MINI/jq"
ln -sf "$(command -v ps)" "$MINI/ps"
ln -sf "$(command -v uname)" "$MINI/uname"
rm -f "$MINI/codex" "$MINI/shasum" "$MINI/sha256sum"
run env PATH="$MINI" bash "$COUNCIL" preflight
assert_rc 1 "no codex at all"
pf_fail_line "Astra model catalog unavailable: codex CLI not found in PATH"

# --- (d) a forced subagent model ----------------------------------------------
pf CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=claude-opus-5-5
assert_rc 1 "forced foreign model"
pf_fail_line "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 with CLAUDE_CODE_SUBAGENT_MODEL='claude-opus-5-5' would force that model onto the Fable seat (pin: claude-fable-5-1)"
pf CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=claude-fable-5-1
assert_rc 0 "forced model equal to the pin"
pf_ok_line "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 with CLAUDE_CODE_SUBAGENT_MODEL=claude-fable-5-1"
# Without FORCE the variable does not override a frontmatter model (the
# current rule): not a council problem.
pf CLAUDE_CODE_SUBAGENT_MODEL=opus
assert_rc 0 "subagent model without force"
no_fail

# --- (e) CLAUDE_CODE_EFFORT_LEVEL ---------------------------------------------
pf CLAUDE_CODE_EFFORT_LEVEL=max
assert_rc 0 "effort level max"
pf_ok_line "CLAUDE_CODE_EFFORT_LEVEL=max"
pf CLAUDE_CODE_EFFORT_LEVEL=high
assert_rc 1 "effort level high"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='high' overrides the frontmatter effort of every seat and the leader's session"
pf CLAUDE_CODE_EFFORT_LEVEL=
assert_rc 1 "effort level defined but empty"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='' overrides"

# --- (f) maxEffortLevel in every settings file in scope -----------------------
check_settings() {
  # check_settings <file> — a value below max there is a FAIL naming the file;
  # max there is fine; garbage there cannot be verified.
  local f="$1"
  mkdir -p "$(dirname "$f")"
  printf '{"maxEffortLevel":"high","other":1}\n' >"$f"
  pf
  assert_rc 1 "maxEffortLevel high in $f"
  pf_fail_line "maxEffortLevel='high' in $f caps every seat and the leader below max"
  printf '{"maxEffortLevel":"max"}\n' >"$f"
  pf
  assert_rc 0 "maxEffortLevel max in $f"
  printf '{ not json\n' >"$f"
  pf
  assert_rc 1 "unparseable $f"
  pf_fail_line "cannot parse $f as JSON"
  rm -f "$f"
}
check_settings "$CLAUDE_CONFIG_DIR/settings.json"
check_settings "$CLAUDE_PROJECT_DIR/.claude/settings.json"
check_settings "$CLAUDE_PROJECT_DIR/.claude/settings.local.json"
check_settings "$TANDEM_CLAUDE_MANAGED_SETTINGS"
# A settings file without the key is simply fine.
printf '{"model":"opus"}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
pf
assert_rc 0 "settings without maxEffortLevel"
rm -f "$CLAUDE_CONFIG_DIR/settings.json"

# --- (g) the two agents, read from the plugin root ----------------------------
# A copy of the plugin whose agents can be edited: the pin is READ from them.
PLUG="$SANDBOX/plugin"
mkdir -p "$PLUG/skills"
cp -R "$REPO_ROOT/scripts" "$PLUG/scripts"
cp -R "$REPO_ROOT/agents" "$PLUG/agents"
cp -R "$REPO_ROOT/skills/council" "$PLUG/skills/council"
pf_copy() { run bash "$PLUG/scripts/council.sh" preflight; }
set_model() {
  # set_model <agent-file> <model>
  LC_ALL=C sed -e "s/^model: .*/model: $2/" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}
set_model "$PLUG/agents/council-fable.md" claude-test-9-9
set_model "$PLUG/agents/council-fable-offline.md" claude-test-9-9
pf_copy
assert_rc 0 "a consistent pin of another id"
pf_ok_line "Fable seat: model=claude-test-9-9 effort=max"
assert_file_contains "$OUT" "Fable: model=claude-test-9-9 effort=max"
set_model "$PLUG/agents/council-fable-offline.md" claude-test-9-8
pf_copy
assert_rc 1 "twins disagree"
pf_fail_line "Fable seat: the twins disagree: council-fable.md model=claude-test-9-9 effort=max, council-fable-offline.md model=claude-test-9-8 effort=max"
set_model "$PLUG/agents/council-fable.md" fable
set_model "$PLUG/agents/council-fable-offline.md" fable
pf_copy
assert_rc 1 "an alias"
pf_fail_line "Fable seat: agents/council-fable.md pins the alias 'fable', not a full model id"
rm -f "$PLUG/agents/council-fable-offline.md"
pf_copy
assert_rc 1 "an agent missing"
pf_fail_line "Fable seat: missing agent definition(s)"

# --- (h) TANDEM_TURN_EFFORT, whatever its value -------------------------------
for value in low "" turbo; do
  pf TANDEM_TURN_EFFORT="$value"
  assert_rc 1 "TANDEM_TURN_EFFORT='$value'"
  pf_fail_line "TANDEM_TURN_EFFORT='$value' must be unset"
done

# --- (i) a sha256 tool ----------------------------------------------------------
ln -sf "$SANDBOX/bin/codex" "$MINI/codex"
rm -f "$MINI/shasum" "$MINI/sha256sum"
run env PATH="$MINI" CODEX_STUB_LOG="$CODEX_STUB_LOG" bash "$COUNCIL" preflight
assert_rc 1 "no sha256 tool"
pf_fail_line "neither shasum nor sha256sum is available"
pf_ok_line "Astra: gpt-6-astra supports effort max"

# --- several problems: ALL reported in one pass --------------------------------
pf TANDEM_COUNCIL_ROUNDS=0 TANDEM_COUNCIL_INTAKE=maybe CLAUDE_CODE_EFFORT_LEVEL=high \
  TANDEM_TURN_EFFORT=low TANDEM_COUNCIL_MODEL=gpt-ghost
assert_rc 1 "five problems at once"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='0'"
pf_fail_line "TANDEM_COUNCIL_INTAKE='maybe'"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='high'"
pf_fail_line "TANDEM_TURN_EFFORT='low'"
pf_fail_line "Astra model 'gpt-ghost' is not in the catalog"
assert_eq "5" "$(LC_ALL=C grep -c '^  FAIL  ' "$OUT" | tr -d ' ')" "FAIL lines in one pass"
assert_file_contains "$OUT" "council preflight: problems found"

# --- zero exec turns, in every run above ---------------------------------------
assert_no_file "$CODEX_STUB_LOG.n"
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem"

note "council preflight: (a)–(i) both ways, every problem in one pass, fail-closed catalog, bound shown, zero turns"
