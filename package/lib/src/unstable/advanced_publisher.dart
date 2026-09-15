import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/native_string.dart';

/// Heartbeat mode for advanced publisher sample miss detection.
enum HeartbeatMode {
  /// Disable heartbeat-based last sample miss detection.
  none(0),

  /// Allow last sample miss detection through periodic heartbeat.
  periodic(1),

  /// Allow last sample miss detection through sporadic heartbeat.
  sporadic(2);

  const HeartbeatMode(this.value);

  /// The integer value matching the zenoh-c enum.
  final int value;
}

/// Options for the advanced publisher's sample cache.
///
/// The *presence* of this object on [AdvancedPublisherOptions.cache] enables
/// the cache; this object carries only the bound. Splitting the two axes is
/// deliberate — a single nullable integer had to mean both "no cache" and
/// "canon decides the bound", and that conflation is what made the value `0`
/// misreadable.
///
/// Canon models the same thing as a struct
/// (`ze_advanced_publisher_cache_options_t`), of which this binds
/// `max_samples`; its `congestion_control`, `priority` and `is_express` are
/// deliberately not bound.
class AdvancedPublisherCacheOptions {
  /// Creates cache options.
  const AdvancedPublisherCacheOptions({this.maxSamples});

  /// The number of samples the cache keeps per resource.
  ///
  /// `null` means **canon decides** — canon's own default
  /// (`ze_advanced_publisher_cache_options_default`) is left untouched.
  ///
  /// There is no unlimited setting, and in particular **`0` is not one**.
  /// Measured against zenoh-c 1.8.0: with an explicit `0`, a late-joining
  /// history subscriber recovers exactly **one** of five pre-join samples —
  /// identical to leaving the field unspecified, because canon's default is
  /// `1`. Zero remains expressible and is passed through verbatim rather than
  /// rejected or swallowed. (Canon *does* document `0` as "no limit" on the
  /// *subscriber*'s history bound, which is a different field on the other
  /// side of the contract.)
  ///
  /// Must be `>= 0`; a negative value throws [ArgumentError] before any
  /// native call.
  final int? maxSamples;
}

/// Options for configuring an advanced publisher.
///
/// All fields are optional. Caching is enabled by supplying a [cache] object;
/// see [AdvancedPublisherCacheOptions] for the bound and for what `0` does
/// and does not mean.
class AdvancedPublisherOptions {
  /// Creates advanced publisher options.
  const AdvancedPublisherOptions({
    this.cache,
    this.enableMatchingListener = false,
    this.publisherDetection = false,
    this.sampleMissDetection = false,
    this.heartbeatMode = HeartbeatMode.none,
    this.heartbeatPeriodMs = 0,
  });

  /// The publisher-side sample cache, or `null` for no cache.
  ///
  /// Presence enables the cache; the object carries the bound. The invalid
  /// combination — a bound with no cache — is unrepresentable.
  final AdvancedPublisherCacheOptions? cache;

  /// Whether to declare a background matching listener, which makes
  /// [AdvancedPublisher.matchingStatus] non-null.
  ///
  /// A bare `bool` rather than an options object because canon's matching
  /// listener takes no options at all — there is no struct for a presence to
  /// stand in for. (Where canon *does* model a thing with an options struct,
  /// as with the subscriber's publisher detection, this binding carries the
  /// enable axis as the presence of that object instead.)
  final bool enableMatchingListener;

  /// Whether to enable publisher detection.
  final bool publisherDetection;

  /// Whether to enable sample miss detection.
  final bool sampleMissDetection;

  /// The heartbeat mode for sample miss detection.
  final HeartbeatMode heartbeatMode;

  /// The heartbeat period in milliseconds (used with periodic/sporadic modes).
  final int heartbeatPeriodMs;
}

/// A zenoh advanced publisher with cache, publisher detection,
/// and sample miss detection capabilities.
///
/// Wraps `ze_owned_advanced_publisher_t`. Call [close] when done to
/// undeclare the publisher and release native resources.
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
class AdvancedPublisher implements Finalizable {
  /// Creates an advanced publisher on the given session and key expression.
  ///
  /// This is called internally by `Session.declareAdvancedPublisher`.
  factory AdvancedPublisher.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe,
    String keyExpr, {
    bool enableCache = false,
    int? cacheMaxSamples,
    bool publisherDetection = false,
    bool sampleMissDetection = false,
    HeartbeatMode heartbeatMode = HeartbeatMode.none,
    int heartbeatPeriodMs = 0,
    bool enableMatchingListener = false,
  }) {
    // ALLOCATE-LAST: the domain check runs before anything is allocated.
    // `Session.declareAdvancedPublisher` rejects a negative bound earlier
    // still, before the key expression is even loaned; this is the second
    // Dart-side gate, and the shim's ZD_DECLARE_ECAPACITY is the structural
    // backstop at the seam itself.
    if (cacheMaxSamples != null && cacheMaxSamples < 0) {
      throw ArgumentError.value(
        cacheMaxSamples,
        'maxSamples',
        "must be >= 0; null leaves canon's own default in place",
      );
    }

    final size = bindings.zd_advanced_publisher_sizeof();
    final ptr = calloc.allocate<Void>(size);

    final rc = bindings.zd_declare_advanced_publisher(
      loanedSession.cast(),
      ptr.cast(),
      loanedKe.cast(),
      enableCache,
      // -1 is the shim's "unspecified" sentinel: canon's default is left
      // untouched. Every value >= 0 is assigned verbatim, zero included.
      cacheMaxSamples ?? -1,
      publisherDetection,
      sampleMissDetection,
      heartbeatMode.value,
      heartbeatPeriodMs,
    );

    if (rc != 0) {
      calloc.free(ptr);
      throw ZenohException('Failed to declare advanced publisher', rc);
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

      final loaned = bindings.zd_advanced_publisher_loan(ptr.cast());
      final mlRc = bindings
          .zd_advanced_publisher_declare_background_matching_listener(
            loaned,
            matchingPort.sendPort.nativePort,
          );

      if (mlRc != 0) {
        // The shipped second-listener teardown template: nothing declared
        // survives the failure, and the throw comes last.
        matchingPort.close();
        unawaited(matchingController.close());
        bindings.zd_advanced_publisher_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare matching listener', mlRc);
      }
    }

    return AdvancedPublisher._(ptr, keyExpr, matchingPort, matchingController);
  }

  AdvancedPublisher._(
    this._ptr,
    this._keyExpr,
    this._matchingPort,
    this._matchingController,
  ) {
    // ⛔ THE NET IS CONDITIONAL AND THE MARKER IS NOT. A matching listener
    // means this object holds a `ReceivePort`, and canon's drop callback for
    // it POSTS to a Dart port -- which from a `NativeFinalizer` callback is
    // documented undefined behaviour ("not allowed to re-enter the Dart VM via
    // Dart C APIs"). So the `ml:ON` configuration keeps today's
    // leak-on-forget, deliberately.
    //
    // ⚠️ Criterion (ii) for the `ml:off` configuration is MEASURED, not read:
    // 0 posts under `zd_advanced_publisher_drop` in BOTH the
    // one-session and TCP-loopback topologies. Reading it is what cost
    // `Querier` and `Query` their admission to this net.
    if (_matchingPort == null) {
      advancedPublisherFinalizer.attach(
        this,
        _ptr.cast(),
        detach: this,
        externalSize: bindings.zd_advanced_publisher_sizeof(),
      );
    }
  }

  final Pointer<Void> _ptr;
  final String _keyExpr;
  final ReceivePort? _matchingPort;
  final StreamController<bool>? _matchingController;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw StateError('AdvancedPublisher has been closed');
  }

  /// The key expression this advanced publisher is declared on.
  String get keyExpr {
    _ensureOpen();
    return _keyExpr;
  }

  /// Returns whether any subscribers currently match this advanced
  /// publisher's key expression.
  ///
  /// Canon's own semantics: true from the moment the first matching
  /// subscriber connects until the last one disconnects.
  ///
  /// Throws [StateError] if this publisher has been closed, and
  /// [ZenohException] carrying canon's code if the query itself fails.
  bool hasMatchingSubscribers() {
    _ensureOpen();
    final loaned = bindings.zd_advanced_publisher_loan(_ptr.cast());
    // ALLOCATE-LAST: the guard and the loan both precede the allocation, and
    // the finally below encloses every statement that can throw.
    final matching = calloc<Int>();
    try {
      final rc = bindings.zd_advanced_publisher_get_matching_status(
        loaned,
        matching,
      );
      if (rc != 0) {
        throw ZenohException('Failed to get matching status', rc);
      }
      return matching.value != 0;
    } finally {
      calloc.free(matching);
    }
  }

  /// A stream of matching-status changes, or `null` if
  /// [AdvancedPublisherOptions.enableMatchingListener] was not set when this
  /// publisher was declared.
  ///
  /// Emits `true` when the first matching subscriber connects and `false` when
  /// the last one disconnects — canon's own wording is *"if last subscriber
  /// disconnects or when the first subscriber connects"*.
  ///
  /// **Lifetime.** Canon binds this listener to the **publisher**: it runs
  /// until the corresponding advanced publisher is dropped. The stream
  /// therefore completes when [close] is called. Its behaviour when the
  /// *session* is closed with this publisher still open is not part of this
  /// contract; the same is true of `AdvancedSubscriber.missEvents`.
  /// (Contrast `AdvancedSubscriber.detectedPublishers`, whose listener canon
  /// binds to the session instead.)
  Stream<bool>? get matchingStatus => _matchingController?.stream;

  /// Publishes a string [value] through this advanced publisher.
  ///
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is consumed by this call and must not
  /// be reused.
  ///
  /// Throws [ZenohException] if the encoding is malformed or the put fails.
  void put(String value, {Encoding? encoding, ZBytes? attachment}) {
    _ensureOpen();
    final loaned = bindings.zd_advanced_publisher_loan(_ptr.cast());
    // The payload is passed as a factory, not a value: _put validates the
    // attachment handle first and only then builds it. Building it here meant
    // a disposed attachment's StateError stranded a payload nothing else held
    // a reference to.
    _put(loaned.cast(), () => ZBytes.fromString(value), encoding, attachment);
  }

  /// Publishes [ZBytes] [payload] through this advanced publisher.
  ///
  /// The payload is consumed by this call and must not be reused.
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is also consumed by this call.
  ///
  /// Throws [ZenohException] if the encoding is malformed or the put fails.
  void putBytes(ZBytes payload, {Encoding? encoding, ZBytes? attachment}) {
    _ensureOpen();
    final loaned = bindings.zd_advanced_publisher_loan(_ptr.cast());
    _put(loaned.cast(), () => payload, encoding, attachment);
  }

  void _put(
    Pointer<Void> loaned,
    ZBytes Function() payloadFactory,
    Encoding? encoding,
    ZBytes? attachment,
  ) {
    // ALLOCATE-LAST: validate the attachment handle before anything is built
    // or allocated.
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    // Two INDEPENDENT length-carried channels (R-2), from the RAW pair (R-3a).
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);
    try {
      // Built inside the try, so the finally covers it and nothing between
      // here and the FFI call can throw.
      final payload = payloadFactory();
      final rc = bindings.zd_advanced_publisher_put(
        loaned.cast(),
        payload.nativePtr.cast(),
        encodingBuf.ptr,
        encodingBuf.len,
        schemaBuf.ptr,
        schemaBuf.len,
        attachmentPtr.cast(),
      );
      // markConsumed is unconditional: z_bytes_move gravestones the owned
      // bytes regardless of the return code.
      payload.markConsumed();
      if (attachment != null) attachment.markConsumed();
      if (rc != 0) {
        throw ZenohException('AdvancedPublisher put failed', rc);
      }
    } finally {
      // allocLengthCarriedUtf8 uses calloc, so the release is calloc.free.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
    }
  }

  /// Sends a DELETE through this advanced publisher.
  void deleteResource() {
    _ensureOpen();
    final loaned = bindings.zd_advanced_publisher_loan(_ptr.cast());
    final rc = bindings.zd_advanced_publisher_delete(loaned);
    if (rc != 0) {
      throw ZenohException('AdvancedPublisher delete failed', rc);
    }
  }

  /// Undeclares the advanced publisher and releases native resources.
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
    advancedPublisherFinalizer.detach(this);
    bindings.zd_advanced_publisher_drop(_ptr.cast());
    _matchingPort?.close();
    unawaited(_matchingController?.close());
    calloc.free(_ptr);
  }
}
