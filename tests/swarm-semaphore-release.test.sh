#!/usr/bin/env bash
# A seat that dies releases its slot, and a seat that cannot get one fails LOUD
# instead of deadlocking — the two halves of a semaphore that must never wedge a
# run. Every signal case is gated by a readiness barrier: without one, a TERM
# delivered before the traps are even armed would give the same exit code and
# prove nothing at all.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
mkdir -p "$SANDBOX/logs"
printf 'seat prompt\n' >"$SANDBOX/seat.txt"

# One slot: every case below is about who holds THE slot.
export TANDEM_ULTRA_CONCURRENCY=1

slots_left() {
  # slots_left <run-state-dir> — how many slot directories survived.
  find "$1/.slots" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

UD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey run-rel)"

# --- a seat that fails releases its slot (the `die` path runs the EXIT trap) --
export CODEX_STUB_SCENARIO=fail
export CODEX_STUB_LOG="$SANDBOX/logs/f1"
run bash "$SCRIPTS/codex-swarm.sh" worker run-rel r1 "$SANDBOX/seat.txt"
assert_rc 1 "codex failure"
assert_eq "0" "$(slots_left "$UD")" "slots left after a failed seat"

# …and the proof that it really released: with one slot and a 3s timeout, a
# leaked slot would make this exit 75 instead of 0.
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_LOG="$SANDBOX/logs/f2"
export TANDEM_ULTRA_SLOT_TIMEOUT=3
run bash "$SCRIPTS/codex-swarm.sh" worker run-rel r1 "$SANDBOX/seat.txt"
assert_rc 0 "the next seat gets the slot the dead one held"
assert_eq "0" "$(slots_left "$UD")" "slots left after a successful seat"
unset TANDEM_ULTRA_SLOT_TIMEOUT

# --- TERM mid-turn: the slot comes back AND the turn is still accounted for --
# The signal is delivered inside the stub's sleep window, so bash defers the
# handler until the turn ends naturally: the seat therefore has a completed turn
# whose quota is already spent, and the ledger + footers must land BEFORE the
# 143. Signalling "just after the turn ended" instead would be a pure race.
TERMLOG="$SANDBOX/logs/term"
TK="$(tkey r-term)"
CODEX_STUB_LOG="$TERMLOG" CODEX_STUB_SLEEP=3 CODEX_STUB_REPLY="reply under TERM" \
  bash "$SCRIPTS/codex-swarm.sh" worker run-rel r-term "$SANDBOX/seat.txt" \
  >"$SANDBOX/term.out" 2>"$SANDBOX/term.err" &
PT=$!

i=0
while [ "$i" -lt 150 ]; do
  if [ -f "$TERMLOG.argv.1" ] && [ -f "$UD/.slots/slot.1/holder" ]; then break; fi
  kill -0 "$PT" 2>/dev/null || fail "the seat exited before the barrier was met"
  sleep 0.1
  i=$((i + 1))
done
[ -f "$TERMLOG.argv.1" ] || fail "barrier: the seat never started its codex turn"
[ -f "$UD/.slots/slot.1/holder" ] || fail "barrier: the seat never registered a slot holder"
kill -0 "$PT" 2>/dev/null || fail "barrier: the seat is no longer alive to be signalled"
assert_eq "1" "$(slots_left "$UD")" "the slot the seat holds while running"

kill -TERM "$PT"
RT=0
wait "$PT" || RT=$?
assert_eq "143" "$RT" "TERM delivered mid-turn"
assert_eq "0" "$(slots_left "$UD")" "slots left after a seat killed by TERM"
assert_file_contains "$SANDBOX/term.err" "signal received"

# The accounting of a turn that completed is unconditional: the signal is
# honoured only after the ledger and both footers exist.
assert_file_contains "$UD/$TK.events.ndjson" '"type":"turn.completed"'
assert_json "$UD/$TK.t1.usage.json" '. == {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$SANDBOX/term.err" 'USAGE: {"input_tokens":1234,"output_tokens":56}'
assert_file_contains "$SANDBOX/term.err" "USAGE_FILE: $UD/$TK.t1.usage.json"

# --- a slot nobody will free: loud 75, zero quota, nothing destroyed ---------
# The seat already has a durable reply and staged prompt from an earlier
# attempt. A timeout must not cost that: the slot is taken BEFORE anything is
# staged or deleted, so both files survive byte for byte.
UD_T="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey run-t)"
QK="$(tkey q1)"
printf 'first attempt prompt\n' >"$SANDBOX/first.txt"
printf 'second attempt prompt — must never be staged\n' >"$SANDBOX/second.txt"

export CODEX_STUB_LOG="$SANDBOX/logs/t1"
export CODEX_STUB_REPLY="durable reply"
run bash "$SCRIPTS/codex-swarm.sh" worker run-t q1 "$SANDBOX/first.txt"
assert_rc 0 "the seat's first attempt"
cp "$UD_T/$QK.reply.txt" "$SANDBOX/reply.ref"
cp "$UD_T/$QK.prompt.txt" "$SANDBOX/prompt.ref"

mkdir -p "$UD_T/.slots/slot.1"
printf 'pid=999999 run=run-t seat=ghost\n' >"$UD_T/.slots/slot.1/holder"
export TANDEM_ULTRA_SLOT_TIMEOUT=1
export CODEX_STUB_LOG="$SANDBOX/logs/t2"
run bash "$SCRIPTS/codex-swarm.sh" worker run-t q1 "$SANDBOX/second.txt"
assert_rc 75 "no free slot within the timeout"
assert_file_contains "$ERR" "no free ultra slot after 1s"
assert_file_contains "$ERR" "$UD_T/.slots"
assert_no_file "$SANDBOX/logs/t2.argv.1"
cmp -s "$SANDBOX/reply.ref" "$UD_T/$QK.reply.txt" \
  || fail "the timeout destroyed the seat's previous reply"
cmp -s "$SANDBOX/prompt.ref" "$UD_T/$QK.prompt.txt" \
  || fail "the timeout overwrote the seat's staged prompt"
assert_file_contains "$UD_T/$QK.prompt.txt" "first attempt prompt"

# The stale slot is the documented manual remedy — remove it and the run resumes.
rm -rf "$UD_T/.slots/slot.1"
export CODEX_STUB_LOG="$SANDBOX/logs/t3"
run bash "$SCRIPTS/codex-swarm.sh" worker run-t q1 "$SANDBOX/second.txt"
assert_rc 0 "the seat recovers once the stale slot is gone"
assert_file_contains "$UD_T/$QK.prompt.txt" "second attempt prompt"
assert_eq "0" "$(slots_left "$UD_T")" "slots left after the recovery run"
unset TANDEM_ULTRA_SLOT_TIMEOUT

# --- TERM while QUEUED: 143, never 75, and never anyone else's slot ----------
UD_Q="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey run-q)"
mkdir -p "$UD_Q/.slots/slot.1"
printf 'pid=999999 run=run-q seat=foreign\n' >"$UD_Q/.slots/slot.1/holder"
cp "$UD_Q/.slots/slot.1/holder" "$SANDBOX/holder.ref"

QLOG="$SANDBOX/logs/q"
CODEX_STUB_LOG="$QLOG" TANDEM_ULTRA_SLOT_TIMEOUT=30 \
  bash "$SCRIPTS/codex-swarm.sh" worker run-q q-wait "$SANDBOX/seat.txt" \
  >"$SANDBOX/q.out" 2>"$SANDBOX/q.err" &
PQ=$!

i=0
while [ "$i" -lt 150 ]; do
  if grep -F -q -- "ultra slots busy — waiting" "$SANDBOX/q.err" 2>/dev/null; then break; fi
  kill -0 "$PQ" 2>/dev/null || fail "the waiter exited before the barrier was met"
  sleep 0.1
  i=$((i + 1))
done
grep -F -q -- "ultra slots busy — waiting" "$SANDBOX/q.err" 2>/dev/null \
  || fail "barrier: the seat never reported queueing behind the busy slot"
kill -0 "$PQ" 2>/dev/null || fail "barrier: the waiter is no longer alive to be signalled"

kill -TERM "$PQ"
RQ=0
wait "$PQ" || RQ=$?
assert_eq "143" "$RQ" "TERM delivered to a queued seat (never the congestion 75)"
assert_no_file "$QLOG.argv.1"
[ -d "$UD_Q/.slots/slot.1" ] || fail "the cancelled waiter deleted the foreign slot"
cmp -s "$SANDBOX/holder.ref" "$UD_Q/.slots/slot.1/holder" \
  || fail "the cancelled waiter rewrote the foreign slot's holder"
assert_eq "1" "$(slots_left "$UD_Q")" "slots after cancelling a queued seat"
note "release: die, TERM mid-turn, timeout 75 and TERM in the queue all behave"

# --- late-signal window: the traps are RE-ARMED to direct exit ---------------
# A signal landing after the accounting boundary (result validation, reply
# emission) has no sig_honor left to honour it: the contract holds because the
# script re-arms HUP/INT/TERM to exit directly once the ledger is durable. The
# window is microseconds wide, so timing a live signal into it would be a flaky
# test; the ordering is asserted structurally instead — the re-arm must exist
# AFTER the last sig_honor boundary, or a late TERM masquerades as success.
# All THREE re-arms must precede the final drain: draining first would leave a
# gap where a signal hits the old recording handler and stays pending forever.
REARM_ORDER="$(awk '
  /^sig_honor$/ { last_honor = NR }
  /^trap '\''exit 129'\'' HUP$/ { hup = NR }
  /^trap '\''exit 130'\'' INT$/ { intr = NR }
  /^trap '\''exit 143'\'' TERM$/ { term = NR }
  END {
    if (hup > 0 && intr > 0 && term > 0 && last_honor > hup && last_honor > intr && last_honor > term) print "ok"
    else print "bad (hup=" hup " int=" intr " term=" term " last_honor=" last_honor ")"
  }' "$SCRIPTS/codex-swarm.sh")"
assert_eq "ok" "$REARM_ORDER" "the three re-armed traps precede the final drain"
