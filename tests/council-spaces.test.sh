#!/usr/bin/env bash
# council.sh with spaces in BOTH the project path and TANDEM_COUNCIL_DIR — a
# whole propose phase, end to end: init, the leader's seal, the two stages, a
# real Astra turn through the wrappers, Fable's capture and the publication —
# and then the visual report of what was published (report).
# A path that travelled through a space-separated string would be cut at its
# first space and the paid answers would never reach DOC_DIR (code review of
# M39, round 1); every path of the run must survive word splitting.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROJ="$SANDBOX/My Project"
make_repo "$PROJ"
export CLAUDE_PROJECT_DIR="$PROJ"
export TANDEM_COUNCIL_DIR="docs/my council"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed settings.json"
export CODEX_STUB_SCENARIO=ok
COUNCIL="$SCRIPTS/council.sh"
FX="$REPO_ROOT/tests/fixtures/council"
RID=2026-10-18-spaces
DOC="$PROJ/docs/my council/$RID"
RD="$PROJ/.tandem/state/council/runs/$RID"
RJ="$RD/run.json"
SD="$PROJ/.tandem/state/council"

council() { run bash "$COUNCIL" "$@"; }

council init "$RID"
assert_rc 0 "init under a project path with a space"
assert_file_contains "$OUT" "DOC_DIR: $DOC"
[ -d "$DOC" ] || fail "DOC_DIR was not created at the spaced path: $DOC"
jq '.letters = {A: "lider", B: "astra", C: "fable"}' "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"
printf '# Brief\n\nObjetivo: medible\n' >"$DOC/brief.md"
council seal "$RID" brief
assert_rc 0 "seal brief"
printf 'Propuesta del líder\nENTREGA: PROPUESTA\n' >"$RD/sealed/propose.md"
council seal "$RID" propose
assert_rc 0 "seal propose"
council stage "$RID" propose B
assert_rc 0 "stage Astra"
assert_eq "$DOC/prompts/propose-B.a1.md" "$(cat "$OUT")" "the staged path keeps its spaces"
council stage "$RID" propose C
assert_rc 0 "stage Fable"

printf 'Propuesta de B\nENTREGA: PROPUESTA\n' >"$SANDBOX/astra reply.txt"
run env CODEX_STUB_REPLY_FILE="$SANDBOX/astra reply.txt" bash "$COUNCIL" astra "$RID" propose
assert_rc 0 "an Astra turn under the spaced paths"
assert_json "$RJ" '.astra_turns[0] | .estado == "done" and .turno == 1'
KEY="$(tkey "council-$RID-g1")"
assert_file "$SD/$KEY.t1.ok"

cp "$FX/subagent-transcript.jsonl" "$SANDBOX/fable agent.jsonl"
council record-agent "$RID" agent-spaces "$SANDBOX/fable agent.jsonl"
assert_rc 0 "record an agent whose transcript path has a space"
council capture "$RID" propose
assert_rc 0 "capture under the spaced paths"

council publish "$RID" propose
assert_rc 0 "publish under the spaced paths"
cmp -s "$RD/sealed/propose.md" "$DOC/1-propuestas/A.md" || fail "the leader's proposal was not published at the spaced path"
cmp -s "$SD/$KEY.t1.reply.txt" "$DOC/1-propuestas/B.md" || fail "Astra's answer was not published at the spaced path"
cmp -s "$FX/expected-reply.txt" "$DOC/1-propuestas/C.md" || fail "Fable's answer was not published at the spaced path"
# Nothing was left behind next to the destinations, and nothing escaped them.
for left in "$DOC/1-propuestas"/.publish.*; do
  [ -e "$left" ] && fail "a publication temp file was left behind: $left"
done
assert_no_file "$PROJ/docs/my"
assert_json "$RJ" '[.publications[] | select(.fase == "propose")] | length == 3'

# The visual report (A7 of M40): its snapshot, its temp file and its page all
# live under the spaced paths.
printf '# Informe del consejo\n\n## Resumen ejecutivo\n\nUn informe de prueba.\n' >"$DOC/informe.md"
printf '# Estrategia\n\nEscrita a mano para la prueba.\n' >"$DOC/estrategia-final.md"
council status "$RID" --metadata
assert_rc 1 "status --metadata under the spaced paths (no complete round yet)"
assert_file "$DOC/metadatos.md"
assert_file_contains "$OUT" "PHASE: informe (escrito; falta informe.html: council.sh report)"
council report "$RID"
assert_rc 0 "report under the spaced paths"
assert_eq "INFORME HTML: $DOC/informe.html" "$(cat "$OUT")" "report prints the full spaced path"
assert_file "$DOC/informe.html"
LC_ALL=C sed -n 's|^<script type="application/json" id="council-data">\(.*\)</script>$|\1|p' "$DOC/informe.html" >"$SANDBOX/payload.json"
assert_json "$SANDBOX/payload.json" '.schema == 1 and (.docs | keys) == ["1-propuestas/A.md", "1-propuestas/B.md",
  "1-propuestas/C.md", "brief.md", "estrategia-final.md", "informe.md", "metadatos.md"]'
jq -j '.docs["1-propuestas/C.md"]' "$SANDBOX/payload.json" >"$SANDBOX/embedded C.md"
cmp -s "$FX/expected-reply.txt" "$SANDBOX/embedded C.md" || fail "Fable's published answer was not embedded byte for byte"
for left in "$DOC"/.informe.html.* "$RD"/.report.*; do
  [ -e "$left" ] && fail "a report temp was left behind: $left"
done
council status "$RID"
assert_file_contains "$OUT" "PHASE: informe (escrito)"

note "council under spaced paths: init, seals, stage, astra, capture, publish and report all keep the full path"
