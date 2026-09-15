import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'package:zenoh_dart/src/bindings.dart'
    show z_bytes_slice_iterator_t, z_view_slice_t;
import 'package:zenoh_dart/src/deserializer.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/serializer.dart';

/// A Zenoh byte payload.
///
/// Wraps `z_owned_bytes_t`. Use [ZBytes.fromString] or [ZBytes.fromUint8List]
/// to create a payload, and [toStr] to extract its content as a string.
///
/// Must be [dispose]d when no longer needed to release native memory.
///
/// ## Single-shot scalar conversions
///
/// Every canon scalar width has a single-shot pair here: [ZBytes.fromUint8]
/// / [toUint8] through [ZBytes.fromUint64] / [toUint64], [ZBytes.fromInt8] /
/// [toInt8] through [ZBytes.fromInt] / [toInt], [ZBytes.fromFloat] /
/// [toFloat], [ZBytes.fromDouble] / [toDouble] and [ZBytes.fromBool] /
/// [toBool]. Each composes over the shipped [ZSerializer] / [ZDeserializer]
/// pair and produces output byte-identical to canon's own one-shot family --
/// measured across all eleven scalar widths, which is why none of them
/// needed a shim function of its own.
///
/// **The names are widths.** [ZBytes.fromInt] / [toInt] are int64 and
/// [ZBytes.fromDouble] / [toDouble] are binary64, unchanged and named for
/// Dart's types rather than canon's. [ZBytes.fromFloat] / [toFloat] are
/// binary32 -- a different width, not a synonym for the double pair. And
/// [ZBytes.fromString] / [toStr] are raw unframed UTF-8, NOT the
/// serializer's length-prefixed string form: those two payloads differ by
/// the prefix and are not interchangeable.
///
/// **Conventions.** Every parameter and return is non-nullable (CONV-2):
/// after the domain guard each width is total, so there is no "unspecified,
/// canon decides" case for a nullable to stand for. Each constructor takes
/// one positional parameter (CONV-2b), so a parameter and not an options
/// class. The narrow integer widths carry a Dart-side domain guard naming
/// the domain (CONV-4(c)) -- inherited from [ZSerializer] by composition,
/// deliberately not duplicated here, so one policy governs the whole
/// surface. [ZBytes.fromUint64] and [ZBytes.fromFloat] carry no guard, for
/// the same reasons the serializer's do not: every Dart int is a valid
/// 64-bit pattern, and every finite f64 has a defined nearest binary32.
///
/// **Two failure codes, and never one.** A payload SHORTER than the width
/// fails with canon's own `-7` (`Z_EDESERIALIZE`), measured on the streaming
/// family these methods call. A payload carrying data BEYOND the value fails
/// with `12`, which is binding-owned and positive on purpose: on that path
/// canon's streaming deserializer returns `Z_OK` -- it accepts the bytes,
/// and the leftover is detected Dart-side through [ZDeserializer.isDone]. A
/// canon negative there would masquerade as a rejection canon never made, so
/// codes minted by this binding live in canon-free positive space beside the
/// shipped `10` (capacity out of range) and `11` (allocation failure). One
/// policy governs all eleven conversions: [toInt], [toDouble] and [toBool]
/// once reported `-1` (`Z_EINVAL`) here and no longer do.
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
class ZBytes implements Finalizable {
  ZBytes._(this._ptr) {
    _attachNet();
  }

  /// Creates [ZBytes] wrapping an existing native z_owned_bytes_t pointer.
  ///
  /// Used internally by `ShmMutBuffer.toBytes` (unstable door) for zero-copy
  /// conversion.
  ///
  /// The pointer must address a heap-allocated `z_owned_bytes_t` that this
  /// package allocated and that no other [ZBytes] wraps. Every in-package
  /// caller passes a pointer it has just allocated itself.
  ///
  /// ⛔ **There are two ways to get this wrong, and a consumer can reach
  /// both.** *(Corrected: this said "the library never hands one out — no
  /// member returns this address". That is false: the public [nativePtr]
  /// getter returns exactly such an address.)*
  ///
  /// - **A pointer this library did not produce aborts the VM.** It is
  ///   stored and dereferenced without validation; nothing can reject a
  ///   wrong one, so the process dies where an ordinary API would throw.
  /// - **A real pointer, obtained through [nativePtr], builds a second
  ///   wrapper** over a block another [ZBytes] still owns. Each wrapper
  ///   releases that block, so the second release works on memory that has
  ///   already been freed and the process dies — measured on Linux at the
  ///   second [dispose].
  ///
  /// ⚠️ **The crash need not arrive where the mistake was made.** This
  /// constructor arms the `NativeFinalizer` net unconditionally, so even a
  /// [ZBytes] that is never read and never disposed is released when it is
  /// collected — at a moment the collector picks, on a stack with nothing to
  /// do with the construction. Either wrong pointer can therefore abort long
  /// after, and far from, the call that supplied it: a second wrapper that is
  /// never disposed still releases its block through the net. (`Query` is
  /// the contrary case: it arms no net, so its abort arrives at first use
  /// instead.)
  ///
  /// Marked `@internal`, so naming it from another package draws a warning.
  /// ⛔ **A warning, not a fence**: [ZBytes] is exported and this constructor
  /// still resolves from a consumer.
  @internal
  ZBytes.fromNative(this._ptr) {
    _attachNet();
  }

  /// Creates [ZBytes] by copying the given [value] string.
  ///
  /// The string is encoded to UTF-8 bytes and copied via the length-based
  /// native copy, so embedded NUL characters are preserved (a NUL-terminated
  /// copy would truncate at the first NUL). This mirrors
  /// [ZBytes.fromUint8List].
  ///
  /// Throws [ZenohException] if the native copy fails.
  factory ZBytes.fromString(String value) {
    final data = Uint8List.fromList(utf8.encode(value));
    final ptr = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    final nativeBuf = calloc<Uint8>(data.length);
    // memcpy-form copy, the idiom already used at serializer.dart:253/270,
    // native_string.dart:35 and keyexpr.dart:282. Guarded on non-empty: the
    // byte loop was vacuously safe at length 0 and `asTypedList` need not be.
    if (data.isNotEmpty) {
      nativeBuf.asTypedList(data.length).setAll(0, data);
    }
    try {
      final rc = bindings.zd_bytes_copy_from_buf(
        ptr.cast(),
        nativeBuf,
        data.length,
      );
      if (rc != 0) {
        calloc.free(ptr);
        throw ZenohException('Failed to create ZBytes from string', rc);
      }
    } finally {
      calloc.free(nativeBuf);
    }
    return ZBytes._(ptr);
  }

  /// Creates [ZBytes] by copying the given [data] buffer.
  ///
  /// Throws [ZenohException] if the native copy fails.
  factory ZBytes.fromUint8List(Uint8List data) {
    final ptr = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    final nativeBuf = calloc<Uint8>(data.length);
    // memcpy-form copy, the idiom already used at serializer.dart:253/270,
    // native_string.dart:35 and keyexpr.dart:282. Guarded on non-empty: the
    // byte loop was vacuously safe at length 0 and `asTypedList` need not be.
    if (data.isNotEmpty) {
      nativeBuf.asTypedList(data.length).setAll(0, data);
    }
    try {
      final rc = bindings.zd_bytes_copy_from_buf(
        ptr.cast(),
        nativeBuf,
        data.length,
      );
      if (rc != 0) {
        calloc.free(ptr);
        throw ZenohException('Failed to create ZBytes from buffer', rc);
      }
    } finally {
      calloc.free(nativeBuf);
    }
    return ZBytes._(ptr);
  }

  /// Creates [ZBytes] containing a serialized int64 value.
  factory ZBytes.fromInt(int value) {
    final ser = ZSerializer()..serializeInt64(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized double value.
  factory ZBytes.fromDouble(double value) {
    final ser = ZSerializer()..serializeDouble(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized bool value.
  // The sole argument of a single-value converter; a named parameter would
  // diverge from canon (`ze_serializer_serialize_bool`) and from the sibling
  // fromInt/fromDouble constructors.
  // ignore: avoid_positional_boolean_parameters
  factory ZBytes.fromBool(bool value) {
    final ser = ZSerializer()..serializeBool(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized uint8 value.
  ///
  /// [value] must lie in `0..255`. An out-of-domain value throws an
  /// [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeUint8] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromUint8(int value) {
    final ser = ZSerializer()..serializeUint8(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized uint16 value.
  ///
  /// [value] must lie in `0..65535`. An out-of-domain value throws an
  /// [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeUint16] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromUint16(int value) {
    final ser = ZSerializer()..serializeUint16(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized uint32 value.
  ///
  /// [value] must lie in `0..4294967295`. An out-of-domain value throws an
  /// [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeUint32] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromUint32(int value) {
    final ser = ZSerializer()..serializeUint32(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized uint64 value.
  ///
  /// Unguarded, and it cannot be otherwise: every Dart int is a valid
  /// 64-bit pattern, so a value above 2^63 is carried as its bit-exact
  /// two's complement rather than rejected. See [toUint64] for what
  /// reading such a payload back returns.
  factory ZBytes.fromUint64(int value) {
    final ser = ZSerializer()..serializeUint64(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized int8 value.
  ///
  /// [value] must lie in `-128..127`. An out-of-domain value throws an
  /// [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeInt8] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromInt8(int value) {
    final ser = ZSerializer()..serializeInt8(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized int16 value.
  ///
  /// [value] must lie in `-32768..32767`. An out-of-domain value throws an
  /// [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeInt16] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromInt16(int value) {
    final ser = ZSerializer()..serializeInt16(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized int32 value.
  ///
  /// [value] must lie in `-2147483648..2147483647`. An out-of-domain value
  /// throws an [ArgumentError] naming the domain, raised by
  /// [ZSerializer.serializeInt32] before any native call is made -- this
  /// surface inherits that guard rather than repeating it.
  factory ZBytes.fromInt32(int value) {
    final ser = ZSerializer()..serializeInt32(value);
    return ser.finish();
  }

  /// Creates [ZBytes] containing a serialized float (binary32) value.
  ///
  /// Unguarded, and narrowing: every finite f64 has a defined nearest
  /// binary32 under IEEE-754, so this is a specified rounding rather than
  /// a wrap, and it matches canon's own `float`-typed entry point. NaN
  /// and the infinities carry across unchanged. Distinct from
  /// [ZBytes.fromDouble], which is binary64.
  factory ZBytes.fromFloat(double value) {
    final ser = ZSerializer()..serializeFloat(value);
    return ser.finish();
  }

  final Pointer<Void> _ptr;
  bool _disposed = false;
  bool _consumed = false;

  /// Materialises a retained payload handle from the byte image that the
  /// shim's receive callbacks post as their retention element.
  ///
  /// The image is the raw `sizeof(z_owned_bytes_t)` bytes of an owned handle
  /// the shim cloned and **transferred**: `Dart_PostCObject_DL` copies typed
  /// data before it returns, so what arrives here is the struct's content and
  /// the refcount it carries, with no owner left on the C side. This
  /// bitwise-moves that content into a **Dart-allocated** slot, which is what
  /// [dispose] and the finalizer both require — each releases with Dart's
  /// allocator, so a shim-`malloc`'d address could not be handed to either.
  ///
  /// ⛔ The size is read from `zd_bytes_sizeof()` at run time, never written as
  /// a literal: `sizeof(z_owned_bytes_t)` is **variant-dependent** (40 on the
  /// unstable build, 32 on stable), and a hardcoded class would be silently
  /// wrong on whichever variant it was not calibrated against.
  ///
  /// Returns null for an absent image — retention off, or no payload element.
  @internal
  static ZBytes? fromPostedImage(Uint8List? image) {
    if (image == null) return null;
    final expected = bindings.zd_bytes_sizeof();
    if (image.length != expected) {
      // Loud rather than silent. Constructing over a truncated image would
      // read uninitialised memory as a refcount, and the first symptom would
      // be a free of an address that was never allocated.
      throw StateError(
        'retained payload image is ${image.length} bytes, '
        'expected $expected (zd_bytes_sizeof)',
      );
    }
    final ptr = calloc.allocate<Void>(expected);
    ptr.cast<Uint8>().asTypedList(expected).setAll(0, image);
    return ZBytes.fromNative(ptr);
  }

  /// Converts the payload to a Dart string.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed.
  /// Throws [ZenohException] if the conversion fails.
  /// Internal: returns the native pointer for use by Session.put/putBytes.
  Pointer<Void> get nativePtr {
    _ensureNotDisposed();
    _ensureNotConsumed();
    return _ptr;
  }

  /// Attaches the safety net.
  ///
  /// `detach: this` is the key: ONE `detach(this)` on either release path
  /// reverses it, so the explicit paths and the finalizer are mutually
  /// exclusive by construction rather than by a flag.
  ///
  /// ⛔ **NO `externalSize` HERE, AND THIS IS THE ONE CLASS IN THE NET WITHOUT
  /// IT.** The other nine pass their slot size, per DQ-F. `ZBytes` does not,
  /// by gate ruling, on a measurement.
  ///
  /// **The mechanism, which is the actual ground:** `externalSize` tells the VM
  /// about native memory behind a Dart object and so drives GC SCHEDULING. Its
  /// *benefit* scales with how often the net FIRES; its *cost* scales with how
  /// often the object is CONSTRUCTED. On the nine other classes those track
  /// each other. On `ZBytes` they diverge maximally: it is constructed **once
  /// per message** on the clone-in-loop throughput and ping paths, and the net
  /// fires only on a caller's bug.
  ///
  /// **Measured** (`z_pub_thr 8192`, arms interleaved on a clean host): with
  /// `externalSize` passed, throughput was below the pre-marker tree in 3 of 3
  /// runs (−5.3 %, −5.4 %, −1.9 %); omitted, it returned to within **0.4 %** in
  /// 2 of 2. The omitted arm is also markedly *tighter*, which is what
  /// identifies GC scheduling as the mechanism rather than merely correlating
  /// with it.
  ///
  /// ⚠️ **THE RESIDUAL, because it cuts the other way and is real.** A program
  /// that *does* leak a `ZBytes` now gets a **later** collection, so the leak
  /// grows further before the net catches it — and that is precisely the case
  /// the net exists for. Bounded and deliberately not measured (*"how much
  /// later"* is awkward to instrument and the consequence is bounded); stated
  /// here and carried to the seed's close so `[10a]`, which owns the payload
  /// path, inherits it.
  void _attachNet() {
    bytesFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  /// Internal: whether the native handle is still owned and usable.
  ///
  /// Exposed so a BORROWER can guard its own accessors on the source's
  /// liveness rather than only on its own. [ZDeserializer] holds a native
  /// cursor into these bytes, so once they are disposed or consumed every
  /// further read from that cursor is a use-after-free -- and the deserializer
  /// cannot see either flag through [nativePtr] without pretending to want the
  /// pointer.
  @internal
  bool get isLive => !_disposed && !_consumed;

  /// Internal: called by a send site after the bytes have been moved into
  /// zenoh-c via `z_bytes_move`.
  ///
  /// The move gravestones the native `z_owned_bytes_t`, so the Dart-owned
  /// calloc block wrapping it is dead memory the instant the FFI call
  /// returns. Freeing it here -- rather than in [dispose] -- is what reaches
  /// every caller: a consumed payload is never disposed on the hot path (the
  /// clone-in-loop publishers drop the reference immediately), so a
  /// dispose-side free would still leak one block per message.
  ///
  /// The native handle is deliberately NOT dropped: zenoh-c has already
  /// gravestoned it, and drop-after-move is the double-drop class.
  ///
  /// Every accessor guards on `_consumed` before touching `_ptr`, so the
  /// pointer is unreachable once this returns. Callers must therefore mark
  /// only *after* the FFI call that consumes the bytes has returned -- never
  /// before it, and never while a derived pointer (a loan, a captured
  /// address) is still live.
  void markConsumed() {
    if (_disposed || _consumed) return;
    _consumed = true;
    // ⛔ THE SEND-PATH DETACH. This frees the block rather than transferring
    // it, so without this line the finalizer would hand the same address to
    // `free()` a second time -- a double free once per message on the
    // clone-in-loop paths, not a leak. Canon has already gravestoned the
    // handle, so the finalizer's `zd_bytes_drop` would be a drop-after-move
    // besides.
    bytesFinalizer.detach(this);
    calloc.free(_ptr);
  }

  /// Converts the payload to a Dart string via a lenient UTF-8 decode.
  ///
  /// Reads the raw payload bytes through the byte-faithful reader (the same
  /// path as [toBytes]) and decodes them with `allowMalformed: true`, so
  /// non-UTF-8 payloads yield U+FFFD replacement characters rather than
  /// throwing. This keeps `toStr` a lenient display view over an opaque byte
  /// contract; use [toBytes] for the exact bytes.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  String toStr() => utf8.decode(toBytes(), allowMalformed: true);

  /// Reads the payload content as a [Uint8List].
  ///
  /// This is a non-destructive read -- the [ZBytes] can still be used after
  /// calling this method.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  Uint8List toBytes() {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final len = bindings.zd_bytes_len(_ptr.cast());
    if (len == 0) return Uint8List(0);
    final buf = malloc<Uint8>(len);
    try {
      bindings.zd_bytes_to_buf(_ptr.cast(), buf, len);
      return Uint8List.fromList(buf.asTypedList(len));
    } finally {
      malloc.free(buf);
    }
  }

  /// Creates an independent shallow copy of this [ZBytes].
  ///
  /// The clone shares the underlying reference-counted data but has its own
  /// native ownership -- disposing the clone does not affect the original,
  /// and vice versa.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  /// Throws [ZenohException] if the native clone fails.
  ZBytes clone() {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final dst = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    final rc = bindings.zd_bytes_clone(dst.cast(), _ptr.cast());
    if (rc != 0) {
      calloc.free(dst);
      throw ZenohException('Failed to clone ZBytes', rc);
    }
    return ZBytes._(dst);
  }

  /// Reads exactly one value of [width] out of this payload, and nothing
  /// else.
  ///
  /// Every single-shot conversion on this class routes through here, so one
  /// policy governs all eleven of them rather than eleven copies of it.
  /// [read] performs canon's own streaming read, and a payload SHORTER than
  /// the width fails inside it with canon's `-7` (`Z_EDESERIALIZE`) --
  /// adopted, because canon reported it. The leftover check afterwards is
  /// the binding's own: canon's streaming deserializer returns `Z_OK` on
  /// trailing data, so `12` is minted here in canon-free positive space
  /// rather than borrowed from a rejection canon never made.
  T _readOne<T>(String width, T Function(ZDeserializer) read) {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final deser = ZDeserializer(this);
    try {
      final value = read(deser);
      if (!deser.isDone) {
        throw ZenohException('ZBytes contains extra data after $width', 12);
      }
      return value;
    } finally {
      deser.dispose();
    }
  }

  /// Deserializes the payload as an int64 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the int64 width, and with code `12`
  /// (binding-owned) if it carries data beyond the int64 value (e.g. a
  /// multi-value payload) -- see the class doc for why those two codes
  /// must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toInt() => _readOne('int64', (d) => d.deserializeInt64());

  /// Deserializes the payload as a double value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the double width, and with code `12`
  /// (binding-owned) if it carries data beyond the double value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  double toDouble() => _readOne('double', (d) => d.deserializeDouble());

  /// Deserializes the payload as a bool value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the bool width, and with code `12`
  /// (binding-owned) if it carries data beyond the bool value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  bool toBool() => _readOne('bool', (d) => d.deserializeBool());

  /// Deserializes the payload as a uint8 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the uint8 width, and with code `12`
  /// (binding-owned) if it carries data beyond the uint8 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toUint8() => _readOne('uint8', (d) => d.deserializeUint8());

  /// Deserializes the payload as a uint16 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the uint16 width, and with code `12`
  /// (binding-owned) if it carries data beyond the uint16 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toUint16() => _readOne('uint16', (d) => d.deserializeUint16());

  /// Deserializes the payload as a uint32 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the uint32 width, and with code `12`
  /// (binding-owned) if it carries data beyond the uint32 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toUint32() => _readOne('uint32', (d) => d.deserializeUint32());

  /// Deserializes the payload as a uint64 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the uint64 width, and with code `12`
  /// (binding-owned) if it carries data beyond the uint64 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// A payload whose top bit is set is returned as the corresponding
  /// negative Dart int: the same 64 bits, in the only form Dart can
  /// represent, and not a transform applied to the value.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toUint64() => _readOne('uint64', (d) => d.deserializeUint64());

  /// Deserializes the payload as a int8 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the int8 width, and with code `12`
  /// (binding-owned) if it carries data beyond the int8 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toInt8() => _readOne('int8', (d) => d.deserializeInt8());

  /// Deserializes the payload as a int16 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the int16 width, and with code `12`
  /// (binding-owned) if it carries data beyond the int16 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toInt16() => _readOne('int16', (d) => d.deserializeInt16());

  /// Deserializes the payload as a int32 value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the int32 width, and with code `12`
  /// (binding-owned) if it carries data beyond the int32 value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  int toInt32() => _readOne('int32', (d) => d.deserializeInt32());

  /// Deserializes the payload as a float value.
  ///
  /// Throws [ZenohException] with code `-7` (canon's `Z_EDESERIALIZE`)
  /// if the payload is shorter than the float width, and with code `12`
  /// (binding-owned) if it carries data beyond the float value -- see
  /// the class doc for why those two codes must differ.
  ///
  /// Returns the binary32 value widened back to a Dart double, so a
  /// value narrowed on the way in comes back as its nearest binary32
  /// rather than as the original f64. Distinct from [toDouble].
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  double toFloat() => _readOne('float', (d) => d.deserializeFloat());

  /// Returns the internal byte slices.
  ///
  /// Each element is a [Uint8List] copy of one contiguous slice of the
  /// underlying payload. The native pointers are not retained across
  /// iterations.
  ///
  /// The native walk runs to completion inside this call and the slices are
  /// then served from a Dart list. It used to be a `sync*` generator holding
  /// two native structs across its yields, and a `sync*` generator's `finally`
  /// NEVER runs for an abandoned iterator — Dart offers no close hook — so
  /// `.first`, a `break`, or `.take(n)` leaked both structs every time (proven
  /// by probe: the finally ran on full iteration only, and not even under GC
  /// pressure otherwise). Nothing about the values changes: the same per-slice
  /// copies, in the same order, behind the same `Iterable<Uint8List>`.
  ///
  /// Throws [StateError] if this [ZBytes] has been disposed or consumed.
  Iterable<Uint8List> get slices {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final loaned = bindings.zd_bytes_loan(_ptr.cast());
    final iterPtr = calloc.allocate<z_bytes_slice_iterator_t>(
      bindings.zd_bytes_slice_iterator_sizeof(),
    );
    bindings.zd_bytes_get_slice_iterator(loaned, iterPtr);
    final slicePtr = calloc.allocate<z_view_slice_t>(
      bindings.zd_view_slice_sizeof(),
    );
    final out = <Uint8List>[];
    try {
      while (bindings.zd_bytes_slice_iterator_next(iterPtr, slicePtr)) {
        final data = bindings.zd_view_slice_data(slicePtr);
        final len = bindings.zd_view_slice_len(slicePtr);
        out.add(Uint8List.fromList(data.cast<Uint8>().asTypedList(len)));
      }
    } finally {
      calloc
        ..free(slicePtr)
        ..free(iterPtr);
    }
    return out;
  }

  /// Releases native resources held by this payload.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void dispose() {
    if (_disposed) return;
    // Consumed bytes were already released by markConsumed: the native handle
    // is gravestoned and the wrapper block is freed. Dropping or freeing again
    // here would be a double-drop / double-free. The detach happened there
    // too, so this early return leaves nothing attached.
    if (_consumed) return;
    _disposed = true;
    bytesFinalizer.detach(this);
    bindings.zd_bytes_drop(_ptr.cast());
    calloc.free(_ptr);
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('ZBytes has been disposed');
  }

  void _ensureNotConsumed() {
    if (_consumed) throw StateError('ZBytes has been consumed');
  }
}
