import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'exceptions.dart';
import 'native_lib.dart';
import 'query.dart';

/// A zenoh queryable that receives queries on a key expression.
///
/// Wraps `z_owned_queryable_t`. Queries are delivered asynchronously
/// via a [Stream]. Call [close] when done to undeclare the queryable
/// and release native resources.
class Queryable {
  final Pointer<Void> _ptr;
  final ReceivePort _receivePort;
  final StreamController<Query> _controller;
  final String _keyExpr;
  bool _closed = false;

  Queryable._(this._ptr, this._receivePort, this._controller, this._keyExpr);

  /// Creates a queryable on the given session and key expression.
  ///
  /// This is called internally by [Session.declareQueryable].
  static Queryable declare(
    Pointer<Void> loanedSession,
    String keyExprStr, {
    bool complete = false,
  }) {
    final size = bindings.zd_queryable_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final receivePort = ReceivePort();
    final controller = StreamController<Query>();

    receivePort.listen((dynamic message) {
      if (message is List) {
        final queryPtr = message[0] as int;
        final keyExpr = message[1] as String;
        final params = message[2] as String;
        final payloadBytes = message[3] as Uint8List?;
        final attachmentBytes = message[4] as Uint8List?;

        final query = Query(
          handle: queryPtr,
          keyExpr: keyExpr,
          parameters: params,
          payloadBytes: payloadBytes,
          attachmentBytes: attachmentBytes,
        );
        controller.add(query);
      }
    });

    final keyExprNative = keyExprStr.toNativeUtf8();
    try {
      final rc = bindings.zd_declare_queryable(
        ptr.cast(),
        loanedSession.cast(),
        keyExprNative.cast(),
        receivePort.sendPort.nativePort,
        complete ? 1 : 0,
      );

      if (rc != 0) {
        receivePort.close();
        controller.close();
        calloc.free(ptr);
        throw ZenohException('Failed to declare queryable', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return Queryable._(ptr, receivePort, controller, keyExprStr);
  }

  /// A stream of [Query]s received by this queryable.
  Stream<Query> get stream => _controller.stream;

  /// The key expression this queryable is declared on.
  String get keyExpr => _keyExpr;

  /// Undeclares the queryable and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_queryable_drop(_ptr.cast());
    _receivePort.close();
    _controller.close();
    calloc.free(_ptr);
  }
}
