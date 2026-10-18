#!/usr/bin/env bash
# agents/council-fable-offline.md is agents/council-fable.md with three
# frontmatter fields changed — name, description, tools — and NOTHING else.
#
# Same two invisible failure modes as the implementer twins. DRIFT: the seat's
# rules live in the BODY (read-only, never read the run directory, never reveal
# the model), so an offline twin that lost one of them would keep every
# behavioural test green — the body is compared BYTE FOR BYTE. And the PIN: the
# model and effort of the Claude seat live ONLY in these two frontmatters
# (scripts/council.sh reads them from here), so both carry the full model id and
# max, never an alias that could resolve to another generation. The tool sets
# are exact: the confidential mode is guaranteed by the offline allowlist, not
# by an instruction, and no seat can write, run commands or spawn agents.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WEB="$REPO_ROOT/agents/council-fable.md"
OFFLINE="$REPO_ROOT/agents/council-fable-offline.md"
assert_file "$WEB"
assert_file "$OFFLINE"

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

split_agent "$WEB" "$SANDBOX/web"
split_agent "$OFFLINE" "$SANDBOX/offline"

# --- the body, byte for byte, and never vacuously ----------------------------
if ! cmp -s "$SANDBOX/web.body" "$SANDBOX/offline.body"; then
  diff "$SANDBOX/web.body" "$SANDBOX/offline.body" >&2 || true
  fail "the offline seat's body is not byte-for-byte identical to the web seat's"
fi
assert_file_contains "$SANDBOX/web.body" "asiento de solo lectura"
assert_file_contains "$SANDBOX/web.body" "Lee COMPLETO el fichero de fase que nombra la tarea y responde exactamente como pide."
assert_file_contains "$SANDBOX/web.body" "Nunca escribes, creas, mueves ni borras ningún fichero."
assert_file_contains "$SANDBOX/web.body" 'No leas nada bajo el directorio del run (`docs/council/<run-id>/`) ni bajo `.tandem/`, salvo el fichero de fase que nombra la tarea.'
assert_file_contains "$SANDBOX/web.body" "no reveles qué modelo eres"

# --- the frontmatter: only name, description and tools may differ ------------
fm_keys "$SANDBOX/web.fm" >"$SANDBOX/keys.raw"
fm_keys "$SANDBOX/offline.fm" >>"$SANDBOX/keys.raw"
LC_ALL=C sort -u "$SANDBOX/keys.raw" >"$SANDBOX/keys"
while IFS= read -r key; do
  [ -n "$key" ] || continue
  whas=1
  ohas=1
  wv="$(fm_get "$SANDBOX/web.fm" "$key")" || whas=0
  ov="$(fm_get "$SANDBOX/offline.fm" "$key")" || ohas=0
  if [ "$whas" = "$ohas" ] && [ "$wv" = "$ov" ]; then continue; fi
  case "$key" in
    name | description | tools) : ;;
    *) fail "frontmatter key [$key] differs (web=[$wv] offline=[$ov]) — only name, description and tools may differ" ;;
  esac
done <"$SANDBOX/keys"

# --- the identifiers the skill dispatches -------------------------------------
assert_eq "council-fable" "$(fm_get "$SANDBOX/web.fm" name)" "council-fable.md name"
assert_eq "council-fable-offline" "$(fm_get "$SANDBOX/offline.fm" name)" "council-fable-offline.md name"

# --- the pin: a FULL model id at max, identical in both -----------------------
for side in web offline; do
  assert_eq "claude-fable-5-1" "$(fm_get "$SANDBOX/$side.fm" model)" "$side seat model"
  assert_eq "max" "$(fm_get "$SANDBOX/$side.fm" effort)" "$side seat effort"
  assert_eq "50" "$(fm_get "$SANDBOX/$side.fm" maxTurns)" "$side seat maxTurns"
done

# --- the exact tool sets ------------------------------------------------------
WEB_TOOLS="$(fm_get "$SANDBOX/web.fm" tools)" || fail "council-fable.md declares no tools"
OFF_TOOLS="$(fm_get "$SANDBOX/offline.fm" tools)" || fail "council-fable-offline.md declares no tools"
assert_eq "$(printf 'Glob\nGrep\nRead\nWebFetch\nWebSearch\n' | LC_ALL=C sort)" "$(tool_set "$WEB_TOOLS")" \
  "the web seat's tool set"
assert_eq "$(printf 'Glob\nGrep\nRead\n' | LC_ALL=C sort)" "$(tool_set "$OFF_TOOLS")" \
  "the offline seat's tool set"
for tools in "$WEB_TOOLS" "$OFF_TOOLS"; do
  for forbidden in Bash Edit Write Agent Task NotebookEdit; do
    if tool_set "$tools" | LC_ALL=C grep -qx "$forbidden"; then
      fail "a council seat may never carry the $forbidden tool (tools: $tools)"
    fi
  done
done

# The descriptions are permitted to differ, and the offline one says why.
assert_file_contains "$SANDBOX/offline.fm" "no web tools"
assert_not_contains "$SANDBOX/web.fm" "no web tools"

note "agents/council-fable{,-offline}.md — bodies identical, pin claude-fable-5-1/max, exact tool sets"
