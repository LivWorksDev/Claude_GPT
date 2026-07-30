#!/usr/bin/env bash
# provision() treats everything under gitignored .tools/ as attacker-adjacent:
# the archive's pinned sha256 is re-verified on every run, the version probe
# only ever runs on the freshly staged file, and a pre-existing impostor at the
# destination that cannot be replaced makes provisioning FAIL — it is never
# executed.
#
# SC2317: sourcing verify.sh in library mode hits its `return … || exit` guard;
# the static analyzer cannot see that the return path is the one taken and
# flags everything after the source as unreachable.
# shellcheck disable=SC2317
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# Library mode: definitions only, no layers run.
TANDEM_VERIFY_LIB=1
# shellcheck source=verify.sh
. "$TESTS_DIR/verify.sh"

# Re-point the globals provision() reads at sandbox-local state.
TOOLS_DIR="$SANDBOX/tools"
CHECKSUMS="$SANDBOX/checksums.txt"
RECORD=0

# A fake release asset whose inner binary reports the pinned version.
ASSET="fake_9.9.9.tar.gz"
WORK="$SANDBOX/asset"
mkdir -p "$WORK"
cat >"$WORK/faketool" <<'SH'
#!/bin/sh
echo "faketool 9.9.9"
SH
chmod +x "$WORK/faketool"
( cd "$WORK" && tar -czf "$ASSET" faketool )
SUM="$(sha256_of "$WORK/$ASSET")" || fail "sha256_of failed"
printf '%s  %s\n' "$SUM" "$ASSET" >"$CHECKSUMS"
mkdir -p "$TOOLS_DIR/archives"
cp "$WORK/$ASSET" "$TOOLS_DIR/archives/$ASSET"

# --- happy path: verified archive -> staged -> atomic publish ----------------
P="$(provision fake 9.9.9 "$ASSET" "http://unused.invalid/x" faketool)" \
  || fail "provision failed on the happy path"
assert_eq "$TOOLS_DIR/fake-9.9.9/faketool" "$P" "published path"
assert_eq "faketool 9.9.9" "$("$P" --version)" "published binary answers"
if ls "$TOOLS_DIR/fake-9.9.9"/.staged.* >/dev/null 2>&1; then
  fail "a staged temp file was left behind"
fi

# --- a pre-existing, unreplaceable impostor is NEVER executed ----------------
# The impostor mimics the pinned version, so only the staging discipline (probe
# the staged file, then rename) stands between it and the lint layers.
rm -rf "$TOOLS_DIR/fake-9.9.9"
mkdir -p "$TOOLS_DIR/fake-9.9.9"
cat >"$TOOLS_DIR/fake-9.9.9/faketool" <<SH
#!/bin/sh
: >"$SANDBOX/impostor-executed"
echo "faketool 9.9.9"
SH
chmod +x "$TOOLS_DIR/fake-9.9.9/faketool"
chmod 555 "$TOOLS_DIR/fake-9.9.9"

rc=0
GOT="$(provision fake 9.9.9 "$ASSET" "http://unused.invalid/x" faketool)" || rc=$?
chmod 755 "$TOOLS_DIR/fake-9.9.9"
[ "$rc" -ne 0 ] || fail "provision claimed success with an unreplaceable destination"
assert_eq "" "$GOT" "no path is printed on failure"
assert_no_file "$SANDBOX/impostor-executed"

# --- a tampered cached archive is refused AND dropped ------------------------
printf 'garbage, not the pinned archive\n' >"$TOOLS_DIR/archives/$ASSET"
rc=0
GOT="$(provision fake 9.9.9 "$ASSET" "http://unused.invalid/x" faketool 2>"$ERR")" || rc=$?
[ "$rc" -ne 0 ] || fail "provision accepted a tampered archive"
assert_eq "" "$GOT" "no path from a tampered archive"
assert_file_contains "$ERR" "checksum mismatch"
assert_no_file "$TOOLS_DIR/archives/$ASSET"
assert_no_file "$SANDBOX/impostor-executed"

# --- an unpinned asset is refused before anything runs -----------------------
printf '%s  %s\n' "UNPINNED" "$ASSET" >"$CHECKSUMS"
cp "$WORK/$ASSET" "$TOOLS_DIR/archives/$ASSET"
rc=0
GOT="$(provision fake 9.9.9 "$ASSET" "http://unused.invalid/x" faketool 2>"$ERR")" || rc=$?
[ "$rc" -ne 0 ] || fail "provision ran with an UNPINNED checksum"
assert_file_contains "$ERR" "Refusing to run an unverified binary"

# --- a leaked TANDEM_VERIFY_LIB never silently skips the gate ----------------
# Library mode is for SOURCING only; executing the script with the variable
# exported must refuse with a distinct code and run zero layers.
run env TANDEM_VERIFY_LIB=1 "$TESTS_BASH" "$TESTS_DIR/verify.sh"
assert_rc 2 "executed directly with TANDEM_VERIFY_LIB=1"
assert_file_contains "$ERR" "Refusing to run: a leaked variable must not skip the gate."
assert_not_contains "$OUT" "==="
