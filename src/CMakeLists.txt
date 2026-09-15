cmake_minimum_required(VERSION 3.10)
project(zenoh_dart_library VERSION 0.0.1 LANGUAGES C)

# zd_scout hosts the blocking z_scout on a detached POSIX worker thread, so the
# shim needs a threads implementation. Resolves under the NDK toolchain too --
# Android carries pthread inside libc, so Threads::Threads is a no-op link there
# rather than a missing -lpthread.
find_package(Threads REQUIRED)

# Resolved early because the file-prefix maps below need it; the canonical
# PACKAGE_ROOT used for zenoh-c discovery is computed again where it is used.
get_filename_component(PACKAGE_ROOT_FOR_MAP "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)

add_library(zenoh_dart SHARED
  "zenoh_dart.c"
  "dart/dart_api_dl.c"
)

target_link_libraries(zenoh_dart PRIVATE Threads::Threads)

set_target_properties(zenoh_dart PROPERTIES
  PUBLIC_HEADER zenoh_dart.h
  OUTPUT_NAME "zenoh_dart"
  C_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)

target_compile_definitions(zenoh_dart PUBLIC DART_SHARED_LIB)

# ── Keep the builder's filesystem out of the shim ──
#
# ⛔ MEASURED 2026-09-12: the Linux shim carries ZERO host paths, and every
# ANDROID shim carries SEVEN. The difference is not our flags — it is the NDK's
# `android.toolchain.cmake`, which adds `-g` to every configuration including
# Release, so the Android shim ships DWARF (`.debug_str`, `.debug_line`) naming
# the build directory and both source files. A published binary must not
# disclose where it was built, and a rebuild made elsewhere must be comparable
# to this one.
#
# `-ffile-prefix-map` maps the recorded paths, which covers DWARF, `__FILE__`
# and the coverage/profile names in one flag. Applied on every platform: it is
# a no-op where nothing records a path, and a platform-conditional here is one
# more thing to be wrong the next time a toolchain changes its defaults.
#
# ⚠️ Whether clang honours the FIRST or the LAST matching map is deliberately
# not relied on. Either order removes the host prefix: with $HOME mapped the
# repository path loses its `/home/...` head, and with the repository mapped it
# disappears entirely. `scripts/check_native_pins.sh` reads the built library
# and forbids BOTH, so the guarantee does not rest on the precedence rule.
if(DEFINED ENV{HOME})
  target_compile_options(zenoh_dart PRIVATE "-ffile-prefix-map=$ENV{HOME}=/builder")
endif()
target_compile_options(zenoh_dart PRIVATE
  "-ffile-prefix-map=${PACKAGE_ROOT_FOR_MAP}=/zenoh-dart"
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=/build")

# Feature defs are driven by ZENOH_DART_VARIANT (set in the root CMakeLists,
# with the Android SHM clamp already applied). They MUST match the cargo
# features libzenohc.so was built with, or the shim references symbols the
# runtime lacks. Undefined (e.g. a hypothetical src/-only configure) degrades
# to stable — safe, since it only removes optional symbol references.
if(ZD_WITH_SHM)
  target_compile_definitions(zenoh_dart PRIVATE Z_FEATURE_SHARED_MEMORY)
endif()
if(ZD_WITH_UNSTABLE)
  target_compile_definitions(zenoh_dart PRIVATE Z_FEATURE_UNSTABLE_API)
endif()

# Dart API DL headers
target_include_directories(zenoh_dart PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/dart"
)

# ── zenoh-c linkage ──
# Resolve the real source dir (handles symlinks in pub cache)
get_filename_component(PACKAGE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)

if(TARGET zenohc::lib)
  # ── Superbuild mode: zenoh-c built by parent CMakeLists.txt ──
  # zenohc::lib's INTERFACE_INCLUDE_DIRECTORIES already provides the
  # zenoh-c headers, so no explicit target_include_directories needed.
  message(STATUS "zenoh-c: linking against zenohc::lib target (superbuild)")
  target_link_libraries(zenoh_dart PRIVATE zenohc::lib)

  # Resolve zenohc location for RPATH.
  # Uses zenohc_shared directly (not zenohc::lib) because:
  # 1. get_target_property() doesn't work on ALIAS targets before CMake 3.27
  # 2. We always want the shared library location regardless of BUILD_SHARED_LIBS
  get_target_property(ZENOHC_LOC zenohc_shared IMPORTED_LOCATION)
  if(ZENOHC_LOC)
    get_filename_component(ZENOHC_LIB_DIR "${ZENOHC_LOC}" DIRECTORY)
  endif()
else()
  # ── Standalone mode: variant-aware discovery ──
  # zenoh-c headers must be added explicitly. zenoh_opaque.h / zenoh_configure.h
  # are GENERATED and version-/arch-specific (opaque struct sizes + feature flags
  # such as SHM). The source-tree copies under extern/zenoh-c/include are clobbered
  # by cargo / cargo-ndk builds; trusting them silently compiles the shim against a
  # mismatched ABI vs the linked libzenohc.so.
  #
  # The variant-matched full build tree, and the preset that produces it. BOTH
  # the header tier and the library tier below key off this: they must resolve
  # to the same variant or the shim compiles against one ABI and links another.
  # (Ignored on Android, which has its own per-ABI tiers.)
  if(ZENOH_DART_VARIANT STREQUAL "unstable")
    set(_full_build_dir "build/linux-x64")
    set(_full_build_preset "linux-x64")
  else()
    set(_full_build_dir "build/linux-x64-stable")
    set(_full_build_preset "linux-x64-stable")
  endif()

  if(ANDROID)
    # Per-ABI generated headers live in the source include dir, regenerated by
    # cargo-ndk immediately before this shim build in the interleaved per-ABI loop
    # (scripts/build_zenoh_android.sh).
    target_include_directories(zenoh_dart PUBLIC
      "${PACKAGE_ROOT}/extern/zenoh-c/include"
    )
  else()
    # Linux standalone / shim-only: read the build-tree generated headers from the
    # full build of the SAME variant (correct, version-matched, feature-matched),
    # mirroring package/ffigen.yaml — NEVER the clobberable source-tree copies.
    # Variant-aware: a stable shim-only build MUST NOT read the unstable build
    # tree's headers — SHM changes opaque struct sizes (10- §4.4, silent ABI
    # corruption). The full build of each variant lives in its own binaryDir.
    set(ZENOHC_GEN_INCLUDE
      "${PACKAGE_ROOT}/${_full_build_dir}/extern/zenoh-c/release/include")
    if(NOT EXISTS "${ZENOHC_GEN_INCLUDE}/zenoh_opaque.h")
      # The recovery hint MUST name the variant-matched preset: `linux-x64`
      # never creates build/linux-x64-stable/, so the old unconditional hint
      # sent a stable build round the same failure a second time.
      message(FATAL_ERROR
        "Generated zenoh-c headers not found at:\n  ${ZENOHC_GEN_INCLUDE}\n"
        "The shim-only build compiles against the version-matched generated headers "
        "produced by the full build of the SAME variant (${ZENOH_DART_VARIANT}). "
        "Run it first:\n"
        "  cmake --preset ${_full_build_preset} && "
        "cmake --build --preset ${_full_build_preset} --target install")
    endif()
    target_include_directories(zenoh_dart PUBLIC "${ZENOHC_GEN_INCLUDE}")
  endif()

  if(ANDROID)
    set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/package/native/android/${ANDROID_ABI}")
    set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
  else()
    # Linux dev discovery, variant-aware for the same reason the header tier
    # above is: the header and the library MUST come from one variant.
    #
    # ⚠️ The flat native/linux/<arch>/libzenohc.so is deliberately NOT probed,
    # and as of 2026-09-12 it does not exist here at all — the two pre-variant
    # flat libraries were retired (roadmap R35). The reason the probe was
    # removed is kept because it is the failure it prevents, not the file:
    # that flat copy was a tracked file that ALWAYS existed and was
    # byte-identical to the UNSTABLE build, so probing it first made
    # `linux-x64-stable-shim-only --target install` copy the unstable library
    # into native/linux/<arch>/stable/ — a silent variant clobber (the root
    # install rule copies ${ZENOHC_LIB_DIR}/libzenohc.so into the variant dir).
    # ⛔ Do not reintroduce a flat tier here if one ever reappears on disk.
    set(_variant_lib_dir
      "${PACKAGE_ROOT}/package/native/linux/${CMAKE_SYSTEM_PROCESSOR}/${ZENOH_DART_VARIANT}")
    if(EXISTS "${_variant_lib_dir}/libzenohc.so")
      set(ZENOHC_LIB_DIR "${_variant_lib_dir}")
    else()
      # Same-variant full-build tree — cargo's output for exactly the headers
      # the tier above just selected.
      set(ZENOHC_LIB_DIR
        "${PACKAGE_ROOT}/${_full_build_dir}/extern/zenoh-c/release/target/release")
    endif()
    set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
  endif()

  if(NOT EXISTS "${ZENOHC_LIBRARY}")
    message(FATAL_ERROR
      "zenoh-c library not found at: ${ZENOHC_LIBRARY}\n"
      "For development: build the ${ZENOH_DART_VARIANT} variant from root with "
      "'cmake --preset ${_full_build_preset} && "
      "cmake --build --preset ${_full_build_preset} --target install'\n"
      "For Android: run 'scripts/build_zenoh_android.sh'\n"
      "For published package: ensure native/ directory contains prebuilt libraries")
  endif()

  message(STATUS "Found zenoh-c: ${ZENOHC_LIBRARY}")
  add_library(zenohc SHARED IMPORTED)
  set_target_properties(zenohc PROPERTIES
    IMPORTED_LOCATION "${ZENOHC_LIBRARY}"
    IMPORTED_NO_SONAME TRUE
  )
  target_link_libraries(zenoh_dart PRIVATE zenohc)
endif()

# Propagate ZENOHC_LIB_DIR to parent scope (for install target)
set(ZENOHC_LIB_DIR "${ZENOHC_LIB_DIR}" PARENT_SCOPE)

# Platform-specific settings
if(ANDROID)
  # Support Android 15 16k page size
  target_link_options(zenoh_dart PRIVATE "-Wl,-z,max-page-size=16384")
else()
  # RPATH: find zenohc in the build tree, and in the same directory once installed.
  #
  # ⛔ NO EXPLICIT ABSOLUTE BUILD_RPATH (roadmap R44, 2026-09-13). This read
  # `BUILD_RPATH "${ZENOHC_LIB_DIR}"`, and that made the INSTALLED shim depend on
  # the length of the directory it was built in: the linker sizes `.dynstr` for
  # the absolute build-tree RUNPATH, and install rewrites that entry to `$ORIGIN`
  # IN PLACE (`file(RPATH_CHANGE)`), leaving the table its original length.
  # Measured by the release station's S4 rehearsal: STRSZ 11,061 against 11,040
  # for build paths of 59 and 38 characters.
  #
  # CMake already puts the directory of every linked shared library on the build
  # RPATH. BUILD_RPATH_USE_ORIGIN writes the ones INSIDE the build tree relative
  # to `$ORIGIN` -- in the superbuild, `$ORIGIN/../extern/zenoh-c/release/target/release`
  # -- which is the same string in every checkout. So the build-tree shim still
  # finds libzenohc.so, and the installed one no longer records where it was built.
  #
  # Rejected, each measured on a stand-in project built at two roots with Ninja:
  #   BUILD_WITH_INSTALL_RPATH      identical installs, but the build-tree shim can
  #                                 no longer find libzenohc.so
  #   CMAKE_NO_BUILTIN_CHRPATH      relink at install instead of editing in place;
  #                                 the Ninja generator refuses to generate
  #   USE_ORIGIN, explicit entry    an explicit BUILD_RPATH entry is not made
  #   kept                          relative, so the dependency survives
  #
  # ⚠️ Scope: only a directory inside THIS build tree becomes relative. The
  # standalone (shim-only) branch above links a libzenohc.so outside it -- under
  # package/native/ or another preset's build tree -- so that build keeps an
  # absolute RUNPATH and its install still depends on the path. The release
  # builds with the full presets, which take the superbuild branch.
  set_target_properties(zenoh_dart PROPERTIES
    BUILD_RPATH_USE_ORIGIN ON
    INSTALL_RPATH "$ORIGIN"
  )
endif()

