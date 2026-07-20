#!/usr/bin/env bash
# tandem — status line renderer.
#
# Claude Code pipes a JSON session snapshot on stdin (model, effort, context
# window, cost, workspace) and prints whatever this script writes to stdout
# below the prompt. Line 1 is always the session; line 2 appears only while a
# Codex turn is in flight or has just finished, and is read from the heartbeat
# written by codex-start.sh / codex-resume.sh.
#
# Contract: never fail, never block. Any missing field, absent .tandem/ tree or
# missing jq degrades to a shorter line instead of an error — a status line
# that errors or hangs simply disappears from the UI.
#
# install (project or user settings.json):
#   "statusLine": { "type": "command", "refreshInterval": 2,
#                   "command": "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" }

set -uo pipefail

INPUT="$(cat)"

# Colours: 256-colour SGR, honouring NO_COLOR. Kept as variables so the layout
# below stays readable.
if [ -n "${NO_COLOR:-}" ]; then
  R='' DIM='' BOLD='' CYAN='' GREEN='' YELLOW='' RED='' GREY='' MAGENTA=''
else
  R=$'\033[0m' DIM=$'\033[2m' BOLD=$'\033[1m'
  CYAN=$'\033[38;5;44m' GREEN=$'\033[38;5;78m' YELLOW=$'\033[38;5;179m'
  RED=$'\033[38;5;168m' GREY=$'\033[38;5;245m' MAGENTA=$'\033[38;5;140m'
fi
SEP="${GREY} · ${R}"

command -v jq >/dev/null 2>&1 || { printf '%s\n' "${GREY}tandem: jq not found${R}"; exit 0; }

# One jq pass, tab-separated, so a malformed payload costs a single failure.
IFS=$'\t' read -r MODEL EFFORT CTX_PCT COST PROJECT_DIR CUR_DIR THINKING <<EOF
$(printf '%s' "$INPUT" | jq -r '
  [ (.model.display_name // .model.id // "?"),
    (.effort.level // ""),
    (.context_window.used_percentage // ""),
    (.cost.total_cost_usd // 0),
    (.workspace.project_dir // .cwd // ""),
    (.workspace.current_dir // .cwd // ""),
    (if .thinking.enabled then "1" else "" end)
  ] | @tsv' 2>/dev/null)
EOF
[ -n "${MODEL:-}" ] || MODEL="?"

# --- line 1: the session ----------------------------------------------------
LINE1="${CYAN}${BOLD}◈ ${MODEL}${R}"
[ -n "${EFFORT:-}" ] && LINE1="${LINE1} ${MAGENTA}${EFFORT}${R}"
[ -n "${THINKING:-}" ] && LINE1="${LINE1}${MAGENTA}✳${R}"

if [ -n "${CTX_PCT:-}" ]; then
  PCT="${CTX_PCT%%.*}"
  case "$PCT" in '' | *[!0-9]*) PCT=0 ;; esac
  # 10-cell gauge; colour tracks urgency, not decoration.
  if [ "$PCT" -ge 80 ]; then CTX_COL="$RED"
  elif [ "$PCT" -ge 60 ]; then CTX_COL="$YELLOW"
  else CTX_COL="$GREEN"; fi
  FILLED=$((PCT / 10))
  [ "$FILLED" -gt 10 ] && FILLED=10
  BAR=""
  i=0
  while [ "$i" -lt 10 ]; do
    if [ "$i" -lt "$FILLED" ]; then BAR="${BAR}▓"; else BAR="${BAR}░"; fi
    i=$((i + 1))
  done
  LINE1="${LINE1}${SEP}${CTX_COL}ctx ${PCT}% ${BAR}${R}"
fi

if [ -n "${COST:-}" ] && [ "$COST" != "0" ]; then
  LINE1="${LINE1}${SEP}${GREY}\$$(printf '%.2f' "$COST" 2>/dev/null || printf '%s' "$COST")${R}"
fi

if [ -n "${CUR_DIR:-}" ]; then
  LINE1="${LINE1}${SEP}${GREY}$(basename "$CUR_DIR")${R}"
  BRANCH="$(git -C "$CUR_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  [ -n "$BRANCH" ] && LINE1="${LINE1} ${GREY}⑂ ${BRANCH}${R}"
fi

printf '%s\n' "$LINE1"

# --- line 2: the Codex gate -------------------------------------------------
HB="${PROJECT_DIR:-$CUR_DIR}/.tandem/state/current.json"
[ -f "$HB" ] || exit 0

IFS=$'\t' read -r HB_ROLE HB_MODEL HB_EFFORT HB_SANDBOX HB_TARGET HB_TURN HB_PID HB_START HB_UPDATED HB_STATUS HB_VERDICT <<EOF
$(jq -r '
  [ (.role // "?"), (.model // "?"), (.effort // ""), (.sandbox // ""),
    (.target // ""), (.turn // 0), (.pid // 0), (.started_at // 0),
    (.updated_at // 0), (.status // "?"), (.verdict // "")
  ] | @tsv' "$HB" 2>/dev/null)
EOF
[ -n "${HB_STATUS:-}" ] || exit 0

NOW="$(date +%s)"
case "${HB_UPDATED:-0}" in '' | *[!0-9]*) HB_UPDATED=0 ;; esac
case "${HB_START:-0}" in '' | *[!0-9]*) HB_START=0 ;; esac

# A finished turn stays visible for a while, then stops cluttering the prompt.
if [ "$HB_STATUS" != "running" ] && [ $((NOW - HB_UPDATED)) -gt 900 ]; then
  exit 0
fi

# A 'running' heartbeat whose process is gone means the turn was killed without
# the EXIT guard firing (SIGKILL, terminal closed). Show it as unknown rather
# than pretending Codex is still working.
if [ "$HB_STATUS" = "running" ] && [ "${HB_PID:-0}" -gt 0 ] \
   && ! kill -0 "$HB_PID" 2>/dev/null; then
  HB_STATUS="orphaned"
fi

case "$HB_STATUS" in
  running)   ICON="⚙" COL="$YELLOW" ;;
  done)
    case "$HB_VERDICT" in
      APPROVED | IMPLEMENTATION_COMPLETE) ICON="✓" COL="$GREEN" ;;
      REVISE | IMPLEMENTATION_PARTIAL)    ICON="↺" COL="$YELLOW" ;;
      REQUEST_CHANGES | NEEDS_REWORK)     ICON="✗" COL="$RED" ;;
      *)                                  ICON="✓" COL="$GREEN" ;;
    esac ;;
  failed)    ICON="✗" COL="$RED" ;;
  orphaned)  ICON="⚠" COL="$GREY" ;;
  *)         ICON="·" COL="$GREY" ;;
esac

LINE2="${COL}${ICON} codex ${HB_MODEL}${R}${SEP}${COL}${HB_ROLE}${R}"
[ -n "${HB_EFFORT:-}" ] && LINE2="${LINE2} ${GREY}${HB_EFFORT}${R}"
[ "${HB_TURN:-0}" != "0" ] && LINE2="${LINE2}${SEP}${GREY}t${HB_TURN}${R}"
[ -n "${HB_SANDBOX:-}" ] && LINE2="${LINE2}${SEP}${GREY}${HB_SANDBOX}${R}"

# Elapsed while running; total duration once finished.
if [ "$HB_START" -gt 0 ]; then
  if [ "$HB_STATUS" = "running" ]; then EL=$((NOW - HB_START)); else EL=$((HB_UPDATED - HB_START)); fi
  [ "$EL" -lt 0 ] && EL=0
  if [ "$EL" -ge 60 ]; then ELAPSED="$((EL / 60))m$((EL % 60))s"; else ELAPSED="${EL}s"; fi
  LINE2="${LINE2}${SEP}${COL}${ELAPSED}${R}"
fi

if [ -n "${HB_VERDICT:-}" ] && [ "$HB_STATUS" != "running" ]; then
  LINE2="${LINE2}${SEP}${COL}${HB_VERDICT}${R}"
fi
[ "$HB_STATUS" = "orphaned" ] && LINE2="${LINE2}${SEP}${GREY}no process${R}"

if [ -n "${HB_TARGET:-}" ]; then
  SHORT="$(basename "$HB_TARGET")"
  SHORT="${SHORT%.plan.md}"
  LINE2="${LINE2}${SEP}${DIM}${SHORT}${R}"
fi

printf '%s\n' "$LINE2"
