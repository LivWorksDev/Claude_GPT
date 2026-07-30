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

# One jq pass per payload. Fields are joined with the unit separator (\x1f),
# NOT @tsv: tab is IFS whitespace, so consecutive tabs collapse and an empty
# field would silently shift every field after it one position left.
IFS=$'\x1f' read -r MODEL EFFORT CTX_PCT COST PROJECT_DIR CUR_DIR THINKING <<EOF
$(printf '%s' "$INPUT" | jq -r '
  [ (.model.display_name // .model.id // "?"),
    (.effort.level // ""),
    (.context_window.used_percentage // ""),
    (.cost.total_cost_usd // 0),
    (.workspace.project_dir // .cwd // ""),
    (.workspace.current_dir // .cwd // ""),
    (if .thinking.enabled then "1" else "" end)
  ] | join("\u001f")' 2>/dev/null)
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
# The heartbeat normally lives in the session's project dir; when the session
# itself runs inside a linked worktree, fall back to the main checkout
# (resolved via the common git dir), where codex-start/resume write it.
HB=""
for CAND in "${PROJECT_DIR:-}" "${CUR_DIR:-}"; do
  if [ -n "$CAND" ] && [ -f "$CAND/.tandem/state/current.json" ]; then
    HB="$CAND/.tandem/state/current.json"; break
  fi
done
if [ -z "$HB" ] && [ -n "${CUR_DIR:-}" ]; then
  COMMON="$(git -C "$CUR_DIR" rev-parse --git-common-dir 2>/dev/null)"
  if [ -n "$COMMON" ]; then
    case "$COMMON" in /*) : ;; *) COMMON="$CUR_DIR/$COMMON" ;; esac
    MAIN="$(CDPATH='' cd -- "$(dirname -- "$COMMON")" 2>/dev/null && pwd)"
    [ -n "$MAIN" ] && [ -f "$MAIN/.tandem/state/current.json" ] \
      && HB="$MAIN/.tandem/state/current.json"
  fi
fi
[ -n "$HB" ] || exit 0

# Same unit-separator transport as line 1 — an empty verdict must not shift
# the events path into the wrong variable. The token fields sit at the END of
# the list on purpose: a heartbeat written by an older version simply has none,
# and the missing values must degrade to empty instead of shifting every field
# after them (the v0.5.0 bug this transport exists to prevent). They cross the
# transport only when they really are JSON numbers: a string, an array or an
# object there is corruption, and it must not survive as text that looks like a
# token count — nor make `join` fail and take the whole line down with it.
IFS=$'\x1f' read -r HB_ROLE HB_MODEL HB_EFFORT HB_SANDBOX HB_TARGET HB_TURN HB_PID HB_START HB_UPDATED HB_STATUS HB_VERDICT HB_EVENTS HB_TOK_IN HB_TOK_OUT <<EOF
$(jq -r '
  [ (.role // "?"), (.model // "?"), (.effort // ""), (.sandbox // ""),
    (.target // ""), (.turn // 0), (.pid // 0), (.started_at // 0),
    (.updated_at // 0), (.status // "?"), (.verdict // ""), (.events // ""),
    (if (.tokens_in | type) == "number" then (.tokens_in | tostring) else "" end),
    (if (.tokens_out | type) == "number" then (.tokens_out | tostring) else "" end)
  ] | join("\u001f")' "$HB" 2>/dev/null)
EOF
[ -n "${HB_STATUS:-}" ] || exit 0

NOW="$(date +%s)"
case "${HB_UPDATED:-0}" in '' | *[!0-9]*) HB_UPDATED=0 ;; esac
case "${HB_START:-0}" in '' | *[!0-9]*) HB_START=0 ;; esac
# A corrupt pid must degrade silently: `-gt` on a non-number prints an
# "integer expression expected" to stderr, which surfaces in the UI as noise.
case "${HB_PID:-0}" in '' | *[!0-9]*) HB_PID=0 ;; esac

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
      APPROVED | IMPLEMENTATION_COMPLETE | IMAGE_READY) ICON="✓" COL="$GREEN" ;;
      REVISE | IMPLEMENTATION_PARTIAL)    ICON="↺" COL="$YELLOW" ;;
      REQUEST_CHANGES | NEEDS_REWORK | IMAGE_BLOCKED) ICON="✗" COL="$RED" ;;
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

# Live activity while running: the last meaningful item event in the NDJSON
# says what Codex is doing right now. tail -c bounds the read (single events
# can be huge); fromjson? tolerates the partial first line that produces.
if [ "$HB_STATUS" = "running" ] && [ -n "${HB_EVENTS:-}" ] && [ -f "$HB_EVENTS" ]; then
  ACT="$(tail -c 100000 "$HB_EVENTS" 2>/dev/null | jq -Rrs '
    [ split("\n")[] | fromjson?
      | select(.type == "item.started" or .type == "item.updated"
               or .type == "item.completed")
      | .item
      | if .item_type == "command_execution" then
          "exec \((.command // "?") | gsub("\\s+"; " ") | .[0:40])"
        elif .item_type == "file_change" then
          ((.changes // []) as $c
           | if ($c | length) == 1 then "edit \(($c[0].path // "?") | split("/") | last)"
             elif ($c | length) > 1 then "edit \($c | length) files"
             else "edit" end)
        elif .item_type == "reasoning" then "thinking…"
        elif .item_type == "agent_message" then "writing reply…"
        elif .item_type == "web_search" then "searching web…"
        else empty end ]
    | last // empty' 2>/dev/null || true)"
  [ -n "$ACT" ] && LINE2="${LINE2}${SEP}${COL}${ACT}${R}"
fi

# Elapsed while running; total duration once finished.
if [ "$HB_START" -gt 0 ]; then
  if [ "$HB_STATUS" = "running" ]; then EL=$((NOW - HB_START)); else EL=$((HB_UPDATED - HB_START)); fi
  [ "$EL" -lt 0 ] && EL=0
  if [ "$EL" -ge 60 ]; then ELAPSED="$((EL / 60))m$((EL % 60))s"; else ELAPSED="${EL}s"; fi
  LINE2="${LINE2}${SEP}${COL}${ELAPSED}${R}"
fi

# What the turn cost, once it is over. Both values must be plain non-negative
# integers or the whole segment disappears — a string, a decimal, a negative or
# a corrupt field is sanitized away exactly like the pid and the timestamps
# above, before any arithmetic can print "integer expression expected" into the
# UI. 'running' never shows them: the heartbeat carries null by contract.
hb_tok_ok() {
  # hb_tok_ok <value> — a decimal integer bash can safely do arithmetic on.
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # 16+ digits would overflow bash's signed arithmetic and print nonsense.
  [ "${#1}" -le 15 ] || return 1
  return 0
}

hb_tok_human() {
  # hb_tok_human <integer> — 999 · 1.2k · 12k · 1.5M, at most one decimal.
  # Integer arithmetic only: bash 3.2 ships no bc and no floating point.
  local n=$((10#$1)) d
  if [ "$n" -lt 1000 ]; then
    printf '%s' "$n"
  elif [ "$n" -lt 1000000 ]; then
    d=$(((n % 1000) / 100))
    if [ "$n" -ge 10000 ] || [ "$d" -eq 0 ]; then printf '%sk' "$((n / 1000))"
    else printf '%s.%sk' "$((n / 1000))" "$d"; fi
  else
    d=$(((n % 1000000) / 100000))
    if [ "$n" -ge 10000000 ] || [ "$d" -eq 0 ]; then printf '%sM' "$((n / 1000000))"
    else printf '%s.%sM' "$((n / 1000000))" "$d"; fi
  fi
}

if { [ "$HB_STATUS" = "done" ] || [ "$HB_STATUS" = "failed" ]; } \
   && hb_tok_ok "${HB_TOK_IN:-}" && hb_tok_ok "${HB_TOK_OUT:-}"; then
  LINE2="${LINE2}${SEP}${GREY}$(hb_tok_human "$HB_TOK_IN")→$(hb_tok_human "$HB_TOK_OUT")${R}"
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
