#!/usr/bin/env bash
# council.sh preflight — the free check before a council spends turns of three
# models. It runs before the interview, with no profile yet, and computes which
# effort profiles are VIABLE (exploratorio = high, estandar = xhigh, critico =
# max): a constraint discards the profiles it rules out and names why; it FAILs
# only on a broken environment or when no profile is left (A2 of the plan).
# Every check (a)–(i) has its positive and its negative case; several problems
# are ALL reported in one pass (exit 1, never a stop at the first); an
# unavailable catalog is a FAIL (fail-closed: it is the only free check before
# the first seat turn); the summary shows the bound of every profile; and not
# one exec turn is spent — the stub's counter is the meter.
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
viable() { assert_file_contains "$OUT" "        perfiles viables: $1"; }
discarded() { assert_file_contains "$OUT" "        descartado $1"; }

# --- baseline: everything in order --------------------------------------------
pf
assert_rc 0 "baseline"
pf_ok_line "TANDEM_COUNCIL_ROUNDS=4"
pf_ok_line "TANDEM_COUNCIL_INTAKE=ask"
pf_ok_line "Astra: gpt-6-astra is in the catalog of 'codex debug models' (supports: low medium high xhigh max ultra)"
pf_ok_line "TANDEM_COUNCIL_EFFORT unset"
pf_ok_line "Fable seats: the six agents pin model=claude-fable-5-1"
pf_ok_line "no forced subagent model"
pf_ok_line "CLAUDE_CODE_EFFORT_LEVEL unset"
pf_ok_line "no maxEffortLevel below max in the settings in scope"
pf_ok_line "TANDEM_TURN_EFFORT unset"
pf_ok_line "sha256 tool available"
pf_ok_line "TANDEM_COUNCIL_PROFILE unset"
no_fail
assert_file_contains "$OUT" "council preflight: ready."
# Without restrictions, the three profiles are viable and none is discarded.
viable "exploratorio (high), estandar (xhigh), critico (max)"
assert_not_contains "$OUT" "descartado"
# (j) the summary: leader, both seats, rounds, intake, web mode and the bound
# of EVERY profile, at its own level.
assert_file_contains "$OUT" "leader expected: claude-opus-5-5 at the chosen profile's level"
assert_file_contains "$OUT" "Astra: model=gpt-6-astra sandbox=read-only (role council; effort = the profile's level)"
assert_file_contains "$OUT" "Fable: model=claude-fable-5-1 (agents/council-fable*.md: one pair per level)"
assert_file_contains "$OUT" "rounds=4 · intake=ask"
assert_file_contains "$OUT" "web mode: web by default"
assert_file_contains "$OUT" "exploratorio: típico 2 × (2 + R) = 12 turnos en high · techo 5 × (2 + R) = 30 turnos en high + 6 recordatorios de Astra en low (R = 4)"
assert_file_contains "$OUT" "estandar: típico 2 × (2 + R) = 12 turnos en xhigh · techo 5 × (2 + R) = 30 turnos en xhigh + 6 recordatorios de Astra en low (R = 4)"
assert_file_contains "$OUT" "critico: típico 2 × (2 + R) = 12 turnos en max · techo 5 × (2 + R) = 30 turnos en max + 6 recordatorios de Astra en low (R = 4)"

# The bound follows R, and the leader follows its variable.
pf TANDEM_COUNCIL_ROUNDS=2 TANDEM_COUNCIL_LEADER_MODEL=claude-other-1-0
assert_rc 0 "two rounds"
assert_file_contains "$OUT" "estandar: típico 2 × (2 + R) = 8 turnos en xhigh · techo 5 × (2 + R) = 20 turnos en xhigh + 4 recordatorios de Astra en low (R = 2)"
assert_file_contains "$OUT" "leader expected: claude-other-1-0"

# --- (a) rounds ---------------------------------------------------------------
pf TANDEM_COUNCIL_ROUNDS=0
assert_rc 1 "rounds 0"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='0' is not a positive integer"
pf TANDEM_COUNCIL_ROUNDS=abc
assert_rc 1 "rounds abc"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='abc' is not a positive integer"
assert_file_contains "$OUT" "critico: cota desconocida hasta que TANDEM_COUNCIL_ROUNDS sea válida"
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
pf TANDEM_COUNCIL_MODEL=gpt-6-luna
assert_rc 0 "luna exists in the catalog"
pf_ok_line "Astra: gpt-6-luna is in the catalog of 'codex debug models' (supports: low medium high xhigh max)"
viable "exploratorio (high), estandar (xhigh), critico (max)"
pf TANDEM_COUNCIL_MODEL=gpt-ghost
assert_rc 1 "unknown model"
pf_fail_line "Astra model 'gpt-ghost' is not in the catalog of 'codex debug models' — fix TANDEM_COUNCIL_MODEL"
viable "ninguno"
# TANDEM_COUNCIL_EFFORT, with ANY value, is a FAIL: the profile decides
# Astra's effort and a global value would contradict it in silence.
for value in max ultra "" low; do
  pf TANDEM_COUNCIL_EFFORT="$value"
  assert_rc 1 "TANDEM_COUNCIL_EFFORT='$value'"
  pf_fail_line "TANDEM_COUNCIL_EFFORT='$value' must be unset — the effort profile decides Astra's effort"
done
# A catalog of our own shape, from a file: Astra stops at high → only
# exploratorio is viable, and the other two say why.
printf '{"models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}\n' >"$SANDBOX/catalog.json"
pf CODEX_STUB_MODELS_JSON="$SANDBOX/catalog.json"
assert_rc 0 "a catalog where astra stops at high"
no_fail
viable "exploratorio (high)"
discarded "estandar (xhigh): Astra model 'gpt-6-astra' does not support effort 'xhigh' (supported: low high)"
discarded "critico (max): Astra model 'gpt-6-astra' does not support effort 'max' (supported: low high)"
# …and when it supports none of the three levels, nothing is left: FAIL.
printf '{"models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"low"}]}]}\n' >"$SANDBOX/catalog-low.json"
pf CODEX_STUB_MODELS_JSON="$SANDBOX/catalog-low.json"
assert_rc 1 "a catalog where astra has no profile level"
pf_fail_line "no effort profile is viable"
viable "ninguno"
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

# --- (e) CLAUDE_CODE_EFFORT_LEVEL: only the profile at exactly that level ------
pf CLAUDE_CODE_EFFORT_LEVEL=xhigh
assert_rc 0 "effort level xhigh"
pf_ok_line "CLAUDE_CODE_EFFORT_LEVEL=xhigh — only the profile at that level is viable"
viable "estandar (xhigh)"
discarded "exploratorio (high): CLAUDE_CODE_EFFORT_LEVEL=xhigh overrides Fable's frontmatter and the leader's session"
discarded "critico (max): CLAUDE_CODE_EFFORT_LEVEL=xhigh overrides"
pf CLAUDE_CODE_EFFORT_LEVEL=max
assert_rc 0 "effort level max"
viable "critico (max)"
pf CLAUDE_CODE_EFFORT_LEVEL=low
assert_rc 1 "effort level low"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='low' overrides the frontmatter effort of every seat and the leader's session, and it is the level of no profile"
viable "ninguno"
pf CLAUDE_CODE_EFFORT_LEVEL=
assert_rc 1 "effort level defined but empty"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='' overrides"

# --- (f) maxEffortLevel in every settings file in scope -----------------------
check_settings() {
  # check_settings <file> — a cap there discards the profiles above it, naming
  # the file (xhigh → critico out; medium → nothing left: FAIL); max there is
  # fine; garbage there cannot be verified.
  local f="$1"
  mkdir -p "$(dirname "$f")"
  printf '{"maxEffortLevel":"xhigh","other":1}\n' >"$f"
  pf
  assert_rc 0 "maxEffortLevel xhigh in $f"
  no_fail
  viable "exploratorio (high), estandar (xhigh)"
  discarded "critico (max): maxEffortLevel='xhigh' in $f caps the seats and the leader below max"
  printf '{"maxEffortLevel":"medium"}\n' >"$f"
  pf
  assert_rc 1 "maxEffortLevel medium in $f"
  pf_fail_line "no effort profile is viable"
  viable "ninguno"
  discarded "exploratorio (high): maxEffortLevel='medium' in $f caps the seats and the leader below high"
  printf '{"maxEffortLevel":"max"}\n' >"$f"
  pf
  assert_rc 0 "maxEffortLevel max in $f"
  viable "exploratorio (high), estandar (xhigh), critico (max)"
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

# --- TANDEM_COUNCIL_PROFILE: the profile of an auto intake ---------------------
pf TANDEM_COUNCIL_PROFILE=estandar
assert_rc 0 "a viable TANDEM_COUNCIL_PROFILE"
pf_ok_line "TANDEM_COUNCIL_PROFILE=estandar (xhigh) is viable"
printf '{"maxEffortLevel":"xhigh"}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
pf TANDEM_COUNCIL_PROFILE=critico
assert_rc 1 "TANDEM_COUNCIL_PROFILE=critico with maxEffortLevel xhigh"
pf_fail_line "TANDEM_COUNCIL_PROFILE=critico (max) is not viable: maxEffortLevel='xhigh' in $CLAUDE_CONFIG_DIR/settings.json"
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
pf TANDEM_COUNCIL_PROFILE=
assert_rc 1 "TANDEM_COUNCIL_PROFILE set but empty"
pf_fail_line "TANDEM_COUNCIL_PROFILE is set but empty"
pf TANDEM_COUNCIL_PROFILE=foo
assert_rc 1 "an unknown TANDEM_COUNCIL_PROFILE"
pf_fail_line "TANDEM_COUNCIL_PROFILE='foo' is not a profile — expected exploratorio, estandar or critico"

# --- (g) the six agents, read from the plugin root ----------------------------
# A copy of the plugin whose agents can be edited: the pin is READ from them.
PLUG="$SANDBOX/plugin"
mkdir -p "$PLUG/skills"
cp -R "$REPO_ROOT/scripts" "$PLUG/scripts"
cp -R "$REPO_ROOT/agents" "$PLUG/agents"
cp -R "$REPO_ROOT/skills/council" "$PLUG/skills/council"
pf_copy() { run bash "$PLUG/scripts/council.sh" preflight; }
set_key() {
  # set_key <agent-file> <key> <value>
  LC_ALL=C sed -e "s/^$2: .*/$2: $3/" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}
SIX="council-fable council-fable-offline council-fable-xhigh council-fable-xhigh-offline council-fable-high council-fable-high-offline"
for a in $SIX; do set_key "$PLUG/agents/$a.md" model claude-test-9-9; done
pf_copy
assert_rc 0 "a consistent pin of another id"
pf_ok_line "Fable seats: the six agents pin model=claude-test-9-9"
assert_file_contains "$OUT" "Fable: model=claude-test-9-9"
# An incoherent pair discards its profile only: an -xhigh twin at max.
set_key "$PLUG/agents/council-fable-xhigh-offline.md" effort max
pf_copy
assert_rc 0 "the xhigh offline twin at max"
viable "exploratorio (high), critico (max)"
discarded "estandar (xhigh): Fable seat: the twins disagree: council-fable-xhigh.md effort=xhigh, council-fable-xhigh-offline.md effort=max"
# …and a pair whose twins agree on the wrong level, too.
set_key "$PLUG/agents/council-fable-xhigh.md" effort max
pf_copy
assert_rc 0 "the xhigh pair at max"
discarded "estandar (xhigh): Fable seat: council-fable-xhigh.md and council-fable-xhigh-offline.md declare effort=max, not xhigh"
set_key "$PLUG/agents/council-fable-xhigh.md" effort xhigh
set_key "$PLUG/agents/council-fable-xhigh-offline.md" effort xhigh
# Different models among the six → FAIL.
set_key "$PLUG/agents/council-fable-high-offline.md" model claude-test-9-8
pf_copy
assert_rc 1 "the six disagree on the model"
pf_fail_line "Fable seats: the six agents disagree on the model:"
assert_file_contains "$OUT" "council-fable-high-offline.md model=claude-test-9-8"
viable "ninguno"
for a in $SIX; do set_key "$PLUG/agents/$a.md" model fable; done
pf_copy
assert_rc 1 "an alias"
pf_fail_line "Fable seats: agents/council-fable*.md pin the alias 'fable', not a full model id"
rm -f "$PLUG/agents/council-fable-high.md"
pf_copy
assert_rc 1 "an agent missing"
pf_fail_line "Fable seats: missing agent definition(s) under $PLUG/agents: council-fable-high.md"

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
pf_ok_line "Astra: gpt-6-astra is in the catalog"

# --- several problems: ALL reported in one pass --------------------------------
pf TANDEM_COUNCIL_ROUNDS=0 TANDEM_COUNCIL_INTAKE=maybe CLAUDE_CODE_EFFORT_LEVEL=low \
  TANDEM_TURN_EFFORT=low TANDEM_COUNCIL_MODEL=gpt-ghost
assert_rc 1 "five problems at once"
pf_fail_line "TANDEM_COUNCIL_ROUNDS='0'"
pf_fail_line "TANDEM_COUNCIL_INTAKE='maybe'"
pf_fail_line "CLAUDE_CODE_EFFORT_LEVEL='low'"
pf_fail_line "TANDEM_TURN_EFFORT='low'"
pf_fail_line "Astra model 'gpt-ghost' is not in the catalog"
pf_fail_line "no effort profile is viable"
assert_eq "6" "$(LC_ALL=C grep -c '^  FAIL  ' "$OUT" | tr -d ' ')" "FAIL lines in one pass (the five, and no profile left)"
assert_file_contains "$OUT" "council preflight: problems found"

# --- zero exec turns, in every run above ---------------------------------------
assert_no_file "$CODEX_STUB_LOG.n"
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem"

note "council preflight: viable profiles (catalog, CLAUDE_CODE_EFFORT_LEVEL, maxEffortLevel, Fable pairs), TANDEM_COUNCIL_EFFORT/_PROFILE, every problem in one pass, bound per profile, zero turns"
