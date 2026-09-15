#!/usr/bin/env bash
#
# The suite entrypoint. Runs package:test SERIAL, off a native library the
# Dart toolchain does not rewrite underneath it.
#
# WHY THIS EXISTS -- the defect it closes
#
# `dart run` / `dart test` re-stage the bundled native assets on EVERY
# invocation, unconditionally and non-atomically:
# `pkg/dartdev/lib/src/native_assets_bundling.dart` carries a
# `TODO(dartbug.com/59668)` directly above the copy, and its `copyTo` comment
# names the dlopen-truncation hazard outright (dart-lang/sdk#62361). The suite
# spawns child `dart run` processes from 45 of its 103 default-suite test files
# while the parent test process has that same 15.6 MB `.so` mmap'ed -- so the file under the parent's
# mapping is rewritten mid-run. The observable is SIGBUS, measured by an
# independent review at 2-3 in 12 under parallel pressure.
#
# The 45/103 above, with its instrument, so the next reader can re-run it rather
# than trust it:
#
#   { grep -rlF "Platform.resolvedExecutable" package/test --include='*_test.dart' \
#       | grep -v '/interop/';
#     grep -rlE "helpers/(bounded_subprocess|bounded_stream_rss_harness)\.dart" \
#       package/test --include='*_test.dart'; } | sort -u | wc -l
#
# It targets the SITE (the call that spawns the Dart executable, directly or
# through the two helpers that do) rather than the word "Process" -- a plain
# `Process.start|run` grep answers 50, but that set includes test/helpers/ and
# test/interop/, neither of which the default suite runs.
#
# `ZENOH_DART_VARIANT` moves the load off `package/.dart_tool/lib/` (the copy
# the toolchain rewrites) and onto `package/native/linux/x86_64/<variant>/`
# (which nothing rewrites during a run). The toolchain still re-stages its copy;
# nobody has it mapped any more.
#
# WHAT THIS IS NOT
#
# It is NOT a licence to drop `--concurrency=1`. The rewrite race is one of
# three measured causes of parallel failure; the other two -- a wall-clock
# teardown assumption and a capacity-0 ordering race -- are untouched here.
# Serial stays the default. See `development/discipline/verification.md`,
# "Scope the run to the risk -- but every run is serial".
#
# THE VARIANT IS DERIVED, NEVER TYPED
#
# `native_lib.dart` documents `ZENOH_DART_VARIANT` as an explicit dev override
# -- "load exactly this variant, IGNORE the toolchain". Standing use of a
# diagnostic is a change of role for it, and it brings the diagnostic's own
# hazard: the env var can silently disagree with what the package declares.
# `package/pubspec.yaml`'s own comment anticipates its `user_defines` default
# flipping to `stable`, and on that day a hardcoded env var would run the whole
# suite against the wrong native -- less capable, most SHM/advanced cells
# quietly SKIPPED rather than failed.
#
# So the value is read from the pubspec, never written here, and a caller who
# has already exported a DIFFERENT value gets a refusal rather than a silent
# preference in either direction. The second lock is in the suite itself:
# `package/test/native_lib_test.dart`'s "library resolution" group fails if the
# loaded path is the staging copy, or if the loaded variant is not the declared
# one -- so bypassing this script does not bypass the check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$REPO_ROOT/package/pubspec.yaml"

# The declared variant, from `hooks: user_defines: zenoh_dart: variant:`.
# Anchored on a column-0 `hooks:` so the `hooks: ^2.0.0` DEPENDENCY (indented
# under `dependencies:`) cannot match. An empty result is a hard failure: this
# script must never guess a variant.
declared="$(awk '
  /^hooks:[[:space:]]*$/            { in_hooks = 1; next }
  in_hooks && /^[^[:space:]#]/      { in_hooks = 0 }
  in_hooks && /^[[:space:]]+variant:/ {
    line = $0
    sub(/^[[:space:]]*variant:[[:space:]]*/, "", line)
    sub(/[[:space:]]*#.*$/, "", line)
    gsub(/["'\'']/, "", line)
    print line
    exit
  }
' "$PUBSPEC")"

if [ -z "$declared" ]; then
  echo "REFUSING: no hooks.user_defines.zenoh_dart.variant in $PUBSPEC." >&2
  echo "The suite's native selection is derived from that key; it is not" >&2
  echo "defaulted here, because guessing it is the failure this script exists" >&2
  echo "to prevent." >&2
  exit 1
fi

if [ -n "${ZENOH_DART_VARIANT:-}" ] && [ "$ZENOH_DART_VARIANT" != "$declared" ]; then
  echo "REFUSING: ZENOH_DART_VARIANT=$ZENOH_DART_VARIANT disagrees with the" >&2
  echo "variant $PUBSPEC declares ($declared)." >&2
  echo >&2
  echo "Preferring either one silently is the hazard: running the suite" >&2
  echo "against the other native changes which features exist, and the cells" >&2
  echo "that need the missing ones SKIP rather than fail." >&2
  echo >&2
  echo "Unset ZENOH_DART_VARIANT to use the declared variant, or change the" >&2
  echo "pubspec's user_defines if you meant to move the whole package." >&2
  exit 1
fi

NATIVE_DIR="$REPO_ROOT/package/native/linux/x86_64/$declared"
for lib in libzenoh_dart.so libzenohc.so; do
  if [ ! -f "$NATIVE_DIR/$lib" ]; then
    echo "REFUSING: $NATIVE_DIR/$lib is missing." >&2
    echo >&2
    echo "The variant directories are build output and are not tracked." >&2
    echo "Build this variant before running the suite:" >&2
    echo >&2
    if [ "$declared" = "stable" ]; then
      echo "  cmake --preset linux-x64-stable" >&2
      echo "  cmake --build --preset linux-x64-stable --target install" >&2
    else
      echo "  cmake --preset linux-x64" >&2
      echo "  cmake --build --preset linux-x64 --target install" >&2
    fi
    exit 1
  fi
done

export ZENOH_DART_VARIANT="$declared"

echo "ZENOH_DART_VARIANT=$ZENOH_DART_VARIANT (declared in package/pubspec.yaml)"
echo "native: $NATIVE_DIR"

cd "$REPO_ROOT/package"
# --concurrency=1 explicitly, even though dart_test.yaml already defaults to it:
# the flag is the thing every doc and every station states out loud, and a
# reader of this script should not have to open a second file to learn that the
# suite is serial.
exec fvm dart test --concurrency=1 "$@"
