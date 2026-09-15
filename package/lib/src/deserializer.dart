import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/bindings.dart' show ze_deserializer_t;
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// A zenoh deserializer for reading structured payloads.
///
/// Wraps `ze_deserializer_t`. Created from a [ZBytes] instance.
/// Call [dispose] when finished to free native resources.
///
/// This object holds a native handle, so it CANNOT cross an isolate boundary:
/// a copy would share this one's native address while carrying its own fresh
/// disposal flag, and the second release would be a use-after-free. Sending it
/// throws `ArgumentError`.
///
/// It carries a `NativeFinalizer` safety net: if it is dropped without
/// [dispose], its native block is released when the object is collected.
/// ⛔ The net is not a substitute for calling [dispose] -- a finalizer runs at
/// an unpredictable time, or not at all if the program exits first.
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
class ZDeserializer implements Finalizable {
  /// Creates a deserializer from the given [bytes].
  ///
  /// The [bytes] must remain valid for the lifetime of this deserializer --
  /// the deserializer holds a native cursor INTO them, not a copy. It keeps a
  /// reference and refuses to read once the source is disposed or consumed,
  /// so violating that is a `StateError` rather than a use-after-free.
  ZDeserializer(ZBytes bytes) : _source = bytes, _ptr = _create(bytes) {
    // THE NET. A deserializer dropped without [dispose] used to leak its
    // native block for the life of the process, with no observable at all --
    // no throw, no corruption, and every behavioural cell green either way.
    //
    // `detach: this` is the key: ONE `detach(this)` in [dispose] reverses this
    // attachment, so the explicit path and the finalizer path are mutually
    // exclusive by construction rather than by a flag.
    //
    // `externalSize` is the slot this finalizer frees -- the same
    // `zd_deserializer_sizeof()` the constructor just allocated -- and nothing
    // else. It drives GC scheduling, and canon's own heap behind the handle is
    // opaque at this pin, so folding in a guess would make the collector race
    // to reclaim a number nobody measured.
    freeBlockFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_deserializer_sizeof(),
    );
  }

  final ZBytes _source;
  final Pointer<ze_deserializer_t> _ptr;
  bool _disposed = false;

  static Pointer<ze_deserializer_t> _create(ZBytes bytes) {
    // ALLOCATE-LAST: a disposed or consumed source throws StateError from
    // nativePtr, and that used to happen with the deserializer block already
    // allocated and nothing holding a reference to it.
    final sourcePtr = bytes.nativePtr;

    final size = bindings.zd_deserializer_sizeof();
    final ptr = calloc.allocate<ze_deserializer_t>(size);
    final loaned = bindings.zd_bytes_loan(sourcePtr.cast());
    bindings.zd_deserializer_from_bytes(loaned, ptr);
    return ptr;
  }

  void _checkState() {
    if (_disposed) throw StateError('ZDeserializer has been disposed');
    if (!_source.isLive) {
      // The cursor points into the source's native storage, so reading after
      // the source is released is a use-after-free the VM cannot see. Fail
      // loudly instead.
      throw StateError(
        'ZDeserializer source ZBytes has been disposed or consumed',
      );
    }
  }

  /// Returns true if all data has been deserialized.
  bool get isDone {
    _checkState();
    return bindings.zd_deserializer_is_done(_ptr);
  }

  /// Deserializes a uint8 value.
  int deserializeUint8() {
    _checkState();
    final out = calloc<Uint8>();
    try {
      final rc = bindings.zd_deserializer_deserialize_uint8(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize uint8', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a uint16 value.
  int deserializeUint16() {
    _checkState();
    final out = calloc<Uint16>();
    try {
      final rc = bindings.zd_deserializer_deserialize_uint16(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize uint16', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a uint32 value.
  int deserializeUint32() {
    _checkState();
    final out = calloc<Uint32>();
    try {
      final rc = bindings.zd_deserializer_deserialize_uint32(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize uint32', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a uint64 value.
  int deserializeUint64() {
    _checkState();
    final out = calloc<Uint64>();
    try {
      final rc = bindings.zd_deserializer_deserialize_uint64(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize uint64', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes an int8 value.
  int deserializeInt8() {
    _checkState();
    final out = calloc<Int8>();
    try {
      final rc = bindings.zd_deserializer_deserialize_int8(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize int8', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes an int16 value.
  int deserializeInt16() {
    _checkState();
    final out = calloc<Int16>();
    try {
      final rc = bindings.zd_deserializer_deserialize_int16(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize int16', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes an int32 value.
  int deserializeInt32() {
    _checkState();
    final out = calloc<Int32>();
    try {
      final rc = bindings.zd_deserializer_deserialize_int32(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize int32', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes an int64 value.
  int deserializeInt64() {
    _checkState();
    final out = calloc<Int64>();
    try {
      final rc = bindings.zd_deserializer_deserialize_int64(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize int64', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a float value.
  double deserializeFloat() {
    _checkState();
    final out = calloc<Float>();
    try {
      final rc = bindings.zd_deserializer_deserialize_float(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize float', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a double value.
  double deserializeDouble() {
    _checkState();
    final out = calloc<Double>();
    try {
      final rc = bindings.zd_deserializer_deserialize_double(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize double', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a bool value.
  bool deserializeBool() {
    _checkState();
    final out = calloc<Bool>();
    try {
      final rc = bindings.zd_deserializer_deserialize_bool(_ptr, out);
      if (rc != 0) throw ZenohException('Failed to deserialize bool', rc);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Deserializes a UTF-8 string value.
  ///
  /// ⛔ **Throws [ZenohException] with `returnCode` `-7` (canon's
  /// `Z_EDESERIALIZE`) when the bytes in the string slot are not valid
  /// UTF-8.** Canon deserializes into a Rust `String`, which validates, and
  /// this binding surfaces its refusal.
  ///
  /// ⚠️ **It does NOT return U+FFFD, and the dartdoc here used to promise
  /// that it did.** The promise was unreachable rather than merely unusual:
  /// canon's validation happens first, so the lenient decode below never sees
  /// an invalid sequence. Measured — bytes written by the non-validating
  /// serialize-side twin come back from this method as a throw, never as a
  /// replacement character.
  ///
  /// The reachable way to get here is a payload whose string slot was filled
  /// by a non-validating writer: `ze_serializer_serialize_slice` takes raw
  /// bytes while `ze_serializer_serialize_string` validates on the way in and
  /// returns `Z_EUTF8`, and the two emit the same length-prefixed byte run.
  ///
  /// Valid content round-trips exactly, multi-byte included, and an empty
  /// string comes back as an empty string rather than as a failure.
  String deserializeString() {
    _checkState();
    final ownedStr = calloc.allocate<Void>(bindings.zd_string_sizeof());
    try {
      final rc = bindings.zd_deserializer_deserialize_string(
        _ptr,
        ownedStr.cast(),
      );
      if (rc != 0) throw ZenohException('Failed to deserialize string', rc);
      final loanedStr = bindings.zd_string_loan(ownedStr.cast());
      final data = bindings.zd_string_data(loanedStr);
      final len = bindings.zd_string_len(loanedStr);
      if (len == 0) return '';
      final bytes = data.cast<Uint8>().asTypedList(len);
      // ⚠️ `allowMalformed` is UNREACHABLE at the pinned zenoh-c and is kept
      // deliberately. Canon validates before we get here (it deserializes
      // into a Rust `String`), so an invalid sequence throws above and never
      // reaches this line. It stays as a defence for the day canon's
      // validation relaxes -- and this comment stays with it, so a later
      // reader neither deletes it as dead code nor re-documents it as a
      // promise this method makes.
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      bindings.zd_string_drop(ownedStr.cast());
      calloc.free(ownedStr);
    }
  }

  /// Deserializes a byte buffer.
  Uint8List deserializeBytes() {
    _checkState();
    final ownedBytes = calloc.allocate<Void>(
      bindings.zd_bytes_sizeof(),
    );
    try {
      final rc = bindings.zd_deserializer_deserialize_buf(
        _ptr,
        ownedBytes.cast(),
      );
      if (rc != 0) throw ZenohException('Failed to deserialize bytes', rc);
      final len = bindings.zd_bytes_len(ownedBytes.cast());
      if (len == 0) return Uint8List(0);
      final buf = malloc<Uint8>(len);
      try {
        bindings.zd_bytes_to_buf(ownedBytes.cast(), buf, len);
        return Uint8List.fromList(buf.asTypedList(len));
      } finally {
        malloc.free(buf);
      }
    } finally {
      bindings.zd_bytes_drop(ownedBytes.cast());
      calloc.free(ownedBytes);
    }
  }

  /// Deserializes a sequence length header.
  int deserializeSequenceLength() {
    _checkState();
    final out = calloc<Size>();
    try {
      final rc = bindings.zd_deserializer_deserialize_sequence_length(
        _ptr,
        out,
      );
      if (rc != 0) {
        throw ZenohException('Failed to deserialize sequence length', rc);
      }
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Releases native resources held by this deserializer.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // DETACH BEFORE THE FREE. A missed detach here is a double free: the
    // finalizer would later hand the same block to `free()` a second time.
    // Detaching an already-detached key is harmless, which is what keeps the
    // "safe to call multiple times" contract above true -- that sentence now
    // also means "and the net is taken down exactly once".
    freeBlockFinalizer.detach(this);
    calloc.free(_ptr);
  }
}
