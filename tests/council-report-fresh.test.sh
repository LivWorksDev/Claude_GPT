#!/usr/bin/env bash
# council.sh status and report — the freshness of informe.html (A6) and the
# provenance of the strategy (A3b), on the documents of the seeded run of
# council-report.test.sh (tests/fixtures/council/report/doc).
#
# status tells three cases apart once informe.md exists — no informe.html, an
# informe.html whose fingerprint is that of the documents as they are now, and
# a stale one (a document changed, or no fingerprint line) — by CONTENT, never
# by mtime, and never moves its STATUS: line nor its exit code for it. The
# strategy is «aprobada» only with consensus AND an exact copy: after the cap
# without consensus it is an exact copy with consensus false, and an
# estrategia-final.md touched by hand is not identical any more.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
COUNCIL="$SCRIPTS/council.sh"
FX="$REPO_ROOT/tests/fixtures/council/report"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
RID=2026-10-19-fresco
DOC="$CLAUDE_PROJECT_DIR/docs/council/$RID"
RJ="$CLAUDE_PROJECT_DIR/.tandem/state/council/runs/$RID/run.json"
HTML="$DOC/informe.html"
PAYLOAD="$SANDBOX/payload.json"

council() { run bash "$COUNCIL" "$@"; }
rj_set() { jq "$@" "$RJ" >"$RJ.tmp" && mv "$RJ.tmp" "$RJ"; }
payload_of() {
  LC_ALL=C sed -n 's|^<script type="application/json" id="council-data">\(.*\)</script>$|\1|p' "$1" >"$PAYLOAD"
  jq -e '.schema == 1' "$PAYLOAD" >/dev/null 2>&1 || fail "the data block of $1 is not JSON with schema 1"
}
expect_phase() {
  # expect_phase <phase> <label> — and the STATUS: line and exit code never move.
  council status "$RID"
  assert_rc 0 "status: $2"
  assert_file_contains "$OUT" "PHASE: $1"
  assert_file_contains "$OUT" "STATUS: CONSENSO"
}

council init "$RID"
assert_rc 0 "init"
cp -R "$FX/doc/." "$DOC/"
rj_set '.letters = {A: "lider", B: "astra", C: "fable"} | .max_rounds = 2'
council status "$RID" --metadata
assert_rc 0 "status --metadata (CONSENSO in round 2)"

# =============================================================================
# A6 — missing, fresh, stale: by content
# =============================================================================
expect_phase "informe (escrito; falta informe.html: council.sh report)" "informe.md written, no informe.html yet"
council report "$RID"
assert_rc 0 "report"
# Fresh — and new mtimes, a stray file or a prompt (outside the closed list) do
# not make it stale.
touch "$DOC/registro.md" "$DOC/brief.md"
printf 'nota suelta\n' >"$DOC/notas-sueltas.md"
printf 'un prompt\n' >"$DOC/prompts/round-1-B.a1.md"
expect_phase "informe (escrito)" "a fresh informe.html (new mtimes, a stray file, a prompt)"

cp "$DOC/informe.md" "$SANDBOX/informe.orig"
printf '\nUna línea añadida a mano.\n' >>"$DOC/informe.md"
expect_phase "informe (escrito; informe.html desactualizado: council.sh report)" "informe.md changed after report"
cp "$SANDBOX/informe.orig" "$DOC/informe.md"
expect_phase "informe (escrito)" "informe.md restored to its content (with a new mtime)"

cp "$DOC/rondas/r1-B.md" "$SANDBOX/r1-B.orig"
printf 'nota del moderador\n' >>"$DOC/rondas/r1-B.md"
expect_phase "informe (escrito; informe.html desactualizado: council.sh report)" "a round document changed after report"
cp "$SANDBOX/r1-B.orig" "$DOC/rondas/r1-B.md"

LC_ALL=C grep -v '^<!-- tandem-council-digest: ' "$HTML" >"$SANDBOX/html.tmp" && cp "$SANDBOX/html.tmp" "$HTML"
expect_phase "informe (escrito; informe.html desactualizado: council.sh report)" "an informe.html with no fingerprint line"

# =============================================================================
# A3b — the provenance of the strategy follows the status
# =============================================================================
payload_of "$HTML"
assert_json "$PAYLOAD" '.facts.strategy == {last_round: 2, synthesis: "sintesis-v2.md", identical: true, consensus: true}'

# SIN_CONSENSO after the cap: round 2 (= max_rounds) ends in REVISE.
printf '# Revisión de B — ronda 2\n\n- [B-2] RESUELTA: concedo\n- [B-3] RESUELTA: corregido\nVERDICT: REVISE\n' >"$DOC/rondas/r2-B.md"
council status "$RID" --metadata
assert_rc 1 "status --metadata after the cap with a REVISE"
assert_file_contains "$OUT" "STATUS: SIN_CONSENSO"
assert_file_contains "$OUT" "PHASE: informe (escrito; informe.html desactualizado: council.sh report)"
council report "$RID"
assert_rc 0 "report on a run SIN_CONSENSO after the cap"
payload_of "$HTML"
assert_json "$PAYLOAD" '.facts.strategy == {last_round: 2, synthesis: "sintesis-v2.md", identical: true, consensus: false}'
assert_json "$PAYLOAD" '.facts.status | .consensus == false and .last_round == 2 and .max_rounds == 2
  and (.reasons | index("ronda 2: B termina en VERDICT: REVISE")) != null'
council status "$RID"
assert_rc 1 "status exits 1 on SIN_CONSENSO, fresh page or not"
assert_file_contains "$OUT" "PHASE: informe (escrito)"

# estrategia-final.md touched by hand after status --metadata.
printf '\nUn retoque a mano.\n' >>"$DOC/estrategia-final.md"
council report "$RID"
assert_rc 0 "report with an estrategia-final.md that no longer matches its synthesis"
payload_of "$HTML"
assert_json "$PAYLOAD" '.facts.strategy.identical == false'

# =============================================================================
# A3 — the sources of an offline run
# =============================================================================
rj_set '.mode = "offline"'
printf -- '- OFFLINE: no aplica\n' >"$DOC/auditoria-v2.md"
council report "$RID"
assert_rc 0 "report on an offline run"
payload_of "$HTML"
assert_json "$PAYLOAD" '.facts.sources == {file: "auditoria-v2.md", offline: true, items: []}'
assert_json "$PAYLOAD" '.run.mode == "offline"'

note "council report freshness: missing / fresh / stale by content, STATUS untouched; strategy provenance follows the status"
