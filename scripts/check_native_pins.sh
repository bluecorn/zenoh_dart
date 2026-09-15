#!/usr/bin/env bash
#
# check_native_pins.sh -- assert, ON THE BUILT ARTIFACT, that
#
#   (1) every core library embeds the pinned zenoh resolution, and
#   (2) no library embeds a path from the machine that built it.
#
# WHY THE ARTIFACT AND NOT THE BUILD FLAGS
#
# Both properties are delivered by build flags -- `--locked` against the pinned
# lockfile, and `--remap-path-prefix` / `-ffile-prefix-map`. Asserting that the
# flags were PASSED proves nothing about what came out: cargo's `build.rustflags`
# is silently overridden by a RUSTFLAGS in the environment (env beats config),
# an added dependency can bring its own path strings, and a toolchain can record
# a path through a mechanism nobody enumerated. ⭐ An assertion about the
# artifact holds whatever the build did, including the paths nobody thought of.
#
# TWO ARMS, DIFFERENT MECHANISMS
#
#   grep -aoF   counts raw byte occurrences, needs no binutils
#   strings -a  counts strings containing the pattern -- the instrument the
#               acceptance criterion names
# They count DIFFERENT NOUNS and are compared only at zero, where they must
# agree. A disagreement is reported rather than resolved.
#
# WHAT IT FORBIDS, and why more than the stated `/home/`
#
# The acceptance is `strings -a <so> | grep -c /home/` == 0. That is necessary
# and not sufficient: a builder whose home is /root or /github/workspace passes
# it while leaking just as much. So this also forbids the ACTUAL $HOME,
# $CARGO_HOME and repository root of the machine running the check.
#
# Usage:
#   scripts/check_native_pins.sh <lib.so> [<lib.so> ...]
#   scripts/check_native_pins.sh --all-shipped     # every variant library
#   scripts/check_native_pins.sh --selftest        # prove the check can fail
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINFILE="${ROOT}/build-pins/zenoh-core.pin"

ZENOH_CORE_VERSION_STRING=""
if [ -f "$PINFILE" ]; then
  ZENOH_CORE_VERSION_STRING="$(sed -n 's/^ZENOH_CORE_VERSION_STRING=//p' "$PINFILE")"
fi
[ -n "$ZENOH_CORE_VERSION_STRING" ] || {
  echo "check_native_pins: no ZENOH_CORE_VERSION_STRING in $PINFILE" >&2; exit 1; }

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"

# Patterns every library must NOT contain. The literal `/home/` is the stated
# acceptance; the rest are this machine's real prefixes, which is the half that
# survives being run somewhere else.
forbidden_patterns() {
  printf '%s\n' "/home/" "$HOME" "$CARGO_HOME_DIR" "$ROOT"
}

fails=0

check_one() {
  local so="$1" is_core=0 bad=0
  case "$(basename "$so")" in libzenohc.so) is_core=1 ;; esac

  if [ ! -f "$so" ]; then
    echo "  MISS $so -- not found"; fails=$((fails+1)); return
  fi

  if [ "$is_core" = 1 ]; then
    local n
    n=$(grep -aoF "$ZENOH_CORE_VERSION_STRING" "$so" | wc -l)
    if [ "$n" -lt 1 ]; then
      echo "  FAIL $so"
      echo "       does not embed the pinned core string $ZENOH_CORE_VERSION_STRING"
      echo "       -- it was built from a different zenoh resolution. See build-pins/zenoh-core.pin."
      bad=1
    fi
  fi

  local pat n2 n3 report="" worst=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    n2=$(grep -aoF "$pat" "$so" | wc -l)
    n3=-1
    if command -v strings >/dev/null 2>&1; then
      n3=$(strings -a "$so" | grep -cF "$pat")
    fi
    if [ "$n2" -ne 0 ]; then
      report="${report}       ${n2} occurrence(s) of '${pat}'"$'\n'
      worst="$pat"
      bad=1
    fi
    if [ "$n3" -ge 0 ]; then
      if { [ "$n2" -eq 0 ] && [ "$n3" -ne 0 ]; } || { [ "$n2" -ne 0 ] && [ "$n3" -eq 0 ]; }; then
        report="${report}       ARMS DISAGREE AT ZERO for '${pat}': grep=${n2} strings=${n3}"$'\n'
        bad=1
      fi
    fi
  done < <(forbidden_patterns)
  if [ -n "$report" ]; then
    echo "  FAIL $so -- embeds build paths:"
    printf '%s' "$report"
    if [ -n "$worst" ] && command -v strings >/dev/null 2>&1; then
      strings -a "$so" | grep -F "$worst" | head -3 | cut -c1-140 | sed 's/^/         e.g. /'
    fi
  fi

  if [ "$bad" = 0 ]; then
    if [ "$is_core" = 1 ]; then
      echo "  OK   $so (core ${ZENOH_CORE_VERSION_STRING}, no build paths)"
    else
      echo "  OK   $so (no build paths)"
    fi
  else
    fails=$((fails+1))
  fi
}

selftest() {
  # ⭐ A CONTROL, not a replication. Prove the check FAILS on a file that
  # carries what it forbids -- otherwise every OK above could be an OK for a
  # file the check never really read.
  local d; d="$(mktemp -d)"
  trap 'rm -rf "$d"' RETURN
  printf 'harmless\n' > "$d/clean.so"
  printf 'x%s/somewhere/file.rs\n' "$HOME" > "$d/dirty.so"

  echo "selftest: a file with no build path must pass"
  fails=0; check_one "$d/clean.so"
  [ "$fails" -eq 0 ] || { echo "SELFTEST FAILED: clean file rejected"; return 1; }

  echo "selftest: a file containing \$HOME must fail"
  fails=0; check_one "$d/dirty.so" >/dev/null
  [ "$fails" -eq 1 ] || { echo "SELFTEST FAILED: dirty file accepted"; return 1; }

  echo "selftest: a core-named file without the pinned string must fail"
  printf 'harmless\n' > "$d/libzenohc.so"
  fails=0; check_one "$d/libzenohc.so" >/dev/null
  [ "$fails" -eq 1 ] || { echo "SELFTEST FAILED: wrong-core file accepted"; return 1; }

  echo "selftest: PASSED -- the check can detect all three violations"
  fails=0
  return 0
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --all-shipped)
    echo "check_native_pins: every VARIANT library under package/native/"
    while IFS= read -r so; do check_one "$so"; done < <(
      /usr/bin/find "$ROOT/package/native" -mindepth 3 -name '*.so' \
        \( -path '*/stable/*' -o -path '*/unstable/*' \) | LC_ALL=C sort)
    # ⚠️ NAMED, NOT SILENTLY SKIPPED — and as of 2026-09-12 there should be
    # NOTHING to name. The pre-variant flat copies under
    # package/native/<os>/<arch>/ and package/native/android/<abi>/ were
    # retired (roadmap R35, pulled forward to rc.1); the two Linux ones were
    # tracked and are deleted, the Android ones were gitignored fossils and are
    # gone from disk. This branch stays as a GUARD: if a flat library ever
    # reappears, it is named here instead of being silently passed over, which
    # is what would let "every library is clean" read wider than it is.
    while IFS= read -r so; do
      echo "  SKIP $so -- an unexpected pre-variant flat library; R35 retired these."
      echo "       It is NOT checked. Find out what wrote it."
    done < <(
      /usr/bin/find "$ROOT/package/native" -name '*.so' \
        ! -path '*/stable/*' ! -path '*/unstable/*' | LC_ALL=C sort)
    ;;
  ''|-h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 1 ;;
  *) for so in "$@"; do check_one "$so"; done ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "check_native_pins: ${fails} librar(y|ies) FAILED" >&2
  exit 1
fi
echo "check_native_pins: all checked libraries pass"
