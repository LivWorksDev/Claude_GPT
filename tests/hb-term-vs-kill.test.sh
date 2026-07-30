#!/usr/bin/env bash
# What a killed turn leaves behind, empirically:
#   SIGTERM -> bash runs the EXIT trap before dying, so hb_guard writes
#              'failed' and the waiter still observes rc 143.
#   SIGKILL -> no trap can run: the heartbeat stays 'running' forever, and it is
#              the STATUS LINE that has to notice the pid is gone.
#
# The turn is launched with job control so it leads its own process group: the
# pipeline (codex | tee | stream_milestones) is reaped with a group kill instead
# of being orphaned for the rest of the suite.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"

export CODEX_STUB_SCENARIO=hang
export CODEX_STUB_HANG_SECONDS=25

launch() {
  # launch <role> <target> -> $PID, once the heartbeat says 'running'
  rm -f "$HB"
  set -m
  bash "$SCRIPTS/codex-start.sh" "$1" "$2" "$SANDBOX/p.tpl" \
    >"$SANDBOX/$2.out" 2>"$SANDBOX/$2.err" &
  PID=$!
  set +m
  wait_for_json "$HB" '.status == "running"' \
    || fail "the turn never published a running heartbeat"
}

reap() { kill -- -"$1" 2>/dev/null; return 0; }

# --- SIGTERM -----------------------------------------------------------------
launch review term-demo
assert_json "$HB" '.status == "running" and .role == "review"'
assert_json "$HB" '.pid == '"$PID"

kill -TERM "$PID"
RCT=0
wait "$PID" || RCT=$?
reap "$PID"

assert_eq "143" "$RCT" "SIGTERM exit code (128 + 15)"
assert_json "$HB" '.status == "failed"'
assert_json "$HB" '.role == "review" and .turn == 1'
# No success artefacts: the turn never completed.
assert_no_file "$(state_dir review)/$(tkey term-demo).thread"
assert_no_file "$(state_dir review)/$(tkey term-demo).last.txt"

# A status line seeing 'failed' paints it as failed, not orphaned.
statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "status line after SIGTERM"
assert_file_contains "$OUT" "✗ codex"
assert_not_contains "$OUT" "no process"

# --- SIGKILL -----------------------------------------------------------------
launch implement kill-demo
assert_json "$HB" '.status == "running" and .role == "implement"'
KILLED_PID="$PID"

kill -KILL "$PID"
RCK=0
wait "$PID" || RCK=$?
reap "$PID"

assert_eq "137" "$RCK" "SIGKILL exit code (128 + 9)"
# Nothing ran: the heartbeat is stuck on 'running' with a pid that is gone.
assert_json "$HB" '.status == "running"'
assert_json "$HB" '.pid == '"$KILLED_PID"
if kill -0 "$KILLED_PID" 2>/dev/null; then fail "pid $KILLED_PID survived SIGKILL"; fi

# The status line is the only thing that can catch this, and it does.
statusline_payload ".workspace.project_dir=$CLAUDE_PROJECT_DIR" \
  | bash "$SCRIPTS/statusline.sh" >"$OUT" 2>"$ERR"
assert_rc 0 "status line after SIGKILL"
assert_file_contains "$OUT" "⚠ codex"
assert_file_contains "$OUT" "no process"
assert_not_contains "$OUT" "⚙"
