import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/channel_kind.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/consolidation_mode.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/liveliness.dart';
import 'package:zenoh_dart/src/locality.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/native_string.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/publisher.dart';
import 'package:zenoh_dart/src/pull_queryable.dart';
import 'package:zenoh_dart/src/pull_replies.dart';
import 'package:zenoh_dart/src/pull_subscriber.dart';
import 'package:zenoh_dart/src/querier.dart';
import 'package:zenoh_dart/src/query.dart';
import 'package:zenoh_dart/src/query_target.dart';
import 'package:zenoh_dart/src/queryable.dart';
import 'package:zenoh_dart/src/reply.dart';
import 'package:zenoh_dart/src/reply_keyexpr.dart';
import 'package:zenoh_dart/src/reply_retention.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/subscriber.dart';
import 'package:zenoh_dart/src/timestamp.dart';

/// A Zenoh session.
///
/// Wraps `z_owned_session_t`. Use [Session.open] to create a session,
/// optionally passing a [Config]. Call [close] when done to gracefully
/// shut down the session and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: its
/// release is documented UNDEFINED BEHAVIOUR from a finalizer callback:
/// `z_close` drops closures that call `Dart_PostCObject_DL`, a Dart C API, and
/// a finalizer callback runs with no current isolate. It is also collected
/// while its children are still live.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class Session implements Finalizable {
  Session._(this._ptr);

  /// Opens a Zenoh session **without blocking the calling isolate**.
  ///
  /// Canon's `z_open` blocks for a duration the *configuration* chooses, and
  /// it can be long. At the pinned zenoh-c 1.8.0, measured on Linux x64:
  ///
  /// - an unreachable configured endpoint — **~505 ms**
  /// - an empty network at canon defaults — **~505 ms**
  /// - a client-mode failure — **~3005 ms**, which is `scouting/timeout`
  /// - multicast off with no endpoint — **~1 ms**
  ///
  /// ⚠️ The ~500 ms against a **reachable** router is a defect in this pinned
  /// version, not canon's design: upstream PR #2493 fixes it in 1.9.0+, where
  /// the same cell reads 7–9 ms. What survives at *every* version is the
  /// unhappy set — empty network at defaults, dead endpoint, and client-mode
  /// failure at 3 s — which is exactly where a frozen UI matters most.
  ///
  /// Four knobs move the wait, and all four are canon's, not this package's:
  /// `scouting/delay` · `open/return_conditions/connect_scouted` ·
  /// `open/return_conditions/declares` · `scouting/timeout` (client mode's
  /// 3 s). ⚠️ Switching `scouting/delay` or `connect_scouted` is a **1.8.0
  /// workaround**, not standing advice. The wait is also a property of the
  /// *pair*: two peers that both have gossip enabled wait, and either one
  /// having it disabled removes it.
  ///
  /// The blocking call therefore runs on a shim-owned thread and this returns
  /// a future. Timers keep firing, other futures keep progressing, and a
  /// Flutter frame pipeline keeps running for the whole wait.
  ///
  /// If [config] is provided it is consumed and must not be reused or
  /// disposed by the caller. If [config] is null a default one is created
  /// internally.
  ///
  /// ⛔ **An open in flight cannot be cancelled.** Dropping the future does
  /// not stop the native call; the worker runs to completion either way.
  ///
  /// ⛔ **[Session] carries no finalizer**, so an un-awaited or un-closed
  /// session leaks by the same documented contract as every other release
  /// here: [close] is the only thing that reclaims it.
  ///
  /// Throws [StateError] **synchronously** — before any future exists — if
  /// [config] has already been consumed or disposed. ⚠️ This deliberately
  /// diverges from `Zenoh.scout`, whose `async` body turns the same class of
  /// pre-flight error into a rejected future. Here the method is
  /// intentionally **not** `async`, so a programming error surfaces at the
  /// call rather than at the await.
  ///
  /// Throws [ZenohException] two ways, and the channel discriminates:
  /// **synchronously with a positive code** if the background call could not
  /// be *started* (nothing ran, and no completion is coming), and as a
  /// **rejected future carrying canon's negative code** if `z_open` itself
  /// failed.
  ///
  /// ⚠️ **A rejected future carries `Z_ENETWORK` (`-4`) for almost every
  /// cause** — canon collapses them all into that one code, so the message
  /// tells you an open failed and not *why*. The reason lives in canon's own
  /// log. Turn it on with `Zenoh.initLog('error')`, or route it into your
  /// application with `Zenoh.initLogWithSink`; ⛔ **the two are mutually
  /// exclusive and first-wins**, so install the sink first if you may ever
  /// want one. See `openFailureMessage` for the full route, its leak
  /// condition, and why the `stable` build has only this one.
  ///
  /// There is no `openSync` sibling.
  static Future<Session> open({Config? config}) {
    // Deliberately NOT an `async` body: everything down to the FFI call runs
    // synchronously, so a spent Config throws at the call site instead of
    // being wrapped into a rejected future.
    final effectiveConfig = config ?? Config();
    final configPtr = effectiveConfig.nativePtr;
    final callerSupplied = config != null;

    final receivePort = ReceivePort();
    final completer = Completer<Session>();

    receivePort.listen((dynamic message) {
      try {
        completeOpenFromPost(
          message,
          completer,
          callerSuppliedConfig: callerSupplied,
        );
      } finally {
        // Exactly one post is contracted, and ReceivePort.close is idempotent,
        // so closing here unconditionally both releases the port and stops the
        // isolate being pinned by a listener nobody will feed again.
        receivePort.close();
      }
    });

    final rc = bindings.zd_open_session_async(
      configPtr.cast(),
      receivePort.sendPort.nativePort,
    );

    // Unconditional, exactly as at zd_scout: the shim takes the config's
    // content via z_config_take before any fallible step, so it is consumed on
    // every path where the entry was reached with one. markConsumed detaches
    // the finalizer and frees the wrapper block without touching native.
    //
    // ⛔ NOT deferred to the post. Deferring would leave a dropped Config's
    // finalizer free to fire while the worker is still inside z_open.
    effectiveConfig.markConsumed();

    if (rc != 0) {
      // "Did it start" failed: nothing ran and no post will ever arrive, so
      // awaiting would hang forever. Close the port and throw SYNCHRONOUSLY --
      // a positive code, which is what tells the two failure classes apart.
      receivePort.close();
      throw ZenohException(openStartFailureMessage(rc), rc);
    }

    return completer.future;
  }

  final Pointer<Void> _ptr;
  bool _closed = false;

  /// Gracefully closes the session and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    // ⛔ SHIM-OWNED BLOCK: zd_open_session_async malloc'd it, so the shim frees
    // it, inside zd_session_close_drop. A calloc.free here would be a
    // cross-allocator free -- the exact defect the allocator-side-frees rule
    // exists to prevent.
    bindings.zd_session_close_drop(_ptr.cast());
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Session has been closed');
  }

  /// Refuses a [timeout] that would marshal onto canon's config-default
  /// sentinel, on the entries where canon's `0` carries that meaning.
  ///
  /// On `z_get` and `z_querier` canon documents `timeout_ms == 0` as *"default
  /// query timeout from zenoh configuration"* — so a caller asking for an
  /// immediate expiry silently gets ~10 seconds instead. That is a **silent
  /// default substitution**: the caller passed a value canon has no way to
  /// represent, and canon was never asked. It is refused here rather than
  /// smuggled through, the same shape as the capacity guard.
  ///
  /// The check keys on the **marshalled wire value**, not on [Duration.zero]
  /// identity, because `Duration(microseconds: 500).inMilliseconds` is also
  /// `0`: a positive sub-millisecond timeout would otherwise truncate onto the
  /// same sentinel, which is the identical defect wearing a different
  /// constructor.
  ///
  /// Not applied on the liveliness entries — see [livelinessGet], where zero
  /// is honoured literally.
  static void _rejectSentinelTimeout(Duration? timeout) {
    if (timeout != null && timeout.inMilliseconds == 0) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'marshals to 0 ms, which zenoh reads as "use the configured default '
            'query timeout" rather than as an immediate expiry. Pass a timeout '
            'of at least 1 ms, or omit it to let zenoh decide',
      );
    }
  }

  /// Whether this session has been closed.
  ///
  /// Returns true after [close] has been called; safe to call any number of
  /// times post-close (never dereferences the freed native handle).
  bool get isClosed {
    // Short-circuit BEFORE any loan/deref: close() frees the native handle,
    // so the Dart-side _closed flag is the only safe post-close source.
    if (_closed) return true;
    final loanedSession = bindings.zd_session_loan(_ptr.cast());
    return bindings.zd_session_is_closed(loanedSession) != 0;
  }

  /// @nodoc
  ///
  /// Internal: the loaned session handle, for unstable-door extensions that
  /// declare advanced entities (`session_advanced_ext.dart`). Not part of the
  /// public contract.
  @internal
  Pointer<Void> get loanedHandle {
    _ensureOpen();
    return bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
  }

  /// Returns the [ZenohId] of this session.
  ///
  /// Throws [StateError] if the session has been closed.
  ZenohId get zid {
    _ensureOpen();
    final idSize = bindings.zd_id_sizeof();
    assert(idSize == 16, 'z_id_t drifted from 16 bytes: $idSize');
    final outId = calloc<Uint8>(idSize);
    try {
      final loanedSession = bindings.zd_session_loan(_ptr.cast());
      bindings.zd_info_zid(loanedSession, outId);
      return ZenohId(Uint8List.fromList(outId.asTypedList(idSize)));
    } finally {
      calloc.free(outId);
    }
  }

  /// Creates a new timestamp from this session's HLC clock.
  ///
  /// Works on a default peer session (no `timestamping/enabled` required).
  ///
  /// Throws [StateError] if the session has been closed.
  /// Throws [ZenohException] if the native timestamp creation fails.
  Timestamp newTimestamp() {
    _ensureOpen();
    final tsSize = bindings.zd_timestamp_sizeof();
    assert(tsSize == 24, 'z_timestamp_t drifted from 24 bytes: $tsSize');
    final outTs = calloc<Uint8>(tsSize);
    try {
      final loanedSession = bindings.zd_session_loan(_ptr.cast());
      final rc = bindings.zd_timestamp_new(loanedSession, outTs);
      if (rc != 0) throw ZenohException('Failed to create timestamp', rc);
      return Timestamp.fromRaw(outTs.asTypedList(tsSize));
    } finally {
      calloc.free(outTs);
    }
  }

  /// Collects ZenohIds from one of the two native enumerators.
  ///
  /// Ownership: the shim allocates the id buffer and the **shim** frees it, at
  /// the designated drop entry `zd_zid_list_drop` — the allocator-side-frees
  /// convention. `zd_zid_list_drop` is called unconditionally and **exactly
  /// once**: after the shim's merged release branch the out-cell holds either a
  /// live buffer this call owns or `NULL`, there is no third state, and `NULL`
  /// is a documented no-op. It is *not* idempotent on a non-`NULL` pointer,
  /// which is why this is a single call in the `finally` rather than a retry or
  /// a second defensive drop.
  ///
  /// Allocate-last: `_ensureOpen()` runs before either out-cell is claimed, so
  /// a closed session strands nothing. The single **outer** `finally` encloses
  /// every statement that can throw — including the materialization loop, whose
  /// `ZenohId` construction now enforces the 16-byte invariant and would raise
  /// mid-loop if the shim ever handed back a short slice.
  ///
  /// Failure is **not** empty: a native or shim-side failure throws, where the
  /// superseded path flattened every failure to `-1` and returned a silent
  /// `[]`.
  List<ZenohId> _collectZids(
    int Function(Pointer<Opaque>, Pointer<Pointer<Uint8>>, Pointer<Size>)
    nativeCall,
    String failureMessage,
  ) {
    _ensureOpen();
    final outIds = calloc<Pointer<Uint8>>();
    final outCount = calloc<Size>();
    try {
      final loanedSession = bindings.zd_session_loan(_ptr.cast());
      final rc = nativeCall(loanedSession, outIds, outCount);
      if (rc != 0) throw ZenohException(failureMessage, rc);
      final count = outCount.value;
      // An empty enumeration allocated no block at all, so the out-pointer is
      // null and must not be dereferenced.
      if (count == 0) return const <ZenohId>[];
      final allBytes = outIds.value.asTypedList(count * 16);
      return [
        for (var i = 0; i < count; i++)
          ZenohId(allBytes.sublist(i * 16, (i + 1) * 16)),
      ];
    } finally {
      bindings.zd_zid_list_drop(outIds.value);
      calloc
        ..free(outIds)
        ..free(outCount);
    }
  }

  /// Returns the [ZenohId]s of all connected routers.
  ///
  /// The enumeration is **unbounded** — canon's contract fires its callback
  /// once for each ID with no bound of any kind, and neither this call nor the
  /// shim beneath it imposes one.
  ///
  /// Returns an empty list if no router is connected (e.g., in peer mode).
  ///
  /// Throws [StateError] if the session has been closed.
  /// Throws [ZenohException] if the native or shim-side collection fails — an
  /// empty list means *no routers*, never *the call failed*.
  List<ZenohId> routersZid() =>
      _collectZids(bindings.zd_info_routers_zid, 'Failed to fetch router Ids');

  /// Returns the [ZenohId]s of all connected peers.
  ///
  /// The enumeration is **unbounded**, exactly as [routersZid].
  ///
  /// Returns an empty list if no peer is connected.
  ///
  /// Throws [StateError] if the session has been closed.
  /// Throws [ZenohException] if the native or shim-side collection fails — an
  /// empty list means *no peers*, never *the call failed*.
  List<ZenohId> peersZid() =>
      _collectZids(bindings.zd_info_peers_zid, 'Failed to fetch peer Ids');

  /// Executes [action] with a loaned session and a loaned key expression
  /// obtained from [keyExpr], which is a `String` or a [KeyExpr].
  ///
  /// The single dispatch point for the union every key expression parameter
  /// accepts. The `String` arm builds a temporary [KeyExpr] — the sole
  /// validator on that path, throwing the same [ZenohException] with canon's
  /// own return code — and disposes it in a `finally`. The [KeyExpr] arm
  /// loans the caller's handle and disposes nothing.
  T _withKeyExprArg<T>(
    Object keyExpr,
    String paramName,
    T Function(Pointer<Void> loanedSession, Pointer<Void> loanedKe) action,
  ) {
    _ensureOpen();
    return withLoanedKeyExpr(keyExpr, paramName, (loanedKe) {
      final loanedSession =
          bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
      return action(loanedSession, loanedKe);
    });
  }

  /// Declares [keyExpr] on this session and returns an owned [KeyExpr].
  ///
  /// [keyExpr] is a `String` or an existing [KeyExpr]; a [KeyExpr] argument is
  /// loaned, not consumed, and remains the caller's to dispose.
  ///
  /// Declaring reduces the key expression to a numerical id in the session's
  /// routing tables, which saves bandwidth when the expression is passed
  /// between Zenoh entities. The returned handle is accepted by every
  /// operation that takes a key expression, and reads back through [KeyExpr]'s
  /// `value` as the expression it was declared from.
  ///
  /// The handle is usable in an operation driven from **another** session —
  /// measured: it routes correctly and observers receive the right key
  /// expression — but it can only be undeclared on the session that declared
  /// it (see [undeclareKeyExpr]).
  ///
  /// Release it with [undeclareKeyExpr] to unregister it, or with
  /// [KeyExpr.dispose] to drop the handle and leave the registration to the
  /// session's own lifetime.
  ///
  /// Throws [ArgumentError] if [keyExpr] is neither a `String` nor a
  /// [KeyExpr]. Throws [ZenohException] if the expression is invalid or the
  /// declaration fails. Throws [StateError] if the session has been closed.
  KeyExpr declareKeyExpr(Object keyExpr) => _withKeyExprArg(
    keyExpr,
    'keyExpr',
    KeyExpr.declareOn,
  );

  /// Undeclares [keyExpr] from this session, releasing its numerical id.
  ///
  /// 🔴 The handle is **consumed on every return code, errors included** —
  /// canon takes the value out before it checks anything. After this call, any
  /// use of [keyExpr] throws [StateError], and that includes
  /// [KeyExpr.dispose]: undeclaring has already released everything.
  ///
  /// Undeclaring on a session other than the declaring one fails with a
  /// [ZenohException] carrying `-128` — and still consumes the handle.
  ///
  /// Throws [ArgumentError], **without** consuming the handle, if [keyExpr]
  /// was not obtained from [declareKeyExpr]: canon's undeclare takes an owned
  /// key expression, so there is no call to make. Throws [StateError], also
  /// without consuming, if the session has been closed or the handle is
  /// already dead.
  void undeclareKeyExpr(KeyExpr keyExpr) {
    _ensureOpen();
    final loanedSession =
        bindings.zd_session_loan(_ptr.cast()) as Pointer<Void>;
    keyExpr.undeclareFrom(loanedSession);
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

  /// Publishes a string [value] on the given [keyExpr].
  ///
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is consumed by this call and must not
  /// be reused. An optional [timestamp] can be attached to the message;
  /// borrowed, not consumed.
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress] and [allowedDestination] are
  /// each optional, and omitting one — or passing `null` — means the same
  /// thing: **canon decides**. This binding substitutes no value of its own.
  /// On this path canon's defaults are [CongestionControl.drop] (a *push*
  /// operation; `get` and `declareQuerier` default to [CongestionControl.block]
  /// instead), [Priority.data], `isExpress: false`, and [Locality.any].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// [keyExpr] is a `String` or a [KeyExpr] — including one obtained from
  /// [declareKeyExpr], whose native handle reaches zenoh directly instead of
  /// being re-parsed from a string. A [KeyExpr] argument is loaned, not
  /// consumed.
  ///
  /// Throws [ArgumentError] if [keyExpr] is neither a `String` nor a
  /// [KeyExpr].
  /// Throws [ZenohException] if the key expression is invalid, the encoding
  /// is malformed, or the put fails.
  /// Throws [StateError] if the session has been closed, or the attachment
  /// has been disposed or already consumed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  void put(
    Object keyExpr,
    String value, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
  }) {
    // FIRST STATEMENT, ahead of every allocation and every native call: a
    // refused congestion control must leave nothing allocated, nothing
    // consumed and nothing declared.
    requireCongestionControlSupported(congestionControl);
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    // Two INDEPENDENT length-carried channels (R-2), fed from the RAW pair
    // (R-3a) -- never the derived `schema` getter, which would split a
    // composed mimeType and change what goes on the wire.
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;
    // OUTER-FINALLY, the pattern deleteResource already uses. The release used
    // to live INSIDE the _withKeyExpr closure, which is never entered when the
    // session is closed (_withKeyExprArg's own _ensureOpen), the argument is
    // wrong-typed, or the key expression is invalid -- so both buffers leaked
    // on those paths, and on a ZBytes.fromString throw as well.
    try {
      _withKeyExprArg<void>(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
        final payload = ZBytes.fromString(value);
        final rc = bindings.zd_put(
          loanedSession.cast(),
          loanedKe.cast(),
          payload.nativePtr.cast(),
          encodingBuf.ptr,
          encodingBuf.len,
          schemaBuf.ptr,
          schemaBuf.len,
          attachmentPtr.cast(),
          tsPtr.cast(),
          congestionControl?.value ?? -1,
          priority?.value ?? -1,
          isExpress == null ? -1 : (isExpress ? 1 : 0),
          allowedDestination?.value ?? -1,
        );
        // markConsumed is unconditional: z_bytes_move gravestones the owned
        // bytes regardless of the return code. The timestamp is borrowed (not
        // moved) -- it is never marked consumed.
        payload.markConsumed();
        if (attachment != null) attachment.markConsumed();
        if (rc != 0) {
          throw ZenohException('Put failed', rc);
        }
      });
    } finally {
      // allocLengthCarriedUtf8 allocates with calloc, so it is released with
      // calloc.free -- not the malloc.free the retired toNativeUtf8 site used.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Publishes a [ZBytes] [payload] on the given [keyExpr].
  ///
  /// The payload is consumed by this call and must not be reused.
  /// Optionally set the [encoding] (MIME type) of the message. An optional
  /// [attachment] can be included; it is also consumed by this call. An
  /// optional [timestamp] can be attached to the message; borrowed, not
  /// consumed.
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress] and [allowedDestination] are
  /// each optional, and omitting one — or passing `null` — means the same
  /// thing: **canon decides**. This binding substitutes no value of its own.
  /// On this path canon's defaults are [CongestionControl.drop] (a *push*
  /// operation; `get` and `declareQuerier` default to [CongestionControl.block]
  /// instead), [Priority.data], `isExpress: false`, and [Locality.any].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// Throws [ZenohException] if the key expression is invalid, the encoding
  /// is malformed, or the put fails.
  /// Throws [StateError] if the session has been closed, or the payload or
  /// attachment has been disposed or already consumed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  ///
  /// ⚠️ **That refusal is raised BEFORE the session-closed check**, so a
  /// closed session carrying [CongestionControl.blockFirst] reports the
  /// argument fault rather than [StateError]. This is the only entry point
  /// where both can apply, and the build-configuration fault is the one
  /// nothing else in the program will ever report; a closed session is
  /// discoverable from any other call on it.
  void putBytes(
    Object keyExpr,
    ZBytes payload, {
    Encoding? encoding,
    ZBytes? attachment,
    Timestamp? timestamp,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
  }) {
    // FIRST STATEMENT, and that means AHEAD OF `_ensureOpen()` -- this is the
    // only one of the seven entry points carrying an explicit closed-session
    // check, so this is where the ordering is a choice rather than an
    // artefact of helper placement. A closed session is discoverable from any
    // other call on that session; a build-configuration fault is discoverable
    // from nothing else in the program, so where a call carries both, the
    // undiscoverable one is the one worth reporting. The alternative -- guard
    // after whatever state check happens to exist -- makes `put` and
    // `putBytes` answer differently on identical inputs, with the
    // discriminator invisible from the API.
    requireCongestionControlSupported(congestionControl);
    _ensureOpen();
    // Validate payload state before allocating KeyExpr
    final payloadPtr = payload.nativePtr;
    final attachmentPtr = attachment != null ? attachment.nativePtr : nullptr;
    // Two INDEPENDENT length-carried channels (R-2), fed from the RAW pair
    // (R-3a) -- never the derived `schema` getter, which would split a
    // composed mimeType and change what goes on the wire.
    final (mime, schema) = encoding != null
        ? encodingWireChannels(encoding)
        : (null, null);
    final encodingBuf = allocLengthCarriedUtf8(mime);
    final schemaBuf = allocLengthCarriedUtf8(schema);
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;
    // OUTER-FINALLY: a wrong-typed or invalid key expression throws inside
    // _withKeyExprArg before the closure runs, so the release could not sit
    // inside it.
    try {
      _withKeyExprArg<void>(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
        final rc = bindings.zd_put(
          loanedSession.cast(),
          loanedKe.cast(),
          payloadPtr.cast(),
          encodingBuf.ptr,
          encodingBuf.len,
          schemaBuf.ptr,
          schemaBuf.len,
          attachmentPtr.cast(),
          tsPtr.cast(),
          congestionControl?.value ?? -1,
          priority?.value ?? -1,
          isExpress == null ? -1 : (isExpress ? 1 : 0),
          allowedDestination?.value ?? -1,
        );
        // markConsumed is unconditional: z_bytes_move gravestones the owned
        // bytes regardless of the return code. The timestamp is borrowed (not
        // moved) -- it is never marked consumed.
        payload.markConsumed();
        if (attachment != null) attachment.markConsumed();
        if (rc != 0) {
          throw ZenohException('Put failed', rc);
        }
      });
    } finally {
      // allocLengthCarriedUtf8 allocates with calloc, so it is released with
      // calloc.free -- not the malloc.free the retired toNativeUtf8 site used.
      if (encodingBuf.ptr != nullptr) calloc.free(encodingBuf.ptr);
      if (schemaBuf.ptr != nullptr) calloc.free(schemaBuf.ptr);
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Deletes a resource on the given [keyExpr].
  ///
  /// An optional [timestamp] can be attached to the message; borrowed, not
  /// consumed.
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress] and [allowedDestination] are
  /// each optional, and omitting one — or passing `null` — means the same
  /// thing: **canon decides**. This binding substitutes no value of its own.
  /// On this path canon's defaults are [CongestionControl.drop] (a *push*
  /// operation; `get` and `declareQuerier` default to [CongestionControl.block]
  /// instead), [Priority.data], `isExpress: false`, and [Locality.any].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// Throws [ZenohException] if the key expression is invalid or the delete
  /// fails.
  /// Throws [StateError] if the session has been closed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  void deleteResource(
    Object keyExpr, {
    Timestamp? timestamp,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
  }) {
    // FIRST STATEMENT: ahead of the timestamp allocation and the key
    // expression's validation.
    requireCongestionControlSupported(congestionControl);
    final tsPtr = timestamp != null ? _timestampToNative(timestamp) : nullptr;
    try {
      _withKeyExprArg<void>(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
        final rc = bindings.zd_delete(
          loanedSession.cast(),
          loanedKe.cast(),
          tsPtr.cast(),
          congestionControl?.value ?? -1,
          priority?.value ?? -1,
          isExpress == null ? -1 : (isExpress ? 1 : 0),
          allowedDestination?.value ?? -1,
        );
        if (rc != 0) {
          throw ZenohException('Delete failed', rc);
        }
      });
    } finally {
      if (tsPtr != nullptr) calloc.free(tsPtr);
    }
  }

  /// Declares a publisher on the given [keyExpr].
  ///
  /// Returns a [Publisher] that can efficiently publish multiple messages
  /// to the same key expression. Call [Publisher.close] when done.
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress] and [allowedDestination] are
  /// each optional, and omitting one — or passing `null` — means the same
  /// thing: **canon decides**. This binding substitutes no value of its own.
  /// On this path canon's defaults are [CongestionControl.drop] (a *push*
  /// operation; `get` and `declareQuerier` default to [CongestionControl.block]
  /// instead), [Priority.data], `isExpress: false`, and [Locality.any].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  Publisher declarePublisher(
    Object keyExpr, {
    Encoding? encoding,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    bool enableMatchingListener = false,
  }) {
    // FIRST STATEMENT, and it is what keeps `publisher.dart:57` out of reach:
    // `Publisher.declare` callocs its entity handle BEFORE the marshal and
    // releases it only on the `rc != 0` branch, so a guard sited at the
    // marshal would strand that block on every refusal.
    requireCongestionControlSupported(congestionControl);
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      return Publisher.declare(
        loanedSession,
        loanedKe,
        encoding: encoding,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
        allowedDestination: allowedDestination,
        enableMatchingListener: enableMatchingListener,
      );
    });
  }

  /// Declares a querier on the given [keyExpr].
  ///
  /// Returns a [Querier] that can efficiently send multiple queries
  /// to the same key expression with pre-configured options.
  /// Call [Querier.close] when done.
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress], [allowedDestination] and
  /// [acceptReplies] are each optional, and omitting one — or passing `null` —
  /// means the same thing: **canon decides**. This binding substitutes no value
  /// of its own. On this path canon's defaults are [CongestionControl.block] (a
  /// *request* operation; `put`, `deleteResource` and `declarePublisher`
  /// default to [CongestionControl.drop] instead), [Priority.data],
  /// `isExpress: false`, [Locality.any], and [ReplyKeyExpr.matchingQuery].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// [target] controls which queryables are targeted (default: bestMatching).
  /// [consolidation] controls reply consolidation (default: auto).
  /// [timeout] sets the query timeout, fixed at declaration time for every
  /// [Querier.get] this querier sends. Omitting it means **canon decides**
  /// (the session's configured default, itself 10 seconds by default).
  ///
  /// ⚠️ **A [timeout] that marshals to 0 ms is refused with [ArgumentError]**,
  /// on the wire value rather than on `Duration.zero` identity — the same rule
  /// [get] carries, and for the same reason: zenoh reads wire `0` as *"use the
  /// configured default"*, so an instant-expiry request would silently become
  /// ~10 seconds. Canon's per-get options struct has no timeout field, so this
  /// declaration is the only place the value can be refused.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  Querier declareQuerier(
    Object keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    ReplyKeyExpr? acceptReplies,
    bool enableMatchingListener = false,
  }) {
    // FIRST STATEMENT, ahead of the timeout guard. Where an entry point
    // carries more than one refuse-first domain check the congestion one runs
    // first, and the order is stated rather than incidental: of the faults a
    // caller can trip at once, this is the only one no change to the call's
    // other arguments can fix. A zero timeout is expressible correctly by
    // choosing another number; blockFirst on a stable native is a property of
    // the build.
    requireCongestionControlSupported(congestionControl);
    // BEFORE any native call, including key-expression validation.
    _rejectSentinelTimeout(timeout);
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      return Querier.declare(
        loanedSession,
        loanedKe,
        keyExprString(keyExpr, 'keyExpr'),
        target: target,
        consolidation: consolidation,
        timeout: timeout,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
        allowedDestination: allowedDestination,
        acceptReplies: acceptReplies,
        enableMatchingListener: enableMatchingListener,
      );
    });
  }

  /// Declares a background subscriber on the given [keyExpr].
  ///
  /// Returns a [Stream] of [Sample]s. Unlike [declareSubscriber], the
  /// background subscriber has no handle and cannot be explicitly closed.
  /// It lives until the session is closed, at which point the stream
  /// completes automatically.
  ///
  /// [allowedOrigin] restricts whose traffic this declaration accepts.
  /// Omitting it — or passing `null` — means **canon decides**, which is
  /// [Locality.any]. See [Locality].
  ///
  /// ⚠️ **This stream is UNBOUNDED, and pausing it does not stop the flow** —
  /// see [declareSubscriber] for the measurement. **There is deliberately no
  /// bounded form of this surface**: a background declaration hands back no
  /// handle, so there is nothing to close and nothing to pace it with. That is
  /// a carve-out, not an oversight. Use [declarePullSubscriber] when you need
  /// a bound.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Stream<Sample> declareBackgroundSubscriber(
    Object keyExpr, {
    Locality? allowedOrigin,

    /// See [declareSubscriber] for what `retainPayload` costs and promises.
    bool retainPayload = false,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: the channel is created only once the key expression has
      // been accepted, so a rejected one cannot strand an open ReceivePort.
      final channel = Subscriber.createSampleChannel(
        retainPayload: retainPayload,
      );
      final rc = bindings.zd_declare_background_subscriber(
        loanedSession.cast(),
        loanedKe.cast(),
        channel.receivePort.sendPort.nativePort,
        allowedOrigin?.value ?? -1,
        retainPayload ? 1 : 0,
      );

      if (rc != 0) {
        channel.abandon();
        throw ZenohException('Failed to declare background subscriber', rc);
      }

      return channel.stream;
    });
  }

  /// Declares a subscriber on the given [keyExpr].
  ///
  /// Returns a [Subscriber] whose [Subscriber.stream] delivers [Sample]s.
  /// Call [Subscriber.close] when done to undeclare and release resources.
  ///
  /// ⚠️ **This stream is UNBOUNDED, and pausing it does not stop the flow.**
  /// Arrivals are pushed into a `StreamController` as they land, so a paused
  /// or slow consumer accumulates them without limit — `pause()` throttles
  /// delivery to *your listener*, never the producer, and nothing in this
  /// package wires the gate callbacks that would.
  ///
  /// Measured on the shipped package, two OS processes over TCP, 64 MiB
  /// posted into a listener paused before any traffic: resident memory grew
  /// by **154 MiB** on this surface, against **3 MiB** for the bounded
  /// alternative on the same load.
  ///
  /// For a bounded consumer use [Session.declarePullSubscriber] and its
  /// [PullSubscriber.stream]: it pulls one sample at a time out of a bounded
  /// native channel and only while the subscription is demanding, so what
  /// accumulates is the channel's own `capacity` plus at most one
  /// already-pulled sample. What happens to the traffic that does not fit is
  /// the channel's [ChannelKind] — [ChannelKind.ring] drops and keeps the
  /// publisher running, [ChannelKind.fifo] holds the publisher back.
  ///
  /// [allowedOrigin] restricts whose traffic this declaration accepts.
  /// Omitting it — or passing `null` — means **canon decides**, which is
  /// [Locality.any]. See [Locality].
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  /// [retainPayload] makes every delivered sample carry an owned
  /// [Sample.payloadZBytes] handle on its payload, so it can be republished
  /// without copying or asked what backs it. **Off by default** — nothing pays
  /// for retention that did not ask for it — and [Sample.payloadBytes] is
  /// unchanged either way. ⛔ A retained handle is the caller's to release.
  Subscriber declareSubscriber(
    Object keyExpr, {
    Locality? allowedOrigin,
    bool retainPayload = false,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      return Subscriber.declare(
        loanedSession,
        loanedKe,
        keyExpr: keyExprString(keyExpr, 'keyExpr'),
        allowedOrigin: allowedOrigin,
        retainPayload: retainPayload,
      );
    });
  }

  /// Declares a queryable whose queries land in a **bounded channel** instead
  /// of a stream, and returns a [PullQueryable] to take them out of.
  ///
  /// The channel-mode sibling of [declareQueryable], carrying its identical
  /// option surface. Where [declareQueryable] pushes every query into a stream
  /// as it arrives and buffers without bound, this holds at most [capacity]
  /// queries and lets the consumer set the pace.
  ///
  /// [kind] and [capacity] are **required**, deliberately: canon forces the
  /// caller to choose both, so this binding substitutes no value canon does not
  /// have.
  ///
  /// The release is [PullQueryable.close], not `dispose` — it undeclares, and
  /// getters stop reaching this queryable.
  ///
  /// ## ⚠️ Never let a same-session getter meet a full fifo channel
  ///
  /// **Measured at zenoh-c 1.8.0.** On a same-session route the query delivery
  /// runs *synchronously inside the getter's own `z_get` call*, so a fifo
  /// channel that has filled up freezes that call inside the FFI boundary with
  /// no timeout escape — and that includes the existing Stream-path [get] on
  /// the same session, not just this handle's own consumers. Use a second
  /// session for the getter, or [ChannelKind.ring].
  ///
  /// Across two sessions the getter is never the blocked party: its call
  /// returns, and the queries queue until this channel is drained. **Measured
  /// here:** an ordinary Stream-path [declareQueryable] co-hosted on the same
  /// session keeps answering while this channel sits full, at every capacity
  /// and depth probed — so a full channel is not, on this binding's measured
  /// behaviour, a session-wide stall. **Canon-direct measurement reports the
  /// opposite** — inbound query delivery stalling session-wide while a fifo
  /// query channel sits full — and that did not reproduce through this stack at
  /// any capacity or depth probed, so treat the favourable behaviour above as
  /// what this binding measured rather than as a guarantee. Size the capacity
  /// for the slowest consumer you will actually run all the same: what queues
  /// has to be held somewhere.
  ///
  /// ## ⚠️ A ring channel drops the oldest query
  ///
  /// Remotely that getter simply gets nothing — its stream completes with no
  /// reply at all. Lossy is the trade a ring makes to never stall the producer.
  ///
  /// ⚠️ **This used to say "that is the dropped getter's timeout: it waited and
  /// got nothing", and the mechanism half is MEASURED FALSE.** The dropped
  /// getter does not wait and does not time out: measured at ~1 ms, finalized
  /// with nothing, while getters still resident in the channel waited for the
  /// close. The conclusion ("got nothing") was right; the route to it was not.
  /// Pinned in `test/fifo_close_window_test.dart`, "the same window on a ring
  /// query channel is the control". Buffered
  /// queries are also **discarded** when the channel disconnects — a fifo hands
  /// its buffer over first, a ring does not.
  ///
  /// ## Capacity 0
  ///
  /// **Measured** on this column: at capacity 0 both kinds hand a query over
  /// under polling and the getter gets its reply. That is not the reply
  /// column's picture — see [pullGet] — because across two sessions the getter
  /// is never the blocked party here.
  ///
  /// Throws [ArgumentError] if [capacity] is negative.
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  PullQueryable declarePullQueryable(
    Object keyExpr, {
    required ChannelKind kind,
    required int capacity,
    bool complete = false,
    Locality? allowedOrigin,
  }) {
    // BEFORE ANY NATIVE CALL: a negative is outside canon's `size_t` domain
    // entirely, and the carriage would otherwise reinterpret it as an enormous
    // unsigned capacity -- a silent transform, not a refusal. No upper bound is
    // invented.
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be non-negative');
    }
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: both slots are claimed only after the key expression has
      // been accepted, so a rejected one cannot strand them.
      final queryableHandle = calloc<Uint8>(bindings.zd_queryable_sizeof());
      // The two handler types are distinct, so the slot is sized for the kind
      // we are about to declare -- and released through the same kind.
      final handlerHandle = calloc<Uint8>(
        bindings.zd_query_handler_sizeof(kind.value),
      );
      // The readiness channel behind `PullQueryable.recv()`: an int64 ping when
      // an armed waiter should look again, and a null sentinel from the
      // closure's drop when the producer is gone.
      final receivePort = ReceivePort();
      // Our out-cell for a SHIM-owned block. The cell is ours; the block is the
      // shim's, released through `zd_pull_tee_drop`.
      final teeOut = calloc<Pointer<Uint8>>();

      final rc = bindings.zd_declare_queryable_channel(
        queryableHandle,
        handlerHandle,
        teeOut,
        receivePort.sendPort.nativePort,
        loanedSession.cast(),
        loanedKe.cast(),
        kind.value,
        capacity,
        complete ? 1 : 0,
        allowedOrigin?.value ?? -1,
      );
      final teeValue = teeOut.value;
      calloc.free(teeOut);

      if (rc != 0) {
        receivePort.close();
        calloc
          ..free(queryableHandle)
          ..free(handlerHandle);
        // The declare channel's return space is SPLIT, mapped here, once, at
        // the single call site -- the same split the pull subscriber ships.
        if (rc == 10) {
          throw ArgumentError.value(
            capacity,
            'capacity',
            "must be non-negative and within this platform's size_t range",
          );
        }
        if (rc == 11) {
          throw ZenohException('Failed to allocate query channel state', rc);
        }
        throw ZenohException('Failed to declare pull queryable', rc);
      }

      return PullQueryable(
        queryableHandle,
        handlerHandle,
        teeValue,
        receivePort,
        keyExprString(keyExpr, 'keyExpr'),
        kind,
      );
    });
  }

  /// Declares a pull subscriber on the given [keyExpr].
  ///
  /// Returns a [PullSubscriber] that buffers samples in a bounded channel of
  /// the given [kind] and [capacity]. Use [PullSubscriber.tryRecv] to poll
  /// without waiting. Call [PullSubscriber.close] when done.
  ///
  /// [kind] chooses what happens when the buffer fills:
  /// [ChannelKind.ring] (the default) drops the oldest sample and never
  /// blocks the publisher; [ChannelKind.fifo] keeps every sample and blocks
  /// the publisher instead.
  ///
  /// ⚠️ **Never publish into a full fifo from this same session.** The
  /// delivery happens on the publisher's own thread, so one thread acting as
  /// both producer and only consumer blocks inside the put permanently —
  /// measured at zenoh-c 1.8.0 and unrecoverable, because the call is a
  /// synchronous FFI call. Use a second session for the publisher, or
  /// [ChannelKind.ring]. See [ChannelKind.fifo].
  ///
  /// The kinds also differ at the END of the channel's life, and the
  /// difference is canon's own: when the producer dies, a fifo hands over the
  /// samples it still holds before reporting disconnected, while a ring
  /// discards them. Either way the drain window closes at
  /// [PullSubscriber.close] — **drain only if the residue matters.**
  ///
  /// ⚠️ **That used to read "drain before you close", and it silently carried a
  /// CORRECTNESS claim it could not honour** — closing an undrained,
  /// overflowing fifo once hung the calling isolate permanently. Fixed at the
  /// source; and draining could never have prevented it from one isolate
  /// anyway. **What still matters is the teardown ORDER:** close the pull
  /// handle *before* closing its session when a fifo may be in overflow. A
  /// session closed first still stalls — a measured residual of canon's own
  /// session teardown that this binding does not fix.
  ///
  /// [capacity] is the channel's bound. Both this and [kind] are
  /// **binding-decided defaults**, not canon's: canon forces the caller to
  /// choose both — its constructors take a raw `size_t` and there is no
  /// options-default to defer to — so there is no "canon decides" value that
  /// omitting them could mean. [ChannelKind.ring] preserves every existing
  /// caller's behaviour byte-for-byte and matches canon's own `z_pull.c`;
  /// 256 is the shipped default, unchanged.
  ///
  /// A capacity of 0 declares and delivers on both kinds — **measured at
  /// zenoh-c 1.8.0, not promised by canon**, which documents nothing about
  /// capacity anywhere. ⚠️ On [ChannelKind.fifo], capacity 0 is a
  /// *rendezvous* rather than a one-slot buffer, so
  /// [PullSubscriber.tryRecv] works there but [PullSubscriber.recv] cannot —
  /// see [PullSubscriber.recv].
  ///
  /// [allowedOrigin] restricts whose traffic this declaration accepts.
  /// Omitting it — or passing `null` — means **canon decides**, which is
  /// [Locality.any]. See [Locality].
  ///
  /// Throws [ArgumentError] if [capacity] is negative, or too large for this
  /// target's `size_t` — outside canon's domain, refused rather than
  /// silently transformed.
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  PullSubscriber declarePullSubscriber(
    Object keyExpr, {
    ChannelKind kind = ChannelKind.ring,
    int capacity = 256,
    Locality? allowedOrigin,

    /// Whether each pulled sample carries a retained
    /// [Sample.payloadZBytes]. Off by default.
    bool retainPayload = false,
  }) {
    // BEFORE ANY NATIVE CALL. A negative is outside canon's `size_t` domain
    // entirely, and the carriage would otherwise reinterpret it as an
    // enormous unsigned capacity -- a silent transform, not a refusal.
    //
    // `ArgumentError`, not `ZenohException`: nothing in zenoh failed here.
    // The caller passed a value canon has no way to represent, and canon was
    // never asked. (The shim carries the same check as a structural
    // backstop, plus the `> SIZE_MAX` half that only an ILP32 target can
    // reach; a 64-bit Dart int cannot exceed a 64-bit `size_t`, so this side
    // has only the one boundary to guard.)
    //
    // No upper bound is invented. Rejecting a large-but-representable
    // capacity would narrow canon's surface on no canon-intrinsic ground --
    // the same reasoning that keeps zero.
    if (capacity < 0) {
      throw ArgumentError.value(
        capacity,
        'capacity',
        'must be non-negative',
      );
    }
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: both slots are claimed only after the key expression
      // has been accepted. They used to be claimed before it, so a rejected
      // key expression stranded them.
      final subscriberHandle = calloc<Uint8>(bindings.zd_subscriber_sizeof());
      // The two handler types are distinct, so the slot is sized for the kind
      // we are about to declare -- and released through the same kind.
      final handlerHandle = calloc<Uint8>(
        bindings.zd_pull_handler_sizeof(kind.value),
      );
      // The readiness channel behind `PullSubscriber.recv()`. The shim posts
      // an int64 ping when an armed waiter should look again, and a null
      // sentinel from the closure's drop when the producer is gone.
      final receivePort = ReceivePort();
      // Our out-cell for a SHIM-owned block: the shim mallocs the tee context
      // and `zd_pull_tee_drop` frees it. This cell is ours, and the outer
      // `finally` below encloses every statement that can throw.
      final teeOut = calloc<Pointer<Uint8>>();

      try {
        final rc = bindings.zd_declare_pull_subscriber(
          subscriberHandle,
          handlerHandle,
          teeOut,
          loanedSession.cast(),
          loanedKe.cast(),
          kind.value,
          capacity,
          allowedOrigin?.value ?? -1,
          receivePort.sendPort.nativePort,
        );

        if (rc != 0) {
          receivePort.close();
          calloc
            ..free(subscriberHandle)
            ..free(handlerHandle);
          // The declare channel's return space is SPLIT, and it is mapped
          // here, once, at the single call site. Positives are the shim's own
          // -- they start at 10 because canon owns 0-and-negative on this
          // channel and a shim-owned -1 would let a canon EINVAL masquerade
          // as our failure. Negatives are canon's, passed through with
          // canon's own code.
          if (rc == 10) {
            throw ArgumentError.value(
              capacity,
              'capacity',
              "must be non-negative and within this platform's size_t range",
            );
          }
          if (rc == 11) {
            throw ZenohException(
              'Failed to allocate pull subscriber state',
              rc,
            );
          }
          throw ZenohException('Failed to declare pull subscriber', rc);
        }

        return PullSubscriber(
          subscriberHandle,
          handlerHandle,
          teeOut.value,
          receivePort,
          keyExprString(keyExpr, 'keyExpr'),
          kind,
          retainPayload,
        );
      } finally {
        calloc.free(teeOut);
      }
    });
  }

  /// Declares a liveliness subscriber whose transitions land in a **bounded
  /// channel**, and returns the shipped [PullSubscriber] to take them out of.
  ///
  /// The channel-mode sibling of [declareLivelinessSubscriber]. It delivers the
  /// alive/gone **transitions** as samples — [SampleKind.put] when a token
  /// appears, [SampleKind.delete] when it goes — which is a different
  /// capability from [livelinessGet]'s snapshot of who is alive now.
  ///
  /// This is the thinnest of the channel-mode entries: canon's liveliness
  /// declare consumes the sample closure, so the handle, the machinery and the
  /// contracts are the pull subscriber's, unchanged.
  ///
  /// [kind] and [capacity] are **required**, deliberately — canon forces the
  /// caller to choose both. ([declarePullSubscriber] defaults them only to keep
  /// every pre-existing caller's behaviour byte-for-byte; new surface has no
  /// such debt.)
  ///
  /// [history] replays tokens that were already alive when this subscriber was
  /// declared. It is canon's only option on this entry.
  ///
  /// ## ⚠️ Think twice before choosing [ChannelKind.ring] here
  ///
  /// A ring drops the oldest entry when it fills, and on a *presence* feed the
  /// dropped entry may be a token-gone transition — which does not merely lose
  /// data, it **inverts the consumer's world-state**: you go on believing
  /// something is alive that has gone. That is a sharper edge than losing a
  /// sample on an ordinary data feed, and it is the reason to prefer
  /// [ChannelKind.fifo] unless you have a specific reason not to.
  ///
  /// Throws [ArgumentError] if [capacity] is negative.
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  PullSubscriber declarePullLivelinessSubscriber(
    Object keyExpr, {
    required ChannelKind kind,
    required int capacity,
    bool history = false,

    /// Whether each pulled sample carries a retained
    /// [Sample.payloadZBytes]. Off by default.
    bool retainPayload = false,
  }) {
    // BEFORE ANY NATIVE CALL: a negative would otherwise be reinterpreted as an
    // enormous unsigned capacity -- a silent transform, not a refusal.
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be non-negative');
    }
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: claimed only after the key expression has been accepted.
      final subscriberHandle = calloc<Uint8>(bindings.zd_subscriber_sizeof());
      final handlerHandle = calloc<Uint8>(
        bindings.zd_pull_handler_sizeof(kind.value),
      );
      final receivePort = ReceivePort();
      final teeOut = calloc<Pointer<Uint8>>();

      try {
        final rc = bindings.zd_declare_pull_liveliness_subscriber(
          subscriberHandle,
          handlerHandle,
          teeOut,
          loanedSession.cast(),
          loanedKe.cast(),
          kind.value,
          capacity,
          history ? 1 : 0,
          receivePort.sendPort.nativePort,
        );

        if (rc != 0) {
          receivePort.close();
          calloc
            ..free(subscriberHandle)
            ..free(handlerHandle);
          // The declare channel's SPLIT return space, mapped here once.
          if (rc == 10) {
            throw ArgumentError.value(
              capacity,
              'capacity',
              "must be non-negative and within this platform's size_t range",
            );
          }
          if (rc == 11) {
            throw ZenohException(
              'Failed to allocate pull liveliness subscriber state',
              rc,
            );
          }
          throw ZenohException(
            'Failed to declare pull liveliness subscriber',
            rc,
          );
        }

        return PullSubscriber(
          subscriberHandle,
          handlerHandle,
          teeOut.value,
          receivePort,
          keyExprString(keyExpr, 'keyExpr'),
          kind,
          retainPayload,
        );
      } finally {
        calloc.free(teeOut);
      }
    });
  }

  /// Declares a queryable on the given [keyExpr].
  ///
  /// Returns a [Queryable] whose [Queryable.stream] delivers [Query]s.
  /// Call [Queryable.close] when done to undeclare and release resources.
  ///
  /// [allowedOrigin] restricts whose traffic this declaration accepts.
  /// Omitting it — or passing `null` — means **canon decides**, which is
  /// [Locality.any]. See [Locality].
  ///
  /// The [complete] parameter indicates whether this queryable is a
  /// complete source of data for its key expression (default: false).
  ///
  /// ⚠️ **The returned [Queryable.stream] is UNBOUNDED, and pausing it does
  /// not stop the flow** — and on this column the cost is native as well as
  /// Dart-side: every buffered query holds a `z_owned_query_t` clone open
  /// until it is disposed. Measured: a paused push queryable retained all
  /// **64** queries fired at it, against **9** for the bounded alternative at
  /// `capacity: 8`.
  ///
  /// For a bounded consumer use [declarePullQueryable] and its
  /// [PullQueryable.stream].
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Queryable declareQueryable(
    Object keyExpr, {
    bool complete = false,
    Locality? allowedOrigin,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      return Queryable.declare(
        loanedSession,
        loanedKe,
        keyExprString(keyExpr, 'keyExpr'),
        complete: complete,
        allowedOrigin: allowedOrigin,
      );
    });
  }

  /// Declares a fire-and-forget background queryable on the given [keyExpr].
  ///
  /// Returns a [Stream] of [Query]s. Delivered queries are fully replyable and
  /// disposable, exactly like those from [declareQueryable]. Unlike
  /// [declareQueryable], the background queryable has no handle and cannot be
  /// explicitly closed. It lives until the session is closed, at which point
  /// the stream completes automatically.
  ///
  /// The [complete] parameter indicates whether this queryable is a complete
  /// source of data for its key expression (default: false).
  ///
  /// [allowedOrigin] restricts whose traffic this declaration accepts.
  /// Omitting it — or passing `null` — means **canon decides**, which is
  /// [Locality.any]. See [Locality].
  ///
  /// ⚠️ **This stream is UNBOUNDED, and pausing it does not stop the flow** —
  /// see [declareQueryable], including the native cost of a retained query
  /// clone. **No bounded form of this surface exists**: a background
  /// declaration hands back no handle. Use [declarePullQueryable] when you
  /// need a bound.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Stream<Query> declareBackgroundQueryable(
    Object keyExpr, {
    bool complete = false,
    Locality? allowedOrigin,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: the channel is created only once the key expression has
      // been accepted, so a rejected one cannot strand an open ReceivePort.
      final channel = QueryChannel.create();
      final rc = bindings.zd_declare_background_queryable(
        loanedSession.cast(),
        loanedKe.cast(),
        channel.receivePort.sendPort.nativePort,
        complete ? 1 : 0,
        allowedOrigin?.value ?? -1,
      );

      if (rc != 0) {
        channel.abandon();
        throw ZenohException('Failed to declare background queryable', rc);
      }

      return channel.stream;
    });
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
  /// ⚠️ **This stream is UNBOUNDED, and pausing it does not stop the flow.**
  /// Arrivals are pushed into a `StreamController` as they land, so a paused
  /// or slow consumer accumulates them without limit — `pause()` throttles
  /// delivery to *your listener*, never the producer, and nothing in this
  /// package wires the gate callbacks that would.
  ///
  /// Measured on the shipped package, two OS processes over TCP, 64 MiB
  /// posted into a listener paused before any traffic: resident memory grew
  /// by **154 MiB** on this surface, against **3 MiB** for the bounded
  /// alternative on the same load.
  ///
  /// For a bounded consumer use [declarePullLivelinessSubscriber] and its
  /// [PullSubscriber.stream] — the same mechanism, reached through the shared
  /// return type at no extra cost.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Subscriber declareLivelinessSubscriber(
    Object keyExpr, {
    bool history = false,

    /// See [declareSubscriber] for what `retainPayload` costs and promises.
    bool retainPayload = false,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: the slot and the channel are claimed only once the key
      // expression has been accepted.
      final ptr = calloc.allocate<Void>(bindings.zd_subscriber_sizeof());
      final channel = Subscriber.createSampleChannel(
        retainPayload: retainPayload,
      );

      final rc = bindings.zd_liveliness_declare_subscriber(
        ptr.cast(),
        loanedSession.cast(),
        loanedKe.cast(),
        channel.receivePort.sendPort.nativePort,
        history ? 1 : 0,
        retainPayload ? 1 : 0,
      );

      if (rc != 0) {
        channel.abandon();
        calloc.free(ptr);
        throw ZenohException('Failed to declare liveliness subscriber', rc);
      }

      return Subscriber.fromParts(
        ptr,
        channel,
        keyExprString(keyExpr, 'keyExpr'),
      );
    });
  }

  /// Declares a fire-and-forget background subscriber on liveliness tokens
  /// intersecting [keyExpr].
  ///
  /// Returns a [Stream] of [Sample]s: a [SampleKind.put] when a liveliness
  /// token is declared and a [SampleKind.delete] when it is undeclared or
  /// lost. Unlike [declareLivelinessSubscriber], there is no handle; the
  /// stream completes automatically when this session is closed.
  ///
  /// If [history] is true, the subscriber also replays liveliness tokens that
  /// were already alive before the subscription was declared.
  ///
  /// ⚠️ **This stream is UNBOUNDED, and pausing it does not stop the flow** —
  /// see [declareSubscriber] for the measurement. **No bounded form exists
  /// here either**, and for the same reason: a background declaration hands
  /// back no handle. Use [declarePullLivelinessSubscriber] when you need a
  /// bound.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Stream<Sample> declareBackgroundLivelinessSubscriber(
    Object keyExpr, {
    bool history = false,

    /// See [declareSubscriber] for what `retainPayload` costs and promises.
    bool retainPayload = false,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: no open ReceivePort survives a rejected key expression.
      final channel = Subscriber.createSampleChannel(
        retainPayload: retainPayload,
      );

      final rc = bindings.zd_liveliness_declare_background_subscriber(
        loanedSession.cast(),
        loanedKe.cast(),
        channel.receivePort.sendPort.nativePort,
        history ? 1 : 0,
        retainPayload ? 1 : 0,
      );

      if (rc != 0) {
        channel.abandon();
        throw ZenohException(
          'Failed to declare background liveliness subscriber',
          rc,
        );
      }

      return channel.stream;
    });
  }

  /// Declares a liveliness token on the given [keyExpr].
  ///
  /// The token advertises this session's presence on the key expression
  /// for as long as it remains undeclared. Call [LivelinessToken.close]
  /// when done.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  LivelinessToken declareLivelinessToken(Object keyExpr) {
    return _withKeyExprArg(
      keyExpr,
      'keyExpr',
      (loanedSession, loanedKe) => LivelinessToken.declare(
        loanedSession,
        loanedKe,
        keyExprString(keyExpr, 'keyExpr'),
      ),
    );
  }

  /// Queries liveliness tokens matching the given [keyExpr].
  ///
  /// Returns a [Stream] of [Reply] objects for each alive token. The stream
  /// completes when all replies have been received or the [timeout] expires.
  /// Defaults to 10 seconds if [timeout] is not specified — sent explicitly,
  /// not deferred to zenoh.
  ///
  /// Unlike [get] and [declareQuerier], **a zero [timeout] is accepted here**.
  /// The asymmetry is deliberate and measured: a liveliness query completes as
  /// soon as the reachable peers have answered (0–2 ms in every configuration
  /// probed, with or without an alive token), so the timeout never bites and a
  /// zero value changes nothing observable — an alive token's reply still
  /// arrives. There is therefore no silent substitution to refuse, and
  /// refusing anyway would invent a restriction with nothing behind it.
  ///
  /// ⚠️ **The returned stream is UNBOUNDED, and pausing it does not stop the
  /// flow.** Replies are pushed in as they arrive; `pause()` throttles
  /// delivery to your listener, not the responders.
  ///
  /// [pullLivelinessGet] is the paced alternative — a bounded [PullReplies]
  /// handle you poll. It offers no `Stream` view; see [get].
  ///
  /// Throws [ZenohException] if the key expression is invalid or the query
  /// fails.
  /// Throws [StateError] if the session has been closed.
  Stream<Reply> livelinessGet(
    Object keyExpr, {
    Duration? timeout,

    /// Whether each OK reply's sample carries a retained
    /// [Sample.payloadZBytes]. Off by default.
    bool retainPayload = false,
  }) {
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: no open ReceivePort survives a rejected key expression.
      final (receivePort, controller, retention) = _createReplyChannel(
        retainPayload: retainPayload,
      );
      final timeoutMs = (timeout ?? const Duration(seconds: 10)).inMilliseconds;

      final rc = bindings.zd_liveliness_get(
        loanedSession.cast(),
        loanedKe.cast(),
        receivePort.sendPort.nativePort,
        timeoutMs,
        retainPayload ? 1 : 0,
      );

      if (rc != 0) {
        receivePort.close();
        unawaited(controller.close());
        throw ZenohException('Liveliness get failed', rc);
      }

      return retention.gate(controller.stream);
    });
  }

  /// Queries liveliness tokens, with replies landing in a **bounded channel**
  /// instead of a stream.
  ///
  /// The channel-mode sibling of [livelinessGet], carrying its identical option
  /// surface. [kind] and [capacity] are required, deliberately — canon forces
  /// the caller to choose both.
  ///
  /// The handle's release is [PullReplies.dispose]: local only, because the
  /// query still runs to completion natively.
  ///
  /// A zero [timeout] is accepted here for the same measured reason it is on
  /// [livelinessGet] — see there.
  ///
  /// ⚠️ A ring channel recovers nothing once the query has completed, and a
  /// liveliness get completes almost immediately, so poll a ring one *in
  /// flight* or use [ChannelKind.fifo].
  ///
  /// Throws [ArgumentError] if [capacity] is negative.
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  PullReplies pullLivelinessGet(
    Object keyExpr, {
    required ChannelKind kind,
    required int capacity,
    Duration? timeout,

    /// Whether each pulled OK reply carries a retained
    /// [Sample.payloadZBytes]. Off by default; the ERROR arm never does.
    bool retainPayload = false,
  }) {
    // BEFORE ANY NATIVE CALL, for the same reason as everywhere else on this
    // axis: a negative would be reinterpreted as an enormous unsigned capacity.
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be non-negative');
    }
    return _withKeyExprArg(keyExpr, 'keyExpr', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: claimed only after the key expression has been accepted.
      final handlerHandle = calloc<Uint8>(
        bindings.zd_reply_handler_sizeof(kind.value),
      );
      final receivePort = ReceivePort();
      final teeOut = calloc<Pointer<Uint8>>();

      final rc = bindings.zd_liveliness_get_channel(
        handlerHandle,
        teeOut,
        receivePort.sendPort.nativePort,
        loanedSession.cast(),
        loanedKe.cast(),
        kind.value,
        capacity,
        (timeout ?? const Duration(seconds: 10)).inMilliseconds,
      );
      final teeValue = teeOut.value;
      calloc.free(teeOut);

      if (rc != 0) {
        receivePort.close();
        calloc.free(handlerHandle);
        if (rc == 10) {
          throw ArgumentError.value(
            capacity,
            'capacity',
            "must be non-negative and within this platform's size_t range",
          );
        }
        if (rc == 11) {
          throw ZenohException('Failed to allocate reply channel state', rc);
        }
        throw ZenohException('Liveliness get failed', rc);
      }

      return PullReplies(
        handlerHandle,
        teeValue,
        receivePort,
        kind,
        retainPayload,
      );
    });
  }

  /// Sends a query on the given [selector] and returns a stream of replies.
  ///
  /// The returned stream completes when all replies have been received
  /// or the timeout expires. When [timeout] is null, the query uses the
  /// default query timeout from the session's zenoh configuration
  /// (`queries_default_timeout`, itself 10 seconds by default) — passing
  /// wire `0`, matching zenoh-c's `GetOptions.timeout_ms == 0` semantics.
  ///
  /// ⚠️ **A [timeout] that marshals to 0 ms is refused with [ArgumentError].**
  /// Zenoh reads wire `0` as *"use the configured default"*, so `Duration.zero`
  /// — which every reasonable reading takes to mean "expire immediately" —
  /// would silently become ~10 seconds. The check is on the **wire value**, so
  /// a positive sub-millisecond duration such as `Duration(microseconds: 500)`
  /// is refused too: its `inMilliseconds` truncates onto the same sentinel.
  /// Pass at least 1 ms, or omit [timeout] to let zenoh decide explicitly.
  /// [declareQuerier] carries the identical rule; [livelinessGet] deliberately
  /// does not — see there.
  ///
  /// Optional [parameters] are the selector's portion after `?`. They are
  /// carried **length-first**, so an interior NUL is a value rather than a
  /// terminator; canon requires the string to be valid UTF-8. Omitting them and
  /// passing `''` are indistinguishable at the queryable — canon collapses the
  /// two before any wire encoding.
  /// Optional [payload], [encoding], and [attachment] attach data to the query.
  /// [target] controls which queryables are targeted (default: bestMatching).
  /// [consolidation] controls reply consolidation (default: auto).
  ///
  /// ### Send options
  ///
  /// [congestionControl], [priority], [isExpress], [allowedDestination] and
  /// [acceptReplies] are each optional, and omitting one — or passing `null` —
  /// means the same thing: **canon decides**. This binding substitutes no value
  /// of its own. On this path canon's defaults are [CongestionControl.block] (a
  /// *request* operation; `put`, `deleteResource` and `declarePublisher`
  /// default to [CongestionControl.drop] instead), [Priority.data],
  /// `isExpress: false`, [Locality.any], and [ReplyKeyExpr.matchingQuery].
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block]:
  /// it can park the calling thread for seconds and then close the transport.
  ///
  /// ⚠️ **The returned stream is UNBOUNDED, and pausing it does not stop the
  /// flow.** Replies are pushed in as they arrive; `pause()` throttles
  /// delivery to your listener, not the responders.
  ///
  /// [pullGet] is the paced alternative: it returns a [PullReplies] handle
  /// over a bounded channel that you poll. ⚠️ Note it offers **no `Stream`
  /// view** — the bounded-`Stream` mechanism is deliberately carved to the
  /// sample and query columns, so on the reply column the bounded form is the
  /// polling handle and nothing else.
  ///
  /// ⚠️ **A value this binding cannot convert arrives as a STREAM ERROR, never
  /// as empty or absent data.** Zenoh can hand over a payload or attachment
  /// the conversion step refuses; delivering that as a zero-length value would
  /// be indistinguishable from a legitimately empty one, and empty is a real
  /// value on this path. The error carries canon's own code.
  ///
  /// ⛔ **The stream keeps running.** A conversion failure is a failed *call*,
  /// not a dead channel — the same rule the pull family already ships — so
  /// later values still arrive and terminating on the first bad one would
  /// lose them. ⚠️ But an unhandled stream error is still an unhandled error:
  /// pass `onError` (or `handleError`), because an unhandled one can take the
  /// program down.
  ///
  /// Throws [StateError] if the session has been closed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  Stream<Reply> get(
    Object selector, {
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    ReplyKeyExpr? acceptReplies,

    /// Whether each OK reply's sample carries a retained
    /// [Sample.payloadZBytes]. Off by default; see [declareSubscriber] for
    /// what retention costs and promises.
    /// The ERROR arm is unaffected: `ReplyError` gets no retained handle.
    bool retainPayload = false,
  }) {
    // FIRST STATEMENT, ahead of the timeout guard -- the stated order,
    // congestion before timeout. It matters here for a second reason too:
    // this method returns its Stream synchronously, so a refusal raised after
    // the ReceivePort below would leave a port NO native sentinel can ever
    // close, pinning the isolate alive.
    requireCongestionControlSupported(congestionControl);
    // BEFORE any native call, including the selector validation below: a
    // refused timeout must leave nothing declared and no ReceivePort open.
    _rejectSentinelTimeout(timeout);
    // The selector is validated exactly ONCE, in the union dispatch, and its
    // temp KeyExpr is disposed before this returns. It used to be validated
    // twice -- here and again inside zd_get -- because the Dart caller cannot
    // tell a pre-move rc from a post-move one, and the markConsumed discipline
    // depends on that distinction: a rejected selector must throw WITHOUT
    // marking payload/attachment consumed, mirroring put/putBytes. Validating
    // in the dispatch, before anything is moved, preserves that exactly.
    return _withKeyExprArg(selector, 'selector', (loanedSession, loanedKe) {
      final (receivePort, controller, retention) = _createReplyChannel(
        retainPayload: retainPayload,
      );
      // Wire 0 means "use the config default query timeout"
      // (zenoh_commons.h:1039; C++ peer GetOptions.timeout_ms defaults to 0,
      // session.hxx:299). Mirror querier.dart:65 rather than substituting a
      // hardcoded default.
      final timeoutMs = timeout != null ? timeout.inMilliseconds : 0;

      // `started` gates the channel teardown in the finally. Every throw
      // between here and a successful zd_get leaves a ReceivePort that NO
      // native sentinel can ever close -- zd_get either never ran or failed --
      // and an open port pins the isolate alive. The reachable trigger is a
      // disposed or already-consumed payload/attachment: their nativePtr
      // getters throw StateError partway through building the call.
      var started = false;
      // LENGTH-CARRIED, not NUL-terminated: the parameters segment's domain
      // includes an interior NUL, so a C string would truncate it at the seam.
      Pointer<Char> parametersNative = nullptr;
      var parametersLen = 0;
      // The encoding joins parameters on the length-carried side of this same
      // signature -- the asymmetry inside it (parameters length-carried, the
      // encoding a bare C string four lines below) is what this seed removes.
      // Two INDEPENDENT channels, from the RAW pair (R-3a).
      Pointer<Char> encodingNative = nullptr;
      var encodingLen = 0;
      Pointer<Char> schemaNative = nullptr;
      var schemaLen = 0;

      try {
        final marshalled = allocLengthCarriedUtf8(parameters);
        parametersNative = marshalled.ptr;
        parametersLen = marshalled.len;
        final (mime, schema) = encoding != null
            ? encodingWireChannels(encoding)
            : (null, null);
        final encMarshalled = allocLengthCarriedUtf8(mime);
        encodingNative = encMarshalled.ptr;
        encodingLen = encMarshalled.len;
        final schemaMarshalled = allocLengthCarriedUtf8(schema);
        schemaNative = schemaMarshalled.ptr;
        schemaLen = schemaMarshalled.len;

        final rc = bindings.zd_get(
          loanedSession.cast(),
          loanedKe.cast(),
          receivePort.sendPort.nativePort,
          target.index,
          consolidation.value,
          payload != null ? payload.nativePtr.cast() : nullptr,
          encodingNative,
          encodingLen,
          schemaNative,
          schemaLen,
          timeoutMs,
          parametersNative,
          parametersLen,
          attachment != null ? attachment.nativePtr.cast() : nullptr,
          congestionControl?.value ?? -1,
          priority?.value ?? -1,
          isExpress == null ? -1 : (isExpress ? 1 : 0),
          allowedDestination?.value ?? -1,
          acceptReplies?.value ?? -1,
          retainPayload ? 1 : 0,
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
          throw ZenohException('Get query failed', rc);
        }
        started = true;
      } finally {
        if (parametersNative != nullptr) calloc.free(parametersNative);
        if (encodingNative != nullptr) calloc.free(encodingNative);
        if (schemaNative != nullptr) calloc.free(schemaNative);
        if (!started) {
          receivePort.close();
          unawaited(controller.close());
        }
      }

      return retention.gate(controller.stream);
    });
  }

  /// Sends a query whose replies land in a **bounded channel** instead of a
  /// stream, and returns a [PullReplies] handle to take them out of.
  ///
  /// The channel-mode sibling of [get], carrying its identical option surface.
  /// Where [get] pushes every reply as it arrives and buffers without bound,
  /// this holds at most [capacity] replies and lets the consumer set the pace —
  /// which is canon's own documented default get flow (`z_get` +
  /// `z_fifo_channel_reply_new`).
  ///
  /// [kind] and [capacity] are **required**, deliberately. Canon forces the
  /// caller to choose both — its channel constructors take a raw `size_t` and
  /// have no options-default, and the C++ binding's channel selector has no
  /// default either — so this binding substitutes no value canon does not have.
  ///
  /// The handle's release is [PullReplies.dispose], not `close`: the query
  /// still runs to completion natively and no peer observes the drop.
  ///
  /// ## ⚠️ Never poll a full fifo channel from the session that answers it
  ///
  /// **Measured at zenoh-c 1.8.0.** On a same-session route the reply delivery
  /// runs *synchronously inside your own `z_get` call*, so a fifo channel that
  /// fills up freezes this call inside the FFI boundary — and [timeout] cannot
  /// rescue a thread stuck in that push. Use a second session for the replier,
  /// or [ChannelKind.ring]. The same hazard runs the other way on a
  /// channel-backed queryable.
  ///
  /// ## ⚠️ A ring channel must be polled while the query is in flight
  ///
  /// A ring discards its whole buffer when the channel disconnects, and a get
  /// completes immediately after its replies — so a ring reply channel polled
  /// only after completion recovers **nothing**. That is canon's behaviour,
  /// measured, and it is rendered here rather than papered over.
  ///
  /// ## ⚠️ [consolidation] decides what this channel can even see
  ///
  /// **Measured.** canon's default, [ConsolidationMode.auto], resolves to a
  /// consolidating mode that both **dedupes replies by key expression** and
  /// **withholds them until the query completes**. Three replies on one key
  /// then reach the channel as one, and nothing at all is visible in flight —
  /// which for a ring channel means nothing at all, full stop. Pass
  /// [ConsolidationMode.none] when you want every reply, or when you intend to
  /// consume in flight.
  ///
  /// ## Capacity 0
  ///
  /// **Measured** on this column: a capacity-0 fifo is a *rendezvous* — full
  /// when empty — and [PullReplies.tryRecv] works there, because a synchronous
  /// poll is itself the concurrent consumer the rendezvous needs.
  /// [PullReplies.recv] does **not**: see its own documentation. A capacity-0
  /// ring recovers nothing after completion, like any other ring.
  ///
  /// Throws [ArgumentError] if [capacity] is negative, or if [timeout] marshals
  /// to 0 ms (see [get]).
  /// Throws [StateError] if the session has been closed.
  ///
  /// ⛔ Throws [ArgumentError] if [congestionControl] is
  /// [CongestionControl.blockFirst] and the loaded native was built without
  /// `Z_FEATURE_UNSTABLE_API`. canon declares
  /// `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under that flag, so on such a
  /// build there is no value to send. Pass [CongestionControl.block] or
  /// [CongestionControl.drop], or select the `unstable` native through your
  /// app's `user_defines`.
  PullReplies pullGet(
    Object selector, {
    required ChannelKind kind,
    required int capacity,
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    ReplyKeyExpr? acceptReplies,

    /// Whether each pulled OK reply carries a retained
    /// [Sample.payloadZBytes]. Off by default; the ERROR arm never does.
    bool retainPayload = false,
  }) {
    // FIRST STATEMENT: the stated order on this entry point is congestion,
    // then capacity, then timeout. A negative capacity and a zero timeout are
    // both expressible correctly by choosing another number; blockFirst on a
    // stable native is not, so reporting the fixable faults first would send
    // the caller round a loop.
    requireCongestionControlSupported(congestionControl);
    // BEFORE ANY NATIVE CALL, and for the same reason as on the pull
    // subscriber: a negative is outside canon's `size_t` domain entirely, and
    // the carriage would otherwise reinterpret it as an enormous unsigned
    // capacity -- a silent transform, not a refusal. No upper bound is
    // invented.
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be non-negative');
    }
    _rejectSentinelTimeout(timeout);

    return _withKeyExprArg(selector, 'selector', (loanedSession, loanedKe) {
      // ALLOCATE-LAST: claimed only after the selector has been accepted.
      final handlerHandle = calloc<Uint8>(
        bindings.zd_reply_handler_sizeof(kind.value),
      );
      // The readiness channel behind `PullReplies.recv()`. The shim posts an
      // int64 ping when an armed waiter should look again, and a null sentinel
      // from the closure's drop when the query completes.
      final receivePort = ReceivePort();
      // Our out-cell for a SHIM-owned block: the shim mallocs the tee context
      // and `zd_pull_tee_drop` releases the handle's reference to it. This cell
      // is ours, and the outer `finally` encloses every statement that can
      // throw.
      final teeOut = calloc<Pointer<Uint8>>();
      Pointer<Uint8> teeValue = nullptr;
      var started = false;
      Pointer<Char> parametersNative = nullptr;
      var parametersLen = 0;
      // The encoding joins parameters on the length-carried side of this same
      // signature -- the asymmetry inside it (parameters length-carried, the
      // encoding a bare C string four lines below) is what this seed removes.
      // Two INDEPENDENT channels, from the RAW pair (R-3a).
      Pointer<Char> encodingNative = nullptr;
      var encodingLen = 0;
      Pointer<Char> schemaNative = nullptr;
      var schemaLen = 0;

      try {
        final marshalled = allocLengthCarriedUtf8(parameters);
        parametersNative = marshalled.ptr;
        parametersLen = marshalled.len;
        final (mime, schema) = encoding != null
            ? encodingWireChannels(encoding)
            : (null, null);
        final encMarshalled = allocLengthCarriedUtf8(mime);
        encodingNative = encMarshalled.ptr;
        encodingLen = encMarshalled.len;
        final schemaMarshalled = allocLengthCarriedUtf8(schema);
        schemaNative = schemaMarshalled.ptr;
        schemaLen = schemaMarshalled.len;

        final rc = bindings.zd_get_channel(
          handlerHandle,
          teeOut,
          receivePort.sendPort.nativePort,
          loanedSession.cast(),
          loanedKe.cast(),
          kind.value,
          capacity,
          target.index,
          consolidation.value,
          payload != null ? payload.nativePtr.cast() : nullptr,
          encodingNative,
          encodingLen,
          schemaNative,
          schemaLen,
          timeout != null ? timeout.inMilliseconds : 0,
          parametersNative,
          parametersLen,
          attachment != null ? attachment.nativePtr.cast() : nullptr,
          congestionControl?.value ?? -1,
          priority?.value ?? -1,
          isExpress == null ? -1 : (isExpress ? 1 : 0),
          allowedDestination?.value ?? -1,
          acceptReplies?.value ?? -1,
        );

        // Marked UNCONDITIONALLY, exactly as on [get]: the shim has either
        // moved them into zenoh-c or dropped them itself on every return code
        // reachable from here. The one code that returns pre-move is the
        // capacity refusal, which the guard above makes unreachable.
        if (payload != null) {
          payload.markConsumed();
        }
        if (attachment != null) {
          attachment.markConsumed();
        }

        if (rc != 0) {
          // The declare channel's return space is SPLIT, and it is mapped here,
          // once, at the single call site -- the same split the pull subscriber
          // ships.
          if (rc == 10) {
            throw ArgumentError.value(
              capacity,
              'capacity',
              "must be non-negative and within this platform's size_t range",
            );
          }
          if (rc == 11) {
            throw ZenohException('Failed to allocate reply channel state', rc);
          }
          throw ZenohException('Get query failed', rc);
        }
        teeValue = teeOut.value;
        started = true;
      } finally {
        if (parametersNative != nullptr) calloc.free(parametersNative);
        if (encodingNative != nullptr) calloc.free(encodingNative);
        if (schemaNative != nullptr) calloc.free(schemaNative);
        if (!started) {
          receivePort.close();
          calloc.free(handlerHandle);
        }
        calloc.free(teeOut);
      }

      return PullReplies(
        handlerHandle,
        teeValue,
        receivePort,
        kind,
        retainPayload,
      );
    });
  }

  /// Creates a [ReceivePort] and [StreamController] wired for reply parsing.
  ///
  /// The returned [ReceivePort] listens for NativePort messages from the C
  /// shim reply callback. Ok replies (tag=1) and error replies (tag=0) are
  /// forwarded to the [StreamController]. A null sentinel closes both.
  static (ReceivePort, StreamController<Reply>, ReplyRetention)
  _createReplyChannel({
    bool retainPayload = false,
  }) {
    final controller = StreamController<Reply>();
    final receivePort = ReceivePort();
    final retention = ReplyRetention(enabled: retainPayload);

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Query complete. The channel self-terminates here, so this is
        // where undelivered retained handles are released.
        retention.drain();
        receivePort.close();
        unawaited(controller.close());
      } else if (message is List) {
        final tag = message[0] as int;
        if (tag == 1) {
          // Length-carried key expression: an interior NUL survives, and the
          // decode is lenient like every other display string here.
          final keyExpr = utf8.decode(
            message[1] as Uint8List,
            allowMalformed: true,
          );
          // ⛔ A VALUE THAT COULD NOT BE CONVERTED IS AN ERROR, NEVER AN
          // EMPTY SUCCESS. Empty is legitimate on this path, so a
          // zero-length buffer posted for a failed conversion would be
          // indistinguishable from a real empty reply. The error goes to the
          // error channel and the stream keeps running.
          final payloadFailure = undecodableRc(message[2]);
          if (payloadFailure != null) {
            controller.addError(undecodableError('a payload', payloadFailure));
            return;
          }
          final attachmentFailure = undecodableRc(message[4]);
          if (attachmentFailure != null) {
            controller.addError(
              undecodableError('an attachment', attachmentFailure),
            );
            return;
          }
          final payloadBytes = message[2] as Uint8List;
          final kind = message[3] as int;
          final attachmentBytes = message[4] as Uint8List?;
          // Length-carried like the key expression above: a rendered MIME
          // string is an arbitrary byte sequence, so a kString truncated it at
          // the first interior NUL.
          final encodingBytes = message.length > 5
              ? message[5] as Uint8List?
              : null;
          // Slice 4: QoS/timestamp metadata (length-guarded, defensive).
          final timestampBytes = message.length > 6
              ? message[6] as Uint8List?
              : null;
          final priorityRaw = message.length > 7 ? message[7] as int : null;
          final congestionRaw = message.length > 8 ? message[8] as int : null;
          final expressRaw = message.length > 9 ? message[9] as int : null;
          // Slice 5: replier id (constant array positions 10/11), length-guarded.
          final replierZid = message.length > 10
              ? message[10] as Uint8List?
              : null;
          final replierEid = message.length > 11 ? message[11] as int? : null;
          final replierId = (replierZid != null && replierEid != null)
              ? EntityGlobalId(ZenohId(replierZid), replierEid)
              : null;

          // Seed [10a] element 12: the retained payload handle image, or null
          // when this carrier did not opt in. Length-guarded like every
          // element above it.
          final retainedImage = message.length > 12
              ? message[12] as Uint8List?
              : null;
          final sample = Sample(
            keyExpr: keyExpr,
            payload: utf8.decode(payloadBytes, allowMalformed: true),
            payloadBytes: payloadBytes,
            kind: kind == 0 ? SampleKind.put : SampleKind.delete,
            attachment: attachmentBytes != null
                ? utf8.decode(attachmentBytes, allowMalformed: true)
                : null,
            attachmentBytes: attachmentBytes,
            encoding: encodingBytes != null
                ? utf8.decode(encodingBytes, allowMalformed: true)
                : null,
            encodingBytes: encodingBytes,
            timestamp: timestampBytes != null
                ? Timestamp.fromRaw(timestampBytes)
                : null,
            // Wire priority is 1..7 -> Priority.fromWire.
            priority: priorityRaw != null
                ? Priority.fromWire(priorityRaw)
                : Priority.data,
            // Wire congestion is 0/1/2 -> CongestionControl.fromWire.
            congestionControl: congestionRaw != null
                ? CongestionControl.fromWire(congestionRaw)
                : CongestionControl.drop,
            express: expressRaw != null && (expressRaw != 0),
            payloadZBytes: ZBytes.fromPostedImage(retainedImage),
          );
          final reply = Reply.ok(sample, replierId: replierId);
          if (controller.isClosed) {
            // Drain branch: the channel already terminated and this was
            // still in the port queue, so nobody can receive it.
            retention.dropUndeliverable(reply);
            return;
          }
          retention.track(reply);
          controller.add(reply);
        } else if (tag == 0) {
          // The error arm needs the same guard for the same reason: an
          // error reply may legitimately carry an empty body, so a failed
          // conversion posted as empty would be read as "the peer replied
          // with an error and said nothing".
          final errorFailure = undecodableRc(message[1]);
          if (errorFailure != null) {
            controller.addError(
              undecodableError('an error payload', errorFailure),
            );
            return;
          }
          final errorPayloadBytes = message[1] as Uint8List;
          final errorEncodingBytes = message.length > 2
              ? message[2] as Uint8List?
              : null;
          // Slice 5: replier id (constant array positions 3/4), length-guarded.
          final replierZid = message.length > 3
              ? message[3] as Uint8List?
              : null;
          final replierEid = message.length > 4 ? message[4] as int? : null;
          final replierId = (replierZid != null && replierEid != null)
              ? EntityGlobalId(ZenohId(replierZid), replierEid)
              : null;

          final replyError = ReplyError(
            payloadBytes: errorPayloadBytes,
            payload: utf8.decode(errorPayloadBytes, allowMalformed: true),
            encoding: errorEncodingBytes != null
                ? utf8.decode(errorEncodingBytes, allowMalformed: true)
                : null,
            encodingBytes: errorEncodingBytes,
          );
          controller.add(Reply.error(replyError, replierId: replierId));
        }
      }
    });

    return (receivePort, controller, retention);
  }
}

/// The codes `z_open` can actually return, with what each one means.
///
/// **Deliberately narrow, and narrower than canon's full `z_result_t` set.**
/// `z_open` has exactly two failure returns
/// (`extern/zenoh-c/src/session.rs:89-111`, read at the pinned 1.8.0):
/// `Z_EINVAL` when no config was provided, and `Z_ENETWORK` for **every**
/// other failure — the `Err(e)` arm is unconditional. A wider map would
/// advertise codes this call cannot produce.
///
/// ⚠️ **`Z_ENETWORK` here does NOT mean "a network problem".** It is canon's
/// catch-all: a bad mode, an unparseable endpoint and an unreachable peer all
/// arrive as `-4`. The rendering below says so, because naming the symbol
/// without that qualification sends a reader after a fault that may not
/// exist. Canon writes the real reason to its own log via `report_error!`.
///
/// ⛔ **RETIRED.** The names now come from `ZenohException.codeNames`, the
/// general accessor this map's own dartdoc named as its successor. Two
/// rc→name tables in one binding can drift apart, and the local one had no
/// way to know it had.
///
/// Reached through [_canonNames] below rather than by widening
/// `ZenohException` with a static: one internal caller does not justify a new
/// public member.

/// Canon's name(s) for [rc], via the general accessor.
///
/// ⚠️ It builds a throwaway exception to ask a question about an integer,
/// which is odd enough to explain: `codeNames` is an instance getter by
/// design — the alternative was a public static, and adding public surface
/// for one internal caller is the wrong trade. This is a failure path, so the
/// allocation costs nothing that matters.
List<String> _canonNames(int rc) => ZenohException('', rc).codeNames;

/// What each reachable code actually tells you.
///
/// ⛔ **STAYS LOCAL, and that is a decision rather than an omission.** Canon
/// defines error NAMES, not meanings — so a general accessor handing out
/// per-code prose would assert semantics canon does not define. This prose is
/// open-path-specific: `Z_ENETWORK` means *"the open failed, cause unstated"*
/// here, and would mean something else wherever else canon returns it.
const Map<int, String> _openErrorMeanings = {
  -1: 'no config was provided',
  -4:
      "zenoh's catch-all for every open failure, whatever the cause -- not "
      "specifically a network fault. Zenoh's own log line carries the reason",
};

/// The shim's own "did it start" codes.
///
/// ⛔ **STAYS, and for the same reason the general accessor excludes it.**
/// These are binding-owned positives, and they are **channel-scoped**: `12` is
/// this shim's allocation failure *on the open channel*, while the same number
/// means trailing data on the deserialize channel. A number-keyed global
/// accessor structurally cannot render two meanings for one number, so it
/// renders neither and the channel that owns the meaning names it here.
const Map<int, String> _openStartFailures = {
  12: "ZD_OPEN_EALLOC: the shim could not allocate the call's heap blocks",
  13: 'ZD_OPEN_ETHREAD: the shim could not start the background thread',
};

/// Renders the message for a session open that never *started*.
///
/// Distinct from [openFailureMessage] and deliberately so. A start failure is
/// a **positive** code raised **synchronously**, meaning nothing ran and no
/// completion is coming. A canon failure is a **negative** code arriving on a
/// **rejected future**. The delivery channel discriminates and the sign
/// confirms it, so the two must not share a rendering.
@internal
@visibleForTesting
String openStartFailureMessage(int rc) {
  final named = _openStartFailures[rc];
  return named == null
      ? 'Failed to start opening a session: code $rc'
      : 'Failed to start opening a session: $named (code $rc). '
            'The session was never opened and no attempt was made';
}

/// Completes [completer] from one `zd_open_session_async` post.
///
/// ⛔ **Nothing here may throw its way out of completing the [completer].** A
/// startup call's hang is total: no in-isolate timeout can rescue a future
/// whose only completion path threw, and a shipped defect of exactly this
/// shape has existed on this bridge before. Every path below either completes
/// or is a deliberate no-op on an already-completed completer.
///
/// Visible for testing because neither case it guards — a malformed post, and
/// a duplicate or late post — can be produced by the shim, which contracts
/// exactly one well-formed post per successful start.
@internal
@visibleForTesting
void completeOpenFromPost(
  dynamic message,
  Completer<Session> completer, {
  required bool callerSuppliedConfig,
}) {
  // A duplicate or late post is inert: the guard makes it a no-op rather than
  // a "Future already completed" thrown from a bare listener.
  if (completer.isCompleted) return;
  try {
    final parts = message as List;
    final rc = parts[0] as int;
    final address = parts[1] as int;
    final detailBytes = parts[2];

    if (rc == 0 && address != 0) {
      completer.complete(Session._(Pointer<Void>.fromAddress(address)));
      return;
    }

    // Canon failed. The detail travelled WITH the post, captured on the worker
    // immediately after the failing call -- never read back afterwards from a
    // thread-local buffer belonging to a thread that did not make the call.
    final detail = detailBytes is Uint8List && detailBytes.isNotEmpty
        ? utf8.decode(detailBytes, allowMalformed: true)
        : null;
    final base = openFailureMessage(
      rc,
      callerSuppliedConfig: callerSuppliedConfig,
    );
    completer.completeError(
      ZenohException(detail == null ? base : '$base. Zenoh says: $detail', rc),
    );
  } on Object catch (error, stackTrace) {
    // Reached only by a post that does not match the contracted shape. Fail
    // the future rather than leave it pending forever.
    if (!completer.isCompleted) completer.completeError(error, stackTrace);
  }
}

/// Renders the message for a failed `Session.open`.
///
/// Names canon's symbol for [rc] **alongside** the number rather than in
/// place of it, and records whether the caller supplied the `Config` or the
/// factory created a default one. An unmapped [rc] degrades to the bare
/// number — no name is invented for it.
///
/// ⛔ **A named code is qualified, never left to speak for itself.** `z_open`
/// collapses every failure but a missing config into `Z_ENETWORK`, so the
/// symbol alone would read as a diagnosis it cannot support.
///
/// ⛔ **This reads nothing but its arguments, and must keep doing so.** Which
/// config was in play is the one piece of context available without an FFI
/// call. Reading a config *field* to say more would cost a call on every
/// **successful** open for a **failure-only** message, and [Config.get]
/// throws [ZenohException] on an absent key — converting a diagnosable
/// failure into a different exception entirely.
///
/// ## Where to find the actual cause
///
/// This message names canon's **catch-all**, not a diagnosis: `z_open`
/// collapses every failure but a missing config into `Z_ENETWORK`, so the
/// symbol cannot tell you *what went wrong*. Canon writes the real reason to
/// its own log, and the route to it is one of:
///
/// - **`Zenoh.initLog('error')`** — canon's records to stdout. Simplest, and
///   what a CLI wants.
/// - **`Zenoh.initLogWithSink(minSeverity: LogSeverity.error)`** — the same
///   records delivered into your application. What a host that cannot read
///   stdout, or that needs to filter, wants.
///
/// ⛔ **They are mutually exclusive, and choosing wrongly is silent at the
/// point of choice.** Canon's logging slot is process-global and first-wins,
/// so calling `initLog` **forecloses** the sink for the life of the process.
/// The foreclosure surfaces as a `StateError` **at the sink install**, never
/// at the `initLog` call — so a host that may ever want a sink installs the
/// sink first.
///
/// ⚠️ **And the log channel is not clean.** Open-failure records carry no
/// config, which is why diagnosis is routed here at all; but canon's
/// **config-rejection** records **echo** the offending value verbatim, with
/// its surrounding source line and a caret, on **both build variants**. The
/// recommendation is qualified rather than a zero-leak promise, and
/// host-side filtering — which only the sink route gives you — is the control.
///
/// ⛔ **On the default `stable` build this is the only route, not the better
/// one.** The upstream-detail capture is compiled out there, so the exception
/// message below is the whole of what this binding can say; a reader who does
/// not know that will keep looking at a message that structurally cannot
/// carry more.
///
/// ## What this message may contain, measured
///
/// On the `unstable` variant this rendering is followed by canon's own text
/// for the failure, captured on the worker immediately after the failing call
/// and marshalled with the post. Its input is the whole `Config`, so the
/// question is not rhetorical: **does it carry secrets?**
///
/// **Measured: no, over nine drivers, with a positive control firing in the
/// same process.** A recognisable marker was planted in a failing endpoint's
/// `#config` section, in key-file paths, as decoded key material, in a
/// password, in a usrpwd dictionary path and inside an ACL rule; all nine
/// reached a canon open failure carrying detail, and none echoed the marker.
///
/// ⭐ **The mechanism, which is what makes that more than a coincidence: the
/// echo is a property of the error type, not of the path's input.** Canon's
/// open-failure errors render a **diagnosis** — *"Unicast not supported for
/// bogusproto protocol"*, *"Invalid TLS private key file"* — while config
/// **parse** errors **do echo** their source, with a caret pointing at the
/// offending token. Both are reachable from a config carrying a secret; only
/// the second puts it in the message. So *"the open path is clean"* is true
/// and *"detail-carrying paths are clean"* is false, and a reader given only
/// the first would enrich a parse path next.
///
/// ⚠️ **Nine drivers are a strong negative with a stated mechanism. They are
/// not a proof over canon's whole open-failure space** — a failure class
/// nobody has driven is a failure class whose text nobody has read, and it is
/// not claimed clean here.
///
/// ⛔ **Misattribution is impossible on this path by construction.** The
/// detail is captured on the worker, on the thread that made the failing
/// call, and travels with the post; nothing is read back afterwards, so no
/// other operation's text can reach this message. That is a structural
/// property, not an observation that happened to hold.
///
/// On the default `stable` variant there is no detail at all: the capture is
/// compiled out, and the message is this rendering alone.
///
/// ⚠️ **The detail crosses the same 511-byte clamp the config sites do** — the
/// worker captures through the same helper — and is truncated silently, with
/// no marker to say so. The full chain is on `ZenohException.enriched`.
///
/// ⚠️ **Provisional**, pending the diagnosability unit's general rc-to-name
/// accessor. It is **not public API, and the thing that keeps it out is the
/// door's `show` clause**: `zenoh.dart` exports `src/session.dart` showing
/// `Session` alone, so a consumer naming this function does not get a warning
/// — the name does not resolve. `@internal` beside `@visibleForTesting` says
/// the same thing to a reader and to an IDE; the fence is the clause.
/// *(Corrected: this used to say it was "intentionally not exported", which
/// was false while the door still exported it. An intention is not a
/// mechanism, and only the mechanism can be relied on.)*
///
/// It stays visible within this package so the two cases no failing open can
/// produce — an unmapped code, and a null-config open — remain testable.
@internal
@visibleForTesting
String openFailureMessage(int rc, {required bool callerSuppliedConfig}) {
  final names = _canonNames(rc);
  final meaning = _openErrorMeanings[rc];
  final code = names.isEmpty
      ? 'code $rc'
      : '${names.join(', ')} (code $rc)'
            '${meaning == null ? '' : ' -- $meaning'}';
  final origin = callerSuppliedConfig
      ? 'the caller-supplied config'
      : 'the default config created internally';
  return 'Failed to open session: $code. Using $origin';
}
