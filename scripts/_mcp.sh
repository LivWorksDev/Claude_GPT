#!/usr/bin/env bash
# tandem — the shared `codex mcp-server` transport. Source this file, do not run
# it.
#
# CONTRACT — like _pins.sh, sourcing this file installs NOTHING: it defines
# functions plus one constant and does nothing else. No `set`, no traps, no
# output. The mcp branch of a wrapper arms the lifecycle EXPLICITLY, after
# hb_begin, because traps do not stack and hb_begin REPLACES the EXIT trap by
# contract (see mcp_lifecycle_arm).
#
# What this transport buys, and what it deliberately does not (docs/plans/
# mcp-transport-ask.plan.md): ONE SERVER PER TURN. `codex-reply` only exists
# inside a single invocation — the thread dies with the process — so a
# continuation between two invocations goes through the hybrid `codex exec
# resume` that M19 proved end to end. The value here is the pins travelling as
# call parameters, typed thread errors instead of a silent fallback, the
# MANDATORY per-turn watchdog (finding d of M19: an MCP-tool approval under
# `never` hangs with no timeout and the client cannot resolve it) and the shared
# client the later hops build on.
#
# Artefact parity is the design: the mcp branch produces the SAME events NDJSON
# that `codex exec --json` produces, so every extractor downstream (turn_usage,
# the thread.started selector, stream_milestones, the status line) is shared
# code with a single path to maintain.
#
# Portable: bash 3.2+ (stock macOS), BSD userland. Dependencies: codex and jq —
# exactly the two the wrappers already require.

# The per-turn watchdog default, in SECONDS. It MUST stay below the 600 s Bash
# tool timeout the skills use for a foreground turn (skills/ask/SKILL.md), or
# the orchestrator would kill the wrapper before this watchdog could classify
# the hang, reap the server group and run the turn's accounting — the turn would
# then vanish with its quota already spent and no ledger entry.
# tests/mcp-transport-parity.test.sh ties the two numbers together statically.
TANDEM_MCP_TIMEOUT_DEFAULT=540

# …and the default for `review`, which is a DIFFERENT problem. A review at
# xhigh runs in the BACKGROUND precisely because it regularly exceeds ten
# minutes (skills/review/SKILL.md), where no Bash-tool ceiling applies, so the
# 540 s above would kill the role's main use case. The value lives here rather
# than in the skill on purpose: delegating it to "export
# TANDEM_MCP_TIMEOUT_SECONDS on every launch" turns one forgotten line of
# documentation into reviews that die at nine minutes — fail-open in practice.
# A per-role default is fail-closed even when the caller configures nothing.
# 3600 is a CHOSEN bound (the xhigh turns observed in this repo take ~10–25
# min), not a measured one; TANDEM_MCP_TIMEOUT_SECONDS exists for the extreme
# case, and the timeout message names it.
TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW=3600

# …and `implement`, which shares review's PROFILE rather than its sandbox: its
# turns run in the background by contract (skills/implement/SKILL.md) and are
# frequently the longest in the system, so the foreground default above would
# kill the role's main use case exactly as it would kill review's.
#
# A literal of its OWN, deliberately not an alias of the review one: the value
# coincides today (3600), but the static contract stays readable per role and
# either role can diverge tomorrow without renaming anything.
TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT=3600

# --- the shared transport validator ------------------------------------------
# transport_resolve <role> <start|resume> <target> — called by codex-start.sh AND
# codex-resume.sh BEFORE any dependency check and before a single byte of state
# moves, so an invalid value answers 64 without launching codex and without
# advancing the turn counter. A resume that fell back to exec on a bogus value
# would violate the fail-closed rule in the one place it matters most.
#
# The gate has THREE axes, in this order: transport → role → TARGET. The third
# one exists because the ROLE does not distinguish its callers, and `review` has
# three launch families behind one wrapper: the pipeline review of
# `tandem:review` (`cr-<slug>`), its out-of-pipeline range mode
# (`range-review-<label>`) — both migrated and proved under mcp by M20b — and
# the PLAN review of `tandem:plan`, whose target is the plan path and which
# legitimately keeps its foreground exception for small plans. That third family
# is not migrated: routing it through mcp would arm the review watchdog (3600 s,
# far above the 600 s Bash-tool cap the skill's foreground launch runs under),
# so the tool would kill the wrapper before the watchdog could classify the
# hang, reap the group and account the turn — the turn would be lost with its
# quota already spent. A `mcp` merely INHERITED from the environment is exactly
# that vector, so the target axis answers 64 instead of taking the risk (M21).
#
# Sets:
#   TRANSPORT            the code path to take here: exec | mcp
#   TRANSPORT_REQUESTED  what the caller ASKED for: exec | mcp
#   TRANSPORT_EFFECTIVE  what really ran: exec | mcp | exec-resume
#   TRANSPORT_OPT_IN     1 when TANDEM_TRANSPORT was defined at all
#
# `exec-resume` is not decoration: under `TANDEM_TRANSPORT=mcp` a continuation
# runs through `codex exec resume`, and recording a bare "mcp" in the turn's
# meta.json would falsify the audit trail of what actually spoke to the model.
#
# shellcheck disable=SC2034  # the four TRANSPORT* names are this function's
# documented OUTPUTS: they are read by the wrappers that source this file, which
# a standalone lint of this helper cannot see.
transport_resolve() {
  local role="${1:-}" kind="${2:-start}" target="${3:-}"
  TRANSPORT_OPT_IN=0
  TRANSPORT_REQUESTED="exec"
  # A DEFINED-but-empty value is invalid like any other, never "unset": the same
  # discipline TANDEM_TURN_EFFORT applies in codex-resume.sh.
  case "${TANDEM_TRANSPORT+set}" in
    set)
      TRANSPORT_OPT_IN=1
      TRANSPORT_REQUESTED="$TANDEM_TRANSPORT"
      ;;
  esac
  case "$TRANSPORT_REQUESTED" in
    exec | mcp) : ;;
    *)
      die "TANDEM_TRANSPORT is not a valid transport: '$TRANSPORT_REQUESTED' (expected: exec or mcp)" 64
      ;;
  esac
  # A CLOSED set of roles, never a negation: the roles this transport has been
  # proved for are enumerated, and every other one — including a typo — is
  # refused. The set is now the four roles the wrappers know (M20c closed the
  # matrix with the two workspace-write ones), so an unknown value here is a
  # typo or a caller inventing a role, never a hop that is still pending.
  if [ "$TRANSPORT_REQUESTED" = "mcp" ]; then
    case "$role" in
      ask | review | implement | image) : ;;
      *)
        die "TANDEM_TRANSPORT=mcp supports roles ask, review, implement and image (got: '$role')" 64
        ;;
    esac
  fi
  # …and, for `review` alone, a CLOSED set of TARGETS: the two launch families
  # the transport has been proved for. The prefix is read on the RAW target, not
  # on the sanitized state key: the skills pass `cr-<slug>` and
  # `range-review-<label>` literally, while a plan path arrives with slashes and
  # dots. A hand-written review target starting with `cr-` gets exactly the
  # transport it asks for, under the pipeline's own contracts; what this closes
  # is the plan review silently losing a foreground turn. `ask` is NOT gated
  # here — its targets are free-form topics with no foreground exception to
  # protect, and neither are `implement`/`image`: a plan path and a topic label
  # are single launch families whose mcp contract lives in their own skills, so
  # a target axis for them would be empty symmetry.
  if [ "$TRANSPORT_REQUESTED" = "mcp" ] && [ "$role" = "review" ]; then
    case "$target" in
      cr-* | range-review-*) : ;;
      *)
        die "TANDEM_TRANSPORT=mcp supports review targets cr-<slug> and range-review-<label> only (got: '$target') — plan reviews stay on exec; see docs/BACKLOG.md M21" 64
        ;;
    esac
  fi
  TRANSPORT="$TRANSPORT_REQUESTED"
  TRANSPORT_EFFECTIVE="$TRANSPORT_REQUESTED"
  if [ "$TRANSPORT_REQUESTED" = "mcp" ]; then
    # Validated in BOTH wrappers even though only the start path arms a
    # watchdog: one bad value must produce the same 64 from either entry point
    # instead of failing in only half the flow. The ROLE travels with it: the
    # default is per role.
    #
    # AFTER the target case on purpose: which launches exist under mcp is a
    # FLOW error and answers before a parameter one (how wide the watchdog is).
    # An unsupported target must therefore report itself even when the timeout
    # is also invalid — and the timeout cases can use a valid target with no
    # ambiguity about which 64 they are proving.
    mcp_timeout_validate "$role"
    if [ "$kind" = "resume" ]; then
      TRANSPORT="exec"
      TRANSPORT_EFFECTIVE="exec-resume"
    fi
  fi
  return 0
}

# mcp_timeout_validate <role> — the per-turn watchdog, a positive integer of
# seconds. Fail-closed with 64: a bogus value must never degrade into "no
# watchdog", which is precisely the hang this transport exists to bound.
#
# The DEFAULT is resolved per role; TANDEM_MCP_TIMEOUT_SECONDS overrides it for
# every role, with the same validation. That override uses the `${VAR+set}`
# discipline of TANDEM_TURN_EFFORT/TANDEM_TRANSPORT rather than `:-`: with `:-`
# a DEFINED-but-empty value is treated as unset, so the rejection of the empty
# string below was unreachable and `TANDEM_MCP_TIMEOUT_SECONDS=` would fall
# silently onto the (now much larger) role default instead of answering 64.
#
# The MATRIX is decided by the role's DOMINANT LAUNCH MODE, never by its
# sandbox: `review` and `implement` run in the background and legitimately pass
# ten minutes, so they get the wide default; `ask` and `image` are foreground
# contracts (a topic answer, 1–3 assets) and keep the 540 s that sits BELOW the
# Bash tool's ceiling so the watchdog classifies the hang first. `image` writes
# to the workspace and still belongs here: giving every workspace-write role an
# hour would make a hung one-asset turn wait sixty minutes instead of nine, and
# the legitimate long case (large sets in the background) has the explicit
# TANDEM_MCP_TIMEOUT_SECONDS override.
mcp_timeout_validate() {
  local role="${1:-}"
  case "$role" in
    review) MCP_TIMEOUT="$TANDEM_MCP_TIMEOUT_DEFAULT_REVIEW" ;;
    implement) MCP_TIMEOUT="$TANDEM_MCP_TIMEOUT_DEFAULT_IMPLEMENT" ;;
    *) MCP_TIMEOUT="$TANDEM_MCP_TIMEOUT_DEFAULT" ;;
  esac
  case "${TANDEM_MCP_TIMEOUT_SECONDS+set}" in
    set) MCP_TIMEOUT="$TANDEM_MCP_TIMEOUT_SECONDS" ;;
  esac
  case "$MCP_TIMEOUT" in
    '' | *[!0-9]*)
      die "TANDEM_MCP_TIMEOUT_SECONDS must be a positive integer of seconds (got: '$MCP_TIMEOUT')" 64
      ;;
  esac
  [ "$((10#$MCP_TIMEOUT))" -gt 0 ] \
    || die "TANDEM_MCP_TIMEOUT_SECONDS must be a positive integer of seconds (got: '$MCP_TIMEOUT')" 64
  MCP_TIMEOUT="$((10#$MCP_TIMEOUT))"
  # The absolute deadline of the whole turn, armed when the transport opens.
  # Everything downstream waits against what REMAINS of it, so fifo + handshake
  # + turn can never add up to more than the budget the caller allows.
  MCP_DEADLINE=0
  return 0
}

# --- the ephemeral CODEX_HOME ------------------------------------------------
# mcp_toml_value <raw> — the TOML rendering of a PINNED value. Every value that
# reaches it comes from codex_pins(), i.e. a closed set of literals; the model
# and the effort are NOT written here on purpose (see mcp_write_config).
mcp_toml_value() {
  case "$1" in
    true | false) printf '%s' "$1" ;;
    \[*\]) printf '%s' "$1" ;;
    '' | *[!0-9]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# mcp_write_config — the ephemeral home's config.toml is the codex_pins() mirror
# and NOTHING ELSE.
#
# SECURITY, non negotiable: the model and the effort travel EXCLUSIVELY as
# parameters of the tool call (`model` is first class, the effort rides the
# `config` map), where jq renders them as JSON. They come from the
# TANDEM_*_MODEL / TANDEM_*_EFFORT overrides, which may legitimately carry
# quotes and backslashes — the hostile values the existing suite already fires
# at the exec path — and a printf-based TOML writer would interpolate them
# unescaped into a file the server parses. The pin values, by contrast, are a
# closed set of literals decided by resolve_role/codex_pins.
mcp_write_config() {
  local tmp prev="" a key val
  tmp="$MCP_HOME/.config.toml.tmp.$$"
  {
    printf '# generated by tandem scripts/_mcp.sh — ephemeral, never the user'\''s home\n'
    for a in "${CODEX_PINS[@]}"; do
      if [ "$prev" = "-c" ]; then
        key="${a%%=*}"
        val="${a#*=}"
        printf '%s = %s\n' "$key" "$(mcp_toml_value "$val")"
      fi
      prev="$a"
    done
  } >"$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$MCP_HOME/config.toml" 2>/dev/null || return 1
  chmod 600 "$MCP_HOME/config.toml" 2>/dev/null || true
  return 0
}

# mcp_pins_config_json — the same policy as the JSON object the tool call's
# `config` map takes (the server accepts the dotted config.toml keys there),
# plus the effort, which has no first class parameter. One source of truth
# again: CODEX_PINS.
#
# The two ARGV-only pins have no key to carry here, and they do not need one:
# `--ignore-user-config` is realised by the ephemeral CODEX_HOME itself (the
# user's config.toml is not in it, so there is nothing to inherit), and
# `--ignore-rules` likewise — the ephemeral home ships no execpolicy `.rules`
# file. `--cd` becomes the call's `cwd` parameter. Everything else — sandbox
# mode, network access, writable roots, approval policy and reviewer — travels
# here verbatim, so the two transports state the same policy.
mcp_pins_config_json() {
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
  printf '%s' "$json" | jq -c --arg e "${CODEX_EFFORT:-}" '.model_reasoning_effort = $e' 2>/dev/null
}

# mcp_deadline_arm — start the single clock of this turn. Called once, when the
# transport opens; every wait below asks mcp_deadline_left for its budget.
mcp_deadline_arm() {
  local now
  now="$(date +%s 2>/dev/null)" || now=""
  case "$now" in '' | *[!0-9]*) MCP_DEADLINE=0; return 0 ;; esac
  MCP_DEADLINE=$((10#$now + MCP_TIMEOUT))
  return 0
}

# mcp_deadline_left — the seconds that REMAIN of the turn's budget, never more
# than the budget itself and never less than 1 (a zero would turn a wait into a
# non-wait and mask a timeout as an empty answer). Without a usable clock it
# degrades to the full timeout: a watchdog that cannot measure must not become a
# watchdog that never fires.
mcp_deadline_left() {
  local now left
  [ "${MCP_DEADLINE:-0}" -gt 0 ] 2>/dev/null || { printf '%s' "$MCP_TIMEOUT"; return 0; }
  now="$(date +%s 2>/dev/null)" || now=""
  case "$now" in '' | *[!0-9]*) printf '%s' "$MCP_TIMEOUT"; return 0 ;; esac
  left=$((MCP_DEADLINE - 10#$now))
  [ "$left" -lt 1 ] && left=1
  [ "$left" -gt "$MCP_TIMEOUT" ] && left="$MCP_TIMEOUT"
  printf '%s' "$left"
  return 0
}

# mcp_home_build — the ephemeral CODEX_HOME owned by tandem, under TMPDIR,
# removed by the lifecycle owner. The copied token NEVER lands under .tandem/,
# which is the project's own (and git-ignored, and inspected) state tree.
mcp_home_build() {
  local tmp base base_phys state_phys
  # The base is CHOSEN, never merely inherited: a TMPDIR pointing inside the
  # project's state tree would put the copied credential under .tandem/ — the
  # one place this transport promises it never goes — and a SIGKILL would leave
  # it there. Both paths are canonicalized and the descendant test is done on
  # the physical forms; a TMPDIR under the state root falls back to /tmp.
  base="${TMPDIR:-/tmp}"
  base_phys="$(CDPATH='' cd -- "$base" 2>/dev/null && pwd -P)" || base_phys=""
  state_phys="$(CDPATH='' cd -- "${CLAUDE_PROJECT_DIR:-$PWD}/.tandem" 2>/dev/null && pwd -P)" || state_phys=""
  if [ -n "$base_phys" ] && [ -n "$state_phys" ]; then
    case "$base_phys/" in
      "$state_phys"/*)
        printf 'tandem: TMPDIR (%s) is inside the tandem state tree; the mcp transport uses /tmp instead so the copied credential never lands under .tandem/\n' \
          "$base_phys" >&2
        base="/tmp"
        ;;
    esac
  fi
  tmp="$(mktemp -d "$base/tandem-mcp-turn.XXXXXX" 2>/dev/null)" || tmp=""
  { [ -n "$tmp" ] && [ -d "$tmp" ]; } \
    || die "cannot create a temporary directory under $base" 3
  # Registered with the lifecycle owner IMMEDIATELY: from this line on the
  # directory is removed on every exit, whether or not the canonicalization
  # below succeeds.
  MCP_TMP="$tmp"
  # CANONICAL from here on. macOS exports TMPDIR with a trailing slash and /var
  # is a symlink to /private/var; the server normalizes the path before echoing
  # it back in its own frames, and a comparison against the unnormalized string
  # reports a mismatch that never happened (found by the first REAL run of
  # scripts/mcp-probe.sh). Both spellings name the same directory, so the
  # cleanup works either way.
  tmp="$(CDPATH='' cd -- "$MCP_TMP" 2>/dev/null && pwd -P)" || tmp=""
  { [ -n "$tmp" ] && [ -d "$tmp" ]; } \
    || die "cannot resolve the temporary directory to a physical path" 3
  MCP_TMP="$tmp"
  MCP_HOME="$MCP_TMP/home"
  mkdir -p "$MCP_HOME" || die "cannot populate $MCP_TMP" 3
  # Fail CLOSED on the mode: announcing 700 and continuing with something else
  # would be a false guarantee about a directory that holds a credential.
  chmod 700 "$MCP_HOME" 2>/dev/null \
    || die "cannot set mode 700 on the ephemeral CODEX_HOME $MCP_HOME" 3
  # The single clock of the turn starts HERE, before the server is forked: from
  # this point fifo, handshake and turn all wait against what remains of it.
  mcp_deadline_arm
  MCP_RPC_OUT="$MCP_TMP/rpc.out.ndjson"
  MCP_FIFO="$MCP_TMP/rpc.fifo"
  MCP_SERVER_PID=0
  MCP_SERVER_GROUP=0
  MCP_FD_OPEN=0
  mcp_write_config \
    || die "cannot write the ephemeral config.toml under $MCP_HOME" 1
  mcp_auth_copy
  return 0
}

# mcp_auth_copy — the login is a FILE at <CODEX_HOME>/auth.json. A machine whose
# token lives only in the keyring has nothing to copy and its keyring entry is
# keyed by the home, so the mcp transport is unusable there: say so, with the
# command that fixes it, BEFORE anything is launched.
mcp_auth_copy() {
  local src="${CODEX_HOME:-${HOME:-}/.codex}"
  [ -f "$src/auth.json" ] \
    || die "no auth.json in $src — the mcp transport copies a file-based token into its own ephemeral CODEX_HOME; run \`CODEX_HOME=$src codex login\` and retry" 3
  cp "$src/auth.json" "$MCP_HOME/auth.json" 2>/dev/null \
    || die "could not copy $src/auth.json into the ephemeral CODEX_HOME" 3
  chmod 600 "$MCP_HOME/auth.json" 2>/dev/null \
    || die "cannot set mode 600 on the copied credential" 3
  return 0
}

# --- the single lifecycle owner ----------------------------------------------
# Traps do NOT stack, and hb_begin REPLACES the EXIT trap — that is its
# contract. Installing a second one in this file would leave either the server,
# the ephemeral home and the copied credential orphaned, or the heartbeat stuck
# on 'running' forever, depending on which one won. So the mcp branch arms ONE
# owner of EXIT/INT/TERM that chains both, in this order: first the mcp cleanup
# (reap the group, delete the credential and the home), then the heartbeat's
# failure handling. INT and TERM merely `exit`, so the single EXIT owner does
# the work exactly once on all five exits (success, wrapper failure, timeout,
# INT, TERM).
mcp_lifecycle_arm() {
  trap 'mcp_lifecycle_exit' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  return 0
}

mcp_lifecycle_exit() {
  local rc=$?
  mcp_cleanup || true
  if [ "${HB_ACTIVE:-0}" = "1" ]; then
    hb_write failed || true
  fi
  exit "$rc"
}

# mcp_cleanup — idempotent by construction (it runs from the EXIT trap, and an
# INT/TERM path reaches it through that same trap). The credential is removed
# EXPLICITLY before the recursive delete: "always deleted, on every path" is a
# statement that must be readable in the code, not an accident of `rm -rf`.
mcp_cleanup() {
  mcp_server_stop 1
  if [ -n "${MCP_HOME:-}" ]; then
    rm -f "$MCP_HOME/auth.json" "$MCP_HOME/config.toml" 2>/dev/null || true
  fi
  if [ -n "${MCP_TMP:-}" ]; then
    rm -rf "$MCP_TMP" 2>/dev/null || true
  fi
  return 0
}

# mcp_kill_group <pid> <group> <grace> — compatibility name for the shared
# TERM→KILL helper moved to _common.sh. The wrappers source _common.sh first.
mcp_kill_group() {
  kill_group_term_kill "$@"
}

# mcp_server_stop <grace> — the mandated stop sequence, in this exact order:
# EOF, WAIT for the server to take it, then reap the group. Called by the
# watchdog path, by the cleanup, and — crucially — BEFORE the rollout is
# touched: the RolloutRecorder appends to that file live, and signalling a
# server in the middle of a flush is precisely how a truncated rollout would be
# published into the user's store.
mcp_server_stop() {
  local grace="${1:-1}" i=0
  if [ "${MCP_FD_OPEN:-0}" = "1" ]; then
    exec 3>&-
    MCP_FD_OPEN=0
  fi
  [ "${MCP_SERVER_PID:-0}" -gt 0 ] 2>/dev/null || return 0
  while [ "$i" -lt "$grace" ]; do
    kill -0 "$MCP_SERVER_PID" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  # Whatever EOF did not close, the group kill does — a hung turn has no
  # graceful exit to wait for.
  mcp_kill_group "$MCP_SERVER_PID" "${MCP_SERVER_GROUP:-0}" "$grace"
  wait "$MCP_SERVER_PID" 2>/dev/null || true
  MCP_SERVER_PID=0
  return 0
}

# --- the ndjson JSON-RPC client, in pure bash --------------------------------
# mcp_fifo_guard <secs> <mark> <timeout-mark> <fifo> — on BSD, open(2) of a FIFO
# for WRITING blocks until a reader shows up, and a shell blocked inside it
# cannot be interrupted. The guard unblocks it by opening the READ end and
# leaves a marker so the caller knows the rendezvous never happened (a server
# that died at startup).
mcp_fifo_guard() {
  # This runs FORKED. A background subshell INHERITS the script's trap
  # dispositions, so without this reset the guard would run the lifecycle owner
  # — reaping the very server it exists to protect — and bash 3.2 would print
  # `run_pending_traps: bad value in trap_list[…]` on stderr. Resetting is the
  # whole fix: the parent owns the cleanup, a guard never does. The guard is
  # NEVER signalled either; it exits by itself on the mark file (the M19 lesson).
  trap - EXIT INT TERM
  local secs="${1:-1}" mark="$2" tmark="$3" fifo="$4" i=0
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

mcp_rpc_start() {
  local mark="$MCP_TMP/fifo.opened" tmark="$MCP_TMP/fifo.timeout" guard
  : >"$MCP_RPC_OUT" 2>/dev/null || return 1
  rm -f "$mark" "$tmark" 2>/dev/null || true
  mkfifo "$MCP_FIFO" 2>/dev/null || return 1
  # Job control only around the fork, so the server LEADS its own process group
  # and the cleanup can reap every descendant it spawns.
  set -m
  CODEX_HOME="$MCP_HOME" codex mcp-server \
    <"$MCP_FIFO" >"$MCP_RPC_OUT" 2>>"$MCP_STDERR" &
  MCP_SERVER_PID=$!
  set +m
  MCP_SERVER_GROUP=0
  if kill -0 -- -"$MCP_SERVER_PID" 2>/dev/null; then MCP_SERVER_GROUP=1; fi
  mcp_fifo_guard "$(mcp_deadline_left)" "$mark" "$tmark" "$MCP_FIFO" &
  guard=$!
  # The write end is opened AFTER the fork on purpose: the server's own
  # redirection opens the read end, and the two opens are the rendezvous.
  exec 3>"$MCP_FIFO"
  : >"$mark"
  # The guard returns BY ITSELF within one poll once the mark exists — it is
  # never signalled. Waiting costs at most one second and keeps bash's trap_list
  # warning off a stderr that belongs to real diagnostics.
  wait "$guard" 2>/dev/null || true
  if [ -f "$tmark" ]; then return 1; fi
  MCP_FD_OPEN=1
  return 0
}

mcp_rpc_send() {
  [ "${MCP_FD_OPEN:-0}" = "1" ] || return 1
  printf '%s\n' "$1" >&3 2>/dev/null || return 1
  return 0
}

# mcp_rpc_scan <id> <dest> — writes the FIRST complete, parseable frame carrying
# that id into <dest>. Only lines jq accepts are considered, so a half written
# line at the end of the stream is skipped and re-polled later.
mcp_rpc_scan() {
  jq -Rc --argjson want "$1" \
    'fromjson? | objects | select(.id == $want)' "$MCP_RPC_OUT" 2>/dev/null \
    | head -n 1 >"$2" 2>/dev/null
  [ -s "$2" ]
}

# mcp_rpc_wait <id> <seconds> <dest> — poll until the frame lands. THIS is the
# per-turn watchdog: the deadline lives in the client's own loop, so no extra
# process has to be forked, signalled or reaped for it.
#   rc 0 = the frame landed · 1 = the deadline expired · 2 = the server died
#   without answering.
# The loop deliberately does NOT run inside a command substitution: a subshell
# does not inherit this script's traps, and a parent blocked on it would defer
# an incoming TERM until the whole deadline expired.
mcp_rpc_wait() {
  local id="$1" secs="$2" dest="$3" i=0
  : >"$dest" 2>/dev/null || true
  while :; do
    if mcp_rpc_scan "$id" "$dest"; then return 0; fi
    if [ "${MCP_SERVER_PID:-0}" -gt 0 ] && ! kill -0 "$MCP_SERVER_PID" 2>/dev/null; then
      # One last scan: the frame may have landed as the server exited.
      if mcp_rpc_scan "$id" "$dest"; then return 0; fi
      return 2
    fi
    [ "$i" -lt "$secs" ] || return 1
    sleep 1
    i=$((i + 1))
  done
}

# --- the event ADAPTER --------------------------------------------------------
# NOT an unwrapping: the internal stream carries `params={_meta,id,msg}` with
# msg types of its OWN (tests/fixtures/mcp-0.144.4/notifications.ndjson — the 14
# structural frames of a REAL turn). This translates them into the EXACT
# serialization `codex exec --json` emits on 0.144.4:
#
#   session_configured        → {"type":"thread.started","thread_id":…}
#   token_count               → the last `info.last_token_usage` is RETAINED
#   task_complete             → ONE {"type":"turn.completed","usage":{…}} built
#                               with EXACTLY the four public fields of exec's
#                               Usage (input/cached_input/output/reasoning_output).
#                               The MCP object also drags `total_tokens`, and
#                               since turn_usage retains every numeric field,
#                               letting it through would poison the ledgers with
#                               a field no exec turn ever carries.
#   item_started/item_completed → item.started/item.completed with the
#                               discriminator `item.type` — the one the real exec
#                               streams archived under .tandem/ carry, and the one
#                               ThreadItemDetails declares. `item_item_type` is
#                               the STALE discriminator this hop retires (kept
#                               only as a compatibility read in the consumers).
#                               The MCP item types are PascalCase
#                               (AgentMessage, CommandExecution…), so the
#                               translation is the generic PascalCase→snake_case
#                               rule; a UserMessage produces NO exec item,
#                               because exec emits none either.
#   error                     → {"type":"error","message":…}
#
# Everything else (`mcp_startup_*`, `task_started`, `agent_message*`,
# `user_message`, `raw_response_item`, the JSON-RPC responses themselves) goes to
# the sideline `<events>.mcp.raw.ndjson` and NEVER into the events file: the
# extractors downstream are untouched, and their conformance is PROVEN by
# replaying the real fixture through this function
# (tests/mcp-transport-parity.test.sh).
#
# mcp_events_adapt <rpc-out> <events-out> <raw-out>
mcp_events_adapt() {
  local rpc_out="${1:-}" events_out="${2:-}" raw_out="${3:-}"
  [ -n "$rpc_out" ] || return 0
  [ -f "$rpc_out" ] || return 0
  [ -n "$events_out" ] || return 0
  jq -Rn -c '
    def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
    def text_of:
      if ((.content // null) | type) == "array"
      then ([ .content[]? | if type == "object" then (.text // "") else "" end ] | join(""))
      else ((.text // "") | tostring) end;
    # PER-TYPE converters, not a generic field-preserving rewrite: the
    # ThreadItemDetails union of exec is closed and each variant has its OWN
    # public shape. Passing internal MCP fields through would emit items that no
    # exec consumer can read (and that no exec stream contains).
    # NOTE: no apostrophes anywhere in this program — it is single-quoted shell.
    def exec_item:
      . as $i
      | ((($i.type // "") | tostring) | snake) as $t
      | ({id: (($i.id // "") | tostring)}) as $id
      | $id +
        (if $t == "command_execution" then
          # exit_code is present even while the command runs (null then), and
          # status too: the real exec item carries both from the first frame.
          # `command` in the core TurnItem is ARGV (an array); exec renders it
          # as one command line. Applying tostring to an array would emit the
          # JSON text ["ls","-l"] as if it were the command.
          {type: $t,
           command: (if ($i.command | type) == "array"
                     then ([ $i.command[]? | tostring ] | join(" "))
                     else (($i.command // "") | tostring) end),
           aggregated_output: (($i.aggregated_output // $i.output // "") | tostring),
           exit_code: (if ($i.exit_code | type) == "number" then $i.exit_code else null end),
           status: (($i.status // "in_progress") | tostring)}
        elif $t == "file_change" then
          # `changes` is a MAP path→kind in the core item and an ARRAY of
          # {path, kind} in exec: the map is converted, never discarded.
          {type: $t,
           changes: (($i.changes // []) 
                     | if type == "array" then .
                       elif type == "object" then
                         (to_entries | map({path: .key,
                                            kind: (if (.value | type) == "string"
                                                   then .value
                                                   else ((.value.kind // "update") | tostring) end)}))
                       else [] end),
           status: (($i.status // "in_progress") | tostring)}
        elif $t == "web_search" then
          # `action` is an OBJECT in the real exec item ({"type":"other"}), not a
          # string: it is carried through as it comes, with a typed default.
          {type: $t,
           query: (($i.query // "") | tostring),
           action: (if ($i.action | type) == "object" then $i.action
                    else {type: "other"} end)}
        elif $t == "agent_message" then
          {type: $t, text: ($i | text_of)}
        elif $t == "reasoning" then
          # Reasoning carries its text in `summary` in the MCP shape; `content`
          # is the fallback for the shapes that use it.
          {type: $t,
           text: (if (($i.summary_text // null) | type) == "string" then $i.summary_text
                  elif (($i.summary_text // null) | type) == "array"
                  then ([ $i.summary_text[]?
                          | if type == "object" then (.text // "") else tostring end ]
                        | join(""))
                  elif (($i.summary // null) | type) == "array"
                  then ([ $i.summary[]?
                          | if type == "object" then (.text // "") else tostring end ]
                        | join(""))
                  elif (($i.summary // null) | type) == "string" then $i.summary
                  else ($i | text_of) end)}
        elif $t == "todo_list" then
          {type: $t, items: (($i.items // []) | if type == "array" then . else [] end)}
        elif $t == "error" then
          {type: $t, message: (($i.message // "") | tostring)}
        elif $t == "collab_agent_tool_call" or $t == "collab_tool_call" then
          # The core variant is CollabAgentToolCall; exec publishes it as
          # `collab_tool_call` WITHOUT a server and WITH the collaboration
          # identity. Keeping the core discriminator (or inventing an empty
          # server) would leave consumers unable to recognise it and would drop
          # exactly the fields that say which agents took part.
          {type: "collab_tool_call",
           # `tool` says WHICH collaborative operation happened — dropping it
           # loses the event. exec renames `resume_agent` to `wait`.
           tool: (((($i.tool // $i.tool_name // "") | tostring)) as $tn
                  | if $tn == "resume_agent" then "wait" else $tn end),
           sender_thread_id: (($i.sender_thread_id // "") | tostring),
           receiver_thread_ids: (($i.receiver_thread_ids // [])
                                 | if type == "array" then . else [] end),
           # `prompt` is OPTIONAL: absent must stay null, not become "".
           prompt: (if ($i.prompt | type) == "string" then $i.prompt else null end),
           # `agents_states` is a MAP in both protocols: forcing it through an
           # array test emptied it silently.
           agents_states: (if ($i.agents_states | type) == "object" then $i.agents_states
                           elif ($i.agents_states | type) == "array" then $i.agents_states
                           else {} end),
           status: (($i.status // "in_progress") | tostring)}
        elif $t == "mcp_tool_call" then
          # MCP tool calls keep their identifying fields. A literal port of the
          # official processor state machine (id correlation across start and
          # completion) is NOT attempted — see the plan note; what is emitted is
          # true, never invented.
          {type: $t,
           server: (($i.server // "") | tostring),
           tool: (($i.tool // $i.tool_name // "") | tostring),
           status: (($i.status // "in_progress") | tostring)}
        else
          # An unknown variant keeps its snake type and nothing else: emitting
          # invented fields would be worse than emitting a bare item.
          {type: $t}
        end);
    [ inputs | fromjson? | objects
      | select((.method? // "") == "codex/event") | .params.msg | objects ]
    | reduce .[] as $m ({u: null, out: []};
        (($m.type // "") | tostring) as $t
        | if $t == "session_configured" then
            .out += [{type: "thread.started", thread_id: (($m.thread_id // "") | tostring)}]
          elif $t == "token_count" then
            .u = (($m.info.last_token_usage | objects) // .u)
          elif $t == "task_complete" then
            .out += [ if (.u | type) == "object"
                      then {type: "turn.completed",
                            usage: {input_tokens: ((.u.input_tokens | numbers) // 0),
                                    cached_input_tokens: ((.u.cached_input_tokens | numbers) // 0),
                                    output_tokens: ((.u.output_tokens | numbers) // 0),
                                    reasoning_output_tokens: ((.u.reasoning_output_tokens | numbers) // 0)}}
                      else {type: "turn.completed"} end ]
          elif $t == "task_started" then
            .out += [{type: "turn.started"}]
          elif $t == "item_started" or $t == "item_completed" then
            ((($m.item | objects) // {}) | exec_item) as $it
            # exec emits NO `item.started` for agent_message/reasoning (its
            # processor suppresses them: the started event of a streamed message
            # carries nothing a consumer can use) and no item at all for a user
            # message. Emitting them would make the stream differ from exec.
            | if ($it.type == "") or ($it.type == "user_message") then .
              elif ($t == "item_started"
                    and (($it.type == "agent_message") or ($it.type == "reasoning"))) then .
              else .out += [{type: (if $t == "item_started"
                                    then "item.started" else "item.completed" end),
                             item: $it}]
              end
          elif $t == "error" then
            .out += [{type: "error", message: ((($m.message // $m.error.message) // "") | tostring)}]
          else . end)
    | .out[]' <"$rpc_out" >"$events_out.tmp" 2>/dev/null || {
    # A failed adaptation must NEVER publish a half events file: the usage, the
    # thread id and the narration all read it, and a truncated one would lie
    # quietly. The partial output is discarded and the caller decides.
    rm -f "$events_out.tmp" 2>/dev/null || true
    MCP_STATUS="the event adapter failed (jq error or write failure) — no events file was published"
    return 1
  }
  mv -f "$events_out.tmp" "$events_out" 2>/dev/null || {
    rm -f "$events_out.tmp" 2>/dev/null || true
    MCP_STATUS="the adapted events file could not be published"
    return 1
  }
  [ -n "$raw_out" ] || return 0
  # The complement, byte for byte: every frame that produced NO events line is
  # kept verbatim, including the lines jq cannot parse at all.
  jq -Rr '
    def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
    . as $line
    | (try ($line | fromjson) catch null) as $v
    | (if ($v | type) != "object" then false
       elif (($v.method? // "") != "codex/event") then false
       else ((($v.params.msg.type? // "") | tostring)) as $t
         | if $t == "session_configured" or $t == "task_complete"
              or $t == "token_count" or $t == "task_started" or $t == "error" then true
           elif ($t == "item_started" or $t == "item_completed") then
             # A frame counts as TRANSLATED only if it really produced an events
             # line. A user_message never does, and neither does the `started` of
             # an agent_message/reasoning (exec suppresses those) — treating them
             # as translated would make them vanish from BOTH files, which is
             # exactly the hole the conservation assertion exists to catch.
             (((($v.params.msg.item.type? // "") | tostring) | snake) as $it
              | if $it == "user_message" then false
                elif ($t == "item_started"
                      and (($it == "agent_message") or ($it == "reasoning"))) then false
                else true end)
           else false end
       end) as $translated
    | if $translated then empty else $line end' <"$rpc_out" >"$raw_out.tmp" 2>/dev/null || {
    # The sideline is an audit artefact, not a contract: its failure is reported
    # but does not invalidate a turn whose events were adapted correctly.
    rm -f "$raw_out.tmp" 2>/dev/null || true
    printf 'tandem: the mcp sideline (%s) could not be written — the events file is unaffected\n' \
      "$raw_out" >&2
    return 0
  }
  mv -f "$raw_out.tmp" "$raw_out" 2>/dev/null || {
    # The sideline is an audit artefact: its failure is REPORTED (never silent)
    # but does not invalidate a turn whose events adapted correctly.
    rm -f "$raw_out.tmp" 2>/dev/null || true
    printf 'tandem: the mcp sideline (%s) could not be published — the events file is unaffected\n' \
      "$raw_out" >&2
  }
  return 0
}

# --- the rollout: relocated to the user's real store -------------------------
# The ephemeral server writes the thread's rollout inside its ephemeral home,
# which the cleanup deletes. Relocating it to the REAL store is what makes the
# thread a normal citizen (resume, codex-show, reset) — it is the exact inverse
# of probe (a) of M19, which proved a rollout is all `codex exec resume` needs.
#
# The sequence is mandatory and ordered (P1-3 of the review):
#   1. the server is ALREADY stopped by the caller — the recorder appends live;
#   2. COPY into a hidden temporary INSIDE the destination directory (a `mv`
#      from TMPDIR crosses filesystems and is NOT an atomic rename);
#   3. validate (non empty, last line parses as JSON);
#   4. rename WITHIN that directory, behind a no-overwrite guard;
#   5. delete the source only after success.
#
# mcp_rollout_find <thread-id> — the rollout the ephemeral server wrote.
mcp_rollout_find() {
  local tid="${1:-}" p
  [ -n "$tid" ] || return 1
  [ -n "${MCP_HOME:-}" ] || return 1
  [ -d "$MCP_HOME/sessions" ] || return 1
  p="$(find "$MCP_HOME/sessions" -type f -name "*$tid*.jsonl" 2>/dev/null | LC_ALL=C sort | tail -n 1)"
  [ -n "$p" ] || return 1
  printf '%s' "$p"
  return 0
}

# mcp_rollout_recover <src> — the credential is NEVER retained, so a relocation
# that failed may not leave the thread inside the ephemeral home either. The
# rollout (and only the rollout) is copied into a fresh 700 directory with the
# file at 600, and the path is announced on stderr.
#
# Under TMPDIR rather than inside the destination store on purpose: the most
# likely reason a relocation failed is that the store itself refused the write,
# and recovering into the same place would bet on the thing that just failed.
mcp_rollout_recover() {
  local src="${1:-}" dir base
  [ -n "$src" ] && [ -f "$src" ] || return 0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/tandem-rollout-recovery.XXXXXX" 2>/dev/null)" || dir=""
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf 'tandem: the rollout could not be relocated, and no recovery directory could be created — it dies with the ephemeral home\n' >&2
    return 0
  fi
  if ! chmod 700 "$dir" 2>/dev/null; then
    rm -rf "$dir" 2>/dev/null || true
    printf 'tandem: the recovery directory could not be made private (700) — the rollout is NOT written anywhere\n' >&2
    return 0
  fi
  base="$(basename -- "$src")"
  if cp "$src" "$dir/$base" 2>/dev/null; then
    if ! chmod 600 "$dir/$base" 2>/dev/null; then
      rm -f "$dir/$base" 2>/dev/null || true
      printf 'tandem: the recovered rollout could not be made private (600) — it is removed instead of left readable\n' >&2
      return 0
    fi
    printf 'tandem: the rollout could not be relocated; it is recovered at %s (directory 700, file 600)\n' \
      "$dir/$base" >&2
  else
    printf 'tandem: the rollout could not be relocated NOR recovered — it dies with the ephemeral home\n' >&2
  fi
  return 0
}

# mcp_rollout_relocate <thread-id> — rc 0 on success (MCP_ROLLOUT_DEST holds the
# final path), rc 1 with MCP_RELOCATE_STATUS set otherwise. A failure is fatal
# for the turn by design: without the rollout in the user's store the thread
# could never be resumed, and persisting a thread id that resolves to nothing is
# exactly the silent-fallback class this project refuses.
#
# shellcheck disable=SC2034  # MCP_ROLLOUT_DEST is an output of this function.
mcp_rollout_relocate() {
  local tid="${1:-}" src dest_root rel dir base tmp final
  MCP_RELOCATE_STATUS=""
  MCP_ROLLOUT_DEST=""
  src="$(mcp_rollout_find "$tid")" || src=""
  if [ -z "$src" ]; then
    MCP_RELOCATE_STATUS="the mcp server left no rollout for $tid under its ephemeral home — the thread could never be resumed"
    return 1
  fi
  dest_root="${CODEX_HOME:-${HOME:-}/.codex}"
  case "$src" in
    "$MCP_HOME"/*) rel="${src#"$MCP_HOME"/}" ;;
    *) rel="sessions/$(basename -- "$src")" ;;
  esac
  final="$dest_root/$rel"
  dir="$(dirname -- "$final")"
  base="$(basename -- "$final")"
  tmp="$dir/.tandem-rollout.$$.tmp"
  if ! mkdir -p "$dir" 2>/dev/null; then
    MCP_RELOCATE_STATUS="cannot create the destination directory $dir"
    mcp_rollout_recover "$src"
    return 1
  fi
  if [ -e "$final" ]; then
    MCP_RELOCATE_STATUS="refusing to overwrite an existing rollout at $final"
    mcp_rollout_recover "$src"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  if ! cp "$src" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    MCP_RELOCATE_STATUS="could not stage the rollout inside $dir"
    mcp_rollout_recover "$src"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || {
    # The staged copy cannot be made private: it is removed rather than left
    # readable — but the rollout must NOT die with it. The source still exists
    # at this point (it is deleted only after a successful rename), so the
    # recovery path gets its chance and the reason is reported.
    rm -f "$tmp" 2>/dev/null || true
    MCP_RELOCATE_STATUS="the staged rollout could not be made private (600) in $dir"
    mcp_rollout_recover "$src"
    return 1
  }
  if [ ! -s "$tmp" ] || ! LC_ALL=C tail -n 1 "$tmp" | jq -e . >/dev/null 2>&1; then
    rm -f "$tmp" 2>/dev/null || true
    MCP_RELOCATE_STATUS="the staged copy of $base is empty or its last line is not JSON — refusing to publish a truncated rollout"
    mcp_rollout_recover "$src"
    return 1
  fi
  # The guard again, immediately before the rename: `mv` would overwrite, and a
  # concurrent turn may have landed here since the first check.
  if [ -e "$final" ]; then
    rm -f "$tmp" 2>/dev/null || true
    MCP_RELOCATE_STATUS="refusing to overwrite an existing rollout at $final"
    mcp_rollout_recover "$src"
    return 1
  fi
  # A rename WITHIN the destination directory: never a cross-filesystem move.
  if ! mv "$tmp" "$final" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    MCP_RELOCATE_STATUS="could not rename the staged rollout into place at $final"
    mcp_rollout_recover "$src"
    return 1
  fi
  rm -f "$src" 2>/dev/null || true
  MCP_ROLLOUT_DEST="$final"
  return 0
}

# --- the turn ----------------------------------------------------------------
# mcp_turn_cwd — the working root of the turn, ABSOLUTE. The real server
# resolves a relative `cwd` against ITS OWN working directory (its inputSchema
# says so), which is not necessarily ours.
mcp_turn_cwd() {
  local d="${TANDEM_CODEX_CWD:-$PWD}"
  case "$d" in
    /*) : ;;
    *) d="$(CDPATH='' cd -- "$d" 2>/dev/null && pwd)" || d="$PWD" ;;
  esac
  printf '%s' "$d"
}

mcp_result_text() {
  [ -f "${1:-}" ] || return 0
  jq -r '[ .error.message?, (.result.content[]? | select(.type == "text") | .text) ]
         | map(select(. != null)) | join(" ")' "$1" 2>/dev/null \
    | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C cut -c1-200
  return 0
}

# mcp_turn_start <prompt-file> <events-out> <msg-out> <stderr-out>
#
# Fresh server, handshake, one `tools/call codex` with the mirrored parameters,
# and the per-turn watchdog. It RETURNS a status and NEVER exits once a turn has
# started: the wrapper captures it under `set +e` and runs the SHARED accounting
# (turn_usage over whatever the stream managed to carry, the `USAGE:` line, the
# diagnostics) BEFORE exiting 1. A turn hung on an elicitation therefore never
# hangs the orchestrator, and never escapes the ledger either.
#
# rc 0 = the turn produced a result · 1 = it did not, with MCP_STATUS naming why.
# On success MCP_THREAD_ID holds the id the server echoed.
#
# shellcheck disable=SC2034  # MCP_STATUS and MCP_THREAD_ID are the outputs the
# wrapper reads back after this returns.
mcp_turn_start() {
  local prompt_file="$1" events_out="$2" msg_out="$3" stderr_out="$4"
  local raw_out="$events_out.mcp.raw.ndjson"
  local args req cfg prompt_json cwd frame rc=0
  MCP_STATUS=""
  MCP_THREAD_ID=""
  MCP_STDERR="$stderr_out"
  : >"$stderr_out" 2>/dev/null || true
  : >"$events_out" 2>/dev/null || true
  : >"$raw_out" 2>/dev/null || true

  cfg="$(mcp_pins_config_json)"
  if [ -z "$cfg" ]; then
    MCP_STATUS="could not render the pinned policy as the tool call's config map (jq)"
    return 1
  fi
  # The prompt crosses as a JSON string built from the FILE, never from a
  # command substitution: `$(cat …)` eats trailing newlines, and the exec path
  # feeds the very same bytes on stdin.
  prompt_json="$(jq -Rs . <"$prompt_file" 2>/dev/null)" || prompt_json=""
  if [ -z "$prompt_json" ]; then
    MCP_STATUS="could not read the rendered prompt: $prompt_file"
    return 1
  fi
  cwd="$(mcp_turn_cwd)"
  args="$(jq -nc \
    --argjson p "$prompt_json" \
    --arg m "${CODEX_MODEL:-}" \
    --arg s "${CODEX_SANDBOX:-}" \
    --arg cwd "$cwd" \
    --argjson cfg "$cfg" \
    '{prompt:$p, model:$m, sandbox:$s, "approval-policy":"never", cwd:$cwd, config:$cfg}' \
    2>/dev/null)" || args=""
  if [ -z "$args" ]; then
    MCP_STATUS="could not build the tool call arguments (jq)"
    return 1
  fi
  req="$(jq -nc --argjson a "$args" \
    '{jsonrpc:"2.0", id:2, method:"tools/call", params:{name:"codex", arguments:$a}}' \
    2>/dev/null)" || req=""
  if [ -z "$req" ]; then
    MCP_STATUS="could not build the tools/call frame (jq)"
    return 1
  fi

  if ! mcp_rpc_start; then
    MCP_STATUS="could not start \`codex mcp-server\` (fifo/spawn failed)"
    mcp_server_stop 1
    return 1
  fi
  if ! mcp_rpc_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tandem","version":"1"}}}'; then
    MCP_STATUS="could not write to the mcp server's stdin"
    mcp_server_stop 1
    return 1
  fi
  # ONE absolute deadline for the whole turn (Major: giving the full timeout to
  # the fifo guard, again to initialize and again to tools/call could add up to
  # far more than the 600s the caller allows — the wrapper must own its clock).
  # Every wait gets what REMAINS, never the whole budget again.
  mcp_rpc_wait 1 "$(mcp_deadline_left)" "$MCP_TMP/initialize.json" || rc=$?
  if [ "$rc" -ne 0 ]; then
    MCP_STATUS="the mcp server never completed the handshake (initialize)"
    mcp_server_stop 1
    return 1
  fi
  mcp_rpc_send '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true
  if ! mcp_rpc_send "$req"; then
    MCP_STATUS="could not send the tools/call frame to the mcp server"
    mcp_server_stop 1
    return 1
  fi

  # --- from here on the turn has STARTED: only `return`, never `exit` --------
  rc=0
  mcp_rpc_wait 2 "$(mcp_deadline_left)" "$MCP_TMP/result.json" || rc=$?
  # The server is stopped on EVERY path before anything else is read: it must
  # write no more frames while the events are adapted, and the rollout may not
  # be touched while the recorder still appends to it.
  mcp_server_stop 2
  # The adapter's failure is checked IMMEDIATELY: narrating, relocating and
  # deleting the source rollout on top of a half-published events file would
  # leave an orphan rollout and unusable accounting, and the wrapper would only
  # notice later, as a missing thread.started.
  if ! mcp_events_adapt "$MCP_RPC_OUT" "$events_out" "$raw_out"; then
    return 1
  fi
  # The same narration the exec path produces, from the same events.
  if command -v stream_milestones >/dev/null 2>&1; then
    stream_milestones <"$events_out" || true
  fi
  case "$rc" in
    0) : ;;
    2)
      MCP_STATUS="the mcp server exited before answering the turn"
      return 1
      ;;
    *)
      MCP_STATUS="no answer within ${MCP_TIMEOUT}s — the per-turn watchdog expired and the server's process group was reaped"
      return 1
      ;;
  esac

  frame="$MCP_TMP/result.json"
  if [ "$(jq -r '.result.isError // false' "$frame" 2>/dev/null)" = "true" ]; then
    MCP_STATUS="the mcp tool call answered with isError: $(mcp_result_text "$frame")"
    return 1
  fi
  if jq -e 'has("error")' "$frame" >/dev/null 2>&1; then
    MCP_STATUS="the mcp server answered with a JSON-RPC error: $(mcp_result_text "$frame")"
    return 1
  fi
  MCP_THREAD_ID="$(jq -r '.result.structuredContent.threadId // empty' "$frame" 2>/dev/null)" \
    || MCP_THREAD_ID=""
  if [ -z "$MCP_THREAD_ID" ]; then
    MCP_STATUS="the mcp result echoed no threadId — the turn cannot be tied to a thread"
    return 1
  fi
  jq -r '.result.structuredContent.content // empty' "$frame" >"$msg_out" 2>/dev/null || true

  if ! mcp_rollout_relocate "$MCP_THREAD_ID"; then
    MCP_STATUS="$MCP_RELOCATE_STATUS"
    return 1
  fi
  return 0
}
