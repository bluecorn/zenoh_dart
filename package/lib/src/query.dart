import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bytes.dart';
import 'encoding.dart';
import 'exceptions.dart';
import 'keyexpr.dart';
import 'native_lib.dart';

/// A received query on a queryable key expression.
///
/// Wraps a heap-allocated `z_owned_query_t`. The query holds a cloned
/// reference to the original query from the callback. Call [dispose]
/// when done to release native resources (even if no reply was sent).
class Query {
  final int _handle;
  bool _disposed = false;

  /// The key expression of this query.
  final String keyExpr;

  /// The query parameters (selector portion after '?'). Empty if none.
  final String parameters;

  /// The optional payload attached to this query.
  final Uint8List? payloadBytes;

  /// The raw attachment bytes, or null if no attachment was present.
  ///
  /// This is the exact ground truth for query attachment metadata. A
  /// non-null empty [Uint8List] denotes a present-but-empty attachment
  /// (distinct from null, which denotes an absent attachment).
  final Uint8List? attachmentBytes;

  /// Creates a Query from NativePort message data.
  ///
  /// This is called internally by [Queryable] stream handler.
  Query({
    required int handle,
    required this.keyExpr,
    required this.parameters,
    this.payloadBytes,
    this.attachmentBytes,
  }) : _handle = handle;

  /// The native pointer handle for this query (used by reply methods).
  int get handle {
    _ensureNotDisposed();
    return _handle;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('Query has been disposed');
    }
  }

  /// Sends a reply to this query with a string value.
  ///
  /// The [keyExpr] should match the queryable's key expression.
  /// Optionally specify an [encoding] for the payload and a binary
  /// [attachment] carried alongside the reply sample.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void reply(
    String keyExpr,
    String value, {
    Encoding? encoding,
    ZBytes? attachment,
  }) {
    _ensureNotDisposed();
    final zbytes = ZBytes.fromString(value);
    replyBytes(keyExpr, zbytes, encoding: encoding, attachment: attachment);
  }

  /// Sends a reply to this query with a [ZBytes] payload.
  ///
  /// The [keyExpr] should match the queryable's key expression.
  /// The [payload] is consumed by this call (ownership transferred to zenoh).
  /// Optionally specify an [encoding] for the payload and a binary
  /// [attachment] carried alongside the reply sample. The [attachment], if
  /// provided, is also consumed by this call.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void replyBytes(
    String keyExpr,
    ZBytes payload, {
    Encoding? encoding,
    ZBytes? attachment,
  }) {
    // PRE-move early-return guards. Both run BEFORE any z_bytes_move, so on
    // these paths the caller retains ownership of payload/attachment and we
    // must NOT mark them consumed:
    //   (1) a disposed query throws StateError here;
    //   (2) an invalid key expression throws ZenohException here.
    // zd_query_reply's own z_view_keyexpr_from_str -1 is a pre-move backstop,
    // but the Dart caller cannot distinguish that rc from a post-move failure,
    // so we validate up front (mirroring Session.get / Querier.get) to keep
    // the markConsumed discipline correct.
    _ensureNotDisposed();
    KeyExpr(keyExpr).dispose();

    final keyExprNative = keyExpr.toNativeUtf8();

    Pointer<Utf8> encodingNative = nullptr;
    if (encoding != null) {
      encodingNative = encoding.mimeType.toNativeUtf8();
    }

    try {
      final rc = bindings.zd_query_reply(
        Pointer.fromAddress(_handle).cast(),
        keyExprNative.cast(),
        payload.nativePtr.cast(),
        encoding != null ? encodingNative.cast() : nullptr,
        attachment != null ? attachment.nativePtr.cast() : nullptr,
      );

      // Mark payload + attachment ZBytes consumed UNCONDITIONALLY: once we
      // reach this FFI call the pre-move guards above have passed, so
      // zd_query_reply has moved both into zenoh-c regardless of the return
      // code (its encoding-error path drops the already-moved bytes). Marking
      // before the rc-throw prevents a later use-after-move.
      payload.markConsumed();
      attachment?.markConsumed();

      if (rc != 0) {
        throw ZenohException('Failed to reply to query', rc);
      }
    } finally {
      calloc.free(keyExprNative);
      if (encoding != null) {
        calloc.free(encodingNative);
      }
    }
  }

  /// Sends an error reply to this query with a string value.
  ///
  /// Error replies carry a payload + optional [encoding] ONLY. There is no
  /// key expression and (by design) no attachment: zenoh-c's
  /// `z_query_reply_err_options_t` exposes only an encoding field. Use this to
  /// signal that the query could not be served successfully.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void replyErr(String value, {Encoding? encoding}) {
    _ensureNotDisposed();
    final zbytes = ZBytes.fromString(value);
    replyErrBytes(zbytes, encoding: encoding);
  }

  /// Sends an error reply to this query with a [ZBytes] payload.
  ///
  /// The [payload] is consumed by this call (ownership transferred to zenoh).
  /// Optionally specify an [encoding] for the payload. Error replies carry a
  /// payload + encoding ONLY -- there is no attachment parameter (zenoh-c's
  /// `z_query_reply_err_options_t` has no attachment field).
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void replyErrBytes(ZBytes payload, {Encoding? encoding}) {
    // PRE-move early-return guard: a disposed query throws StateError here,
    // BEFORE any z_bytes_move, so the caller retains ownership of payload and
    // we must NOT mark it consumed on this path (mirrors replyBytes).
    _ensureNotDisposed();

    Pointer<Utf8> encodingNative = nullptr;
    if (encoding != null) {
      encodingNative = encoding.mimeType.toNativeUtf8();
    }

    try {
      final rc = bindings.zd_query_reply_err(
        Pointer.fromAddress(_handle).cast(),
        payload.nativePtr.cast(),
        encoding != null ? encodingNative.cast() : nullptr,
      );

      // Mark the payload ZBytes consumed UNCONDITIONALLY: once we reach this
      // FFI call the pre-move guard above has passed, so zd_query_reply_err has
      // moved the payload into zenoh-c regardless of the return code (its
      // encoding-error path drops the already-moved bytes). Marking before the
      // rc-throw prevents a later use-after-move. The encoding is a MIME string
      // (not a caller-owned ZBytes), so it needs no Dart-side markConsumed.
      payload.markConsumed();

      if (rc != 0) {
        throw ZenohException('Failed to send error reply to query', rc);
      }
    } finally {
      if (encoding != null) {
        calloc.free(encodingNative);
      }
    }
  }

  /// Releases the native query resources.
  ///
  /// Must be called even if no reply was sent. Safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bindings.zd_query_drop(Pointer.fromAddress(_handle).cast());
  }
}
