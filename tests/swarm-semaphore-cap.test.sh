#!/usr/bin/env bash
# The cap, without any chunking: four seats of one run launched AT ONCE with
# TANDEM_ULTRA_CONCURRENCY=2 run at most two codex turns simultaneously, because
# codex-swarm.sh queues the surplus itself.
#
# The measurement is the stub's own census of live turns (CODEX_STUB_CONC_DIR),
# never a duration: wall-clock assertions are flaky and this suite forbids them.
# Each seat gets its OWN CODEX_STUB_LOG so the stub's flat invocation counter
# cannot race.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
mkdir -p "$SANDBOX/logs"

export TANDEM_ULTRA_CONCURRENCY=2
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_SLEEP=2
export CODEX_STUB_CONC_DIR="$SANDBOX/conc"

PIDS=""
i=1
while [ "$i" -le 4 ]; do
  printf 'prompt for seat %s\n' "$i" >"$SANDBOX/s$i.txt"
  CODEX_STUB_LOG="$SANDBOX/logs/s$i" CODEX_STUB_REPLY="reply $i" \
    bash "$SCRIPTS/codex-swarm.sh" worker run-cap "s$i" "$SANDBOX/s$i.txt" \
    >"$SANDBOX/s$i.out" 2>"$SANDBOX/s$i.err" &
  PIDS="$PIDS $!"
  i=$((i + 1))
done

n=1
for p in $PIDS; do
  rc=0
  wait "$p" || rc=$?
  assert_eq "0" "$rc" "seat s$n exit code"
  n=$((n + 1))
done

# --- the cap itself ----------------------------------------------------------
# Every seat saw at most C live turns, and at least one saw exactly C: the first
# half proves the semaphore holds, the second that this test can see overlap at
# all (a semaphore that serialized everything would pass the first alone).
MAXC=0
i=1
while [ "$i" -le 4 ]; do
  f="$SANDBOX/logs/s$i.conc.1"
  assert_file "$f"
  c="$(cat "$f")"
  case "$c" in
    '' | *[!0-9]*) fail "seat s$i recorded a non-numeric turn census: [$c]" ;;
  esac
  [ "$c" -le 2 ] || fail "seat s$i saw $c simultaneous codex turns — the cap is 2"
  if [ "$c" -gt "$MAXC" ]; then MAXC="$c"; fi
  i=$((i + 1))
done
assert_eq "2" "$MAXC" "maximum simultaneous codex turns observed"

# --- the surplus really queued, and every slot came back ---------------------
UD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$(tkey run-cap)"
[ -d "$UD/.slots" ] || fail "expected the run's slot directory: $UD/.slots"
LEFT="$(find "$UD/.slots" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
assert_eq "0" "$LEFT" "slots left behind after every seat finished"

waited=0
i=1
while [ "$i" -le 4 ]; do
  if grep -F -q -- "ultra slots busy — waiting" "$SANDBOX/s$i.err"; then waited=1; fi
  i=$((i + 1))
done
[ "$waited" -eq 1 ] \
  || fail "no seat ever reported waiting for a slot — nothing was queued"

# --- and the queue changed nothing about the results -------------------------
assert_file_contains "$UD/$(tkey s1).reply.txt" "reply 1"
assert_file_contains "$UD/$(tkey s4).reply.txt" "reply 4"
assert_file_contains "$SANDBOX/s1.err" "concurrency=2"
note "4 seats, cap 2 — max observed $MAXC live turns, $LEFT slots left behind"
