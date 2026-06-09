import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bytes.dart';
import 'encoding.dart';
import 'exceptions.dart';
import 'native_lib.dart';

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

/// Options for configuring an advanced publisher.
///
/// All fields are optional. When [cacheMaxSamples] is non-null, caching is
/// enabled with the given maximum sample count (0 means unlimited).
class AdvancedPublisherOptions {
  /// Maximum number of samples to cache. If non-null, caching is enabled.
  /// A value of 0 means unlimited cache.
  final int? cacheMaxSamples;

  /// Whether to enable publisher detection.
  final bool publisherDetection;

  /// Whether to enable sample miss detection.
  final bool sampleMissDetection;

  /// The heartbeat mode for sample miss detection.
  final HeartbeatMode heartbeatMode;

  /// The heartbeat period in milliseconds (used with periodic/sporadic modes).
  final int heartbeatPeriodMs;

  /// Creates advanced publisher options.
  const AdvancedPublisherOptions({
    this.cacheMaxSamples,
    this.publisherDetection = false,
    this.sampleMissDetection = false,
    this.heartbeatMode = HeartbeatMode.none,
    this.heartbeatPeriodMs = 0,
  });
}

/// A zenoh advanced publisher with cache, publisher detection,
/// and sample miss detection capabilities.
///
/// Wraps `ze_owned_advanced_publisher_t`. Call [close] when done to
/// undeclare the publisher and release native resources.
class AdvancedPublisher {
  final Pointer<Void> _ptr;
  final String _keyExpr;
  bool _closed = false;

  AdvancedPublisher._(this._ptr, this._keyExpr);

  /// Creates an advanced publisher on the given session and key expression.
  ///
  /// This is called internally by [Session.declareAdvancedPublisher].
  static AdvancedPublisher declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe,
    String keyExpr, {
    bool enableCache = false,
    int cacheMaxSamples = 0,
    bool publisherDetection = false,
    bool sampleMissDetection = false,
    HeartbeatMode heartbeatMode = HeartbeatMode.none,
    int heartbeatPeriodMs = 0,
  }) {
    final size = bindings.zd_advanced_publisher_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final rc = bindings.zd_declare_advanced_publisher(
      loanedSession.cast(),
      ptr.cast(),
      loanedKe.cast(),
      enableCache,
      cacheMaxSamples,
      publisherDetection,
      sampleMissDetection,
      heartbeatMode.value,
      heartbeatPeriodMs,
    );

    if (rc != 0) {
      calloc.free(ptr);
      throw ZenohException('Failed to declare advanced publisher', rc);
    }

    return AdvancedPublisher._(ptr, keyExpr);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('AdvancedPublisher has been closed');
  }

  /// The key expression this advanced publisher is declared on.
  String get keyExpr {
    _ensureOpen();
    return _keyExpr;
  }

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
    final payload = ZBytes.fromString(value);
    _put(loaned.cast(), payload, encoding, attachment);
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
    _put(loaned.cast(), payload, encoding, attachment);
  }

  void _put(
    Pointer<Void> loaned,
    ZBytes payload,
    Encoding? encoding,
    ZBytes? attachment,
  ) {
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    final encodingStr = encoding != null
        ? encoding.mimeType.toNativeUtf8()
        : nullptr;
    try {
      final rc = bindings.zd_advanced_publisher_put(
        loaned.cast(),
        payload.nativePtr.cast(),
        encodingStr.cast(),
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
      if (encodingStr != nullptr) malloc.free(encodingStr);
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
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_advanced_publisher_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
