#!/usr/bin/env bash
# tandem — diagnose the toolchain. Reports every problem found (does not stop
# at the first one) and exits non-zero if anything is broken.
#
# usage: codex-doctor.sh [--smoke]
#   --smoke  ALSO spend one REAL codex turn per UNIQUE configured model (two
#            with the default policy) to prove the model names still resolve —
#            a deprecation found here costs a one-line turn instead of half a
#            long run. It NEVER runs without the flag: a diagnostic must not
#            spend the user's quota unasked.
#
# env: TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS  per-model watchdog for --smoke
#      (default 120; a positive integer of seconds, anything else is a usage
#      error). Ignored without the flag.
#
# exit codes: 0 all good · 1 problems found · 64 usage error
#
# This script deliberately does NOT source _common.sh: its `set -euo pipefail`
# would abort the diagnosis at the first failure, and reporting everything is
# the whole point. It sources only _pins.sh, which by contract has no shell
# side effects and carries the argv policy block the --smoke turns share with
# the real wrappers.

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_pins.sh
. "$SCRIPT_DIR/_pins.sh"

# --- arguments ---------------------------------------------------------------
# With no arguments the output is exactly what it has always been, byte for
# byte; anything unknown is a usage error before a single line is printed.
usage() { printf 'usage: codex-doctor.sh [--smoke]\n' >&2; }

SMOKE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1 ;;
    *)
      printf 'tandem: unknown argument: %s\n' "$1" >&2
      usage
      exit 64
      ;;
  esac
  shift
done

# The watchdog override is validated only when it can matter: without --smoke
# nothing is launched, and a stray value in the environment must not turn the
# default diagnosis into a usage error.
SMOKE_TIMEOUT="${TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS:-120}"
if [ "$SMOKE" -eq 1 ]; then
  case "$SMOKE_TIMEOUT" in
    '' | *[!0-9]*) SMOKE_TIMEOUT_BAD=1 ;;
    *) SMOKE_TIMEOUT_BAD=0; [ "$((10#$SMOKE_TIMEOUT))" -gt 0 ] || SMOKE_TIMEOUT_BAD=1 ;;
  esac
  if [ "$SMOKE_TIMEOUT_BAD" -eq 1 ]; then
    printf 'tandem: TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS must be a positive integer of seconds (got: "%s")\n' \
      "$SMOKE_TIMEOUT" >&2
    usage
    exit 64
  fi
fi

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
info() { printf '        %s\n' "$1"; }

# --- Claude Code version, for the critical agent type's `effort: xhigh` -------
# The frontmatter `effort` field exists since Claude Code 2.1.78, but the VALUE
# `xhigh` only since 2.1.111: an older install accepts agents/implementer-critical.md
# and quietly runs it at the default effort, which would turn this plugin's
# central guarantee into a lie. Parsing and comparison are pure bash — no awk,
# no sed — so the check keeps working on a minimal PATH.
CRITICAL_MIN_CLAUDE="2.1.111"

# claude_dotted <text> — the first dotted-numeric token of <text>
# ("2.1.111 (Claude Code)" -> "2.1.111", "2.1.111-beta" -> "2.1.111"). Prints
# nothing and returns 1 when there is none: undeterminable, never "assume new".
claude_dotted() {
  local rest="$1" tok
  while [ -n "$rest" ]; do
    tok="${rest%%[[:space:]]*}"
    case "$tok" in
      [0-9]*)
        tok="${tok%%[!0-9.]*}"
        case "$tok" in
          *[0-9]*) printf '%s' "$tok"; return 0 ;;
        esac
        ;;
    esac
    case "$rest" in
      *[[:space:]]*) rest="${rest#*[[:space:]]}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# version_ge <have> <want> — dotted versions compared FIELD BY FIELD as decimal
# integers (a missing field is 0), because "2.1.111" is newer than "2.1.99" and
# a string comparison says the opposite. Any non-numeric field returns false:
# fail closed.
version_ge() {
  local hrest="$1" wrest="$2" h w i=1
  while [ "$i" -le 3 ]; do
    h="${hrest%%.*}"
    w="${wrest%%.*}"
    case "$hrest" in *.*) hrest="${hrest#*.}" ;; *) hrest="" ;; esac
    case "$wrest" in *.*) wrest="${wrest#*.}" ;; *) wrest="" ;; esac
    [ -n "$h" ] || h=0
    [ -n "$w" ] || w=0
    case "$h" in *[!0-9]*) return 1 ;; esac
    case "$w" in *[!0-9]*) return 1 ;; esac
    if [ "$((10#$h))" -gt "$((10#$w))" ]; then return 0; fi
    if [ "$((10#$h))" -lt "$((10#$w))" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

printf 'tandem doctor\n\n'

# codex binary
if ! command -v codex >/dev/null 2>&1; then
  bad "codex CLI not found in PATH"
  info "install: npm install -g @openai/codex@latest"
elif ! ver="$(codex --version 2>/dev/null)"; then
  bad "codex is in PATH but cannot run (missing/removed native binary)"
  info "repair: npm install -g @openai/codex@latest"
else
  ok "codex runs: $ver"
  # login
  if codex login status >/dev/null 2>&1; then
    ok "codex is logged in"
  else
    bad "codex is not logged in"
    info "run: codex login   (or: codex login --device-auth)"
  fi
fi

# jq
if command -v jq >/dev/null 2>&1; then
  ok "jq available: $(jq --version 2>/dev/null)"
else
  bad "jq not found (needed to capture thread ids)"
  info "install: brew install jq"
fi

# git
if command -v git >/dev/null 2>&1; then
  ok "git available"
else
  bad "git not found"
fi

# status line (optional integration — informational, never a FAIL)
printf '\nstatus line:\n'
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -x "$CLAUDE_DIR/tandem-statusline.sh" ] \
  && jq -e '.statusLine.command // "" | test("tandem-statusline")' \
       "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
  ok "installed (shim + settings.json)"
else
  info "not installed — /tandem:statusline, or:"
  info "bash \"$SCRIPT_DIR/statusline-install.sh\""
fi

# image generation (optional — only tandem:image transparency needs a backend;
# informational, never a FAIL)
printf '\nimage generation (tandem:image):\n'
if command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL.Image' >/dev/null 2>&1; then
  ok "chroma-key backend: python3 + Pillow (graded alpha + despill)"
elif command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
  ok "chroma-key backend: ImageMagick (binary alpha — install Pillow for cleaner sprite edges)"
else
  info "no chroma-key backend — transparent backgrounds will report IMAGE_BLOCKED"
  info "install: pip3 install Pillow   (or: brew install imagemagick)"
fi

# model policy (mirrors _common.sh resolve_role)
printf '\nmodel policy (override via env):\n'
info "review/ask:  model=${TANDEM_REVIEW_MODEL:-gpt-5.6-sol} effort=${TANDEM_REVIEW_EFFORT:-xhigh} sandbox=read-only (pinned)"
# Default only when UNSET: a set-but-empty selector is a config error, not opus.
implementer="${TANDEM_IMPLEMENTER-opus}"
case "$implementer" in
  "")
    bad "TANDEM_IMPLEMENTER is set but empty — expected opus or sol"
    ;;
  opus)
    info "implementer: opus — Claude Opus 5 subagent (default; harness tool allowlist, Bash has no OS sandbox)"
    if [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
      info "TANDEM_CRITICAL=1 (agent type tandem:implementer-critical, frontmatter effort=xhigh; review remains mandatory)"
      # Mirror of tandem:implement's gate 3. CLAUDE_CODE_EFFORT_LEVEL takes
      # precedence over the agent type's frontmatter effort, so a defined value
      # other than xhigh means the attempt runs as "critical" at a degraded
      # effort — announced here instead of discovered never.
      case "${CLAUDE_CODE_EFFORT_LEVEL+set}" in
        set)
          if [ "$CLAUDE_CODE_EFFORT_LEVEL" = "xhigh" ]; then
            ok "CLAUDE_CODE_EFFORT_LEVEL=xhigh (agrees with the critical agent type's effort)"
          else
            bad "CLAUDE_CODE_EFFORT_LEVEL='$CLAUDE_CODE_EFFORT_LEVEL' overrides the critical agent type's frontmatter effort: xhigh — the attempt would run as critical at a degraded effort; tandem:implement's preflight will STOP the run"
            info "fix, any of: unset CLAUDE_CODE_EFFORT_LEVEL · set it to exactly xhigh · run with TANDEM_IMPLEMENTER=sol"
          fi
          ;;
      esac
      # Version gate: without it the whole guarantee would be false on installs
      # between 2.1.78 (frontmatter effort) and 2.1.111 (the value xhigh).
      # Only under CRITICAL + opus: nobody else pays for this check.
      claude_raw=""
      claude_ver=""
      if command -v claude >/dev/null 2>&1; then
        claude_raw="$(claude --version 2>/dev/null)" || claude_raw=""
        claude_ver="$(claude_dotted "$claude_raw")" || claude_ver=""
      fi
      if [ -z "$claude_ver" ]; then
        bad "Claude Code version is undeterminable (no 'claude' in PATH, or 'claude --version' printed nothing usable) — the critical agent type's effort xhigh needs Claude Code >= $CRITICAL_MIN_CLAUDE and cannot be confirmed here"
        info "fix, any of: install/repair the claude CLI so 'claude --version' answers · update Claude Code · run with TANDEM_IMPLEMENTER=sol · drop TANDEM_CRITICAL"
      elif version_ge "$claude_ver" "$CRITICAL_MIN_CLAUDE"; then
        ok "Claude Code $claude_ver >= $CRITICAL_MIN_CLAUDE (the critical agent type's effort xhigh is supported)"
      else
        bad "Claude Code $claude_ver < $CRITICAL_MIN_CLAUDE — the frontmatter effort field is accepted but the VALUE xhigh is not, so the critical agent type would run at the default effort"
        info "fix, any of: update Claude Code · run with TANDEM_IMPLEMENTER=sol · drop TANDEM_CRITICAL"
      fi
    else
      info "TANDEM_CRITICAL=0 (1 selects the tandem:implementer-critical agent type, frontmatter effort=xhigh; review remains mandatory)"
    fi
    # CLAUDE_CODE_SUBAGENT_MODEL takes precedence over the agent type's
    # `model: opus`, so any other value silently swaps the implementer's model.
    # tandem:implement's preflight is fail-closed about it and STOPS the run —
    # discovering that mid-pipeline is exactly what this line prevents. Under
    # `sol` the check does not apply: that transport uses no subagent.
    case "${CLAUDE_CODE_SUBAGENT_MODEL+set}" in
      set)
        if [ "$CLAUDE_CODE_SUBAGENT_MODEL" = "opus" ]; then
          ok "CLAUDE_CODE_SUBAGENT_MODEL=opus (agrees with the implementer subagent)"
        else
          bad "CLAUDE_CODE_SUBAGENT_MODEL='$CLAUDE_CODE_SUBAGENT_MODEL' overrides the implementer subagent's model: opus — tandem:implement's preflight will STOP the run"
          info "fix, any of: unset CLAUDE_CODE_SUBAGENT_MODEL · set it to exactly opus · run with TANDEM_IMPLEMENTER=sol"
        fi
        ;;
    esac
    ;;
  sol)
    if [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
      impl_effort="${TANDEM_IMPLEMENT_EFFORT:-xhigh}"
    else
      impl_effort="${TANDEM_IMPLEMENT_EFFORT:-high}"
    fi
    info "implementer: sol — Codex CLI transport"
    info "implement:   model=${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-sol} effort=$impl_effort sandbox=workspace-write (pinned)"
    # EFFECTIVE effort, never a promise: TANDEM_IMPLEMENT_EFFORT wins over
    # CRITICAL, so announcing "raises to xhigh" while the run will spend `low`
    # is propaganda, not diagnosis.
    if [ -n "${TANDEM_IMPLEMENT_EFFORT:-}" ]; then
      info "TANDEM_CRITICAL=${TANDEM_CRITICAL:-0}, but TANDEM_IMPLEMENT_EFFORT takes precedence — this run implements at effort $impl_effort"
    elif [ "${TANDEM_CRITICAL:-0}" = "1" ]; then
      info "TANDEM_CRITICAL=1 — Sol implements at effort xhigh (effective)"
    else
      info "TANDEM_CRITICAL=0 (1 raises Sol implementation effort to xhigh)"
    fi
    ;;
  *)
    bad "TANDEM_IMPLEMENTER=$implementer is invalid — expected opus or sol"
    ;;
esac
info "image:       model=${TANDEM_IMAGE_MODEL:-gpt-5.6-sol} effort=${TANDEM_IMAGE_EFFORT:-high} sandbox=workspace-write (pinned)"
# The swarm semaphore's dials are VALIDATED here, not merely displayed: a bad
# value makes EVERY seat of a run die with a usage error, and discovering that
# one seat at a time is exactly what a preflight exists to prevent. Same rules
# as codex-swarm.sh — expanded without `:` so set-but-empty is a config error,
# and normalized with 10# because `08`/`09` are not octal to anyone but bash.
ultra_conc="${TANDEM_ULTRA_CONCURRENCY-4}"
ultra_slot_timeout="${TANDEM_ULTRA_SLOT_TIMEOUT-1800}"
ultra_dial_ok() {
  # ultra_dial_ok <value> — true when it is a positive decimal integer.
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$((10#$1))" -ge 1 ] || return 1
  return 0
}
if ultra_dial_ok "$ultra_conc"; then
  ultra_conc="$((10#$ultra_conc))"
else
  bad "TANDEM_ULTRA_CONCURRENCY='$ultra_conc' is not a positive integer — every swarm seat would exit 64"
fi
if ultra_dial_ok "$ultra_slot_timeout"; then
  ultra_slot_timeout="$((10#$ultra_slot_timeout))"
else
  bad "TANDEM_ULTRA_SLOT_TIMEOUT='$ultra_slot_timeout' is not a positive integer — every swarm seat would exit 64"
fi
info "ultra seats: judge=${TANDEM_ULTRA_JUDGE_MODEL:-gpt-5.6-sol}/${TANDEM_ULTRA_JUDGE_EFFORT:-xhigh} worker=${TANDEM_ULTRA_WORKER_MODEL:-gpt-5.6-sol}/${TANDEM_ULTRA_WORKER_EFFORT:-high} scout=${TANDEM_ULTRA_SCOUT_MODEL:-gpt-5.6-luna}/${TANDEM_ULTRA_SCOUT_EFFORT:-high} sandbox=read-only (pinned) concurrency=$ultra_conc slot_timeout=${ultra_slot_timeout}s"
info "TANDEM_AUTONOMOUS=${TANDEM_AUTONOMOUS:-0} (1 replaces human gates with APPROVED+green-gate policy; commits stay on the tandem branch, never push/merge)"
if [ "${TANDEM_AUTONOMOUS:-0}" = "1" ] && [ -z "${TANDEM_PROMOTE_REVIEWS:-}" ]; then
  bad "TANDEM_AUTONOMOUS=1 but TANDEM_PROMOTE_REVIEWS is unset — autonomous runs must not ask mid-run; set it to 0 or 1"
fi

# --- model smoke (--smoke only) ----------------------------------------------
# "Is this model name still a model?" — asked with the cheapest possible real
# turn, one per UNIQUE configured model. It is NOT a pipeline test: no
# codex-start.sh, no threads, nothing under .tandem/ (a phantom thread here
# would show up in codex-show/codex-reset forever). The isolation is total
# because a turn that only has to answer "OK" needs no context at all:
# --ephemeral (no orphan session files), a private temp working root, the
# wrappers' full pin block from _pins.sh and no web search.

SMOKE_MODELS=()

# smoke_add <model> — appends unless already present (bash 3.2: no associative
# arrays). Deduplication is the point: with the default policy five roles name
# two distinct models, and the user pays per model, not per role.
smoke_add() {
  local m="$1" x
  [ -n "$m" ] || return 0
  for x in ${SMOKE_MODELS[@]+"${SMOKE_MODELS[@]}"}; do
    [ "$x" = "$m" ] && return 0
  done
  SMOKE_MODELS+=("$m")
  return 0
}

# smoke_watchdog <pid> <seconds> <marker> <group> — kills a turn that never
# answers, taking the whole process group down when the turn leads one (same
# pattern as tests/run.sh). Touches <marker> so the caller can tell a timeout
# apart from an exit code.
smoke_watchdog() {
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

# smoke_run_one <model> — ONE real turn. Sets SMOKE_RC and SMOKE_TIMEDOUT and
# leaves the reply in $SMOKE_REPLY, the stderr in $SMOKE_ERR. No effort override
# on purpose: `minimal` is not supported by the default models, and forcing an
# effort could report a healthy model as retired — the exact false negative the
# smoke exists to prevent. Every model runs at its own deterministic default
# (the user's config is ignored anyway).
# The group of the turn currently in flight, for the signal cleanup: an
# interrupted doctor must never orphan the isolated codex group it started.
SMOKE_ACTIVE_PID=0
SMOKE_ACTIVE_GROUP=0

smoke_cleanup() {
  local pid="${SMOKE_ACTIVE_PID:-0}" group="${SMOKE_ACTIVE_GROUP:-0}"
  if [ "$pid" -gt 0 ]; then
    # The GROUP is what must die, checked independently of the leader: during
    # the watchdog's TERM->KILL grace the leader is often already gone while a
    # TERM-resistant descendant keeps the group alive — gating the group kill
    # on leader liveness would orphan exactly that descendant.
    if [ "$group" = "1" ] && kill -0 -- -"$pid" 2>/dev/null; then
      kill -TERM -- -"$pid" 2>/dev/null
      sleep 1
      kill -KILL -- -"$pid" 2>/dev/null
    elif kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
    fi
  fi
  SMOKE_ACTIVE_PID=0
  [ -n "${SMOKE_TMP:-}" ] && rm -rf "$SMOKE_TMP" 2>/dev/null
  return 0
}

smoke_run_one() {
  local model="$1" pid wd group=0
  # Pre-delete like the wrappers do: a stale reply from the previous model must
  # never be read as this one's answer.
  rm -f "$SMOKE_REPLY" "$SMOKE_MARK"
  : >"$SMOKE_ERR"
  # Job control only around the fork, so the turn leads its OWN process group
  # and the watchdog cannot take this script down with it.
  set -m
  codex exec \
    --skip-git-repo-check --color never \
    --model "$model" \
    --sandbox "$CODEX_SANDBOX" \
    "${CODEX_PINS[@]}" \
    -c web_search=disabled \
    --ephemeral \
    --output-last-message "$SMOKE_REPLY" \
    - <"$SMOKE_PROMPT" >/dev/null 2>"$SMOKE_ERR" &
  pid=$!
  set +m
  if kill -0 -- -"$pid" 2>/dev/null; then group=1; fi
  SMOKE_ACTIVE_PID="$pid"
  SMOKE_ACTIVE_GROUP="$group"
  smoke_watchdog "$pid" "$SMOKE_TIMEOUT" "$SMOKE_MARK" "$group" &
  wd=$!
  SMOKE_RC=0
  # 2>/dev/null on `wait` itself: when the watchdog kills the group, bash would
  # otherwise print its own "Terminated: 15 <the whole command line>" job notice
  # into the middle of the diagnosis. The exit code still arrives, and the FAIL
  # line below says what happened in one readable sentence.
  wait "$pid" 2>/dev/null || SMOKE_RC=$?
  if [ -f "$SMOKE_MARK" ]; then
    # The watchdog fired: let it FINISH its TERM→KILL sequence. Killing it the
    # moment the group leader dies on TERM would skip the KILL that reaps
    # TERM-resistant descendants, and those would outlive the diagnosis.
    wait "$wd" 2>/dev/null
  else
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
  fi
  SMOKE_ACTIVE_PID=0
  SMOKE_TIMEDOUT=0
  [ -f "$SMOKE_MARK" ] && SMOKE_TIMEDOUT=1
  return 0
}

# smoke_model_error <stderr-file> — true only for model-not-available SEMANTICS.
# Never the mere presence of the model name: auth, quota and network errors
# quote it too, and calling those "the model is gone" would send the user
# chasing a deprecation that never happened.
smoke_model_error() {
  LC_ALL=C grep -E -i -q \
    -e 'model[^[:cntrl:]]{0,60}(not found|not_found|unknown|unsupported|not supported|does not exist|no longer|deprecated|retired|unavailable|not available|no access)' \
    -e '(unknown|unsupported|unrecognized|invalid|deprecated|retired) model' \
    -e 'model_not_found' \
    "$1" 2>/dev/null
}

smoke_show_stderr() {
  local l
  tail -n 5 "$1" 2>/dev/null | while IFS= read -r l; do
    [ -n "$l" ] || continue
    info "stderr: $l"
  done
  return 0
}

# smoke_report <model> — reads the outcome of the last smoke_run_one.
smoke_report() {
  local model="$1"
  if [ "$SMOKE_TIMEDOUT" = "1" ]; then
    bad "model $model: no reply within ${SMOKE_TIMEOUT}s — turn killed (NOT a model-availability failure)"
    info "action: check connectivity and 'codex login'; raise TANDEM_DOCTOR_SMOKE_TIMEOUT_SECONDS if the model is simply slow"
  elif [ "$SMOKE_RC" -eq 0 ] && [ -s "$SMOKE_REPLY" ]; then
    ok "model $model answers"
  elif smoke_model_error "$SMOKE_ERR"; then
    bad "model $model is not available — the CLI/API rejected the model NAME itself (renamed, retired or not enabled for this account)"
    info "action: point the matching TANDEM_*_MODEL override at a supported model, or update the Codex CLI"
    smoke_show_stderr "$SMOKE_ERR"
  else
    bad "model $model: the turn failed (exit $SMOKE_RC) — NOT a model-availability failure (auth, network or quota)"
    info "action: re-run 'codex login', check connectivity, then repeat --smoke"
    smoke_show_stderr "$SMOKE_ERR"
  fi
  return 0
}

if [ "$SMOKE" -eq 1 ]; then
  printf '\nmodel smoke (--smoke):\n'

  smoke_add "${TANDEM_REVIEW_MODEL:-gpt-5.6-sol}"
  # implement only under sol: the opus transport spends no codex turn at all,
  # and its model name already rides in through review/ask.
  if [ "$implementer" = "sol" ]; then
    smoke_add "${TANDEM_IMPLEMENT_MODEL:-gpt-5.6-sol}"
  fi
  smoke_add "${TANDEM_IMAGE_MODEL:-gpt-5.6-sol}"
  smoke_add "${TANDEM_ULTRA_JUDGE_MODEL:-gpt-5.6-sol}"
  smoke_add "${TANDEM_ULTRA_WORKER_MODEL:-gpt-5.6-sol}"
  smoke_add "${TANDEM_ULTRA_SCOUT_MODEL:-gpt-5.6-luna}"

  # The cost warning comes BEFORE anything is launched — the user must be able
  # to read what this is about to spend even if the first turn hangs.
  info "about to spend ${#SMOKE_MODELS[@]} REAL codex turns — one per unique configured model: ${SMOKE_MODELS[*]}"
  info "each turn: --ephemeral, private temp working root, no web search, no effort override, ${SMOKE_TIMEOUT}s watchdog"

  smoke_ready=1
  if ! command -v codex >/dev/null 2>&1; then
    bad "smoke not run: codex CLI not found in PATH"
    smoke_ready=0
  else
    # Capability probe, never a pipeline: `--help | grep -q` would make grep
    # close the pipe early, and pipefail would then read SIGPIPE as "the flag is
    # missing" and skip the smoke on a perfectly capable CLI. The exit status
    # counts too: help text scraped out of a FAILED probe proves nothing, and
    # launching real turns on unproven capability is exactly what the probe
    # exists to prevent.
    smoke_help_rc=0
    smoke_help="$(codex exec --help 2>/dev/null)" || smoke_help_rc=$?
    if [ "$smoke_help_rc" -ne 0 ]; then
      bad "smoke not run: 'codex exec --help' failed (rc $smoke_help_rc) — cannot verify --ephemeral support"
      info "nothing was launched; repair the CLI first: npm install -g @openai/codex@latest"
      smoke_ready=0
    else
      case "$smoke_help" in
        *--ephemeral*) : ;;
        *)
          bad "smoke not run: this codex CLI has no 'exec --ephemeral' flag"
          info "a diagnostic turn must not leave orphan session files behind, so nothing was launched"
          info "upgrade: npm install -g @openai/codex@latest"
          smoke_ready=0
          ;;
      esac
    fi
  fi

  if [ "$smoke_ready" -eq 1 ]; then
    SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tandem-smoke.XXXXXX" 2>/dev/null)"
    if [ -z "${SMOKE_TMP:-}" ] || [ ! -d "$SMOKE_TMP" ]; then
      bad "smoke not run: could not create a private temp directory under ${TMPDIR:-/tmp}"
      smoke_ready=0
    else
      # EXIT covers the normal path; INT/TERM cover an interrupted doctor —
      # both must reap the isolated codex group of the turn in flight, not just
      # the temp directory.
      trap 'smoke_cleanup' EXIT
      trap 'smoke_cleanup; exit 130' INT
      trap 'smoke_cleanup; exit 143' TERM
    fi
  fi

  if [ "$smoke_ready" -eq 1 ]; then
    SMOKE_CWD="$SMOKE_TMP/cwd"
    SMOKE_REPLY="$SMOKE_TMP/reply.txt"
    SMOKE_ERR="$SMOKE_TMP/stderr.txt"
    SMOKE_PROMPT="$SMOKE_TMP/prompt.txt"
    SMOKE_MARK="$SMOKE_TMP/timedout"
    mkdir -p "$SMOKE_CWD"
    printf 'Reply with exactly: OK\n' >"$SMOKE_PROMPT"

    # The ONE `--cd` comes from codex_pins (the CLI rejects two of them), so the
    # working root is fixed HERE, before the helper runs, and any inherited
    # TANDEM_CODEX_CWD — empty or not — is overwritten: the smoke never runs
    # over the user's repo.
    TANDEM_CODEX_CWD="$SMOKE_CWD"
    CODEX_SANDBOX="read-only"
    codex_pins

    for smoke_model in "${SMOKE_MODELS[@]}"; do
      smoke_run_one "$smoke_model"
      smoke_report "$smoke_model"
    done
  fi
fi

if [ "$fail" -ne 0 ]; then
  printf '\ntandem doctor: problems found — fix the FAIL lines above.\n'
  exit 1
fi
printf '\ntandem doctor: all good.\n'
