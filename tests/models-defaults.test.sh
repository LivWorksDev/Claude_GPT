#!/usr/bin/env bash
# scripts/_models.sh — the one place where the default model of every seat lives.
#
# Four contracts. (1) The mapping itself, seat by seat, and the answer for a
# seat that does not exist: no output and rc 1, never an empty string that would
# reach `--model` in silence. (2) The no-side-effects contract that lets
# codex-doctor.sh source the helper without _common.sh: sourcing it into a clean
# shell changes nothing but the one function it defines. (3) Two static sweeps
# that keep the source single: no 5.6 literal left in scripts/ or skills/, and no
# default model assigned anywhere else. (4) resolve_role, the wrappers' side of
# the wiring: every role gets the model of its own seat.
#
# The expected models are WRITTEN HERE and never read back from _models.sh: a
# test that derived its expectation from the source would stay green through an
# accidental change of a default, and catching that is the job of this file and
# of the argv tests that carry the same literals.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

MODELS="$SCRIPTS/_models.sh"
assert_file "$MODELS"

seat_model() (
  # shellcheck source=../scripts/_models.sh
  . "$MODELS"
  tandem_default_model "$@"
)

# --- 1. the mapping, byte for byte, and the unknown seat ---------------------
check_seat() {
  # check_seat <seat> <model> — exactly the model's bytes: no newline, no stderr.
  local seat="$1" want="$2"
  seat_model "$seat" >"$SANDBOX/seat.out" 2>"$SANDBOX/seat.err" \
    || fail "seat $seat: expected exit 0, got $?"
  printf '%s' "$want" >"$SANDBOX/seat.want"
  cmp -s "$SANDBOX/seat.want" "$SANDBOX/seat.out" \
    || fail "seat $seat: expected exactly [$want], got [$(cat "$SANDBOX/seat.out")]"
  [ ! -s "$SANDBOX/seat.err" ] || fail "seat $seat wrote to stderr: $(cat "$SANDBOX/seat.err")"
}

check_seat review gpt-6-astra
check_seat implement gpt-6-sol
check_seat image gpt-6-sol
check_seat ultra-judge gpt-6-astra
check_seat ultra-worker gpt-6-sol
check_seat ultra-scout gpt-6-luna

check_unknown() {
  # check_unknown <label> [seat…] — rc 1 and NOTHING on either stream.
  local label="$1" rc=0
  shift
  seat_model "$@" >"$SANDBOX/seat.out" 2>"$SANDBOX/seat.err" || rc=$?
  assert_eq "1" "$rc" "unknown seat ($label): exit code"
  [ ! -s "$SANDBOX/seat.out" ] \
    || fail "unknown seat ($label) printed on stdout: $(cat "$SANDBOX/seat.out")"
  [ ! -s "$SANDBOX/seat.err" ] \
    || fail "unknown seat ($label) printed on stderr: $(cat "$SANDBOX/seat.err")"
}

check_unknown "a name that is no seat" bogus
check_unknown "a near miss of a real seat" reviewer
check_unknown "the empty string" ''
check_unknown "no argument at all"

# --- 2. the contract: sourcing it changes NOTHING but the one function --------
# The snapshots are taken by a separate CLEAN shell (no profile, no rc file, an
# empty environment but PATH) around the very source, so the comparison is the
# helper's own doing. The harness declares no variable of its own — it would be a
# false positive in the diff it feeds — and takes a WARM-UP snapshot first: the
# first pipeline a bash runs creates PIPESTATUS, which would otherwise show up as
# a variable "added" by whatever happens to be sourced after it. The bash-managed
# dynamic variables that differ between versions are left out of the name list.
SNAP="$SANDBOX/snap"
mkdir -p "$SNAP"
cat >"$SANDBOX/snap.sh" <<'EOF'
snapshot() {
  compgen -v \
    | LC_ALL=C grep -v -E '^(BASH_ARGC|BASH_ARGV|BASH_COMMAND|BASH_LINENO|BASH_REMATCH|BASH_SOURCE|FUNCNAME|_)$' \
    | LC_ALL=C sort >"$1/$2.vars"
  set -o >"$1/$2.options"
  shopt -p >"$1/$2.shopt"
  trap -p >"$1/$2.traps"
  declare -F | LC_ALL=C sort >"$1/$2.functions"
}
snapshot "$2" warmup
snapshot "$2" before
. "$1" >"$2/source.out" 2>"$2/source.err"
printf '%s\n' "$?" >"$2/source.rc"
snapshot "$2" after
EOF
run env -i PATH="$PATH" "${TESTS_BASH:-bash}" --noprofile --norc \
  "$SANDBOX/snap.sh" "$MODELS" "$SNAP"
assert_rc 0 "snapshot harness"

assert_eq "0" "$(cat "$SNAP/source.rc")" "exit status of sourcing"
[ ! -s "$SNAP/source.out" ] || fail "sourcing printed on stdout: $(cat "$SNAP/source.out")"
[ ! -s "$SNAP/source.err" ] || fail "sourcing printed on stderr: $(cat "$SNAP/source.err")"

for kind in vars options shopt traps; do
  if ! cmp -s "$SNAP/before.$kind" "$SNAP/after.$kind"; then
    diff "$SNAP/before.$kind" "$SNAP/after.$kind" >&2
    fail "sourcing changed the shell's $kind"
  fi
done

# Exactly one function appears, and nothing disappears.
assert_eq "declare -f tandem_default_model" \
  "$(comm -13 "$SNAP/before.functions" "$SNAP/after.functions")" \
  "the functions sourcing adds"
assert_eq "" "$(comm -23 "$SNAP/before.functions" "$SNAP/after.functions")" \
  "the functions sourcing removes"

# --- 3. the sweeps that keep the source single --------------------------------
assert_sweep_empty() {
  # assert_sweep_empty <label> <grep args…> — grep must find NOTHING (rc 1). An
  # rc of 2 is a broken sweep, and a broken sweep must never read as a clean one.
  local label="$1"
  shift
  run grep "$@"
  if [ "$RC" = "0" ]; then
    cat "$OUT" >&2
    fail "$label"
  fi
  assert_rc 1 "sweep ran: $label"
}

# tests/fixtures/ is outside both sweeps on purpose: those files are real
# captures of the 5.6 generation and are never edited.
assert_sweep_empty "a gpt-5.6 literal survives in scripts/ or skills/" \
  -r -n -I -i -E 'gpt[- ]?5\.6' "$REPO_ROOT/scripts" "$REPO_ROOT/skills"
# The user-facing documents of the CURRENT policy go stale exactly like code
# does: the README model table, the architecture diagram and the manifests'
# descriptions. History (CHANGELOG, BACKLOG, docs/plans, docs/reviews,
# docs/audits) is left out on purpose — it records what WAS true.
assert_sweep_empty "a gpt-5.6 literal survives in the current-policy documents" \
  -n -I -i -E 'gpt[- ]?5\.6' "$REPO_ROOT/README.md" "$REPO_ROOT/docs/ARCHITECTURE.md" \
  "$REPO_ROOT/.claude-plugin/plugin.json" "$REPO_ROOT/.claude-plugin/marketplace.json"
assert_sweep_empty "a default model is assigned outside scripts/_models.sh" \
  -r -n -E '_MODEL:-gpt-' "$REPO_ROOT/scripts"

# --- 4. resolve_role: every role gets the model of its own seat ---------------
role_model() (
  # The case is about the DEFAULT: no override may be in scope.
  unset TANDEM_REVIEW_MODEL TANDEM_IMPLEMENT_MODEL TANDEM_IMAGE_MODEL
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  resolve_role "$1"
  printf '%s' "$CODEX_MODEL"
)

check_role() {
  # check_role <role> <seat> <model> — the literal pins the default; the
  # comparison with the seat's own line is what notices a role wired to ANOTHER
  # seat once those two seats stop sharing a model.
  local role="$1" seat="$2" want="$3" got
  got="$(role_model "$role")"
  assert_eq "$want" "$got" "resolve_role $role: default model"
  assert_eq "$(seat_model "$seat")" "$got" "resolve_role $role follows the $seat seat"
}

check_role review review gpt-6-astra
check_role ask review gpt-6-astra
check_role implement implement gpt-6-sol
check_role image image gpt-6-sol
