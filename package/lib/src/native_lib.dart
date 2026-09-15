import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'package:zenoh_dart/src/bindings.dart';

/// What a loadable `libzenoh_dart.so` is expected to be here, named in the
/// found-but-unloadable message so the reader can check it against the file.
String get _abiDescription =>
    '${Platform.operatingSystem} ${Abi.current().toString().split('_').last}';

bool _initialized = false;
late ZenohDartBindings _bindings;
late DynamicLibrary _library;
String? _resolvedLibraryPath;

/// Where [ensureInitialized] loaded `libzenoh_dart.so` from.
///
/// Null until initialization, and on the paths where the OS linker resolves
/// the library by soname rather than by path (Android's APK, Flutter
/// desktop's `$ORIGIN/lib`). Exposed so a probe-order change is falsifiable:
/// a test asserting *which* directory was used cannot be fooled by a silent
/// fallback to another candidate.
///
/// Surfaced publicly as `Zenoh.resolvedLibraryPath`, which is where a consumer
/// meets it: this library is exported from neither public door, so reaching it
/// here means reaching into `src/`.
String? get resolvedLibraryPath => _resolvedLibraryPath;

/// Returns the singleton [ZenohDartBindings] instance.
///
/// The bindings are backed by [DynamicLibrary.open] which loads the library
/// eagerly on the main thread. This avoids the Dart VM's `@Native` loading
/// path which uses `NoActiveIsolateScope` (thread-isolate detachment during
/// dlopen) and causes tokio waker vtable crashes when two Dart processes
/// connect via zenoh TCP.
///
/// Auto-initializes on first access.
ZenohDartBindings get bindings {
  if (!_initialized) ensureInitialized();
  return _bindings;
}

/// The loaded `libzenoh_dart.so` itself, for symbol-name resolution.
///
/// ⚠️ **Exists for ONE consumer: `NativeFinalizer` callback resolution.** A
/// `NativeFinalizer` takes a `Pointer<NativeFinalizerFunction>`, which the
/// generated `bindings.dart` cannot provide — it emits *callable* Dart
/// functions, not the raw entry addresses a finalizer needs. So the
/// `zd_fin_*` family is looked up by name here instead (see
/// `finalizers.dart`), and that is exactly why those symbols read as dead
/// under the export-liveness rule and are declared exempt in the header.
///
/// Auto-initializes on first access, like [bindings].
@internal
DynamicLibrary get nativeLibrary {
  if (!_initialized) ensureInitialized();
  return _library;
}

/// Resolves the absolute path to a prebuilt native library.
///
/// Probe order (INVERTED from the pre-variant loader, and sound only on Dart
/// >= 3.12.2 — enforced by the pubspec SDK floor):
///
///   1. `ZENOH_DART_VARIANT` env → `native/<os>/<arch>/<variant>/<name>` — an
///      explicit dev override ("load exactly this variant, ignore the
///      toolchain"). Belt, not braces: cheap escape hatch for diagnosing a
///      variant question.
///   2. `.dart_tool/lib/<name>` — the build hook's staged copy. This is the
///      only VARIANT-CORRECT location: the hook stages the
///      `user_defines`-selected variant, so it is authoritative for consumers,
///      and its staleness is closed by the hook's `output.dependencies`.
///   3. (caller) bare `DynamicLibrary.open('<name>')` — Android APK / Flutter
///      desktop (`RUNPATH=$ORIGIN/lib`).
///
/// Why the inversion is safe now — and why it was NOT before. The pre-variant
/// loader preferred `native/<os>/<arch>/` (flat) because loading `libzenohc.so`
/// from `.dart_tool/lib/` aborted with the v0.6.2 tokio-waker crash: the Dart
/// VM eagerly `dlopen`'d the registered CodeAsset under `NoActiveIsolateScope`,
/// and our load inherited that poisoned handle — tokio's waker vtable then
/// dereferenced NULL (`pc=0`) the moment a second Dart process connected over
/// zenoh TCP. Dart 3.12.2 dropped the eager code-asset load (the VM-held
/// `.dart_tool/lib/` mapping is gone), so `interprocess_test` is 7/7 from
/// `.dart_tool/lib/` — Gate A, `development/build/08-gate-a-results.md` §3.
/// `.dart_tool/lib/` is now both safe AND the only place that knows which
/// variant a consumer selected; the SDK floor (`^3.12.2`) is what makes
/// preferring it sound (on 3.11.x it would ship the crash).
///
/// `libzenohc.so` is not resolved here — it loads transitively via `DT_NEEDED`
/// from `libzenoh_dart.so`'s own directory (`RUNPATH=$ORIGIN`), so the hook
/// staging BOTH into `.dart_tool/lib/` keeps them together.
///
/// `resolvedLibraryPath` records the winner so a probe-order regression is
/// falsifiable — a test asserting WHICH directory was used cannot be fooled by
/// a silent fallback.
String? _resolveLibraryPath(String libraryName) {
  final variantOverride = _validatedVariantOverride();
  final hasOverride = variantOverride != null;

  // Try package URI resolution first (works in pure Dart,
  // but throws UnsupportedError in Flutter test runner).
  Uri? packageUri;
  try {
    packageUri = Isolate.resolvePackageUriSync(
      Uri.parse('package:zenoh_dart/src/native_lib.dart'),
    );
  } on Object catch (e) {
    // NARROWED: only the documented UnsupportedError is swallowed, and only
    // around resolvePackageUriSync itself.
    //
    // It used to be `on Object catch (_)` wrapping the File.fromUri calls too.
    // A ZENOH_DART_VARIANT value containing `?` or `#` made File.fromUri throw
    // ArgumentError, the catch ate it, the hook-staged probe was never
    // reached, and the loader silently demoted to CWD probing — an env value
    // could redirect where native code is loaded from, without a diagnostic.
    // (The value itself is now validated too; this is the second lock.)
    if (e is! UnsupportedError) rethrow;
    // Unsupported in Flutter's test runner — fall through to CWD probing.
    packageUri = null;
  }

  final packageRoot = packageUri?.resolve('../../');
  final probed = <String>[];

  // 1. Explicit dev override → the variant subdir.
  if (packageRoot != null && hasOverride) {
    final overrideFile = File.fromUri(
      packageRoot.resolve('native/linux/x86_64/$variantOverride/$libraryName'),
    );
    if (overrideFile.existsSync()) return overrideFile.path;
    probed.add(overrideFile.path);
  }

  // Same override probe relative to the current working directory.
  if (hasOverride) {
    final cwdOverride = File(
      'native/linux/x86_64/$variantOverride/$libraryName',
    );
    if (cwdOverride.existsSync()) return cwdOverride.absolute.path;
    probed.add(cwdOverride.absolute.path);

    // FAIL LOUDLY rather than fall through. An explicit variant request that
    // cannot be satisfied used to demote to the hook's staged copy, which is
    // whatever variant the toolchain selected -- so asking for `stable` and
    // receiving the SHM-carrying `unstable` build was a silent success. That
    // is a strictly larger capability than the one requested.
    throw StateError(
      'ZENOH_DART_VARIANT=$variantOverride was set, but no $libraryName was '
      'found for that variant. Probed:\n  ${probed.join('\n  ')}\n'
      'Build it, or unset ZENOH_DART_VARIANT to use the build hook output.',
    );
  }

  // 2. Hook output — variant-correct, authoritative.
  if (packageRoot != null) {
    final hookFile = File.fromUri(
      packageRoot.resolve('.dart_tool/lib/$libraryName'),
    );
    if (hookFile.existsSync()) return hookFile.path;
  }

  final cwdHook = File('.dart_tool/lib/$libraryName');
  if (cwdHook.existsSync()) return cwdHook.absolute.path;

  return null;
}

/// Reads `ZENOH_DART_VARIANT`, or null when unset/empty.
///
/// VALIDATED, because the failure mode of not validating is not a missing
/// library — it is the WRONG one. An unrecognised value (`stbale`) used to be
/// interpolated straight into the probe path; that path never existed, the
/// probe silently fell through to the build hook's staged copy, and the
/// process loaded whichever variant the toolchain had selected. Asking for
/// `stable` and getting the SHM-carrying `unstable` native is a strictly
/// larger capability than the one requested, delivered silently.
///
/// The twin selector in `hook/build.dart` already throws on the same input, so
/// before this the binding shipped two variant selectors with opposite failure
/// modes.
String? _validatedVariantOverride() {
  final raw = Platform.environment['ZENOH_DART_VARIANT'];
  if (raw == null || raw.isEmpty) return null;
  if (raw != 'stable' && raw != 'unstable') {
    throw StateError(
      'ZENOH_DART_VARIANT must be "stable" or "unstable" (or unset), '
      'got "$raw"',
    );
  }
  return raw;
}

/// Ensures the native library is loaded and the Dart API DL is initialized.
///
/// Loads libzenoh_dart.so via [DynamicLibrary.open] on the main thread,
/// which also transitively loads libzenohc.so via DT_NEEDED (RPATH=$ORIGIN).
/// This avoids the `@Native` loading path that causes inter-process crashes.
///
/// Must be called before any FFI usage. Safe to call multiple times.
void ensureInitialized() {
  if (_initialized) return;

  DynamicLibrary lib;
  if (Platform.isAndroid) {
    // Android: APK linker resolves from lib/<abi>/ automatically.
    // libzenohc.so loads transitively via DT_NEEDED.
    lib = DynamicLibrary.open('libzenoh_dart.so');
  } else {
    final libPath = _resolveLibraryPath('libzenoh_dart.so');
    if (libPath != null) {
      // FOUND BUT UNLOADABLE is its own failure, and it used to propagate
      // the VM's bare exception with no context at all. The probe order said
      // this file was the right one; the loader disagreed. A reader needs to
      // know WHICH path was tried and WHAT it was expected to be, because
      // the two most common causes -- a wrong-architecture build and a
      // truncated or half-written file -- are indistinguishable from the
      // VM's message alone.
      //
      // ⚠️ NARROW, AND BOUND. `DynamicLibrary.open`'s failure type is not
      // part of its contract; at this SDK it is `ArgumentError`, so that is
      // what is caught. Anything else propagates unwrapped, deliberately: an
      // `on Object catch (_)` here would swallow a failure class nobody has
      // seen and report it as this one.
      try {
        lib = DynamicLibrary.open(libPath);
        // ArgumentError is what DynamicLibrary.open throws on a load
        // failure, and this is the one place the binding can turn it into a
        // diagnosable message.
        // ignore: avoid_catching_errors
      } on ArgumentError catch (e) {
        throw StateError(
          'Found $libPath but could not load it as a shared library. '
          'It should be a $_abiDescription ELF shared object; a build for '
          'another architecture, or a truncated file, fails exactly here. '
          'The loader said: $e',
        );
      }
      _resolvedLibraryPath = libPath;
    } else {
      // Last resort: let the OS linker resolve via RUNPATH/LD_LIBRARY_PATH.
      // This handles Flutter desktop (RUNPATH=$ORIGIN/lib in the runner binary).
      try {
        lib = DynamicLibrary.open('libzenoh_dart.so');
        // ignore: avoid_catching_errors -- as above.
      } on ArgumentError catch (e) {
        // ⚠️ THE CAUGHT ERROR IS EMBEDDED. This used to be `on Object` with
        // no binding, which discarded the one sentence saying what the OS
        // linker actually objected to -- and left a reader with generic
        // remediation for a specific failure.
        throw StateError(
          'Could not find libzenoh_dart.so. No probed path resolved, and the '
          'OS linker could not find it by soname either. Ensure the build '
          'hook has run. The linker said: $e',
        );
      }
    }
  }

  _library = lib;
  _bindings = ZenohDartBindings(lib);

  final result = _bindings.zd_init_dart_api_dl(NativeApi.initializeApiDLData);
  if (result != 0) {
    throw StateError('Failed to initialize Dart API DL (code: $result)');
  }

  _initialized = true;
}
