#!/usr/bin/env bash
# codex-show.sh reports thread state without calling codex at all.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
SD="$(state_dir review)"
KEY="$(seed_key review demo)"

# --- no thread -> exit 2 -----------------------------------------------------
run bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 2 "no thread"
assert_file_contains "$ERR" 'no thread exists for "demo" (role review).'

# --- thread + turns + last reply --------------------------------------------
printf 'thr_show_1\n' >"$SD/$KEY.thread"
printf '5\n' >"$SD/$KEY.turn"
printf 'the last reply body\nVERDICT: APPROVED\n' >"$SD/$KEY.last.txt"

run bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 0 "full state"
assert_file_contains "$OUT" "target:    demo"
assert_file_contains "$OUT" "role:      review"
assert_file_contains "$OUT" "thread_id: thr_show_1"
assert_file_contains "$OUT" "turns:     5"
assert_file_contains "$OUT" "--- last reply ---"
assert_file_contains "$OUT" "the last reply body"
assert_file_contains "$OUT" "VERDICT: APPROVED"
assert_file_contains "$OUT" "--- end ---"

# --- thread but no turn file -------------------------------------------------
rm -f "$SD/$KEY.turn"
run bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 0 "missing turn file"
assert_file_contains "$OUT" "turns:     ?"

# --- thread but no (or empty) last reply -------------------------------------
: >"$SD/$KEY.last.txt"
run bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 0 "empty last reply"
assert_file_contains "$OUT" "(no last reply captured)"
assert_not_contains "$OUT" "--- last reply ---"

rm -f "$SD/$KEY.last.txt"
run bash "$SCRIPTS/codex-show.sh" review demo
assert_rc 0 "absent last reply"
assert_file_contains "$OUT" "(no last reply captured)"

# --- roles are separate namespaces -------------------------------------------
run bash "$SCRIPTS/codex-show.sh" implement demo
assert_rc 2 "same target, other role"

# --- usage -------------------------------------------------------------------
run bash "$SCRIPTS/codex-show.sh" auditor demo
assert_rc 64 "unknown role"
run bash "$SCRIPTS/codex-show.sh" review "..."
assert_rc 64 "empty state key"

# codex was never invoked at any point.
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
