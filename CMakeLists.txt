cmake_minimum_required(VERSION 3.16)
project(zenoh_dart VERSION 0.0.1 LANGUAGES C CXX)
# CXX required because zenoh-c's project() declares both C and CXX

# Reuse zenoh-c's battle-tested helpers
set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/extern/zenoh-c/cmake"
                      ${CMAKE_MODULE_PATH})
include(helpers)
set_default_build_type(Release)

# ── Options ──
declare_cache_var(ZENOH_DART_BUILD_ZENOHC TRUE BOOL
    "Build zenoh-c from source via cargo (FALSE = use prebuilt)")

# ── Platform guard ──
if(NOT (UNIX OR ANDROID))
    message(FATAL_ERROR "Only Linux and Android targets are supported")
endif()
if(ANDROID)
    # cargo-ndk builds zenoh-c separately; CMake only builds the C shim here
    set(ZENOH_DART_BUILD_ZENOHC FALSE)
endif()

# ── Feature variant (criterion 2: stable | unstable) ──
# One switch drives BOTH zenoh-c's cargo features (below) and the shim's
# compile definitions (src/CMakeLists.txt), replacing the platform-accidental
# `if(NOT ANDROID)` split. Default is `stable` — canon-faithful (10- §5.2).
# Each variant installs to its own native/<os>/<arch>/<variant>/ dir and MUST
# use its own build tree: SHM changes opaque struct sizes, so mixing a
# variant's headers with another's library is silent ABI corruption (10- §4.4).
set(ZENOH_DART_VARIANT "stable" CACHE STRING "Feature variant: stable|unstable")
set_property(CACHE ZENOH_DART_VARIANT PROPERTY STRINGS stable unstable)

if(ZENOH_DART_VARIANT STREQUAL "unstable")
    set(ZD_WITH_UNSTABLE TRUE)
    set(ZD_WITH_SHM TRUE)
elseif(ZENOH_DART_VARIANT STREQUAL "stable")
    set(ZD_WITH_UNSTABLE FALSE)
    set(ZD_WITH_SHM FALSE)
else()
    message(FATAL_ERROR
        "ZENOH_DART_VARIANT must be 'stable' or 'unstable', got '${ZENOH_DART_VARIANT}'")
endif()
if(ANDROID)
    # Platform capability clamp — canon can't do SHM on Android either. The
    # unstable API on Android is a step-7 concern; the default `stable` variant
    # already yields both-off here, matching current behaviour.
    set(ZD_WITH_SHM FALSE)
endif()
message(STATUS
    "zenoh-dart variant: ${ZENOH_DART_VARIANT} (unstable=${ZD_WITH_UNSTABLE}, shm=${ZD_WITH_SHM})")

# ── Reproducible cargo build: the pinned core, and no build paths in the artifact ──
#
# ⛔ THE PROBLEM. zenoh-c asks for the zenoh crates BY BRANCH (`release/1.8.0`),
# and the Cargo.lock committed at its own 1.8.0 tag names a different resolution
# (`branch=main#c3761375...`). A branch is not a pin. Left alone, cargo re-resolves
# against whatever the branch points at today, and the library that comes out looks
# identical to the one we certified while being built from different source.
# Separately, every core built here embeds this machine's home directory in ~1,500
# strings, which discloses the builder's filesystem and makes a rebuild elsewhere
# incomparable. Both are fixed here, and BOTH ARE THEN ASSERTED ON THE ARTIFACT.
#
# 1. The pinned lockfiles go into the submodule before cargo can read them.
#    Configure time is early enough: zenoh-c copies Cargo.lock into its own build
#    tree during configure (its configure_cargo_toml), and cargo does not run
#    until build time.
execute_process(
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/apply_build_pins.sh"
    RESULT_VARIABLE _zd_pin_rc
    OUTPUT_VARIABLE _zd_pin_out
    ERROR_VARIABLE  _zd_pin_err)
if(NOT _zd_pin_rc EQUAL 0)
    message(FATAL_ERROR "apply_build_pins.sh failed:\n${_zd_pin_out}${_zd_pin_err}")
endif()
if(_zd_pin_out)
    message(STATUS "${_zd_pin_out}")
endif()

# 2. `--locked` forbids cargo from changing the resolution it was given, and
#    `--remap-path-prefix` keeps this machine's paths out of the output.
#
#    ⚠️ `build.rustflags` LOSES TO A `RUSTFLAGS` IN THE ENVIRONMENT — cargo's
#    documented precedence. That is why the remap is not trusted: the POST_BUILD
#    check below reads the produced library and fails the build if a path
#    survived, whatever the reason. The flag is the mechanism; the check is the
#    guarantee.
#
#    The prefixes are computed, not typed, so the OUTPUT is machine-independent
#    while the INPUT is whatever this machine happens to use.
#
# ⛔ WHY THE PROJECT REMAP IS NARROWED TO `extern/zenoh-c/src` AND NOT THE
#    REPOSITORY ROOT. Remapping the root was tried first and BROKE THE BUILD:
#
#      error: failed to run custom build command for `zenoh-c v1.8.0`
#      Failed to copy Cargo.lock to /zenoh-dart/extern/zenoh-c/build-resources/
#      opaque-types/Cargo.lock: No such file or directory (os error 2)
#
#    zenoh-c's build.rs derives a REAL FILESYSTEM PATH from `file!()`
#    (`get_build_rs_path`, extern/zenoh-c/build.rs:7), and `--remap-path-prefix`
#    rewrites exactly that. So the build script went looking for the placeholder.
#
#    The narrower prefix excludes `extern/zenoh-c/build.rs` while still covering
#    every project path that actually reaches the artifact: measured on the
#    shipped core, the ONLY repository paths in it are 176 occurrences of
#    `extern/zenoh-c/src/…`, and no build-tree path at all. `file!()` is used
#    as a path nowhere else in zenoh-c or in the pinned core's build scripts.
#
# ⭐ AND THE NARROWING IS SAFE ONLY BECAUSE OF THE POST_BUILD CHECK. The remap
#    set is derived from a measurement, and a measurement can go stale. If a
#    future dependency embeds a repository path this list does not cover, the
#    check in src/CMakeLists.txt fails the build naming it, rather than the
#    library shipping with it. Widen the list then; do not widen it to the root.
if(DEFINED ENV{CARGO_HOME})
    set(_zd_cargo_home "$ENV{CARGO_HOME}")
else()
    set(_zd_cargo_home "$ENV{HOME}/.cargo")
endif()
set(ZENOHC_CARGO_FLAGS
    "--locked;--config;build.rustflags=[\"--remap-path-prefix=${_zd_cargo_home}=/cargo\",\"--remap-path-prefix=${CMAKE_CURRENT_SOURCE_DIR}/extern/zenoh-c/src=/zenoh-dart/extern/zenoh-c/src\"]"
    CACHE STRING "" FORCE)
message(STATUS "cargo flags: ${ZENOHC_CARGO_FLAGS}")

# ── zenoh-c (from source) ──
if(ZENOH_DART_BUILD_ZENOHC)
    # These cache vars configure zenoh-c's CMakeLists.txt before add_subdirectory
    set(BUILD_SHARED_LIBS TRUE CACHE BOOL "" FORCE)
    # Driven by ZENOH_DART_VARIANT — the shim's compile defs (src/) track the
    # same two vars, so the shim and libzenohc.so can never disagree on features.
    set(ZENOHC_BUILD_WITH_SHARED_MEMORY ${ZD_WITH_SHM} CACHE BOOL "" FORCE)
    set(ZENOHC_BUILD_WITH_UNSTABLE_API ${ZD_WITH_UNSTABLE} CACHE BOOL "" FORCE)
    # "+1.93.0" makes cargo invoke `cargo +1.93.0 build ...`, matching the
    # channel pinned by extern/zenoh-c/rust-toolchain.toml at the 1.8.0 tag.
    # The old +1.85.0 pin worked around zenoh-c 1.7.2's transitive dep
    # `static_init` 1.0.3 failing on Rust >= 1.86 (parking_lot resolution
    # error); 1.8.0 resolves that break, so the 1.85.0 pin is no longer
    # required. Pinned to 1.93.0 for reproducibility; the pin can be dropped
    # once stable Rust >= 1.93.0 is confirmed on all build machines.
    set(ZENOHC_CARGO_CHANNEL "+1.93.0" CACHE STRING "" FORCE)
    # Note: ZENOHC_BUILD_IN_SOURCE_TREE is irrelevant here — zenoh-c's condition
    # (line 79) also checks CMAKE_SOURCE_DIR == CMAKE_CURRENT_SOURCE_DIR, which
    # is always FALSE when used via add_subdirectory(). No need to set it.
    add_subdirectory(extern/zenoh-c)
    message(STATUS "zenoh-c: building from source (cargo +1.93.0)")
else()
    message(STATUS "zenoh-c: using prebuilt (discovery in src/CMakeLists.txt)")
endif()

# ── C shim ──
add_subdirectory(src)

# ── Install: copy both .so files to the prebuilt directory ──
# Uses absolute DESTINATION intentionally — CMake install normally uses
# CMAKE_INSTALL_PREFIX + relative path, but we need libraries placed into
# the Dart package's native/ directory (which the build hook reads), not
# a system prefix like /usr/local/lib.
set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/package/native")

# Per-variant install dir (10- §4.4): variants must NOT share an install dir —
# their libzenohc.so and opaque struct layouts genuinely differ.
#
# ⚠️ The trailing clause here used to read "until then the flat
# native/<os>/<arch>/ copy still feeds the hook and the test loader". That
# stopped being true when the loader's probe order was inverted, and the flat
# copies were deleted outright on 2026-09-12. Nothing writes or reads
# native/<os>/<arch>/ on Linux any more: the hook resolves
# native/linux/<arch>/<variant>/, the loader resolves that or .dart_tool/lib/,
# and this install rule writes only the variant directory.
if(ANDROID)
    set(PREBUILT_DIR "${NATIVE_DIR}/android/${ANDROID_ABI}/${ZENOH_DART_VARIANT}")
else()
    set(PREBUILT_DIR "${NATIVE_DIR}/linux/${CMAKE_SYSTEM_PROCESSOR}/${ZENOH_DART_VARIANT}")
endif()

# Install libzenoh_dart.so via install(TARGETS) — NOT install(FILES).
# install(TARGETS) applies INSTALL_RPATH ("$ORIGIN") automatically via
# chrpath/relinking. install(FILES) is a raw copy that skips RPATH editing.
# This eliminates the patchelf dependency entirely.
install(TARGETS zenoh_dart LIBRARY DESTINATION "${PREBUILT_DIR}")

# Install libzenohc.so — source depends on build mode.
# zenohc_shared is an IMPORTED target, so install(TARGETS) cannot be used.
# install(FILES) is correct here — we don't own this library's RPATH.
if(ZENOH_DART_BUILD_ZENOHC AND TARGET zenohc_shared)
    # Superbuild: copy from cargo output in build tree
    install(FILES $<TARGET_FILE:zenohc_shared> DESTINATION "${PREBUILT_DIR}")
else()
    # Standalone/Android: libzenohc.so already in place (cargo-ndk or prior build)
    # Only copy if source differs from destination (avoids self-copy)
    if(DEFINED ZENOHC_LIB_DIR AND NOT "${ZENOHC_LIB_DIR}" STREQUAL "${PREBUILT_DIR}")
        install(FILES "${ZENOHC_LIB_DIR}/libzenohc.so" DESTINATION "${PREBUILT_DIR}")
    endif()
endif()


# ── The artifact assertion (R1 + R2) — at INSTALL time, on what actually ships ──
#
# ⭐ ASSERTED ON WHAT CAME OUT, not on what was passed in. A build flag can be
# overridden by the environment (cargo's `build.rustflags` loses to a RUSTFLAGS
# in the environment), a new dependency can bring its own path strings, and a
# toolchain can record a path through a mechanism nobody enumerated. This reads
# the library.
#
# ⛔ WHY INSTALL AND NOT POST_BUILD. It was POST_BUILD first, and it failed —
# correctly — on the shim's BUILD_RPATH:
#
#      FAIL build/linux-x64/src/libzenoh_dart.so — embeds build paths:
#           1 occurrence(s) of '/home/hugo/bluecorn/git/zenoh_dart_dev'
#           e.g. …/build/linux-x64/extern/zenoh-c/release/target/release:
#
#   A pre-install shim is SUPPOSED to carry an absolute BUILD_RPATH; that is how
#   it finds libzenohc.so in the build tree. `install(TARGETS)` relinks it to
#   INSTALL_RPATH `$ORIGIN`. So the build-tree file is not the object of the
#   claim, and checking it would have forced the check to be weakened to pass —
#   the failure mode where a control gets loosened until it is quiet.
#   ▶ The shipped file is the object. Check that.
#
#   ⚠️ Corrected 2026-09-13 (roadmap R44): the two factual clauses above no
#   longer hold, and the reason to check the installed file is unchanged. The
#   superbuild's pre-install shim now carries the RELATIVE RUNPATH
#   `$ORIGIN/../extern/zenoh-c/release/target/release` (src/CMakeLists.txt), so
#   it finds libzenohc.so in the build tree without an absolute path. And
#   install does not relink: it EDITS the RUNPATH in place, which is what left
#   the installed shim's bytes depending on the build directory's length. The
#   standalone (shim-only) branch's build-tree shim still carries an absolute
#   path, and the shipped file is still the object.
#
# `scripts/check_native_pins.sh --selftest` proves the check can detect all
# three violations; a check nobody has watched fire is a check nobody knows works.
install(CODE "
    execute_process(
        COMMAND \"${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_native_pins.sh\"
                \"${PREBUILT_DIR}/libzenoh_dart.so\"
                \"${PREBUILT_DIR}/libzenohc.so\"
        RESULT_VARIABLE _zd_check_rc)
    if(NOT _zd_check_rc EQUAL 0)
        message(FATAL_ERROR \"installed libraries failed the pin/build-path check\")
    endif()
")
