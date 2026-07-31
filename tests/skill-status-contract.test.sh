#!/usr/bin/env bash
# The status skill's promise — it reads state, it never calls Codex and never
# spends a turn — is executable documentation: no behavioural test can see a
# skill that grew a codex launch, and the day it did, a "free" orientation tool
# would quietly start burning quota.
#
# The negative assertions are applied ONLY to the fenced EXECUTABLE blocks,
# never to the whole file: the skill MUST be able to state that policy in prose,
# and a file-wide `assert_not_contains` on the very words the anchor needs would
# be a contract impossible to satisfy. The dynamic half of the guarantee (zero
# codex invocations, in slug mode AND in list mode) lives in the behavioural
# cases, on the stub's own records.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$REPO_ROOT/skills/status/SKILL.md"
SCRIPT="$SCRIPTS/tandem-status.sh"

# flatten <file> — Markdown wraps, so prose anchors are judged on a
# whitespace-flattened copy. Never vacuously green: a truncated skill is a
# different bug, not a pass.
flatten() {
  local f="$1" out lines
  [ -f "$f" ] || fail "skill not found: $f"
  lines="$(wc -l <"$f" | tr -d ' ')"
  [ "$lines" -ge 20 ] || fail "$f looks truncated ($lines lines) — the anchors prove nothing"
  out="$SANDBOX/$(basename "$(dirname "$f")").flat"
  LC_ALL=C tr '\n' ' ' <"$f" | LC_ALL=C tr -s ' ' >"$out"
  printf '%s' "$out"
}

# extract_cmds <file> <out> — every LOGICAL command inside a fenced block, one
# per line, with backslash continuations accumulated: the same parser the
# worktree and turn-effort contracts use to decide what a skill really RUNS.
extract_cmds() {
  local f="$1" out="$2" line stripped cmd="" cont=0 fence=0 n=0
  [ -f "$f" ] || fail "skill not found: $f"
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '```'*)
        if [ -n "$cmd" ]; then
          printf '%s\n' "$cmd" >>"$out"
          n=$((n + 1))
        fi
        cmd="" cont=0
        if [ "$fence" -eq 1 ]; then fence=0; else fence=1; fi
        continue
        ;;
    esac
    [ "$fence" -eq 1 ] || continue
    if [ "$cont" -eq 1 ]; then cmd="$cmd $line"; else cmd="$line"; fi
    case "$cmd" in
      *\\)
        cont=1
        cmd="${cmd%\\}"
        ;;
      *)
        cont=0
        if [ -n "$cmd" ]; then
          printf '%s\n' "$cmd" >>"$out"
          n=$((n + 1))
        fi
        cmd=""
        ;;
    esac
  done <"$f"
  if [ -n "$cmd" ]; then
    printf '%s\n' "$cmd" >>"$out"
    n=$((n + 1))
  fi
  [ "$fence" -eq 0 ] || fail "$f: unterminated fenced block — the sections would be guesswork"
  [ "$n" -ge 1 ] || fail "$f: no command inside any fenced block"
  note "$(basename "$(dirname "$f")")/SKILL.md — $n command(s) in fenced blocks"
}

# --- the skill is a thin wrapper over the script under test ------------------
FLAT="$(flatten "$SKILL")"
assert_matches "$SKILL" '^name: status$'
assert_matches "$SKILL" '^argument-hint: "\[slug\]"$'
assert_file_contains "$FLAT" "tandem-status.sh"

# --- the anchor: read-only, never Codex, never a turn ------------------------
assert_file_contains "$FLAT" "read-only"
assert_file_contains "$FLAT" "never calls Codex"
assert_file_contains "$FLAT" "never spends a turn"
# What the report's degradations mean, and that exit 2 lists the runs.
assert_file_contains "$FLAT" "desconocido"
assert_file_contains "$FLAT" "The known runs are listed on stderr"
# The next: line is offered, never executed on its own.
assert_file_contains "$FLAT" "never run it on your own"

# --- the negatives, on the executable blocks ONLY ----------------------------
CMDS="$SANDBOX/status.cmds"
extract_cmds "$SKILL" "$CMDS"
assert_file_contains "$CMDS" "scripts/tandem-status.sh"
for needle in "codex-start.sh" "codex-resume.sh" "codex-swarm.sh" "codex exec"; do
  assert_not_contains "$CMDS" "$needle"
done

# --- the terminal record the phase ladder depends on -------------------------
# Without this line in the review skill, `commit final` could never be proven:
# the branch, which a legitimate merge deletes, is not evidence forever.
REVIEW_FLAT="$(flatten "$REPO_ROOT/skills/review/SKILL.md")"
assert_file_contains "$REVIEW_FLAT" "final — commit:"
assert_file_contains "$REVIEW_FLAT" ".tandem/log/<slug>.md"
assert_file_contains "$REVIEW_FLAT" "machine-parseable"

# --- the run skill points at the new orientation tool ------------------------
RUN_FLAT="$(flatten "$REPO_ROOT/skills/run/SKILL.md")"
assert_file_contains "$RUN_FLAT" "/tandem:status"

# --- the script the skill points at exists and holds its usage contract ------
assert_file "$SCRIPT"
run bash "$SCRIPT" "../x"
assert_rc 64 "invalid slug"
assert_file_contains "$ERR" "usage:"

note "status/SKILL.md — read-only anchor, no codex launch in any executable block"
