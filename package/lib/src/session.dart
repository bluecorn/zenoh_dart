import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'advanced_publisher.dart';
import 'advanced_subscriber.dart';
import 'bytes.dart';
import 'config.dart';
import 'congestion_control.dart';
import 'consolidation_mode.dart';
import 'encoding.dart';
import 'exceptions.dart';
import 'id.dart';
import 'keyexpr.dart';
import 'liveliness.dart';
import 'native_lib.dart';
import 'priority.dart';
import 'pull_subscriber.dart';
import 'publisher.dart';
import 'querier.dart';
import 'query_target.dart';
import 'queryable.dart';
import 'reply.dart';
import 'sample.dart';
import 'subscriber.dart';

/// A Zenoh session.
///
/// Wraps `z_owned_session_t`. Use [Session.open] to create a session,
/// optionally passing a [Config]. Call [close] when done to gracefully
/// shut down the session and release native resources.
class Session {
  final Pointer<Void> _ptr;
  bool _closed = false;

  Session._(this._ptr);

  /// Opens a Zenoh session.
  ///
  /// If [config] is provided, it is consumed by the session and must not
  /// be reused or disposed by the caller. If [config] is null, a default
  /// configuration is created internally.
  ///
  /// Throws [ZenohException] if the session cannot be opened.
  static Session open({Config? config}) {
    final size = bindings.zd_session_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    Config effectiveConfig;
    bool ownsConfig;
    if (config != null) {
      effectiveConfig = config;
      ownsConfig = false;
    } else {
      effectiveConfig = Config();
      ownsConfig = true;
    }

    final rc = bindings.zd_open_session(
      ptr.cast(),
      effectiveConfig.nativePtr.cast(),
    );

    // Mark user-provided config as consumed regardless of success/failure,
    // because z_config_move already consumed the native pointer.
    if (config != null) {
      config.markConsumed();
    }

    if (rc != 0) {
      calloc.free(ptr);
      if (ownsConfig) effectiveConfig.dispose();
      throw ZenohException('Failed to open session', rc);
    }

    return Session._(ptr);
  }

  /// Gracefully closes the session and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_close_session(_ptr.cast());
    calloc.free(_ptr);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Session has been closed');
  }

  /// Returns the [ZenohId] of this session.
  ///
  /// Throws [StateError] if the session has been closed.
  ZenohId get zid {
    _ensureOpen();
    final outId = calloc<Uint8>(16);
    try {
      final loanedSession = bindings.zd_session_loan(_ptr.cast());
      bindings.zd_info_zid(loanedSession, outId);
      return ZenohId(Uint8List.fromList(outId.asTypedList(16)));
    } finally {
      calloc.free(outId);
    }
  }

  /// Collects ZenohIds using a native info function that fills a buffer.
  List<ZenohId> _collectZids(
    int Function(Pointer<Opaque>, Pointer<Uint8>, int) nativeCall,
  ) {
    _ensureOpen();
    const maxCount = 64;
    final outIds = calloc<Uint8>(maxCount * 16);
    try {
      final loanedSession = bindings.zd_session_loan(_ptr.cast());
      final count = nativeCall(loanedSession, outIds, maxCount);
      final allBytes = outIds.asTypedList(count * 16);
      return [
        for (var i = 0; i < count; i++)
          ZenohId(Uint8List.fromList(allBytes.sublist(i * 16, (i + 1) * 16))),
      ];
    } finally {
      calloc.free(outIds);
    }
  }

  /// Returns the [ZenohId]s of all connected routers.
  ///
  /// May return an empty list if no router is connected (e.g., in peer mode).
  ///
  /// Throws [StateError] if the session has been closed.
  List<ZenohId> routersZid() => _collectZids(bindings.zd_info_routers_zid);

  /// Returns the [ZenohId]s of all connected peers.
  ///
  /// May return an empty list if no peer is connected.
  ///
  /// Throws [StateError] if the session has been closed.
  List<ZenohId> peersZid() => _collectZids(bindings.zd_info_peers_zid);

  /// Executes [action] with a loaned session and a loaned key expression,
  /// guaranteeing cleanup of the key expression in all cases.
  void _withKeyExpr(
    String keyExpr,
    void Function(Pointer<Void> loanedSession, Pointer<Void> loanedKe) action,
  ) {
    _ensureOpen();
    final ke = KeyExpr(keyExpr);
    try {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      final loanedKe =
          bindings.zd_view_keyexpr_loan(ke.nativePtr.cast()) as Pointer<Void>;
      action(loanedSession, loanedKe);
    } finally {
      ke.dispose();
    }
  }

  /// Publishes a string [value] on the given [keyExpr].
  ///
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is consumed by this call and must not
  /// be reused.
  ///
  /// Throws [ZenohException] if the key expression is invalid, the encoding
  /// is malformed, or the put fails.
  /// Throws [StateError] if the session has been closed, or the attachment
  /// has been disposed or already consumed.
  void put(
    String keyExpr,
    String value, {
    Encoding? encoding,
    ZBytes? attachment,
  }) {
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    final encodingStr = encoding != null
        ? encoding.mimeType.toNativeUtf8()
        : nullptr;
    _withKeyExpr(keyExpr, (loanedSession, loanedKe) {
      final payload = ZBytes.fromString(value);
      try {
        final rc = bindings.zd_put(
          loanedSession.cast(),
          loanedKe.cast(),
          payload.nativePtr.cast(),
          encodingStr.cast(),
          attachmentPtr.cast(),
        );
        // markConsumed is unconditional: z_bytes_move gravestones the owned
        // bytes regardless of the return code.
        payload.markConsumed();
        if (attachment != null) attachment.markConsumed();
        if (rc != 0) {
          throw ZenohException('Put failed', rc);
        }
      } finally {
        if (encodingStr != nullptr) malloc.free(encodingStr);
      }
    });
  }

  /// Publishes a [ZBytes] [payload] on the given [keyExpr].
  ///
  /// The payload is consumed by this call and must not be reused.
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is also consumed by this call.
  ///
  /// Throws [ZenohException] if the key expression is invalid, the encoding
  /// is malformed, or the put fails.
  /// Throws [StateError] if the session has been closed, or the payload or
  /// attachment has been disposed or already consumed.
  void putBytes(
    String keyExpr,
    ZBytes payload, {
    Encoding? encoding,
    ZBytes? attachment,
  }) {
    _ensureOpen();
    // Validate payload state before allocating KeyExpr
    final payloadPtr = payload.nativePtr;
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    final encodingStr = encoding != null
        ? encoding.mimeType.toNativeUtf8()
        : nullptr;
    _withKeyExpr(keyExpr, (loanedSession, loanedKe) {
      try {
        final rc = bindings.zd_put(
          loanedSession.cast(),
          loanedKe.cast(),
          payloadPtr.cast(),
          encodingStr.cast(),
          attachmentPtr.cast(),
        );
        // markConsumed is unconditional: z_bytes_move gravestones the owned
        // bytes regardless of the return code.
        payload.markConsumed();
        if (attachment != null) attachment.markConsumed();
        if (rc != 0) {
          throw ZenohException('Put failed', rc);
        }
      } finally {
        if (encodingStr != nullptr) malloc.free(encodingStr);
      }
    });
  }

  /// Deletes a resource on the given [keyExpr].
  ///
  /// Throws [ZenohException] if the key expression is invalid or the delete fails.
  /// Throws [StateError] if the session has been closed.
  void deleteResource(String keyExpr) {
    _withKeyExpr(keyExpr, (loanedSession, loanedKe) {
      final rc = bindings.zd_delete(loanedSession.cast(), loanedKe.cast());
      if (rc != 0) {
        throw ZenohException('Delete failed', rc);
      }
    });
  }

  /// Declares a publisher on the given [keyExpr].
  ///
  /// Returns a [Publisher] that can efficiently publish multiple messages
  /// to the same key expression. Call [Publisher.close] when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Publisher declarePublisher(
    String keyExpr, {
    Encoding? encoding,
    CongestionControl congestionControl = CongestionControl.block,
    Priority priority = Priority.data,
    bool isExpress = false,
    bool enableMatchingListener = false,
  }) {
    _ensureOpen();
    final ke = KeyExpr(keyExpr);
    try {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      final loanedKe =
          bindings.zd_view_keyexpr_loan(ke.nativePtr.cast()) as Pointer<Void>;
      return Publisher.declare(
        loanedSession,
        loanedKe,
        encoding: encoding,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
        enableMatchingListener: enableMatchingListener,
      );
    } finally {
      ke.dispose();
    }
  }

  /// Declares an advanced publisher on the given [keyExpr].
  ///
  /// Returns an [AdvancedPublisher] with optional cache, publisher detection,
  /// and sample miss detection capabilities. Call [AdvancedPublisher.close]
  /// when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  AdvancedPublisher declareAdvancedPublisher(
    String keyExpr, {
    AdvancedPublisherOptions? options,
  }) {
    _ensureOpen();
    final opts = options ?? const AdvancedPublisherOptions();
    final ke = KeyExpr(keyExpr);
    try {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      final loanedKe =
          bindings.zd_view_keyexpr_loan(ke.nativePtr.cast()) as Pointer<Void>;
      return AdvancedPublisher.declare(
        loanedSession,
        loanedKe,
        keyExpr,
        enableCache: opts.cacheMaxSamples != null,
        cacheMaxSamples: opts.cacheMaxSamples ?? 0,
        publisherDetection: opts.publisherDetection,
        sampleMissDetection: opts.sampleMissDetection,
        heartbeatMode: opts.heartbeatMode,
        heartbeatPeriodMs: opts.heartbeatPeriodMs,
      );
    } finally {
      ke.dispose();
    }
  }

  /// Declares an advanced subscriber on the given [keyExpr].
  ///
  /// Returns an [AdvancedSubscriber] with optional history recovery,
  /// late publisher detection, sample recovery, and miss detection
  /// capabilities. Call [AdvancedSubscriber.close] when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  AdvancedSubscriber declareAdvancedSubscriber(
    String keyExpr, {
    AdvancedSubscriberOptions options = const AdvancedSubscriberOptions(),
  }) {
    _ensureOpen();
    final ke = KeyExpr(keyExpr);
    try {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      final loanedKe =
          bindings.zd_view_keyexpr_loan(ke.nativePtr.cast()) as Pointer<Void>;
      return AdvancedSubscriber.declare(
        loanedSession,
        loanedKe,
        options: options,
      );
    } finally {
      ke.dispose();
    }
  }

  /// Declares a querier on the given [keyExpr].
  ///
  /// Returns a [Querier] that can efficiently send multiple queries
  /// to the same key expression with pre-configured options.
  /// Call [Querier.close] when done.
  ///
  /// [target] controls which queryables are targeted (default: bestMatching).
  /// [consolidation] controls reply consolidation (default: auto).
  /// [timeout] sets the query timeout (default: 10 seconds).
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Querier declareQuerier(
    String keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    bool enableMatchingListener = false,
  }) {
    _ensureOpen();
    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    return Querier.declare(
      loanedSession,
      keyExpr,
      target: target,
      consolidation: consolidation,
      timeout: timeout,
      enableMatchingListener: enableMatchingListener,
    );
  }

  /// Declares a background subscriber on the given [keyExpr].
  ///
  /// Returns a [Stream] of [Sample]s. Unlike [declareSubscriber], the
  /// background subscriber has no handle and cannot be explicitly closed.
  /// It lives until the session is closed, at which point the stream
  /// completes automatically.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Stream<Sample> declareBackgroundSubscriber(String keyExpr) {
    _ensureOpen();
    final (receivePort, controller) = Subscriber.createSampleChannel();
    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_declare_background_subscriber(
        loanedSession.cast(),
        keyExprNative.cast(),
        receivePort.sendPort.nativePort,
      );

      if (rc != 0) {
        receivePort.close();
        controller.close();
        throw ZenohException('Failed to declare background subscriber', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return controller.stream;
  }

  /// Declares a subscriber on the given [keyExpr].
  ///
  /// Returns a [Subscriber] whose [Subscriber.stream] delivers [Sample]s.
  /// Call [Subscriber.close] when done to undeclare and release resources.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Subscriber declareSubscriber(String keyExpr) {
    _ensureOpen();
    final ke = KeyExpr(keyExpr);
    try {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      final loanedKe =
          bindings.zd_view_keyexpr_loan(ke.nativePtr.cast()) as Pointer<Void>;
      return Subscriber.declare(loanedSession, loanedKe);
    } finally {
      ke.dispose();
    }
  }

  /// Declares a pull subscriber on the given [keyExpr].
  ///
  /// Returns a [PullSubscriber] that buffers samples in a ring channel of
  /// the given [capacity]. Use [PullSubscriber.tryRecv] to poll for samples.
  /// Call [PullSubscriber.close] when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  PullSubscriber declarePullSubscriber(String keyExpr, {int capacity = 256}) {
    _ensureOpen();

    final subscriberSize = bindings.zd_subscriber_sizeof();
    final handlerSize = bindings.zd_ring_handler_sample_sizeof();
    final subscriberHandle = calloc<Uint8>(subscriberSize);
    final handlerHandle = calloc<Uint8>(handlerSize);

    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_declare_pull_subscriber(
        subscriberHandle,
        handlerHandle,
        loanedSession.cast(),
        keyExprNative.cast(),
        capacity,
      );

      if (rc != 0) {
        calloc.free(subscriberHandle);
        calloc.free(handlerHandle);
        throw ZenohException('Failed to declare pull subscriber', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return PullSubscriber(subscriberHandle, handlerHandle, keyExpr);
  }

  /// Declares a queryable on the given [keyExpr].
  ///
  /// Returns a [Queryable] whose [Queryable.stream] delivers [Query]s.
  /// Call [Queryable.close] when done to undeclare and release resources.
  ///
  /// The [complete] parameter indicates whether this queryable is a
  /// complete source of data for its key expression (default: false).
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Queryable declareQueryable(String keyExpr, {bool complete = false}) {
    _ensureOpen();
    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    return Queryable.declare(loanedSession, keyExpr, complete: complete);
  }

  /// Declares a liveliness subscriber on the given [keyExpr].
  ///
  /// Returns a [Subscriber] whose [Subscriber.stream] delivers [Sample]s
  /// with [SampleKind.put] when a liveliness token is declared and
  /// [SampleKind.delete] when a token is undeclared.
  ///
  /// If [history] is true, the subscriber will also receive notifications
  /// for liveliness tokens that were declared before the subscription.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Subscriber declareLivelinessSubscriber(
    String keyExpr, {
    bool history = false,
  }) {
    _ensureOpen();

    final size = bindings.zd_subscriber_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final (receivePort, controller) = Subscriber.createSampleChannel();

    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_liveliness_declare_subscriber(
        ptr.cast(),
        loanedSession.cast(),
        keyExprNative.cast(),
        receivePort.sendPort.nativePort,
        history ? 1 : 0,
      );

      if (rc != 0) {
        receivePort.close();
        controller.close();
        calloc.free(ptr);
        throw ZenohException('Failed to declare liveliness subscriber', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return Subscriber.fromParts(ptr, receivePort, controller);
  }

  /// Declares a liveliness token on the given [keyExpr].
  ///
  /// The token advertises this session's presence on the key expression
  /// for as long as it remains undeclared. Call [LivelinessToken.close]
  /// when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  LivelinessToken declareLivelinessToken(String keyExpr) {
    _ensureOpen();
    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    return LivelinessToken.declare(loanedSession, keyExpr);
  }

  /// Queries liveliness tokens matching the given [keyExpr].
  ///
  /// Returns a [Stream] of [Reply] objects for each alive token. The stream
  /// completes when all replies have been received or the [timeout] expires.
  /// Defaults to 10 seconds if [timeout] is not specified.
  ///
  /// Throws [ZenohException] if the key expression is invalid or the query
  /// fails.
  /// Throws [StateError] if the session has been closed.
  Stream<Reply> livelinessGet(String keyExpr, {Duration? timeout}) {
    _ensureOpen();

    final (receivePort, controller) = _createReplyChannel();
    final timeoutMs = (timeout ?? const Duration(seconds: 10)).inMilliseconds;

    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_liveliness_get(
        loanedSession.cast(),
        keyExprNative.cast(),
        receivePort.sendPort.nativePort,
        timeoutMs,
      );

      if (rc != 0) {
        receivePort.close();
        controller.close();
        throw ZenohException('Liveliness get failed', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return controller.stream;
  }

  /// Sends a query on the given [selector] and returns a stream of replies.
  ///
  /// The returned stream completes when all replies have been received
  /// or the timeout expires. The [timeout] defaults to 10 seconds.
  ///
  /// Optional [parameters] are appended to the query selector.
  /// Optional [payload], [encoding], and [attachment] attach data to the query.
  /// [target] controls which queryables are targeted (default: bestMatching).
  /// [consolidation] controls reply consolidation (default: auto).
  ///
  /// Throws [StateError] if the session has been closed.
  Stream<Reply> get(
    String selector, {
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
  }) {
    _ensureOpen();

    // Validate the selector keyexpr in Dart BEFORE any z_bytes_move. zd_get's
    // own z_view_keyexpr_from_str is a pre-move early-return (-1), but the
    // Dart caller cannot distinguish that rc from a post-move failure -- so we
    // validate here to keep the markConsumed discipline correct: a genuine
    // pre-move early-return throws here and does NOT mark payload/attachment
    // consumed (the caller retains ownership), mirroring put/putBytes.
    KeyExpr(selector).dispose();

    final (receivePort, controller) = _createReplyChannel();
    final timeoutMs = (timeout ?? const Duration(seconds: 10)).inMilliseconds;

    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;

    final selectorNative = selector.toNativeUtf8();
    Pointer<Utf8> parametersNative = nullptr;
    Pointer<Utf8> encodingNative = nullptr;

    if (parameters != null) {
      parametersNative = parameters.toNativeUtf8();
    }
    if (encoding != null) {
      encodingNative = encoding.mimeType.toNativeUtf8();
    }

    try {
      final rc = bindings.zd_get(
        loanedSession.cast(),
        selectorNative.cast(),
        receivePort.sendPort.nativePort,
        target.index,
        consolidation.value,
        payload != null ? payload.nativePtr.cast() : nullptr,
        encoding != null ? encodingNative.cast() : nullptr,
        timeoutMs,
        parameters != null ? parametersNative.cast() : nullptr,
        attachment != null ? attachment.nativePtr.cast() : nullptr,
      );

      // Mark payload + attachment ZBytes as consumed UNCONDITIONALLY:
      // zd_get moves them into zenoh-c regardless of the return code (and
      // its encoding-error early-return drops the already-moved bytes), so
      // the caller must not touch them after this call -- even on error.
      // Marking before the rc-throw prevents a later use-after-move.
      if (payload != null) {
        payload.markConsumed();
      }
      if (attachment != null) {
        attachment.markConsumed();
      }

      if (rc != 0) {
        receivePort.close();
        controller.close();
        throw ZenohException('Get query failed', rc);
      }
    } finally {
      calloc.free(selectorNative);
      if (parameters != null) calloc.free(parametersNative);
      if (encoding != null) calloc.free(encodingNative);
    }

    return controller.stream;
  }

  /// Creates a [ReceivePort] and [StreamController] wired for reply parsing.
  ///
  /// The returned [ReceivePort] listens for NativePort messages from the C
  /// shim reply callback. Ok replies (tag=1) and error replies (tag=0) are
  /// forwarded to the [StreamController]. A null sentinel closes both.
  static (ReceivePort, StreamController<Reply>) _createReplyChannel() {
    final controller = StreamController<Reply>();
    final receivePort = ReceivePort();

    receivePort.listen((dynamic message) {
      if (message == null) {
        receivePort.close();
        controller.close();
      } else if (message is List) {
        final tag = message[0] as int;
        if (tag == 1) {
          final keyExpr = message[1] as String;
          final payloadBytes = message[2] as Uint8List;
          final kind = message[3] as int;
          final attachmentBytes = message[4] as Uint8List?;
          final encodingStr = message.length > 5 ? message[5] as String? : null;

          final sample = Sample(
            keyExpr: keyExpr,
            payload: utf8.decode(payloadBytes, allowMalformed: true),
            payloadBytes: payloadBytes,
            kind: kind == 0 ? SampleKind.put : SampleKind.delete,
            attachment: attachmentBytes != null
                ? utf8.decode(attachmentBytes, allowMalformed: true)
                : null,
            attachmentBytes: attachmentBytes,
            encoding: encodingStr,
          );
          controller.add(Reply.ok(sample));
        } else if (tag == 0) {
          final errorPayloadBytes = message[1] as Uint8List;
          final errorEncoding = message.length > 2
              ? message[2] as String?
              : null;

          final replyError = ReplyError(
            payloadBytes: errorPayloadBytes,
            payload: utf8.decode(errorPayloadBytes, allowMalformed: true),
            encoding: errorEncoding,
          );
          controller.add(Reply.error(replyError));
        }
      }
    });

    return (receivePort, controller);
  }
}
