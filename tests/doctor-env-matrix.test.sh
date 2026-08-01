#!/usr/bin/env bash
# codex-doctor.sh reports every problem it finds (it does not stop at the first)
# and exits non-zero if anything is broken.
#
# The implementer selector is the sharp edge: UNSET means "default to opus",
# SET-BUT-EMPTY is a config error. `${TANDEM_IMPLEMENTER-opus}` (no colon)
# distinguishes them; `env -u` vs `env VAR=` is the only way to test both.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

doctor() {
  run env "$@" bash "$SCRIPTS/codex-doctor.sh"
}

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_LOGIN_RC=0

# --- healthy baseline: implementer UNSET -> opus -----------------------------
doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "healthy, implementer unset"
assert_file_contains "$OUT" "ok    codex runs: codex-cli 0.0.0-stub"
assert_file_contains "$OUT" "ok    codex is logged in"
assert_file_contains "$OUT" "ok    jq available:"
assert_file_contains "$OUT" "ok    git available"
assert_file_contains "$OUT" "implementer: opus"
assert_file_contains "$OUT" "TANDEM_CRITICAL=0"
assert_file_contains "$OUT" "tandem doctor: all good."
assert_not_contains "$OUT" "FAIL"

# --- implementer SET BUT EMPTY -> hard failure, never a silent opus ----------
doctor TANDEM_IMPLEMENTER=
assert_rc 1 "implementer set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_IMPLEMENTER is set but empty — expected opus or sol"
assert_not_contains "$OUT" "implementer: opus"
assert_file_contains "$OUT" "tandem doctor: problems found"

# --- implementer=sol ----------------------------------------------------------
doctor TANDEM_IMPLEMENTER=sol
assert_rc 0 "implementer sol"
assert_file_contains "$OUT" "implementer: sol — Codex CLI transport"
assert_file_contains "$OUT" "implement:   model=gpt-5.6-sol effort=high sandbox=workspace-write (pinned)"

doctor TANDEM_IMPLEMENTER=sol TANDEM_CRITICAL=1
assert_rc 0 "implementer sol, critical"
assert_file_contains "$OUT" "effort=xhigh sandbox=workspace-write"

doctor TANDEM_IMPLEMENTER=sol TANDEM_IMPLEMENT_MODEL=custom TANDEM_IMPLEMENT_EFFORT=low
assert_rc 0 "implementer sol, overridden"
assert_file_contains "$OUT" "model=custom effort=low"

# --- sol + CRITICAL: the EFFECTIVE effort, never a promise -------------------
# TANDEM_IMPLEMENT_EFFORT has real precedence over the xhigh CRITICAL asks for,
# so a doctor that still announced "raises Sol implementation effort to xhigh"
# would be describing a run that spends `low`.
doctor TANDEM_IMPLEMENTER=sol TANDEM_CRITICAL=1 TANDEM_IMPLEMENT_EFFORT=low
assert_rc 0 "sol, critical, effort overridden"
assert_file_contains "$OUT" "effort=low sandbox=workspace-write"
assert_file_contains "$OUT" "TANDEM_IMPLEMENT_EFFORT takes precedence — this run implements at effort low"
assert_not_contains "$OUT" "raises Sol implementation effort to xhigh"
assert_not_contains "$OUT" "at effort xhigh"

# Without the override the effective effort IS xhigh, and it is stated as such.
doctor TANDEM_IMPLEMENTER=sol TANDEM_CRITICAL=1
assert_rc 0 "sol, critical, no override"
assert_file_contains "$OUT" "TANDEM_CRITICAL=1 — Sol implements at effort xhigh (effective)"

# --- opus + CRITICAL: a real effect, and the two gates that keep it real -----
# Since 0.21 the flag selects the tandem:implementer-critical agent type, whose
# frontmatter carries effort: xhigh. The old "effort is not exposed" line is
# gone — a stale limitation is as misleading as a false promise.
doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "opus, no critical"
assert_file_contains "$OUT" "TANDEM_CRITICAL=0 (1 selects the tandem:implementer-critical agent type"
assert_not_contains "$OUT" "under opus, effort is not exposed"

# claude_stub <text> — a `claude` on the sandbox PATH whose --version prints
# exactly <text> (the doctor calls no other subcommand). Same pattern as the
# codex stub the runner drops into $SANDBOX/bin.
claude_stub() {
  cat >"$SANDBOX/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "$1"
EOF
  chmod +x "$SANDBOX/bin/claude"
}
# A CLI that is present but cannot answer: undeterminable, never "assume new".
claude_stub_broken() {
  cat >"$SANDBOX/bin/claude" <<'EOF'
#!/bin/sh
printf 'claude: fatal\n' >&2
exit 1
EOF
  chmod +x "$SANDBOX/bin/claude"
}
claude_unstub() { rm -f "$SANDBOX/bin/claude"; }

# No `claude` in PATH at all → undeterminable → FAIL, but only under CRITICAL.
claude_unstub
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "critical under opus with no claude in PATH"
assert_file_contains "$OUT" "TANDEM_CRITICAL=1 (agent type tandem:implementer-critical, frontmatter effort=xhigh; review remains mandatory)"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"
assert_file_contains "$OUT" "run with TANDEM_IMPLEMENTER=sol"

doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "no claude in PATH is silent without CRITICAL"
assert_not_contains "$OUT" "Claude Code"

# The exact boundaries of the gate.
claude_stub "2.1.110 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "claude 2.1.110 under CRITICAL+opus"
assert_file_contains "$OUT" "FAIL  Claude Code 2.1.110 < 2.1.111"
assert_file_contains "$OUT" "the VALUE xhigh is not"

doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "claude 2.1.110 is silent without CRITICAL"
assert_not_contains "$OUT" "Claude Code 2.1.110"

claude_stub "2.1.111 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 0 "claude 2.1.111 under CRITICAL+opus"
assert_file_contains "$OUT" "ok    Claude Code 2.1.111 >= 2.1.111"
assert_not_contains "$OUT" "FAIL"

claude_stub "3.0.0 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 0 "a newer major under CRITICAL+opus"
assert_file_contains "$OUT" "ok    Claude Code 3.0.0 >= 2.1.111"

# Field-wise, not lexicographic: "2.1.99" sorts after "2.1.111" as a string and
# is older as a version.
claude_stub "2.1.99 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "claude 2.1.99 is OLDER than 2.1.111"
assert_file_contains "$OUT" "FAIL  Claude Code 2.1.99 < 2.1.111"

# A version that cannot be parsed is undeterminable — never optimistic.
claude_stub "Claude Code (unknown build)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "unparseable claude --version"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"

claude_stub_broken
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "claude --version fails"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"

doctor -u TANDEM_IMPLEMENTER
assert_rc 0 "a broken claude is silent without CRITICAL"
assert_not_contains "$OUT" "Claude Code version"

# --- the parser is STRICT: only a three-component dotted token is a version --
# A build number in front of the real version used to WIN the gate: "123" beat
# "2.1.111" on the first field and printed "ok Claude Code 123 >= 2.1.111" on a
# 2.1.110 install — a false pass of the whole critical guarantee.
claude_stub "Claude Code build 123 version 2.1.110"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "a build number in front of the version"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"
assert_file_contains "$OUT" "did not print a strict N.N.N dotted version"
assert_not_contains "$OUT" "ok    Claude Code"

# A dotted date is not a version either, and the 2.1.111 behind it is NOT
# rescued: the first digit-leading token decides, or nothing does.
claude_stub "2026-08-01 2.1.111"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "a date in front of the version"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"
assert_not_contains "$OUT" "ok    Claude Code"

# Four components: the comparator read three fields and ignored the rest, so
# this used to pass as "2.1.111".
claude_stub "2.1.111.7 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "four components"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"
assert_not_contains "$OUT" "ok    Claude Code"

# Two components: no zero-fill — undeterminable, not "2.1.0".
claude_stub "2.1 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 1 "two components"
assert_file_contains "$OUT" "FAIL  Claude Code version is undeterminable"
assert_not_contains "$OUT" "ok    Claude Code"

# The one suffix that IS trimmed: a pre-release of a supported version passes.
claude_stub "2.1.111-beta (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 0 "a pre-release suffix is trimmed"
assert_file_contains "$OUT" "ok    Claude Code 2.1.111 >= 2.1.111"
assert_not_contains "$OUT" "FAIL"

# --- the comparator itself: validation BEFORE comparison ---------------------
# version_ge is exercised directly, sourced in a subshell from the doctor's own
# text (the pins_of pattern of doctor-smoke: never a second copy of the code).
# A field-at-a-time validation would be no validation at all — "3.bad" and
# "3.0.0.7" win on the first field and return before the garbage behind them is
# ever read, which is the trap left open for any future caller of this helper.
VER_GE_FN="$SANDBOX/version_ge.fn"
LC_ALL=C sed -n '/^version_ge() {$/,/^}$/p' "$SCRIPTS/codex-doctor.sh" >"$VER_GE_FN"
assert_file_contains "$VER_GE_FN" "version_ge() {"
ver_ge() (
  # shellcheck source=/dev/null
  . "$VER_GE_FN"
  version_ge "$1" "$2"
)

run ver_ge "3.bad" "2.1.111"
assert_rc 1 "a non-numeric field never wins on the first field"
run ver_ge "3.0.0.7" "2.1.111"
assert_rc 1 "a fourth component never wins on the first field"
run ver_ge "2.1" "2.1.111"
assert_rc 1 "a missing field is never zero-filled"
run ver_ge "2.1.111" "2.1.111"
assert_rc 0 "equal versions"
run ver_ge "3.0.0" "2.1.111"
assert_rc 0 "a newer major"
run ver_ge "2.1.99" "2.1.111"
assert_rc 1 "2.1.99 is older than 2.1.111"

# Under sol there is no subagent, so neither critical gate applies.
claude_stub_broken
doctor TANDEM_IMPLEMENTER=sol TANDEM_CRITICAL=1
assert_rc 0 "the version gate does not apply under sol"
assert_not_contains "$OUT" "Claude Code"

# --- CLAUDE_CODE_EFFORT_LEVEL: the mirror of implement's gate 3 --------------
# It takes precedence over the critical agent type's frontmatter effort, so a
# defined value other than xhigh means "critical" at a degraded effort.
claude_stub "2.1.111 (Claude Code)"
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1 CLAUDE_CODE_EFFORT_LEVEL=medium
assert_rc 1 "critical under opus with a degraded effort level"
assert_file_contains "$OUT" "FAIL  CLAUDE_CODE_EFFORT_LEVEL='medium' overrides the critical agent type's frontmatter effort: xhigh"
assert_file_contains "$OUT" "preflight will STOP the run"
assert_file_contains "$OUT" "unset CLAUDE_CODE_EFFORT_LEVEL"
assert_file_contains "$OUT" "set it to exactly xhigh"
assert_file_contains "$OUT" "TANDEM_IMPLEMENTER=sol"

# Set-but-empty is not "unset": it overrides the frontmatter just the same.
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1 CLAUDE_CODE_EFFORT_LEVEL=
assert_rc 1 "effort level set but empty"
assert_file_contains "$OUT" "FAIL  CLAUDE_CODE_EFFORT_LEVEL='' overrides the critical agent type's frontmatter effort"

doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1 CLAUDE_CODE_EFFORT_LEVEL=xhigh
assert_rc 0 "effort level agrees with the critical agent type"
assert_file_contains "$OUT" "ok    CLAUDE_CODE_EFFORT_LEVEL=xhigh"
assert_not_contains "$OUT" "FAIL"

# Without CRITICAL the normal agent type declares no effort at all: silence.
doctor -u TANDEM_IMPLEMENTER CLAUDE_CODE_EFFORT_LEVEL=medium
assert_rc 0 "effort level without CRITICAL"
assert_not_contains "$OUT" "CLAUDE_CODE_EFFORT_LEVEL"

doctor TANDEM_IMPLEMENTER=sol TANDEM_CRITICAL=1 CLAUDE_CODE_EFFORT_LEVEL=medium
assert_rc 0 "effort level is irrelevant under sol"
assert_not_contains "$OUT" "CLAUDE_CODE_EFFORT_LEVEL"

claude_unstub

# --- an invalid selector is a failure, not a fallback ------------------------
doctor TANDEM_IMPLEMENTER=luna
assert_rc 1 "invalid implementer"
assert_file_contains "$OUT" "FAIL  TANDEM_IMPLEMENTER=luna is invalid — expected opus or sol"

doctor TANDEM_IMPLEMENTER=OPUS
assert_rc 1 "implementer is case sensitive"
assert_file_contains "$OUT" "is invalid"

# --- CLAUDE_CODE_SUBAGENT_MODEL: the preflight tandem:implement enforces ------
# The variable takes precedence over the agent type's `model: opus`, so under
# the opus transport anything but the exact string `opus` means the run will
# stop mid-pipeline. The doctor says so first. Under `sol` there is no subagent
# and the check must stay silent — a FAIL there would be noise.
doctor -u TANDEM_IMPLEMENTER -u CLAUDE_CODE_SUBAGENT_MODEL
assert_rc 0 "subagent model unset"
assert_not_contains "$OUT" "CLAUDE_CODE_SUBAGENT_MODEL"

doctor -u TANDEM_IMPLEMENTER CLAUDE_CODE_SUBAGENT_MODEL=opus
assert_rc 0 "subagent model set to opus"
assert_file_contains "$OUT" "ok    CLAUDE_CODE_SUBAGENT_MODEL=opus"
assert_not_contains "$OUT" "FAIL"

doctor -u TANDEM_IMPLEMENTER CLAUDE_CODE_SUBAGENT_MODEL=sonnet
assert_rc 1 "subagent model overridden under opus"
assert_file_contains "$OUT" "FAIL  CLAUDE_CODE_SUBAGENT_MODEL='sonnet' overrides the implementer subagent's model"
assert_file_contains "$OUT" "preflight will STOP the run"
# All three ways out are named, not just the variable.
assert_file_contains "$OUT" "unset CLAUDE_CODE_SUBAGENT_MODEL"
assert_file_contains "$OUT" "set it to exactly opus"
assert_file_contains "$OUT" "TANDEM_IMPLEMENTER=sol"

# Set-but-empty is NOT "unset": it overrides the agent type just the same.
doctor -u TANDEM_IMPLEMENTER CLAUDE_CODE_SUBAGENT_MODEL=
assert_rc 1 "subagent model set but empty"
assert_file_contains "$OUT" "FAIL  CLAUDE_CODE_SUBAGENT_MODEL='' overrides the implementer subagent's model"

doctor TANDEM_IMPLEMENTER=sol CLAUDE_CODE_SUBAGENT_MODEL=sonnet
assert_rc 0 "subagent model is irrelevant under sol"
assert_not_contains "$OUT" "CLAUDE_CODE_SUBAGENT_MODEL"

# --- autonomous requires an explicit promote-reviews decision ----------------
doctor -u TANDEM_IMPLEMENTER TANDEM_AUTONOMOUS=1
assert_rc 1 "autonomous without TANDEM_PROMOTE_REVIEWS"
assert_file_contains "$OUT" "FAIL  TANDEM_AUTONOMOUS=1 but TANDEM_PROMOTE_REVIEWS is unset"

doctor -u TANDEM_IMPLEMENTER TANDEM_AUTONOMOUS=1 TANDEM_PROMOTE_REVIEWS=0
assert_rc 0 "autonomous with an explicit 0"
doctor -u TANDEM_IMPLEMENTER TANDEM_AUTONOMOUS=1 TANDEM_PROMOTE_REVIEWS=1
assert_rc 0 "autonomous with an explicit 1"

# --- several problems at once are ALL reported -------------------------------
doctor TANDEM_IMPLEMENTER=nope TANDEM_AUTONOMOUS=1
assert_rc 1 "two problems"
assert_file_contains "$OUT" "TANDEM_IMPLEMENTER=nope is invalid"
assert_file_contains "$OUT" "TANDEM_AUTONOMOUS=1 but TANDEM_PROMOTE_REVIEWS is unset"

# --- toolchain problems -------------------------------------------------------
doctor -u TANDEM_IMPLEMENTER CODEX_STUB_LOGIN_RC=1
assert_rc 1 "not logged in"
assert_file_contains "$OUT" "FAIL  codex is not logged in"
assert_file_contains "$OUT" "codex login --device-auth"

doctor -u TANDEM_IMPLEMENTER CODEX_STUB_SCENARIO=version-fail
assert_rc 1 "codex cannot run"
assert_file_contains "$OUT" "FAIL  codex is in PATH but cannot run"
assert_not_contains "$OUT" "codex is logged in"

MINBIN="$(make_minbin)"
ln -sf "$(command -v jq)" "$MINBIN/jq"
run env -u TANDEM_IMPLEMENTER PATH="$MINBIN" bash "$SCRIPTS/codex-doctor.sh"
assert_rc 1 "codex missing"
assert_file_contains "$OUT" "FAIL  codex CLI not found in PATH"

rm -f "$MINBIN/jq"
ln -sf "$SANDBOX/bin/codex" "$MINBIN/codex"
run env -u TANDEM_IMPLEMENTER PATH="$MINBIN" CODEX_STUB_LOG="$CODEX_STUB_LOG" \
  bash "$SCRIPTS/codex-doctor.sh"
assert_rc 1 "jq missing"
assert_file_contains "$OUT" "FAIL  jq not found"

# --- the ultra tier policy and the image role are reported -------------------
doctor -u TANDEM_IMPLEMENTER
assert_file_contains "$OUT" "review/ask:  model=gpt-5.6-sol effort=xhigh sandbox=read-only (pinned)"
assert_file_contains "$OUT" "image:       model=gpt-5.6-sol effort=high sandbox=workspace-write (pinned)"
assert_file_contains "$OUT" "judge=gpt-5.6-sol/xhigh worker=gpt-5.6-sol/high scout=gpt-5.6-luna/high"
assert_file_contains "$OUT" "concurrency=4"
assert_file_contains "$OUT" "slot_timeout=1800s"

# --- the swarm semaphore's dials are VALIDATED, not just echoed --------------
# codex-swarm.sh exits 64 on a bad value, so a doctor that merely displayed it
# would hand the user a green preflight and a run where every seat dies.
doctor -u TANDEM_IMPLEMENTER TANDEM_ULTRA_CONCURRENCY=banana
assert_rc 1 "invalid ultra concurrency"
assert_file_contains "$OUT" "FAIL  TANDEM_ULTRA_CONCURRENCY='banana' is not a positive integer"

doctor -u TANDEM_IMPLEMENTER TANDEM_ULTRA_CONCURRENCY=
assert_rc 1 "ultra concurrency set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_ULTRA_CONCURRENCY='' is not a positive integer"

doctor -u TANDEM_IMPLEMENTER TANDEM_ULTRA_SLOT_TIMEOUT=0
assert_rc 1 "ultra slot timeout of zero"
assert_file_contains "$OUT" "FAIL  TANDEM_ULTRA_SLOT_TIMEOUT='0' is not a positive integer"

# `08` is eight here too: the value is normalized with 10# before any arithmetic.
doctor -u TANDEM_IMPLEMENTER TANDEM_ULTRA_CONCURRENCY=08 TANDEM_ULTRA_SLOT_TIMEOUT=09
assert_rc 0 "leading zeros are decimal"
assert_file_contains "$OUT" "concurrency=8 slot_timeout=9s"

# The status line integration is informational — absent must never be a FAIL.
assert_file_contains "$OUT" "not installed — /tandem:statusline"
assert_file_contains "$OUT" "tandem doctor: all good."
