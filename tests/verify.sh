#!/usr/bin/env bash
# tandem — the single verification entry point. CI calls exactly this script.
#
#   bash tests/verify.sh                    # tests + shellcheck + actionlint
#   TANDEM_VERIFY_OFFLINE=1 bash tests/verify.sh   # tests only, loudly degraded
#   bash tests/verify.sh --record-checksums        # pin the tool checksums
#
# Three layers, all of them mandatory:
#   1. the test suite            (tests/run.sh)
#   2. shellcheck                (scripts/ and tests/, two invocations)
#   3. actionlint                (.github/workflows/)
#
# The lint binaries are PINNED and provisioned into tests/.tools/ (gitignored),
# downloaded per `uname -m` and verified against tests/checksums.txt. A layer
# that cannot run is a FAILURE that names itself — never a silent skip. The one
# way to run less than everything is TANDEM_VERIFY_OFFLINE=1, which is
# deliberate, prints a banner, and still exits non-zero if the tests fail.

set -uo pipefail

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd -P)"
TOOLS_DIR="$TESTS_DIR/.tools"
CHECKSUMS="$TESTS_DIR/checksums.txt"

SHELLCHECK_VERSION="0.10.0"
ACTIONLINT_VERSION="1.7.7"

RECORD=0
[ "${1:-}" = "--record-checksums" ] && RECORD=1

FAILED=""
note() { printf '\n=== %s ===\n' "$1"; }
layer_failed() { FAILED="$FAILED
  - $1"; printf 'VERIFY: layer FAILED — %s\n' "$1" >&2; }

# --- platform ----------------------------------------------------------------
case "$(uname -s)" in
  Darwin) OS_SC="darwin"; OS_AL="darwin" ;;
  Linux) OS_SC="linux"; OS_AL="linux" ;;
  *) printf 'verify: unsupported OS: %s\n' "$(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH_SC="x86_64"; ARCH_AL="amd64" ;;
  arm64 | aarch64) ARCH_SC="aarch64"; ARCH_AL="arm64" ;;
  *) printf 'verify: unsupported architecture: %s\n' "$(uname -m)" >&2; exit 2 ;;
esac

SHELLCHECK_ASSET="shellcheck-v${SHELLCHECK_VERSION}.${OS_SC}.${ARCH_SC}.tar.xz"
SHELLCHECK_URL="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${SHELLCHECK_ASSET}"
ACTIONLINT_ASSET="actionlint_${ACTIONLINT_VERSION}_${OS_AL}_${ARCH_AL}.tar.gz"
ACTIONLINT_URL="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_ASSET}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    printf 'verify: no sha256 tool (sha256sum / shasum) available\n' >&2
    return 1
  fi
}

expected_sum() {
  # expected_sum <asset> — the pinned sha256, or nothing.
  [ -f "$CHECKSUMS" ] || return 0
  LC_ALL=C awk -v a="$1" '$0 !~ /^#/ && $2 == a { print $1 }' "$CHECKSUMS" | head -n 1
}

fetch() {
  # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    printf 'verify: neither curl nor wget is available\n' >&2
    return 1
  fi
}

# provision <name> <version> <asset> <url> <path-of-binary-inside-archive>
# Prints the path to a checksum-verified binary. Prints nothing and returns
# non-zero when it cannot produce one — the caller turns that into a named
# layer failure.
#
# Only the release ARCHIVE is ever cached (tests/.tools/archives/, and that is
# also all CI restores). Its pinned sha256 is re-verified on EVERY run and the
# binary is re-extracted from it: a cached binary is never trusted, because the
# CI cache — like anything under gitignored .tools/ — is attacker-adjacent
# state that the pin committed in tests/checksums.txt must dominate.
provision() {
  local name="$1" version="$2" asset="$3" url="$4" inner="$5"
  local dest want got tmp got_version archive staged
  dest="$TOOLS_DIR/$name-$version/$(basename "$inner")"
  archive="$TOOLS_DIR/archives/$asset"

  want="$(expected_sum "$asset")"
  if [ -z "$want" ] || [ "$want" = "UNPINNED" ]; then
    if [ "$RECORD" -ne 1 ]; then
      printf 'verify: no sha256 pinned for %s in %s.\n' "$asset" "$CHECKSUMS" >&2
      printf '        Refusing to run an unverified binary. On a trusted machine run:\n' >&2
      printf '          bash tests/verify.sh --record-checksums\n' >&2
      printf '        then commit tests/checksums.txt.\n' >&2
      return 1
    fi
  fi

  if [ ! -f "$archive" ]; then
    mkdir -p "$TOOLS_DIR/archives"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/tandem-tool.XXXXXX")" || return 1
    if ! fetch "$url" "$tmp/$asset"; then
      printf 'verify: could not download %s\n' "$url" >&2
      printf '        (no network? re-run with TANDEM_VERIFY_OFFLINE=1 to run the\n' >&2
      printf '        tests alone — that is NOT the full gate.)\n' >&2
      rm -rf "$tmp"
      return 1
    fi
    mv "$tmp/$asset" "$archive"
    rm -rf "$tmp"
  fi

  got="$(sha256_of "$archive")" || return 1
  if [ "$RECORD" -eq 1 ] && { [ -z "$want" ] || [ "$want" = "UNPINNED" ]; }; then
    printf 'RECORD %s  %s\n' "$got" "$asset" >&2
    mkdir -p "$TOOLS_DIR"
    printf '%s  %s\n' "$got" "$asset" >>"$TOOLS_DIR/checksums.recorded"
    want="$got"
  fi
  if [ "$got" != "$want" ]; then
    printf 'verify: checksum mismatch for %s (cached archive dropped)\n  expected %s\n  got      %s\n' \
      "$asset" "$want" "$got" >&2
    rm -f "$archive"
    return 1
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tandem-tool.XXXXXX")" || return 1
  case "$asset" in
    *.tar.xz) tar -xJf "$archive" -C "$tmp" ;;
    *.tar.gz) tar -xzf "$archive" -C "$tmp" ;;
    *) printf 'verify: unknown archive type: %s\n' "$asset" >&2; rm -rf "$tmp"; return 1 ;;
  esac
  if [ ! -f "$tmp/$inner" ]; then
    printf 'verify: %s not found inside %s\n' "$inner" "$asset" >&2
    rm -rf "$tmp"
    return 1
  fi

  # Publish atomically via a fresh staged name. Every step is checked (this
  # function runs without -e), the version probe runs on the STAGED file —
  # verified archive content, never whatever already sits at $dest — and only a
  # successful rename makes it current. A leftover impostor at $dest that
  # cannot be replaced makes this FAIL; it is never executed.
  if ! mkdir -p "$TOOLS_DIR/$name-$version"; then
    rm -rf "$tmp"
    return 1
  fi
  staged="$(mktemp "$TOOLS_DIR/$name-$version/.staged.XXXXXX")" \
    || { rm -rf "$tmp"; return 1; }
  if ! cp "$tmp/$inner" "$staged" || ! chmod +x "$staged"; then
    printf 'verify: could not stage the %s binary\n' "$name" >&2
    rm -f "$staged"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  # Belt and braces: the pin is about reproducible findings, so the binary has
  # to actually be the pinned version.
  got_version="$("$staged" --version 2>/dev/null | LC_ALL=C tr -d '\r')"
  case "$got_version" in
    *"$version"*) : ;;
    *)
      printf 'verify: %s reports a version that is not %s:\n%s\n' \
        "$name" "$version" "$got_version" >&2
      rm -f "$staged"
      return 1
      ;;
  esac

  if ! mv -f "$staged" "$dest" || [ ! -x "$dest" ]; then
    printf 'verify: could not install the %s binary into place\n' "$name" >&2
    rm -f "$staged"
    return 1
  fi

  printf '%s' "$dest"
}

# Library mode: `TANDEM_VERIFY_LIB=1 . tests/verify.sh` gives the test suite
# access to provision() and friends without running any layer. Honoured ONLY
# when this file is genuinely being sourced: a leaked variable on a direct
# `bash tests/verify.sh` must refuse loudly, never become a silent green gate
# (TANDEM_VERIFY_OFFLINE=1 is the one permitted degradation, and it is noisy).
if [ "${TANDEM_VERIFY_LIB:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  printf 'verify: TANDEM_VERIFY_LIB=1 is only meaningful when SOURCING this file.\n' >&2
  printf '        Refusing to run: a leaked variable must not skip the gate.\n' >&2
  exit 2
fi

# --- layer 1: the suite -------------------------------------------------------
note "tests"
if "${TESTS_BASH:-${BASH:-/bin/bash}}" "$TESTS_DIR/run.sh"; then
  TESTS_OK=1
else
  TESTS_OK=0
  layer_failed "tests (tests/run.sh)"
fi

if [ "${TANDEM_VERIFY_OFFLINE:-0}" = "1" ]; then
  printf '\n'
  printf '################################################################\n'
  printf '# TANDEM_VERIFY_OFFLINE=1 — DEGRADED RUN, NOT THE FULL GATE.   #\n'
  printf '# Layers NOT executed:                                         #\n'
  printf '#   - shellcheck (scripts/ and tests/)                         #\n'
  printf '#   - actionlint (.github/workflows/)                          #\n'
  printf '# Re-run without TANDEM_VERIFY_OFFLINE before trusting this.   #\n'
  printf '################################################################\n'
  [ "$TESTS_OK" -eq 1 ] || exit 1
  exit 0
fi

mkdir -p "$TOOLS_DIR"

# --- layer 2: shellcheck ------------------------------------------------------
note "shellcheck v$SHELLCHECK_VERSION"
SC="$(provision shellcheck "$SHELLCHECK_VERSION" "$SHELLCHECK_ASSET" \
  "$SHELLCHECK_URL" "shellcheck-v$SHELLCHECK_VERSION/shellcheck")"
if [ -z "$SC" ] || [ ! -x "$SC" ]; then
  layer_failed "shellcheck (could not provision the pinned binary)"
else
  "$SC" --version | LC_ALL=C sed -e 's|^|  |'
  # -x follows the `. _common.sh` sourcing; --source-path=SCRIPTDIR resolves it
  # relative to each script instead of the working directory.
  if "$SC" --source-path=SCRIPTDIR -x "$REPO_ROOT"/scripts/*.sh; then
    printf 'shellcheck: scripts/ clean\n'
  else
    layer_failed "shellcheck (scripts/)"
  fi
  if "$SC" --source-path=SCRIPTDIR -x \
    "$TESTS_DIR"/*.sh "$TESTS_DIR"/*.test.sh "$TESTS_DIR"/stub/codex \
    "$TESTS_DIR"/fixtures/hang/*.test.sh "$TESTS_DIR"/fixtures/ndjson/check-drift.sh; then
    printf 'shellcheck: tests/ clean\n'
  else
    layer_failed "shellcheck (tests/)"
  fi
fi

# --- layer 3: actionlint ------------------------------------------------------
note "actionlint v$ACTIONLINT_VERSION"
AL="$(provision actionlint "$ACTIONLINT_VERSION" "$ACTIONLINT_ASSET" \
  "$ACTIONLINT_URL" "actionlint")"
if [ -z "$AL" ] || [ ! -x "$AL" ]; then
  layer_failed "actionlint (could not provision the pinned binary)"
else
  "$AL" --version | head -n 1 | LC_ALL=C sed -e 's|^|  |'
  # actionlint shells out to shellcheck for `run:` blocks; point it at the
  # pinned one so CI and local runs agree.
  if [ -n "${SC:-}" ] && [ -x "${SC:-}" ]; then
    AL_SHELLCHECK="-shellcheck=$SC"
  else
    AL_SHELLCHECK="-shellcheck="
  fi
  if ( cd "$REPO_ROOT" && "$AL" -no-color "$AL_SHELLCHECK" ); then
    printf 'actionlint: workflows clean\n'
  else
    layer_failed "actionlint (.github/workflows/)"
  fi
fi

# --- verdict ------------------------------------------------------------------
printf '\n'
if [ -n "$FAILED" ]; then
  printf 'VERIFY FAILED. Layers that did not pass:%s\n' "$FAILED"
  exit 1
fi
printf 'VERIFY OK — tests, shellcheck and actionlint all green.\n'
exit 0
