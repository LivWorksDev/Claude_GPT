#!/usr/bin/env bash
# The six Fable seats of the council — one web/offline pair per effort profile
# (council-fable{,-offline}.md at max for critico, council-fable-xhigh{,-offline}.md
# for estandar, council-fable-high{,-offline}.md for exploratorio) — are ONE
# agent: they may differ only in name, description, effort (the pair's level)
# and tools (the exact web or offline set), and in NOTHING else.
#
# Same two invisible failure modes as the implementer twins. DRIFT: the seat's
# rules live in the BODY (read-only, never read the run directory, never reveal
# the model), so an offline twin that lost one of them would keep every
# behavioural test green — the body is compared BYTE FOR BYTE. And the PIN: the
# model and effort of the Claude seat live ONLY in these frontmatters
# (scripts/council.sh reads them from here), so all six carry the same full
# model id, never an alias that could resolve to another generation, and each
# pair carries exactly its profile's level. The tool sets
# are exact: the confidential mode is guaranteed by the offline allowlist, not
# by an instruction, and no seat can write, run commands or spawn agents.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

AG="$REPO_ROOT/agents"
# <base> <level> — the three pairs.
PAIRS="council-fable:max council-fable-xhigh:xhigh council-fable-high:high"
for pair in $PAIRS; do
  assert_file "$AG/${pair%%:*}.md"
  assert_file "$AG/${pair%%:*}-offline.md"
done
# No seventh seat: every council-fable*.md is one of the six.
for f in "$AG"/council-fable*.md; do
  b="${f##*/}"
  b="${b%.md}"
  b="${b%-offline}"
  case " $PAIRS " in *" $b:"*) : ;; *) fail "an unexpected council agent: $f" ;; esac
done

# split_agent <file> <prefix> — <prefix>.fm (frontmatter lines) and
# <prefix>.body (everything after the closing delimiter, the file's own bytes).
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

# fm_get <fm-file> <key> — the trimmed value; rc 1 when the key is absent.
fm_get() {
  local f="$1" key="$2" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *:*) : ;; *) continue ;; esac
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

fm_keys() {
  local f="$1" line k
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *:*) : ;; *) continue ;; esac
    k="${line%%:*}"
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    [ -n "$k" ] || continue
    printf '%s\n' "$k"
  done <"$f"
}

# tool_set <tools-value> — one tool per line, sorted: the comparison is a SET.
tool_set() {
  printf '%s\n' "$1" | LC_ALL=C tr ',' '\n' | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | LC_ALL=C grep -v '^$' | LC_ALL=C sort
}

WEB_TOOLS_WANT="$(printf 'Glob\nGrep\nRead\nWebFetch\nWebSearch\n' | LC_ALL=C sort)"
OFF_TOOLS_WANT="$(printf 'Glob\nGrep\nRead\n' | LC_ALL=C sort)"
split_agent "$AG/council-fable.md" "$SANDBOX/ref"

for pair in $PAIRS; do
  base="${pair%%:*}"
  level="${pair#*:}"
  for side in web offline; do
    name="$base"
    [ "$side" = "offline" ] && name="$base-offline"
    f="$AG/$name.md"
    p="$SANDBOX/$name"
    split_agent "$f" "$p"

    # --- the body, byte for byte, and never vacuously ------------------------
    if ! cmp -s "$SANDBOX/ref.body" "$p.body"; then
      diff "$SANDBOX/ref.body" "$p.body" >&2 || true
      fail "$name.md: its body is not byte-for-byte identical to council-fable.md's"
    fi

    # --- the frontmatter: only name, description, effort and tools differ ----
    fm_keys "$SANDBOX/ref.fm" >"$SANDBOX/keys.raw"
    fm_keys "$p.fm" >>"$SANDBOX/keys.raw"
    LC_ALL=C sort -u "$SANDBOX/keys.raw" >"$SANDBOX/keys"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      rhas=1
      phas=1
      rv="$(fm_get "$SANDBOX/ref.fm" "$key")" || rhas=0
      pv="$(fm_get "$p.fm" "$key")" || phas=0
      if [ "$rhas" = "$phas" ] && [ "$rv" = "$pv" ]; then continue; fi
      case "$key" in
        name | description | effort | tools) : ;;
        *) fail "$name.md: frontmatter key [$key] differs (council-fable.md=[$rv] $name.md=[$pv]) — only name, description, effort and tools may differ" ;;
      esac
    done <"$SANDBOX/keys"

    # --- the identifier the skill dispatches, the pin, the level -------------
    assert_eq "$name" "$(fm_get "$p.fm" name)" "$name.md name"
    assert_eq "claude-fable-5-1" "$(fm_get "$p.fm" model)" "$name.md model (the same full id in all six)"
    assert_eq "$level" "$(fm_get "$p.fm" effort)" "$name.md effort (its pair's level)"
    assert_eq "50" "$(fm_get "$p.fm" maxTurns)" "$name.md maxTurns"
    assert_file_contains "$p.fm" "$level effort"

    # --- the exact tool sets -------------------------------------------------
    tools="$(fm_get "$p.fm" tools)" || fail "$name.md declares no tools"
    if [ "$side" = "web" ]; then
      assert_eq "$WEB_TOOLS_WANT" "$(tool_set "$tools")" "$name.md tool set (web)"
      assert_not_contains "$p.fm" "no web tools"
    else
      assert_eq "$OFF_TOOLS_WANT" "$(tool_set "$tools")" "$name.md tool set (offline)"
      assert_file_contains "$p.fm" "no web tools"
    fi
    for forbidden in Bash Edit Write Agent Task NotebookEdit; do
      if tool_set "$tools" | LC_ALL=C grep -qx "$forbidden"; then
        fail "a council seat may never carry the $forbidden tool ($name.md tools: $tools)"
      fi
    done
  done
done

# The body says what a seat is (never vacuously identical).
assert_file_contains "$SANDBOX/ref.body" "asiento de solo lectura"
assert_file_contains "$SANDBOX/ref.body" "Lee COMPLETO el fichero de fase que nombra la tarea y responde exactamente como pide."
assert_file_contains "$SANDBOX/ref.body" "Nunca escribes, creas, mueves ni borras ningún fichero."
assert_file_contains "$SANDBOX/ref.body" 'No leas nada bajo el directorio del run (`docs/council/<run-id>/`) ni bajo `.tandem/`, salvo el fichero de fase que nombra la tarea.'
assert_file_contains "$SANDBOX/ref.body" "no reveles qué modelo eres"

note "agents/council-fable{,-xhigh,-high}{,-offline}.md — six bodies identical, pin claude-fable-5-1, levels max/xhigh/high, exact tool sets"
