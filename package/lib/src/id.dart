import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A 16-byte zenoh entity identifier.
///
/// ZenohId wraps a 16-byte unique identifier assigned to each zenoh session.
///
/// [bytes] is the ground truth: the sixteen bytes in **storage order**,
/// byte-exact, exactly as canon delivered them. [toHexString] is a derived
/// view that renders them in canon's own form — see its doc for the exact
/// contract, which is *not* storage order.
///
/// ## The 16-byte invariant
///
/// The length is an invariant, not a convention: canon cannot express an
/// identifier of any other size, because `z_id_t` is a fixed `uint8_t[16]`.
/// Construction therefore throws an [ArgumentError] for a [Uint8List] of any
/// length other than 16, so every instance that exists is exactly 16 bytes
/// wide and [operator ==]'s bounded `0..15` loop is total by that invariant.
///
/// The invariant constrains LENGTH only, never content. In particular the
/// all-zero identifier is a valid [ZenohId]: canon's stable API documents it
/// as the invalid-session sentinel that its own accessors return, so refusing
/// it here would make a documented canon return value untranslatable.
///
/// ## Where a wrong length could come from
///
/// Nowhere, in a correct build. Every native materialization site posts fixed
/// 16-byte typed data by construction, so a wrong-length array reaching this
/// constructor is a defect in the C shim rather than bad user input. The throw
/// is the correct diagnosis of that defect and is deliberately loud: no
/// graceful degradation (padding, truncation, sentinel substitution) exists
/// that would not turn a shim bug into a silently wrong identity.
@immutable
class ZenohId {
  /// Creates a ZenohId from a 16-byte [Uint8List].
  ///
  /// Throws an [ArgumentError] unless [bytes] is exactly 16 bytes long. The
  /// guard is a real throw and not an `assert`, so that it holds in a release
  /// build too -- an `assert` would be compiled away there and [operator ==]
  /// would read past the end of a short array.
  ZenohId(Uint8List bytes) : bytes = _checkedUnmodifiableCopy(bytes);

  static Uint8List _checkedUnmodifiableCopy(Uint8List bytes) {
    if (bytes.length != 16) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'A ZenohId is exactly 16 bytes (canon z_id_t is a fixed uint8_t[16])',
      );
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  /// The raw 16-byte identifier -- an unmodifiable view over a defensive copy.
  ///
  /// Neither side of the constructor can edit an identity after the fact.
  /// Writing through this list -- `id.bytes[0] = ...`, `setAll`, `fillRange`,
  /// `sort` -- throws an [UnsupportedError], and mutating the [Uint8List]
  /// originally passed to the constructor does not reach the id, because what
  /// is stored here is a copy of it rather than the array itself.
  ///
  /// Failing loudly is the point: a caller writing into an `@immutable`
  /// value's bytes has a bug, and silently discarding the write would hide it.
  /// Before the view landed, such a write SUCCEEDED and moved both
  /// [toHexString]'s output and [hashCode] in place, which makes an id already
  /// used as a `Map` or `Set` key unfindable in that collection.
  ///
  /// The view is stored, not rebuilt per access, so [operator ==], [hashCode]
  /// and [toHexString] read it at no cost. Reading is unconstrained: indexing,
  /// iteration, `length` and `Uint8List.fromList(id.bytes)` (the escape hatch
  /// for a caller that needs a writable array of its own) all behave normally.
  final Uint8List bytes;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ZenohId) return false;
    for (var i = 0; i < 16; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 0;
    for (final byte in bytes) {
      hash = (hash * 31 + byte) & 0x7FFFFFFF;
    }
    return hash;
  }

  /// Renders the identifier exactly as zenoh-c's `z_id_to_string` renders it.
  ///
  /// Canon treats the sixteen bytes as a 128-bit integer and prints its
  /// minimal lowercase hex: digit order [bytes]`[15]` down to [bytes]`[0]` —
  /// the byte-pair reverse of storage order — with leading zeros stripped **per
  /// hex digit**, across byte boundaries, and the all-zero identifier rendered
  /// as a single `'0'`.
  ///
  /// So the width is 1–32 digits, not always 32, and the result never begins
  /// with `'0'` unless it *is* `'0'`. That is zenoh's own contract for a
  /// rendered id, not an observation of one: a configured id with a leading
  /// zero is refused outright (*"Leading 0s are not valid"*).
  ///
  /// Stripping is a **leading-digit** rule, never a per-byte formatting rule —
  /// an interior `0x0a` still emits two digits.
  ///
  /// This is a derived view. [bytes] is the ground truth and stays raw storage
  /// order, byte-exact, whatever this returns.
  String toHexString() {
    final sb = StringBuffer();
    for (var i = 15; i >= 0; i--) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    final stripped = sb.toString().replaceFirst(RegExp('^0+'), '');
    return stripped.isEmpty ? '0' : stripped;
  }

  @override
  String toString() => toHexString();
}
