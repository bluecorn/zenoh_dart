import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// A zenoh serializer for building structured payloads.
///
/// Wraps `ze_owned_serializer_t`. Call [finish] to produce a [ZBytes],
/// or [dispose] to release native resources without finishing.
///
/// ## Declared widths: integer widths reject, floating widths round
///
/// Every method here names the native width it writes. For the integer
/// widths narrower than 64 bits -- [serializeUint8], [serializeUint16],
/// [serializeUint32], [serializeInt8], [serializeInt16], [serializeInt32]
/// -- a value outside that width's domain throws an [ArgumentError] naming
/// the domain, raised before any native call is made. It is never
/// truncated into range.
///
/// For the unsigned widths this is convention CONV-4(c) applied, not a new
/// rule: "The value is carried full-width -- no silent truncation; a
/// narrower native width (`uint8_t`) gets an explicit Dart-side range guard
/// naming the domain." CONV-4's scope is parameters marshalled into
/// `size_t`/`uintN_t`, so the *signed* widths fall outside it and take the
/// same rule for their own separate reason: shipping two contradictory
/// domain policies on one surface is worse than extending one policy
/// across it.
///
/// [serializeFloat] (f64 narrowed to f32) does *not* reject. An integer
/// width has an exactly-representable domain, so a value outside it is a
/// caller error; a binary floating width has no such domain -- every finite
/// f64 has a defined nearest binary32 under IEEE-754, which is a specified
/// rounding rather than a wrap. Canon's own
/// `ze_serializer_serialize_float(float)` performs the identical narrowing
/// at the ABI. So float documents and pins its narrowing where the integer
/// widths reject.
///
/// [serializeUint64], [serializeInt64] and [serializeDouble] are unguarded:
/// their domains are Dart's own. A [serializeUint64] argument above 2^63 is
/// carried as its bit-exact two's complement pattern -- the only
/// Dart-representable form, and not a transform.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// It carries a `NativeFinalizer` **safety net**: if it is dropped without an
/// explicit release, its native resources are reclaimed when the object is
/// collected.
/// ⛔ The net is **not a substitute** for releasing it explicitly — a finalizer
/// runs at an unpredictable time, or not at all if the program exits first.
class ZSerializer implements Finalizable {
  /// Creates an empty serializer.
  ZSerializer() : _ptr = _create() {
    // `_create` either returns a live slot or does not return, so reaching
    // here means the object exists and the net is safe to arm.
    serializerFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_serializer_sizeof(),
    );
  }

  final Pointer<Void> _ptr;
  bool _finished = false;
  bool _disposed = false;

  static Pointer<Void> _create() {
    final size = bindings.zd_serializer_sizeof();
    final ptr = calloc.allocate<Void>(size);
    bindings.zd_serializer_empty(ptr.cast());
    return ptr;
  }

  void _checkState() {
    if (_disposed) throw StateError('ZSerializer has been disposed');
    if (_finished) throw StateError('ZSerializer has been finished');
  }

  Pointer<Void> _loanMut() {
    final out = calloc<Pointer<Void>>();
    bindings.zd_serializer_loan_mut(_ptr.cast(), out.cast());
    final loaned = out.value;
    calloc.free(out);
    return loaned;
  }

  /// Refuses [value] unless it lies within the declared native width's
  /// exactly-representable domain `min..max`.
  ///
  /// Runs after the state check and before any loan, so a refused call
  /// touches no native state and leaves the serializer usable.
  static void _requireInRange(int value, int min, int max, String width) {
    if (value < min || value > max) {
      throw ArgumentError.value(
        value,
        'value',
        'out of range for $width: must be in $min..$max',
      );
    }
  }

  /// Serializes a uint8 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `0..255`, before any native call is made. See the class doc
  /// for why the integer widths reject.
  void serializeUint8(int value) {
    _checkState();
    _requireInRange(value, 0, 255, 'uint8');
    final rc = bindings.zd_serializer_serialize_uint8(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize uint8', rc);
  }

  /// Serializes a uint16 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `0..65535`, before any native call is made. See the class doc
  /// for why the integer widths reject.
  void serializeUint16(int value) {
    _checkState();
    _requireInRange(value, 0, 65535, 'uint16');
    final rc = bindings.zd_serializer_serialize_uint16(
      _loanMut().cast(),
      value,
    );
    if (rc != 0) throw ZenohException('Failed to serialize uint16', rc);
  }

  /// Serializes a uint32 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `0..4294967295`, before any native call is made. See the class doc
  /// for why the integer widths reject.
  void serializeUint32(int value) {
    _checkState();
    _requireInRange(value, 0, 4294967295, 'uint32');
    final rc = bindings.zd_serializer_serialize_uint32(
      _loanMut().cast(),
      value,
    );
    if (rc != 0) throw ZenohException('Failed to serialize uint32', rc);
  }

  /// Serializes a uint64 value.
  ///
  /// Unguarded, and it cannot be otherwise: every Dart int is a valid
  /// 64-bit pattern, so a value above 2^63 is carried as its bit-exact
  /// two's complement rather than rejected.
  void serializeUint64(int value) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_uint64(
      _loanMut().cast(),
      value,
    );
    if (rc != 0) throw ZenohException('Failed to serialize uint64', rc);
  }

  /// Serializes an int8 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `-128..127`, before any native call is made. See the class doc
  /// for why the integer widths reject.
  void serializeInt8(int value) {
    _checkState();
    _requireInRange(value, -128, 127, 'int8');
    final rc = bindings.zd_serializer_serialize_int8(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize int8', rc);
  }

  /// Serializes an int16 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `-32768..32767`, before any native call is made. See the class doc
  /// for why the integer widths reject.
  void serializeInt16(int value) {
    _checkState();
    _requireInRange(value, -32768, 32767, 'int16');
    final rc = bindings.zd_serializer_serialize_int16(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize int16', rc);
  }

  /// Serializes an int32 value.
  ///
  /// Throws an [ArgumentError] naming the domain if [value] falls
  /// outside `-2147483648..2147483647`, before any native call is made.
  /// See the class doc for why the integer widths reject.
  void serializeInt32(int value) {
    _checkState();
    _requireInRange(value, -2147483648, 2147483647, 'int32');
    final rc = bindings.zd_serializer_serialize_int32(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize int32', rc);
  }

  /// Serializes an int64 value.
  void serializeInt64(int value) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_int64(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize int64', rc);
  }

  /// Serializes a float value, narrowing the f64 [value] to binary32.
  ///
  /// Does not reject. Every finite f64 has a defined nearest binary32 under
  /// IEEE-754, so this narrowing is a specified rounding rather than a
  /// wrap, and it matches canon's own `float`-typed entry point. See the
  /// class doc for why the integer widths reject where this one rounds.
  void serializeFloat(double value) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_float(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize float', rc);
  }

  /// Serializes a double value.
  void serializeDouble(double value) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_double(
      _loanMut().cast(),
      value,
    );
    if (rc != 0) throw ZenohException('Failed to serialize double', rc);
  }

  /// Serializes a bool value.
  // Mirrors canon `ze_serializer_serialize_bool(bool)` and the sibling
  // serializeInt/serializeDouble methods; a named parameter would break
  // parity and every call site.
  // ignore: avoid_positional_boolean_parameters
  void serializeBool(bool value) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_bool(_loanMut().cast(), value);
    if (rc != 0) throw ZenohException('Failed to serialize bool', rc);
  }

  /// Serializes a UTF-8 string value.
  ///
  /// Encodes to UTF-8 bytes and passes an explicit length, so embedded NUL
  /// bytes are preserved (a NUL-terminated copy would truncate at the first
  /// NUL).
  void serializeString(String value) {
    _checkState();
    final utf8Bytes = utf8.encode(value);
    final nativeBuf = calloc.allocate<Uint8>(utf8Bytes.length);
    try {
      nativeBuf.asTypedList(utf8Bytes.length).setAll(0, utf8Bytes);
      final rc = bindings.zd_serializer_serialize_string(
        _loanMut().cast(),
        nativeBuf,
        utf8Bytes.length,
      );
      if (rc != 0) throw ZenohException('Failed to serialize string', rc);
    } finally {
      calloc.free(nativeBuf);
    }
  }

  /// Serializes a byte buffer.
  void serializeBytes(Uint8List value) {
    _checkState();
    final nativeBuf = calloc.allocate<Uint8>(value.length);
    try {
      nativeBuf.asTypedList(value.length).setAll(0, value);
      final rc = bindings.zd_serializer_serialize_buf(
        _loanMut().cast(),
        nativeBuf,
        value.length,
      );
      if (rc != 0) throw ZenohException('Failed to serialize bytes', rc);
    } finally {
      calloc.free(nativeBuf);
    }
  }

  /// Serializes a sequence length header.
  ///
  /// Must be followed by exactly [length] serialized elements of the
  /// same type to form a valid sequence.
  void serializeSequenceLength(int length) {
    _checkState();
    final rc = bindings.zd_serializer_serialize_sequence_length(
      _loanMut().cast(),
      length,
    );
    if (rc != 0) {
      throw ZenohException('Failed to serialize sequence length', rc);
    }
  }

  /// Finishes the serializer and returns the produced [ZBytes].
  ///
  /// The serializer is consumed by this call. After finishing,
  /// no further operations are allowed.
  ///
  /// Throws [StateError] if already finished or disposed.
  ZBytes finish() {
    _checkState();
    _finished = true;
    // ⛔ `finish()` IS A RELEASE PATH. It moves the handle into canon and frees
    // the slot below, so without this detach the net would later drop a moved
    // handle and free the slot a second time.
    serializerFinalizer.detach(this);
    final bytesPtr = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    bindings.zd_serializer_finish(_ptr.cast(), bytesPtr.cast());
    calloc.free(_ptr);
    return ZBytes.fromNative(bytesPtr);
  }

  /// Releases native resources held by this serializer.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  /// Safe to call after [finish] -- no-op since resources were
  /// already transferred.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void dispose() {
    if (_disposed) return;
    if (_finished) {
      // `finish()` already detached and released; a second detach here would
      // be harmless but the early return makes it unreachable, and saying so
      // is what keeps the "safe to call multiple times" note honest.
      _disposed = true;
      return;
    }
    _disposed = true;
    serializerFinalizer.detach(this);
    bindings.zd_serializer_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
