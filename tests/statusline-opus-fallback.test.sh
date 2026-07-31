#!/usr/bin/env bash
# Line 2 during an Opus implementation. The durable attempt state
# (.tandem/state/implement-claude/<slug>.json) carries presence and outcome, and
# the row is a WINNER SELECTION, not a fallback bolted onto the end of the Codex
# path: a live Codex turn always wins, and between states that are not live the
# newest one does — otherwise the plan-review heartbeat that finished seconds
# before the implementation started would hide it for its whole first quarter of
# an hour, and an orphaned heartbeat would hide it forever.
#
# Every window here is fabricated with `touch -t`: no sleeps, no wall clock.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
IMPL="$CLAUDE_PROJECT_DIR/.tandem/state/implement-claude"
NOW="$(date +%s)"

GREEN=$'\033[38;5;78m'
YELLOW=$'\033[38;5;179m'
GREY=$'\033[38;5;245m'

show() {
  statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
    | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
  RC=$?
  assert_rc 0
  # Per invocation: the status line must never write to stderr, and $ERR is
  # overwritten by the next case.
  assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr"
}

lines() { wc -l <"$OUT" | tr -d ' '; }

# stamp <epoch> — a `touch -t` timestamp for an absolute epoch second. BSD reads
# an epoch with -r, GNU with -d @…; the wrong flavour fails and falls through.
stamp() {
  date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null
}

# age <file> <seconds-ago> — backdate the mtime, which is the only clock the
# Opus row has.
age() {
  local secs="$2" s
  s="$(stamp "$((NOW - secs))")"
  [ -n "$s" ] || fail "neither date -r nor date -d produced a timestamp"
  touch -t "$s" "$1" || fail "touch -t $s failed for $1"
}

# impl <slug> <status> <sentinel|""> <age-seconds> — the attempt state, shaped
# like the one skills/implement writes.
impl() {
  local f="$IMPL/$1.json"
  mkdir -p "$IMPL"
  jq -n --arg s "$2" --arg v "$3" '{
    agent: {name: "tandem-implementer", id: "agent_1"},
    task_id: "task_1", status: $s, continuation_rounds: 0,
    last_sentinel: (if $v == "" then null else $v end),
    last_report: null, worktree: null,
    plan_path: "docs/plans/demo.plan.md", plan_hash: "deadbeef",
    branch: "tandem/demo", base_head: "cafe", remote_snapshot: ""
  }' >"$f" || fail "cannot write $f"
  age "$f" "$4"
}

clean() { rm -rf "$IMPL"; rm -f "$HB"; }

# A real child, run to completion and reaped: definitively ours, definitively
# dead (never an invented pid, which could belong to a live process).
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
if kill -0 "$DEAD_PID" 2>/dev/null; then fail "pid $DEAD_PID is still alive"; fi

# --- presence and outcome, with no Codex heartbeat at all --------------------
clean
impl demo running "" 5
show
assert_eq "2" "$(lines)" "running attempt"
assert_file_contains "$OUT" "${YELLOW}⚒ opus implement"
assert_file_contains "$OUT" "running"
assert_file_contains "$OUT" "demo"
# Presence and outcome only — never invented activity.
assert_not_contains "$OUT" "exec"
assert_not_contains "$OUT" "codex"

impl demo terminal IMPLEMENTATION_COMPLETE 5
show
assert_file_contains "$OUT" "${GREEN}✓ opus implement"
assert_file_contains "$OUT" "IMPLEMENTATION_COMPLETE"
assert_file_contains "$OUT" "demo"

impl demo terminal IMPLEMENTATION_PARTIAL 5
show
assert_file_contains "$OUT" "${YELLOW}↺ opus implement"
assert_file_contains "$OUT" "IMPLEMENTATION_PARTIAL"

# A terminal turn that left no sentinel is an unknown outcome, not a success.
impl demo terminal "" 5
show
assert_file_contains "$OUT" "${GREY}· opus implement"
assert_file_contains "$OUT" "demo"

# The slug is the file name — attempt state uses the plain slug, with no
# checksum to reverse.
clean
impl statusline-opus running "" 5
show
assert_file_contains "$OUT" "statusline-opus"
assert_not_contains "$OUT" ".json"

# --- visibility windows, by the mtime of the JSON ----------------------------
clean
impl demo terminal IMPLEMENTATION_COMPLETE 840
show
assert_eq "2" "$(lines)" "terminal 840s old (60s inside the window survives CI delay)"
assert_file_contains "$OUT" "✓ opus implement"

impl demo terminal IMPLEMENTATION_COMPLETE 960
show
assert_eq "1" "$(lines)" "terminal 960s old (60s outside)"
assert_not_contains "$OUT" "opus implement"
assert_file_contains "$OUT" "◈ Claude Fable 5"

# A running attempt stays for two hours…
impl demo running "" 7140
show
assert_file_contains "$OUT" "${YELLOW}⚒ opus implement"
assert_not_contains "$OUT" "sin señal"

# …and then says it lost the signal instead of faking work or going silent: the
# JSON is only written at launch and at close, so a running state hours old is
# almost always a session that died without closing it.
impl demo running "" 7260
show
assert_eq "2" "$(lines)" "running 2h old"
assert_file_contains "$OUT" "${GREY}⚠ opus implement"
assert_file_contains "$OUT" "sin señal"

# --- priority: a LIVE Codex turn always wins ---------------------------------
clean
impl demo running "" 1
write_hb "$HB" "status=running" "pid=$$"
show
assert_file_contains "$OUT" "⚙ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# A running heartbeat with pid 0 is UNKNOWN, not dead: it keeps the existing
# contract (statusline-orphaned-pid) and therefore keeps the row.
write_hb "$HB" "status=running" "pid=0"
show
assert_file_contains "$OUT" "⚙ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# --- priority: between states that are NOT live, the newest wins --------------
# THE REAL PIPELINE TRANSITION — the plan review finished seconds ago and the
# implementation has just started. With absolute priority for the terminal
# heartbeat this row would be blind for 15 minutes, i.e. for most attempts.
clean
write_hb "$HB" "status=done" "verdict=APPROVED" "updated_at=$((NOW - 60))" \
  "started_at=$((NOW - 120))"
impl demo running "" 10
show
assert_file_contains "$OUT" "⚒ opus implement"
assert_not_contains "$OUT" "codex"

# The mirror image: the heartbeat is the newest state, so it keeps the row.
write_hb "$HB" "status=done" "verdict=APPROVED" "updated_at=$((NOW - 10))" \
  "started_at=$((NOW - 120))"
impl demo running "" 300
show
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# An ORPHANED heartbeat is exempt from the staleness window, so with absolute
# priority it would cover every future attempt, forever.
clean
write_hb "$HB" "status=running" "pid=$DEAD_PID" "updated_at=$((NOW - 5000))" \
  "started_at=$((NOW - 5100))"
impl demo running "" 5
show
assert_file_contains "$OUT" "⚒ opus implement"
assert_not_contains "$OUT" "no process"

# A heartbeat already suppressed by its own 900 s window never competes.
clean
write_hb "$HB" "status=done" "updated_at=$((NOW - 1000))" \
  "started_at=$((NOW - 1100))"
impl demo running "" 5
show
assert_eq "2" "$(lines)" "suppressed heartbeat, fresh attempt"
assert_file_contains "$OUT" "⚒ opus implement"
assert_not_contains "$OUT" "codex"

# --- exact timestamp ties are deterministic ----------------------------------
# Both clocks have second resolution and the hand-over is immediate, so ties are
# not hypothetical. A running attempt is the state that has just been born…
clean
write_hb "$HB" "status=done" "verdict=APPROVED" "updated_at=$((NOW - 60))" \
  "started_at=$((NOW - 120))"
impl demo running "" 60
show
assert_file_contains "$OUT" "⚒ opus implement"
assert_not_contains "$OUT" "codex"

# …while a terminal one loses: in doubt, the existing path keeps the row.
impl demo terminal IMPLEMENTATION_COMPLETE 60
show
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# --- several attempts on disk: the newest by mtime, not by name --------------
clean
impl alpha terminal IMPLEMENTATION_COMPLETE 500
impl zulu running "" 5
show
assert_file_contains "$OUT" "⚒ opus implement"
assert_file_contains "$OUT" "zulu"
assert_not_contains "$OUT" "alpha"

# Reversed in time but not in name — lexicographic order would answer "zulu".
age "$IMPL/alpha.json" 1
show
assert_file_contains "$OUT" "✓ opus implement"
assert_file_contains "$OUT" "alpha"
assert_not_contains "$OUT" "zulu"

# --- no clock at all: `stat` unreachable -------------------------------------
# A stub that FAILS, in $SANDBOX/bin, which precedes /usr/bin on the runner's
# PATH. Emptying PATH instead would kill jq first and the branch would never
# run.
clean
printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/stat"
chmod +x "$SANDBOX/bin/stat"
assert_eq "$SANDBOX/bin/stat" "$(command -v stat)" "the stat stub shadows the real one"

# With an eligible heartbeat there is nothing to break the tie with: Codex keeps
# the row.
write_hb "$HB" "status=done" "verdict=APPROVED" "updated_at=$((NOW - 60))" \
  "started_at=$((NOW - 120))"
impl demo running "" 10
show
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# Alone, the attempt renders WITHOUT its window — a visible degradation, never a
# crash and never silence. The mtime here is days old and still shows.
rm -f "$HB"
impl demo terminal IMPLEMENTATION_COMPLETE 500000
show
assert_eq "2" "$(lines)" "no stat, no heartbeat"
assert_file_contains "$OUT" "${GREEN}✓ opus implement"
rm -f "$SANDBOX/bin/stat"

# --- corruption removes the candidate, and nothing else ----------------------
clean
mkdir -p "$IMPL"
printf 'not json at all\n' >"$IMPL/demo.json"
show
assert_eq "1" "$(lines)" "corrupt attempt state"
assert_not_contains "$OUT" "opus implement"

# A corrupt file must never suppress a VALID Codex heartbeat, even when it is
# the newest thing on disk.
write_hb "$HB" "status=done" "verdict=IMPLEMENTATION_COMPLETE" \
  "updated_at=$((NOW - 60))" "started_at=$((NOW - 120))"
printf '{"status":"running",\n' >"$IMPL/demo.json"
show
assert_eq "2" "$(lines)" "corrupt attempt state, valid heartbeat"
assert_file_contains "$OUT" "✓ codex gpt-5.6-sol"
assert_not_contains "$OUT" "opus implement"

# --- the same dual-root resolution as the heartbeat --------------------------
# A session opened inside a linked worktree sees the state of the main checkout,
# which is where the skill writes it.
clean
MAIN="$CLAUDE_PROJECT_DIR"
WT="$SANDBOX/wt"
mkdir -p "$MAIN/.tandem"
printf '*\n' >"$MAIN/.tandem/.gitignore"
make_repo "$MAIN"
printf 'seed\n' >"$MAIN/f.txt"
commit_all "$MAIN"
git -C "$MAIN" worktree add -q -b tandem/demo "$WT" >/dev/null 2>&1 \
  || fail "git worktree add failed"

impl demo running "" 5
assert_no_file "$WT/.tandem/state/implement-claude/demo.json"

statusline_payload ".workspace.project_dir=$WT" ".workspace.current_dir=$WT" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
RC=$?
assert_rc 0 "status line inside the worktree"
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr from the worktree"
assert_file_contains "$OUT" "⚒ opus implement"
assert_file_contains "$OUT" "demo"

# An EMPTY implement-claude/ in the worktree must not mask the main checkout:
# the fallback resolves on real *.json candidates, not on directory existence.
mkdir -p "$WT/.tandem/state/implement-claude"
statusline_payload ".workspace.project_dir=$WT" ".workspace.current_dir=$WT" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
RC=$?
assert_rc 0 "status line with an empty local state dir"
assert_eq "0" "$(wc -c <"$ERR" | tr -d ' ')" "bytes on stderr (empty local dir)"
assert_file_contains "$OUT" "⚒ opus implement"
assert_file_contains "$OUT" "demo"
