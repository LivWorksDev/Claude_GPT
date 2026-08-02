#!/usr/bin/env bash
# tandem — the Phase 2 decision instrument: preflight probes against
# `codex mcp-server`, with archived evidence and one parseable line per probe.
#
# usage: mcp-probe.sh [--spend] [--only <a|b|c|d>[,…]]
#
#   --spend  ALSO spend the REAL codex turns the live probes need (3 with the
#            default selection). Without it NOTHING is spent: the free preflight
#            still runs, the static verdict of (d) is still emitted, and every
#            live probe reports NOT_RUN. A diagnostic must not spend the user's
#            quota unasked (same contract as codex-doctor.sh --smoke).
#   --only   restrict the run to a comma separated subset. The prerequisite
#            CLOSURE is applied (b → c → a) and shown in the budget: a selection
#            naming `c` or `a` without `b` runs `b` too — never a hidden turn,
#            and never a probe without its prerequisite.
#
# env: TANDEM_MCP_PROBE_TIMEOUT_SECONDS  per-turn watchdog, seconds (default
#      240; a positive integer, anything else is a usage error). It governs the
#      free preflight too, so it is validated on every invocation.
#
# exit codes: 0 everything that ran is PASS/STATIC (or only the preflight ran)
#             1 any FAIL or INDETERMINABLE, or broken machinery
#             3 missing dependency · 64 usage error
#
# The probes, and why each one exists (docs/audits/fase2-mcp-parity.md):
#
#   b home-auth           1 turn — the ONLY thing the source code cannot decide:
#                         does the auth.json copied into a CODEX_HOME owned by
#                         tandem actually authorize a live turn?
#   c frozen-inheritance  1 turn — `codex-reply` must NOT re-read the home's
#                         config.toml. Discriminated by the rollout's last
#                         `turn_context`, never by what the model says.
#   a rollout-resume      1 turn — the hybrid: kill the server, then resurrect
#                         the very same thread with `codex exec resume`.
#   d elicitation-never   0 turns — closed in source, emitted as STATIC and
#                         gated on the audited CLI version. A live demo would
#                         hang a PAID turn that never completes.
#
# Verdict taxonomy, identical in stdout and in every verdict.txt:
#   PASS | FAIL | INDETERMINABLE | STATIC | NOT_RUN
# A watchdog expiry is ALWAYS INDETERMINABLE, never FAIL: it proves nothing
# except "no answer before the deadline". INDETERMINABLE is never green.
#
# This script sources _common.sh and immediately drops `-e`: a diagnosis reports
# EVERY probe and never aborts on the first one (scripts/config-probe.sh).

set -uo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
set +e

# The static verdicts of this script were audited against exactly this CLI. The
# README tells users to install `@latest`, so a newer CLI must NOT inherit a
# green verdict for code it may no longer contain.
MCP_STATIC_AUDITED_VERSION="0.144.4"
# Hostile, and deliberately INNOCUOUS: probe (c) rewrites the ephemeral home's
# config.toml with a bogus model and a different effort. The security fields are
# NEVER touched — see write_probe_config.
MCP_HOSTILE_MODEL="tandem-bogus-model-m19"

usage() { printf 'usage: mcp-probe.sh [--spend] [--only <a|b|c|d>[,…]]\n' >&2; }

# --- arguments ---------------------------------------------------------------
# Fail closed and BEFORE anything is printed or launched: an unknown argument is
# a usage error, never a half-run diagnosis.
SPEND=0
ONLY=""
ONLY_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --spend) SPEND=1 ;;
    --only)
      shift
      [ $# -gt 0 ] || {
        printf 'tandem: --only needs a value (a, b, c or d, comma separated)\n' >&2
        usage
        exit 64
      }
      ONLY="$1"
      ONLY_SET=1
      ;;
    --only=*)
      ONLY="${1#--only=}"
      ONLY_SET=1
      ;;
    *)
      printf 'tandem: unknown argument: %s\n' "$1" >&2
      usage
      exit 64
      ;;
  esac
  shift
done

SEL_A=1
SEL_B=1
SEL_C=1
SEL_D=1
if [ "$ONLY_SET" -eq 1 ]; then
  [ -n "$ONLY" ] || {
    printf 'tandem: --only is empty — name at least one probe (a, b, c or d)\n' >&2
    usage
    exit 64
  }
  SEL_A=0
  SEL_B=0
  SEL_C=0
  SEL_D=0
  only_rest="$ONLY"
  while [ -n "$only_rest" ]; do
    case "$only_rest" in
      *,*)
        only_tok="${only_rest%%,*}"
        only_rest="${only_rest#*,}"
        ;;
      *)
        only_tok="$only_rest"
        only_rest=""
        ;;
    esac
    case "$only_tok" in
      a) SEL_A=1 ;;
      b) SEL_B=1 ;;
      c) SEL_C=1 ;;
      d) SEL_D=1 ;;
      *)
        printf 'tandem: unknown probe in --only: %s (expected a, b, c or d)\n' "$only_tok" >&2
        usage
        exit 64
        ;;
    esac
  done
  # Prerequisite CLOSURE of the b → c → a chain, applied to the SELECTION so the
  # budget below can state it out loud. Running `a` without `b` would either
  # spend a hidden turn or probe nothing at all.
  if [ "$SEL_A" -eq 1 ]; then
    SEL_C=1
    SEL_B=1
  fi
  if [ "$SEL_C" -eq 1 ]; then
    SEL_B=1
  fi
fi

# The watchdog is validated on EVERY invocation, with or without --spend: the
# free preflight runs it too, so a bad value is a usage error either way.
PROBE_TIMEOUT="${TANDEM_MCP_PROBE_TIMEOUT_SECONDS:-240}"
case "$PROBE_TIMEOUT" in
  '' | *[!0-9]*) PROBE_TIMEOUT_BAD=1 ;;
  *)
    PROBE_TIMEOUT_BAD=0
    [ "$((10#$PROBE_TIMEOUT))" -gt 0 ] || PROBE_TIMEOUT_BAD=1
    ;;
esac
if [ "$PROBE_TIMEOUT_BAD" -eq 1 ]; then
  printf 'tandem: TANDEM_MCP_PROBE_TIMEOUT_SECONDS must be a positive integer of seconds (got: "%s")\n' \
    "$PROBE_TIMEOUT" >&2
  usage
  exit 64
fi
PROBE_TIMEOUT="$((10#$PROBE_TIMEOUT))"

need_codex
need_jq

# --- state, evidence ---------------------------------------------------------
ROLE="mcp-probe"
state_init
RUN_DIR="$STATE_DIR/$(date +%Y%m%dT%H%M%S).$$"
mkdir -p "$RUN_DIR/preflight" || die "cannot create the evidence directory: $RUN_DIR" 1

# The seat: read-only, effort and model from the review policy. The sandbox is
# NOT overridable — the probes only ever ask a model to answer a word.
MCP_MODEL="${TANDEM_REVIEW_MODEL:-gpt-5.6-sol}"
MCP_EFFORT="${TANDEM_REVIEW_EFFORT:-xhigh}"
CODEX_SANDBOX="read-only"
case "$MCP_EFFORT" in
  low) MCP_HOSTILE_EFFORT="minimal" ;;
  *) MCP_HOSTILE_EFFORT="low" ;;
esac

# --- the ephemeral CODEX_HOME ------------------------------------------------
# Owned by tandem, under TMPDIR, removed by the traps. The working root of the
# turns is a SIBLING directory, never the home itself: a read-only turn can read
# whatever its cwd contains, and the home holds the copied token.
PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tandem-mcp.XXXXXX" 2>/dev/null)"
if [ -z "${PROBE_TMP:-}" ] || [ ! -d "$PROBE_TMP" ]; then
  die "cannot create a temporary directory under ${TMPDIR:-/tmp}" 3
fi
# CANONICAL from here on. macOS exports TMPDIR with a trailing slash, so mktemp
# hands back `…/T//tandem-mcp.XXXX`: the server normalizes that before echoing it
# back in the rollout's turn_context, and a probe comparing its own string
# against the echoed one reports a mismatch that never happened. Found by the
# first REAL run of this script, where probe (c) said INDETERMINABLE while its
# own evidence showed the inheritance had worked.
PROBE_TMP="$(CDPATH='' cd -- "$PROBE_TMP" 2>/dev/null && pwd -P)"
if [ -z "${PROBE_TMP:-}" ] || [ ! -d "$PROBE_TMP" ]; then
  die "cannot resolve the temporary directory to a physical path" 3
fi
PROBE_HOME="$PROBE_TMP/home"
PROBE_CWD="$PROBE_TMP/cwd"
mkdir -p "$PROBE_HOME" "$PROBE_CWD" || die "cannot populate $PROBE_TMP" 3
chmod 700 "$PROBE_HOME" 2>/dev/null

SERVER_PID=0
SERVER_GROUP=0
EXEC_PID=0
EXEC_GROUP=0
RPC_FD_OPEN=0

# mcp_kill_group <pid> <group> <grace> — the GROUP is what must die, checked
# independently of the leader: during a TERM→KILL grace the leader is often
# already gone while a TERM-resistant descendant keeps the group alive
# (codex-doctor.sh smoke_cleanup).
mcp_kill_group() {
  local pid="$1" group="$2" grace="$3" i=0
  [ "$pid" -gt 0 ] 2>/dev/null || return 0
  if [ "$group" = "1" ] && kill -0 -- -"$pid" 2>/dev/null; then
    kill -TERM -- -"$pid" 2>/dev/null
  elif kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
  fi
  while [ "$i" -lt "$grace" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  if [ "$group" = "1" ] && kill -0 -- -"$pid" 2>/dev/null; then
    kill -KILL -- -"$pid" 2>/dev/null
  elif kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
  fi
  return 0
}

# mcp_server_stop <grace> — EOF first (a well behaved server exits on it), then
# the group. Used both by probe (a), which needs the server GONE, and by the
# cleanup traps.
mcp_server_stop() {
  local grace="${1:-1}"
  if [ "$RPC_FD_OPEN" = "1" ]; then
    exec 3>&-
    RPC_FD_OPEN=0
  fi
  [ "$SERVER_PID" -gt 0 ] 2>/dev/null || return 0
  mcp_kill_group "$SERVER_PID" "$SERVER_GROUP" "$grace"
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=0
  return 0
}

# The evidence under .tandem/ SURVIVES; the ephemeral home (with the copied
# token) never does, and never lands in .tandem/ in the first place.
mcp_cleanup() {
  mcp_server_stop 1
  mcp_kill_group "$EXEC_PID" "$EXEC_GROUP" 1
  EXEC_PID=0
  [ -n "${PROBE_TMP:-}" ] && rm -rf "$PROBE_TMP" 2>/dev/null
  return 0
}
trap 'mcp_cleanup' EXIT
trap 'mcp_cleanup; exit 130' INT
trap 'mcp_cleanup; exit 143' TERM

# The one `--cd` comes from codex_pins, so the working root is fixed HERE,
# before the helper runs: an inherited TANDEM_CODEX_CWD — empty or not — never
# reaches a probe turn, and the probes never run over the user's repo.
TANDEM_CODEX_CWD="$PROBE_CWD"
codex_pins

# --- config.toml of the ephemeral home ---------------------------------------
# toml_value <raw> — the TOML rendering of a pinned value.
toml_value() {
  case "$1" in
    true | false) printf '%s' "$1" ;;
    \[*\]) printf '%s' "$1" ;;
    '' | *[!0-9]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# write_probe_config <model> <effort> — the home's config.toml, written to a
# temp file and moved into place (a half written config is never observable).
#
# SECURITY, non negotiable: the ONLY parameters are the model and the effort.
# Every security field (sandbox_mode, approval_policy, approvals_reviewer,
# sandbox_workspace_write.network_access, .writable_roots, web_search) is
# MIRRORED from CODEX_PINS by construction, so the tandem config and the hostile
# config of probe (c) carry byte-identical security. Degrading them right before
# the turn whose premise is that they are NOT inherited would mean that, if the
# premise is false, a PAID turn runs without containment on the user's machine.
# Probing the inheritance of the security fields would need an independent OS
# sandbox and is OUT OF SCOPE; the rollout's turn_context echoes sandbox and
# approval anyway, so their inheritance is OBSERVED without degrading anything.
write_probe_config() {
  local model="$1" effort="$2" tmp prev="" a key val
  tmp="$PROBE_HOME/.config.toml.tmp.$$"
  {
    printf '# generated by tandem scripts/mcp-probe.sh — ephemeral, never the user'\''s home\n'
    printf 'model = "%s"\n' "$model"
    printf 'model_reasoning_effort = "%s"\n' "$effort"
    for a in "${CODEX_PINS[@]}"; do
      if [ "$prev" = "-c" ]; then
        key="${a%%=*}"
        val="${a#*=}"
        printf '%s = %s\n' "$key" "$(toml_value "$val")"
      fi
      prev="$a"
    done
  } >"$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$PROBE_HOME/config.toml" 2>/dev/null || return 1
  chmod 600 "$PROBE_HOME/config.toml" 2>/dev/null
  return 0
}

# pins_config_json — the same policy as a JSON object for the tool call's
# `config` map (the MCP server takes the dotted config.toml keys there), plus
# the effort, which is not a first class param. One source of truth again:
# CODEX_PINS.
pins_config_json() {
  local prev="" a key val json='{}'
  for a in "${CODEX_PINS[@]}"; do
    if [ "$prev" = "-c" ]; then
      key="${a%%=*}"
      val="${a#*=}"
      case "$val" in
        true | false | \[*\])
          json="$(printf '%s' "$json" | jq -c --arg k "$key" --argjson v "$val" '.[$k] = $v' 2>/dev/null)"
          ;;
        *)
          json="$(printf '%s' "$json" | jq -c --arg k "$key" --arg v "$val" '.[$k] = $v' 2>/dev/null)"
          ;;
      esac
    fi
    prev="$a"
  done
  printf '%s' "$json" | jq -c --arg e "$MCP_EFFORT" '.model_reasoning_effort = $e' 2>/dev/null
}

write_probe_config "$MCP_MODEL" "$MCP_EFFORT" \
  || die "cannot write the probe config.toml under $PROBE_HOME" 1

# --- auth: copied, never invented, never persisted ---------------------------
# The default auth storage is a FILE at <CODEX_HOME>/auth.json (storage.rs
# 150-152). A machine whose login lives in the keyring has no file to copy and
# its keyring entry is keyed by the home, so the probes that authenticate
# degrade to INDETERMINABLE — BEFORE spending anything.
SOURCE_HOME="${CODEX_HOME:-${HOME:-}/.codex}"
AUTH_OK=0
AUTH_REASON="no auth.json in $SOURCE_HOME (keyring-only login?) — run \`CODEX_HOME=$SOURCE_HOME codex login\` so a file-based token exists to copy, then re-run"
if [ -f "$SOURCE_HOME/auth.json" ]; then
  if cp "$SOURCE_HOME/auth.json" "$PROBE_HOME/auth.json" 2>/dev/null; then
    chmod 600 "$PROBE_HOME/auth.json" 2>/dev/null
    AUTH_OK=1
    AUTH_REASON=""
  else
    AUTH_REASON="could not copy $SOURCE_HOME/auth.json into the ephemeral home"
  fi
fi

# --- verdicts ----------------------------------------------------------------
V_PASS=0
V_FAIL=0
V_INDET=0
V_STATIC=0
V_NOTRUN=0
B_PASSED=0
C_PASSED=0
THREAD_ID=""
CODEWORD=""

# verdict <id> <name> <verdict> <reason> <evidence-dir> — ONE parseable line on
# stdout and the SAME token in the probe's verdict.txt.
verdict() {
  local id="$1" name="$2" v="$3" reason="$4" dir="$5"
  mkdir -p "$dir" 2>/dev/null
  {
    printf 'verdict: %s\n' "$v"
    printf 'probe: %s\n' "$id"
    printf 'name: %s\n' "$name"
    printf 'reason: %s\n' "$reason"
    printf 'evidence: %s\n' "$dir"
  } >"$dir/verdict.txt" 2>/dev/null
  printf 'PROBE %s: %s — %s (evidence: %s)\n' "$id" "$v" "$reason" "$dir"
  case "$v" in
    PASS) V_PASS=$((V_PASS + 1)) ;;
    FAIL) V_FAIL=$((V_FAIL + 1)) ;;
    INDETERMINABLE) V_INDET=$((V_INDET + 1)) ;;
    STATIC) V_STATIC=$((V_STATIC + 1)) ;;
    NOT_RUN) V_NOTRUN=$((V_NOTRUN + 1)) ;;
  esac
  return 0
}

# --- the ndjson JSON-RPC client, in pure bash --------------------------------
RPC_IN="$RUN_DIR/preflight/rpc.in.ndjson"
RPC_OUT="$RUN_DIR/preflight/rpc.out.ndjson"
SERVER_ERR="$RUN_DIR/preflight/server.stderr.log"
RPC_FIFO="$PROBE_TMP/rpc.fifo"

# fifo_guard — on BSD, open(2) of a FIFO for WRITING blocks until a reader shows
# up, and a shell blocked inside it cannot be interrupted. The guard unblocks it
# by opening the READ end, and leaves a marker so the caller knows the rendezvous
# never happened (a server that died at startup).
fifo_guard() {
  # This runs FORKED, and the parent stops it with a plain `kill` (TERM). A
  # background subshell inherits the script's trap dispositions, so without this
  # reset the guard would run mcp_cleanup — reaping the very server it exists to
  # protect — and bash warns about the inconsistent trap list on stderr, which an
  # exit-0 run must never print. Resetting is the whole fix: the parent owns the
  # cleanup, a guard never does.
  trap - EXIT INT TERM
  local secs="$1" mark="$2" tmark="$3" fifo="$4" i=0
  while [ "$i" -lt "$secs" ]; do
    [ -f "$mark" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  [ -f "$mark" ] && return 0
  : >"$tmark"
  ( exec 4<"$fifo" ) 2>/dev/null
  return 0
}

rpc_start() {
  local mark="$PROBE_TMP/fifo.opened" tmark="$PROBE_TMP/fifo.timeout" guard
  : >"$RPC_IN"
  : >"$RPC_OUT"
  : >"$SERVER_ERR"
  rm -f "$mark" "$tmark"
  mkfifo "$RPC_FIFO" 2>/dev/null || return 1
  # Job control only around the fork, so the server LEADS its own process group
  # and the cleanup can reap every descendant it spawns.
  set -m
  CODEX_HOME="$PROBE_HOME" codex mcp-server \
    <"$RPC_FIFO" >"$RPC_OUT" 2>"$SERVER_ERR" &
  SERVER_PID=$!
  set +m
  if kill -0 -- -"$SERVER_PID" 2>/dev/null; then SERVER_GROUP=1; fi
  fifo_guard "$PROBE_TIMEOUT" "$mark" "$tmark" "$RPC_FIFO" &
  guard=$!
  # The write end is opened AFTER the fork on purpose: the server's own
  # redirection opens the read end, and the two opens are the rendezvous.
  exec 3>"$RPC_FIFO"
  : >"$mark"
  # The guard exits BY ITSELF within one poll once the mark exists — it is never
  # signalled. Killing a background job while the shell toggles job control
  # (`set -m` around the fork above) is what makes bash 3.2 print
  # `run_pending_traps: bad value in trap_list[15]` on stderr, and an exit-0 run
  # of this script must say nothing there. Waiting costs at most one second.
  wait "$guard" 2>/dev/null
  if [ -f "$tmark" ]; then return 1; fi
  RPC_FD_OPEN=1
  return 0
}

rpc_send() {
  [ "$RPC_FD_OPEN" = "1" ] || return 1
  printf '%s\n' "$1" >>"$RPC_IN"
  printf '%s\n' "$1" >&3 2>/dev/null || return 1
  return 0
}

# rpc_scan <id> <dest> — writes the FIRST complete, parseable frame carrying
# that id into <dest>. Only lines jq accepts are considered, so a half written
# line at the end of the stream is simply skipped and re-polled later.
rpc_scan() {
  jq -Rc --argjson want "$1" \
    'fromjson? | objects | select(.id == $want)' "$RPC_OUT" 2>/dev/null \
    | head -n 1 >"$2" 2>/dev/null
  [ -s "$2" ]
}

# rpc_wait <id> <seconds> <dest> — poll until the frame lands.
# rc 0 = it did (in <dest>) · 1 = deadline · 2 = the server died without
# answering (broken machinery, not a probe verdict).
#
# The polling loop deliberately does NOT run inside a command substitution: a
# subshell does not inherit this script's traps, and the parent blocked on it
# would defer an incoming TERM until the whole deadline expired — an interrupted
# probe must reap its server group in a second, not in four minutes.
rpc_wait() {
  local id="$1" secs="$2" dest="$3" i=0
  : >"$dest"
  while :; do
    if rpc_scan "$id" "$dest"; then return 0; fi
    if [ "$SERVER_PID" -gt 0 ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      # One last scan: the frame may have landed as the server exited.
      if rpc_scan "$id" "$dest"; then return 0; fi
      return 2
    fi
    [ "$i" -lt "$secs" ] || return 1
    sleep 1
    i=$((i + 1))
  done
}

server_tail() {
  LC_ALL=C tail -n 3 "$SERVER_ERR" 2>/dev/null | LC_ALL=C tr '\n' ' ' | LC_ALL=C cut -c1-160
}

# oneline <text> [max] — a reason is ONE line by contract (stdout and
# verdict.txt are parsed field by field), so anything quoted from a server
# answer is flattened and clipped before it gets there.
oneline() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C cut -c1-"${2:-160}"
}

# --- classifiers --------------------------------------------------------------
# mcp_auth_error <file> — true only for auth SEMANTICS, never the mere mention
# of a token (same discipline as the doctor's smoke_model_error).
mcp_auth_error() {
  LC_ALL=C grep -E -i -q \
    -e '(401|403)[^[:cntrl:]]{0,40}(unauthorized|forbidden)' \
    -e 'unauthorized' \
    -e 'not (logged in|authenticated)' \
    -e 'authentication[^[:cntrl:]]{0,60}(failed|required|error|invalid)' \
    -e '(missing|invalid|expired|revoked)[^[:cntrl:]]{0,40}(api key|token|credential|auth)' \
    -e 'codex login' \
    "$1" 2>/dev/null
}

# json_has_value <json> <value> — is <value> one of the STRING values anywhere
# inside <json>? The discriminator of probe (c) is value based on purpose: the
# exact key layout of a rollout item is not audited yet, but a model name is a
# model name wherever it sits.
json_has_value() {
  printf '%s' "$1" | jq -e --arg v "$2" '[.. | strings] | index($v) != null' \
    >/dev/null 2>&1
}

# rollout_for <thread-id> — the rollout file the server wrote for the thread.
# First best effort from the notification stream (the SessionConfigured frame
# carries `rollout_path`, whose exact shape is NOT audited yet, so the lookup is
# value based and tolerant), then the store on disk, which is ours and ephemeral:
# CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<ThreadId>.jsonl (recorder.rs
# 1505-1521).
rollout_for() {
  local tid="$1" p=""
  p="$(jq -Rr 'fromjson? | .. | strings | select(endswith(".jsonl"))' "$RPC_OUT" 2>/dev/null \
    | LC_ALL=C grep -F -- "$tid" | tail -n 1)"
  if [ -n "$p" ] && [ -f "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  p="$(find "$PROBE_HOME/sessions" -type f -name "*$tid*.jsonl" 2>/dev/null | LC_ALL=C sort | tail -n 1)"
  [ -n "$p" ] || return 1
  printf '%s' "$p"
  return 0
}

# last_turn_context <rollout> — the LAST turn_context item of the rollout. Each
# real turn appends one with model/effort/approval_policy/sandbox/cwd
# (turn_context.rs 364-389); the selector is tolerant about the tagging because
# that shape has no captured fixture yet.
last_turn_context() {
  jq -Rc 'fromjson? | objects
    | select(((.type? // "") == "turn_context")
             or ((.item_type? // "") == "turn_context")
             or (has("turn_context")))' "$1" 2>/dev/null | tail -n 1
}

# turn_context_count <rollout> — how many turn_context items the rollout holds.
# A missing file counts 0: probe (c) compares the count before and after its
# continuation, and "no rollout yet" must read as "nothing appended", never as a
# failure that hides one.
turn_context_count() {
  if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    printf '0'
    return 0
  fi
  jq -Rc 'fromjson? | objects
    | select(((.type? // "") == "turn_context")
             or ((.item_type? // "") == "turn_context")
             or (has("turn_context")))' "$1" 2>/dev/null | wc -l | tr -d ' '
}

# result_is_error <frame> — did the tool call answer with isError? An errored
# call ran no turn, so nothing downstream may be read as evidence about it.
result_is_error() {
  [ -f "${1:-}" ] || return 1
  [ "$(jq -r '.result.isError // false' "$1" 2>/dev/null)" = "true" ]
}

# result_text <frame> — the first text block of a tool result, one line, for the
# reason of a verdict.
result_text() {
  [ -f "${1:-}" ] || return 0
  jq -r '[.result.content[]? | select(.type == "text") | .text][0] // ""' "$1" 2>/dev/null \
    | LC_ALL=C tr '\n' ' ' | LC_ALL=C cut -c1-200
}

# result_thread_id <frame> — the threadId the server echoed for this call.
result_thread_id() {
  [ -f "${1:-}" ] || return 0
  jq -r '.result.structuredContent.threadId // empty' "$1" 2>/dev/null
}

# --- header and budget --------------------------------------------------------
CODEX_VERSION_RAW="$(codex --version 2>/dev/null)" || CODEX_VERSION_RAW=""
printf '%s\n' "$CODEX_VERSION_RAW" >"$RUN_DIR/codex-version.txt"

# version_dotted <text> — the strict N.N.N the text announces, or nothing. A
# trailing non numeric suffix is trimmed ("0.0.0-stub" → "0.0.0"); anything that
# is not three decimal fields is undeterminable. Fail closed: a version that
# cannot be read is NOT the audited one.
version_dotted() {
  local rest="$1" tok a r b c
  while [ -n "$rest" ]; do
    tok="${rest%%[[:space:]]*}"
    case "$tok" in
      [0-9]*)
        # NO suffix stripping here, on purpose: this gate decides whether a
        # verdict proved by reading the source of 0.144.4 may be emitted, and
        # `0.144.4-dev` is a build whose source nobody audited. The doctor's
        # parser trims `-beta` because it answers "is this new enough"; this one
        # answers "is this EXACTLY the audited build", so anything but a bare
        # N.N.N token is undeterminable.
        case "$tok" in
          *[!0-9.]*) return 1 ;;
          *.*.*.*) return 1 ;;
          *.*.*) : ;;
          *) return 1 ;;
        esac
        a="${tok%%.*}"
        r="${tok#*.}"
        b="${r%%.*}"
        c="${r#*.}"
        case "$a" in '' | *[!0-9]*) return 1 ;; esac
        case "$b" in '' | *[!0-9]*) return 1 ;; esac
        case "$c" in '' | *[!0-9]*) return 1 ;; esac
        printf '%s.%s.%s' "$a" "$b" "$c"
        return 0
        ;;
    esac
    case "$rest" in
      *[[:space:]]*) rest="${rest#*[[:space:]]}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

CODEX_VERSION="$(version_dotted "$CODEX_VERSION_RAW")" || CODEX_VERSION=""

printf 'tandem mcp-probe — %s\n' "${CODEX_VERSION_RAW:-unknown version}"
printf 'evidence: %s\n' "$RUN_DIR"
printf 'ephemeral CODEX_HOME: %s (removed on exit; auth.json is NEVER written under .tandem/)\n' \
  "$PROBE_HOME"
printf '\n'

# The cost table comes BEFORE anything is launched — the user must be able to
# read what this is about to spend even if the first turn hangs (the literal
# contract of codex-doctor.sh --smoke).
BUDGET_TOTAL=0
printf 'budget (b → c → a is a dependency chain; the selection below is its closure):\n'
if [ "$SEL_B" -eq 1 ]; then
  printf '  probe b  home-auth            1 REAL codex turn\n'
  BUDGET_TOTAL=$((BUDGET_TOTAL + 1))
fi
if [ "$SEL_C" -eq 1 ]; then
  printf '  probe c  frozen-inheritance   1 REAL codex turn\n'
  BUDGET_TOTAL=$((BUDGET_TOTAL + 1))
fi
if [ "$SEL_A" -eq 1 ]; then
  printf '  probe a  rollout-resume       1 REAL codex turn\n'
  BUDGET_TOTAL=$((BUDGET_TOTAL + 1))
fi
if [ "$SEL_D" -eq 1 ]; then
  printf '  probe d  elicitation-never    0 turns (STATIC verdict, audited %s)\n' \
    "$MCP_STATIC_AUDITED_VERSION"
fi
printf 'total: %s REAL codex turns\n' "$BUDGET_TOTAL"
if [ "$SPEND" -eq 0 ]; then
  # %s, never a literal leading `--`: printf would read it as its own option.
  printf '%s\n' '--spend not given: nothing is spent, every live probe reports NOT_RUN (requires --spend)'
fi
printf '\n'

# --- preflight: free, always, and it blames ITSELF ---------------------------
# The handshake needs no auth (confirmed in the audit), so it costs nothing. If
# it breaks, the machinery is broken and every live probe is INDETERMINABLE — a
# missing `mcp-server` subcommand on an old CLI is never a probe's FAIL.
PREFLIGHT_OK=0
PREFLIGHT_REASON=""
printf 'preflight (free — no model turn):\n'

preflight() {
  local rc=0
  if ! rpc_start; then
    PREFLIGHT_REASON="could not start \`codex mcp-server\` (fifo/spawn failed): $(server_tail)"
    return 1
  fi
  if ! rpc_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tandem-mcp-probe","version":"1"}}}'; then
    PREFLIGHT_REASON="could not write to the server's stdin: $(server_tail)"
    return 1
  fi
  rpc_wait 1 "$PROBE_TIMEOUT" "$RUN_DIR/preflight/initialize.json" || rc=$?
  case "$rc" in
    0) : ;;
    2)
      PREFLIGHT_REASON="\`codex mcp-server\` exited before answering initialize (old CLI without the subcommand?): $(server_tail)"
      return 1
      ;;
    *)
      PREFLIGHT_REASON="no answer to initialize within ${PROBE_TIMEOUT}s: $(server_tail)"
      return 1
      ;;
  esac
  rpc_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  if ! rpc_send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'; then
    PREFLIGHT_REASON="could not request tools/list: $(server_tail)"
    return 1
  fi
  rc=0
  rpc_wait 2 "$PROBE_TIMEOUT" "$RUN_DIR/preflight/tools.json" || rc=$?
  case "$rc" in
    0) : ;;
    2)
      PREFLIGHT_REASON="the server exited before answering tools/list: $(server_tail)"
      return 1
      ;;
    *)
      PREFLIGHT_REASON="no answer to tools/list within ${PROBE_TIMEOUT}s: $(server_tail)"
      return 1
      ;;
  esac
  if ! jq -e '
      [.result.tools[]?.name] as $n
      | (($n | index("codex")) != null) and (($n | index("codex-reply")) != null)' \
      "$RUN_DIR/preflight/tools.json" >/dev/null 2>&1; then
    PREFLIGHT_REASON="the server did not advertise both tools (codex, codex-reply) — see $RUN_DIR/preflight/tools.json"
    return 1
  fi
  return 0
}

if preflight; then
  PREFLIGHT_OK=1
  printf '  ok    handshake: initialize + tools/list, tools codex and codex-reply present\n'
  printf '        %s\n' "$RUN_DIR/preflight/tools.json"
else
  printf '  BROKEN  %s\n' "$PREFLIGHT_REASON"
  printf '          the probe machinery is at fault, not the transport under test\n'
fi
printf '\n'

# --- the probes ---------------------------------------------------------------
codeword_new() {
  local w
  w="$(LC_ALL=C od -An -tx1 -N8 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'a-f0-9')"
  [ -n "$w" ] || w="$(date +%s)$$"
  printf 'TDM-%s' "$w"
}

# probe_b — home-auth. The only unavoidable turn: does the copied token
# authorize a live turn from a CODEX_HOME owned by tandem?
probe_b() {
  local dir="$RUN_DIR/probe-b" args req frame tid content errtxt rc=0
  mkdir -p "$dir"
  if [ "$PREFLIGHT_OK" -ne 1 ]; then
    verdict b home-auth INDETERMINABLE "preflight broken: $PREFLIGHT_REASON" "$dir"
    return 0
  fi
  if [ "$SPEND" -ne 1 ]; then
    verdict b home-auth NOT_RUN "requires --spend (1 REAL codex turn)" "$dir"
    return 0
  fi
  if [ "$AUTH_OK" -ne 1 ]; then
    verdict b home-auth INDETERMINABLE "$AUTH_REASON" "$dir"
    return 0
  fi
  CODEWORD="$(codeword_new)"
  args="$(jq -nc \
    --arg p "This is a tandem MCP preflight probe. Remember the codeword below for the rest of this thread.
codeword: $CODEWORD
Reply with exactly: OK" \
    --arg m "$MCP_MODEL" \
    --arg s "$CODEX_SANDBOX" \
    --arg cwd "$PROBE_CWD" \
    --argjson cfg "$(pins_config_json)" \
    '{prompt:$p, model:$m, sandbox:$s, "approval-policy":"never", cwd:$cwd, config:$cfg}' 2>/dev/null)"
  if [ -z "$args" ]; then
    verdict b home-auth INDETERMINABLE "could not build the tool call arguments (jq)" "$dir"
    return 0
  fi
  req="$(jq -nc --argjson a "$args" \
    '{jsonrpc:"2.0", id:3, method:"tools/call", params:{name:"codex", arguments:$a}}' 2>/dev/null)"
  printf '%s\n' "$req" >"$dir/request.json"
  if ! rpc_send "$req"; then
    verdict b home-auth INDETERMINABLE "could not send the tool call: $(server_tail)" "$dir"
    return 0
  fi
  rpc_wait 3 "$PROBE_TIMEOUT" "$dir/result.json" || rc=$?
  case "$rc" in
    0) : ;;
    2)
      verdict b home-auth INDETERMINABLE "the server exited before answering the call: $(server_tail)" "$dir"
      return 0
      ;;
    *)
      # A watchdog expiry is ALWAYS INDETERMINABLE: it proves nothing but "no
      # answer before the deadline".
      verdict b home-auth INDETERMINABLE "no answer within ${PROBE_TIMEOUT}s — watchdog expired (proves nothing about auth)" "$dir"
      return 0
      ;;
  esac
  frame="$(cat "$dir/result.json" 2>/dev/null)"
  # Evidence for the next probes: whatever the stream said about this thread.
  jq -Rc 'fromjson? | objects | select(has("id") | not)' "$RPC_OUT" 2>/dev/null \
    >"$dir/notifications.ndjson"
  tid="$(printf '%s' "$frame" | jq -r '.result.structuredContent.threadId // empty' 2>/dev/null)"
  content="$(printf '%s' "$frame" | jq -r '.result.structuredContent.content // empty' 2>/dev/null)"
  if [ -n "$tid" ] && [ -n "$content" ] \
    && ! printf '%s' "$frame" | jq -e '.result.isError == true' >/dev/null 2>&1; then
    THREAD_ID="$tid"
    B_PASSED=1
    printf '%s\n' "$tid" >"$dir/thread-id.txt"
    verdict b home-auth PASS "the copied auth.json authorized a live turn from the tandem CODEX_HOME (threadId $tid)" "$dir"
    return 0
  fi
  errtxt="$(printf '%s' "$frame" | jq -r '
    [ .error.message?, (.result.content[]?.text?) ]
    | map(select(. != null)) | join(" ")' 2>/dev/null)"
  printf '%s\n' "$errtxt" >"$dir/error.txt"
  LC_ALL=C tail -n 20 "$SERVER_ERR" >>"$dir/error.txt" 2>/dev/null
  if mcp_auth_error "$dir/error.txt"; then
    verdict b home-auth FAIL "the turn was rejected with AUTH semantics — the token copied into the tandem CODEX_HOME does not authorize: $(oneline "$errtxt" 120)" "$dir"
  else
    verdict b home-auth INDETERMINABLE "the call did not return a threadId and the error has no auth semantics: $(oneline "$errtxt" 120)" "$dir"
  fi
  return 0
}

# probe_c — frozen inheritance. Between the two calls the home's config.toml is
# rewritten with an INNOCUOUS hostile model/effort (security fields untouched,
# see write_probe_config), and the discriminator is the rollout's last
# turn_context: direct evidence of the turn's effective config, which a polite
# model cannot fake.
probe_c() {
  local dir="$RUN_DIR/probe-c" req rollout tc rc=0 rollout_pre="" tc_before=0 tc_after=0 got_t=""
  # The rollout as it stands BEFORE the continuation: its turn_context count is
  # the baseline that makes "the continuation appended one" checkable.
  rollout_pre="$(rollout_for "${THREAD_ID:-}" 2>/dev/null || true)"
  mkdir -p "$dir"
  if [ "$PREFLIGHT_OK" -ne 1 ]; then
    verdict c frozen-inheritance INDETERMINABLE "preflight broken: $PREFLIGHT_REASON" "$dir"
    return 0
  fi
  if [ "$SPEND" -ne 1 ]; then
    verdict c frozen-inheritance NOT_RUN "requires --spend (1 REAL codex turn)" "$dir"
    return 0
  fi
  if [ "$B_PASSED" -ne 1 ] || [ -z "$THREAD_ID" ]; then
    verdict c frozen-inheritance NOT_RUN "dependencia b no superada" "$dir"
    return 0
  fi
  cp "$PROBE_HOME/config.toml" "$dir/config.pre.toml" 2>/dev/null
  if ! write_probe_config "$MCP_HOSTILE_MODEL" "$MCP_HOSTILE_EFFORT"; then
    verdict c frozen-inheritance INDETERMINABLE "could not rewrite the ephemeral config.toml" "$dir"
    return 0
  fi
  cp "$PROBE_HOME/config.toml" "$dir/config.post.toml" 2>/dev/null
  # The count BEFORE the call is SENT, not merely before its answer: the server
  # appends the turn_context early in the turn, so counting after `rpc_send`
  # races with it and would turn a perfectly good paid continuation into an
  # INDETERMINABLE now and then.
  tc_before="$(turn_context_count "$rollout_pre")"
  req="$(jq -nc --arg t "$THREAD_ID" \
    --arg p "Still the same thread. Reply with exactly: OK" \
    '{jsonrpc:"2.0", id:4, method:"tools/call",
      params:{name:"codex-reply", arguments:{threadId:$t, prompt:$p}}}' 2>/dev/null)"
  printf '%s\n' "$req" >"$dir/request.json"
  if ! rpc_send "$req"; then
    verdict c frozen-inheritance INDETERMINABLE "could not send the codex-reply call: $(server_tail)" "$dir"
    return 0
  fi
  rpc_wait 4 "$PROBE_TIMEOUT" "$dir/result.json" || rc=$?
  case "$rc" in
    0) : ;;
    2)
      write_probe_config "$MCP_MODEL" "$MCP_EFFORT"
      verdict c frozen-inheritance INDETERMINABLE "the server exited before answering codex-reply: $(server_tail)" "$dir"
      return 0
      ;;
    *)
      write_probe_config "$MCP_MODEL" "$MCP_EFFORT"
      verdict c frozen-inheritance INDETERMINABLE "no answer within ${PROBE_TIMEOUT}s — watchdog expired (proves nothing about inheritance)" "$dir"
      return 0
      ;;
  esac
  # The hostile config has served its purpose: restore the tandem one so probe
  # (a) resumes from a home that carries the policy, not the bait. Both states
  # are archived above.
  write_probe_config "$MCP_MODEL" "$MCP_EFFORT"
  # An ERRORED continuation proves nothing about inheritance — and if it appended
  # no context, the evaluation below would silently re-read probe (b)'s own,
  # certifying a failed call as frozen inheritance.
  if result_is_error "$dir/result.json"; then
    verdict c frozen-inheritance INDETERMINABLE "codex-reply answered with isError — the continuation never ran: $(result_text "$dir/result.json")" "$dir"
    return 0
  fi
  got_t="$(result_thread_id "$dir/result.json")"
  if [ -z "$got_t" ]; then
    # Without the echoed id there is no proof the answer belongs to the thread
    # whose inheritance is being judged — the same rule probe (a) applies.
    verdict c frozen-inheritance INDETERMINABLE "codex-reply answered without echoing a threadId — the result cannot be tied to $THREAD_ID" "$dir"
    return 0
  fi
  if [ "$got_t" != "$THREAD_ID" ]; then
    verdict c frozen-inheritance FAIL "codex-reply answered for thread $got_t instead of $THREAD_ID" "$dir"
    return 0
  fi
  if ! rollout="$(rollout_for "$THREAD_ID")"; then
    verdict c frozen-inheritance INDETERMINABLE "no rollout found for $THREAD_ID under the probe CODEX_HOME — nothing to read the effective config from" "$dir"
    return 0
  fi
  cp "$rollout" "$dir/rollout.jsonl" 2>/dev/null
  tc="$(last_turn_context "$rollout")"
  if [ -z "$tc" ]; then
    verdict c frozen-inheritance INDETERMINABLE "the rollout carries no turn_context item — the effective config of the continuation is not observable" "$dir"
    return 0
  fi
  # …and it must be a NEW one: same count as before the call means the
  # continuation appended nothing and the last context is still (b)'s.
  tc_after="$(turn_context_count "$rollout")"
  if [ "$tc_after" -le "$tc_before" ] 2>/dev/null; then
    verdict c frozen-inheritance INDETERMINABLE "the continuation appended no turn_context (${tc_before} → ${tc_after}) — the last one belongs to call 1 and proves nothing" "$dir"
    return 0
  fi
  printf '%s\n' "$tc" >"$dir/turn-context.last.json"
  if json_has_value "$tc" "$MCP_HOSTILE_MODEL" || json_has_value "$tc" "$MCP_HOSTILE_EFFORT"; then
    verdict c frozen-inheritance FAIL "the continuation's turn_context echoes the HOSTILE config ($MCP_HOSTILE_MODEL / $MCP_HOSTILE_EFFORT) — codex-reply re-read the home's config.toml" "$dir"
    return 0
  fi
  # The FULL promise of the acceptance predicate, not half of it: model, effort,
  # AND the security-relevant fields the continuation must have kept —
  # approval_policy never, sandbox read-only and the isolated cwd. Proving that
  # the model was inherited while saying nothing about the sandbox would be
  # exactly the reassurance this probe exists to avoid giving.
  if json_has_value "$tc" "$MCP_MODEL" && json_has_value "$tc" "$MCP_EFFORT" \
    && json_has_value "$tc" "never" && json_has_value "$tc" "read-only" \
    && json_has_value "$tc" "$PROBE_CWD"; then
    C_PASSED=1
    verdict c frozen-inheritance PASS "the continuation's turn_context still echoes call 1 ($MCP_MODEL / $MCP_EFFORT / never / read-only / $PROBE_CWD) with the hostile config.toml in place — the inheritance is frozen" "$dir"
    return 0
  fi
  verdict c frozen-inheritance INDETERMINABLE "the last turn_context echoes neither the pinned nor the hostile values — see $dir/turn-context.last.json" "$dir"
  return 0
}

# probe_a — rollout-resume. Kill the server, then resurrect the SAME thread with
# `codex exec resume` (the exact form of codex-resume.sh 120-127) and ask for the
# codeword seeded in (b). The prompt never contains it: a new, polite thread
# cannot pass.
probe_a() {
  local dir="$RUN_DIR/probe-a" prompt reply events rollout rc=0 got wd pid
  mkdir -p "$dir"
  if [ "$PREFLIGHT_OK" -ne 1 ]; then
    verdict a rollout-resume INDETERMINABLE "preflight broken: $PREFLIGHT_REASON" "$dir"
    return 0
  fi
  if [ "$SPEND" -ne 1 ]; then
    verdict a rollout-resume NOT_RUN "requires --spend (1 REAL codex turn)" "$dir"
    return 0
  fi
  if [ "$B_PASSED" -ne 1 ] || [ -z "$THREAD_ID" ]; then
    verdict a rollout-resume NOT_RUN "dependencia b no superada" "$dir"
    return 0
  fi
  if [ "$C_PASSED" -ne 1 ]; then
    verdict a rollout-resume NOT_RUN "dependencia c no superada" "$dir"
    return 0
  fi
  # A clean kill first: the whole point is that the thread outlives the process.
  mcp_server_stop 5
  find "$PROBE_HOME/sessions" -type f -print >"$dir/sessions.txt" 2>/dev/null
  if ! rollout="$(rollout_for "$THREAD_ID")"; then
    verdict a rollout-resume FAIL "the server left no rollout for $THREAD_ID — there is nothing for \`codex exec resume\` to resurrect" "$dir"
    return 0
  fi
  printf '%s\n' "$rollout" >"$dir/rollout-path.txt"
  prompt="$dir/prompt.txt"
  reply="$dir/reply.txt"
  events="$dir/events.ndjson"
  printf 'Earlier in this same thread I gave you a codeword. Reply with exactly that codeword and nothing else.\n' \
    >"$prompt"
  # Belt and braces for the anti-self-fulfilment rule: the resume prompt must
  # NEVER carry the codeword, or the probe would prove nothing.
  if [ -n "$CODEWORD" ] && LC_ALL=C grep -F -q -- "$CODEWORD" "$prompt" 2>/dev/null; then
    verdict a rollout-resume INDETERMINABLE "the resume prompt leaked the codeword — the probe would prove nothing" "$dir"
    return 0
  fi
  rm -f "$reply"
  set -m
  CODEX_HOME="$PROBE_HOME" codex exec \
    --json --skip-git-repo-check --color never \
    --model "$MCP_MODEL" \
    --sandbox "$CODEX_SANDBOX" \
    -c model_reasoning_effort="$MCP_EFFORT" \
    "${CODEX_PINS[@]}" \
    --output-last-message "$reply" \
    resume "$THREAD_ID" - <"$prompt" >"$events" 2>"$events.stderr" &
  pid=$!
  set +m
  EXEC_PID="$pid"
  EXEC_GROUP=0
  if kill -0 -- -"$pid" 2>/dev/null; then EXEC_GROUP=1; fi
  rm -f "$dir/timedout" "$dir/exec-done"
  exec_watchdog "$pid" "$PROBE_TIMEOUT" "$dir/timedout" "$EXEC_GROUP" "$dir/exec-done" &
  wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  # The mark, not a signal: the watchdog notices within one poll and returns.
  : >"$dir/exec-done"
  wait "$wd" 2>/dev/null
  EXEC_PID=0
  if [ -f "$dir/timedout" ]; then
    verdict a rollout-resume INDETERMINABLE "no reply within ${PROBE_TIMEOUT}s — watchdog expired (proves nothing about resumability)" "$dir"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    if LC_ALL=C grep -E -i -q -e 'session not found' -e 'thread not found' \
      "$events.stderr" "$events" 2>/dev/null; then
      verdict a rollout-resume FAIL "\`codex exec resume\` could not find the thread the MCP server created (Session not found)" "$dir"
    else
      verdict a rollout-resume INDETERMINABLE "the resume turn failed (exit $rc) with no classifiable cause — see $dir/events.ndjson.stderr" "$dir"
    fi
    return 0
  fi
  got="$(jq -rs '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' \
    "$events" 2>/dev/null)"
  if [ -z "$got" ]; then
    # No identity evidence, no PASS: the anti-fallback guarantee IS the equality
    # of the ids, so a stream without `thread.started` proves nothing — however
    # convincing the reply looks.
    verdict a rollout-resume INDETERMINABLE "the resume stream carries no thread.started id — the anti-fallback equality cannot be checked (see $dir/events.ndjson)" "$dir"
    return 0
  fi
  if [ "$got" != "$THREAD_ID" ]; then
    verdict a rollout-resume FAIL "resume attached to thread $got instead of $THREAD_ID — the silent fallback guard of codex-resume.sh would have fired" "$dir"
    return 0
  fi
  if [ ! -s "$reply" ] || ! LC_ALL=C grep -F -q -- "$CODEWORD" "$reply" 2>/dev/null; then
    verdict a rollout-resume FAIL "the resumed turn never echoed the codeword seeded in (b) — the CLI answered from a thread with no memory of it" "$dir"
    return 0
  fi
  verdict a rollout-resume PASS "the thread survived the server: \`codex exec resume $THREAD_ID\` recalled the codeword seeded through MCP" "$dir"
  return 0
}

# exec_watchdog <pid> <secs> <marker> <group> — same shape as the doctor's.
exec_watchdog() {
  # Forked like fifo_guard, and like it never signalled: it returns as soon as
  # the watched process is gone (or the done mark appears), so the parent only
  # has to `wait`. See the comment at the guard's wait for why signalling a
  # background job here would print bash's trap_list warning on stderr.
  trap - EXIT INT TERM
  local pid="$1" secs="$2" marker="$3" group="$4" done_mark="$5" i=0
  while [ "$i" -lt "$secs" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    [ -n "$done_mark" ] && [ -f "$done_mark" ] && return 0
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

# probe_d — elicitation under `never`. Closed in source, in BOTH directions, and
# a live demo would hang a PAID turn that never completes: it is documented, not
# executed. STATIC is a first class verdict — neither PASS (nothing was
# observed) nor INDETERMINABLE (there is no uncertainty) — and it is TIED to the
# audited version.
probe_d() {
  local dir="$RUN_DIR/probe-d"
  mkdir -p "$dir"
  cp "$RUN_DIR/codex-version.txt" "$dir/codex-version.txt" 2>/dev/null
  if [ "$CODEX_VERSION" != "$MCP_STATIC_AUDITED_VERSION" ]; then
    verdict d elicitation-never INDETERMINABLE "veredicto estático auditado para $MCP_STATIC_AUDITED_VERSION, esta CLI es ${CODEX_VERSION_RAW:-unreadable} — no green verdict for code this build may not contain" "$dir"
    return 0
  fi
  {
    printf 'STATIC verdict — codex-cli %s (audited)\n\n' "$MCP_STATIC_AUDITED_VERSION"
    printf 'half 1 — approvals under approval_policy=never are suppressed TOTALLY for exec and patch:\n'
    printf '  exec_policy.rs:174-196 · sandboxing.rs:206-242 · safety.rs:57-61 · network_approval.rs:190-192\n\n'
    printf 'half 2 — one reachable AND unresolvable hang remains, via MCP-tool approval:\n'
    printf '  codex-mcp/src/mcp/mod.rs:79-98 (mcp_permission_prompt_is_auto_approved is false under\n'
    printf '  Never with a Managed profile; forceable with default_tools_approval_mode = "prompt")\n'
    printf '  emits EventMsg::ElicitationRequest; core waits on a oneshot with NO timeout\n'
    printf '  (session/mcp.rs:259-282) and the mcp-server tool runner DISCARDS the event\n'
    printf '  (codex_tool_runner.rs:276-279, "TODO: forward elicitation requests to the client?").\n'
    printf '  Not even an auto-deny is possible from the MCP client side.\n\n'
    printf 'why this probe is NOT executed: a live demo would burn a PAID turn that never completes.\n'
  } >"$dir/static-verdict.txt"
  verdict d elicitation-never STATIC "approvals exec/patch totally suppressed under \`never\` (exec_policy.rs:174-196, sandboxing.rs:206-242, safety.rs:57-61, network_approval.rs:190-192); but an MCP-tool approval hang is reachable AND unresolvable from the client (codex-mcp/src/mcp/mod.rs:79-98 → ElicitationRequest, oneshot without timeout at session/mcp.rs:259-282, discarded by codex_tool_runner.rs:276-279) — a live demo would hang a PAID turn forever, so it is documented instead of run" "$dir"
  return 0
}

# Execution order is the order of the decision chain, with the free static
# verdict last. `d` is INDEPENDENT: a failure upstream never silences it.
[ "$SEL_B" -eq 1 ] && probe_b
[ "$SEL_C" -eq 1 ] && probe_c
[ "$SEL_A" -eq 1 ] && probe_a
[ "$SEL_D" -eq 1 ] && probe_d

printf '\n'
printf 'MCP-PROBE RESULT: %s pass · %s fail · %s indeterminable · %s static · %s not run — evidence: %s\n' \
  "$V_PASS" "$V_FAIL" "$V_INDET" "$V_STATIC" "$V_NOTRUN" "$RUN_DIR"

# NOT_RUN is neutral for the exit code: whoever failed the prerequisite decides
# it, never the skip. INDETERMINABLE is never green.
#
# The script deliberately does NOT end on an unconditional `exit`: the cleanup
# lives in an EXIT trap, and falling off the end keeps that trap reachable for
# static analysis as well as for bash.
if [ "$V_FAIL" -gt 0 ] || [ "$V_INDET" -gt 0 ] || [ "$PREFLIGHT_OK" -ne 1 ]; then
  exit 1
fi
