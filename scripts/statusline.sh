#!/usr/bin/env bash
# tandem — status line renderer.
#
# Claude Code pipes a JSON session snapshot on stdin (model, effort, context
# window, cost, workspace) and prints whatever this script writes to stdout
# below the prompt. Line 1 is always the session; line 2 belongs to whichever
# implementation is in flight or has just finished — the Codex heartbeat
# written by codex-start.sh / codex-resume.sh, or the durable Opus attempt
# state the implement skill writes to .tandem/state/implement-claude/.
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

# --- line 2: the Codex gate, or the Opus attempt ----------------------------
# Two sources can claim this row: the Codex heartbeat (a turn in flight or just
# finished) and the durable Opus attempt state the implement skill writes. The
# rule is "a LIVE Codex turn always wins; between states that are NOT live, the
# newest one does". Absolute priority for any renderable heartbeat would make
# the Opus row invisible exactly when it matters: the pipeline runs the Sol
# plan-review and the implementation back to back, so a lingering terminal
# heartbeat — or an orphaned one, which never ages out — would cover every
# future attempt.
NOW="$(date +%s)"

state_is() {
  # state_is <f|d|j> <path> — the existence test, picked without an eval.
  # 'j' means "a directory that actually CONTAINS at least one *.json": the
  # dual-root fallback must resolve on real candidates, because an EMPTY
  # implement-claude/ in a linked worktree would otherwise mask the main
  # checkout's perfectly valid attempt state.
  case "$1" in
    f) [ -f "$2" ] ;;
    d) [ -d "$2" ] ;;
    j)
      [ -d "$2" ] || return 1
      local _j
      for _j in "$2"/*.json; do
        [ -f "$_j" ] && return 0
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

state_path() {
  # state_path <f|d> <path under .tandem/> — state normally lives in the
  # session's project dir; when the session itself runs inside a linked
  # worktree, fall back to the main checkout (resolved via the common git dir),
  # where codex-start/resume and the implement skill write it. Prints nothing
  # when there is none.
  local kind="$1" rel="$2" cand common main
  for cand in "${PROJECT_DIR:-}" "${CUR_DIR:-}"; do
    [ -n "$cand" ] || continue
    if state_is "$kind" "$cand/.tandem/$rel"; then
      printf '%s' "$cand/.tandem/$rel"
      return 0
    fi
  done
  [ -n "${CUR_DIR:-}" ] || return 1
  common="$(git -C "$CUR_DIR" rev-parse --git-common-dir 2>/dev/null)"
  [ -n "$common" ] || return 1
  case "$common" in /*) : ;; *) common="$CUR_DIR/$common" ;; esac
  main="$(CDPATH='' cd -- "$(dirname -- "$common")" 2>/dev/null && pwd)"
  [ -n "$main" ] || return 1
  state_is "$kind" "$main/.tandem/$rel" || return 1
  printf '%s' "$main/.tandem/$rel"
}

# --- candidate 1: the Codex heartbeat ---------------------------------------
# Parsed and CLASSIFIED, never rendered on the spot except when it is live: a
# heartbeat that is absent, corrupt or aged out simply stops being a candidate,
# and that must not exit — the Opus attempt below may still have something to
# say.
HB_ROLE="" HB_MODEL="" HB_EFFORT="" HB_SANDBOX="" HB_TARGET="" HB_TURN=0
HB_PID=0 HB_START=0 HB_UPDATED=0 HB_STATUS="" HB_VERDICT="" HB_EVENTS=""
HB_TOK_IN="" HB_TOK_OUT=""
HB_ELIGIBLE=0 HB_LIVE=0

HB="$(state_path f state/current.json)"
if [ -n "$HB" ]; then
  # Same unit-separator transport as line 1 — an empty verdict must not shift
  # the events path into the wrong variable. The token fields sit at the END of
  # the list on purpose: a heartbeat written by an older version simply has
  # none, and the missing values must degrade to empty instead of shifting
  # every field after them (the v0.5.0 bug this transport exists to prevent).
  # They cross the transport only when they really are JSON numbers: a string,
  # an array or an object there is corruption, and it must not survive as text
  # that looks like a token count — nor make `join` fail and take the whole
  # line down with it.
  IFS=$'\x1f' read -r HB_ROLE HB_MODEL HB_EFFORT HB_SANDBOX HB_TARGET HB_TURN HB_PID HB_START HB_UPDATED HB_STATUS HB_VERDICT HB_EVENTS HB_TOK_IN HB_TOK_OUT <<EOF
$(jq -r '
  [ (.role // "?"), (.model // "?"), (.effort // ""), (.sandbox // ""),
    (.target // ""), (.turn // 0), (.pid // 0), (.started_at // 0),
    (.updated_at // 0), (.status // "?"), (.verdict // ""), (.events // ""),
    (if (.tokens_in | type) == "number" then (.tokens_in | tostring) else "" end),
    (if (.tokens_out | type) == "number" then (.tokens_out | tostring) else "" end)
  ] | join("\u001f")' "$HB" 2>/dev/null)
EOF
  case "${HB_UPDATED:-0}" in '' | *[!0-9]*) HB_UPDATED=0 ;; esac
  case "${HB_START:-0}" in '' | *[!0-9]*) HB_START=0 ;; esac
  # A corrupt pid must degrade silently: `-gt` on a non-number prints an
  # "integer expression expected" to stderr, which surfaces in the UI as noise.
  case "${HB_PID:-0}" in '' | *[!0-9]*) HB_PID=0 ;; esac

  if [ -n "${HB_STATUS:-}" ]; then
    # A finished turn stays a candidate for a while, then stops cluttering the
    # prompt; a running one is exempt however old its timestamp is.
    if [ "$HB_STATUS" != "running" ] && [ $((NOW - HB_UPDATED)) -gt 900 ]; then
      HB_ELIGIBLE=0
    else
      HB_ELIGIBLE=1
      # A 'running' heartbeat whose process is gone means the turn was killed
      # without the EXIT guard firing (SIGKILL, terminal closed). Show it as
      # unknown rather than pretending Codex is still working. A pid of 0 — or
      # a corrupt one, sanitized to 0 — is UNKNOWN, not dead: only a pid that
      # is provably gone demotes the turn, everything else keeps the absolute
      # priority of a live one.
      if [ "$HB_STATUS" = "running" ] && [ "${HB_PID:-0}" -gt 0 ] \
         && ! kill -0 "$HB_PID" 2>/dev/null; then
        HB_STATUS="orphaned"
      elif [ "$HB_STATUS" = "running" ]; then
        HB_LIVE=1
      fi
    fi
  fi
fi

# --- candidate 2: the durable Opus attempt state ----------------------------
# `.tandem/state/implement-claude/<slug>.json` is rewritten by the implement
# skill on every launch and every continuation, so it carries presence and
# outcome — never live activity, which would have to be invented. The newest
# file by mtime is the attempt this session is about, and the slug is simply
# its name: attempt state uses the plain slug, not the checksummed target key
# of the Codex thread state.
#
# Skipped entirely while a live Codex turn holds the row.
OP_JSON="" OP_MTIME="" OP_OK="" OP_STATUS="" OP_SENTINEL="" OP_SLUG=""
OP_ELIGIBLE=0 OP_STALE=0
OP_US=$'\x1f'

op_mtime() {
  # op_mtime <file> — mtime in epoch seconds, BSD flavour then GNU. Neither
  # branch can be trusted by its exit status alone: GNU's `stat -f` is
  # --file-system and cheerfully prints a mount point, so a result only counts
  # when it is a plain number. Empty means "no clock available" — a visible
  # degradation (the entry renders without its window), never a crash.
  local m
  m="$(stat -f %m "$1" 2>/dev/null)"
  case "$m" in '' | *[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  case "$m" in '' | *[!0-9]*) m="" ;; esac
  printf '%s' "$m"
}

if [ "$HB_LIVE" != "1" ]; then
  OP_DIR="$(state_path j state/implement-claude)"
  if [ -n "$OP_DIR" ]; then
    for OP_CAND in "$OP_DIR"/*.json; do
      [ -f "$OP_CAND" ] || continue
      OP_CAND_M="$(op_mtime "$OP_CAND")"
      if [ -z "$OP_JSON" ]; then
        OP_JSON="$OP_CAND" OP_MTIME="$OP_CAND_M"
      elif [ -n "$OP_CAND_M" ] \
        && { [ -z "$OP_MTIME" ] || [ "$OP_CAND_M" -gt "$OP_MTIME" ]; }; then
        OP_JSON="$OP_CAND" OP_MTIME="$OP_CAND_M"
      fi
    done
  fi
fi

if [ -n "$OP_JSON" ]; then
  # The same unit-separator transport and the same distrust as the heartbeat: a
  # status that is not a string, or a sentinel that is neither a string nor
  # null, is corruption and only removes this candidate from the selection. It
  # must NEVER exit — one broken historical file would otherwise suppress a
  # perfectly valid Codex heartbeat.
  IFS=$'\x1f' read -r OP_OK OP_STATUS OP_SENTINEL <<EOF
$(jq -r --arg us "$OP_US" '
  if type == "object"
     and ((.status | type) == "string")
     and (((.last_sentinel | type) == "string")
          or ((.last_sentinel | type) == "null"))
  then ([ "1", .status, (.last_sentinel // "") ] | join($us))
  else empty end' "$OP_JSON" 2>/dev/null)
EOF
  if [ "${OP_OK:-}" = "1" ]; then
    case "$OP_STATUS" in
      running | terminal) OP_ELIGIBLE=1 ;;
    esac
  fi
  OP_SLUG="$(basename "$OP_JSON" 2>/dev/null)"
  OP_SLUG="${OP_SLUG%.json}"
fi

# Visibility windows, from the mtime of the JSON: a finished attempt ages out
# like a finished Codex turn (900 s), while a 'running' one that nothing ever
# closed is indistinguishable from a dead session after two hours — the longest
# attempt observed is ~25 min — and says so in grey instead of faking work.
if [ "$OP_ELIGIBLE" = "1" ] && [ -n "$OP_MTIME" ]; then
  OP_AGE=$((NOW - OP_MTIME))
  if [ "$OP_STATUS" = "terminal" ] && [ "$OP_AGE" -gt 900 ]; then
    OP_ELIGIBLE=0
  elif [ "$OP_STATUS" = "running" ] && [ "$OP_AGE" -gt 7200 ]; then
    OP_STALE=1
  fi
fi

# --- the winner -------------------------------------------------------------
# A live Codex turn wins outright. Otherwise the newest timestamp does: the
# JSON's mtime against the heartbeat's updated_at. Both clocks have second
# resolution and the pipeline's hand-over is immediate, so an exact tie goes to
# a 'running' Opus attempt (the state that has just been born) and to Codex in
# every other case (stable order: when in doubt, the existing path). With no
# mtime at all there is nothing to compare, so an eligible heartbeat keeps the
# row and the Opus attempt only renders when it is alone.
WINNER=""
if [ "$HB_LIVE" = "1" ]; then
  WINNER="codex"
elif [ "$OP_ELIGIBLE" = "1" ] && [ "$HB_ELIGIBLE" = "1" ]; then
  if [ -z "$OP_MTIME" ]; then
    WINNER="codex"
  elif [ "$OP_MTIME" -gt "$HB_UPDATED" ]; then
    WINNER="opus"
  elif [ "$OP_MTIME" -lt "$HB_UPDATED" ]; then
    WINNER="codex"
  elif [ "$OP_STATUS" = "running" ]; then
    WINNER="opus"
  else
    WINNER="codex"
  fi
elif [ "$OP_ELIGIBLE" = "1" ]; then
  WINNER="opus"
elif [ "$HB_ELIGIBLE" = "1" ]; then
  WINNER="codex"
fi

# --- line 2, the Opus attempt ------------------------------------------------
# Presence and outcome only. There is no live activity to show: the file
# changes exactly twice per turn, and anything in between would be invented.
if [ "$WINNER" = "opus" ]; then
  if [ "$OP_STALE" = "1" ]; then
    OP_ICON="⚠" OP_COL="$GREY" OP_WHAT="sin señal"
  elif [ "$OP_STATUS" = "running" ]; then
    OP_ICON="⚒" OP_COL="$YELLOW" OP_WHAT="running"
  else
    OP_WHAT="$OP_SENTINEL"
    case "$OP_SENTINEL" in
      IMPLEMENTATION_COMPLETE) OP_ICON="✓" OP_COL="$GREEN" ;;
      IMPLEMENTATION_PARTIAL)  OP_ICON="↺" OP_COL="$YELLOW" ;;
      *)                       OP_ICON="·" OP_COL="$GREY" ;;
    esac
  fi
  LINE2="${OP_COL}${OP_ICON} opus implement${R}"
  [ -n "$OP_WHAT" ] && LINE2="${LINE2}${SEP}${OP_COL}${OP_WHAT}${R}"
  [ -n "$OP_SLUG" ] && LINE2="${LINE2}${SEP}${DIM}${OP_SLUG}${R}"
  printf '%s\n' "$LINE2"
  exit 0
fi

# --- line 2, the Codex turn --------------------------------------------------
[ "$WINNER" = "codex" ] || exit 0

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
