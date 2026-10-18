#!/usr/bin/env bash
# council.sh — concurrency and the lifecycle of an Astra turn, part 1 of A5b
# (part 2 is council-recovery.test.sh; the shared preamble lives in
# council-lifecycle-lib.sh, so that neither case nears the runner's per-case
# watchdog).
#
# run.json has ONE writer at a time: the run lock is taken for every write,
# the state is READ inside it, a lock that cannot be acquired is a 75 naming
# its owner and is never reclaimed, and the EXIT trap releases it on every
# error path. The astra driver owns its turn: it reserves and launches in ONE
# critical section and forwards TERM to the wrapper, and a driver killed with
# -9 leaves a running entry that the next subcommand recovers by the wrapper's
# receipt.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"
# shellcheck source=council-lifecycle-lib.sh
. "$TESTS_DIR/council-lifecycle-lib.sh"

# =============================================================================
# 1. the lock: wait, read inside, write once; 75 without reclaiming; release
# =============================================================================
setup_run 2026-10-18-lock
sleep 30 &
HOLDER=$!
mkdir "$RD/.lock"
printf 'pid=%s\nlstart=%s\ncommand=the test\n' "$HOLDER" "$(LC_ALL=C "$REAL_PS" -o lstart= -p "$HOLDER")" >"$RD/.lock/owner"
printf '{}\n' >"$SANDBOX/agent-w.jsonl"
bash "$COUNCIL" record-agent "$RID" agent-w "$SANDBOX/agent-w.jsonl" >"$SANDBOX/ra.out" 2>"$SANDBOX/ra.err" &
RA=$!
sleep 1
kill -0 "$RA" 2>/dev/null || fail "record-agent did not wait for the held lock"
assert_json "$RJ" '.agents == []'
# A change made by the lock's owner while record-agent waits…
jq '.marker = "escrito por el dueño del lock"' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
rm -rf "$RD/.lock"
RC=0
wait "$RA" || RC=$?
assert_rc 0 "record-agent after the lock was released"
# …survives record-agent's write: it read the state INSIDE the lock.
assert_json "$RJ" '.marker == "escrito por el dueño del lock" and (.agents | length) == 1 and .agents[0].agent_id == "agent-w"'
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true

# Not acquired in time → 75 naming the lock and its owner, never reclaimed.
mkdir "$RD/.lock"
printf 'pid=4242\nlstart=Sun Oct 18 00:00:00 2026\ncommand=council.sh seal other\n' >"$RD/.lock/owner"
run env TANDEM_COUNCIL_LOCK_TIMEOUT=1 bash "$COUNCIL" seal "$RID" brief
assert_rc 75 "lock not acquired"
assert_file_contains "$ERR" "run lock not acquired within 1s: $RD/.lock"
assert_file_contains "$ERR" "pid=4242"
assert_file_contains "$ERR" "never reclaimed automatically"
[ -d "$RD/.lock" ] || fail "a held lock was reclaimed"
assert_file_contains "$RD/.lock/owner" "pid=4242"
rm -rf "$RD/.lock"
# The EXIT trap releases it on the error paths.
council stage "$RID" cross B
assert_rc 1 "stage with a missing input"
assert_no_file "$RD/.lock"
council stage "$RID" round-1 A
assert_rc 64 "stage of a round for the leader"
assert_no_file "$RD/.lock"
council astra "$RID" propose
assert_rc 1 "astra with nothing staged"
assert_no_file "$RD/.lock"

# =============================================================================
# 2. the reservation and record-agent both survive, overlapping astra's close
# =============================================================================
setup_run 2026-10-18-overlap
council stage "$RID" propose B
env CODEX_STUB_SLEEP=2 bash "$COUNCIL" astra "$RID" propose >"$SANDBOX/ov.out" 2>"$SANDBOX/ov.err" &
DRV=$!
wait_registered 0
assert_json "$RJ" '.astra_turns[0].estado == "running"'
# The test holds the lock while the turn runs: astra's CLOSE must wait for it.
mkdir "$RD/.lock"
printf 'pid=%s\ncommand=the test\n' "$$" >"$RD/.lock/owner"
wait_until "the wrapper's receipt" "[ -f \"\$SD/\$KEY.t1.ok\" ]"
wait_gone "$WPID"
printf '{}\n' >"$SANDBOX/agent-ov.jsonl"
bash "$COUNCIL" record-agent "$RID" agent-ov "$SANDBOX/agent-ov.jsonl" >"$SANDBOX/ra2.out" 2>"$SANDBOX/ra2.err" &
RA=$!
sleep 0.5
assert_json "$RJ" '.astra_turns[0].estado == "running" and .agents == []'
rm -rf "$RD/.lock"
RC=0
wait "$DRV" || RC=$?
assert_rc 0 "astra's close after the lock was released"
RC=0
wait "$RA" || RC=$?
assert_rc 0 "record-agent queued behind the same lock"
assert_json "$RJ" '.astra_turns | length == 1 and .[0].estado == "done" and .[0].turno == 1'
assert_json "$RJ" '.agents | length == 1 and .[0].agent_id == "agent-ov"'

# =============================================================================
# 3. TERM to the driver: forwarded, the resistant descendant reaped, interrupted
# =============================================================================
setup_run 2026-10-18-term
council stage "$RID" propose B
export CODEX_STUB_HANG_PIDFILE="$SANDBOX/resistant.pid"
env CODEX_STUB_SCENARIO=hang CODEX_STUB_HANG_SECONDS=600 CODEX_STUB_HANG_RESISTANT=1 \
  bash "$COUNCIL" astra "$RID" propose >"$SANDBOX/term.out" 2>"$SANDBOX/term.err" &
DRV=$!
wait_registered 0
wait_until "the resistant descendant" "[ -s \"\$CODEX_STUB_HANG_PIDFILE\" ]"
RESIST="$(cat "$CODEX_STUB_HANG_PIDFILE")"
kill -TERM "$DRV"
RC=0
wait "$DRV" || RC=$?
assert_rc 143 "the driver after TERM"
wait_gone "$WPID"
wait_gone "$RESIST"
assert_json "$RJ" '.astra_turns[0].estado == "interrupted" and .astra_turns[0].turno == 1'
assert_no_file "$RD/.lock"
unset CODEX_STUB_HANG_PIDFILE

# =============================================================================
# 4. kill -9 of the driver, wrapper alive: running; recovered done and published
# =============================================================================
setup_run 2026-10-18-kill
ready_to_publish
printf 'Propuesta de B\nENTREGA: PROPUESTA\n' >"$SANDBOX/kill-reply.txt"
env CODEX_STUB_SLEEP=1 CODEX_STUB_REPLY_FILE="$SANDBOX/kill-reply.txt" \
  bash "$COUNCIL" astra "$RID" propose >"$SANDBOX/kill.out" 2>"$SANDBOX/kill.err" &
DRV=$!
wait_registered 0
kill -9 "$DRV"
wait "$DRV" 2>/dev/null || true
assert_json "$RJ" '.astra_turns[0].estado == "running"'
wait_gone "$WPID"
council publish "$RID" propose
assert_rc 0 "publish recovers the orphaned turn and publishes it"
assert_json "$RJ" '.astra_turns[0] | .estado == "done" and .recuperado == true and .turno == 1
  and .resolucion == "recuperada automáticamente"'
cmp -s "$SD/$KEY.t1.reply.txt" "$DOC/1-propuestas/B.md" || fail "the recovered turn is not what was published"

note "council lifecycle: one writer under the lock, 75 never reclaimed, TERM forwarded, kill -9 recovered by receipt"
