#!/usr/bin/env bash
# Two seats of the same run, genuinely concurrent. Seat independence is the
# point of a swarm: no shared thread, no shared heartbeat, no interleaved state.
#
# Each seat gets its OWN CODEX_STUB_LOG so the stub's flat invocation counter
# cannot race (the suite is otherwise sequential and needs no locking).
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
printf 'prompt for seat A\n' >"$SANDBOX/a.txt"
printf 'prompt for seat B\n' >"$SANDBOX/b.txt"
mkdir -p "$SANDBOX/logs"

export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_SLEEP=1

CODEX_STUB_LOG="$SANDBOX/logs/a" CODEX_STUB_REPLY="reply from A" \
  bash "$SCRIPTS/codex-swarm.sh" worker run-x seat-a "$SANDBOX/a.txt" \
  >"$SANDBOX/a.out" 2>"$SANDBOX/a.err" &
PA=$!
CODEX_STUB_LOG="$SANDBOX/logs/b" CODEX_STUB_REPLY="reply from B" \
  bash "$SCRIPTS/codex-swarm.sh" scout run-x seat-b "$SANDBOX/b.txt" \
  >"$SANDBOX/b.out" 2>"$SANDBOX/b.err" &
PB=$!

RA=0; wait "$PA" || RA=$?
RB=0; wait "$PB" || RB=$?
assert_eq "0" "$RA" "seat A exit code"
assert_eq "0" "$RB" "seat B exit code"

RUNKEY="$(tkey run-x)"
UD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUNKEY"
AK="$(tkey seat-a)"
BK="$(tkey seat-b)"

# State is per seat, in one shared run namespace.
assert_file_contains "$UD/$AK.reply.txt" "reply from A"
assert_file_contains "$UD/$BK.reply.txt" "reply from B"
assert_file_contains "$UD/$AK.prompt.txt" "prompt for seat A"
assert_file_contains "$UD/$BK.prompt.txt" "prompt for seat B"
assert_not_contains "$UD/$AK.reply.txt" "reply from B"
assert_not_contains "$UD/$BK.reply.txt" "reply from A"

# Each seat's own stub log recorded exactly one invocation, with its own tier.
assert_eq "1" "$(cat "$SANDBOX/logs/a.n")" "seat A invocations"
assert_eq "1" "$(cat "$SANDBOX/logs/b.n")" "seat B invocations"
assert_file_contains "$SANDBOX/logs/a.argv.1" "gpt-5.6-sol"
assert_file_contains "$SANDBOX/logs/b.argv.1" "gpt-5.6-luna"
assert_file_contains "$SANDBOX/logs/a.stdin.1" "prompt for seat A"
assert_file_contains "$SANDBOX/logs/b.stdin.1" "prompt for seat B"

# No seat wrote the heartbeat: N parallel turns would fight over current.json.
assert_no_file "$CLAUDE_PROJECT_DIR/.tandem/state/current.json"
assert_no_file "$SANDBOX/logs/a.hb.1"
assert_no_file "$SANDBOX/logs/b.hb.1"

# Both panels narrated their own progress.
assert_file_contains "$SANDBOX/a.out" "» thread thr_stub_1"
assert_file_contains "$SANDBOX/b.out" "» thread thr_stub_1"
assert_file_contains "$SANDBOX/a.err" "seat=seat-a"
assert_file_contains "$SANDBOX/b.err" "seat=seat-b"

# --- the token ledger: one file per ATTEMPT, per seat ------------------------
# Each seat's first attempt is t1, in its own run namespace, and each seat
# advertises its own ledger path so the aggregation never has to reconstruct a
# target_key checksum to find it.
assert_json "$UD/$AK.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$UD/$BK.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$SANDBOX/a.err" 'USAGE: {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$SANDBOX/a.err" "USAGE_FILE: $UD/$AK.t1.usage.json"
assert_file_contains "$SANDBOX/b.err" "USAGE_FILE: $UD/$BK.t1.usage.json"

# A retry overwrites the seat's reply by contract — but never its ledger: the
# quota the first attempt spent is already gone, so t2 is ADDED next to t1.
unset CODEX_STUB_SLEEP
export CODEX_STUB_LOG="$SANDBOX/logs/a2"
export CODEX_STUB_REPLY="retry from A"
run bash "$SCRIPTS/codex-swarm.sh" worker run-x seat-a "$SANDBOX/a.txt"
assert_rc 0 "successful retry"
assert_file_contains "$UD/$AK.reply.txt" "retry from A"
assert_json "$UD/$AK.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$UD/$AK.t2.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$ERR" "USAGE_FILE: $UD/$AK.t2.usage.json"

# A retry that burns quota and THEN fails is accounted for exactly the same way:
# the exit code is the failure's, the ledger grows anyway.
export CODEX_STUB_SCENARIO=empty-reply
export CODEX_STUB_LOG="$SANDBOX/logs/a3"
run bash "$SCRIPTS/codex-swarm.sh" worker run-x seat-a "$SANDBOX/a.txt"
assert_rc 1 "retry with an empty reply"
assert_json "$UD/$AK.t3.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$ERR" 'USAGE: {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$ERR" "USAGE_FILE: $UD/$AK.t3.usage.json"

# A genuine turn.failed never completed a turn: nothing is added, nothing is
# corrupted, and no footer is emitted for the wrapper's schema to fill.
export CODEX_STUB_SCENARIO=fail
export CODEX_STUB_LOG="$SANDBOX/logs/a4"
run bash "$SCRIPTS/codex-swarm.sh" worker run-x seat-a "$SANDBOX/a.txt"
assert_rc 1 "retry that never completed a turn"
assert_no_file "$UD/$AK.t4.usage.json"
assert_not_contains "$ERR" "USAGE:"
assert_not_contains "$ERR" "USAGE_FILE:"
assert_json "$UD/$AK.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_json "$UD/$AK.t3.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
# Seat B's ledger was never touched by any of seat A's attempts.
assert_no_file "$UD/$BK.t2.usage.json"
