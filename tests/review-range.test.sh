#!/usr/bin/env bash
# scripts/review-range.sh — the out-of-pipeline review of an ALREADY-COMMITTED
# range. Everything this helper does is GIT behaviour (range parsing and
# resolution, the inline diff, the state bootstrap) plus the two namespaces that
# must never meet the pipeline's, so a static assertion on the skill would stay
# green while every one of them was broken. Each case runs against a real,
# throwaway repository.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

RR="$SCRIPTS/review-range.sh"

# rr <repo> <args…> — invoked the way the skill does: from the checkout, with
# the project state anchored there.
rr() {
  local repo="$1"
  shift
  run_in "$repo" env CLAUDE_PROJECT_DIR="$repo" bash "$RR" "$@"
}

field() {
  # field <NAME> — the value of one parseable output line.
  LC_ALL=C sed -n "s/^$1: //p" "$OUT"
}

diff_section() {
  # diff_section <context-file> <out> — everything after the `DIFF:` heading,
  # byte for byte. The diff is the last section of the file on purpose.
  LC_ALL=C sed -n '/^DIFF:$/,$p' "$1" | tail -n +2 >"$2"
}

seed_repo() {
  # seed_repo <name> — three commits: f.txt twice, then a new g.txt.
  local d="$SANDBOX/$1"
  make_repo "$d"
  printf 'a\n' >"$d/f.txt"
  commit_all "$d" one
  printf 'b\n' >>"$d/f.txt"
  commit_all "$d" two
  printf 'c\n' >"$d/g.txt"
  commit_all "$d" three
  printf '%s' "$d"
}

# =============================================================================
# 1. Bootstrap: a project with NO .tandem/ at all
# =============================================================================
A="$(seed_repo plain)"
A_SHA_A="$(git -C "$A" rev-parse 'HEAD~2')"
A_SHA_B="$(git -C "$A" rev-parse HEAD)"
assert_no_file "$A/.tandem"

rr "$A" demo "HEAD~2..HEAD"
assert_rc 0 "two-dot range on a fresh project"

[ -d "$A/.tandem/tmp" ] || fail "the helper did not create .tandem/tmp"
[ -d "$A/.tandem/log/ranges" ] || fail "the helper did not create .tandem/log/ranges"
assert_file "$A/.tandem/.gitignore"
assert_eq "*" "$(cat "$A/.tandem/.gitignore")" "default .gitignore"

# Every emitted path is absolute, and the two namespaces are the documented ones.
assert_eq "range-review-demo" "$(field TARGET)" "thread target"
assert_eq "$A_SHA_A $A_SHA_B" "$(field ENDPOINTS)" "resolved endpoints"
CTX="$(field CONTEXT_FILE)"
LOG="$(field LOG_FILE)"
assert_eq "$A/.tandem/tmp/range-demo-context.md" "$CTX" "context path"
assert_eq "$A/.tandem/log/ranges/demo.md" "$LOG" "log path"
assert_eq "$A" "$(field WORK_ROOT)" "work root"
assert_file "$CTX"
assert_file "$LOG"

# The endpoints travel RESOLVED: full shas, plus the refs the user typed.
assert_file_contains "$CTX" "$A_SHA_A"
assert_file_contains "$CTX" "$A_SHA_B"
assert_file_contains "$CTX" "(HEAD~2)"
# The mandatory reading rule, anchored at B — not at the checkout.
assert_file_contains "$CTX" "git show $A_SHA_B:"
assert_file_contains "$CTX" "git ls-tree -r --name-only $A_SHA_B"
# The commit list and the stat are there too.
assert_file_contains "$CTX" "COMMITS:"
assert_file_contains "$CTX" "2 files changed"

# The inline diff is byte for byte the diff of the resolved two-dot range.
diff_section "$CTX" "$SANDBOX/got.diff"
git -C "$A" diff "$A_SHA_A..$A_SHA_B" >"$SANDBOX/want.diff"
cmp -s "$SANDBOX/got.diff" "$SANDBOX/want.diff" \
  || fail "the inline DIFF is not byte-identical to git diff $A_SHA_A..$A_SHA_B"
[ -s "$SANDBOX/want.diff" ] || fail "the fixture diff is empty — the comparison proves nothing"

# =============================================================================
# 2. Three-dot on a GENUINELY divergent graph
# =============================================================================
# Both sides carry commits of their own, so `A..B` and `A...B` cannot be the
# same text: two-dot also undoes the side branch, three-dot does not.
D="$SANDBOX/diverge"
make_repo "$D"
printf 'base\n' >"$D/base.txt"
commit_all "$D" base
D_MAIN="$(git -C "$D" rev-parse --abbrev-ref HEAD)"
git -C "$D" checkout -q -b side
printf 'side\n' >"$D/side.txt"
commit_all "$D" side
D_SIDE="$(git -C "$D" rev-parse HEAD)"
git -C "$D" checkout -q "$D_MAIN"
printf 'main\n' >"$D/main.txt"
commit_all "$D" main
D_TIP="$(git -C "$D" rev-parse HEAD)"

rr "$D" div "$D_SIDE...$D_TIP"
assert_rc 0 "three-dot range"
D_CTX="$(field CONTEXT_FILE)"
assert_eq "$D_SIDE $D_TIP" "$(field ENDPOINTS)" "divergent endpoints"

diff_section "$D_CTX" "$SANDBOX/got3.diff"
git -C "$D" diff "$D_SIDE...$D_TIP" >"$SANDBOX/want3.diff"
git -C "$D" diff "$D_SIDE..$D_TIP" >"$SANDBOX/want2.diff"
cmp -s "$SANDBOX/got3.diff" "$SANDBOX/want3.diff" \
  || fail "the inline DIFF is not byte-identical to the three-dot diff"
if cmp -s "$SANDBOX/want3.diff" "$SANDBOX/want2.diff"; then
  fail "the fixture graph is not divergent — three-dot and two-dot agree, so the case proves nothing"
fi
if cmp -s "$SANDBOX/got3.diff" "$SANDBOX/want2.diff"; then
  fail "the three-dot range produced the TWO-dot diff"
fi

# =============================================================================
# 3. Range shapes that never reach git
# =============================================================================
for bad in "HEAD" "..HEAD" "HEAD.." ".." "A..B..C" "HEAD~1....HEAD" "-x..HEAD" \
  "HEAD..--upload-pack=touch" ""; do
  rr "$A" demo "$bad"
  assert_rc 64 "range [$bad]"
done
# A control character in an endpoint is a usage error, never something git sees.
rr "$A" demo "$(printf 'HE\tAD..HEAD')"
assert_rc 64 "endpoint with a control character"

# …and the label obeys plan-approve's charset.
for badlabel in "" "../evil" "-lead" ".lead" "a b" "a/b"; do
  rr "$A" "$badlabel" "HEAD~1..HEAD"
  assert_rc 64 "label [$badlabel]"
done
rr "$A"
assert_rc 64 "no arguments"
rr "$A" demo
assert_rc 64 "one argument"
rr "$A" demo "HEAD~1..HEAD" extra
assert_rc 64 "three arguments"

# =============================================================================
# 4. A ref that does not resolve, and a range with nothing in it
# =============================================================================
rr "$A" demo "nope..HEAD"
assert_rc 65 "unresolvable A endpoint"
assert_file_contains "$ERR" "cannot resolve the A endpoint"
rr "$A" demo "HEAD..nope"
assert_rc 65 "unresolvable B endpoint"

rr "$A" empty "HEAD..HEAD"
assert_rc 2 "empty range"
assert_file_contains "$ERR" "nothing to review"
assert_no_file "$A/.tandem/tmp/range-empty-context.md"

# =============================================================================
# 5. A dirty working tree does not block anything
# =============================================================================
# This mode never reads, fixes or commits the working tree, so the pipeline's
# clean/dirty gates are simply not its business.
printf 'uncommitted\n' >>"$A/f.txt"
printf 'untracked\n' >"$A/new.txt"
rr "$A" dirty "HEAD~1..HEAD"
assert_rc 0 "dirty tree does not block a range review"
assert_file "$A/.tandem/tmp/range-dirty-context.md"
git -C "$A" checkout -q -- f.txt
rm -f "$A/new.txt"

# =============================================================================
# 6. The .gitignore the user owns is never overwritten
# =============================================================================
G="$(seed_repo ignore)"
mkdir -p "$G/.tandem"
USER_CONTENT="$(printf '*\n!log/\n!log/*.md\n# kept by hand\n')"
printf '%s\n' "$USER_CONTENT" >"$G/.tandem/.gitignore"
rr "$G" demo "HEAD~1..HEAD"
assert_rc 0 "range review with a hand-written .gitignore"
assert_eq "$USER_CONTENT" "$(cat "$G/.tandem/.gitignore")" ".gitignore preserved"

# =============================================================================
# 7. Zero collisions with the pipeline, by construction
# =============================================================================
N="$(seed_repo namespace)"
rr "$N" foo "HEAD~1..HEAD"
assert_rc 0 "range review of label foo"
assert_eq "range-review-foo" "$(field TARGET)" "range target"

# A pipeline slug that starts with `range` still cannot produce this key: the
# pipeline's is `cr-<slug>` and this one is `range-review-<label>`.
K_PIPE="$(tkey "cr-range-foo")"
K_RANGE="$(tkey "range-review-foo")"
[ -n "$K_PIPE" ] || fail "target_key produced an empty key for cr-range-foo"
[ -n "$K_RANGE" ] || fail "target_key produced an empty key for range-review-foo"
[ "$K_PIPE" != "$K_RANGE" ] \
  || fail "cr-range-foo and range-review-foo collide on one state key ($K_PIPE)"

# The logs live in different places, and the range's is in a SUBDIRECTORY.
assert_eq "$N/.tandem/log/ranges/foo.md" "$(field LOG_FILE)" "range log path"
printf '# tandem log — range-foo\n' >"$N/.tandem/log/range-foo.md"
assert_file "$N/.tandem/log/ranges/foo.md"

# …which is exactly why /tandem:status neither lists nor recommends anything
# about a range: its scan is the top-level `log/*.md`, one pipeline run per file.
run_in "$N" env CLAUDE_PROJECT_DIR="$N" bash "$SCRIPTS/tandem-status.sh"
assert_rc 0 "status listing with a range present"
assert_eq "1" "$(LC_ALL=C awk '$1 == "range-foo" { n++ } END { print n + 0 }' "$OUT")" \
  "the pipeline run is listed once"
assert_eq "0" "$(LC_ALL=C awk '$1 == "foo" { n++ } END { print n + 0 }' "$OUT")" \
  "the range is not listed as a run"
assert_eq "1" "$(wc -l <"$OUT" | tr -d ' ')" "exactly one run listed"

# =============================================================================
# 8. A context that cannot be completed is never published
# =============================================================================
# The context is built in a temporary file and moved into place only when it is
# complete; every filesystem failure becomes an explicit 65. A retry must never
# be able to read a truncated context.
rm -f "$N/.tandem/tmp/range-fail-context.md"
chmod 555 "$N/.tandem/tmp"
rr "$N" fail "HEAD~1..HEAD"
FAIL_RC="$RC"
chmod 755 "$N/.tandem/tmp" 2>/dev/null || true
assert_eq "65" "$FAIL_RC" "an unwritable tmp directory is a fail-closed stop"
assert_no_file "$N/.tandem/tmp/range-fail-context.md"

# The retry, once the directory is writable again, produces a complete context.
rr "$N" fail "HEAD~1..HEAD"
assert_rc 0 "retry after the filesystem is fixed"
assert_file "$N/.tandem/tmp/range-fail-context.md"
assert_file_contains "$N/.tandem/tmp/range-fail-context.md" "DIFF:"

# =============================================================================
# 9. No CLAUDE_PROJECT_DIR, invoked from a subdirectory
# =============================================================================
# The wrapper `rr` always exports CLAUDE_PROJECT_DIR, which is exactly the shape
# that would HIDE a cwd-anchored bug: without the variable, every emitted path
# must still resolve to the MAIN checkout's .tandem — the same root the launch
# pin `${CLAUDE_PROJECT_DIR:-$WORK_ROOT}` hands the wrappers — never to the
# subdirectory the shell happens to sit in.
mkdir -p "$A/sub"
run_in "$A/sub" env -u CLAUDE_PROJECT_DIR bash "$RR" subdir "HEAD~1..HEAD"
assert_rc 0 "range review from a subdirectory without CLAUDE_PROJECT_DIR"
assert_eq "$A" "$(field WORK_ROOT)" "work root resolved to the main checkout"
assert_eq "$A/.tandem/tmp/range-subdir-context.md" "$(field CONTEXT_FILE)" \
  "context under the main checkout's .tandem"
assert_eq "$A/.tandem/log/ranges/subdir.md" "$(field LOG_FILE)" \
  "log under the main checkout's .tandem"
assert_no_file "$A/sub/.tandem"

# =============================================================================
# 10. A directory squatting on the context path is a stop, not a publication
# =============================================================================
# `mv -f <file> <existing-dir>` drops the file INSIDE the directory and returns
# success — the one filesystem failure the atomic-publication contract could
# miss. The helper must refuse it with 65 and leave no stray temporary behind.
mkdir -p "$N/.tandem/tmp/range-dircase-context.md"
rr "$N" dircase "HEAD~1..HEAD"
assert_rc 65 "a directory on the context path is a fail-closed stop"
assert_file_contains "$ERR" "not a regular file"
[ -d "$N/.tandem/tmp/range-dircase-context.md" ] \
  || fail "the squatting directory was replaced or removed"
[ -z "$(find "$N/.tandem/tmp/range-dircase-context.md" -mindepth 1)" ] \
  || fail "the temporary context was moved INSIDE the squatting directory"
rmdir "$N/.tandem/tmp/range-dircase-context.md"

# Nothing here ever called codex: the helper prepares a turn, it does not spend one.
assert_no_file "$CODEX_STUB_LOG.argv.1"
assert_no_file "$CODEX_STUB_LOG.n"
