#!/usr/bin/env bash
#
# apply_build_pins.sh -- put the pinned zenoh-core resolution where cargo will
# read it, and prove the pin file and the lockfiles still agree.
#
# THE PROBLEM IT SOLVES
#
# zenoh-c asks for the zenoh crates by BRANCH (`release/1.8.0`), and the
# Cargo.lock committed at zenoh-c's own 1.8.0 tag names a DIFFERENT resolution
# (`branch=main#c3761375...`). So in a fresh clone cargo re-resolves against a
# branch that can move, and the library it produces looks identical to the one
# we certified while being built from different source. See build-pins/zenoh-core.pin.
#
# WHAT IT DOES
#
#   * copies build-pins/zenoh-c/**/Cargo.lock over the submodule's copies, but
#     only when they differ, and never before saving what was there;
#   * asserts the pin file's ZENOH_CORE_COMMIT actually appears in the lockfile
#     it applied -- two records that must agree, so editing one alone stops the
#     build instead of shipping a mismatch.
#
# ⛔ IT NEVER RESETS, RESTORES, DELETES OR `cargo update`s ANYTHING. Before the
# pin tree existed, the submodule's working-tree Cargo.lock was the ONLY record
# on any machine of the resolution our shipped libraries were built from, and
# the submodule's working tree is shared between sessions. Anything this script
# would overwrite is copied to <name>.pre-pin first, and an existing .pre-pin is
# never clobbered -- the first thing displaced is the thing worth keeping.
#
# Idempotent. Run from anywhere. Both build paths call it: the root
# CMakeLists.txt at configure time, and scripts/build_zenoh_android.sh before
# cargo-ndk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="${ROOT}/build-pins"
ZC="${ROOT}/extern/zenoh-c"
PINFILE="${PINS}/zenoh-core.pin"

die() { echo "apply_build_pins: $*" >&2; exit 1; }

# ⛔ A MISSING PIN TREE IS A HARD FAILURE, NOT A FALLBACK. If the release
# assembly ever fails to carry build-pins/, the build must stop here rather
# than quietly resolve the branch itself and ship an uncertified core.
[ -f "$PINFILE" ] || die "missing $PINFILE -- build-pins/ was not carried into this tree.
The build refuses to resolve the zenoh core on its own: that is the defect the
pin exists to close. Restore build-pins/ from the release commit."
[ -d "$ZC" ] || die "missing $ZC -- run 'git submodule update --init --recursive'"

# shellcheck disable=SC1090
ZENOH_CORE_COMMIT=""; ZENOH_CORE_VERSION_STRING=""
while IFS='=' read -r k v; do
  case "$k" in
    ZENOH_CORE_COMMIT)         ZENOH_CORE_COMMIT="$v" ;;
    ZENOH_CORE_VERSION_STRING) ZENOH_CORE_VERSION_STRING="$v" ;;
  esac
done < <(grep -E '^[A-Z_]+=' "$PINFILE")
[ -n "$ZENOH_CORE_COMMIT" ] || die "$PINFILE declares no ZENOH_CORE_COMMIT"

apply_one() {
  local rel="$1"
  local src="${PINS}/zenoh-c/${rel}"
  local dst="${ZC}/${rel}"
  [ -f "$src" ] || die "missing pinned lockfile $src"
  [ -d "$(dirname "$dst")" ] || die "no such directory in the submodule: $(dirname "$dst")"

  # The pin and the lockfile are two records of one fact. Check they agree
  # BEFORE writing anything, so a mismatch never reaches the submodule.
  grep -q "$ZENOH_CORE_COMMIT" "$src" \
    || die "$src does not name ZENOH_CORE_COMMIT=$ZENOH_CORE_COMMIT from $PINFILE.
The pin file and the pinned lockfile disagree. Fix them together; the bump is
one commit or it is a mismatch."

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi
  if [ -f "$dst" ] && [ ! -f "${dst}.pre-pin" ]; then
    cp -p "$dst" "${dst}.pre-pin"
    echo "apply_build_pins: saved displaced ${rel} to ${rel}.pre-pin"
  fi
  cp "$src" "$dst"
  echo "apply_build_pins: applied pinned ${rel} (core ${ZENOH_CORE_COMMIT})"
}

apply_one "Cargo.lock"
apply_one "build-resources/opaque-types/Cargo.lock"

# ⭐ Verify the ARTIFACT on disk, not this script's own report of what it did.
for rel in "Cargo.lock" "build-resources/opaque-types/Cargo.lock"; do
  cmp -s "${PINS}/zenoh-c/${rel}" "${ZC}/${rel}" \
    || die "after applying, ${ZC}/${rel} still differs from the pin"
done
