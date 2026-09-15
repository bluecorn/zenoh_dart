import 'package:zenoh_dart/src/native_lib.dart';

/// Runtime detection of which optional zenoh features the loaded native was
/// built with.
///
/// Reads the C shim's `zd_features()` bitmask once and caches it. The unstable
/// entrypoints gate on this so that importing `zenoh_unstable.dart` against a
/// native that lacks the feature (a build-variant mismatch — forgotten
/// `user_defines`, a typo'd package name, or a stale `.so`) fails loudly with a
/// fix-naming error instead of crashing inside zenoh-c.
///
/// ⛔ **The compile-time partition is not the whole story, and this file is no
/// longer only about the door.** A stable-door consumer cannot *name* the
/// unstable API — that much is enforced at compile time. But the door a
/// consumer imports and the native their pubspec selects are ORTHOGONAL AXES,
/// and one **stable-door** member falls in the gap:
/// `CongestionControl.blockFirst`, which canon declares only under
/// `Z_FEATURE_UNSTABLE_API`. It gates on [ZenohFeatures.hasUnstableApi] too —
/// see `requireCongestionControlSupported`.
///
/// So this file covers two runtime cases, not one: *"unstable API imported,
/// stable native loaded"*, and *"stable-door member the loaded native cannot
/// represent"*.
abstract final class ZenohFeatures {
  // One call per process, cached.
  static final int _bits = bindings.zd_features();

  // Mirror the src/zenoh_dart.h ZD_FEATURE_* macros. ffigen's zd_.* filter is
  // lowercase-only, so those uppercase macros are not emitted to bindings.dart.
  static const int _unstableApi = 1 << 0; // ZD_FEATURE_UNSTABLE_API
  static const int _sharedMemory = 1 << 1; // ZD_FEATURE_SHARED_MEMORY

  /// Whether `Z_FEATURE_UNSTABLE_API` was compiled into the loaded native.
  static bool get hasUnstableApi => _bits & _unstableApi != 0;

  /// Whether `Z_FEATURE_SHARED_MEMORY` was compiled into the loaded native.
  static bool get hasSharedMemory => _bits & _sharedMemory != 0;
}

/// Throws [UnsupportedError] if the loaded native lacks the unstable API.
///
/// Called at each unstable entrypoint (advanced pub/sub declaration).
void requireUnstable() {
  if (!ZenohFeatures.hasUnstableApi) {
    throw UnsupportedError(_featureMessage('Z_FEATURE_UNSTABLE_API'));
  }
}

/// Throws [UnsupportedError] if the loaded native lacks shared memory.
///
/// Called at each SHM entrypoint (`ShmProvider`, `ZBytes.isShmBacked`).
void requireShm() {
  if (!ZenohFeatures.hasSharedMemory) {
    throw UnsupportedError(_featureMessage('Z_FEATURE_SHARED_MEMORY'));
  }
}

String _featureMessage(String macro) =>
    'zenoh_unstable requires the `unstable` native variant, but the loaded '
    'libzenoh_dart.so was built without $macro.\n\n'
    "Add to your APP's pubspec.yaml (the root package — dependencies cannot "
    'set this):\n'
    '  hooks:\n'
    '    user_defines:\n'
    '      zenoh_dart:\n'
    '        variant: unstable';
