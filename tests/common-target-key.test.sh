#!/usr/bin/env bash
# target_key: filesystem-safe, collision-resistant, empty for unusable labels.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

key() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  target_key "$1"
)
sum() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

assert_eq "demo.$(sum demo)" "$(key demo)" "plain label"
assert_eq "docs_plans_x.plan.md.$(sum 'docs/plans/x.plan.md')" \
  "$(key 'docs/plans/x.plan.md')" "path label"

# Labels that sanitize to the same text must NOT share a thread: the checksum is
# taken over the RAW label.
a="$(key 'a/b')"
b="$(key 'a b')"
assert_eq "a_b" "${a%%.*}" "sanitized form of a/b"
assert_eq "a_b" "${b%%.*}" "sanitized form of 'a b'"
if [ "$a" = "$b" ]; then fail "a/b and 'a b' collided on one key: $a"; fi

# Leading dots are stripped (no hidden state files, no '..' traversal).
assert_eq "hidden.$(sum '...hidden')" "$(key '...hidden')" "leading dots"
assert_eq "_.._etc.$(sum '../../etc')" "$(key '../../etc')" "traversal"

# CR/LF collapse to underscores before anything else touches the label.
assert_eq "two_lines.$(sum "$(printf 'two\nlines')")" \
  "$(key "$(printf 'two\nlines')")" "embedded newline"

# Separators still sanitize to something usable — only labels that are pure
# leading dots (or empty) end up with nothing left.
assert_eq "___.$(sum '///')" "$(key '///')" "slashes only"
assert_eq "" "$(key '...')" "dots only"
assert_eq "" "$(key '')" "empty label"

# Callers reject the empty key with 64, never with a silent success.
make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "x"
export CODEX_STUB_SCENARIO=ok
run bash "$SCRIPTS/codex-start.sh" review '...' "$SANDBOX/p.tpl"
assert_rc 64 "empty state key"
assert_file_contains "$ERR" "empty state key"
assert_no_file "$CODEX_STUB_LOG.argv.1"
