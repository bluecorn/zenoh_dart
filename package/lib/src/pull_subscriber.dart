import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_lib.dart';
import 'sample.dart';

/// A zenoh pull subscriber that receives samples via a ring buffer.
///
/// Unlike [Subscriber] which delivers samples asynchronously via a stream,
/// PullSubscriber buffers samples in a ring channel and delivers them
/// on-demand via [tryRecv].
///
/// Call [close] when done to undeclare the subscriber and release
/// native resources.
class PullSubscriber {
  final Pointer<Uint8> _subscriberHandle;
  final Pointer<Uint8> _handlerHandle;
  final String _keyExpr;
  bool _closed = false;

  /// Internal constructor. Use [Session.declarePullSubscriber] instead.
  PullSubscriber(this._subscriberHandle, this._handlerHandle, this._keyExpr);

  /// The key expression this pull subscriber is declared on.
  String get keyExpr => _keyExpr;

  /// Tries to receive a sample from the ring buffer.
  ///
  /// Returns a [Sample] if one is available, or `null` if the buffer is
  /// empty or the channel has been disconnected.
  ///
  /// Throws [StateError] if the subscriber has been closed.
  Sample? tryRecv() {
    if (_closed) throw StateError('PullSubscriber is closed');

    final outKeyexpr = calloc<Pointer<Char>>();
    final outPayload = calloc<Pointer<Uint8>>();
    final outPayloadLen = calloc<Int32>();
    final outKind = calloc<Int8>();
    final outEncoding = calloc<Pointer<Char>>();
    final outAttachment = calloc<Pointer<Uint8>>();
    final outAttachmentLen = calloc<Int32>();

    try {
      final rc = bindings.zd_pull_subscriber_try_recv(
        _handlerHandle,
        outKeyexpr.cast(),
        outPayload.cast(),
        outPayloadLen,
        outKind,
        outEncoding.cast(),
        outAttachment.cast(),
        outAttachmentLen,
      );

      if (rc != 0) {
        // 1 = disconnected, 2 = empty — both return null
        return null;
      }

      // Extract fields from malloc'd pointers
      final keyExprPtr = outKeyexpr.value;
      final keyExprStr = keyExprPtr.cast<Utf8>().toDartString();

      final payloadLen = outPayloadLen.value;
      final payloadPtr = outPayload.value;
      Uint8List payloadBytes;
      String payloadStr;
      if (payloadLen > 0 && payloadPtr != nullptr) {
        payloadBytes = Uint8List.fromList(payloadPtr.asTypedList(payloadLen));
        payloadStr = utf8.decode(payloadBytes, allowMalformed: true);
      } else {
        payloadBytes = Uint8List(0);
        payloadStr = '';
      }

      final kind = outKind.value;

      final encodingPtr = outEncoding.value;
      String? encodingStr;
      if (encodingPtr != nullptr) {
        encodingStr = encodingPtr.cast<Utf8>().toDartString();
      }

      final attachmentLen = outAttachmentLen.value;
      final attachmentPtr = outAttachment.value;
      String? attachmentStr;
      if (attachmentLen > 0 && attachmentPtr != nullptr) {
        final attachmentBytes = Uint8List.fromList(
          attachmentPtr.asTypedList(attachmentLen),
        );
        attachmentStr = utf8.decode(attachmentBytes, allowMalformed: true);
      }

      // Free all malloc'd C buffers (allocated by C malloc)
      if (keyExprPtr != nullptr) {
        malloc.free(keyExprPtr.cast());
      }
      if (payloadPtr != nullptr) {
        malloc.free(payloadPtr.cast());
      }
      if (encodingPtr != nullptr) {
        malloc.free(encodingPtr.cast());
      }
      if (attachmentPtr != nullptr) {
        malloc.free(attachmentPtr.cast());
      }

      return Sample(
        keyExpr: keyExprStr,
        payload: payloadStr,
        payloadBytes: payloadBytes,
        kind: kind == 0 ? SampleKind.put : SampleKind.delete,
        attachment: attachmentStr,
        encoding: encodingStr,
      );
    } finally {
      calloc.free(outKeyexpr);
      calloc.free(outPayload);
      calloc.free(outPayloadLen);
      calloc.free(outKind);
      calloc.free(outEncoding);
      calloc.free(outAttachment);
      calloc.free(outAttachmentLen);
    }
  }

  /// Closes the pull subscriber and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    // Drop subscriber first (undeclares from the session)
    bindings.zd_subscriber_drop(_subscriberHandle.cast());
    // Then drop ring handler
    bindings.zd_ring_handler_sample_drop(_handlerHandle);
    // Free allocated handle memory
    calloc.free(_subscriberHandle);
    calloc.free(_handlerHandle);
  }
}
