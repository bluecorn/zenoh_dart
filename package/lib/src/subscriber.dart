import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'exceptions.dart';
import 'native_lib.dart';
import 'sample.dart';

/// A zenoh subscriber that receives samples on a key expression.
///
/// Wraps `z_owned_subscriber_t`. Samples are delivered asynchronously
/// via a [Stream]. Call [close] when done to undeclare the subscriber
/// and release native resources.
class Subscriber {
  final Pointer<Void> _ptr;
  final ReceivePort _receivePort;
  final StreamController<Sample> _controller;
  bool _closed = false;

  Subscriber._(this._ptr, this._receivePort, this._controller);

  /// Sets up a [ReceivePort] and [StreamController] pair that parses
  /// incoming NativePort sample messages into [Sample] objects.
  ///
  /// Returns `(ReceivePort, StreamController<Sample>)`. The caller is
  /// responsible for passing `receivePort.sendPort.nativePort` to the
  /// C shim and for cleanup on failure.
  static (ReceivePort, StreamController<Sample>) createSampleChannel() {
    final receivePort = ReceivePort();
    final controller = StreamController<Sample>();

    receivePort.listen((dynamic message) {
      if (message == null) {
        receivePort.close();
        controller.close();
      } else if (message is List) {
        final keyExpr = message[0] as String;
        final payloadBytes = message[1] as Uint8List;
        final kind = message[2] as int;
        final attachmentBytes = message[3] as Uint8List?;
        final encoding = message.length > 4 ? message[4] as String? : null;

        final sample = Sample(
          keyExpr: keyExpr,
          payload: utf8.decode(payloadBytes, allowMalformed: true),
          payloadBytes: payloadBytes,
          kind: kind == 0 ? SampleKind.put : SampleKind.delete,
          attachment: attachmentBytes != null
              ? utf8.decode(attachmentBytes, allowMalformed: true)
              : null,
          encoding: encoding,
        );
        controller.add(sample);
      }
    });

    return (receivePort, controller);
  }

  /// Creates a Subscriber from a pre-allocated native handle and a
  /// sample channel pair.
  ///
  /// Used by [Session.declareLivelinessSubscriber] where the native
  /// subscriber is declared through a different C shim function but
  /// uses the same `z_owned_subscriber_t` type.
  factory Subscriber.fromParts(
    Pointer<Void> ptr,
    ReceivePort receivePort,
    StreamController<Sample> controller,
  ) {
    return Subscriber._(ptr, receivePort, controller);
  }

  /// Creates a subscriber on the given session and key expression.
  ///
  /// This is called internally by [Session.declareSubscriber].
  static Subscriber declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe,
  ) {
    final size = bindings.zd_subscriber_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final (receivePort, controller) = createSampleChannel();

    final rc = bindings.zd_declare_subscriber(
      loanedSession.cast(),
      ptr.cast(),
      loanedKe.cast(),
      receivePort.sendPort.nativePort,
    );

    if (rc != 0) {
      receivePort.close();
      controller.close();
      calloc.free(ptr);
      throw ZenohException('Failed to declare subscriber', rc);
    }

    return Subscriber._(ptr, receivePort, controller);
  }

  /// A stream of [Sample]s received by this subscriber.
  Stream<Sample> get stream => _controller.stream;

  /// Undeclares the subscriber and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_subscriber_drop(_ptr.cast());
    _receivePort.close();
    _controller.close();
    calloc.free(_ptr);
  }
}
