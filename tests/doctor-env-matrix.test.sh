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

# TANDEM_CRITICAL under opus does not change the effort (Agent does not expose it).
doctor -u TANDEM_IMPLEMENTER TANDEM_CRITICAL=1
assert_rc 0 "critical under opus"
assert_file_contains "$OUT" "TANDEM_CRITICAL=1 (under opus, effort is not exposed; review remains mandatory)"

# --- an invalid selector is a failure, not a fallback ------------------------
doctor TANDEM_IMPLEMENTER=luna
assert_rc 1 "invalid implementer"
assert_file_contains "$OUT" "FAIL  TANDEM_IMPLEMENTER=luna is invalid — expected opus or sol"

doctor TANDEM_IMPLEMENTER=OPUS
assert_rc 1 "implementer is case sensitive"
assert_file_contains "$OUT" "is invalid"

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

# The status line integration is informational — absent must never be a FAIL.
assert_file_contains "$OUT" "not installed — /tandem:statusline"
assert_file_contains "$OUT" "tandem doctor: all good."
