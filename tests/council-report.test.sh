#!/usr/bin/env bash
# council.sh report — the visual report (informe.html), judged on a run seeded
# by hand (no model turn is needed: report reads what is on disk).
#
# A1 the contract (usage, missing run, the three outputs of step 6, the
# template's marker, no temp left behind); A2 the shape of the file (one data
# block, one fingerprint line, exactly the closed list of documents, each one
# byte for byte); A3 the facts come from the SAME grammar as ledger, status and
# metadatos.md (and write_metadata keeps its output byte for byte after the
# refactor that shares those facts); A3b the provenance of the strategy; A4 no
# text of a seat can close the data block; A6 the page is coherent with itself
# (its fingerprint and its facts come from the bytes it embeds). The freshness
# of the page and the provenance of the strategy live in
# council-report-fresh.test.sh.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
FX="$REPO_ROOT/tests/fixtures/council/report"
TPL="$REPO_ROOT/skills/council/report/informe.tpl.html"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
SD="$CLAUDE_PROJECT_DIR/.tandem/state/council"
RID=2026-10-19-report
DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
RD="$SD/runs/$RID"
RJ="$RD/run.json"
HTML="$DOC/informe.html"
PAYLOAD="$SANDBOX/payload.json"

council() { run bash "$COUNCIL" "$@"; }
rj_set() { jq "$@" "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"; }
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 <"$1" | cut -d' ' -f1; else sha256sum <"$1" | cut -d' ' -f1; fi
}
# payload_of <html> — the JSON of the data block, as the browser parses it.
payload_of() {
  LC_ALL=C sed -n 's|^<script type="application/json" id="council-data">\(.*\)</script>$|\1|p' "$1" >"$PAYLOAD"
  jq -e '.schema == 1' "$PAYLOAD" >/dev/null 2>&1 || fail "the data block of $1 is not JSON with schema 1"
}
digest_line() { LC_ALL=C sed -n 's/^<!-- tandem-council-digest: \([0-9a-f]\{64\}\) -->$/\1/p' "$1"; }

# The ledger's own parser — COUNCIL_JQ, read from the script — on a map of
# documents {path: text}: published answers only, exactly as docs_json reads them.
sq="'"
CJQ="$(LC_ALL=C awk -v start="COUNCIL_JQ=$sq" -v stop="$sq" '$0 == start { f = 1; next } f && $0 == stop { exit } f { print }' "$COUNCIL")"
[ -n "$CJQ" ] || fail "cannot read COUNCIL_JQ from council.sh"
# shellcheck disable=SC2016  # a jq program
PARSER_IN='[ to_entries[] | .key as $k | .value as $v
  | ( ($k | capture("^1-propuestas/(?<l>[A-C])\\.md$") | {author: .l, order: 1, phase: "propose"}),
      ($k | capture("^2-contrainterrogatorio/(?<l>[A-C])\\.md$") | {author: .l, order: 2, phase: "cross"}),
      ($k | capture("^rondas/r(?<n>[0-9]+)-(?<l>[A-C])\\.md$")
        | {author: .l, order: (2 + (.n | tonumber)), phase: "round-\(.n | tonumber)"}) )
  | . + {file: $k, lines: ($v | split("\n"))} ]'
ledger_objs() {
  jq -c "$CJQ"'[objections[]] | sort_by(.author, .n) | map({id, author, n, sev, title, phase, status, reason})'
}
files_map() {
  local d="$1" f acc='{}'
  for f in "$d"/1-propuestas/*.md "$d"/2-contrainterrogatorio/*.md "$d"/rondas/*.md; do
    [ -f "$f" ] || continue
    acc="$(printf '%s' "$acc" | jq -c --arg k "${f#"$d"/}" --rawfile v "$f" '. + {($k): $v}')"
  done
  printf '%s' "$acc"
}

# =============================================================================
# the seeded run: two rounds, two Astra generations, Fable captures (one of
# them transcribed by hand), reminders, a rebuild and out-of-scope reads
# =============================================================================
council init "$RID"
assert_rc 0 "init"
cp -R "$FX/doc/." "$DOC/"
K1="$(tkey "council-$RID-g1")"
K2="$(tkey "council-$RID-g2")"
rj_set --arg g1 "council-$RID-g1" --arg g2 "council-$RID-g2" '
  .created = "2026-10-19T08:00:00Z"
  | .letters = {A: "lider", B: "astra", C: "fable"}
  | .leader_model = "claude-opus-5-5"
  | .max_rounds = 2
  | .astra_targets = [$g1, $g2]
  | .agents = [
      {agent_id: "agente-1", output_file: "/transcripts/agente-1.jsonl", recorded: "2026-10-19T08:10:00Z"},
      {agent_id: "agente-2", output_file: "/transcripts/agente-2.jsonl", recorded: "2026-10-19T09:00:00Z"}]
  | .prompts = [
      {fase: "propose", letra: "B", intento: 1, recordatorio: false, historia: false},
      {fase: "cross", letra: "B", intento: 1, recordatorio: false, historia: false},
      {fase: "cross", letra: "B", intento: 2, recordatorio: false, historia: true},
      {fase: "round-1", letra: "C", intento: 1, recordatorio: true, historia: false}]
  | .astra_turns = [
      {fase: "propose", intento: 1, tipo: "sustantivo", target: $g1, estado: "done", turno: 1,
       inicio: "2026-10-19T08:10:00Z", fin: "2026-10-19T08:22:30Z", exit: 0, nota: "turno 1"},
      {fase: "cross", intento: 1, tipo: "sustantivo", target: $g1, estado: "failed", turno: 2,
       inicio: "2026-10-19T08:40:00Z", fin: "2026-10-19T08:41:00Z", exit: 1, nota: "turno sin recibo: rechazado o cortado"},
      {fase: "cross", intento: 2, tipo: "sustantivo", target: $g2, estado: "done", turno: 1, recuperado: true,
       inicio: "2026-10-19T09:00:00Z", fin: "2026-10-19T09:15:00Z", exit: 0, nota: "recibo del wrapper presente"},
      {fase: "round-1", intento: 1, tipo: "sustantivo", target: $g2, estado: "done", turno: 2,
       inicio: "2026-10-19T10:00:00Z", fin: "2026-10-19T10:20:00Z", exit: 0, nota: "turno 2"},
      {fase: "round-1", intento: 1, tipo: "recordatorio", target: $g2, estado: "interrupted", turno: null,
       inicio: "2026-10-19T10:30:00Z", fin: "2026-10-19T10:30:01Z", nota: "señal antes de lanzar: no hubo turno"},
      {fase: "round-2", intento: 1, tipo: "sustantivo", target: $g2, estado: "done", turno: 3,
       inicio: "2026-10-19T11:00:00Z", fin: "2026-10-19T11:25:00Z", exit: 0, nota: "turno 3"}]
  | .captures = [
      {fase: "propose", intento: 1, tipo: "sustantivo", captura: "capturado", modelo: "verificado",
       modelos: ["claude-fable-5-1"], mensajes: 5, sin_usage_definitivo: 2},
      {fase: "cross", intento: 1, tipo: "sustantivo", captura: "capturado", modelo: "verificado",
       modelos: ["claude-fable-5-1"], mensajes: 3, sin_usage_definitivo: 1},
      {fase: "round-1", intento: 1, tipo: "sustantivo", captura: "transcrito", modelo: "no verificado", modelos: []},
      {fase: "round-1", intento: 1, tipo: "recordatorio", captura: "capturado", modelo: "verificado",
       modelos: ["claude-fable-5-1"], mensajes: 1, sin_usage_definitivo: 0},
      {fase: "round-2", intento: 1, tipo: "sustantivo", captura: "capturado", modelo: "verificado",
       modelos: ["claude-fable-5-1-20261001"], mensajes: 4, sin_usage_definitivo: 0}]
  | .anomalies = [
      {tipo: "lectura-fuera-de-alcance", asiento: "fable", fase: "cross", intento: 1, herramienta: "Read",
       rutas: ["docs/council/x/1-propuestas/B.md", "docs/council/x/prompts/cross-B.a1.md"]},
      {tipo: "lectura-fuera-de-alcance", asiento: "astra", fase: "round-1", intento: 1, turno: 2,
       comando: "cat .tandem/state/council/runs/x/sealed/cross.md"}]'
mkdir -p "$SD"
printf '{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}\n' >"$SD/$K1.t1.usage.json"
printf '{"input_tokens":200,"output_tokens":20,"reasoning_output_tokens":5}\n' >"$SD/$K1.t2.usage.json"
printf '{"input_tokens":3000,"cached_input_tokens":2000,"output_tokens":300,"reasoning_output_tokens":50}\n' >"$SD/$K2.t1.usage.json"
printf '{"input_tokens":4000,"cached_input_tokens":3000,"output_tokens":400,"model":"no es un número"}\n' >"$SD/$K2.t2.usage.json"
printf '{"input_tokens":5000,"cached_input_tokens":4500,"output_tokens":500,"reasoning_output_tokens":70}\n' >"$SD/$K2.t3.usage.json"
for m in "$K1.t1" "$K1.t2" "$K2.t1" "$K2.t2" "$K2.t3"; do
  printf '{"role":"council","model":"gpt-6-astra","effort":"max","sandbox":"read-only"}\n' >"$SD/$m.meta.json"
done
printf '{"input_tokens":2,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":7}\n' >"$RD/fable.propose.a1.usage.json"
printf '{"input_tokens":3,"cache_read_input_tokens":20,"cache_creation_input_tokens":6,"output_tokens":8}\n' >"$RD/fable.cross.a1.usage.json"
printf '{"input_tokens":1,"cache_read_input_tokens":4,"cache_creation_input_tokens":0,"output_tokens":2}\n' >"$RD/fable.round-1.a1.reminder.usage.json"
printf '{"input_tokens":4,"cache_read_input_tokens":40,"cache_creation_input_tokens":9,"output_tokens":11}\n' >"$RD/fable.round-2.a1.usage.json"

council status "$RID" --metadata
assert_rc 0 "status --metadata on the seeded run (CONSENSO in round 2)"
assert_file "$DOC/metadatos.md"
cmp -s "$DOC/sintesis-v2.md" "$DOC/estrategia-final.md" || fail "estrategia-final.md is not the synthesis of round 2"

# A run with nothing in it: every empty branch of metadatos.md.
RID0=2026-10-19-vacio
DOC0="$CLAUDE_PROJECT_DIR/docs/council/$RID0"
council init "$RID0"
assert_rc 0 "init of the empty run"
jq '.created = "2026-10-19T07:00:00Z" | .letters = {A: "astra", B: "fable", C: "lider"} | .leader_model = "claude-opus-5-5"' \
  "$SD/runs/$RID0/run.json" >"$SANDBOX/rj0.tmp" && mv "$SANDBOX/rj0.tmp" "$SD/runs/$RID0/run.json"
printf '# Brief\n' >"$DOC0/brief.md"
council status "$RID0" --metadata
assert_rc 1 "status --metadata on the empty run"

# --- A3: write_metadata keeps its output byte for byte (the expected files were
# generated by the code of c0d8cf1, before the refactor that shares its facts
# with report) ----------------------------------------------------------------
cmp -s "$FX/metadatos.expected.md" "$DOC/metadatos.md" || {
  diff -u "$FX/metadatos.expected.md" "$DOC/metadatos.md" >&2 || true
  fail "metadatos.md of the seeded run changed"
}
cmp -s "$FX/metadatos-vacio.expected.md" "$DOC0/metadatos.md" || {
  diff -u "$FX/metadatos-vacio.expected.md" "$DOC0/metadatos.md" >&2 || true
  fail "metadatos.md of the empty run changed"
}

# =============================================================================
# A1 — the contract of report
# =============================================================================
council report
assert_rc 64 "report with no run id"
council report "$RID" de-mas
assert_rc 64 "report with one argument too many"
council report 2026-10-19-no-existe
assert_rc 1 "report on a run that does not exist"

# The three outputs of step 6: one missing at a time, then all three at once —
# every missing one is named.
mkdir -p "$SANDBOX/aside"
for f in informe.md estrategia-final.md metadatos.md; do
  mv "$DOC/$f" "$SANDBOX/aside/$f"
  council report "$RID"
  assert_rc 1 "report without $f"
  assert_file_contains "$ERR" "$DOC/$f"
  mv "$SANDBOX/aside/$f" "$DOC/$f"
done
mv "$DOC/informe.md" "$DOC/estrategia-final.md" "$DOC/metadatos.md" "$SANDBOX/aside/"
council report "$RID"
assert_rc 1 "report without any of the three outputs of step 6"
for f in informe.md estrategia-final.md metadatos.md; do assert_file_contains "$ERR" "$DOC/$f"; done
mv "$SANDBOX/aside/informe.md" "$SANDBOX/aside/estrategia-final.md" "$SANDBOX/aside/metadatos.md" "$DOC/"

# The template: exactly one marker line, or 65.
LC_ALL=C grep -vxF '<!-- COUNCIL_DATA -->' "$TPL" >"$SANDBOX/sin-marcador.html"
{ cat "$TPL"; printf '<!-- COUNCIL_DATA -->\n'; } >"$SANDBOX/dos-marcadores.html"
for t in sin-marcador dos-marcadores no-existe; do
  run env TANDEM_COUNCIL_REPORT_TEMPLATE="$SANDBOX/$t.html" bash "$COUNCIL" report "$RID"
  assert_rc 65 "report with the template: $t"
done
assert_no_file "$HTML"

# Strays that never travel: prompts/, a loose file, an answer of no seat, a
# backup, a synthesis with no number.
printf 'un prompt\n' >"$DOC/prompts/propose-B.a1.md"
printf 'nota suelta\n' >"$DOC/notas-sueltas.md"
printf 'borrador\n' >"$DOC/1-propuestas/borrador.md"
printf 'copia\n' >"$DOC/rondas/r1-B.md.bak"
printf 'sin número\n' >"$DOC/sintesis-vfinal.md"

# No lock (D8): report works while the run lock is held, and never writes run.json.
RJ_SHA="$(sha_of "$RJ")"
mkdir "$RD/.lock"
council report "$RID"
assert_rc 0 "report with everything present (and the run lock held by someone else)"
rmdir "$RD/.lock"
assert_eq "INFORME HTML: $HTML" "$(cat "$OUT")" "report prints the path of the page"
assert_file "$HTML"
assert_eq "$RJ_SHA" "$(sha_of "$RJ")" "report never writes run.json"
for left in "$DOC"/.informe.html.* "$RD"/.report.* "$RD"/.digest*; do
  [ -e "$left" ] && fail "a temp file was left behind: $left"
done

# =============================================================================
# A2 — the shape of the file
# =============================================================================
assert_eq 1 "$(LC_ALL=C grep -cF '<script type="application/json" id="council-data">' "$HTML")" "one data block"
assert_eq 1 "$(LC_ALL=C grep -cE '^<!-- tandem-council-digest: [0-9a-f]{64} -->$' "$HTML")" "one fingerprint line"
payload_of "$HTML"
WANT_DOCS="$(printf '%s\n' brief.md informe.md estrategia-final.md metadatos.md registro.md \
  sintesis-v1.md sintesis-v2.md auditoria-v1.md auditoria-v2.md \
  1-propuestas/A.md 1-propuestas/B.md 1-propuestas/C.md \
  2-contrainterrogatorio/A.md 2-contrainterrogatorio/B.md 2-contrainterrogatorio/C.md \
  rondas/r1-B.md rondas/r1-C.md rondas/r2-B.md rondas/r2-C.md | LC_ALL=C sort)"
GOT_DOCS="$(jq -r '.docs | keys[]' "$PAYLOAD" | LC_ALL=C sort)"
assert_eq "$WANT_DOCS" "$GOT_DOCS" "the embedded documents are exactly the closed list"
# Each text byte for byte — and, from those same bytes, the fingerprint (A6).
: >"$SANDBOX/digest.list"
for k in $GOT_DOCS; do
  jq -j --arg k "$k" '.docs[$k]' "$PAYLOAD" >"$SANDBOX/doc.out"
  cmp -s "$SANDBOX/doc.out" "$DOC/$k" || fail "the embedded $k is not byte-identical to the file"
  printf '%s\t%s\n' "$k" "$(sha_of "$SANDBOX/doc.out")" >>"$SANDBOX/digest.list"
done
LC_ALL=C sort "$SANDBOX/digest.list" >"$SANDBOX/digest.sorted"
assert_eq "$(sha_of "$SANDBOX/digest.sorted")" "$(digest_line "$HTML")" \
  "the fingerprint line is the fingerprint of the embedded documents"
assert_json "$PAYLOAD" '.run == {run_id: "2026-10-19-report", created: "2026-10-19T08:00:00Z", mode: "web", max_rounds: 2,
  letters: {A: "lider", B: "astra", C: "fable"}, leader_model: "claude-opus-5-5"}'
assert_json "$PAYLOAD" '.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'

# =============================================================================
# A4 — a seat's text cannot close the data block nor open a comment
# =============================================================================
if LC_ALL=C grep -q '<' "$PAYLOAD"; then fail "the payload holds a < byte"; fi
# The hostile text is there, with every < written as the JSON escape of <.
LT='\u''003c'
assert_file_contains "$PAYLOAD" "${LT}/script>${LT}script>alert(1)${LT}/script>"
assert_file_contains "$PAYLOAD" "${LT}!-- comentario -->"
assert_file_contains "$PAYLOAD" "${LT}img src=x onerror=alert(1)>"
count_of() { LC_ALL=C grep -o -- "$1" "$2" | wc -l | tr -d ' '; }
assert_eq "$(($(count_of '<script' "$TPL") + 1))" "$(count_of '<script' "$HTML")" \
  "informe.html holds the <script tags of the template plus its data block, nothing else"
assert_eq "$(count_of '<!--' "$TPL")" "$(count_of '<!--' "$HTML")" \
  "informe.html opens no comment but the fingerprint line (in place of the marker)"
if LC_ALL=C grep -q '<img' "$HTML"; then fail "a seat's <img reached informe.html"; fi

# =============================================================================
# A3 — the facts: the grammar of ledger, status and metadatos.md
# =============================================================================
OBJS_PAYLOAD="$(jq -c '.facts.objections | map({id, author, n, sev, title, phase, status, reason})' "$PAYLOAD")"
assert_eq "$(files_map "$DOC" | jq -c "$PARSER_IN" | ledger_objs)" "$OBJS_PAYLOAD" \
  "facts.objections = the ledger's parser on the published answers"
assert_json "$PAYLOAD" '[.facts.objections[] | "\(.id) \(.author) \(.sev) \(.status)"]
  == ["A-1 A P2 PENDIENTE", "B-1 B P2 RESUELTA", "B-2 B P1 RESUELTA", "B-3 B P2 RESUELTA",
      "C-1 C P1 RESUELTA", "C-2 C P3 PENDIENTE", "C-3 C P2 RESUELTA"]'
# The detail: the deeper-indented lines after the objection's own line, a blank
# line only when more indentation follows, up to the next line that is not.
assert_json "$PAYLOAD" '(.facts.objections[] | select(.id == "B-1") | .detail)
  == "  - Escenario: el coste por usuario se dispara en la apertura\n  - Evidencia: https://example.com/coste\n\n  - Propuesta: fijar un tope de gasto por usuario"'
assert_json "$PAYLOAD" '(.facts.objections[] | select(.id == "C-1") | .detail)
  == "  - Escenario: 90 días no bastan para 1.000 usuarios\n  - Propuesta: medir a los 120 días"'
assert_json "$PAYLOAD" '(.facts.objections[] | select(.id == "B-2") | .detail) == "  - Escenario: el canal satura a los 500 usuarios"'
assert_eq "$(jq -Rsc 'split("\n")' "$DOC/registro.md" | jq -c "$CJQ"'rows')" "$(jq -c '.facts.rows' "$PAYLOAD")" \
  "facts.rows = the rows of registro.md"
# The status, exactly what status prints (it exited 0: CONSENSO).
assert_json "$PAYLOAD" '.facts.status | .consensus == true and .round == 2 and .reasons == []
  and .last_round == 2 and .max_rounds == 2'
assert_json "$PAYLOAD" '.facts.rounds == [
  {n: 1, verdicts: [{letra: "B", verdict: "REVISE", riesgo: null},
                    {letra: "C", verdict: "APPROVED", riesgo: "dependencia externa"}]},
  {n: 2, verdicts: [{letra: "B", verdict: "APPROVED", riesgo: "el coste puede subir"},
                    {letra: "C", verdict: "APPROVED", riesgo: "el regulador puede cambiar de criterio"}]}]'
# The events: the seeded REABRE and NO RESUELTA, never a foreign ID a seat quoted.
assert_json "$PAYLOAD" 'any(.facts.events[]; .id == "C-3" and .author == "C" and .phase == "round-2"
  and .kind == "REABRE" and .text == "el regulador publicó una norma nueva")'
assert_json "$PAYLOAD" 'any(.facts.events[]; .id == "B-2" and .author == "B" and .phase == "round-1"
  and .kind == "NO RESUELTA" and .text == "el canal sigue sin escalar")'
assert_json "$PAYLOAD" 'any(.facts.events[]; .id == "B-1" and .kind == "NUEVA" and .sev == "P2" and .phase == "propose")'
assert_json "$PAYLOAD" '[.facts.events[] | select(.author == "B" and .id == "C-1")] == []'
assert_json "$PAYLOAD" '[.facts.events[] | select(.author == "C" and .id == "B-2")] == []'
# The tokens, the seats and the anomalies: the sums and lines metadatos.md prints.
META="$DOC/metadatos.md"
assert_file_contains "$META" "- Astra: $(jq -r '.facts.tokens.astra | to_entries | map("\(.key)=\(.value)") | join(" ")' "$PAYLOAD") ($(jq -r '.facts.tokens.nu' "$PAYLOAD") ficheros"
assert_file_contains "$META" "- Fable: $(jq -r '.facts.tokens.fable | to_entries | map("\(.key)=\(.value)") | join(" ")' "$PAYLOAD") ($(jq -r '.facts.tokens.nf' "$PAYLOAD") capturas"
assert_file_contains "$META" "COTA INFERIOR: $(jq -r '.facts.tokens.sin_usage_definitivo' "$PAYLOAD") de $(jq -r '.facts.tokens.mensajes' "$PAYLOAD") mensajes"
assert_json "$PAYLOAD" '.facts.tokens.astra.input_tokens == 13200 and .facts.tokens.fable.output_tokens == 28'
assert_json "$PAYLOAD" '[.facts.seats[] | "\(.letra) \(.asiento) \(.modelos | join(","))"]
  == ["A lider claude-opus-5-5", "B astra gpt-6-astra/max", "C fable claude-fable-5-1,claude-fable-5-1-20261001"]'
jq -r '.facts.anomalies[] | "- \(.)"' "$PAYLOAD" >"$SANDBOX/anom.payload"
LC_ALL=C awk '/^## Anomalías$/ { f = 1; next } /^## / { f = 0 } f && NF' "$META" >"$SANDBOX/anom.meta"
cmp -s "$SANDBOX/anom.meta" "$SANDBOX/anom.payload" || fail "facts.anomalies are not the anomalies of metadatos.md"
assert_json "$PAYLOAD" '[.facts.astra_turns[] | "\(.fase) \(.estado) \(.turno) \(.meta.model)"]
  == ["propose done 1 gpt-6-astra", "cross failed 2 gpt-6-astra", "cross done 1 gpt-6-astra",
      "round-1 done 2 gpt-6-astra", "round-1 interrupted null null", "round-2 done 3 gpt-6-astra"]'
# The sources of the LAST audit, split at the first « — ».
assert_json "$PAYLOAD" '.facts.sources == {file: "auditoria-v2.md", offline: false, items: [
  {id: "F1", status: "VERIFICADA", src: "https://example.com/dato", desc: "42 % de conversión"},
  {id: "F2", status: "VERIFICADA", src: "proyecto/datos.csv", desc: "1.200 registros — leídos en el fichero"},
  {id: "F3", status: "NO ACCESIBLE", src: "https://example.com/caido", desc: "sin respuesta del servidor"}]}'
assert_json "$PAYLOAD" '.facts.strategy == {last_round: 2, synthesis: "sintesis-v2.md", identical: true, consensus: true}'

# =============================================================================
# A6 — a page coherent with itself
# =============================================================================
# The facts come from the same bytes the page embeds.
assert_eq "$(jq -c '.docs' "$PAYLOAD" | jq -c "$PARSER_IN" | ledger_objs)" "$OBJS_PAYLOAD" \
  "facts.objections = the ledger's parser on the documents of the payload"
# (and the fingerprint line is the fingerprint of those same bytes: A2 above)

note "council report: closed list byte for byte, no < in the payload, facts = ledger/status/metadatos grammar, one fingerprint of the embedded bytes"
