import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// A zenoh timestamp: a 24-byte `z_timestamp_t` value.
///
/// Wraps the raw 24 bytes of the native timestamp verbatim (no decomposition),
/// so a received timestamp is re-sendable bit-exact. The [time] (NTP64) and
/// [id] ([ZenohId]) are accessor views computed from the held bytes.
@immutable
class Timestamp {
  /// Wraps a raw 24-byte `z_timestamp_t` image.
  ///
  /// Timestamps originate from `Session.newTimestamp()` or from a received
  /// sample; constructing one directly is not the intended route.
  ///
  /// ⚠️ **Nothing prevents it.** This constructor is ordinary public API — it
  /// carries no annotation, and naming it from a consumer draws no diagnostic
  /// at all. *(Corrected: this said the constructor was "reachable only
  /// within the package", which was measured FALSE. Dart has no
  /// package-private modifier, and a dartdoc that claims a fence which is not
  /// there is worse than one that claims nothing.)*
  ///
  /// It is safe in the way the rest of this class is: the 24-byte invariant
  /// below is enforced by a real throw, and the bytes are copied defensively,
  /// so an image of the wrong length is refused.
  Timestamp.fromRaw(Uint8List raw)
    // The 24-byte invariant is enforced by a real throw, not an `assert`:
    // asserts are stripped in release builds, where a wrong-length image
    // would otherwise be accepted silently. Canon's `z_timestamp_t` is a
    // fixed 24 bytes, so no other length is expressible.
    : _raw = _checkedCopy(raw);

  /// Enforces the 24-byte invariant, then copies defensively.
  ///
  /// Throws [ArgumentError] when [raw] is not exactly 24 bytes long.
  static Uint8List _checkedCopy(Uint8List raw) {
    if (raw.length != 24) {
      throw ArgumentError.value(
        raw.length,
        'raw',
        'z_timestamp_t is exactly 24 bytes',
      );
    }
    return Uint8List.fromList(raw);
  }

  /// The raw 24-byte `z_timestamp_t` image (defensive copy).
  final Uint8List _raw;

  /// The raw 24-byte `z_timestamp_t` image.
  ///
  /// Internal: exposed for package-internal re-representation (send paths,
  /// round-trip tests). Returns a defensive copy.
  Uint8List get rawBytes => Uint8List.fromList(_raw);

  /// The NTP64 time as a Dart `int` carrying the raw unsigned-64 bit-pattern.
  ///
  /// Values ≥ 2⁶³ read as negative in Dart but are bit-exact; the full 64-bit
  /// value is preserved with no narrowing.
  int get time {
    final tsSize = bindings.zd_timestamp_sizeof();
    // Kept deliberately alongside the constructor's length guard: this pair
    // (here and in `id`) diagnoses a canon LAYOUT drift and names that cause,
    // where the guard would only report a bare length mismatch. Defence in
    // depth - the invariant's release-mode reach is the constructor's throw,
    // not these asserts, which cost nothing.
    assert(tsSize == 24, 'z_timestamp_t drifted from 24 bytes: $tsSize');
    final ptr = calloc<Uint8>(tsSize);
    try {
      ptr.asTypedList(tsSize).setAll(0, _raw);
      return bindings.zd_timestamp_ntp64_time(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// The [ZenohId] of the HLC that produced this timestamp.
  ZenohId get id {
    final tsSize = bindings.zd_timestamp_sizeof();
    final idSize = bindings.zd_id_sizeof();
    assert(tsSize == 24, 'z_timestamp_t drifted from 24 bytes: $tsSize');
    assert(idSize == 16, 'z_id_t drifted from 16 bytes: $idSize');
    final tsPtr = calloc<Uint8>(tsSize);
    final idPtr = calloc<Uint8>(idSize);
    try {
      tsPtr.asTypedList(tsSize).setAll(0, _raw);
      bindings.zd_timestamp_id(tsPtr, idPtr);
      return ZenohId(Uint8List.fromList(idPtr.asTypedList(idSize)));
    } finally {
      calloc
        ..free(tsPtr)
        ..free(idPtr);
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Timestamp) return false;
    for (var i = 0; i < 24; i++) {
      if (_raw[i] != other._raw[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 0;
    for (final byte in _raw) {
      hash = (hash * 31 + byte) & 0x7FFFFFFF;
    }
    return hash;
  }

  @override
  String toString() => 'Timestamp(time: $time, id: $id)';
}
