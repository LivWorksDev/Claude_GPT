#!/usr/bin/env bash
# tandem tests — assertion library. Sourced by every tests/*.test.sh.
#
# Deliberately tiny and fail-fast: no bats, no new dependencies, bash 3.2 only
# (no mapfile, no associative arrays, no ${var,,}).
#
# The runner exports SANDBOX, REPO_ROOT, TESTS_DIR, CODEX_STUB_LOG,
# CLAUDE_PROJECT_DIR, CLAUDE_CONFIG_DIR, HOME, TMPDIR, TESTS_BASH, TEST_NAME.

set -uo pipefail

# Unit separator: the transport the scripts use and the separator the stub joins
# argv with.
US=$'\x1f'
ESC=$'\033'

# --- hard guard: never let a test touch the real checkout -------------------
# state_init() writes $CLAUDE_PROJECT_DIR/.tandem unconditionally. A test that
# leaked the developer's project dir (or simply forgot to cd) would create real
# state inside the repo — that already happened once (incident 2026-07-20), so
# it is a FATAL, not a warning.
_guard_outside_repo() {
  local root="${REPO_ROOT:-}" p
  [ -n "$root" ] || return 0
  for p in "$PWD" "${CLAUDE_PROJECT_DIR:-}" "${CLAUDE_CONFIG_DIR:-}" "${HOME:-}"; do
    [ -n "$p" ] || continue
    case "$p/" in
      "$root"/*)
        printf 'FATAL %s: %s is inside the checkout (%s) — refusing to run\n' \
          "${TEST_NAME:-?}" "$p" "$root" >&2
        exit 99
        ;;
    esac
  done
}
_guard_outside_repo

[ -n "${SANDBOX:-}" ] || { printf 'FATAL: SANDBOX is not set\n' >&2; exit 99; }

SCRIPTS="$REPO_ROOT/scripts"
OUT="$SANDBOX/run.out"
ERR="$SANDBOX/run.err"
RC=0

# --- failure reporting ------------------------------------------------------
fail() {
  local i=1 src="?" line="?"
  while [ "$i" -lt "${#BASH_SOURCE[@]}" ]; do
    case "${BASH_SOURCE[$i]}" in
      */lib.sh) : ;;
      *)
        src="${BASH_SOURCE[$i]}"
        line="${BASH_LINENO[$((i - 1))]}"
        break
        ;;
    esac
    i=$((i + 1))
  done
  printf 'ASSERT %s:%s: %s\n' "$src" "$line" "$1" >&2
  exit 1
}

note() { printf '      %s\n' "$*" >&2; }

# --- running things under test ---------------------------------------------
# run <cmd…> — captures stdout in $OUT, stderr in $ERR, exit code in $RC.
# Never aborts: exit codes are the contract under test.
run() {
  RC=0
  "$@" >"$OUT" 2>"$ERR" || RC=$?
  return 0
}

# run_in <dir> <cmd…> — same, from a different working directory.
run_in() {
  local d="$1"
  shift
  RC=0
  ( cd "$d" && "$@" ) >"$OUT" 2>"$ERR" || RC=$?
  return 0
}

# --- assertions -------------------------------------------------------------
# assert_rc <expected> [label] — EXACT equality against $RC. Never `!= 0`:
# "codex failed" and "usage error" are different contracts.
assert_rc() {
  local want="$1" label="${2:-exit code}"
  if [ "$RC" != "$want" ]; then
    printf -- '--- stdout ---\n' >&2; tail -n 20 "$OUT" >&2 2>/dev/null || true
    printf -- '--- stderr ---\n' >&2; tail -n 20 "$ERR" >&2 2>/dev/null || true
    fail "$label: expected $want, got $RC"
  fi
}

assert_eq() {
  local want="$1" got="$2" label="${3:-value}"
  [ "$want" = "$got" ] || fail "$label: expected [$want], got [$got]"
}

assert_file() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_no_file() {
  if [ -e "$1" ]; then fail "expected path to NOT exist: $1"; fi
}

assert_file_contains() {
  local f="$1" needle="$2"
  [ -f "$f" ] || fail "expected file to exist: $f"
  if grep -F -q -- "$needle" "$f"; then return 0; fi
  printf -- '--- %s ---\n' "$f" >&2; tail -n 30 "$f" >&2 2>/dev/null || true
  fail "expected [$needle] in $f"
}

# Negative assertions never use `grep -c` (a zero count still exits 1 and the
# arithmetic hides it); they branch on grep's own status.
assert_not_contains() {
  local f="$1" needle="$2"
  [ -f "$f" ] || return 0
  if grep -F -q -- "$needle" "$f"; then
    fail "did NOT expect [$needle] in $f"
  fi
}

assert_matches() {
  local f="$1" re="$2"
  [ -f "$f" ] || fail "expected file to exist: $f"
  if LC_ALL=C grep -E -q -- "$re" "$f"; then return 0; fi
  printf -- '--- %s ---\n' "$f" >&2; tail -n 30 "$f" >&2 2>/dev/null || true
  fail "expected /$re/ to match in $f"
}

# assert_argv <n> <expected> — byte-for-byte comparison of the stub's recorded
# argv for exec invocation <n>, joined with \x1f. One comparison asserts the
# exact set AND the exact order.
assert_argv() {
  local n="$1" want="$2" f got
  f="$CODEX_STUB_LOG.argv.$n"
  [ -f "$f" ] || fail "no argv recorded for codex invocation $n"
  got="$(cat "$f")"
  if [ "$got" != "$want" ]; then
    printf -- '--- want ---\n%s\n--- got ---\n%s\n' \
      "$(printf '%s' "$want" | tr "$US" '\n')" \
      "$(printf '%s' "$got" | tr "$US" '\n')" >&2
    fail "codex argv #$n mismatch"
  fi
}

assert_json() {
  local f="$1" filter="$2"
  [ -f "$f" ] || fail "expected JSON file to exist: $f"
  if jq -e "$filter" "$f" >/dev/null 2>&1; then return 0; fi
  printf -- '--- %s ---\n' "$f" >&2; cat "$f" >&2 2>/dev/null || true
  fail "jq filter failed: $filter"
}

# assert_no_escapes <file> — used for the NO_COLOR contract of the status line.
assert_no_escapes() {
  local f="$1"
  [ -f "$f" ] || return 0
  if LC_ALL=C grep -q "$ESC" "$f"; then
    fail "expected no ANSI escapes in $f"
  fi
}

# --- fixtures ---------------------------------------------------------------
# make_repo <dir> — a real git checkout so state_init's --git-common-dir path
# and the status line's branch lookup exercise the real code.
make_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q >/dev/null 2>&1 || fail "git init failed in $d"
  git -C "$d" config user.email "tests@tandem.invalid"
  git -C "$d" config user.name "tandem tests"
  git -C "$d" config commit.gpgsign false
}

commit_all() {
  local d="$1" msg="${2:-seed}"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m "$msg" >/dev/null 2>&1 || fail "git commit failed in $d"
}

# tkey <target> — the state key the scripts derive, computed by the REAL
# target_key so tests never hardcode a second implementation of the algorithm.
# (common-target-key asserts the algorithm itself.)
tkey() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  target_key "$1"
)

state_dir() {
  printf '%s' "${CLAUDE_PROJECT_DIR}/.tandem/state/$1"
}

# seed_key <role> <target> — makes the role's state dir and prints the key.
seed_key() {
  local role="$1" target="$2" key dir
  key="$(tkey "$target")"
  dir="$(state_dir "$role")"
  mkdir -p "$dir"
  printf '%s' "$key"
}

# seed_thread <role> <target> <thread-id> [turn] — an existing thread on disk.
seed_thread() {
  local role="$1" target="$2" id="$3" turn="${4:-}" key dir
  key="$(seed_key "$role" "$target")"
  dir="$(state_dir "$role")"
  printf '%s\n' "$id" >"$dir/$key.thread"
  [ -n "$turn" ] && printf '%s\n' "$turn" >"$dir/$key.turn"
  return 0
}

# write_hb <path> [key=value …] — a heartbeat with sane defaults. Numeric keys
# are injected as JSON numbers; the literal value `null` writes a JSON null
# (never the empty string — the status line distinguishes them).
write_hb() {
  local out="$1" now json kv k v
  shift
  mkdir -p "$(dirname "$out")"
  now="$(date +%s)"
  json="$(jq -n --argjson now "$now" '{
    role:"review", model:"gpt-5.6-sol", effort:"xhigh", sandbox:"read-only",
    target:"demo", turn:1, pid:0, started_at:($now - 5), updated_at:$now,
    status:"done", verdict:null, events:null, tokens_in:null, tokens_out:null }')"
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      turn | pid | started_at | updated_at)
        json="$(printf '%s' "$json" | jq --arg k "$k" --argjson v "$v" '.[$k] = $v')"
        ;;
      tokens_in | tokens_out)
        # A number where a number belongs, but a corrupt heartbeat is exactly
        # what the status line has to survive: anything that is not valid JSON
        # is injected as the string it is.
        if [ "$v" = "null" ]; then
          json="$(printf '%s' "$json" | jq --arg k "$k" '.[$k] = null')"
        elif printf '%s' "$v" | jq -e . >/dev/null 2>&1; then
          json="$(printf '%s' "$json" | jq --arg k "$k" --argjson v "$v" '.[$k] = $v')"
        else
          json="$(printf '%s' "$json" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')"
        fi
        ;;
      *)
        if [ "$v" = "null" ]; then
          json="$(printf '%s' "$json" | jq --arg k "$k" '.[$k] = null')"
        else
          json="$(printf '%s' "$json" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')"
        fi
        ;;
    esac
  done
  printf '%s\n' "$json" >"$out"
}

# statusline_payload [<jq-path>=<value> …] — the Claude Code session snapshot
# piped to statusline.sh on stdin. A value that parses as JSON is injected as
# JSON, anything else as a string; the literal `__DELETE__` removes the path.
#   statusline_payload '.context_window.used_percentage=85' \
#                      '.workspace.current_dir=/tmp/x' '.effort=__DELETE__'
statusline_payload() {
  local json kv k v
  json='{"model":{"display_name":"Claude Fable 5"},"effort":{"level":"high"},
         "context_window":{"used_percentage":42.7},"cost":{"total_cost_usd":1.239},
         "workspace":{},"thinking":{"enabled":false}}'
  json="$(printf '%s' "$json" | jq -c '.')"
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    if [ "$v" = "__DELETE__" ]; then
      json="$(printf '%s' "$json" | jq -c "del($k)")"
    elif printf '%s' "$v" | jq . >/dev/null 2>&1; then
      json="$(printf '%s' "$json" | jq -c --argjson v "$v" "$k = \$v")"
    else
      json="$(printf '%s' "$json" | jq -c --arg v "$v" "$k = \$v")"
    fi
  done
  printf '%s' "$json"
}

# wait_for_json <file> <jq-filter> [tries] — poll until a background turn has
# published the state we want to observe. Order, never wall-clock duration.
wait_for_json() {
  local f="$1" filter="$2" tries="${3:-150}" i=0
  while [ "$i" -lt "$tries" ]; do
    if [ -f "$f" ] && jq -e "$filter" "$f" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# make_minbin — a symlink farm with every utility the scripts need EXCEPT jq.
# Prepending only $SANDBOX/bin:$SANDBOX/minbin makes "jq is missing" reachable:
# /usr/bin/jq exists on modern macOS and on both CI runners, so simply dropping
# $SANDBOX/tools from PATH would not hide it.
make_minbin() {
  local d="$SANDBOX/minbin" u p
  mkdir -p "$d"
  for u in bash sh env cat cp mv rm ln mkdir mktemp tee tail head cut tr sed \
    grep egrep date dirname basename cksum sleep chmod touch printf sort wc \
    od cmp expr find kill ls git; do
    p="$(command -v "$u" 2>/dev/null)" || continue
    [ -n "$p" ] || continue
    ln -sf "$p" "$d/$u" 2>/dev/null || true
  done
  rm -f "$d/jq"
  printf '%s' "$d"
}

# stub_stdin <n> / stub_hb <n> — the prompt and the mid-turn heartbeat snapshot
# recorded by the stub for exec invocation <n>.
stub_stdin() { printf '%s' "$CODEX_STUB_LOG.stdin.$1"; }
stub_hb() { printf '%s' "$CODEX_STUB_LOG.hb.$1"; }

# tpl <path> <content…> — writes a prompt template.
tpl() {
  local p="$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" >"$p"
}
