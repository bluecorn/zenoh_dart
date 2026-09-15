#!/usr/bin/env bash
set -euo pipefail

# Build zenoh-c + the C shim for Android, per (ABI x variant), via cargo-ndk.
#
# Usage:
#   ./scripts/build_zenoh_android.sh                     # the three shipped ABIs, both variants
#   ./scripts/build_zenoh_android.sh --abi arm64-v8a     # single ABI, both variants
#   ./scripts/build_zenoh_android.sh --variant stable    # all shipped ABIs, stable only
#   ./scripts/build_zenoh_android.sh --api 26            # override API level
#
# Variants (mirror the Linux ZENOH_DART_VARIANT switch):
#   stable    -- no unstable API, no SHM (canon default)
#   unstable  -- unstable API ON; SHM stays OFF (platform capability clamp:
#                canon cannot do SHM on Android either)
#
# Environment:
#   ANDROID_NDK_HOME  Path to the Android NDK. VERIFIED against the pin below,
#                     never merely accepted. Unset => resolved from the SDK.
#   API_LEVEL         Minimum Android API level (default: 24)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ZENOHC_DIR="${PROJECT_ROOT}/extern/zenoh-c"
NATIVE_ANDROID_DIR="${PROJECT_ROOT}/package/native/android"
API_LEVEL="${API_LEVEL:-24}"

# ── The NDK pin ──
#
# ⛔ THE DEFECT THIS REPLACES. This script used to take the NEWEST installed
# NDK (`sort -V | tail -1`). On this host that selected a BETA, and every
# Android library we shipped was built with it -- measured 2026-09-12: the
# shipped shims' `.comment` names clang 21.0.0, which is NDK 30.0.14904198-beta1
# / 30.0.15729638-beta2, not the stable NDK installed alongside them.
#
# ⭐ AND THE BETA MARKER IS NOT IN THE DIRECTORY NAME. The installed directories
# are `28.2.13676358`, `30.0.14904198`, `30.0.15729638` -- no `-beta` suffix
# anywhere. Only `source.properties` says: `Pkg.Revision = 30.0.14904198-beta1`.
# A check written against the directory name cannot see that it picked a beta,
# which is exactly why the verification below reads `Pkg.Revision`.
NDK_PIN="28.2.13676358"

ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")   # exactly the three we ship (R4)
VARIANTS=("stable" "unstable")

while [[ $# -gt 0 ]]; do
  case $1 in
    --abi) ABIS=("$2"); shift 2 ;;
    --variant) VARIANTS=("$2"); shift 2 ;;
    --api) API_LEVEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

ndk_revision() {
  # `Pkg.Revision` is the ONLY place the beta suffix appears. Read it, never
  # the directory name.
  sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$1/source.properties" 2>/dev/null | tr -d '\r'
}

# ── Resolve and VERIFY the NDK ──
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  echo "Using ANDROID_NDK_HOME from the environment: ${ANDROID_NDK_HOME}"
else
  for base in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "${HOME}/Android/Sdk"; do
    [[ -n "${base}" && -d "${base}/ndk/${NDK_PIN}" ]] || continue
    ANDROID_NDK_HOME="${base}/ndk/${NDK_PIN}"
    break
  done
fi

if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
  echo "Error: NDK ${NDK_PIN} not found."
  echo "  Looked for <sdk>/ndk/${NDK_PIN} under ANDROID_SDK_ROOT, ANDROID_HOME and ~/Android/Sdk."
  echo "  Install it:  sdkmanager 'ndk;${NDK_PIN}'"
  echo "  This build does NOT fall back to another NDK: the released libraries"
  echo "  name their compiler, so the compiler is pinned."
  exit 1
fi
export ANDROID_NDK_HOME

FOUND_REV="$(ndk_revision "${ANDROID_NDK_HOME}")"
if [[ "${FOUND_REV}" != "${NDK_PIN}" ]]; then
  echo "Error: NDK revision mismatch."
  echo "  ${ANDROID_NDK_HOME}"
  echo "    Pkg.Revision = ${FOUND_REV:-<unreadable>}"
  echo "    required     = ${NDK_PIN}"
  echo "  ⛔ Note the directory name may look right while Pkg.Revision says '-betaN'."
  exit 1
fi
echo "NDK: ${ANDROID_NDK_HOME}  (Pkg.Revision = ${FOUND_REV})"

NDK_CLANG="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
NDK_CLANG_VERSION="$("${NDK_CLANG}" --version 2>/dev/null | grep -oE 'clang version [0-9.]+' | head -1 || true)"
echo "NDK clang: ${NDK_CLANG_VERSION:-<unknown>}"

# Prerequisites check
command -v cargo >/dev/null 2>&1 || { echo "Error: cargo not found"; exit 1; }
command -v cargo-ndk >/dev/null 2>&1 || {
  echo "cargo-ndk not found. Install with: cargo install cargo-ndk"
  exit 1
}
command -v cmake >/dev/null 2>&1 || { echo "Error: cmake not found"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "Error: ninja not found"; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "Error: readelf not found"; exit 1; }

# ── The pinned zenoh core, and a build that cannot re-resolve it ──
# Same mechanism as the Linux superbuild; see build-pins/zenoh-core.pin.
"${SCRIPT_DIR}/apply_build_pins.sh"

# ── RUSTFLAGS: build paths out, 16 KB pages in ──
#
# `--remap-path-prefix` keeps this machine's home and repository out of the
# core (measured before this change: 572-628 host-path strings per Android
# core). `-C link-arg=-Wl,-z,max-page-size=16384` makes the RUST link 16 KB
# aligned, which is what the shim has always done via src/CMakeLists.txt and
# libzenohc.so never did -- measured: armeabi-v7a's core linked at 0x1000
# while its shim linked at 0x4000, in the same directory.
#
# ⛔ THE PROJECT PREFIX IS `extern/zenoh-c/src`, NOT THE REPOSITORY ROOT, and
# that is not tidiness. Remapping the root makes zenoh-c's build.rs -- which
# derives a real path from `file!()` (build.rs:7) -- go looking for the
# placeholder, and cargo fails with "Failed to copy Cargo.lock to
# /zenoh-dart/... No such file or directory". Same reasoning and same
# measurement as the Linux superbuild; the root CMakeLists.txt carries it.
#
# ✅ Safe to export: cargo-ndk 4.1.2 does not read, set or append to RUSTFLAGS
# (verified -- the string does not occur in the binary, while CARGO_TARGET_ and
# CARGO_NDK_* do, so the scan is not reading nothing). It sets linker and CC
# variables only. An existing RUSTFLAGS is preserved and extended.
_cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${_cargo_home}=/cargo --remap-path-prefix=${PROJECT_ROOT}/extern/zenoh-c/src=/zenoh-dart/extern/zenoh-c/src -C link-arg=-Wl,-z,max-page-size=16384"
echo "RUSTFLAGS: ${RUSTFLAGS}"

declare -A ABI_TO_TARGET=(
  ["arm64-v8a"]="aarch64-linux-android"
  ["armeabi-v7a"]="armv7-linux-androideabi"
  ["x86"]="i686-linux-android"
  ["x86_64"]="x86_64-linux-android"
)

for abi in "${ABIS[@]}"; do
  target="${ABI_TO_TARGET[$abi]:-}"
  [[ -n "${target}" ]] || { echo "Unknown ABI: ${abi}"; exit 1; }
  echo "Ensuring Rust target: ${target} (toolchain 1.93.0)"
  rustup target add --toolchain 1.93.0 "${target}"
done

# 16 KB page-size alignment is mandatory for Android 15+ on 64-bit devices, and
# is applied here to every ABI so one rule covers the tree.
#
# ⚠️ THE 16 KB REQUIREMENT IS 64-BIT ONLY. Google Play's wording is "must
# support 16 KB memory page sizes on 64-bit devices". It does NOT reach
# armeabi-v7a. armv7 is aligned anyway because its SHIM has shipped at 0x4000
# since the shim's link options were written, so a 16 KB armv7 library is
# already in the field; leaving the core at 0x1000 beside it is an
# inconsistency, not a safeguard. The cost is a few KB of padding.
check_16k() {
  local so="$1"
  local bad
  bad=$(readelf -lW "${so}" 2>/dev/null \
    | awk '/LOAD/ {a=$NF; if (a!="0x4000" && a!="0x10000") print a}')
  if [[ -n "${bad}" ]]; then
    echo "  FAIL ${so}: LOAD segment aligned ${bad} (need >= 0x4000 / 16 KB)"
    return 1
  fi
  echo "  OK   ${so}"
}

# Build zenoh-c + the C shim per (ABI x variant) in ONE interleaved loop.
#
# The interleave is REQUIRED for correctness: `cargo ndk build` regenerates the
# GENERATED, arch-/feature-specific zenoh-c headers (zenoh_opaque.h /
# zenoh_configure.h) in-source under extern/zenoh-c/include, and
# src/CMakeLists.txt's Android branch compiles the shim against those same
# in-source headers. Building all zenoh-c configs first and all shims second
# would compile every shim against the LAST config's headers -> cross-config
# ABI corruption. Interleaving guarantees each shim sees its own
# (ABI x variant) freshly regenerated headers.
#
# cargo-ndk requires running from the crate directory; cmake uses absolute
# -S/-B paths, so it is cwd-independent.
cd "${ZENOHC_DIR}"

for abi in "${ABIS[@]}"; do
  target="${ABI_TO_TARGET[$abi]}"
  for variant in "${VARIANTS[@]}"; do
    echo "=== ${abi} / ${variant} (${target}, API ${API_LEVEL}) ==="
    OUT_DIR="${NATIVE_ANDROID_DIR}/${abi}/${variant}"
    mkdir -p "${OUT_DIR}"

    # variant -> cargo features + shim compile defs. SHM stays OFF on Android
    # (platform clamp); the shim's -S src build does NOT run the root CMakeLists,
    # so ZD_WITH_* must be passed explicitly here.
    cargo_features=()
    shim_defs=()
    if [[ "${variant}" == "unstable" ]]; then
      cargo_features=(--features unstable)
      shim_defs=(-DZD_WITH_UNSTABLE=TRUE)
    elif [[ "${variant}" != "stable" ]]; then
      echo "Unknown variant: ${variant} (want stable|unstable)"; exit 1
    fi

    # 1. zenoh-c (regenerates in-source per-(ABI x variant) headers). Pinned to
    #    Rust 1.93.0 to match the Linux build (rust-toolchain.toml @ 1.8.0), and
    #    `--locked` so the resolution applied above is the one that is built.
    echo "Building zenoh-c for ${abi}/${variant}..."
    RUSTUP_TOOLCHAIN=1.93.0 cargo ndk \
      -t "${abi}" \
      --platform "${API_LEVEL}" \
      -o "${NATIVE_ANDROID_DIR}" \
      build --release --locked ${cargo_features[@]+"${cargo_features[@]}"}
    # cargo-ndk writes native/android/<abi>/libzenohc.so (flat). The shim's
    # src/CMakeLists discovery reads it there, so it stays flat until AFTER the
    # shim links; then both move into the variant subdir. (The APK linker
    # resolves libzenohc.so by soname at runtime, so the build-time path of the
    # dependency does not bake into the shim.)

    # 2. C shim for THIS (ABI x variant), against the headers cargo-ndk just wrote.
    echo "Building C shim for ${abi}/${variant}..."
    BUILD_DIR="${PROJECT_ROOT}/build/android/${abi}-${variant}"

    # ⛔⛔ CONFIGURE FROM SCRATCH. CMake reads CMAKE_TOOLCHAIN_FILE only on the
    # FIRST configure of a build directory; on a directory that already has a
    # cache it keeps the compiler it cached and IGNORES the -D. Measured
    # 2026-09-12, and it defeated the NDK pin on its very first run: with
    # ANDROID_NDK_HOME correctly verified at 28.2.13676358 (clang 19.0.1) and
    # passed as the toolchain file, the object CMake produced was compiled by
    # clang 21.0.0 out of NDK 30.0.15729638-beta2 — the cached compiler from
    # the previous build — and the cache still held host tools
    # (CMAKE_C_COMPILER_AR=/usr/bin/llvm-ar-21) beside it.
    #
    # ⭐ Nothing in the pin could have seen that: the variable was right, the
    # verification passed, and the wrong compiler ran anyway. The .comment
    # assertion below is what caught it. Wiping is cheap — the shim is two
    # translation units — and it also removes the same hazard for compile
    # flags, which changed in this round.
    rm -rf "${BUILD_DIR}"

    cmake \
      -S "${PROJECT_ROOT}/src" \
      -B "${BUILD_DIR}" \
      -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="${abi}" \
      -DANDROID_PLATFORM="android-${API_LEVEL}" \
      -DCMAKE_BUILD_TYPE=Release \
      ${shim_defs[@]+"${shim_defs[@]}"}
    cmake --build "${BUILD_DIR}" --config Release

    # 3. GATE BEFORE PLACING.
    #
    # ⛔ THE ORDERING WAS THE DEFECT. Both checks used to run after every
    # library had already been moved into package/native/, so a library that
    # failed them was in the shipping tree by the time anyone was told. A
    # failing check now places nothing, and what is on disk after a failed run
    # is the previous good pair.
    NEW_CORE="${NATIVE_ANDROID_DIR}/${abi}/libzenohc.so"
    NEW_SHIM="${BUILD_DIR}/libzenoh_dart.so"
    echo "Gating ${abi}/${variant} before placing..."
    check_16k "${NEW_CORE}"
    check_16k "${NEW_SHIM}"
    "${SCRIPT_DIR}/check_native_pins.sh" "${NEW_CORE}" "${NEW_SHIM}"
    if [[ -n "${NDK_CLANG_VERSION}" ]]; then
      # ⭐ The NDK is asserted ON THE ARTIFACT, not on the variable that chose
      # it: the shim records its compiler in `.comment`, so this catches a
      # toolchain reaching the compile by any route the pin above did not see.
      if ! readelf -p .comment "${NEW_SHIM}" 2>/dev/null | grep -qF "${NDK_CLANG_VERSION}"; then
        echo "  FAIL ${NEW_SHIM}: .comment does not name '${NDK_CLANG_VERSION}'"
        readelf -p .comment "${NEW_SHIM}" | sed 's/^/         /'
        exit 1
      fi
      echo "  OK   ${NEW_SHIM} (.comment names ${NDK_CLANG_VERSION})"
    fi

    # 4. Both .so into the variant subdir.
    mv "${NEW_CORE}" "${OUT_DIR}/libzenohc.so"
    cp "${NEW_SHIM}" "${OUT_DIR}/"
    echo "Built: ${OUT_DIR}/{libzenohc.so, libzenoh_dart.so}"
  done
done

echo ""
echo "=== 16 KB page-size sweep over everything present ==="
# The per-build gate above is what stops a bad library shipping. This sweep is
# the second arm: it also sees libraries left by EARLIER runs, which the gate
# by construction cannot.
check_fail=0
for so in "${NATIVE_ANDROID_DIR}"/*/*/lib*.so; do
  check_16k "${so}" || check_fail=1
done
if [[ ${check_fail} -ne 0 ]]; then
  echo "16 KB alignment sweep FAILED"
  exit 1
fi

echo ""
echo "=== build environment, recorded ==="
{
  echo "date_utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ndk:           ${ANDROID_NDK_HOME}"
  echo "ndk_revision:  ${FOUND_REV}"
  echo "ndk_clang:     ${NDK_CLANG_VERSION:-<unknown>}"
  echo "api_level:     ${API_LEVEL}"
  echo "abis:          ${ABIS[*]}"
  echo "variants:      ${VARIANTS[*]}"
  echo "rust:          $(RUSTUP_TOOLCHAIN=1.93.0 rustc --version)"
  echo "cargo_ndk:     $(cargo ndk --version 2>&1 | head -1)"
  echo "rustflags:     ${RUSTFLAGS}"
  echo "core_pin:      $(sed -n 's/^ZENOH_CORE_VERSION_STRING=//p' "${PROJECT_ROOT}/build-pins/zenoh-core.pin")"
} | tee "${PROJECT_ROOT}/build/android/BUILD-ENV.txt"
echo "(also written to build/android/BUILD-ENV.txt -- build output, not shipped)"

echo ""
echo "Done. Android prebuilts (per ABI x variant) at: ${NATIVE_ANDROID_DIR}"
ls -la "${NATIVE_ANDROID_DIR}"/*/*/lib*.so
