import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// Shared-memory introspection on [ZBytes] — the unstable door.
///
/// In scope only when `zenoh_unstable.dart` is imported.
extension ShmBytes on ZBytes {
  /// Returns whether this payload is backed by shared memory.
  ///
  /// ⚠️ **A `false` means "not a single-slice SHM payload", NOT "not shared
  /// memory".** Canon's predicate reports **not-SHM for a payload holding more
  /// than one slice**, and fragmentation **survives the wire** — so a large
  /// SHM payload that arrives in several slices reads `false` while genuinely
  /// being shared-memory backed.
  ///
  /// **Measured** at zenoh-c 1.8.0, seed `[10a]`: a payload assembled from two
  /// SHM slices arrives as **2 slices** and reports **`false`**. That is
  /// canon's own behaviour, not this binding's rendering of it. Check
  /// [ZBytes.slices] alongside this predicate when the answer matters.
  ///
  /// Throws [UnsupportedError] if the loaded native lacks shared memory (the
  /// gate replaces the old `Platform.isAndroid` short-circuit — capability is
  /// detected from the build, not inferred from the platform).
  /// Throws [StateError] if this [ZBytes] has been consumed or disposed
  /// (via [ZBytes.nativePtr], which performs both guards).
  bool get isShmBacked {
    requireShm();
    return bindings.zd_bytes_is_shm(nativePtr.cast()) == 1;
  }
}
