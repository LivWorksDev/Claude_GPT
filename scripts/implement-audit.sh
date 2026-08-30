#!/usr/bin/env bash
# tandem — audit dependency-sensitive writes made by one implementation attempt.
#
# The census and guard are a pair. snapshot publishes the census first and the
# guard second; close removes only the guard. An interrupted lifecycle therefore
# stays fail-closed, and snapshot knows how to repair either partial pair.
#
# Keep the path deny-list in sync with scripts/hook-implement-guard.sh: the hook
# stops common JS package-manager mutations early, while this script is the
# broader closing audit (including non-JS lockfiles and node_modules set diffs).

set -uo pipefail

LC_ALL=C
export LC_ALL

usage() {
  printf 'usage: implement-audit.sh snapshot <slug> <work_root>\n' >&2
  printf '       implement-audit.sh check <slug> <work_root>\n' >&2
  printf '       implement-audit.sh close <slug>\n' >&2
  exit 64
}

precondition() {
  printf 'tandem: implement audit: %s\n' "$1" >&2
  exit 65
}

valid_slug() {
  case "$1" in
    '' | '.' | '..' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

audit_init() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  AUDIT_DIR="$PROJECT_DIR/.tandem/state/implement-audit"
  if ! mkdir -p "$AUDIT_DIR" "$PROJECT_DIR/.tandem/log" "$PROJECT_DIR/.tandem/tmp"; then
    precondition "cannot create audit state under $PROJECT_DIR/.tandem"
  fi
  if [ ! -f "$PROJECT_DIR/.tandem/.gitignore" ]; then
    if ! printf '*\n' >"$PROJECT_DIR/.tandem/.gitignore"; then
      precondition "cannot protect .tandem state with .gitignore"
    fi
  fi
}

scratch_init() {
  SCRATCH="$(mktemp -d "$AUDIT_DIR/.audit.XXXXXX")" \
    || precondition "cannot create an audit temporary directory"
}

cleanup() {
  if [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ]; then
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT HUP INT TERM

resolve_identity() {
  [ -d "$WORK_ROOT_INPUT" ] \
    || precondition "work root is not a directory: $WORK_ROOT_INPUT"
  WORK_ROOT="$(CDPATH='' cd -- "$WORK_ROOT_INPUT" 2>/dev/null && pwd -P)" \
    || precondition "cannot resolve work root: $WORK_ROOT_INPUT"
  command -v git >/dev/null 2>&1 || precondition "git is not available"
  [ "$(git -C "$WORK_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
    || precondition "work root is not a git worktree: $WORK_ROOT"

  PLAN_PATH="docs/plans/$SLUG.plan.md"
  PLAN_HASH="$(git -C "$WORK_ROOT" rev-parse "HEAD:$PLAN_PATH" 2>/dev/null)" \
    || precondition "committed plan blob is unreadable: $PLAN_PATH"
  git -C "$WORK_ROOT" cat-file -e "$PLAN_HASH^{blob}" 2>/dev/null \
    || precondition "committed plan blob is unreadable: $PLAN_PATH"
  BASE_HEAD="$(git -C "$WORK_ROOT" rev-parse HEAD 2>/dev/null)" \
    || precondition "cannot read HEAD from $WORK_ROOT"
}

# build_node_records <output>
# D<TAB>relative node_modules dir
# E<TAB>relative node_modules dir<TAB>first-level entry name
build_node_records() {
  local output="$1" abs rel entry name
  : >"$SCRATCH/node-dirs.raw"
  if ! find "$WORK_ROOT" -maxdepth 4 -type d -name node_modules -prune -print \
    >"$SCRATCH/node-dirs.raw" 2>"$SCRATCH/find.err"; then
    precondition "cannot enumerate node_modules directories under $WORK_ROOT"
  fi

  : >"$SCRATCH/node-dirs"
  while IFS= read -r abs || [ -n "$abs" ]; do
    [ -n "$abs" ] || continue
    rel="${abs#"$WORK_ROOT"/}"
    [ "$rel" != "$abs" ] || continue
    printf '%s\n' "$rel" >>"$SCRATCH/node-dirs"
  done <"$SCRATCH/node-dirs.raw"
  sort -u "$SCRATCH/node-dirs" >"$SCRATCH/node-dirs.sorted"

  : >"$SCRATCH/node-entries"
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    (
      shopt -s dotglob nullglob
      for entry in "$WORK_ROOT/$rel"/*; do
        name="${entry##*/}"
        printf '%s\t%s\n' "$rel" "$name"
      done
    ) >>"$SCRATCH/node-entries"
  done <"$SCRATCH/node-dirs.sorted"
  sort -u "$SCRATCH/node-entries" >"$SCRATCH/node-entries.sorted"

  : >"$output"
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    printf 'D\t%s\n' "$rel" >>"$output"
  done <"$SCRATCH/node-dirs.sorted"
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    printf 'E\t%s\n' "$entry" >>"$output"
  done <"$SCRATCH/node-entries.sorted"
}

write_census() {
  local destination="$1"
  build_node_records "$SCRATCH/node-records"
  {
    printf 'format\t1\n'
    printf 'plan_hash\t%s\n' "$PLAN_HASH"
    printf 'base_head\t%s\n' "$BASE_HEAD"
    printf 'work_root\t%s\n' "$WORK_ROOT"
    printf 'plan_path\t%s\n' "$PLAN_PATH"
    cat "$SCRATCH/node-records"
  } >"$destination" || precondition "cannot write census temporary file"
}

census_value() {
  local census="$1" key="$2"
  awk -F '\t' -v wanted="$key" '
    $1 == wanted { print substr($0, length($1) + 2); exit }
  ' "$census"
}

validate_census_identity() {
  local census="$1" got_format got_plan got_head got_root got_path
  got_format="$(census_value "$census" format)"
  got_plan="$(census_value "$census" plan_hash)"
  got_head="$(census_value "$census" base_head)"
  got_root="$(census_value "$census" work_root)"
  got_path="$(census_value "$census" plan_path)"
  if [ "$got_format" != "1" ] \
    || [ "$got_plan" != "$PLAN_HASH" ] \
    || [ "$got_head" != "$BASE_HEAD" ] \
    || [ "$got_root" != "$WORK_ROOT" ] \
    || [ "$got_path" != "$PLAN_PATH" ]; then
    printf 'tandem: implement audit: census identity mismatch for %s; run the exact reset before retrying\n' \
      "$SLUG" >&2
    return 1
  fi
  return 0
}

publish_guard() {
  local tmp="$SCRATCH/guard.tmp"
  {
    printf 'slug\t%s\n' "$SLUG"
    printf 'plan_hash\t%s\n' "$PLAN_HASH"
    printf 'base_head\t%s\n' "$BASE_HEAD"
    printf 'work_root\t%s\n' "$WORK_ROOT"
  } >"$tmp" || precondition "cannot write guard temporary file"
  mv "$tmp" "$GUARD" || precondition "cannot publish implement guard"
}

snapshot_command() {
  audit_init
  scratch_init
  CENSUS="$AUDIT_DIR/$SLUG.census"
  GUARD="$AUDIT_DIR/$SLUG.guard"
  resolve_identity

  if [ -f "$CENSUS" ]; then
    validate_census_identity "$CENSUS" || exit 65
    if [ ! -e "$GUARD" ]; then
      publish_guard
    fi
    printf 'AUDIT: snapshot ready for %s\n' "$SLUG"
    exit 0
  fi

  write_census "$SCRATCH/census.tmp"
  mv "$SCRATCH/census.tmp" "$CENSUS" \
    || precondition "cannot publish implement census"
  if [ ! -e "$GUARD" ]; then
    publish_guard
  fi
  printf 'AUDIT: snapshot ready for %s\n' "$SLUG"
  exit 0
}

prepare_plan_section() {
  if ! git -C "$WORK_ROOT" cat-file blob "$PLAN_HASH" >"$SCRATCH/plan" 2>/dev/null; then
    precondition "committed plan blob is unreadable: $PLAN_HASH"
  fi
  awk '
    /^## Files to touch[[:space:]]*$/ { inside = 1; next }
    inside && /^##[[:space:]]/ { exit }
    inside { print }
  ' "$SCRATCH/plan" >"$SCRATCH/files-to-touch"
}

token_in_plan() {
  local token="$1"
  awk -v token="$token" '
    function delimiter(c) {
      return c == "" || index(" \t|`\"()[]{}:,;", c) > 0
    }
    {
      rest = $0
      while ((at = index(rest, token)) > 0) {
        before = (at == 1 ? "" : substr(rest, at - 1, 1))
        after = substr(rest, at + length(token), 1)
        if (delimiter(before) && delimiter(after)) found = 1
        rest = substr(rest, at + length(token))
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$SCRATCH/files-to-touch"
}

is_declared() {
  local path="$1" alternate="${2:-}"
  token_in_plan "$path" && return 0
  [ -n "$alternate" ] && token_in_plan "$alternate" && return 0
  return 1
}

record_violation() {
  local path="$1" reason="$2" alternate="${3:-}"
  if is_declared "$path" "$alternate"; then
    return 0
  fi
  printf 'VIOLATION: %s — %s\n' "$path" "$reason" >>"$SCRATCH/violations"
}

jq_dependency_subset() {
  local input="$1" output="$2"
  jq -S -c '
    if type != "object" then error("package.json is not an object") else
      with_entries(select(
        .key == "dependencies" or
        .key == "devDependencies" or
        .key == "peerDependencies" or
        .key == "optionalDependencies" or
        .key == "bundledDependencies" or
        .key == "resolutions" or
        .key == "overrides" or
        .key == "pnpm" or
        .key == "packageManager"
      ))
    end
  ' "$input" >"$output" 2>/dev/null
}

check_package_json() {
  local path="$1" seq head_exists=0 index_exists=0 work_exists=0 invalid=0 changed=0
  local side exists
  PKG_SEQ=$((PKG_SEQ + 1))
  seq="$PKG_SEQ"

  if ! command -v jq >/dev/null 2>&1; then
    record_violation "$path" "package.json modified; jq unavailable, so dependency audit fails closed"
    return 0
  fi

  if git -C "$WORK_ROOT" cat-file -e "HEAD:$path" 2>/dev/null; then
    head_exists=1
    git -C "$WORK_ROOT" show "HEAD:$path" >"$SCRATCH/pkg.$seq.head" 2>/dev/null \
      || invalid=1
  fi
  if git -C "$WORK_ROOT" cat-file -e ":0:$path" 2>/dev/null; then
    index_exists=1
    git -C "$WORK_ROOT" show ":0:$path" >"$SCRATCH/pkg.$seq.index" 2>/dev/null \
      || invalid=1
  fi
  if [ -f "$WORK_ROOT/$path" ]; then
    work_exists=1
    cp "$WORK_ROOT/$path" "$SCRATCH/pkg.$seq.work" 2>/dev/null || invalid=1
  fi

  if [ "$head_exists" -eq 1 ] && { [ "$index_exists" -eq 0 ] || [ "$work_exists" -eq 0 ]; }; then
    record_violation "$path" "package.json was deleted or renamed"
    return 0
  fi

  for side in head index work; do
    case "$side" in
      head) exists="$head_exists" ;;
      index) exists="$index_exists" ;;
      work) exists="$work_exists" ;;
    esac
    [ "$exists" -eq 1 ] || continue
    if ! jq_dependency_subset "$SCRATCH/pkg.$seq.$side" "$SCRATCH/pkg.$seq.$side.deps"; then
      invalid=1
    fi
  done
  if [ "$invalid" -ne 0 ]; then
    record_violation "$path" "package.json is unreadable or unparseable by jq; dependency audit fails closed"
    return 0
  fi

  if [ "$head_exists" -eq 0 ]; then
    if [ "$index_exists" -eq 1 ] && [ "$(cat "$SCRATCH/pkg.$seq.index.deps")" != "{}" ]; then
      changed=1
    fi
    if [ "$work_exists" -eq 1 ] && [ "$(cat "$SCRATCH/pkg.$seq.work.deps")" != "{}" ]; then
      changed=1
    fi
    if [ "$changed" -eq 1 ]; then
      record_violation "$path" "added package.json contains dependency-management keys"
    fi
    return 0
  fi

  if [ "$index_exists" -eq 1 ] \
    && ! cmp -s "$SCRATCH/pkg.$seq.head.deps" "$SCRATCH/pkg.$seq.index.deps"; then
    changed=1
  fi
  if [ "$work_exists" -eq 1 ] \
    && ! cmp -s "$SCRATCH/pkg.$seq.head.deps" "$SCRATCH/pkg.$seq.work.deps"; then
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    record_violation "$path" "package.json dependency-management keys changed"
  fi
}

check_git_writes() {
  local record path base patch_dir
  if ! git -C "$WORK_ROOT" -c core.quotePath=false status \
    --porcelain=v1 -z -uall --no-renames >"$SCRATCH/status" 2>"$SCRATCH/status.err"; then
    precondition "git status could not enumerate implementation writes"
  fi

  while IFS= read -r -d '' record; do
    [ "${#record}" -ge 4 ] || continue
    path="${record:3}"
    base="${path##*/}"
    case "$base" in
      pnpm-lock.yaml | yarn.lock | package-lock.json | .npmrc | Cargo.lock | poetry.lock | uv.lock | Gemfile.lock | go.sum | composer.lock)
        record_violation "$path" "deny-listed lockfile or dependency configuration changed"
        ;;
    esac
    case "$path" in
      patches/*)
        record_violation "$path" "entry under a patches/ directory changed" "patches/"
        ;;
      */patches/*)
        patch_dir="${path%%/patches/*}/patches/"
        record_violation "$path" "entry under a patches/ directory changed" "$patch_dir"
        ;;
    esac
    if [ "$base" = "package.json" ]; then
      check_package_json "$path"
    fi
  done <"$SCRATCH/status"
}

extract_census_nodes() {
  awk -F '\t' '$1 == "D" { print substr($0, 3) }' "$CENSUS" \
    | sort -u >"$SCRATCH/before.dirs"
  awk -F '\t' '$1 == "E" { print substr($0, 3) }' "$CENSUS" \
    | sort -u >"$SCRATCH/before.entries"
}

check_node_modules() {
  local path composite dir name
  build_node_records "$SCRATCH/current.records"
  extract_census_nodes
  awk -F '\t' '$1 == "D" { print substr($0, 3) }' "$SCRATCH/current.records" \
    | sort -u >"$SCRATCH/after.dirs"
  awk -F '\t' '$1 == "E" { print substr($0, 3) }' "$SCRATCH/current.records" \
    | sort -u >"$SCRATCH/after.entries"

  comm -23 "$SCRATCH/before.dirs" "$SCRATCH/after.dirs" >"$SCRATCH/dirs.removed"
  comm -13 "$SCRATCH/before.dirs" "$SCRATCH/after.dirs" >"$SCRATCH/dirs.added"
  comm -12 "$SCRATCH/before.dirs" "$SCRATCH/after.dirs" >"$SCRATCH/dirs.common"

  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    record_violation "$path" "censused node_modules directory disappeared" "$path/"
  done <"$SCRATCH/dirs.removed"
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    record_violation "$path" "new node_modules directory appeared" "$path/"
  done <"$SCRATCH/dirs.added"

  : >"$SCRATCH/common.before.entries"
  : >"$SCRATCH/common.after.entries"
  while IFS= read -r dir || [ -n "$dir" ]; do
    [ -n "$dir" ] || continue
    awk -F '\t' -v wanted="$dir" '$1 == wanted { print }' "$SCRATCH/before.entries" \
      >>"$SCRATCH/common.before.entries"
    awk -F '\t' -v wanted="$dir" '$1 == wanted { print }' "$SCRATCH/after.entries" \
      >>"$SCRATCH/common.after.entries"
  done <"$SCRATCH/dirs.common"
  sort -u "$SCRATCH/common.before.entries" >"$SCRATCH/common.before.sorted"
  sort -u "$SCRATCH/common.after.entries" >"$SCRATCH/common.after.sorted"
  comm -23 "$SCRATCH/common.before.sorted" "$SCRATCH/common.after.sorted" \
    >"$SCRATCH/entries.removed"
  comm -13 "$SCRATCH/common.before.sorted" "$SCRATCH/common.after.sorted" \
    >"$SCRATCH/entries.added"

  while IFS= read -r composite || [ -n "$composite" ]; do
    [ -n "$composite" ] || continue
    dir="${composite%%	*}"
    name="${composite#*	}"
    record_violation "$dir/$name" "first-level node_modules entry disappeared"
  done <"$SCRATCH/entries.removed"
  while IFS= read -r composite || [ -n "$composite" ]; do
    [ -n "$composite" ] || continue
    dir="${composite%%	*}"
    name="${composite#*	}"
    record_violation "$dir/$name" "first-level node_modules entry appeared"
  done <"$SCRATCH/entries.added"
}

check_command() {
  local count
  audit_init
  scratch_init
  CENSUS="$AUDIT_DIR/$SLUG.census"
  GUARD="$AUDIT_DIR/$SLUG.guard"
  resolve_identity
  : >"$SCRATCH/violations"
  PKG_SEQ=0

  if [ -f "$CENSUS" ]; then
    validate_census_identity "$CENSUS" || exit 65
  else
    printf 'WARN: census missing — node_modules changes unverified\n'
  fi
  prepare_plan_section
  check_git_writes
  if [ -f "$CENSUS" ]; then
    check_node_modules
  fi

  if [ -s "$SCRATCH/violations" ]; then
    cat "$SCRATCH/violations"
    count="$(wc -l <"$SCRATCH/violations" | tr -d ' ')"
    printf 'AUDIT: %s violation(s)\n' "$count"
    exit 20
  fi
  printf 'AUDIT: OK — no undeclared deny-list writes\n'
  exit 0
}

close_command() {
  audit_init
  GUARD="$AUDIT_DIR/$SLUG.guard"
  if ! rm -f "$GUARD"; then
    precondition "cannot remove implement guard for $SLUG"
  fi
  printf 'AUDIT: guard closed for %s\n' "$SLUG"
  exit 0
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift
case "$COMMAND" in
  snapshot | check)
    [ $# -eq 2 ] || usage
    SLUG="$1"
    WORK_ROOT_INPUT="$2"
    valid_slug "$SLUG" || usage
    "$COMMAND"_command
    ;;
  close)
    [ $# -eq 1 ] || usage
    SLUG="$1"
    valid_slug "$SLUG" || usage
    close_command
    ;;
  *) usage ;;
esac
