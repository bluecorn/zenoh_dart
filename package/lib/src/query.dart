import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/native_string.dart';
import 'package:zenoh_dart/src/queryable.dart' show Queryable;
import 'package:zenoh_dart/src/reply_keyexpr.dart';
import 'package:zenoh_dart/src/timestamp.dart';

/// A received query on a queryable key expression.
///
/// Wraps a heap-allocated `z_owned_query_t`. The query holds a cloned
/// reference to the original query from the callback. Call [dispose]
/// when done to release native resources (even if no reply was sent).
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: on the
/// one-session path `zd_query_drop` POSTS to a Dart port, and a post reached
/// from a finalizer callback is documented undefined behaviour. Measured: 1
/// post one-session, 0 over TCP loopback — the topology dependence is why "it
/// worked once" is not evidence here.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class Query implements Finalizable {
  /// Creates a Query from NativePort message data.
  ///
  /// This is called internally by [Queryable] stream handler.
  ///
  /// `handle` is the address of a heap-allocated `z_owned_query_t` that the
  /// shim has just handed over as a plain integer — posted across the
  /// NativePort for a pushed query, written back by the receive call for a
  /// pulled one. Inside this package that is the only value ever passed
  /// here.
  ///
  /// ⛔ **There are two ways to get this wrong, and a consumer can reach
  /// both.** *(Corrected: this said "the library never hands one out — no
  /// member returns it". That is false: the public `handle` getter returns
  /// exactly this value.)*
  ///
  /// - **A handle this library did not produce aborts the VM.** The integer
  ///   is cast back to a pointer and dereferenced without validation on
  ///   every native call this object makes. Nothing can reject a wrong one,
  ///   so the process dies where an ordinary API would throw.
  /// - **A real handle, obtained through `handle`, builds a second
  ///   wrapper** over a query another [Query] still owns. Each wrapper
  ///   releases it in [dispose], so the second release works on a block that
  ///   has already been freed and the process dies — measured on Linux at the
  ///   second [dispose].
  ///
  /// ⚠️ **The crash need not arrive where the mistake was made.**
  /// Construction succeeds silently — nothing is dereferenced here. A
  /// fabricated handle aborts at the first member that touches it: [reply],
  /// [replyBytes], [replyDel], [replyErr], [replyErrBytes], [payloadZBytes]
  /// or [dispose]. A second wrapper's handle stays valid until either
  /// wrapper is disposed, so that mistake surfaces later still. Either can be
  /// far from the construction in both source and time.
  ///
  /// ⭐ **The delayed-arrival mechanism differs from [ZBytes.fromNative] and
  /// `ShmMutBuffer.fromNative`.** Those arm a `NativeFinalizer`
  /// unconditionally, so collection is an arrival point for them even when
  /// the object is never used. This class arms none — the class dartdoc
  /// above gives the ground — so a Query that is constructed and then merely
  /// dropped never touches its handle at all.
  ///
  /// Marked `@internal`, so naming it from another package draws a warning.
  /// ⛔ **A warning, not a fence**: [Query] is exported and this is its only
  /// constructor, so the name still resolves and the crash class above stays
  /// reachable by decision.
  @internal
  Query({
    required this._handle,
    required this.keyExpr,
    required this.parameters,
    this.payloadBytes,
    this.attachmentBytes,
    this.encoding,
    this.encodingBytes,
    this.acceptsReplies = ReplyKeyExpr.matchingQuery,
  });

  final int _handle;
  bool _disposed = false;

  /// Memo for [payloadZBytes]. `_resolved` is separate from a null check
  /// because ABSENT is a legitimate resolved value: a query with no
  /// payload must memoise `null` rather than re-cloning on every read.
  ZBytes? _payloadZBytes;
  bool _payloadZBytesResolved = false;

  /// The key expression of this query.
  ///
  /// Delivered byte-exact: it crosses from native length-carried rather than
  /// as a C string, so an interior NUL — which the key expression grammar
  /// permits and canon carries across the wire — survives here too.
  final String keyExpr;

  /// The query parameters — the selector's portion after `?`.
  ///
  /// Delivered byte-exact: the channel is **length-carried in both
  /// directions**, so an interior NUL survives the send seam and this receive
  /// seam alike. (Before that rebase the value was measured with `strlen` on
  /// both sides and truncated at the first NUL.) The decode is lenient, like
  /// every other display string on a receive surface.
  ///
  /// **Absent and present-but-empty are the same value here, and that is
  /// canon's doing, not this binding's.** Measured: a query sent with no
  /// parameters and a query sent with `parameters: ''` both arrive as the empty
  /// string. canon collapses them before any wire encoding — its own string
  /// view takes a NULL pointer at length 0 and a non-NULL pointer at length 0
  /// alike — which is also why this field is a non-nullable [String]: there is
  /// no absent value to render.
  final String parameters;

  /// The optional payload attached to this query.
  final Uint8List? payloadBytes;

  /// The raw attachment bytes, or null if no attachment was present.
  ///
  /// This is the exact ground truth for query attachment metadata. A
  /// non-null empty [Uint8List] denotes a present-but-empty attachment
  /// (distinct from null, which denotes an absent attachment).
  final Uint8List? attachmentBytes;

  /// The encoding the requester declared, or null if none.
  ///
  /// A lenient MIME display string (e.g. `application/json`). The byte/opaque
  /// encoding is never crystallized into an [Encoding] object on this field --
  /// it is exposed as a `String?` display view. Null denotes an absent
  /// encoding (the requester set none), distinct from a present-but-empty
  /// encoding, which reads as an empty string.
  ///
  /// Delivered length-carried, so an interior NUL in the rendered MIME string
  /// or its schema survives rather than truncating at the seam. Use
  /// [encodingBytes] for the exact data.
  final String? encoding;

  /// The raw bytes of the rendered encoding, or null if the requester set
  /// none.
  ///
  /// This is the exact ground truth for the encoding channel; [encoding] is a
  /// lenient UTF-8 string view of these same bytes. A non-null empty
  /// [Uint8List] denotes a present-but-empty encoding, distinct from null,
  /// which denotes an absent one — the asymmetry canon gives a query and
  /// gives neither a sample nor a reply.
  final Uint8List? encodingBytes;

  /// Which key expressions this query accepts replies on (default
  /// `matchingQuery`).
  final ReplyKeyExpr acceptsReplies;

  /// The native pointer handle for this query (used by reply methods).
  int get handle {
    _ensureNotDisposed();
    return _handle;
  }

  /// The query's payload as a retained [ZBytes] handle, or null if the
  /// requester sent none.
  ///
  /// ## Why this needs no opt-in, where a sample's does
  ///
  /// `Session.declareSubscriber` takes a `retainPayload:` flag because a
  /// **sample's** native payload dies when the delivery callback returns —
  /// retaining it has to happen inside that callback or not at all, so it must
  /// be decided at declaration time and costs something on every message.
  ///
  /// A **query's** does not. The whole owned query is cloned across the seam
  /// and stays alive until [dispose] is called, so its payload is reachable
  /// whenever you ask. This accessor is therefore lazy — it costs nothing
  /// unless read — and needs no flag. **The asymmetry is the reason the flag
  /// exists elsewhere**, not an inconsistency.
  ///
  /// ## Lifetime
  ///
  /// The handle is an independent, shallow, refcounted clone. It **outlives
  /// this query**: calling [dispose] does not invalidate it, and reading it
  /// after disposal is fine once it has been materialised.
  ///
  /// The accessor is **memoized** — reading it repeatedly returns the identical
  /// object rather than minting a handle per read, so a consumer cannot leak
  /// one by looping.
  ///
  /// ⛔ **Release it**, with [ZBytes.dispose] or by handing it to a send that
  /// consumes it. [dispose] on this query deliberately does **not** release it:
  /// it is yours, not the query's. A `ZBytes` carries a finalizer safety net,
  /// but a finalizer runs at an unpredictable time or not at all, so the net is
  /// not a substitute for releasing it.
  ///
  /// Throws [StateError] if this query has been disposed **and** the payload
  /// was never materialised — there is no live handle left to clone from.
  ZBytes? get payloadZBytes {
    // The memo is checked BEFORE the disposal guard, deliberately: once
    // materialised the clone is independent of this query, so it stays
    // readable afterwards. Only an unresolved read needs the native handle,
    // and that is exactly what the guard protects.
    if (_payloadZBytesResolved) return _payloadZBytes;
    _ensureNotDisposed();

    final size = bindings.zd_bytes_sizeof();
    final slot = calloc.allocate<Void>(size);
    final present = calloc<Int32>();
    try {
      bindings.zd_query_payload_clone(
        Pointer<Uint8>.fromAddress(_handle),
        slot.cast(),
        present,
      );
      if (present.value == 0) {
        // Absent, not empty. Nothing was written into the slot, so it is freed
        // here rather than wrapped — wrapping it would hand out a ZBytes over
        // uninitialised memory.
        calloc.free(slot);
        _payloadZBytes = null;
      } else {
        _payloadZBytes = ZBytes.fromNative(slot);
      }
    } finally {
      // OUTER-FINALLY, enclosing every statement that can throw: the presence
      // cell is Dart-allocated and is released on every control path.
      calloc.free(present);
    }
    _payloadZBytesResolved = true;
    return _payloadZBytes;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('Query has been disposed');
    }
  }

  /// Copies a [Timestamp]'s raw 24-byte image into freshly calloc'd (8-byte
  /// aligned) native memory. z_timestamp_t is ALIGN(8); the C shim memcpy's
  /// these bytes into aligned stack storage, but the send-side buffer must
  /// itself be aligned to be safe on Android/ARM. Caller frees the pointer.
  Pointer<Uint8> _timestampToNative(Timestamp ts) {
    final tsSize = bindings.zd_timestamp_sizeof();
    assert(tsSize == 24, 'z_timestamp_t drifted from 24 bytes: $tsSize');
    final p = calloc<Uint8>(tsSize);
    p.asTypedList(tsSize).setAll(0, ts.rawBytes);
    return p;
  }

  /// Sends a reply to this query with a string value.
  ///
  /// The [keyExpr] should match the queryable's key expression.
  /// Optionally specify an [encoding] for the payload, a binary [attachment]
  /// carried alongside the reply sample, and a [timestamp] stamped onto the
  /// reply.
  ///
  /// [isExpress] disables batching for this reply; omitting it — or passing
  /// `null` — means **canon decides**, which is `false`.
  ///
  /// [isExpress] is the ONLY quality-of-service option on the reply path, and
  /// that is deliberate. canon marks a reply's congestion control and priority
  /// **deprecated and ignored** ("Reply congestion control is not supported
  /// anymore"), so this binding does not expose them: a reply inherits the
  /// QUERY's congestion control and priority, and nothing set here could
  /// change that. Set them on the `get` or `Querier` instead.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void reply(
    Object keyExpr,
    String value, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
    bool? isExpress,
  }) {
    // ALLOCATE-LAST. replyBytes' own pre-move guards throw BEFORE consuming
    // the payload -- a disposed query (StateError) and a rejected key
    // expression (ArgumentError or ZenohException) -- and this method builds
    // the ZBytes for them. Nothing else holds a reference to it, so the guard
    // has to run before the ZBytes exists. The query guard does that here;
    // the key expression is validated once, downstream, by replyBytes' union
    // dispatch -- which is still before the payload is moved, because the
    // dispatch encloses the FFI call.
    //
    // This method no longer constructs a throwaway KeyExpr of its own. One
    // reply() used to validate the same string three times: here, in
    // replyBytes, and again in the shim.
    _ensureNotDisposed();

    final zbytes = ZBytes.fromString(value);
    replyBytes(
      keyExpr,
      zbytes,
      encoding: encoding,
      attachment: attachment,
      timestamp: timestamp,
      isExpress: isExpress,
    );
  }

  /// Sends a reply to this query with a [ZBytes] payload.
  ///
  /// The [keyExpr] should match the queryable's key expression.
  /// The [payload] is consumed by this call (ownership transferred to zenoh).
  /// Optionally specify an [encoding] for the payload and a binary
  /// [attachment] carried alongside the reply sample. The [attachment], if
  /// provided, is also consumed by this call. An optional [timestamp] is
  /// borrowed (not consumed) and stamped onto the reply sample.
  ///
  /// [isExpress] disables batching for this reply; omitting it — or passing
  /// `null` — means **canon decides**, which is `false`.
  ///
  /// [isExpress] is the ONLY quality-of-service option on the reply path, and
  /// that is deliberate. canon marks a reply's congestion control and priority
  /// **deprecated and ignored** ("Reply congestion control is not supported
  /// anymore"), so this binding does not expose them: a reply inherits the
  /// QUERY's congestion control and priority, and nothing set here could
  /// change that. Set them on the `get` or `Querier` instead.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void replyBytes(
    Object keyExpr,
    ZBytes payload, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
    bool? isExpress,
  }) {
    // PRE-move guards. All of these run BEFORE any z_bytes_move, so on these
    // paths the caller retains ownership of payload/attachment and we must
    // NOT mark them consumed:
    //   (1) a disposed query throws StateError here;
    //   (2) a wrong-typed key expression throws ArgumentError in the dispatch;
    //   (3) an invalid key expression string throws ZenohException there too.
    // The dispatch encloses the FFI call, so (2) and (3) still precede the
    // move -- which is what the unconditional markConsumed below depends on.
    _ensureNotDisposed();

    withLoanedKeyExpr(keyExpr, 'keyExpr', (loanedKe) {
      // Two INDEPENDENT length-carried channels (R-2), from the RAW pair
      // (R-3a). Built BEFORE the payload move, like everything else here.
      final (mime, schema) = encoding != null
          ? encodingWireChannels(encoding)
          : (null, null);
      final encodingBuf = allocLengthCarriedUtf8(mime);
      final schemaBuf = allocLengthCarriedUtf8(schema);

      // Timestamp is BORROWED (not moved) -- allocate an 8-byte-aligned copy
      // after the pre-move guards so a pre-move throw never leaks it. Freed in
      // the finally alongside encodingNative.
      final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;

      try {
        final rc = bindings.zd_query_reply(
          Pointer.fromAddress(_handle).cast(),
          loanedKe.cast(),
          payload.nativePtr.cast(),
          encodingBuf.ptr,
          encodingBuf.len,
          schemaBuf.ptr,
          schemaBuf.len,
          attachment != null ? attachment.nativePtr.cast() : nullptr,
          tsPtr.cast(),
          isExpress == null ? -1 : (isExpress ? 1 : 0),
        );

        // Mark payload + attachment ZBytes consumed UNCONDITIONALLY: once we
        // reach this FFI call the pre-move guards above have passed, so
        // zd_query_reply has moved both into zenoh-c regardless of the return
        // code (its encoding-error path drops the already-moved bytes).
        // Marking before the rc-throw prevents a later use-after-move.
        payload.markConsumed();
        attachment?.markConsumed();

        if (rc != 0) {
          throw ZenohException('Failed to reply to query', rc);
        }
      } finally {
        // allocLengthCarriedUtf8 uses calloc; ptr is nullptr exactly when the
        // value was null, so the guard is on the pointer, not on `encoding`.
        if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
        if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
        if (tsPtr != nullptr) {
          calloc.free(tsPtr);
        }
      }
    });
  }

  /// Sends a DELETE-kind reply to this query.
  ///
  /// The [keyExpr] should match the queryable's key expression. A DELETE-kind
  /// reply carries no payload and no encoding (mirroring `z_query_reply_del`),
  /// but may carry a binary [attachment] and an optional [timestamp]. The
  /// [attachment], if provided, is consumed by this call (ownership transferred
  /// to zenoh). The [timestamp] is borrowed (not consumed) and stamped onto the
  /// reply sample.
  ///
  /// [isExpress] disables batching for this reply; omitting it — or passing
  /// `null` — means **canon decides**, which is `false`.
  ///
  /// [isExpress] is the ONLY quality-of-service option on the reply path, and
  /// that is deliberate. canon marks a reply's congestion control and priority
  /// **deprecated and ignored** ("Reply congestion control is not supported
  /// anymore"), so this binding does not expose them: a reply inherits the
  /// QUERY's congestion control and priority, and nothing set here could
  /// change that. Set them on the `get` or `Querier` instead.
  ///
  /// Throws [StateError] if the query has been disposed.
  /// Throws [ZenohException] if the reply fails.
  void replyDel(
    Object keyExpr, {
    ZBytes? attachment,
    Timestamp? timestamp,
    bool? isExpress,
  }) {
    // PRE-move guards, as in replyBytes: a disposed query, a wrong-typed key
    // expression and an invalid key expression string all throw before the
    // attachment is moved, so on those paths the caller keeps ownership.
    _ensureNotDisposed();

    withLoanedKeyExpr(keyExpr, 'keyExpr', (loanedKe) {
      // Timestamp is BORROWED (not moved) -- allocate an 8-byte-aligned copy
      // after the pre-move guards so a pre-move throw never leaks it.
      final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;

      try {
        final rc = bindings.zd_query_reply_del(
          Pointer.fromAddress(_handle).cast(),
          loanedKe.cast(),
          attachment != null ? attachment.nativePtr.cast() : nullptr,
          tsPtr.cast(),
          isExpress == null ? -1 : (isExpress ? 1 : 0),
        );

        // Mark the attachment ZBytes consumed UNCONDITIONALLY: once we reach
        // this FFI call the pre-move guards above have passed, so
        // zd_query_reply_del has moved the attachment into zenoh-c regardless
        // of the return code. Marking before the rc-throw prevents a later
        // use-after-move.
        attachment?.markConsumed();

        if (rc != 0) {
          throw ZenohException('Failed to reply-del to query', rc);
        }
      } finally {
        if (tsPtr != nullptr) {
          calloc.free(tsPtr);
        }
      }
    });
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
    // ALLOCATE-LAST: replyErrBytes' only pre-move guard is the disposed-query
    // check, so running it here keeps that throw ahead of the ZBytes this
    // method builds and nothing else owns.
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

    // Two INDEPENDENT length-carried channels (R-2), from the RAW pair (R-3a).
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);

    try {
      final rc = bindings.zd_query_reply_err(
        Pointer.fromAddress(_handle).cast(),
        payload.nativePtr.cast(),
        encodingBuf.ptr,
        encodingBuf.len,
        schemaBuf.ptr,
        schemaBuf.len,
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
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
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
