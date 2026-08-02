#!/usr/bin/env bash
# tandem — where a run stands, and how it is resumed. Read-only.
#
# usage: tandem-status.sh [slug]
#
#   With a slug: one report for that run — plan and approval, branch, rounds and
#   verdicts per phase, implementation attempt, testing gate, token totals, the
#   phase the evidence proves and a deterministic `next:`.
#   Without arguments: the known runs, one `<slug> — <phase>` line each.
#
# STRICTLY read-only: it never writes a byte (no state_init — which would
# mkdir —, no heartbeat, no log line) and it never calls codex. A tool that
# mutated the state it describes would break its only promise. That promise
# covers the SHELL too: no heredoc and no here-string anywhere in this file,
# because bash materializes both as temporary files — on a machine whose temp
# directory is not writable (a read-only sandbox, exactly the kind of broken
# environment this tool exists for) they fail, and a report built on failed
# reads would be a lie that still exited 0. Lists are arrays, command output is
# read through `$( )` (a pipe) and split in place.
#
# jq and git are SOFT dependencies, exactly like the status line's: their
# absence degrades the fields that need them to `desconocido`, never to an
# error (the deliberate contrast with the wrappers' `need_jq` exit 3 — those
# spend quota, this one spends nothing). An orientation tool has to answer on a
# broken machine: that is precisely when it is needed.
#
# exit codes: 0 report emitted (a partially `desconocido` report is still one)
#             2 the slug has no evidence at all (message + known runs on stderr),
#               OR the state roots contradict each other irreconcilably (both
#               roots, both phases and the offending fact on stderr, no report
#               and no next step: a report would have to pick a root for every
#               other row, which is the masking bug this refuses to commit)
#             64 usage error
# Never 1 or 3: there is no hard dependency here and no turn to spend.

set -uo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
# _common.sh arms `set -euo pipefail` for the wrappers. Here it would kill the
# very degradation this tool promises — a missing file, a failing grep, a jq
# that is not installed — so it goes off IMMEDIATELY, before anything is read.
# Only `target_key` (the cksum is not reconstructible by hand) and `hb_verdict`
# (the single sentinel regex of the repo) are borrowed; `_pins.sh`, sourced
# along the way, has no shell side effects by contract.
set +e

NL='
'
US=$'\x1f'

usage_die() {
  # usage_die <message> — a usage error names itself and prints the usage line.
  printf 'tandem: %s\n' "$1" >&2
  printf 'usage: tandem-status.sh [slug]\n' >&2
  exit 64
}

# --- soft dependencies -------------------------------------------------------
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_GIT=0
command -v git >/dev/null 2>&1 && HAVE_GIT=1

# --- arguments ---------------------------------------------------------------
[ $# -le 1 ] || usage_die "too many arguments"
LIST_MODE=1
ARG_SLUG=""
if [ $# -eq 1 ]; then
  LIST_MODE=0
  ARG_SLUG="$1"
  [ -n "$ARG_SLUG" ] || usage_die "empty slug"
  # Same charset as plan-approve.sh: the slug is a path component and a branch
  # name, so anything outside it is rejected instead of escaped.
  case "$ARG_SLUG" in
    *[!A-Za-z0-9._-]*) usage_die "invalid slug '$ARG_SLUG' — use [A-Za-z0-9._-] only" ;;
    [-.]*) usage_die "invalid slug '$ARG_SLUG' — must not start with '-' or '.'" ;;
  esac
fi

# --- where the state lives ---------------------------------------------------
# Dual-root resolution, like the status line's: the session's project dir, the
# working directory, and the MAIN checkout of each. In SLUG mode EVERY candidate
# carrying evidence OF THAT SLUG is analyzed and the results are reconciled (see
# the resolver below) — a foreign run's state in a linked worktree's .tandem
# must not mask the slug that lives under the main checkout, and a stale copy of
# the same run must not mask the authoritative one either. In LIST mode every
# candidate contributes (the deduplicated union), because a later root is not
# "the same answer twice".
git_main_from() {
  # git_main_from <dir> — the main checkout seen from <dir>, or nothing.
  local d="${1:-}" common main
  [ -n "$d" ] || return 1
  [ -d "$d" ] || return 1
  common="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)"
  [ -n "$common" ] || return 1
  case "$common" in /*) : ;; *) common="$d/$common" ;; esac
  main="$(CDPATH='' cd -- "$(dirname -- "$common")" 2>/dev/null && pwd)"
  [ -n "$main" ] || return 1
  printf '%s' "$main"
}

phys_path() {
  # phys_path <dir> — <dir> with every symlink resolved, or nothing. Two logical
  # names for one directory (a symlink to the checkout, /var vs /private/var on
  # macOS) are ONE root: deduplicating on the logical path would count the same
  # evidence twice and could even report it as contradicting itself.
  local d="${1:-}" p
  [ -n "$d" ] || return 0
  [ -d "$d" ] || return 0
  p="$(CDPATH='' cd -- "$d" 2>/dev/null && pwd -P)"
  [ -n "$p" ] || return 0
  printf '%s' "$p"
  return 0
}

CAND=()
CAND_N=0
add_cand() {
  local d="${1:-}" c i=0
  [ -n "$d" ] || return 0
  [ -d "$d" ] || return 0
  c="$(phys_path "$d")"
  [ -n "$c" ] || return 0
  while [ "$i" -lt "$CAND_N" ]; do
    [ "${CAND[$i]}" = "$c" ] && return 0
    i=$((i + 1))
  done
  CAND[CAND_N]="$c"
  CAND_N=$((CAND_N + 1))
  return 0
}

GITR=()
GITR_N=0
add_gitr() {
  local d="${1:-}" i=0
  [ -n "$d" ] || return 0
  while [ "$i" -lt "$GITR_N" ]; do
    [ "${GITR[$i]}" = "$d" ] && return 0
    i=$((i + 1))
  done
  GITR[GITR_N]="$d"
  GITR_N=$((GITR_N + 1))
  return 0
}

# The project dir comes FIRST everywhere, including for git: a session standing
# in an unrelated repository must not have its branch, its commit counts and
# its terminal record validated against that repository while the state is read
# from the project's.
DEFAULT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
add_cand "${CLAUDE_PROJECT_DIR:-}"
add_cand "$PWD"
GIT_ROOT_DEFAULT=""
if [ "$HAVE_GIT" = "1" ]; then
  GIT_MAIN_PROJ="$(git_main_from "${CLAUDE_PROJECT_DIR:-}")"
  GIT_MAIN_PWD="$(git_main_from "$PWD")"
  GIT_ROOT_DEFAULT="$GIT_MAIN_PROJ"
  [ -n "$GIT_ROOT_DEFAULT" ] || GIT_ROOT_DEFAULT="$GIT_MAIN_PWD"
  add_cand "$GIT_MAIN_PROJ"
  add_cand "$GIT_MAIN_PWD"
fi

# --- per-slug facts ----------------------------------------------------------
# Every key is rebuilt with the SAME literal label the skills use, through the
# real target_key: plan-review is role `review` on the plan path, code review is
# role `review` on `cr-<slug>`, and the Sol implementation is role `implement`
# on the plan path again.
compute_keys() {
  K_PLAN="$(target_key "docs/plans/$1.plan.md")"
  K_CR="$(target_key "cr-$1")"
}

slug_has_evidence() {
  # slug_has_evidence <root> <slug> — anything under <root>/.tandem that belongs
  # to THIS slug. Keys must already be computed.
  local t="$1/.tandem" s="$2"
  [ -f "$t/log/$s.md" ] && return 0
  [ -f "$t/state/plan-approve/$s.json" ] && return 0
  [ -f "$t/state/plan-approve/$s.json.pending" ] && return 0
  [ -f "$t/state/implement-claude/$s.json" ] && return 0
  [ -n "${K_PLAN:-}" ] && [ -f "$t/state/review/$K_PLAN.thread" ] && return 0
  [ -n "${K_PLAN:-}" ] && [ -f "$t/state/implement/$K_PLAN.thread" ] && return 0
  [ -n "${K_CR:-}" ] && [ -f "$t/state/review/$K_CR.thread" ] && return 0
  return 1
}

EVR=()
EVR_N=0
evidence_roots() {
  # evidence_roots <slug> — EVR[]/EVR_N: every candidate root that carries
  # evidence OF THAT SLUG, in candidate priority order. The keys must already be
  # computed for THIS slug (compute_keys): slug_has_evidence reads K_PLAN/K_CR,
  # so stale keys would silently lose every root whose only trace is a thread.
  local s="$1" i=0
  EVR=()
  EVR_N=0
  while [ "$i" -lt "$CAND_N" ]; do
    if slug_has_evidence "${CAND[$i]}" "$s"; then
      EVR[EVR_N]="${CAND[$i]}"
      EVR_N=$((EVR_N + 1))
    fi
    i=$((i + 1))
  done
  return 0
}

root_has_branch() {
  # root_has_branch <root> <branch> — does the repository of <root> carry the
  # branch? The question is asked per ROOT, never once against the default one:
  # a branch that only exists in another candidate's repository has an owner,
  # and naming a non-owner would be an invented fact.
  local g
  [ "$HAVE_GIT" = "1" ] || return 1
  g="$(git_main_from "$1")"
  [ -n "$g" ] || return 1
  git -C "$g" show-ref --verify --quiet "refs/heads/$2" || return 1
  return 0
}

json_str() {
  # json_str <file> <key> — one string field of a record plan-approve.sh wrote
  # (one field per line, no jq needed), read with its very same sed.
  [ -f "$1" ] || return 0
  LC_ALL=C sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null || true
}

is_sha40() {
  case "${1:-}" in
    '' | *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || return 1
  return 0
}

short_sha() {
  local s="${1:-}"
  [ -n "$s" ] || return 0
  printf '%s' "${s:0:7}"
}

thread_facts() {
  # thread_facts <state-dir> <key> — TF_HAS, TF_ROUNDS, TF_VERDICTS, TF_LAST,
  # plus the three facts the multi-root resolver needs: TF_ID (the thread id,
  # an IDENTITY fact — one run cannot have two of them for one key), TF_MAX (the
  # highest round the state proves, always a number) and TF_TOP (the verdict of
  # THAT round, empty when its reply is absent — the last verdict of an earlier
  # round is not this round's outcome).
  # The turn counter is sanitized exactly like codex-start.sh's ('08' would
  # abort as octal, garbage must degrade to `?` and never to an error), and the
  # verdict of each round comes from the real hb_verdict over that round's
  # reply file: an absent reply is `—`, never a guess.
  local dir="$1" key="$2" turn n max i v f
  TF_HAS=0
  TF_ROUNDS="?"
  TF_VERDICTS=""
  TF_LAST=""
  TF_ID=""
  TF_MAX=0
  TF_TOP=""
  if [ -f "$dir/$key.thread" ]; then
    TF_HAS=1
    # One line, whitespace stripped: this id is compared BETWEEN roots, and a
    # trailing newline must never make one id look like two.
    TF_ID="$(head -n 1 "$dir/$key.thread" 2>/dev/null | LC_ALL=C tr -d '[:space:]')"
  fi
  turn="$(cat "$dir/$key.turn" 2>/dev/null)"
  case "$turn" in
    '' | *[!0-9]*)
      TF_ROUNDS="?"
      n=0
      ;;
    *)
      n=$((10#$turn))
      TF_ROUNDS="$n"
      ;;
  esac
  max=0
  for f in "$dir/$key".t*.reply.txt; do
    [ -f "$f" ] || continue
    i="${f##*/}"
    i="${i#"$key".t}"
    i="${i%%.*}"
    case "$i" in '' | *[!0-9]*) continue ;; esac
    [ "$((10#$i))" -gt "$max" ] && max=$((10#$i))
  done
  [ "$n" -gt "$max" ] && max="$n"
  TF_MAX="$max"
  i=1
  while [ "$i" -le "$max" ]; do
    v="$(hb_verdict "$dir/$key.t$i.reply.txt")"
    [ -n "$v" ] || v="—"
    if [ -n "$TF_VERDICTS" ]; then TF_VERDICTS="$TF_VERDICTS, $v"; else TF_VERDICTS="$v"; fi
    [ "$v" != "—" ] && TF_LAST="$v"
    if [ "$i" -eq "$max" ] && [ "$v" != "—" ]; then TF_TOP="$v"; fi
    i=$((i + 1))
  done
  return 0
}

thread_line() {
  # thread_line <has> <rounds> <verdicts>
  if [ "$1" != "1" ]; then
    printf 'sin hilo'
    return 0
  fi
  local unit="rondas"
  [ "$2" = "1" ] && unit="ronda"
  if [ -n "$3" ]; then
    printf '%s %s · veredictos: %s' "$2" "$unit" "$3"
  else
    printf '%s %s · veredictos: —' "$2" "$unit"
  fi
  return 0
}

sum_ledgers() {
  # sum_ledgers <state-dir> <key> — S_IN, S_OUT, S_BAD from the per-turn usage
  # ledgers the wrappers write unconditionally (even for a failed turn), which
  # is why they and not the log's `tokens:` lines are the source here. A file
  # that is not JSON at all is skipped and counted: an unreadable ledger must
  # never silently vanish into a total that looks complete.
  local dir="$1" key="$2" f line
  S_IN=0
  S_OUT=0
  S_BAD=0
  OKF=()
  [ "$HAVE_JQ" = "1" ] || return 0
  for f in "$dir/$key".t*.usage.json; do
    [ -f "$f" ] || continue
    if jq -e . "$f" >/dev/null 2>&1; then
      OKF[${#OKF[@]}]="$f"
    else
      S_BAD=$((S_BAD + 1))
    fi
  done
  [ "${#OKF[@]}" -gt 0 ] || return 0
  line="$(jq -rs '[ .[] | objects ]
    | reduce .[] as $u ({ "in": 0, "out": 0 };
        .["in"] += (if ($u.input_tokens | type) == "number" then $u.input_tokens else 0 end)
        | .["out"] += (if ($u.output_tokens | type) == "number" then $u.output_tokens else 0 end))
    | "\(.["in"]) \(.["out"])"' "${OKF[@]}" 2>/dev/null)"
  [ -n "$line" ] || return 0
  S_IN="${line%% *}"
  S_OUT="${line##* }"
  # Same numeric distrust as usage_number: only a plain integer is arithmetic.
  case "$S_IN" in '' | *[!0-9]*) S_IN=0 ;; esac
  case "$S_OUT" in '' | *[!0-9]*) S_OUT=0 ;; esac
  return 0
}

tok_phase() {
  # tok_phase <label> <in> <out> <bad>
  printf '%s in %s · out %s' "$1" "$2" "$3"
  if [ "$4" -gt 0 ]; then
    if [ "$4" = "1" ]; then printf ' (+1 ilegible)'; else printf ' (+%s ilegibles)' "$4"; fi
  fi
  return 0
}

gate_block() {
  # gate_block <log> — the LAST logical `gate — ` block, normalized to one line.
  # The real logs wrap it over several physical lines, so the block is read from
  # its opening line to the first blank line or heading: a single-line grep
  # would amputate exactly the summary this field exists to show.
  local f="$1" line stripped cur="" cap=0 last=""
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    if [ "$cap" = "1" ]; then
      case "$stripped" in
        '' | '#'*)
          last="$cur"
          cur=""
          cap=0
          ;;
        *)
          cur="$cur $stripped"
          continue
          ;;
      esac
    fi
    case "$stripped" in
      'gate — '*)
        cap=1
        cur="$stripped"
        ;;
    esac
  done <"$f"
  [ "$cap" = "1" ] && last="$cur"
  [ -n "$last" ] || return 0
  printf '%s' "$last" | LC_ALL=C tr -s ' '
  return 0
}

term_record() {
  # term_record <log> — the sha of the LAST terminal record of the run, the
  # `final — commit: <sha>` line tandem:review writes right after the approval
  # commit. It is the only durable, machine-parseable proof that the run closed:
  # the branch, which a legitimate merge deletes, is not evidence forever.
  #
  # The line must be EXACT — the literal prefix, one full 40-hex sha, nothing
  # after it. A prefix plus prose ("… (merged)"), or an abbreviated sha, is not
  # a record: this line is the single fact that can turn into "run completo —
  # merge/PR", so anything less than exact is no record at all.
  [ -f "$1" ] || return 0
  LC_ALL=C sed -n 's/^final — commit: \([0-9a-fA-F]\{40\}\)$/\1/p' "$1" 2>/dev/null | tail -n 1
  return 0
}

analyze() {
  # analyze <slug> <root> — every fact of one run, from disk only, read from ONE
  # state root. The root is chosen by the resolver and never here: a function
  # that picked its own root could not be asked the same question about a second
  # one, which is exactly what reconciling two roots requires.
  SLUG="$1"
  compute_keys "$SLUG"
  ST_BASE="$2"
  ST="$ST_BASE/.tandem"
  LOG_FILE="$ST/log/$SLUG.md"
  PA_FILE="$ST/state/plan-approve/$SLUG.json"
  PA_PENDING="$PA_FILE.pending"
  OP_FILE="$ST/state/implement-claude/$SLUG.json"
  REVIEW_DIR="$ST/state/review"
  IMPL_DIR="$ST/state/implement"
  PLAN_REL="docs/plans/$SLUG.plan.md"
  BRANCH="tandem/$SLUG"

  # The repository is the one that owns the state, never "whichever repo the
  # shell happens to stand in".
  GIT_ROOT=""
  if [ "$HAVE_GIT" = "1" ]; then
    GIT_ROOT="$(git_main_from "$ST_BASE")"
    [ -n "$GIT_ROOT" ] || GIT_ROOT="$GIT_ROOT_DEFAULT"
  fi

  # --- plan working copy ---
  PLAN_PATH=""
  local i=0
  if [ -f "$ST_BASE/$PLAN_REL" ]; then
    PLAN_PATH="$ST_BASE/$PLAN_REL"
  else
    while [ "$i" -lt "$CAND_N" ]; do
      if [ -f "${CAND[$i]}/$PLAN_REL" ]; then
        PLAN_PATH="${CAND[$i]}/$PLAN_REL"
        break
      fi
      i=$((i + 1))
    done
  fi

  # --- the approval record: PRESENT is not VALID, VALID is not PROVEN ----
  # plan-approve.sh publishes four fields and re-verifies every one of them
  # against git before it trusts them; a status that accepted the mere presence
  # of the file would report "plan aprobado" — and recommend implementing — off
  # a truncated write or a record copied from another run, which is precisely
  # the human gate this flow refuses to skip.
  PA_PRESENT=0
  PA_VALID=0
  PA_UNVERIFIED=0
  PA_WHY=""
  PLAN_COMMIT=""
  PA_MODE=""
  if [ -f "$PA_FILE" ]; then
    PA_PRESENT=1
    local pa_branch pa_source pa_parent pa_files
    PLAN_COMMIT="$(json_str "$PA_FILE" plan_commit)"
    PA_MODE="$(json_str "$PA_FILE" mode)"
    pa_branch="$(json_str "$PA_FILE" branch)"
    pa_source="$(json_str "$PA_FILE" source_head)"
    PA_VALID=1
    [ "$pa_branch" = "$BRANCH" ] || PA_VALID=0
    case "$PA_MODE" in in-place | worktree) : ;; *) PA_VALID=0 ;; esac
    is_sha40 "$PLAN_COMMIT" || PA_VALID=0
    is_sha40 "$pa_source" || PA_VALID=0
    if [ "$PA_VALID" = "1" ]; then
      if [ "$HAVE_GIT" != "1" ]; then
        # Structure is ALL there is without a repository: the four facts below
        # cannot be produced, so the record stays unverified, never certified.
        # A structurally plausible record is exactly what a corrupt one looks
        # like from here, and "plan aprobado" would send the user across the
        # human gate on the strength of a file nobody could check.
        PA_VALID=0
        PA_UNVERIFIED=1
        PA_WHY="sin git"
      elif [ -z "$GIT_ROOT" ]; then
        PA_VALID=0
        PA_UNVERIFIED=1
        PA_WHY="fuera de un repositorio git"
      else
        # Coherence with the repository, the same four facts plan-approve.sh
        # re-checks before it resumes: the plan commit exists, it sits on the
        # recorded source_head, it touches NOTHING but the recorded plan, and it
        # carries that plan. The last two are what separates an approval commit
        # from any other commit that happens to share its parent — and a merge
        # commit, whose diff-tree is empty, is correctly none of them.
        if ! git -C "$GIT_ROOT" rev-parse --verify -q "$PLAN_COMMIT^{commit}" >/dev/null 2>&1; then
          PA_VALID=0
        else
          pa_parent="$(git -C "$GIT_ROOT" rev-parse --verify -q "$PLAN_COMMIT^" 2>/dev/null)"
          [ "$pa_parent" = "$pa_source" ] || PA_VALID=0
          pa_files="$(git -C "$GIT_ROOT" diff-tree --no-commit-id --name-only -r "$PLAN_COMMIT" 2>/dev/null)"
          [ "$pa_files" = "$PLAN_REL" ] || PA_VALID=0
          git -C "$GIT_ROOT" rev-parse --verify -q "$PLAN_COMMIT:$PLAN_REL" >/dev/null 2>&1 || PA_VALID=0
        fi
      fi
    fi
    # An INVALID record keeps no sha — there is nothing to point at. An
    # unverified one does: the report has to be able to name the commit whose
    # proof could not be produced.
    if [ "$PA_VALID" != "1" ] && [ "$PA_UNVERIFIED" != "1" ]; then PLAN_COMMIT=""; fi
  fi

  PLAN_VAL="$PLAN_REL"
  [ -n "$PLAN_PATH" ] || PLAN_VAL="$PLAN_REL (sin copia de trabajo)"
  if [ "$PA_PRESENT" = "1" ]; then
    if [ "$PA_VALID" = "1" ]; then
      PLAN_VAL="$PLAN_VAL · aprobado: commit $(short_sha "$PLAN_COMMIT") · modo $PA_MODE"
    elif [ "$PA_UNVERIFIED" = "1" ]; then
      # "aprobado: commit" belongs to the PROVEN state alone.
      PLAN_VAL="$PLAN_VAL · aprobación registrada (commit $(short_sha "$PLAN_COMMIT")) · SIN VERIFICAR ($PA_WHY)"
    else
      PLAN_VAL="$PLAN_VAL · registro de aprobación corrupto (desconocido)"
    fi
  fi
  [ -f "$PA_PENDING" ] && PLAN_VAL="$PLAN_VAL · aprobación interrumpida (pending)"

  # --- branch ---
  # BR_READY is the branch's own question, deliberately separate from the
  # record's validity: a sound approval record says nothing about the branch
  # that has to carry the work. A `tandem/<slug>` reset back to source_head
  # counts 0 commits over the plan exactly like an untouched one, so only
  # CONTAINMENT of the plan commit tells them apart — and a branch deleted mid
  # run cannot be implemented on nor reviewed either.
  BR_EXISTS=0
  BR_TIP=""
  BR_AHEAD=""
  BR_READY=0
  BR_WHY=""
  PLAN_COMMIT_OK=0
  WT_PATH=""
  if [ "$HAVE_GIT" != "1" ]; then
    RAMA_VAL="desconocido (sin git)"
    BR_WHY="sin git no se puede comprobar que la rama $BRANCH lleve el commit de aprobación"
  elif [ -z "$GIT_ROOT" ]; then
    RAMA_VAL="desconocido (fuera de un repositorio git)"
    BR_WHY="fuera de un repositorio git no se puede comprobar la rama $BRANCH"
  else
    if [ -n "$PLAN_COMMIT" ] \
      && git -C "$GIT_ROOT" rev-parse --verify -q "$PLAN_COMMIT^{commit}" >/dev/null 2>&1; then
      PLAN_COMMIT_OK=1
    fi
    if git -C "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      BR_EXISTS=1
      BR_TIP="$(git -C "$GIT_ROOT" rev-parse "refs/heads/$BRANCH" 2>/dev/null)"
      RAMA_VAL="$BRANCH · tip $(short_sha "$BR_TIP")"
      if [ "$PLAN_COMMIT_OK" = "1" ]; then
        BR_AHEAD="$(git -C "$GIT_ROOT" rev-list --count "$PLAN_COMMIT..refs/heads/$BRANCH" 2>/dev/null)"
        case "$BR_AHEAD" in '' | *[!0-9]*) BR_AHEAD="" ;; esac
        if git -C "$GIT_ROOT" merge-base --is-ancestor "$PLAN_COMMIT" "refs/heads/$BRANCH" 2>/dev/null; then
          BR_READY=1
        else
          BR_WHY="la rama $BRANCH no contiene el commit de aprobación"
        fi
      else
        BR_WHY="no hay commit de aprobación verificado con el que comprobar la rama $BRANCH"
      fi
      if [ -n "$BR_AHEAD" ]; then
        RAMA_VAL="$RAMA_VAL · $BR_AHEAD commit(s) sobre el plan"
      else
        RAMA_VAL="$RAMA_VAL · commits sobre el plan: desconocido"
      fi
      # The worktree REGISTRY is the only source of truth about where a branch
      # is checked out. Its output is captured through a pipe and split here:
      # records may carry spaces, so they are never word-split.
      local wt_out wt_rest wt_line wt_cur=""
      wt_out="$(git -C "$GIT_ROOT" worktree list --porcelain 2>/dev/null)"
      wt_rest="$wt_out"
      while [ -n "$wt_rest" ]; do
        wt_line="${wt_rest%%"$NL"*}"
        if [ "$wt_line" = "$wt_rest" ]; then wt_rest=""; else wt_rest="${wt_rest#*"$NL"}"; fi
        case "$wt_line" in
          'worktree '*) wt_cur="${wt_line#worktree }" ;;
          "branch refs/heads/$BRANCH") [ -n "$WT_PATH" ] || WT_PATH="$wt_cur" ;;
        esac
      done
      [ -n "$WT_PATH" ] && RAMA_VAL="$RAMA_VAL · worktree $WT_PATH"
    else
      RAMA_VAL="sin rama $BRANCH"
      BR_WHY="la rama $BRANCH no existe"
    fi
  fi

  # --- threads per phase ---
  thread_facts "$REVIEW_DIR" "$K_PLAN"
  PR_HAS="$TF_HAS"
  PR_LAST="$TF_LAST"
  PR_ID="$TF_ID"
  PR_MAX="$TF_MAX"
  PR_TOP="$TF_TOP"
  PR_VAL="$(thread_line "$TF_HAS" "$TF_ROUNDS" "$TF_VERDICTS")"
  thread_facts "$REVIEW_DIR" "$K_CR"
  CR_HAS="$TF_HAS"
  CR_LAST="$TF_LAST"
  CR_ID="$TF_ID"
  CR_MAX="$TF_MAX"
  CR_TOP="$TF_TOP"
  CR_VAL="$(thread_line "$TF_HAS" "$TF_ROUNDS" "$TF_VERDICTS")"
  thread_facts "$IMPL_DIR" "$K_PLAN"
  IM_HAS="$TF_HAS"
  IM_ROUNDS="$TF_ROUNDS"
  IM_LAST="$TF_LAST"
  IM_ID="$TF_ID"
  IM_MAX="$TF_MAX"
  IM_TOP="$TF_TOP"

  # --- the implementation attempt ---
  # The Opus attempt state gets the same typed distrust as the status line's: a
  # status that is not a string, or a sentinel that is neither string nor null,
  # is corruption and degrades this field alone — never an exit.
  OP_HAS=0
  OP_OK=0
  OP_STATUS=""
  OP_SENT=""
  OP_CONT=""
  OP_ID_VALID=0
  OP_ID_PRESENT=0
  OP_PLAN_HASH=""
  OP_BRANCH=""
  OP_AGENT_TYPE=""
  OP_PROG_OK=0
  [ -f "$OP_FILE" ] && OP_HAS=1
  if [ "$OP_HAS" = "1" ] && [ "$HAVE_JQ" = "1" ]; then
    local opline oprest opid
    opline="$(jq -r --arg us "$US" '
      if type == "object"
         and ((.status | type) == "string")
         and (((.last_sentinel | type) == "string") or ((.last_sentinel | type) == "null"))
      then ([ .status, (.last_sentinel // ""),
              (if (.continuation_rounds | type) == "number"
               then (.continuation_rounds | tostring) else "" end) ] | join($us))
      else empty end' "$OP_FILE" 2>/dev/null)"
    if [ -n "$opline" ]; then
      # Split on the unit separator in place: a heredoc-fed `read` would need a
      # temp file, and an empty middle field must not shift the last one.
      OP_STATUS="${opline%%"$US"*}"
      oprest="${opline#*"$US"}"
      OP_SENT="${oprest%%"$US"*}"
      OP_CONT="${oprest#*"$US"}"
      OP_OK=1
    fi
    # PRESENCE is a separate question from validity, asked with has(): a
    # lineage key that exists with a null/object value, or only HALF a lineage,
    # is not the legacy absent shape — it is corrupt state. Legacy treatment is
    # reserved for a state with ALL lineage keys absent.
    if jq -e '(type == "object") and (has("plan_hash") or has("branch") or has("agent_type"))' \
      "$OP_FILE" >/dev/null 2>&1; then
      OP_ID_PRESENT=1
    fi
    # The attempt's IMMUTABLE lineage — `plan_hash` + `branch` are the identity
    # of the attempt in the implement contract, `agent_type` its closed enum —
    # validated here exactly like that contract validates it before dispatching
    # anything. `agent.id` is deliberately NOT part of it: a legitimate recovery
    # launches a fresh agent and records the new identity without resetting the
    # attempt, so comparing it between roots would invent a split brain.
    opid="$(jq -r --arg us "$US" '
      if type == "object"
         and ((.plan_hash | type) == "string")
         and ((.branch | type) == "string")
      then ([ .plan_hash, .branch,
              (if (has("agent_type") | not) then "tandem:implementer"
               elif (.agent_type | type) == "string" then .agent_type
               else "" end) ] | join($us))
      else empty end' "$OP_FILE" 2>/dev/null)"
    if [ -n "$opid" ]; then
      OP_PLAN_HASH="${opid%%"$US"*}"
      oprest="${opid#*"$US"}"
      OP_BRANCH="${oprest%%"$US"*}"
      OP_AGENT_TYPE="${oprest#*"$US"}"
      OP_ID_VALID=1
      is_sha40 "$OP_PLAN_HASH" || OP_ID_VALID=0
      [ "$OP_BRANCH" = "$BRANCH" ] || OP_ID_VALID=0
      case "$OP_AGENT_TYPE" in
        # The absent field is the documented legacy shape and means the default
        # type; anything outside the enum is a lineage this tool will not read.
        tandem:implementer | tandem:implementer-critical) : ;;
        *) OP_ID_VALID=0 ;;
      esac
      if [ "$OP_ID_VALID" = "1" ] && [ "$HAVE_GIT" = "1" ] && [ -n "$GIT_ROOT" ]; then
        # The recorded hash is the COMMITTED plan blob: where there is a
        # repository to ask, shape alone is not proof.
        git -C "$GIT_ROOT" rev-parse --verify -q "$OP_PLAN_HASH^{blob}" >/dev/null 2>&1 \
          || OP_ID_VALID=0
      fi
    fi
    # An invalid lineage carries NO comparable value: it degrades like any other
    # corrupt state and never enters the identity probe.
    if [ "$OP_ID_VALID" != "1" ]; then
      OP_PLAN_HASH=""
      OP_BRANCH=""
      OP_AGENT_TYPE=""
    fi
  fi
  # The progress TUPLE is a separate question from the lineage: a snapshot can
  # be perfectly identified and still carry garbage where the round counter
  # belongs. Only a VALIDATED tuple is ever ordered against another one —
  # nothing here may reach arithmetic (`[ 0.5 -gt 0 ]` prints a diagnostic on
  # stderr, which an exit-0 report promises never to do) or force a split brain.
  if [ "$OP_OK" = "1" ]; then
    OP_PROG_OK=1
    case "$OP_CONT" in '' | *[!0-9]*) OP_PROG_OK=0 ;; esac
    case "$OP_STATUS" in running | terminal) : ;; *) OP_PROG_OK=0 ;; esac
    case "$OP_SENT" in
      '' | IMPLEMENTATION_COMPLETE | IMPLEMENTATION_PARTIAL) : ;;
      *) OP_PROG_OK=0 ;;
    esac
  fi
  if [ "$OP_HAS" = "1" ]; then
    if [ "$HAVE_JQ" != "1" ]; then
      IMPL_VAL="opus · desconocido (sin jq)"
    elif [ "$OP_OK" != "1" ] || { [ "$OP_ID_PRESENT" = "1" ] && [ "$OP_ID_VALID" != "1" ]; }; then
      # A lineage that is PRESENT but does not validate (wrong branch, a hash
      # that is not the committed plan blob, an unknown agent type) is corrupt
      # state: its status and sentinel belong to an attempt this tool cannot
      # identify, and they must not drive a next step. ABSENT lineage fields
      # are different — that is the legacy shape M11's contract displays as the
      # typed status it carries.
      IMPL_VAL="opus · desconocido (estado corrupto)"
    else
      IMPL_VAL="opus · $OP_STATUS · ${OP_SENT:-—} · continuaciones: ${OP_CONT:-?}"
      [ "$OP_STATUS" = "running" ] \
        && IMPL_VAL="$IMPL_VAL (running: el sentinel describe un turno ANTERIOR)"
    fi
  elif [ "$IM_HAS" = "1" ]; then
    IMPL_VAL="sol · t$IM_ROUNDS · ${IM_LAST:-—}"
  else
    IMPL_VAL="sin intento"
  fi
  IMPL_SENT=""
  if [ "$OP_OK" = "1" ] && ! { [ "$OP_ID_PRESENT" = "1" ] && [ "$OP_ID_VALID" != "1" ]; }; then
    IMPL_SENT="$OP_SENT"
  elif [ "$IM_HAS" = "1" ]; then
    IMPL_SENT="$IM_LAST"
  fi

  # --- testing gate + log ---
  GATE_VAL="$(gate_block "$LOG_FILE")"
  GATE_HAS=0
  if [ -n "$GATE_VAL" ]; then GATE_HAS=1; else GATE_VAL="sin registro"; fi
  if [ -f "$LOG_FILE" ]; then
    LOG_VAL="$LOG_FILE · $(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ') líneas"
  else
    LOG_VAL="ausente"
  fi

  # --- tokens ---
  if [ "$HAVE_JQ" != "1" ]; then
    TOKENS_VAL="desconocido (sin jq)"
  else
    local tin=0 tout=0 part
    sum_ledgers "$REVIEW_DIR" "$K_PLAN"
    part="$(tok_phase plan "$S_IN" "$S_OUT" "$S_BAD")"
    tin=$((tin + S_IN))
    tout=$((tout + S_OUT))
    sum_ledgers "$REVIEW_DIR" "$K_CR"
    part="$part | $(tok_phase cr "$S_IN" "$S_OUT" "$S_BAD")"
    tin=$((tin + S_IN))
    tout=$((tout + S_OUT))
    if [ "$OP_HAS" = "1" ] && [ "$IM_HAS" != "1" ]; then
      # No ledger exists under the opus transport — the same fact the log
      # records, not a zero pretending to be an accounting.
      part="$part | implement n/a (transporte opus)"
    else
      sum_ledgers "$IMPL_DIR" "$K_PLAN"
      part="$part | $(tok_phase implement "$S_IN" "$S_OUT" "$S_BAD")"
      tin=$((tin + S_IN))
      tout=$((tout + S_OUT))
    fi
    TOKENS_VAL="$part | total in $tin · out $tout"
  fi

  # --- the terminal record, validated against git ---
  # Three steps, never one: the sha must BE a commit, it must be a STRICT
  # descendant of the plan commit — equality would certify the approval commit
  # itself, a run with no implementation at all, and a valid but foreign sha
  # (source_head, another run's commit) proves nothing either — and while the
  # tandem branch still exists its tip must be EXACTLY the recorded sha: a
  # descendant tip means commits landed after the final gate, and blessing that
  # as "run completo — merge/PR" would merge unreviewed code.
  TERM_SHA="$(term_record "$LOG_FILE")"
  TERM_FULL=""
  TERM_STATE="none"
  if [ -n "$TERM_SHA" ]; then
    TERM_STATE="unverified"
    if [ "$HAVE_GIT" = "1" ] && [ -n "$GIT_ROOT" ] && [ "$PLAN_COMMIT_OK" = "1" ]; then
      TERM_FULL="$(git -C "$GIT_ROOT" rev-parse --verify -q "$TERM_SHA^{commit}" 2>/dev/null)"
      if [ -n "$TERM_FULL" ] && [ "$TERM_FULL" != "$PLAN_COMMIT" ] \
        && git -C "$GIT_ROOT" merge-base --is-ancestor "$PLAN_COMMIT" "$TERM_FULL" 2>/dev/null; then
        if [ "$BR_EXISTS" = "1" ] && [ "$BR_TIP" != "$TERM_FULL" ]; then
          TERM_STATE="advanced"
        else
          TERM_STATE="verified"
        fi
      fi
    fi
  fi

  # --- the identity of the run, as THIS root tells it ---
  # The facts an honest run cannot hold two different values of, exported ONLY
  # when this analyze PROVED them: a plan commit whose record did not validate,
  # or a terminal sha git did not confirm, keeps its existing degradation and
  # stays NON-comparable — corruption must never manufacture a split brain.
  # Deliberately absent: `agent.id`, `task_id`, `status` and the sentinel, none
  # of which is immutable over the life of one attempt.
  ID_PLAN_COMMIT=""
  [ "$PA_VALID" = "1" ] && ID_PLAN_COMMIT="$PLAN_COMMIT"
  ID_TERM=""
  case "$TERM_STATE" in
    verified | advanced) ID_TERM="$TERM_FULL" ;;
  esac

  # --- the phase ladder: the most advanced evidence wins ---
  # FASE_RANK is assigned in the SAME branch as FASE, never through a parallel
  # string→number map: the order two roots are reconciled by has to be the very
  # ladder printed in the report, and a second source of truth could drift from
  # it. Twelve rungs, twelve UNIQUE ranks, 11 down to 0.
  if [ "$TERM_STATE" = "verified" ]; then
    FASE="commit final"
    FASE_RANK=11
  elif [ "$TERM_STATE" = "advanced" ]; then
    FASE="contradictorio — rama avanzó tras registro final"
    FASE_RANK=10
  elif [ "$TERM_STATE" = "unverified" ]; then
    FASE="commit final (no verificado)"
    FASE_RANK=9
  elif [ "$BR_EXISTS" = "1" ] && [ -n "$BR_AHEAD" ] && [ "$BR_AHEAD" -gt 0 ]; then
    # A commit by the implementer is a hard safety failure for this flow, so an
    # unregistered one is never blessed as a finished run.
    FASE="contradictorio — commits sin registro final"
    FASE_RANK=8
  elif [ "$CR_HAS" = "1" ]; then
    FASE="code review"
    FASE_RANK=7
  elif [ "$GATE_HAS" = "1" ]; then
    FASE="gate de testing"
    FASE_RANK=6
  elif [ "$OP_HAS" = "1" ] || [ "$IM_HAS" = "1" ]; then
    FASE="implementación"
    FASE_RANK=5
  elif [ "$PA_VALID" = "1" ]; then
    FASE="plan aprobado"
    FASE_RANK=4
  elif [ "$PA_UNVERIFIED" = "1" ]; then
    # One rung below "plan aprobado" and deliberately WITHOUT that substring: a
    # record whose git invariants could not be checked is not an approval this
    # tool is willing to certify. Any higher evidence still wins the ladder.
    FASE="aprobación no verificada"
    FASE_RANK=3
  elif [ "$PR_HAS" = "1" ]; then
    FASE="plan en revisión"
    FASE_RANK=2
  elif [ -n "$PLAN_PATH" ]; then
    FASE="plan (borrador)"
    FASE_RANK=1
  else
    FASE="desconocido"
    FASE_RANK=0
  fi

  # --- next: derived from the phase, deterministic and testable ---
  # The manual verification an unverified approval demands, named once: it is
  # both that phase's own next step and the override applied below. It names the
  # two invariants that could not be checked, and never a slash command.
  local pa_manual
  pa_manual="ATENCIÓN: la aprobación de $SLUG no está verificada ($PA_WHY) — comprobar a mano que el commit ${PLAN_COMMIT:-registrado} toca SOLO $PLAN_REL y contiene ese fichero (git show --stat) antes de seguir"
  case "$FASE" in
    "commit final")
      NEXT="run completo — merge/PR manual"
      ;;
    "commit final (no verificado)")
      NEXT="verificar a mano el commit final ($TERM_SHA) con git log antes de cualquier merge/PR"
      ;;
    "contradictorio — rama avanzó tras registro final")
      NEXT="ATENCIÓN: la rama avanzó tras el registro final — revisar a mano los commits posteriores antes de merge/PR"
      ;;
    "contradictorio — commits sin registro final")
      NEXT="ATENCIÓN: commits no registrados — verificar el safety check de implement antes de nada"
      ;;
    "code review")
      if [ "$CR_LAST" = "APPROVED" ]; then
        NEXT="/tandem:review $SLUG (Step 4: gate final y commit)"
      else
        NEXT="/tandem:review $SLUG (retomar)"
      fi
      ;;
    "gate de testing")
      NEXT="/tandem:review $SLUG"
      ;;
    "implementación")
      if [ "$OP_OK" = "1" ] && [ "$OP_STATUS" = "running" ]; then
        NEXT="verificar el intento vivo antes de nada (tandem:implement paso 1, guard de liveness)"
      elif [ "$IMPL_SENT" = "IMPLEMENTATION_COMPLETE" ]; then
        NEXT="gate de testing (tandem:implement paso 4)"
      else
        NEXT="/tandem:implement $SLUG (continuación)"
      fi
      ;;
    "plan aprobado")
      NEXT="/tandem:implement $SLUG"
      ;;
    "aprobación no verificada")
      NEXT="$pa_manual"
      ;;
    "plan en revisión")
      if [ "$PR_LAST" = "APPROVED" ]; then
        NEXT="/tandem:plan $SLUG (Resolution: aprobar con plan-approve.sh)"
      else
        NEXT="/tandem:plan $SLUG (retomar el hilo)"
      fi
      ;;
    "plan (borrador)")
      NEXT="/tandem:plan $SLUG (arrancar la revisión adversarial)"
      ;;
    *)
      NEXT="desconocido"
      ;;
  esac
  # A branch that cannot carry the run is not a step forward either: while its
  # readiness is unproven, no path may recommend implementing on it or reviewing
  # it. The TERMINAL phases are deliberately untouched — a branch a legitimate
  # merge deleted is proven by the terminal record, which wins the ladder above
  # and whose next names no phase to continue.
  if [ "$BR_READY" != "1" ]; then
    case "$NEXT" in
      */tandem:implement* | */tandem:review*)
        NEXT="ATENCIÓN: $BR_WHY — resolver la rama a mano antes de continuar el run"
        ;;
    esac
  fi
  # An unverified approval overrides EVERY next: the phase is descriptive (what
  # evidence exists), the next is prescriptive (what to do), and only the second
  # can push anyone across a gate whose proof was never produced.
  if [ "$PA_UNVERIFIED" = "1" ]; then
    NEXT="$pa_manual"
  fi
  # A corrupt approval record must never read as a step forward: whatever the
  # ladder says, the record itself has to be resolved by hand first. A record
  # nobody could VERIFY is not the same thing as one nobody can READ, so the
  # unverified state has its own message above and never this one.
  if [ "$PA_PRESENT" = "1" ] && [ "$PA_VALID" != "1" ] && [ "$PA_UNVERIFIED" != "1" ]; then
    NEXT="ATENCIÓN: el registro de aprobación de $SLUG no es legible — resolverlo a mano ($NEXT)"
  fi

  # Evidence at all? A slug nobody ever heard of is an honest stop, not a
  # report full of `desconocido` that hides a typo.
  HAS_ANY=0
  [ -f "$LOG_FILE" ] && HAS_ANY=1
  [ "$PA_PRESENT" = "1" ] && HAS_ANY=1
  [ -f "$PA_PENDING" ] && HAS_ANY=1
  [ "$OP_HAS" = "1" ] && HAS_ANY=1
  [ "$PR_HAS" = "1" ] && HAS_ANY=1
  [ "$CR_HAS" = "1" ] && HAS_ANY=1
  [ "$IM_HAS" = "1" ] && HAS_ANY=1
  [ "$BR_EXISTS" = "1" ] && HAS_ANY=1
  [ -n "$PLAN_PATH" ] && HAS_ANY=1
  return 0
}

# --- reconciling the roots ---------------------------------------------------
# One slug leaving evidence in more than one root is DESIGNED behaviour, not an
# accident: a run executed in a linked worktree keeps its thread state where it
# ran while the rest lives in the main checkout. Taking the first root that
# carries anything lets a stale copy mask the authoritative one — wrong phase,
# wrong `next:`, which is the whole bug M17 exists to kill. So every root with
# evidence is analyzed, the consistent ones are reconciled deterministically,
# and roots whose IDENTITY facts disagree stop the tool instead of being
# silently narrated from one of them.
#
# One snapshot array per fact, indexed by evidence root: bash 3.2 has no
# associative arrays, and the comparison must run over FROZEN snapshots — never
# over "whatever the last analyze left behind".
R_FASE=()
R_RANK=()
R_TH_PR=()
R_TH_IM=()
R_TH_CR=()
R_PR_MAX=()
R_PR_TOP=()
R_IM_MAX=()
R_IM_TOP=()
R_CR_MAX=()
R_CR_TOP=()
R_PC=()
R_TERM=()
R_OP_HAS=()
R_OP_IDV=()
R_OP_PH=()
R_OP_BR=()
R_OP_AT=()
R_OP_PV=()
R_OP_CONT=()
R_OP_ST=()
R_OP_SENT=()

snap_root() {
  # snap_root <i> — freeze the analyzed root's facts into slot <i>.
  local i="$1"
  R_FASE[i]="$FASE"
  R_RANK[i]="$FASE_RANK"
  R_TH_PR[i]="$PR_ID"
  R_TH_IM[i]="$IM_ID"
  R_TH_CR[i]="$CR_ID"
  R_PR_MAX[i]="$PR_MAX"
  R_PR_TOP[i]="$PR_TOP"
  R_IM_MAX[i]="$IM_MAX"
  R_IM_TOP[i]="$IM_TOP"
  R_CR_MAX[i]="$CR_MAX"
  R_CR_TOP[i]="$CR_TOP"
  R_PC[i]="$ID_PLAN_COMMIT"
  R_TERM[i]="$ID_TERM"
  R_OP_HAS[i]="$OP_HAS"
  R_OP_IDV[i]="$OP_ID_VALID"
  R_OP_PH[i]="$OP_PLAN_HASH"
  R_OP_BR[i]="$OP_BRANCH"
  R_OP_AT[i]="$OP_AGENT_TYPE"
  R_OP_PV[i]="$OP_PROG_OK"
  R_OP_CONT[i]="$OP_CONT"
  R_OP_ST[i]="$OP_STATUS"
  R_OP_SENT[i]="$OP_SENT"
  return 0
}

id_fact() {
  # id_fact <fact> <root-index> — the VALIDATED value of one identity fact for
  # one analyzed root, or nothing when that root does not carry it. Empty is
  # silence, never disagreement.
  case "$1" in
    1) printf '%s' "${R_TH_PR[$2]}" ;;
    2) printf '%s' "${R_TH_IM[$2]}" ;;
    3) printf '%s' "${R_TH_CR[$2]}" ;;
    4) printf '%s' "${R_PC[$2]}" ;;
    5) printf '%s' "${R_TERM[$2]}" ;;
    6) printf '%s' "${R_OP_PH[$2]}" ;;
    7) printf '%s' "${R_OP_BR[$2]}" ;;
    8) printf '%s' "${R_OP_AT[$2]}" ;;
  esac
  return 0
}

id_label() {
  # id_label <fact> — how the report names the fact that cannot be reconciled.
  # Fact 7 (the attempt's branch) is compared for completeness and can only fire
  # if the lineage validation above ever stops pinning it to `tandem/<slug>`: a
  # branch that is not this slug's makes the whole lineage invalid, and an
  # invalid lineage never reaches this probe.
  case "$1" in
    1) printf 'thread de plan-review distinto entre raíces' ;;
    2) printf 'thread de implementación (sol) distinto entre raíces' ;;
    3) printf 'thread de code-review distinto entre raíces' ;;
    4) printf 'commit de aprobación del plan distinto entre raíces' ;;
    5) printf 'commit final registrado distinto entre raíces' ;;
    6) printf 'plan_hash del intento opus distinto entre raíces' ;;
    7) printf 'rama del intento opus distinta entre raíces' ;;
    8) printf 'agent_type del intento opus distinto entre raíces' ;;
  esac
  return 0
}

identity_probe() {
  # The split-brain probe: one identity fact present in TWO roots with different
  # VALIDATED values is not stale state — an honest run cannot have two thread
  # ids for one key, two approval commits or two attempt lineages. Divergence of
  # PHASE is deliberately not here: that is exactly what legitimate stale state
  # looks like, and reconciling it is the job of the comparison below.
  local f=1 i j a b
  while [ "$f" -le 8 ]; do
    i=0
    while [ "$i" -lt "$EVR_N" ]; do
      a="$(id_fact "$f" "$i")"
      if [ -n "$a" ]; then
        j=$((i + 1))
        while [ "$j" -lt "$EVR_N" ]; do
          b="$(id_fact "$f" "$j")"
          if [ -n "$b" ] && [ "$b" != "$a" ]; then
            CONTRA=1
            [ -n "$CONTRA_FACT" ] || CONTRA_FACT="$(id_label "$f")"
            return 0
          fi
          j=$((j + 1))
        done
      fi
      i=$((i + 1))
    done
    f=$((f + 1))
  done
  return 0
}

thread_vote() {
  # thread_vote <id-a> <max-a> <top-a> <id-b> <max-b> <top-b> <fact> — VOTE_R:
  # 0 no order, 1 a, 2 b, 3 irreconcilable. Only the SAME thread can be ordered
  # (two different ids were already stopped by the identity probe, and a thread
  # only one root knows says nothing about the other): the later turn wins; at
  # the same turn a completed reply beats an absent one; and two DIFFERENT
  # completed verdicts of the same turn are not an order at all.
  VOTE_R=0
  if [ -z "$1" ] || [ "$1" != "$4" ]; then return 0; fi
  if [ "$2" -gt "$5" ]; then VOTE_R=1; return 0; fi
  if [ "$2" -lt "$5" ]; then VOTE_R=2; return 0; fi
  if [ -n "$3" ] && [ -z "$6" ]; then VOTE_R=1; return 0; fi
  if [ -z "$3" ] && [ -n "$6" ]; then VOTE_R=2; return 0; fi
  if [ -n "$3" ] && [ "$3" != "$6" ]; then
    VOTE_R=3
    [ -n "$CONTRA_FACT" ] || CONTRA_FACT="$7"
  fi
  return 0
}

opus_vote() {
  # opus_vote <i> <j> — the same question over the durable Opus attempt.
  local a="$1" b="$2"
  VOTE_R=0
  if [ "${R_OP_HAS[$a]}" != "1" ] || [ "${R_OP_HAS[$b]}" != "1" ]; then return 0; fi
  # Progress is only comparable WITHIN one identified attempt: without TWO valid
  # lineages there is no proof both snapshots describe the same attempt, so no
  # progress vote is cast at all — both-invalid falls through to candidate
  # priority, exactly as the plan orders. (Mixed validity never reaches here:
  # cmp_roots' lineage dominance already decided it.)
  if [ "${R_OP_IDV[$a]}" != "1" ] || [ "${R_OP_IDV[$b]}" != "1" ]; then return 0; fi
  # A VALID progress tuple DOMINATES an invalid one: the corrupt snapshot never
  # wins by candidate priority and never forces a contradiction either.
  if [ "${R_OP_PV[$a]}" = "1" ] && [ "${R_OP_PV[$b]}" != "1" ]; then VOTE_R=1; return 0; fi
  if [ "${R_OP_PV[$b]}" = "1" ] && [ "${R_OP_PV[$a]}" != "1" ]; then VOTE_R=2; return 0; fi
  # Both invalid: nothing to order, candidate priority decides.
  if [ "${R_OP_PV[$a]}" != "1" ]; then return 0; fi
  # Rounds FIRST — a running turn of round 1 is newer than a terminal round 0.
  if [ "${R_OP_CONT[$a]}" -gt "${R_OP_CONT[$b]}" ]; then VOTE_R=1; return 0; fi
  if [ "${R_OP_CONT[$a]}" -lt "${R_OP_CONT[$b]}" ]; then VOTE_R=2; return 0; fi
  # Same round: the finished turn beats the one still running.
  if [ "${R_OP_ST[$a]}" != "${R_OP_ST[$b]}" ]; then
    if [ "${R_OP_ST[$a]}" = "terminal" ]; then VOTE_R=1; else VOTE_R=2; fi
    return 0
  fi
  # The same terminal revision with two different outcomes is not an order.
  if [ "${R_OP_ST[$a]}" = "terminal" ] && [ "${R_OP_SENT[$a]}" != "${R_OP_SENT[$b]}" ]; then
    VOTE_R=3
    [ -n "$CONTRA_FACT" ] \
      || CONTRA_FACT="sentinel distinto en la misma revisión terminal del intento opus"
  fi
  return 0
}

cast_vote() {
  # cast_vote <vote> — merge one channel's verdict into VOTE. Channels that
  # point in opposite directions are genuinely incomparable, which stops the
  # tool: an arbitrary pick by priority is the failure mode being fixed.
  [ "$1" = "0" ] && return 0
  if [ "$VOTE" = "0" ]; then
    VOTE="$1"
  elif [ "$VOTE" != "$1" ]; then
    VOTE=3
  fi
  return 0
}

cmp_roots() {
  # cmp_roots <i> <j> — CMP_R: 1 = i wins, 2 = j wins, 0 = no order at all
  # (candidate priority decides), 3 = irreconcilable.
  local a="$1" b="$2"
  CMP_R=0
  VOTE=0
  # The ladder first: the most advanced phase wins outright, whatever the
  # candidate order says.
  if [ "${R_RANK[$a]}" -gt "${R_RANK[$b]}" ]; then CMP_R=1; return 0; fi
  if [ "${R_RANK[$a]}" -lt "${R_RANK[$b]}" ]; then CMP_R=2; return 0; fi
  # Same phase: a VALID Opus lineage dominates an invalid one BEFORE any
  # progress is compared. The progress rules require the same attempt, which a
  # corrupt lineage cannot establish — without this rule a corrupt state in the
  # priority root would tie on phase and win by order, masking a valid
  # IMPLEMENTATION_COMPLETE in the other one.
  if [ "${R_OP_HAS[$a]}" = "1" ] && [ "${R_OP_HAS[$b]}" = "1" ]; then
    if [ "${R_OP_IDV[$a]}" = "1" ] && [ "${R_OP_IDV[$b]}" != "1" ]; then CMP_R=1; return 0; fi
    if [ "${R_OP_IDV[$b]}" = "1" ] && [ "${R_OP_IDV[$a]}" != "1" ]; then CMP_R=2; return 0; fi
  fi
  # Same phase and comparable identity: the explicit REVISION ORDER, channel by
  # channel. Two copies of one run share a phase and differ in progress, so
  # picking by candidate priority here would reproduce the very stale `next:`
  # this exists to prevent.
  thread_vote "${R_TH_PR[$a]}" "${R_PR_MAX[$a]}" "${R_PR_TOP[$a]}" \
    "${R_TH_PR[$b]}" "${R_PR_MAX[$b]}" "${R_PR_TOP[$b]}" \
    'veredictos distintos en el mismo turno del hilo de plan-review'
  cast_vote "$VOTE_R"
  thread_vote "${R_TH_IM[$a]}" "${R_IM_MAX[$a]}" "${R_IM_TOP[$a]}" \
    "${R_TH_IM[$b]}" "${R_IM_MAX[$b]}" "${R_IM_TOP[$b]}" \
    'resultados distintos en el mismo turno del hilo de implementación'
  cast_vote "$VOTE_R"
  thread_vote "${R_TH_CR[$a]}" "${R_CR_MAX[$a]}" "${R_CR_TOP[$a]}" \
    "${R_TH_CR[$b]}" "${R_CR_MAX[$b]}" "${R_CR_TOP[$b]}" \
    'veredictos distintos en el mismo turno del hilo de code-review'
  cast_vote "$VOTE_R"
  opus_vote "$a" "$b"
  cast_vote "$VOTE_R"
  if [ "$VOTE" = "3" ]; then
    CMP_R=3
    [ -n "$CONTRA_FACT" ] || CONTRA_FACT="evidencia de progreso incomparable entre raíces"
  else
    CMP_R="$VOTE"
  fi
  return 0
}

resolve_slug() {
  # resolve_slug <slug> — the whole multi-root question, answered once: which
  # root's story the report tells (RS_ROOT, always PHYSICAL), what that root
  # does not carry (RS_NOSTATE, RS_BRANCH_ROOT), which other roots also hold
  # evidence (EVR/R_FASE, RS_WIN) and whether they contradict each other
  # (CONTRA, CONTRA_FACT). It leaves the WINNER's analyze in place, so every
  # field the report prints comes from one root and never from a chimera.
  local s="$1" i=0 j=0 w=0 plan_owner branch_owner
  CONTRA=0
  CONTRA_FACT=""
  RS_NOSTATE=0
  RS_BRANCH_ROOT=""
  RS_ROOT=""
  RS_WIN=-1
  # FIRST, before any discovery or probe: the thread keys of THIS slug.
  # slug_has_evidence reads K_PLAN/K_CR, so in list mode a later slug evaluated
  # with the previous one's keys would lose every thread-only root.
  compute_keys "$s"
  evidence_roots "$s"

  if [ "$EVR_N" -eq 0 ]; then
    # No state anywhere. There can still be a report — a plan on disk, a branch
    # in some candidate's repository — but it is attributed to whoever OWNS that
    # evidence: analyzing the default root, where the branch may not exist,
    # would either report "no trace" or name a root that owns nothing.
    plan_owner=""
    branch_owner=""
    while [ "$i" -lt "$CAND_N" ]; do
      if [ -z "$plan_owner" ] && [ -f "${CAND[$i]}/docs/plans/$s.plan.md" ]; then
        plan_owner="${CAND[$i]}"
      fi
      if [ -z "$branch_owner" ] && root_has_branch "${CAND[$i]}" "tandem/$s"; then
        branch_owner="${CAND[$i]}"
      fi
      i=$((i + 1))
    done
    RS_NOSTATE=1
    if [ -n "$plan_owner" ]; then
      RS_ROOT="$plan_owner"
      # Plan and branch can live in DIFFERENT candidates. That is a fact of the
      # report, never a licence to name a root that owns neither of them.
      if [ -n "$branch_owner" ] && [ "$branch_owner" != "$plan_owner" ] \
        && ! root_has_branch "$plan_owner" "tandem/$s"; then
        RS_BRANCH_ROOT="$branch_owner"
      fi
    elif [ -n "$branch_owner" ]; then
      RS_ROOT="$branch_owner"
    else
      # The fallback goes through the SAME physical machinery as the candidates:
      # the root named in the report is always canonical.
      RS_ROOT="$(phys_path "$DEFAULT_ROOT")"
      [ -n "$RS_ROOT" ] || RS_ROOT="$DEFAULT_ROOT"
    fi
    analyze "$s" "$RS_ROOT"
    return 0
  fi

  if [ "$EVR_N" -eq 1 ]; then
    RS_ROOT="${EVR[0]}"
    analyze "$s" "$RS_ROOT"
    return 0
  fi

  # Two or more roots: analyze each one FIRST — the identity facts compared
  # below are the ones analyze itself validated, never raw file contents.
  i=0
  while [ "$i" -lt "$EVR_N" ]; do
    analyze "$s" "${EVR[$i]}"
    snap_root "$i"
    i=$((i + 1))
  done
  identity_probe
  if [ "$CONTRA" = "1" ]; then return 0; fi
  # EVERY pair is asked whether it can be reconciled at all, not just the ones
  # the champion below happens to meet: with three roots, two of them could
  # disagree irreconcilably while both compare cleanly against the third, and
  # answering from a champion that never met them would hide exactly the split
  # brain this stops for. cmp_roots is pure in-memory arithmetic over the
  # snapshots, so asking twice costs nothing.
  i=0
  while [ "$i" -lt "$EVR_N" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$EVR_N" ]; do
      cmp_roots "$i" "$j"
      if [ "$CMP_R" = "3" ]; then
        CONTRA=1
        return 0
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  # Reconcilable: the champion, in candidate order, so an outright tie keeps the
  # root with priority — the existing doctrine for two identical copies.
  i=1
  while [ "$i" -lt "$EVR_N" ]; do
    cmp_roots "$w" "$i"
    [ "$CMP_R" = "2" ] && w="$i"
    i=$((i + 1))
  done
  RS_WIN="$w"
  RS_ROOT="${EVR[$w]}"
  # The final analyze over the winner: every printed field comes from THAT root.
  analyze "$s" "$RS_ROOT"
  return 0
}

raiz_val() {
  # raiz_val — the `raíz:` value: the physical root the report was read from,
  # what that root does not carry, and every other root that also holds
  # evidence (with the phase it is at, so a stale copy is visible and never
  # mistaken for the report's own `fase:`).
  local v="$RS_ROOT" i=0
  [ "$RS_NOSTATE" = "1" ] && v="$v (sin estado .tandem)"
  [ -n "$RS_BRANCH_ROOT" ] && v="$v · rama en $RS_BRANCH_ROOT"
  if [ "$EVR_N" -gt 1 ] && [ "$RS_WIN" -ge 0 ]; then
    while [ "$i" -lt "$EVR_N" ]; do
      if [ "$i" != "$RS_WIN" ]; then
        v="$v · evidencia también en ${EVR[$i]} (fase: ${R_FASE[$i]})"
      fi
      i=$((i + 1))
    done
  fi
  printf '%s' "$v"
  return 0
}

print_contra() {
  # print_contra <slug> — every root, every phase, the fact that cannot be
  # reconciled, and NO next step. stdout stays empty on purpose: a report would
  # have to choose a root for each of its other rows, which is the masking bug.
  local s="$1" i=0
  printf 'tandem: evidencia contradictoria para "%s" entre raíces de estado:\n' "$s" >&2
  while [ "$i" -lt "$EVR_N" ]; do
    printf '  - %s — fase: %s\n' "${EVR[$i]}" "${R_FASE[$i]}" >&2
    i=$((i + 1))
  done
  printf '  hecho irreconciliable: %s\n' "$CONTRA_FACT" >&2
  printf '  resolver a mano — sin paso siguiente automático\n' >&2
  return 0
}

# --- the known runs ----------------------------------------------------------
RUN=()
RUN_N=0
add_run() {
  local s="${1:-}" i=0
  [ -n "$s" ] || return 0
  case "$s" in
    ultra-*) return 0 ;;
    *[!A-Za-z0-9._-]*) return 0 ;;
    [-.]*) return 0 ;;
  esac
  while [ "$i" -lt "$RUN_N" ]; do
    [ "${RUN[$i]}" = "$s" ] && return 0
    i=$((i + 1))
  done
  RUN[RUN_N]="$s"
  RUN_N=$((RUN_N + 1))
  return 0
}

collect_runs() {
  # The union of every candidate root, deduplicated: state split across a main
  # checkout and a linked worktree is still one list of runs, and every
  # candidate's repository contributes its `tandem/*` branches. Slugs come from
  # sources that carry them PLAIN — the checksummed thread keys are not
  # reversible and are deliberately not attempted (the log is initialized in
  # plan's Act 1, so every run that ever started is covered).
  local i=0 c f base refs rest line
  while [ "$i" -lt "$CAND_N" ]; do
    c="${CAND[$i]}"
    for f in "$c/.tandem/log"/*.md; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      add_run "${base%.md}"
    done
    for f in "$c/.tandem/state/plan-approve"/*.json; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      add_run "${base%.json}"
    done
    for f in "$c/.tandem/state/implement-claude"/*.json; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      add_run "${base%.json}"
    done
    [ "$HAVE_GIT" = "1" ] && add_gitr "$(git_main_from "$c")"
    i=$((i + 1))
  done
  [ "$HAVE_GIT" = "1" ] && add_gitr "$GIT_ROOT_DEFAULT"
  i=0
  while [ "$i" -lt "$GITR_N" ]; do
    refs="$(git -C "${GITR[$i]}" for-each-ref --format='%(refname)' 'refs/heads/tandem/*' 2>/dev/null)"
    rest="$refs"
    while [ -n "$rest" ]; do
      line="${rest%%"$NL"*}"
      if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*"$NL"}"; fi
      [ -n "$line" ] || continue
      add_run "${line#refs/heads/tandem/}"
    done
    i=$((i + 1))
  done
  return 0
}

print_runs() {
  # print_runs <out|err> — one `<slug> — <phase>` line per known run. A slug
  # whose roots contradict each other is listed as such and does NOT change the
  # exit code: the list is the panoramic view, and the detail (both roots, both
  # phases, the offending fact) is what slug mode is for.
  local stream="$1" sorted rest s ph
  if [ "$RUN_N" -eq 0 ]; then
    if [ "$stream" = "err" ]; then
      printf '(ningún run conocido)\n' >&2
    else
      printf '(ningún run conocido)\n'
    fi
    return 0
  fi
  sorted="$(printf '%s\n' "${RUN[@]}" | LC_ALL=C sort)"
  rest="$sorted"
  while [ -n "$rest" ]; do
    s="${rest%%"$NL"*}"
    if [ "$s" = "$rest" ]; then rest=""; else rest="${rest#*"$NL"}"; fi
    [ -n "$s" ] || continue
    resolve_slug "$s"
    ph="$FASE"
    [ "$CONTRA" = "1" ] && ph="contradictorio entre raíces"
    if [ "$stream" = "err" ]; then
      printf '  %s — %s\n' "$s" "$ph" >&2
    else
      printf '%s — %s\n' "$s" "$ph"
    fi
  done
  return 0
}

row() { printf '%-14s %s\n' "$1" "$2"; }

# --- list mode ---------------------------------------------------------------
if [ "$LIST_MODE" = "1" ]; then
  collect_runs
  print_runs out
  exit 0
fi

# --- slug mode ---------------------------------------------------------------
resolve_slug "$ARG_SLUG"
if [ "$CONTRA" = "1" ]; then
  print_contra "$ARG_SLUG"
  exit 2
fi
if [ "$HAS_ANY" != "1" ]; then
  printf 'tandem: no hay ni rastro del run "%s" (ni log, ni estado, ni plan, ni rama).\n' \
    "$ARG_SLUG" >&2
  printf 'tandem: runs conocidos:\n' >&2
  collect_runs
  print_runs err
  exit 2
fi

row 'slug:' "$SLUG"
# `raíz:` is printed ALWAYS, single root included: one more row in exchange for
# the user always seeing where the truth came from. Its label carries one
# two-byte character and printf pads by BYTES, so it gets one extra column of
# width to line up with the ASCII labels around it.
printf '%-15s %s\n' 'raíz:' "$(raiz_val)"
row 'plan:' "$PLAN_VAL"
row 'rama:' "$RAMA_VAL"
row 'plan-review:' "$PR_VAL"
row 'implement:' "$IMPL_VAL"
row 'code-review:' "$CR_VAL"
row 'gate:' "$GATE_VAL"
row 'tokens:' "$TOKENS_VAL"
row 'log:' "$LOG_VAL"
row 'fase:' "$FASE"
row 'next:' "$NEXT"
exit 0
