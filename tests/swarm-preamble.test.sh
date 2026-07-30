#!/usr/bin/env bash
# --preamble is the whole point of M8: the shared seat preamble is concatenated
# by the SCRIPT, so no wrapper model ever retypes it. "Byte for byte" is the
# acceptance criterion, so every assertion here is `cmp` against a reference
# concatenation — never "contains", which would pass for a prompt that lost a
# tab, doubled a backslash or grew a courtesy newline.
#
# Two observation points, both mandatory: the staged .prompt.txt (the durable
# record of what the seat was sent) and the stdin the stub actually drained
# (what codex really received). One file feeds both, and this proves it.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
export CODEX_STUB_SCENARIO=ok

# same <got> <want> <label> — byte-for-byte equality, with the first differing
# byte named when it fails.
same() {
  local got="$1" want="$2" label="$3"
  [ -f "$got" ] || fail "$label: expected file to exist: $got"
  [ -f "$want" ] || fail "$label: reference file is missing: $want"
  if cmp -s "$got" "$want"; then return 0; fi
  cmp "$got" "$want" >&2 || true
  printf -- '--- got (od -c) ---\n' >&2; od -c "$got" | head -n 20 >&2
  printf -- '--- want (od -c) ---\n' >&2; od -c "$want" | head -n 20 >&2
  fail "$label: bytes differ from $want"
}

# The preamble lives where a filename that lost its quotes would break: spaces
# AND glob metacharacters. An unquoted "$PREAMBLE_FILE" word-splits here, and a
# glob that matches nothing stays literal and fails to open.
PDIR="$SANDBOX/pre amble [dir]"
mkdir -p "$PDIR"
PRE="$PDIR/seat *preamble*.md"

# …and the CONTENT carries the mutation vectors: printf format specifiers, real
# tabs and literal backslash escapes. A `printf "$content"` or an `echo -e`
# anywhere in the path would eat one of them.
printf 'PREAMBLE %%s %%d are literal format specifiers\n\tTAB-indented line\nbackslashes: C:\\tmp \\n \\t stay as typed\n100%% verbatim, and this trailing newline is the author'\''s\n' \
  >"$PRE"

BRIEF="$SANDBOX/brief.md"
printf 'BRIEF: judge the thing.\nOutput contract: a fenced JSON object, %%s style.\n' >"$BRIEF"

# The reference: the concatenation, with nothing at all between the two files.
EXPECTED="$SANDBOX/expected.txt"
cat "$PRE" "$BRIEF" >"$EXPECTED"
# Never vacuously green: if the reference equalled the brief the cmp assertions
# below would hold even with --preamble ignored entirely.
if cmp -s "$EXPECTED" "$BRIEF"; then
  fail "the reference concatenation is indistinguishable from the brief alone"
fi

RUNKEY="$(tkey run-p)"
UD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUNKEY"

# --- with --preamble --------------------------------------------------------
run bash "$SCRIPTS/codex-swarm.sh" --preamble "$PRE" worker run-p seat-a "$BRIEF"
assert_rc 0 "seat with --preamble"

AK="$(tkey seat-a)"
same "$UD/$AK.prompt.txt" "$EXPECTED" "staged prompt (durable record)"
same "$(stub_stdin 1)" "$EXPECTED" "stdin drained by codex"

# The flag is consumed here and never reaches codex: the argv contract of the
# swarm seat is unchanged by M8.
assert_not_contains "$CODEX_STUB_LOG.argv.1" "--preamble"
assert_not_contains "$CODEX_STUB_LOG.argv.1" "$PRE"

# --- without --preamble: not a byte moves -----------------------------------
run bash "$SCRIPTS/codex-swarm.sh" worker run-p seat-b "$BRIEF"
assert_rc 0 "seat without --preamble"

BK="$(tkey seat-b)"
same "$UD/$BK.prompt.txt" "$BRIEF" "staged prompt without --preamble"
same "$(stub_stdin 2)" "$BRIEF" "stdin without --preamble"

assert_eq "2" "$(cat "$CODEX_STUB_LOG.n")" "codex invocations"
note "preamble concatenated by the script, byte for byte, in staged and stdin"
