#!/usr/bin/env bash
# tandem tests — the runner. Pure bash 3.2, no dependencies beyond jq and git.
#
#   bash tests/run.sh              # every tests/*.test.sh
#   bash tests/run.sh statusline   # only cases whose name contains "statusline"
#   TESTS_BASH=/bin/bash bash tests/run.sh    # replicate the macOS CI job
#
# Isolation is the hard rule here (incident 2026-07-20: a test wrote .tandem/
# into the real checkout). Every case gets its own sandbox and runs under
# `env -i` with an explicit allowlist, so the developer's HOME, CLAUDE_CONFIG_DIR
# and a real `codex` on PATH are structurally unreachable.
#
# Env knobs:
#   TESTS_BASH              bash used to run each case (default: the one running us)
#   TEST_TIMEOUT            per-case watchdog, seconds (default 60)
#   RUNNER_TEMP             where sandboxes live (default $TMPDIR); CI sets it
#   TANDEM_TEST_CASES_DIR   directory scanned for *.test.sh (default: tests/)

set -uo pipefail

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd -P)"
CASES_DIR="${TANDEM_TEST_CASES_DIR:-$TESTS_DIR}"
CASES_DIR="$(CDPATH='' cd -- "$CASES_DIR" && pwd -P)"
TESTS_BASH="${TESTS_BASH:-${BASH:-/bin/bash}}"
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"
FILTER="${1:-}"

fatal() {
  printf 'FATAL: %s\n' "$1" >&2
  exit 2
}

[ -x "$TESTS_BASH" ] || fatal "TESTS_BASH is not executable: $TESTS_BASH"
command -v jq >/dev/null 2>&1 || fatal "jq is required to run the suite"
command -v git >/dev/null 2>&1 || fatal "git is required to run the suite"

JQ_BIN="$(command -v jq)"
GIT_BIN="$(command -v git)"

# Physical path once, up front: on macOS $TMPDIR is /var/… which is a symlink to
# /private/var, and every expectation in the suite is derived from the physical
# form (scripts canonicalize with `cd … && pwd`).
_tmp_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
_tmp_base="$(CDPATH='' cd -- "$_tmp_base" 2>/dev/null && pwd -P)" \
  || fatal "cannot resolve temp directory: ${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
RUNNER_TMP="$(mktemp -d "$_tmp_base/tandem-tests.XXXXXX")" \
  || fatal "cannot create the runner temp directory under $_tmp_base"
RUNNER_TMP="$(CDPATH='' cd -- "$RUNNER_TMP" && pwd -P)"

# --- sandbox construction ---------------------------------------------------
# $SANDBOX/tools holds symlinks to the two external binaries the scripts need
# and nothing else. Never the directory they live in: /opt/homebrew/bin also
# contains bash 5 and, quite possibly, the developer's real `codex`.
make_sandbox() {
  local name="$1" sb
  sb="$RUNNER_TMP/$name"
  mkdir -p "$sb/bin" "$sb/home" "$sb/tmp" "$sb/project" "$sb/claude-config" "$sb/tools"
  cp "$TESTS_DIR/stub/codex" "$sb/bin/codex" || return 1
  chmod +x "$sb/bin/codex"
  ln -sf "$JQ_BIN" "$sb/tools/jq"
  ln -sf "$GIT_BIN" "$sb/tools/git"
  printf '%s' "$sb"
}

sandbox_path() {
  printf '%s' "$1/bin:$1/tools:/usr/bin:/bin:/usr/sbin:/sbin"
}

# scrubbed_env <sandbox> <cmd…> — the ONLY way a case is started. Adding a new
# variable to the allowlist is a deliberate act: the scripts' environment
# contract stays explicit.
scrubbed_env() {
  local sb="$1"
  shift
  env -i \
    PATH="$(sandbox_path "$sb")" \
    HOME="$sb/home" \
    TMPDIR="$sb/tmp" \
    CLAUDE_PROJECT_DIR="$sb/project" \
    CLAUDE_CONFIG_DIR="$sb/claude-config" \
    CODEX_STUB_LOG="$sb/stub" \
    REPO_ROOT="$REPO_ROOT" \
    TESTS_DIR="$TESTS_DIR" \
    TESTS_BASH="$TESTS_BASH" \
    SANDBOX="$sb" \
    TEST_NAME="$(basename "$sb")" \
    TERM=dumb \
    LC_ALL=C \
    "$@"
}

# --- self-check: prove the isolation before trusting a single assertion ------
self_check() {
  local sb got want
  sb="$(make_sandbox _selfcheck)" || fatal "cannot build the self-check sandbox"

  got="$(scrubbed_env "$sb" "$TESTS_BASH" -c 'command -v codex' 2>/dev/null)"
  [ "$got" = "$sb/bin/codex" ] \
    || fatal "codex does not resolve to the stub inside the scrubbed env (got: ${got:-<nothing>})"

  want="$("$TESTS_BASH" -c 'printf %s "$BASH_VERSION"')"
  got="$(scrubbed_env "$sb" "$TESTS_BASH" -c 'bash -c '\''printf %s "$BASH_VERSION"'\''' 2>/dev/null)"
  if [ "$got" != "$want" ]; then
    fatal "bash mismatch: TESTS_BASH ($TESTS_BASH) is $want but \`bash\` on the sandbox PATH is ${got:-<nothing>}.
       Set TESTS_BASH=/bin/bash to test the platform bash (this is what CI does)."
  fi

  got="$(scrubbed_env "$sb" "$TESTS_BASH" -c 'printf %s "${SOME_LEAKED_VAR:-clean}"' 2>/dev/null)"
  [ "$got" = "clean" ] || fatal "env -i did not scrub the environment"

  rm -rf "$sb"
}

# --- watchdog ---------------------------------------------------------------
# A plain background job SHARES the runner's process group in bash 3.2, so
# `kill -- -$!` would take the runner down with it. Each case is therefore
# launched with job control on so it leads its own group, the group is verified
# to exist before the watchdog is armed, and the timeout kills the whole group —
# a hung stub must not leave tee/jq orphans behind.
watchdog() {
  local pid="$1" secs="$2" marker="$3" group="$4" i=0
  while [ "$i" -lt "$secs" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || return 0
  : >"$marker"
  if [ "$group" = "1" ]; then
    kill -TERM -- -"$pid" 2>/dev/null
    sleep 2
    kill -KILL -- -"$pid" 2>/dev/null
  else
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL "$pid" 2>/dev/null
  fi
  return 0
}

# --- main -------------------------------------------------------------------
self_check

CASE_LIST="$(find "$CASES_DIR" -maxdepth 1 -type f -name '*.test.sh' 2>/dev/null | LC_ALL=C sort)"
[ -n "$CASE_LIST" ] || fatal "no *.test.sh found in $CASES_DIR"

PASSED=0
FAILED=0
TIMEDOUT=0
FAILED_NAMES=""

printf 'tandem tests — bash %s · %s · timeout %ss\n' \
  "$("$TESTS_BASH" -c 'printf %s "$BASH_VERSION"')" "$RUNNER_TMP" "$TEST_TIMEOUT"

while IFS= read -r case_file; do
  [ -n "$case_file" ] || continue
  name="$(basename "$case_file" .test.sh)"
  case "$name" in
    *"$FILTER"*) : ;;
    *) continue ;;
  esac

  sb="$(make_sandbox "$name")" || fatal "cannot build the sandbox for $name"
  log="$sb/test.log"
  marker="$sb/.timeout"

  # Job control ON only around the fork, so the case leads its own process group.
  set -m
  ( cd "$sb/project" && scrubbed_env "$sb" "$TESTS_BASH" "$case_file" ) \
    >"$log" 2>&1 </dev/null &
  pid=$!
  set +m

  group=0
  if kill -0 -- -"$pid" 2>/dev/null; then group=1; fi

  watchdog "$pid" "$TEST_TIMEOUT" "$marker" "$group" &
  wd=$!

  rc=0
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null

  if [ -f "$marker" ]; then
    TIMEDOUT=$((TIMEDOUT + 1))
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    if [ "$group" = "1" ]; then scope="group kill"; else scope="pid kill (NO process group)"; fi
    printf 'TIMEOUT %s (after %ss, %s)\n' "$name" "$TEST_TIMEOUT" "$scope"
    printf -- '--- last 40 lines: %s ---\n' "$log"
    tail -n 40 "$log" 2>/dev/null
  elif [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    printf 'ok %s\n' "$name"
    rm -rf "$sb"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    printf 'FAIL %s rc=%s\n' "$name" "$rc"
    printf -- '--- last 40 lines: %s ---\n' "$log"
    tail -n 40 "$log" 2>/dev/null
  fi
done <<EOF
$CASE_LIST
EOF

printf '\n%s passed, %s failed' "$PASSED" "$FAILED"
[ "$TIMEDOUT" -gt 0 ] && printf ' (%s timed out)' "$TIMEDOUT"
printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  printf 'sandboxes kept for inspection under %s\n' "$RUNNER_TMP"
  exit 1
fi
rmdir "$RUNNER_TMP" 2>/dev/null
exit 0
