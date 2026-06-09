import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bytes.dart';
import 'consolidation_mode.dart';
import 'encoding.dart';
import 'exceptions.dart';
import 'native_lib.dart';
import 'query_target.dart';
import 'reply.dart';
import 'sample.dart';

/// A zenoh querier for efficiently sending multiple queries on a single
/// key expression with pre-configured options.
///
/// Wraps `z_owned_querier_t`. Call [close] when done to undeclare the
/// querier and release native resources.
class Querier {
  final Pointer<Void> _ptr;
  final String _keyExpr;
  bool _closed = false;
  final ReceivePort? _matchingPort;
  final StreamController<bool>? _matchingController;

  Querier._(
    this._ptr,
    this._keyExpr,
    this._matchingPort,
    this._matchingController,
  );

  /// Creates a querier on the given session and key expression.
  ///
  /// This is called internally by [Session.declareQuerier].
  static Querier declare(
    Pointer<Void> loanedSession,
    String keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    bool enableMatchingListener = false,
  }) {
    final size = bindings.zd_querier_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_declare_querier(
        ptr.cast(),
        loanedSession.cast(),
        keyExprNative.cast(),
        target.index,
        consolidation.value,
        timeout != null ? timeout.inMilliseconds : 0,
      );

      if (rc != 0) {
        calloc.free(ptr);
        throw ZenohException('Failed to declare querier', rc);
      }
    } finally {
      calloc.free(keyExprNative);
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

      final mlRc = bindings.zd_querier_declare_background_matching_listener(
        ptr.cast(),
        matchingPort.sendPort.nativePort,
      );

      if (mlRc != 0) {
        matchingPort.close();
        matchingController.close();
        bindings.zd_querier_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare matching listener', mlRc);
      }
    }

    return Querier._(ptr, keyExpr, matchingPort, matchingController);
  }

  /// The key expression this querier is declared on.
  String get keyExpr {
    if (_closed) throw StateError('Querier has been closed');
    return _keyExpr;
  }

  /// Sends a query via this querier and returns a stream of replies.
  ///
  /// Optional [parameters] are passed as query parameters.
  /// Optional [payload] is consumed (ownership transferred to zenoh-c).
  /// Optional [encoding] specifies the payload encoding.
  /// Optional [attachment] is consumed (ownership transferred to zenoh-c).
  ///
  /// [payload], [encoding], and [attachment] are per-query options (they vary
  /// per [get] call), unlike the declaration-time options (target,
  /// consolidation, timeout) fixed at [Session.declareQuerier].
  ///
  /// Throws [StateError] if the querier has been closed.
  Stream<Reply> get({
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,
  }) {
    if (_closed) throw StateError('Querier is closed');

    final controller = StreamController<Reply>();
    final receivePort = ReceivePort();

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Null sentinel: query complete
        receivePort.close();
        controller.close();
      } else if (message is List) {
        final tag = message[0] as int;
        if (tag == 1) {
          // Ok reply: [1, keyexpr, payload_bytes, kind, attachment, encoding]
          final keyExprStr = message[1] as String;
          final payloadBytes = message[2] as Uint8List;
          final kind = message[3] as int;
          final attachmentBytes = message[4] as Uint8List?;
          final encodingStr = message.length > 5 ? message[5] as String? : null;

          final sample = Sample(
            keyExpr: keyExprStr,
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
          // Error reply: [0, error_payload_bytes, error_encoding]
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

    Pointer<Utf8> parametersNative = nullptr;
    Pointer<Utf8> encodingNative = nullptr;

    if (parameters != null) {
      parametersNative = parameters.toNativeUtf8();
    }
    if (encoding != null) {
      encodingNative = encoding.mimeType.toNativeUtf8();
    }

    try {
      final rc = bindings.zd_querier_get(
        _ptr.cast(),
        parameters != null ? parametersNative.cast() : nullptr,
        receivePort.sendPort.nativePort,
        payload != null ? payload.nativePtr.cast() : nullptr,
        encoding != null ? encodingNative.cast() : nullptr,
        attachment != null ? attachment.nativePtr.cast() : nullptr,
      );

      // Mark payload + attachment ZBytes as consumed UNCONDITIONALLY:
      // zd_querier_get moves them into zenoh-c regardless of the return code
      // (and its encoding-error early-return drops the already-moved bytes),
      // so the caller must not touch them after this call -- even on error.
      // Marking before the rc-throw prevents a later use-after-move.
      // (Querier.get has no per-get selector to pre-validate: the keyexpr was
      // validated at declaration, so every reachable error path here is
      // post-move.)
      if (payload != null) {
        payload.markConsumed();
      }
      if (attachment != null) {
        attachment.markConsumed();
      }

      if (rc != 0) {
        receivePort.close();
        controller.close();
        throw ZenohException('Querier get failed', rc);
      }
    } finally {
      if (parameters != null) calloc.free(parametersNative);
      if (encoding != null) calloc.free(encodingNative);
    }

    return controller.stream;
  }

  /// Returns whether any queryables currently match this querier's
  /// key expression.
  bool hasMatchingQueryables() {
    if (_closed) throw StateError('Querier has been closed');
    final Pointer<Int8> matching = calloc<Int8>();
    try {
      final rc = bindings.zd_querier_get_matching_status(_ptr.cast(), matching);
      if (rc != 0) {
        throw ZenohException('Failed to get matching status', rc);
      }
      return matching.value != 0;
    } finally {
      calloc.free(matching);
    }
  }

  /// A stream of matching status changes, or null if the matching listener
  /// was not enabled when the querier was declared.
  Stream<bool>? get matchingStatus => _matchingController?.stream;

  /// Undeclares the querier and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_querier_drop(_ptr.cast());
    _matchingPort?.close();
    _matchingController?.close();
    calloc.free(_ptr);
  }
}
