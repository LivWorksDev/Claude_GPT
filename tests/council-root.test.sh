#!/usr/bin/env bash
# council.sh — which project a call belongs to (real canary, 2026-10-18: the
# leader's working directory moved between its Bash calls, and a call made from
# elsewhere could not find the run). init creates the run where it is called and
# prints PROJECT, recording it in run.json; the skill pins that path on every
# later call. Without CLAUDE_PROJECT_DIR, every other subcommand looks for the
# run in $PWD and then in each parent, so a call from a subdirectory of the
# project still finds it; from outside the project it does not, and says so.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

PROJ="$SANDBOX/proyecto"
mkdir -p "$PROJ/sub/dir"
export TANDEM_CLAUDE_MANAGED_SETTINGS="$SANDBOX/managed-settings.json"
COUNCIL="$SCRIPTS/council.sh"
RID=2026-10-19-raiz
DOC="$PROJ/docs/council/$RID"
RJ="$PROJ/.tandem/state/council/runs/$RID/run.json"

# init from the project root, with no CLAUDE_PROJECT_DIR at all.
run_in "$PROJ" env -u CLAUDE_PROJECT_DIR bash "$COUNCIL" init "$RID"
assert_rc 0 "init from the project root"
assert_file_contains "$OUT" "PROJECT: $PROJ"
assert_file_contains "$OUT" "DOC_DIR: $DOC"
assert_json "$RJ" ".project_dir == \"$PROJ\""

# From a subdirectory of the project — DOC_DIR itself — the run is found.
printf '# Brief\n\nObjetivo: x\n' >"$DOC/brief.md"
run_in "$DOC" env -u CLAUDE_PROJECT_DIR bash "$COUNCIL" seal "$RID" brief
assert_rc 0 "seal from DOC_DIR"
assert_json "$RJ" '.seals.brief.sha256 | type == "string"'
run_in "$PROJ/sub/dir" env -u CLAUDE_PROJECT_DIR bash "$COUNCIL" status "$RID"
assert_rc 1 "status from a deep subdirectory (no round yet)"
assert_file_contains "$OUT" "PHASE: propose"
assert_no_file "$PROJ/sub/dir/.tandem"

# From outside the project there is no run to find, and it says so.
mkdir -p "$SANDBOX/fuera"
run_in "$SANDBOX/fuera" env -u CLAUDE_PROJECT_DIR bash "$COUNCIL" status "$RID"
assert_rc 1 "status from outside the project"
assert_file_contains "$ERR" "no council run '$RID'"
assert_no_file "$SANDBOX/fuera/.tandem"

# An explicit CLAUDE_PROJECT_DIR wins: no walk from the working directory.
run_in "$PROJ/sub/dir" env CLAUDE_PROJECT_DIR="$PROJ/sub" bash "$COUNCIL" status "$RID"
assert_rc 1 "status pinned to another directory"
assert_file_contains "$ERR" "no council run '$RID' ($PROJ/sub/.tandem/state/council/runs/$RID/run.json)"
run_in "$SANDBOX/fuera" env CLAUDE_PROJECT_DIR="$PROJ" bash "$COUNCIL" status "$RID"
assert_rc 1 "status pinned to the project from outside it"
assert_file_contains "$OUT" "PHASE: propose"

# init never walks: called from a subdirectory, it creates THERE.
run_in "$PROJ/sub" env -u CLAUDE_PROJECT_DIR bash "$COUNCIL" init 2026-10-19-otro
assert_rc 0 "init from a subdirectory"
assert_file_contains "$OUT" "PROJECT: $PROJ/sub"
assert_file "$PROJ/sub/.tandem/state/council/runs/2026-10-19-otro/run.json"

note "council project root: init prints and records PROJECT; a run is found from any subdirectory, never from outside; an explicit CLAUDE_PROJECT_DIR wins; init never walks"
