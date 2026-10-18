#!/usr/bin/env bash
# council.sh capture — Fable's channel: the subagent transcript the harness
# links as the Agent's output_file, read from cursor + 1.
#
# The fixtures are DERIVED FROM REAL TRANSCRIPTS (tests/fixtures/council/README.md):
# the handback answer must come out byte for byte, and the usage must be
# deduplicated by message.id keeping the LAST line of each message — a message
# spans several lines, and in a long message the earlier ones carry the PARTIAL
# streaming counts (the streaming fixture: [8,8,8,330]), so neither the first
# line nor the naive per-line sum is the real usage; both differences are
# asserted with literals. The continuation and
# the text-block answer are SYNTHETIC variants and are labelled as such: the
# real canary validates them. A foreign model is a 65 with nothing written and
# the cursor intact; a dated pin is accepted; no answer is a 1; --manual is the
# visible degradation; a Read under the run's directories is an anomaly that
# never blocks; and a capture beyond the phase's cap is a 65.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
FX="$REPO_ROOT/tests/fixtures/council"
REAL="$FX/subagent-transcript.jsonl"
assert_file "$REAL"
assert_file "$FX/expected-reply.txt"

council() { run bash "$COUNCIL" "$@"; }

# capture_run <run-id> <transcript> — a run whose Fable seat (letter B) has its
# propose prompt staged and an agent recorded on a COPY of <transcript>.
capture_run() {
  RID="$1"
  DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
  RD="$CLAUDE_PROJECT_DIR/.tandem/state/council/runs/$RID"
  RJ="$RD/run.json"
  TR="$SANDBOX/$RID.agent.jsonl"
  council init "$RID"
  assert_rc 0 "init $RID"
  jq '.letters = {A: "lider", B: "fable", C: "astra"}' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
  printf '# Brief\n\nObjetivo: x\n' >"$DOC/brief.md"
  council seal "$RID" brief
  assert_rc 0 "seal brief $RID"
  printf 'Propuesta sellada del líder\nENTREGA: PROPUESTA\n' >"$RD/sealed/propose.md"
  council seal "$RID" propose
  assert_rc 0 "seal propose $RID"
  council stage "$RID" propose B
  assert_rc 0 "stage propose B $RID"
  PROMPT="$(cat "$OUT")"
  cp "$2" "$TR"
  council record-agent "$RID" "agent-$RID" "$TR"
  assert_rc 0 "record-agent $RID"
}

reply_of() { printf '%s' "$RD/fable.propose.a1${1:-}.reply.md"; }
usage_of() { printf '%s' "$RD/fable.propose.a1${1:-}.usage.json"; }

# =============================================================================
# 1. the real fixture: byte-faithful handback, usage deduplicated by message.id
# =============================================================================
capture_run 2026-10-18-real "$REAL"
council capture "$RID" propose
assert_rc 0 "capture of the real transcript"
assert_eq "$(reply_of)" "$(cat "$OUT")" "capture prints the answer's path"
cmp -s "$FX/expected-reply.txt" "$(reply_of)" || fail "the handback answer is not byte-for-byte input.message"
# The per-message.id sum, computed here independently of the script, from the
# LAST line of each message (jq's group_by is stable, so .[-1] is the last line
# in file order). In this short capture every line of a message carries the
# same usage; the streaming fixture below is the one that tells first from last…
WANT_USAGE="$(jq -sc '[.[] | select(.type == "assistant")] | group_by(.message.id) | map(.[-1].message.usage)
  | {input_tokens: (map(.input_tokens) | add), cache_read_input_tokens: (map(.cache_read_input_tokens) | add),
     cache_creation_input_tokens: (map(.cache_creation_input_tokens) | add), output_tokens: (map(.output_tokens) | add)}' "$REAL")"
assert_json "$(usage_of)" ". == $WANT_USAGE"
assert_json "$(usage_of)" '. == {input_tokens: 14, cache_read_input_tokens: 673606, cache_creation_input_tokens: 49175, output_tokens: 56}'
# …and it is NOT the naive per-line sum: the transcript repeats each usage.
NAIVE_OUT="$(jq -s '[.[] | select(.type == "assistant") | .message.usage.output_tokens] | add' "$REAL")"
assert_eq "94" "$NAIVE_OUT" "naive per-line output_tokens of the real fixture"
assert_json "$(usage_of)" ".output_tokens != $NAIVE_OUT"
assert_json "$RD/fable.cursor" ". == {agent_id: \"agent-$RID\", line: 38}"
assert_json "$RJ" '.captures | length == 1'
assert_json "$RJ" '.captures[0] | .fase == "propose" and .intento == 1 and .tipo == "sustantivo"
  and .captura == "capturado" and .modelo == "verificado" and .modelos == ["claude-fable-5-1"]
  and .desde == 1 and .hasta == 38'

# --- a SECOND real transcript, with streaming usage ---------------------------
# A long implementer run of the same host (tests/fixtures/council/README.md):
# each message spans several lines and only its LAST line carries the final
# usage — output_tokens per message [8,8,8,330] · [16,16,16,341] · [16,16,260] ·
# [8,8,4217]. The literals below are written here, never read back from the
# script: last line per message = 5148, first line = 48, naive per-line = 5268.
STREAM="$FX/subagent-transcript-streaming.jsonl"
assert_file "$STREAM"
assert_eq "48" "$(jq -s '[.[] | select(.type == "assistant")] | group_by(.message.id) | map(.[0].message.usage.output_tokens) | add' "$STREAM")" \
  "first-line output_tokens of the streaming fixture"
assert_eq "5268" "$(jq -s '[.[] | select(.type == "assistant") | .message.usage.output_tokens] | add' "$STREAM")" \
  "naive per-line output_tokens of the streaming fixture"
SAVE_RID="$RID" SAVE_DOC="$DOC" SAVE_RD="$RD" SAVE_RJ="$RJ" SAVE_TR="$TR"
capture_run 2026-10-18-streaming "$STREAM"
council capture "$RID" propose
assert_rc 0 "capture of the streaming transcript"
cmp -s "$FX/expected-reply.txt" "$(reply_of)" || fail "the streaming handback answer is not byte-for-byte input.message"
assert_json "$(usage_of)" '. == {input_tokens: 8, cache_read_input_tokens: 886207, cache_creation_input_tokens: 34997, output_tokens: 5148}'
assert_json "$RJ" '.captures[0].modelos == ["claude-fable-5-1"]'
RID="$SAVE_RID" DOC="$SAVE_DOC" RD="$SAVE_RD" RJ="$SAVE_RJ" TR="$SAVE_TR"

# A second capture of the same attempt is beyond the cap of the phase.
council capture "$RID" propose
assert_rc 65 "a second capture of the same attempt"
assert_file_contains "$ERR" "already captured — beyond the cap of the phase"
assert_json "$RJ" '.captures | length == 1'

# No answer in the new lines → 1, and the cursor does not move.
council stage "$RID" propose B --reminder
assert_rc 0 "stage the reminder (the handback lacks ENTREGA: PROPUESTA)"
assert_file_contains "$DOC/prompts/propose-B.a1.reminder.md" '- la última línea exacta `ENTREGA: PROPUESTA`'
council capture "$RID" propose --reminder
assert_rc 1 "no new line, no answer"
assert_file_contains "$ERR" "no answer in the transcript slice"
assert_file_contains "$ERR" "$(reply_of .reminder)"
assert_json "$RD/fable.cursor" '.line == 38'
assert_no_file "$(reply_of .reminder)"

# --- the SYNTHETIC continuation: the second turn reads ONLY the new lines ----
cat "$FX/synthetic-continuation.jsonl" >>"$TR"
council capture "$RID" propose --reminder
assert_rc 0 "capture of the (synthetic) continuation"
cmp -s "$FX/synthetic-continuation-reply.txt" "$(reply_of .reminder)" \
  || fail "the continuation's answer is not its own handback"
assert_json "$(usage_of .reminder)" '. == {input_tokens: 3, cache_read_input_tokens: 190000, cache_creation_input_tokens: 500, output_tokens: 11}'
assert_json "$RD/fable.cursor" '.line == 42'
assert_json "$RJ" '.captures[1] | .tipo == "recordatorio" and .desde == 39 and .hasta == 42'
# One reminder per phase: a second one is beyond the cap.
council capture "$RID" propose --reminder
assert_rc 65 "a second reminder capture"

# =============================================================================
# 2. a foreign model: 65, nothing written, cursor intact
# =============================================================================
jq -c 'if .type == "assistant" then .message.model = "claude-haiku-5-5" else . end' "$REAL" >"$SANDBOX/haiku.jsonl"
capture_run 2026-10-18-haiku "$SANDBOX/haiku.jsonl"
cp "$RD/fable.cursor" "$SANDBOX/cursor.before"
council capture "$RID" propose
assert_rc 65 "every line answered by the real model of the source transcript"
assert_file_contains "$ERR" '["claude-haiku-5-5"]'
assert_file_contains "$ERR" "instead of the seat's pin claude-fable-5-1"
assert_no_file "$(reply_of)"
assert_no_file "$(usage_of)"
cmp -s "$SANDBOX/cursor.before" "$RD/fable.cursor" || fail "the cursor moved on a foreign model"
assert_json "$RJ" '.captures | length == 0'

# One single foreign line is enough (a silent model switch mid-turn).
jq -c 'if .message.id == "msg_011Cg9bFfw3NJr1LteuY7bnF" and (.message.content[0].type == "thinking") then .message.model = "claude-haiku-5-5" else . end' \
  "$REAL" >"$SANDBOX/one-line.jsonl"
cp "$SANDBOX/one-line.jsonl" "$SANDBOX/one-line.agent.jsonl"
council record-agent "$RID" agent-one-line "$SANDBOX/one-line.agent.jsonl"
assert_rc 0 "record the second agent"
council capture "$RID" propose
assert_rc 65 "one foreign line"
assert_no_file "$(reply_of)"
assert_json "$RD/fable.cursor" '. == {agent_id: "agent-one-line", line: 0}'

# An assistant line with NO model at all is no proof of the pin either.
jq -c 'if .type == "assistant" and .message.id == "msg_011Cg9as56vFbhWqwxshw3ra" then del(.message.model) else . end' \
  "$REAL" >"$SANDBOX/no-model.agent.jsonl"
council record-agent "$RID" agent-no-model "$SANDBOX/no-model.agent.jsonl"
council capture "$RID" propose
assert_rc 65 "an assistant line without a model"
assert_no_file "$(reply_of)"

# =============================================================================
# 3. the pin with a date suffix is the pin
# =============================================================================
jq -c 'if .type == "assistant" then .message.model = "claude-fable-5-1-20261018" else . end' "$REAL" >"$SANDBOX/dated.jsonl"
capture_run 2026-10-18-dated "$SANDBOX/dated.jsonl"
council capture "$RID" propose
assert_rc 0 "the dated pin"
cmp -s "$FX/expected-reply.txt" "$(reply_of)" || fail "the dated-pin capture changed the answer"
assert_json "$RJ" '.captures[0].modelos == ["claude-fable-5-1-20261018"]'
# …but a dated OTHER model, or a non-date suffix, is not.
jq -c 'if .type == "assistant" then .message.model = "claude-fable-5-1-fast" else . end' "$REAL" >"$SANDBOX/suffix.agent.jsonl"
council record-agent "$RID" agent-suffix "$SANDBOX/suffix.agent.jsonl"
council stage "$RID" propose B --reminder
council capture "$RID" propose --reminder
assert_rc 65 "a suffix that is not an 8-digit date"

# =============================================================================
# 4. the SYNTHETIC text-block answer (no SubagentHandback at all)
# =============================================================================
capture_run 2026-10-18-text "$FX/synthetic-text-reply.jsonl"
council capture "$RID" propose
assert_rc 0 "the text-block branch"
cmp -s "$FX/synthetic-text-reply-expected.txt" "$(reply_of)" \
  || fail "the text branch must join the text blocks of the LAST message.id with text and no tool_use"
assert_json "$(usage_of)" '. == {input_tokens: 4, cache_read_input_tokens: 80700, cache_creation_input_tokens: 1000, output_tokens: 14}'

# =============================================================================
# 5. --manual: the visible degradation after a capture that exits 1
# =============================================================================
{ cat "$REAL"; printf 'this line is not json\n'; } >"$SANDBOX/garbled.jsonl"
capture_run 2026-10-18-manual "$SANDBOX/garbled.jsonl"
council capture "$RID" propose
assert_rc 1 "an unrecognised transcript"
assert_file_contains "$ERR" "format not recognised"
assert_file_contains "$ERR" "council.sh capture $RID propose --manual"
assert_no_file "$(reply_of)"
printf 'Respuesta transcrita a mano por el líder\nENTREGA: PROPUESTA\n' >"$(reply_of)"
council capture "$RID" propose --manual
assert_rc 0 "manual transcription"
assert_json "$RJ" '.captures[0] | .captura == "transcrito" and .modelo == "no verificado" and .uso == null'
assert_no_file "$(usage_of)"
assert_json "$RD/fable.cursor" '.line == 39'

# =============================================================================
# 6. a Read under the run's directories is an anomaly, never a block
# =============================================================================
# SYNTHETIC lines, built from the fixture's own WebFetch line (12): one Read of
# a published answer (forbidden) and one of the seat's own phase file (fine).
mk_read() {
  # mk_read <path> <id> — one assistant tool_use line reading <path>.
  sed -n 12p "$REAL" | jq -c --arg p "$1" --arg id "$2" \
    '.message.id = $id | .message.content[0].name = "Read"
     | .message.content[0].input = {file_path: $p} | .wireToolInputs = {}'
}
R6=2026-10-18-reads
D6="$CLAUDE_PROJECT_DIR/docs/council/$R6"
{
  sed -n '1,35p' "$REAL"
  mk_read "$D6/1-propuestas/A.md" msg_SYNTHETIC_read_0001
  mk_read "$D6/prompts/propose-B.a1.md" msg_SYNTHETIC_read_0002
  sed -n '36,38p' "$REAL"
} >"$SANDBOX/reads.jsonl"
capture_run "$R6" "$SANDBOX/reads.jsonl"
assert_eq "$D6/prompts/propose-B.a1.md" "$PROMPT" "the staged prompt path"
council capture "$RID" propose
assert_rc 0 "a forbidden Read never blocks the capture"
cmp -s "$FX/expected-reply.txt" "$(reply_of)" || fail "the read audit changed the answer"
assert_json "$RJ" '.anomalies | length == 1'
assert_json "$RJ" ".anomalies[0] | .tipo == \"lectura-fuera-de-alcance\" and .asiento == \"fable\"
  and .herramienta == \"Read\" and .rutas == [\"$D6/1-propuestas/A.md\"]"

note "council capture: real fixture byte-exact and deduplicated, foreign model 65, dated pin, synthetic continuation and text branch, --manual, read audit, caps"
