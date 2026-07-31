#!/usr/bin/env bash
# agents/implementer-critical.md is agents/implementer.md with three frontmatter
# fields changed and NOTHING else.
#
# Two failure modes are invisible to every behavioural test. First DRIFT: the
# security prohibitions of the implementer live in the agent's BODY (no commits,
# no pushes, no branch/remote changes, no network/MCP/nested agents), so a
# critical twin that lost one of them while keeping the tool allowlist intact
# would pass a tools-only comparison and hand critical work — auth, migrations,
# payments — to the least restricted agent in the plugin. The body is therefore
# compared BYTE FOR BYTE. Second, the NAME: it is the invocation identifier, and
# a typo there leaves `tandem:implementer-critical` pointing at an agent type
# that does not exist, with the whole suite green and TANDEM_CRITICAL silently
# doing nothing again — so both names are asserted literally.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

NORMAL="$REPO_ROOT/agents/implementer.md"
CRITICAL="$REPO_ROOT/agents/implementer-critical.md"
assert_file "$NORMAL"
assert_file "$CRITICAL"

# split_agent <file> <prefix> — writes <prefix>.fm (the frontmatter lines, in
# file order) and <prefix>.body (everything after the closing delimiter). The
# body is cut with tail, never re-emitted by a read loop: what is compared below
# has to be the file's bytes.
split_agent() {
  local f="$1" pfx="$2" n=0 delim=0 end=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$line" = "---" ]; then
      delim=$((delim + 1))
      if [ "$delim" -eq 1 ] && [ "$n" -ne 1 ]; then
        fail "$f: the frontmatter must open on line 1 (found --- on line $n)"
      fi
      if [ "$delim" -eq 2 ]; then
        end="$n"
        break
      fi
    fi
  done <"$f"
  [ "$end" -ge 3 ] || fail "$f: no closing frontmatter delimiter"
  tail -n +2 "$f" | head -n "$((end - 2))" >"$pfx.fm"
  tail -n +"$((end + 1))" "$f" >"$pfx.body"
}

# fm_get <fm-file> <key> — the trimmed value of <key>; nothing and rc 1 when the
# key is absent (an absent key and an empty value are different contracts here:
# `effort` must be ABSENT from the normal agent).
fm_get() {
  local f="$1" key="$2" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *:*) : ;;
      *) continue ;;
    esac
    k="${line%%:*}"
    v="${line#*:}"
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [ "$k" = "$key" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <"$f"
  return 1
}

# fm_keys <fm-file> — every key, one per line.
fm_keys() {
  local f="$1" line k
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *:*) : ;;
      *) continue ;;
    esac
    k="${line%%:*}"
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    [ -n "$k" ] || continue
    printf '%s\n' "$k"
  done <"$f"
}

split_agent "$NORMAL" "$SANDBOX/normal"
split_agent "$CRITICAL" "$SANDBOX/critical"

# --- the body, byte for byte -------------------------------------------------
if ! cmp -s "$SANDBOX/normal.body" "$SANDBOX/critical.body"; then
  printf -- '--- implementer body ---\n' >&2
  cat "$SANDBOX/normal.body" >&2
  printf -- '--- implementer-critical body ---\n' >&2
  cat "$SANDBOX/critical.body" >&2
  fail "the critical agent's body is not byte-for-byte identical to the implementer's"
fi

# Never vacuously green: two empty bodies are identical too, and the whole point
# of the comparison is that these prohibitions are in there.
assert_file_contains "$SANDBOX/normal.body" 'Never run `git commit`, `git push`, `git tag`'
assert_file_contains "$SANDBOX/normal.body" "Do not access MCP servers, connectors, the network, WebFetch, WebSearch, or nested agents."
assert_file_contains "$SANDBOX/normal.body" "Work only inside the absolute working directory named in the task prompt."
assert_file_contains "$SANDBOX/normal.body" "Do not install dependencies."
assert_file_contains "$SANDBOX/normal.body" "sentinel"

# --- the frontmatter: only three keys may differ -----------------------------
fm_keys "$SANDBOX/normal.fm" >"$SANDBOX/keys.raw"
fm_keys "$SANDBOX/critical.fm" >>"$SANDBOX/keys.raw"
LC_ALL=C sort -u "$SANDBOX/keys.raw" >"$SANDBOX/keys"

while IFS= read -r key; do
  [ -n "$key" ] || continue
  nhas=1
  chas=1
  nv="$(fm_get "$SANDBOX/normal.fm" "$key")" || nhas=0
  cv="$(fm_get "$SANDBOX/critical.fm" "$key")" || chas=0
  if [ "$nhas" = "$chas" ] && [ "$nv" = "$cv" ]; then continue; fi
  case "$key" in
    name | description | effort) : ;;
    *)
      fail "frontmatter key [$key] differs (implementer=[$nv] implementer-critical=[$cv]) — only name, description and effort may differ"
      ;;
  esac
done <"$SANDBOX/keys"

# --- the exact values the two agent types are identified and run by ----------
# The name IS the agent type: `tandem:<name>`.
assert_eq "implementer" "$(fm_get "$SANDBOX/normal.fm" name)" "implementer.md name"
assert_eq "implementer-critical" "$(fm_get "$SANDBOX/critical.fm" name)" "implementer-critical.md name"

# Same model, same tools — the critical twin raises effort, nothing else.
assert_eq "opus" "$(fm_get "$SANDBOX/normal.fm" model)" "implementer.md model"
assert_eq "opus" "$(fm_get "$SANDBOX/critical.fm" model)" "implementer-critical.md model"

NORMAL_TOOLS="$(fm_get "$SANDBOX/normal.fm" tools)" || fail "implementer.md declares no tools"
CRITICAL_TOOLS="$(fm_get "$SANDBOX/critical.fm" tools)" || fail "implementer-critical.md declares no tools"
[ -n "$NORMAL_TOOLS" ] || fail "implementer.md has an empty tools allowlist"
assert_eq "$NORMAL_TOOLS" "$CRITICAL_TOOLS" "tool allowlist"

# The field that gives TANDEM_CRITICAL its effect — exact value, and absent from
# the default agent (which must keep running at the harness default).
assert_eq "xhigh" "$(fm_get "$SANDBOX/critical.fm" effort)" "implementer-critical.md effort"
if fm_get "$SANDBOX/normal.fm" effort >/dev/null; then
  fail "implementer.md declares an effort — the default agent type must not"
fi

# The description is one of the three permitted differences, and it has to say
# what this agent type is for.
assert_file_contains "$SANDBOX/critical.fm" "TANDEM_CRITICAL"
assert_not_contains "$SANDBOX/normal.fm" "TANDEM_CRITICAL"

note "agents/implementer{,-critical}.md — bodies identical, only {name, description, effort} differ"
