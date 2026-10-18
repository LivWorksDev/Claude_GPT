#!/usr/bin/env bash
# council.sh — the lifecycle of an Astra turn, part 2 of A5b (part 1 is
# council-lifecycle.test.sh; the shared preamble lives in
# council-lifecycle-lib.sh).
#
# Liveness is decided by process identity (pid + lstart) and by the three argv
# signatures of the turn — never by a pid having died — and the scan never
# counts the recovering command itself: a direct astra recovers an orphaned
# entry by its receipt and launches. A rejected reply whose bytes equal
# last.txt is interrupted, never published. When in doubt, `bloqueada`, and
# only a person unblocks it — also after a kill -9 inside the critical section,
# which orphans the lock instead of leaving an unregistered launch.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"
# shellcheck source=council-lifecycle-lib.sh
. "$TESTS_DIR/council-lifecycle-lib.sh"

# =============================================================================
# 5. 75 while the wrapper lives; then a DIRECT astra recovers and launches;
#    then a wrong-thread reply with last.txt's bytes is interrupted
# =============================================================================
setup_run 2026-10-18-direct
ready_to_publish
printf 'Propuesta de B sin cierre (a1)\n' >"$SANDBOX/a1.txt"
env CODEX_STUB_SLEEP=3 CODEX_STUB_REPLY_FILE="$SANDBOX/a1.txt" \
  bash "$COUNCIL" astra "$RID" propose >"$SANDBOX/d1.out" 2>"$SANDBOX/d1.err" &
DRV=$!
wait_registered 0
kill -9 "$DRV"
wait "$DRV" 2>/dev/null || true
council astra "$RID" propose
assert_rc 75 "a second astra while the wrapper lives"
assert_file_contains "$ERR" "is still alive"
assert_json "$RJ" '.astra_turns | length == 1 and .[0].estado == "running"'
wait_gone "$WPID"
# A plain stage leaves the entry to its owner: no recovery happens here.
council stage "$RID" propose B
assert_rc 0 "stage the retry"
assert_json "$RJ" '.astra_turns[0].estado == "running"'
# No status before: astra itself recovers a1 by its receipt — the scan counts
# neither itself nor its probes — and launches a2.
printf 'Propuesta de B sin cierre (a2)\n' >"$SANDBOX/a2.txt"
run env CODEX_STUB_REPLY_FILE="$SANDBOX/a2.txt" bash "$COUNCIL" astra "$RID" propose
assert_rc 0 "a direct astra after every process of the first launch exited"
assert_json "$RJ" '.astra_turns[0] | .estado == "done" and .recuperado == true and .turno == 1'
assert_json "$RJ" '.astra_turns[1] | .estado == "done" and .intento == 2 and .turno == 2'
# The driver dies again, and the wrapper REJECTS its turn (wrong thread) with
# reply bytes identical to the current last.txt: no receipt → interrupted.
council stage "$RID" propose B --reminder
assert_rc 0 "stage the reminder"
cp "$SD/$KEY.last.txt" "$SANDBOX/same-bytes.txt"
env CODEX_STUB_SCENARIO=resume-fallback CODEX_STUB_THREAD_ID_2=thr_elsewhere CODEX_STUB_SLEEP=1 \
  CODEX_STUB_REPLY_FILE="$SANDBOX/same-bytes.txt" \
  bash "$COUNCIL" astra "$RID" propose --reminder >"$SANDBOX/d3.out" 2>"$SANDBOX/d3.err" &
DRV=$!
wait_registered 2
kill -9 "$DRV"
wait "$DRV" 2>/dev/null || true
wait_gone "$WPID"
cmp -s "$SD/$KEY.t3.reply.txt" "$SD/$KEY.last.txt" || fail "the rejected reply should repeat last.txt's bytes"
assert_no_file "$SD/$KEY.t3.ok"
council status "$RID"
assert_json "$RJ" '.astra_turns[2] | .tipo == "recordatorio" and .estado == "interrupted" and .turno == 3
  and .nota == "turno sin recibo: rechazado o cortado"'
council publish "$RID" propose
assert_rc 0 "publish the current attempt"
cmp -s "$SD/$KEY.t2.reply.txt" "$DOC/1-propuestas/B.md" \
  || fail "an interrupted reminder must never be published, however its bytes look"

# =============================================================================
# 6. argv signatures, unknown liveness, unblock
# =============================================================================
setup_run 2026-10-18-sig
council stage "$RID" propose B
dead_pid
inject_entry running 0 feedfacefeedface
# codex itself, orphaned: a process whose argv names the turn's reply.txt.
( exec -a "fake-codex --output-last-message $SD/$KEY.t1.reply.txt" sleep 30 ) &
FAKE=$!
council astra "$RID" propose
assert_rc 75 "a process naming the turn's reply.txt is alive"
kill "$FAKE" 2>/dev/null || true
wait "$FAKE" 2>/dev/null || true
# A survivor of the original launch, identified by its token alone.
( exec -a "council-astra-feedfacefeedface" sleep 30 ) &
SURV=$!
council astra "$RID" propose
assert_rc 75 "a survivor carrying the launch token"
kill "$SURV" 2>/dev/null || true
wait "$SURV" 2>/dev/null || true
# Liveness cannot be established (ps broken) → bloqueada, and 65.
mkdir -p "$SANDBOX/badps"
printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/badps/ps"
chmod +x "$SANDBOX/badps/ps"
N_BEFORE="$(stub_n)"
run env PATH="$SANDBOX/badps:$PATH" bash "$COUNCIL" astra "$RID" propose
assert_rc 65 "liveness impossible to establish"
assert_file_contains "$ERR" "bloqueada"
assert_json "$RJ" '.astra_turns[0] | .estado == "bloqueada" and (.nota | startswith("liveness imposible"))'
council astra "$RID" propose
assert_rc 65 "a bloqueada entry blocks every launch on its target"
assert_eq "$N_BEFORE" "$(stub_n)" "nothing launched over a blocked target"
# unblock: 75 while a signature lives…
( exec -a "council-astra-feedfacefeedface" sleep 30 ) &
SURV=$!
council unblock "$RID" "$TARGET"
assert_rc 75 "unblock while the token lives"
kill "$SURV" 2>/dev/null || true
wait "$SURV" 2>/dev/null || true
council unblock "$RID" nope
assert_rc 64 "unblock of a target the run does not have"
# …then the same evidence: counter unchanged → interrupted, resolved by hand.
council unblock "$RID" "$TARGET"
assert_rc 0 "unblock"
assert_json "$RJ" '.astra_turns[0] | .estado == "interrupted" and .resolucion == "resuelta a mano"'
# Advanced by one WITHOUT a receipt → interrupted; by more than one → stays
# bloqueada (65) for a person to review.
printf '1\n' >"$SD/$KEY.turn"
inject_entry bloqueada 0 cafecafecafecafe nowrapper
council unblock "$RID" "$TARGET"
assert_rc 0 "unblock of a turn without its receipt"
assert_json "$RJ" '.astra_turns[1] | .estado == "interrupted" and .turno == 1 and .resolucion == "resuelta a mano"'
printf '3\n' >"$SD/$KEY.turn"
inject_entry bloqueada 1 abbaabbaabbaabba nowrapper
council unblock "$RID" "$TARGET"
assert_rc 65 "a counter that advanced more than one"
assert_json "$RJ" '.astra_turns[2].estado == "bloqueada" and (.astra_turns[2].nota | contains("más de uno"))'

# =============================================================================
# 7. kill -9 INSIDE the critical section: a deterministic pause between launch
#    and registration (a fake ps that blocks on the child's lstart)
# =============================================================================
setup_run 2026-10-18-pause
council stage "$RID" propose B
mkdir -p "$SANDBOX/pauseps"
cat >"$SANDBOX/pauseps/ps" <<EOF
#!/bin/bash
# Blocks ONCE on an lstart query about a pid that is not an ancestor of the
# caller — the driver asking for its freshly forked child's start time.
case " \$* " in
  *" lstart= "*)
    pid="" prev=""
    for a in "\$@"; do [ "\$prev" = "-p" ] && pid="\$a"; prev="\$a"; done
    if [ -n "\$pid" ] && [ ! -e "$SANDBOX/pause.pid" ]; then
      anc=0 p="\$PPID" i=0
      while [ -n "\$p" ] && [ "\$p" -gt 1 ] && [ "\$i" -lt 30 ]; do
        [ "\$p" = "\$pid" ] && { anc=1; break; }
        p="\$("$REAL_PS" -o ppid= -p "\$p" 2>/dev/null | tr -d ' ')"
        i=\$((i + 1))
      done
      if [ "\$anc" = 0 ]; then
        printf '%s\n' "\$\$" >"$SANDBOX/pause.pid"
        exec sleep 600
      fi
    fi
    ;;
esac
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SANDBOX/pauseps/ps"
# The stub's records start from zero here, so "one exec" means THIS launch's.
rm -f "$CODEX_STUB_LOG".*
env PATH="$SANDBOX/pauseps:$PATH" CODEX_STUB_SLEEP=6 \
  bash "$COUNCIL" astra "$RID" propose >"$SANDBOX/pause.out" 2>"$SANDBOX/pause.err" &
DRV=$!
wait_until "the pause between launch and registration" "[ -s \"\$SANDBOX/pause.pid\" ]"
assert_json "$RJ" '.astra_turns[0] | .estado == "running" and .wrapper == null'
[ -d "$RD/.lock" ] || fail "the reservation must still hold the lock during the pause"
kill -9 "$DRV"
wait "$DRV" 2>/dev/null || true
kill "$(cat "$SANDBOX/pause.pid")" 2>/dev/null || true
# The lock is orphaned: every subcommand of the run answers 75…
[ -d "$RD/.lock" ] || fail "a kill -9 inside the critical section orphans the lock"
run env TANDEM_COUNCIL_LOCK_TIMEOUT=1 bash "$COUNCIL" astra "$RID" propose
assert_rc 75 "astra over an orphaned lock"
wait_until "the child's codex invocation" "[ -f \"\$CODEX_STUB_LOG.n\" ]"
assert_eq "1" "$(stub_n)" "one single exec: the second astra launched nothing"
# …until a person cleans it: the entry with no wrapper registered is bloqueada.
rm -rf "$RD/.lock"
council astra "$RID" propose
assert_rc 65 "the unregistered launch is bloqueada"
assert_json "$RJ" '.astra_turns[0] | .estado == "bloqueada" and (.nota | contains("sin wrapper registrado"))'
council unblock "$RID" "$TARGET"
assert_rc 75 "unblock while the unregistered wrapper still runs"
# Once every process of that launch has exited, its receipt decides.
wait_until "the unregistered turn's receipt" "[ -f \"\$SD/\$KEY.t1.ok\" ]"
I=0
while [ "$I" -lt 50 ]; do
  council unblock "$RID" "$TARGET"
  [ "$RC" != "75" ] && break
  sleep 0.2
  I=$((I + 1))
done
assert_rc 0 "unblock once the launch is gone"
assert_json "$RJ" '.astra_turns[0] | .estado == "done" and .recuperado == true and .turno == 1
  and .resolucion == "resuelta a mano"'
assert_eq "1" "$(stub_n)" "still one single exec"

note "council recovery: direct retry by receipt, same-bytes rejection interrupted, three argv signatures, bloqueada until unblock, kill -9 inside the critical section"
