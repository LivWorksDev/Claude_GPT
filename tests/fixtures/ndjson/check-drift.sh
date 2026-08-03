#!/usr/bin/env bash
# tandem tests — fixture drift check.
#
# usage: check-drift.sh <captured.ndjson> [more.ndjson …]
#
# Compares a freshly captured `codex exec --json` stream against the fixtures in
# this directory and reports, per (type, item_type) pair, which keys are new,
# which fixtures claim keys the real stream no longer emits, and which keys
# changed JSON type. Advisory by design: it prints a report and exits 1 when it
# found drift, 0 when the shapes agree.
#
# Portable: bash 3.2, jq only.

set -uo pipefail

DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

[ $# -ge 1 ] || {
  printf 'usage: check-drift.sh <captured.ndjson> [more.ndjson …]\n' >&2
  exit 64
}
command -v jq >/dev/null 2>&1 || { printf 'check-drift: jq not found\n' >&2; exit 3; }

# shape <file…> — one "type|item_type|key:jsontype" line per distinct shape,
# sorted and deduplicated. The JSON type travels WITH the key: a field that
# silently turns from number into string is drift the jq filters would feel
# (arithmetic on usage, exit_code comparisons), so it must be visible here.
# Non-JSON lines are skipped the same way the production filters skip them
# (fromjson?).
#
# The item class resolves `.item.type` FIRST: that is the discriminator
# codex-cli 0.144.4 really emits, so reading only the stale `.item.item_type`
# classified every real capture as `-` and left the tier-2 load-bearing checks
# permanently "advisory" — a drift report that could not detect the drift it
# exists for. `.item_type` stays as the compatibility read.
shape() {
  cat "$@" 2>/dev/null | jq -Rr '
    fromjson? |
    . as $e
    | (($e.type // "?")) as $t
    | (($e.item.type // $e.item.item_type // "-")) as $it
    | ([ $e | paths(scalars) ])[]
    | . as $p
    | "\($t)|\($it)|\($p | map(tostring) | join(".")):\($e | getpath($p) | type)"
  ' 2>/dev/null | LC_ALL=C sort -u
}

# Array indices differ run to run; collapse them so changes[0].path and
# changes[3].path count as one shape (the trailing form ends in ":type", hence
# the colon-anchored variant).
normalise() {
  LC_ALL=C sed -e 's|\.[0-9][0-9]*\.|.N.|g' -e 's|\.[0-9][0-9]*:|.N:|' \
    | LC_ALL=C sort -u
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/tandem-drift.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

shape "$DIR"/*.ndjson | normalise >"$tmp/fixtures"
shape "$@" | normalise >"$tmp/real"

printf 'fixture shapes: %s · captured shapes: %s\n' \
  "$(wc -l <"$tmp/fixtures" | tr -d ' ')" "$(wc -l <"$tmp/real" | tr -d ' ')"

drift=0

new="$(LC_ALL=C comm -13 "$tmp/fixtures" "$tmp/real")"
if [ -n "$new" ]; then
  drift=1
  printf '\nNEW in the captured stream (fixtures do not cover these):\n'
  printf '%s\n' "$new" | LC_ALL=C sed -e 's|^|  + |'
fi

gone="$(LC_ALL=C comm -23 "$tmp/fixtures" "$tmp/real")"
if [ -n "$gone" ]; then
  printf '\nONLY in the fixtures (not seen in this capture — may be fine if the\n'
  printf 'capture simply did not trigger the event):\n'
  printf '%s\n' "$gone" | LC_ALL=C sed -e 's|^|  - |'
fi

# The shapes the production filters actually read, in two tiers.
#
# Tier 1 — present in ANY successful capture: even a single one-turn "OK" smoke
# emits thread.started and turn.completed. Missing these is drift that WILL
# break the UI, not a coverage gap.
printf '\nload-bearing shapes (required in any successful capture):\n'
for want in \
  'thread.started|-|thread_id:string' \
  'turn.completed|-|usage.input_tokens:number' \
  'turn.completed|-|usage.output_tokens:number'; do
  if LC_ALL=C grep -Fqx -- "$want" "$tmp/real"; then
    printf '  ok       %s\n' "$want"
  else
    printf '  MISSING  %s\n' "$want"
    drift=1
  fi
done

# Tier 2 — enforced only when the capture actually triggered the event class:
# a minimal read-only smoke legitimately produces no command execution, no file
# change and no failure, and MUST NOT be permanently red for that. But when the
# class IS present with the wrong shape, that is real drift.
printf '\nload-bearing shapes (enforced only when the event class was triggered):\n'
for want in \
  'item.started|command_execution|item.command:string' \
  'item.completed|command_execution|item.exit_code:number' \
  'item.completed|file_change|item.changes.N.path:string' \
  'turn.failed|-|error.message:string' \
  'error|-|message:string'; do
  cls="${want%|*}"
  if LC_ALL=C grep -q "^$(printf '%s' "$cls" | LC_ALL=C sed -e 's|[.[\*^$]|\\&|g')|" "$tmp/real"; then
    if LC_ALL=C grep -Fqx -- "$want" "$tmp/real"; then
      printf '  ok       %s\n' "$want"
    else
      printf '  MISSING  %s (class present, shape wrong)\n' "$want"
      drift=1
    fi
  else
    printf '  advisory %s (class not triggered by this capture)\n' "$want"
  fi
done

if [ "$drift" -ne 0 ]; then
  printf '\ndrift detected — re-record the fixtures (see README.md) if the CLI changed.\n'
  exit 1
fi
printf '\nno drift.\n'
exit 0
