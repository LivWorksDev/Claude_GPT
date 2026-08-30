#!/usr/bin/env bash
# codex-doctor.sh --autonomous — free, cold preflight for unattended runs.
#
# Every non-smoke invocation is metered through the codex stub: version/login
# probes are free, while any accidental `codex exec` would create the counter
# and fail the case. The runner does not provide a git repository, so the clean
# baseline is initialized and seeded explicitly here.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_LOGIN_RC=0

reset_stub() { rm -f "$CODEX_STUB_LOG".*; }

turns() {
  if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi
}

assert_zero_turns() {
  assert_eq "0" "$(turns)" "--autonomous without --smoke must spend zero turns"
  assert_no_file "$CODEX_STUB_LOG.argv.1"
}

# Healthy autonomous baseline. Later assignments in "$@" override these two;
# all other TANDEM_* variables start unset in the runner's scrubbed environment.
doctor_autonomous() {
  reset_stub
  run env TANDEM_IMPLEMENTER=sol TANDEM_PROMOTE_REVIEWS=1 "$@" \
    bash "$SCRIPTS/codex-doctor.sh" --autonomous
  assert_zero_turns
}

make_repo "$CLAUDE_PROJECT_DIR"
printf 'seed\n' >"$CLAUDE_PROJECT_DIR/seed.txt"
commit_all "$CLAUDE_PROJECT_DIR" "seed autonomous doctor fixture"

# --- promote decision: strict {0,1}, and WARN even when another check fails ---
reset_stub
run env -u TANDEM_PROMOTE_REVIEWS TANDEM_IMPLEMENTER=sol \
  bash "$SCRIPTS/codex-doctor.sh" --autonomous
assert_zero_turns
assert_rc 1 "promote reviews unset"
assert_file_contains "$OUT" "FAIL  TANDEM_PROMOTE_REVIEWS is unset"
assert_file_contains "$OUT" "WARN  permission prompts"

doctor_autonomous TANDEM_PROMOTE_REVIEWS=1
assert_rc 0 "promote reviews always"
assert_file_contains "$OUT" "ok    TANDEM_PROMOTE_REVIEWS=1 — review record always written"
assert_file_contains "$OUT" "ok    autonomous tree=clean — HEAD present"
assert_file_contains "$OUT" "ok    implementer=sol"
assert_file_contains "$OUT" "ok    critical=0"
assert_file_contains "$OUT" "ok    worktree=in-place"
assert_file_contains "$OUT" "ok    web_search=default"
assert_file_contains "$OUT" "ok    transport=exec (default)"
assert_file_contains "$OUT" "ok    autonomous=ready (not enabled"
assert_file_contains "$OUT" "ok    TANDEM_EXEC_TIMEOUT_SECONDS=role defaults"
assert_file_contains "$OUT" "ok    TANDEM_TURN_EFFORT=unset"
assert_file_contains "$OUT" "ok    TANDEM_CODEX_CWD=unset"
assert_file_contains "$OUT" "WARN  permission prompts"
assert_file_contains "$OUT" "tandem doctor: all good."

doctor_autonomous TANDEM_PROMOTE_REVIEWS=0
assert_rc 0 "promote reviews never"
assert_file_contains "$OUT" "ok    TANDEM_PROMOTE_REVIEWS=0 — review record never written"
assert_file_contains "$OUT" "tandem doctor: all good."

doctor_autonomous TANDEM_PROMOTE_REVIEWS=2
assert_rc 1 "promote reviews unknown value"
assert_file_contains "$OUT" "FAIL  TANDEM_PROMOTE_REVIEWS='2' is invalid"

doctor_autonomous TANDEM_PROMOTE_REVIEWS=
assert_rc 1 "promote reviews set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_PROMOTE_REVIEWS='' is invalid"

# --- git states and project-root anchoring -----------------------------------
printf 'dirty\n' >"$CLAUDE_PROJECT_DIR/untracked.txt"
doctor_autonomous
assert_rc 1 "dirty project tree"
assert_file_contains "$OUT" "FAIL  autonomous tree: 1 uncommitted entry"
rm -f "$CLAUDE_PROJECT_DIR/untracked.txt"

# Invoking from elsewhere must still inspect CLAUDE_PROJECT_DIR.
mkdir -p "$SANDBOX/invocation-cwd"
printf 'dirty from elsewhere\n' >"$CLAUDE_PROJECT_DIR/untracked.txt"
reset_stub
run_in "$SANDBOX/invocation-cwd" env TANDEM_IMPLEMENTER=sol \
  TANDEM_PROMOTE_REVIEWS=1 bash "$SCRIPTS/codex-doctor.sh" --autonomous
assert_zero_turns
assert_rc 1 "dirty project while invoked from another directory"
assert_file_contains "$OUT" "FAIL  autonomous tree: 1 uncommitted entry"
rm -f "$CLAUDE_PROJECT_DIR/untracked.txt"

mkdir -p "$SANDBOX/not-repo"
doctor_autonomous CLAUDE_PROJECT_DIR="$SANDBOX/not-repo"
assert_rc 1 "project directory is not a repository"
assert_file_contains "$OUT" "FAIL  autonomous tree: '$SANDBOX/not-repo' is not a git repository"

make_repo "$SANDBOX/unborn"
doctor_autonomous CLAUDE_PROJECT_DIR="$SANDBOX/unborn"
assert_rc 1 "repository has no HEAD"
assert_file_contains "$OUT" "FAIL  autonomous tree: HEAD is missing"
assert_not_contains "$OUT" "autonomous tree=clean"

# A PATH that contains every doctor dependency except git must fail closed.
NO_GIT_BIN="$(make_minbin)"
ln -sf "$(command -v jq)" "$NO_GIT_BIN/jq"
ln -sf "$SANDBOX/bin/codex" "$NO_GIT_BIN/codex"
rm -f "$NO_GIT_BIN/git"
reset_stub
run env PATH="$NO_GIT_BIN" CODEX_STUB_LOG="$CODEX_STUB_LOG" \
  TANDEM_IMPLEMENTER=sol TANDEM_PROMOTE_REVIEWS=1 \
  bash "$SCRIPTS/codex-doctor.sh" --autonomous
assert_zero_turns
assert_rc 1 "git absent"
assert_file_contains "$OUT" "FAIL  autonomous tree: git is not available"

doctor_autonomous
assert_rc 0 "committed clean repository"
assert_file_contains "$OUT" "ok    autonomous tree=clean — HEAD present"

# --- effective worktree mode -------------------------------------------------
doctor_autonomous TANDEM_WORKTREE=bogus
assert_rc 1 "worktree unknown value"
assert_file_contains "$OUT" "FAIL  TANDEM_WORKTREE='bogus' is invalid"

doctor_autonomous TANDEM_WORKTREE=
assert_rc 1 "worktree set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_WORKTREE='' is invalid"

doctor_autonomous TANDEM_WORKTREE=1
assert_rc 0 "worktree enabled"
assert_file_contains "$OUT" "ok    worktree=worktree"

doctor_autonomous
assert_rc 0 "worktree unset"
assert_file_contains "$OUT" "ok    worktree=in-place"

# --- plan-review transport must be exec -------------------------------------
doctor_autonomous
assert_rc 0 "transport unset"
assert_file_contains "$OUT" "ok    transport=exec (default)"

doctor_autonomous TANDEM_TRANSPORT=exec
assert_rc 0 "transport explicitly exec"
assert_file_contains "$OUT" "ok    transport=exec"

doctor_autonomous TANDEM_TRANSPORT=mcp
assert_rc 1 "mcp cannot launch the plan review"
assert_file_contains "$OUT" "FAIL  TANDEM_TRANSPORT='mcp'"
assert_file_contains "$OUT" "plan review exit 64 on its first launch"

doctor_autonomous TANDEM_TRANSPORT=
assert_rc 1 "transport set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_TRANSPORT=''"

doctor_autonomous TANDEM_TRANSPORT=bogus
assert_rc 1 "transport unknown value"
assert_file_contains "$OUT" "FAIL  TANDEM_TRANSPORT='bogus'"

# --- autonomous tri-state ---------------------------------------------------
doctor_autonomous
assert_rc 0 "autonomous flag unset but ready"
assert_file_contains "$OUT" "ok    autonomous=ready (not enabled"

doctor_autonomous TANDEM_AUTONOMOUS=0
assert_rc 0 "autonomous flag explicitly off but ready"
assert_file_contains "$OUT" "ok    autonomous=ready (not enabled"

doctor_autonomous TANDEM_AUTONOMOUS=1
assert_rc 0 "autonomous flag active"
assert_file_contains "$OUT" "ok    autonomous=1 (active"

doctor_autonomous TANDEM_AUTONOMOUS=
assert_rc 1 "autonomous flag set but empty"
assert_file_contains "$OUT" "FAIL  TANDEM_AUTONOMOUS='' is invalid"

doctor_autonomous TANDEM_AUTONOMOUS=bogus
assert_rc 1 "autonomous flag unknown value"
assert_file_contains "$OUT" "FAIL  TANDEM_AUTONOMOUS='bogus' is invalid"

# --- exec watchdog ----------------------------------------------------------
doctor_autonomous
assert_rc 0 "exec timeout unset"
assert_file_contains "$OUT" "ok    TANDEM_EXEC_TIMEOUT_SECONDS=role defaults"

doctor_autonomous TANDEM_EXEC_TIMEOUT_SECONDS=540
assert_rc 0 "exec timeout positive"
assert_file_contains "$OUT" "ok    TANDEM_EXEC_TIMEOUT_SECONDS=540"

doctor_autonomous TANDEM_EXEC_TIMEOUT_SECONDS=
assert_rc 1 "exec timeout empty"
assert_file_contains "$OUT" "FAIL  TANDEM_EXEC_TIMEOUT_SECONDS='' is invalid"

doctor_autonomous TANDEM_EXEC_TIMEOUT_SECONDS=abc
assert_rc 1 "exec timeout non-numeric"
assert_file_contains "$OUT" "FAIL  TANDEM_EXEC_TIMEOUT_SECONDS='abc' is invalid"

doctor_autonomous TANDEM_EXEC_TIMEOUT_SECONDS=0
assert_rc 1 "exec timeout zero"
assert_file_contains "$OUT" "FAIL  TANDEM_EXEC_TIMEOUT_SECONDS='0' is invalid"

# --- turn effort must be absent, even when the value is wrapper-valid --------
doctor_autonomous
assert_rc 0 "turn effort unset"
assert_file_contains "$OUT" "ok    TANDEM_TURN_EFFORT=unset"

doctor_autonomous TANDEM_TURN_EFFORT=
assert_rc 1 "turn effort empty"
assert_file_contains "$OUT" "FAIL  TANDEM_TURN_EFFORT='' must be unset"
assert_file_contains "$OUT" "round 2+ resume exit 64"

doctor_autonomous TANDEM_TURN_EFFORT=bogus
assert_rc 1 "turn effort invalid"
assert_file_contains "$OUT" "FAIL  TANDEM_TURN_EFFORT='bogus' must be unset"
assert_file_contains "$OUT" "round 2+ resume exit 64"

doctor_autonomous TANDEM_TURN_EFFORT=low
assert_rc 1 "valid turn effort must still not be exported"
assert_file_contains "$OUT" "FAIL  TANDEM_TURN_EFFORT='low' must be unset"
assert_file_contains "$OUT" "global export would degrade substantive round 2+ resumes"

# --- Codex cwd is physically equivalent to the project root -----------------
doctor_autonomous
assert_rc 0 "Codex cwd unset"
assert_file_contains "$OUT" "ok    TANDEM_CODEX_CWD=unset"

doctor_autonomous TANDEM_CODEX_CWD="$CLAUDE_PROJECT_DIR"
assert_rc 0 "Codex cwd equals project root"
assert_file_contains "$OUT" "ok    TANDEM_CODEX_CWD=$CLAUDE_PROJECT_DIR — resolves to the project root"

ln -s "$CLAUDE_PROJECT_DIR" "$SANDBOX/project-link"
doctor_autonomous TANDEM_CODEX_CWD="$SANDBOX/project-link"
assert_rc 0 "Codex cwd symlink resolves to project root"
assert_file_contains "$OUT" "ok    TANDEM_CODEX_CWD=$SANDBOX/project-link — resolves to the project root"

doctor_autonomous TANDEM_CODEX_CWD=
assert_rc 1 "Codex cwd empty"
assert_file_contains "$OUT" "FAIL  TANDEM_CODEX_CWD='' is invalid"

doctor_autonomous TANDEM_CODEX_CWD="$SANDBOX/missing"
assert_rc 1 "Codex cwd missing"
assert_file_contains "$OUT" "FAIL  TANDEM_CODEX_CWD='$SANDBOX/missing' is not an existing directory"

mkdir -p "$SANDBOX/other-repo"
doctor_autonomous TANDEM_CODEX_CWD="$SANDBOX/other-repo"
assert_rc 1 "Codex cwd points elsewhere"
assert_file_contains "$OUT" "FAIL  TANDEM_CODEX_CWD='$SANDBOX/other-repo' resolves outside the project root"
assert_file_contains "$OUT" "plan reviewer would inspect a different repository"

# --- combining --autonomous with --smoke adds no turn beyond smoke's contract -
reset_stub
run env TANDEM_IMPLEMENTER=sol TANDEM_PROMOTE_REVIEWS=1 \
  bash "$SCRIPTS/codex-doctor.sh" --autonomous --smoke
assert_rc 0 "autonomous plus smoke"
assert_file_contains "$OUT" "autonomous preflight (--autonomous):"
assert_file_contains "$OUT" "model smoke (--smoke):"
assert_eq "2" "$(turns)" "one turn per unique configured model, none for autonomous"
assert_no_file "$CODEX_STUB_LOG.argv.3"

# --- usage and default mode remain bounded and explicit ----------------------
reset_stub
run env TANDEM_IMPLEMENTER=sol bash "$SCRIPTS/codex-doctor.sh" --bogus
assert_rc 64 "unknown argument"
assert_eq "" "$(cat "$OUT")" "unknown argument prints no stdout"
assert_eq $'tandem: unknown argument: --bogus\nusage: codex-doctor.sh [--smoke] [--autonomous]' \
  "$(cat "$ERR")" "complete usage error"
assert_eq "0" "$(turns)" "unknown argument spends no turns"

reset_stub
run env TANDEM_IMPLEMENTER=sol bash "$SCRIPTS/codex-doctor.sh"
assert_rc 0 "default doctor"
assert_not_contains "$OUT" "autonomous preflight"
assert_not_contains "$OUT" "WARN  permission prompts"
assert_eq "0" "$(turns)" "default doctor spends no turns"

# --- the run skill invokes the preflight through a path it actually defines ---
# skills/run/SKILL.md never sets SCRIPTS (it orchestrates sibling skills), so the
# documented command must resolve from CLAUDE_SKILL_DIR, never from $SCRIPTS.
RUN_SKILL="$REPO_ROOT/skills/run/SKILL.md"
assert_file "$RUN_SKILL"
assert_file_contains "$RUN_SKILL" \
  'bash "${CLAUDE_SKILL_DIR}/../../scripts/codex-doctor.sh" --autonomous'
assert_not_contains "$RUN_SKILL" '$SCRIPTS/codex-doctor.sh'

