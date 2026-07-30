#!/usr/bin/env bash
# The RUNNING heartbeat is the one the status line actually reads while a turn
# is in flight, and by the time the script returns hb_end has overwritten it —
# no assertion on the final state can see it. The stub snapshots it mid-turn.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "prompt {{TARGET}}"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_snap

run bash "$SCRIPTS/codex-start.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0

KEY="$(tkey demo)"
SD="$(state_dir review)"
SNAP="$(stub_hb 1)"
assert_file "$SNAP"

# The contract the live-activity block depends on: status running AND the
# events path of THIS turn, already present before codex emitted a single event.
assert_json "$SNAP" '.status == "running"'
assert_json "$SNAP" '.events == "'"$SD/$KEY.t1.events.ndjson"'"'
assert_json "$SNAP" '.turn == 1'
assert_json "$SNAP" '.role == "review" and .model == "gpt-5.6-sol"'
assert_json "$SNAP" '.effort == "xhigh" and .sandbox == "read-only"'
assert_json "$SNAP" '.target == "demo"'
assert_json "$SNAP" '.verdict == null'
# Tokens are ALWAYS null while running: the usage only exists once the turn
# closes, and showing the previous turn's tokens during a new one would lie.
assert_json "$SNAP" '.tokens_in == null and .tokens_out == null'
assert_json "$SNAP" '(.pid | type) == "number" and .pid > 0'
assert_json "$SNAP" '(.started_at | type) == "number" and .started_at > 0'

# The pid is a process that really existed: it is the codex-start.sh shell, and
# it is the stub's own parent chain, so it was alive when the snapshot was taken.
assert_json "$SNAP" '.pid != .turn'

# The final heartbeat then supersedes it, same turn, same events path — and it
# is the one that carries the tokens the turn actually spent.
HB="$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
assert_json "$HB" '.status == "done" and .turn == 1'
assert_json "$HB" '.tokens_in == 1234 and .tokens_out == 56'
assert_json "$HB" '.events == "'"$SD/$KEY.t1.events.ndjson"'"'
assert_eq "$(jq -r .pid "$SNAP")" "$(jq -r .pid "$HB")" "same pid before and after"
assert_eq "$(jq -r .started_at "$SNAP")" "$(jq -r .started_at "$HB")" "same start time"

# Resume publishes a running heartbeat for its own turn number.
run bash "$SCRIPTS/codex-resume.sh" review demo "$SANDBOX/p.tpl"
assert_rc 0 "resume"
SNAP2="$(stub_hb 2)"
assert_json "$SNAP2" '.status == "running" and .turn == 2'
assert_json "$SNAP2" '.events == "'"$SD/$KEY.t2.events.ndjson"'"'
# Not even the tokens of the turn that just finished leak into the new one.
assert_json "$SNAP2" '.tokens_in == null and .tokens_out == null'

# A turn that fails also passed through 'running' first — the snapshot proves
# the EXIT guard flipped an already-published heartbeat rather than inventing one.
export CODEX_STUB_SCENARIO=fail
run bash "$SCRIPTS/codex-start.sh" implement other "$SANDBOX/p.tpl"
assert_rc 1 "failing turn"
SNAP3="$(stub_hb 3)"
assert_json "$SNAP3" '.status == "running" and .role == "implement"'
assert_json "$SNAP3" '.sandbox == "workspace-write"'
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" '.status == "failed"'

# "No usage" means "the stream carried no turn.completed", and that is the ONLY
# thing it means: this scenario never completed a turn, so there is no ledger
# file, no footer, and the heartbeat's tokens stay null.
assert_no_file "$(state_dir implement)/$(tkey other).t1.usage.json"
assert_not_contains "$ERR" "USAGE:"
assert_json "$CLAUDE_PROJECT_DIR/.tandem/state/current.json" \
  '.tokens_in == null and .tokens_out == null'
