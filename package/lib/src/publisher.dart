import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/locality.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/native_string.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/session.dart' show Session;
import 'package:zenoh_dart/src/timestamp.dart';

/// A zenoh publisher for efficiently publishing multiple messages on a
/// single key expression.
///
/// Wraps `z_owned_publisher_t`. Call [close] when done to undeclare the
/// publisher and release native resources.
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
class Publisher implements Finalizable {
  /// Creates a publisher on the given session and key expression.
  ///
  /// This is called internally by [Session.declarePublisher].
  ///
  /// [congestionControl], [priority], [isExpress] and [allowedDestination] are
  /// each optional; omitting one — or passing `null` — means **canon decides**.
  /// A publisher is a *push* path, so canon's congestion default here is
  /// [CongestionControl.drop]; the other defaults are [Priority.data],
  /// `isExpress: false` and [Locality.any].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block].
  factory Publisher.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe, {
    Encoding? encoding,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    bool enableMatchingListener = false,
  }) {
    final size = bindings.zd_publisher_sizeof();
    final ptr = calloc.allocate<Void>(size);

    // Two INDEPENDENT length-carried channels (R-2), from the RAW pair (R-3a).
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);

    try {
      final rc = bindings.zd_declare_publisher(
        loanedSession.cast(),
        ptr.cast(),
        loanedKe.cast(),
        encodingBuf.ptr,
        encodingBuf.len,
        schemaBuf.ptr,
        schemaBuf.len,
        congestionControl?.value ?? -1,
        priority?.value ?? -1,
        isExpress == null ? -1 : (isExpress ? 1 : 0),
        allowedDestination?.value ?? -1,
      );

      if (rc != 0) {
        calloc.free(ptr);
        throw ZenohException('Failed to declare publisher', rc);
      }
    } finally {
      // allocLengthCarriedUtf8 uses calloc, so the release is calloc.free.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
    }

    ReceivePort? matchingPort;
    StreamController<bool>? matchingController;

    if (enableMatchingListener) {
      matchingPort = ReceivePort();
      matchingController = StreamController<bool>();

      matchingPort.listen((dynamic message) {
        if (message is int) {
          matchingController!.add(message != 0);
        }
      });

      final loaned = bindings.zd_publisher_loan(ptr.cast());
      final mlRc = bindings.zd_publisher_declare_background_matching_listener(
        loaned,
        matchingPort.sendPort.nativePort,
      );

      if (mlRc != 0) {
        matchingPort.close();
        unawaited(matchingController.close());
        bindings.zd_publisher_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare matching listener', mlRc);
      }
    }

    return Publisher._(ptr, matchingPort, matchingController);
  }

  Publisher._(this._ptr, this._matchingPort, this._matchingController) {
    // ⛔ THE NET IS CONDITIONAL AND THE MARKER IS NOT. A matching listener
    // means this object holds a `ReceivePort`, and canon's drop callback for
    // it POSTS to a Dart port -- which from a `NativeFinalizer` callback is
    // documented undefined behaviour ("not allowed to re-enter the Dart VM via
    // Dart C APIs"). So the `ml:ON` configuration keeps today's
    // leak-on-forget, deliberately.
    //
    // ⚠️ Criterion (ii) for the `ml:off` configuration is MEASURED, not read:
    // 0 posts under `zd_publisher_drop` in BOTH the
    // one-session and TCP-loopback topologies. Reading it is what cost
    // `Querier` and `Query` their admission to this net.
    if (_matchingPort == null) {
      publisherFinalizer.attach(
        this,
        _ptr.cast(),
        detach: this,
        externalSize: bindings.zd_publisher_sizeof(),
      );
    }
  }

  final Pointer<Void> _ptr;
  bool _closed = false;
  final ReceivePort? _matchingPort;
  final StreamController<bool>? _matchingController;

  void _ensureOpen() {
    if (_closed) throw StateError('Publisher has been closed');
  }

  /// Copies a [Timestamp]'s raw 24 bytes into freshly `calloc`'d native memory.
  ///
  /// `calloc` returns 8-byte-aligned storage, which the C shim requires before
  /// reinterpreting the bytes as an ALIGN(8) `z_timestamp_t`. The caller must
  /// free the returned pointer.
  Pointer<Uint8> _timestampToNative(Timestamp ts) {
    final tsSize = bindings.zd_timestamp_sizeof();
    assert(tsSize == 24, 'z_timestamp_t drifted from 24 bytes: $tsSize');
    final p = calloc<Uint8>(tsSize);
    p.asTypedList(tsSize).setAll(0, ts.rawBytes);
    return p;
  }

  /// The key expression this publisher is declared on.
  String get keyExpr {
    _ensureOpen();
    final loaned = bindings.zd_publisher_loan(_ptr.cast());
    final loanedKe = bindings.zd_publisher_keyexpr(loaned);
    final viewStrSize = bindings.zd_view_string_sizeof();
    final viewStr = calloc.allocate<Void>(viewStrSize);
    bindings.zd_keyexpr_as_view_string(loanedKe, viewStr.cast());
    final data = bindings.zd_view_string_data(viewStr.cast());
    final len = bindings.zd_view_string_len(viewStr.cast());
    final result = data.cast<Utf8>().toDartString(length: len);
    calloc.free(viewStr);
    return result;
  }

  /// Publishes a string [value] through this publisher.
  ///
  /// Optionally override the [encoding] for this specific put.
  /// An optional [attachment] can be included (consumed by this call).
  /// An optional [timestamp] can be attached to the message; borrowed, not
  /// consumed.
  void put(
    String value, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
  }) {
    _ensureOpen();
    // ALLOCATE-LAST: the attachment handle is read before anything is
    // created. A disposed or already-consumed attachment throws StateError
    // here, and it used to throw with the internally-created payload ZBytes
    // (contents AND wrapper) and the encoding string already live and
    // unreleasable -- nothing else holds a reference to that payload.
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    final loaned = bindings.zd_publisher_loan(_ptr.cast());

    // Two INDEPENDENT length-carried channels (R-2), from the RAW pair (R-3a).
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;

    try {
      // Created inside the try so the finally covers it: nothing between here
      // and the FFI call can throw, so the payload is always either moved or
      // never built.
      final payload = ZBytes.fromString(value);
      final rc = bindings.zd_publisher_put(
        loaned,
        payload.nativePtr.cast(),
        encodingBuf.ptr,
        encodingBuf.len,
        schemaBuf.ptr,
        schemaBuf.len,
        attachmentPtr.cast(),
        tsPtr.cast(),
      );

      payload.markConsumed();
      if (attachment != null) attachment.markConsumed();

      if (rc != 0) {
        throw ZenohException('Publisher put failed', rc);
      }
    } finally {
      // allocLengthCarriedUtf8 uses calloc, so the release is calloc.free.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Publishes [ZBytes] [payload] through this publisher.
  ///
  /// The payload is consumed by this call and must not be reused.
  /// An optional [attachment] can be included (consumed by this call).
  /// An optional [timestamp] can be attached to the message; borrowed, not
  /// consumed.
  void putBytes(
    ZBytes payload, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
  }) {
    _ensureOpen();
    // ALLOCATE-LAST: both handle reads run before the first allocation. The
    // attachment read used to sit AFTER the encoding string was allocated, so
    // a disposed or consumed attachment stranded it.
    final payloadPtr = payload.nativePtr;
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    final loaned = bindings.zd_publisher_loan(_ptr.cast());

    // Two INDEPENDENT length-carried channels (R-2), from the RAW pair (R-3a).
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;

    try {
      final rc = bindings.zd_publisher_put(
        loaned,
        payloadPtr.cast(),
        encodingBuf.ptr,
        encodingBuf.len,
        schemaBuf.ptr,
        schemaBuf.len,
        attachmentPtr.cast(),
        tsPtr.cast(),
      );

      payload.markConsumed();
      if (attachment != null) attachment.markConsumed();

      if (rc != 0) {
        throw ZenohException('Publisher put failed', rc);
      }
    } finally {
      // allocLengthCarriedUtf8 uses calloc, so the release is calloc.free.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Sends a DELETE through this publisher.
  ///
  /// An optional [timestamp] can be attached to the message; borrowed, not
  /// consumed.
  void deleteResource({Timestamp? timestamp}) {
    _ensureOpen();
    final loaned = bindings.zd_publisher_loan(_ptr.cast());
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;
    try {
      final rc = bindings.zd_publisher_delete(loaned, tsPtr.cast());
      if (rc != 0) {
        throw ZenohException('Publisher delete failed', rc);
      }
    } finally {
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Returns whether any subscribers currently match this publisher's
  /// key expression.
  bool hasMatchingSubscribers() {
    _ensureOpen();
    final loaned = bindings.zd_publisher_loan(_ptr.cast());
    final matching = calloc<Int>();
    try {
      final rc = bindings.zd_publisher_get_matching_status(loaned, matching);
      if (rc != 0) {
        throw ZenohException('Failed to get matching status', rc);
      }
      return matching.value != 0;
    } finally {
      calloc.free(matching);
    }
  }

  /// A stream of matching status changes, or null if the matching listener
  /// was not enabled when the publisher was declared.
  /// ⚠️ **Unbounded, like every push stream here** — but this is an
  /// edge-signal channel, not a data channel: it carries transitions, not
  /// traffic, so there is deliberately no bounded form of it.
  ///
  Stream<bool>? get matchingStatus => _matchingController?.stream;

  /// Undeclares the publisher and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void close() {
    if (_closed) return;
    _closed = true;
    // Unconditional: detaching a key that was never attached (the `ml:ON`
    // path) is a no-op, and a branch here would be one more place for the two
    // configurations to drift apart.
    publisherFinalizer.detach(this);
    bindings.zd_publisher_drop(_ptr.cast());
    _matchingPort?.close();
    unawaited(_matchingController?.close());
    calloc.free(_ptr);
  }
}
