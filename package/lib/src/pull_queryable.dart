import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/channel_kind.dart';
import 'package:zenoh_dart/src/demand_gated_stream.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/query.dart';
import 'package:zenoh_dart/src/queryable.dart' show Queryable;
import 'package:zenoh_dart/src/recv_result.dart';
import 'package:zenoh_dart/src/reply_keyexpr.dart';
import 'package:zenoh_dart/src/session.dart' show Session;

/// A queryable whose queries accumulate in a bounded channel, taken out on
/// demand.
///
/// The channel-mode sibling of [Queryable]. Where a [Queryable] pushes every
/// query into a stream as it arrives and buffers without bound, this holds at
/// most `capacity` queries and lets the consumer set the pace.
///
/// The [kind] chosen at declaration decides what happens when the buffer fills:
/// [ChannelKind.ring] drops the oldest query — remotely visible as that
/// getter's timeout — while [ChannelKind.fifo] keeps every query and stalls
/// inbound delivery instead.
///
/// **Reply before you close. Drain only if the residue matters.** [close]
/// undeclares the queryable and releases the channel with whatever it holds. A
/// query already taken out of the channel can still be replied to *until*
/// then; canon calls replying after undeclare undefined behaviour, so this
/// binding renders it as a contract rather than exposing a post-close drain
/// window. (Measured at zenoh-c 1.8.0, subprocess-isolated: a reply attempted
/// after undeclare returns normally and is silently dropped — no error and no
/// crash. That is what makes a documented contract the proportionate rendering
/// rather than a guard; it is not a licence to rely on it.)
///
/// ⚠️ **The drain half used to read "drain before you close", and it silently
/// carried a CORRECTNESS claim it could not honour.** Closing an undrained,
/// overflowing fifo once hung the calling isolate permanently. That is fixed at
/// the source, and draining could never have prevented it from one isolate
/// anyway — measured at canon level, the hang persisted after the producer was
/// gone. The REPLY half is unaffected and still binding: it is about canon's
/// undefined behaviour after undeclare, not about this hang.
///
/// ⚠️ **One teardown ORDER still matters, and it is canon's, not this
/// binding's:** close pull handles *before* closing their session when a fifo
/// may be in overflow. A session closed first still stalls — measured, and
/// pinned as a residual in `test/fifo_close_deadlock_test.dart`. This unit does
/// not fix that path.
///
/// The two terminal triggers differ in what they leave you: [close] releases
/// this handle, so nothing can be polled afterwards, while the SESSION closing
/// leaves the handle alive — a fifo then hands over what it still holds before
/// reporting [RecvDisconnected], and a ring discards it.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: as
/// `PullSubscriber` — its close ordering is half Dart-side, which a finalizer
/// callback cannot run.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class PullQueryable implements Finalizable {
  /// Internal constructor. Use [Session.declarePullQueryable] instead.
  PullQueryable(
    this._queryableHandle,
    this._handlerHandle,
    this._teeHandle,
    this._receivePort,
    this._keyExpr,
    this._kind,
  ) {
    _receivePort.listen(_onWake);
  }

  final Pointer<Uint8> _queryableHandle;
  final Pointer<Uint8> _handlerHandle;
  final Pointer<Uint8> _teeHandle;
  final ReceivePort _receivePort;
  final String _keyExpr;
  final ChannelKind _kind;
  bool _closed = false;

  /// The single outstanding [recv] waiter, or null.
  Completer<RecvResult<Query>>? _pending;

  /// The demand gate behind [stream], created on first access to it.
  ///
  /// Null until someone asks for [stream]: a caller who never does has no gate
  /// at all, which is what keeps [tryRecv] and [recv] byte-identical for them.
  DemandGate<Query>? _gate;

  /// The key expression this queryable is declared on.
  String get keyExpr => _keyExpr;

  /// The bounded channel kind backing this queryable.
  ChannelKind get kind => _kind;

  /// A bounded, demand-gated [Stream] view over this handle's own [recv].
  ///
  /// Unlike `Session.declareQueryable`'s stream, which pushes every arrival
  /// into an unbounded `StreamController` seam, this one **pulls**: it takes
  /// one query at a time out of the bounded native channel, and only while the
  /// subscription is demanding.
  ///
  /// ## This column is where the bound costs native memory, not only Dart
  ///
  /// Every buffered query is a `z_owned_query_t` **clone** held on the native
  /// side until it is disposed. A slow consumer on the push stream therefore
  /// grows both the Dart queue and native memory; a slow consumer here retains
  /// the channel's own `capacity` and **at most one already-pulled query** —
  /// at most `capacity + 1`, because the first pull starts synchronously
  /// inside `onListen` and the query completing it goes to a one-slot stash.
  ///
  /// ⚠️ A ceiling, not an equality. Measured on `ring, capacity: 8`: 64
  /// concurrent getters left **8** queries retained where the shipped push
  /// queryable retained all **64**. Canon's ring makes room before it inserts,
  /// so sustained overflow sits one short of the ceiling.
  ///
  /// What happens to the queries that do not fit is the channel's [kind],
  /// unchanged: a [ChannelKind.ring] drops its oldest *channel* entry, which
  /// the requester sees as its getter finalizing with no reply; a
  /// [ChannelKind.fifo] stalls inbound delivery instead.
  ///
  /// ## ⚠️ This getter is a MODE SWITCH
  ///
  /// Once the returned stream has a listener, the drive loop owns this
  /// handle's [recv]: calling [recv] yourself throws [StateError] while a pull
  /// is in flight, and an interleaved [tryRecv] competes with the loop for
  /// arrivals. Pick one consumption idiom per handle.
  ///
  /// A query that completed a pull into a paused or cancelled subscription is
  /// **stashed, not disposed**: [tryRecv] hands it back before it touches the
  /// channel — so it can still be replied to — and [close] disposes anything
  /// still held, so the remedy does not trade a lost reply for a leak.
  ///
  /// Reply to every [Query] you take and then call [Query.dispose], exactly as
  /// on the polling path.
  ///
  /// ## ⚠️ Capacity 0, measured per kind — this column only
  ///
  /// On a [ChannelKind.fifo] at capacity 0 this stream delivers **nothing**;
  /// on [ChannelKind.ring] it delivers. ⚠️ **That is not what
  /// [Session.declarePullQueryable] reports for the same capacity, and both
  /// are true**: that dartdoc says both kinds hand a query over *under
  /// polling*, which is about [tryRecv]. This stream does not poll — it drives
  /// [recv], and [recv] is the one accessor a capacity-0 fifo cannot serve on
  /// either column, because the rendezvous is full when it is empty. **The
  /// axis is the accessor, not the column.**
  ///
  /// ## Teardown
  ///
  /// With a pull still in flight, [close] completes it and the loop's own
  /// terminal arm closes the stream; with the loop already exited holding a
  /// stash, only [close]'s gate step can. Either way anything stashed is
  /// disposed there — measured, the requester's getter then finalizes in
  /// ~24 ms instead of waiting out its own timeout.
  ///
  /// Single-subscription. Throws [StateError] if this queryable has been
  /// [close]d, exactly as [tryRecv] and [recv] do.
  Stream<Query> get stream {
    if (_closed) throw StateError('PullQueryable has been closed');
    return (_gate ??= DemandGate<Query>(
      pull: recv,
      // ⚠️ NOT a no-op on this column. A query the consumer will never see
      // still holds a native clone, and dropping it is what sends canon's
      // `ResponseFinal` -- so the requester's getter completes promptly
      // instead of waiting out its own timeout.
      release: (query) => query.dispose(),
    )).stream;
  }

  /// Whether the [stream] drive loop has a pull outstanding right now.
  /// **Test instrument only.**
  ///
  /// Establishing the drive loop's state by a consuming peek would, under the
  /// stash-first accessor, take the very query a cell is about. Same precedent
  /// as [teeAddressForTesting].
  ///
  /// Reads `false` when [stream] was never accessed: no gate, no loop.
  @internal
  @visibleForTesting
  bool get pullInFlightForTesting => _gate?.inFlight ?? false;

  /// Whether the [stream] gate is holding a stashed query. **Test instrument
  /// only.** See [pullInFlightForTesting].
  @internal
  @visibleForTesting
  bool get stashHeldForTesting => _gate?.hasStash ?? false;

  /// The owned handler slot's address. **Test instrument only.**
  ///
  /// A resource defect is invisible to a behavioural assertion, so the only
  /// instrument that can see a leaked slot is counting DISTINCT BLOCK ADDRESSES
  /// over many cycles — which needs the address. Same precedent as
  /// `PullSubscriber.handlerAddressForTesting`.
  @internal
  @visibleForTesting
  int get handlerAddressForTesting => _handlerHandle.address;

  /// The shim-owned readiness-tee block's address. **Test instrument only.**
  /// See [handlerAddressForTesting].
  @internal
  @visibleForTesting
  int get teeAddressForTesting => _teeHandle.address;

  /// Tries to take one query, without waiting.
  ///
  /// Returns canon's own three-way outcome, undiluted:
  ///
  /// - [RecvData] — a query was taken out of the buffer. Reply to it and then
  ///   call [Query.dispose], exactly as on the stream path.
  /// - [RecvEmpty] — the queryable is alive and nothing is buffered right now.
  ///   Back off and call again.
  /// - [RecvDisconnected] — the producing end is gone: this queryable was
  ///   undeclared, or its session closed. Terminal and sticky.
  ///
  /// Throws [ZenohException] if the call itself failed — an allocation sized by
  /// the requester could not be satisfied. That is a fault, not a channel
  /// state, so it is thrown rather than returned.
  ///
  /// Throws [StateError] if this queryable has been [close]d. That guard is
  /// ours, not canon's, and it is load-bearing rather than defensive: loaning a
  /// dropped handler is undefined behaviour in canon, never an error it
  /// reports.
  RecvResult<Query> tryRecv() {
    if (_closed) throw StateError('PullQueryable has been closed');

    // THE STASH IS CONSULTED FIRST, ahead of the native channel.
    //
    // A query that completed the [stream] drive loop's pull into a paused or
    // cancelled subscription is held in a one-slot stash rather than disposed,
    // and this is its retrieval exit -- the one that keeps it REPLIABLE.
    // Taking it before the channel preserves the ordering [recv]'s own dartdoc
    // publishes: an interleaved `tryRecv` "is fine and *wins*".
    //
    // A caller who never touched [stream] has no gate, so this reads null and
    // the path below is byte-identical to what shipped.
    final stashed = _gate?.takeStash();
    if (stashed != null) return RecvData(stashed);

    final outQuery = calloc<Int64>();
    final outKeyExpr = calloc<Pointer<Uint8>>();
    final outKeyExprLen = calloc<Size>();
    final outParameters = calloc<Pointer<Uint8>>();
    final outParametersLen = calloc<Size>();
    final outPayload = calloc<Pointer<Uint8>>();
    final outPayloadLen = calloc<Size>();
    final outAttachment = calloc<Pointer<Uint8>>();
    final outAttachmentLen = calloc<Size>();
    final outEncoding = calloc<Pointer<Char>>();
    final outEncodingLen = calloc<Size>();
    final outAccepts = calloc<Int8>();

    // The buffers the SHIM mallocs and hands over. Captured out here so the
    // finally releases them on every path, including a throw between the rc
    // check and the reads.
    Pointer<Uint8> keyExprPtr = nullptr;
    Pointer<Uint8> parametersPtr = nullptr;
    Pointer<Uint8> payloadPtr = nullptr;
    Pointer<Uint8> attachmentPtr = nullptr;
    Pointer<Char> encodingPtr = nullptr;

    try {
      final rc = bindings.zd_query_channel_try_recv(
        _handlerHandle,
        _kind.value,
        outQuery,
        outKeyExpr.cast(),
        outKeyExprLen,
        outParameters.cast(),
        outParametersLen,
        outPayload.cast(),
        outPayloadLen,
        outAttachment.cast(),
        outAttachmentLen,
        outEncoding.cast(),
        outEncodingLen,
        outAccepts,
      );

      // Canon's own codes, passed through by the shim and preserved here.
      // These two are STATES, not failures.
      if (rc == 1) return const RecvDisconnected<Query>();
      if (rc == 2) return const RecvEmpty<Query>();
      if (rc != 0) {
        throw ZenohException('Failed to receive from query channel', rc);
      }

      keyExprPtr = outKeyExpr.value;
      parametersPtr = outParameters.value;
      payloadPtr = outPayload.value;
      attachmentPtr = outAttachment.value;
      encodingPtr = outEncoding.value;

      // Both length-carried, never strlen-measured: the key expression grammar
      // and the selector's parameters segment each admit an interior NUL, and
      // canon carries one byte-exact.
      final keyExprStr = utf8.decode(
        keyExprPtr.asTypedList(outKeyExprLen.value),
        allowMalformed: true,
      );
      final parametersStr = utf8.decode(
        parametersPtr.asTypedList(outParametersLen.value),
        allowMalformed: true,
      );

      // Empty != absent on all three: the shim reports an absent value as a
      // null pointer and a present-but-empty one as a non-null pointer at
      // length 0, so the discriminator is the POINTER.
      final payloadBytes = payloadPtr == nullptr
          ? null
          : Uint8List.fromList(payloadPtr.asTypedList(outPayloadLen.value));
      final attachmentBytes = attachmentPtr == nullptr
          ? null
          : Uint8List.fromList(
              attachmentPtr.asTypedList(outAttachmentLen.value),
            );

      // Length-carried, exactly like the key expression and the parameters
      // above: a rendered MIME string is an arbitrary byte sequence and canon
      // carries an interior NUL in one byte-exact. NULL still means absent --
      // canon returns no encoding when the requester set none and sent no
      // payload — while a present-but-empty one is a non-NULL pointer at
      // length 0.
      final encodingBytes = encodingPtr == nullptr
          ? null
          : Uint8List.fromList(
              encodingPtr.cast<Uint8>().asTypedList(outEncodingLen.value),
            );

      return RecvData(
        Query(
          handle: outQuery.value,
          keyExpr: keyExprStr,
          parameters: parametersStr,
          payloadBytes: payloadBytes,
          attachmentBytes: attachmentBytes,
          encoding: encodingBytes == null
              ? null
              : utf8.decode(encodingBytes, allowMalformed: true),
          encodingBytes: encodingBytes,
          acceptsReplies: ReplyKeyExpr.fromWire(outAccepts.value),
        ),
      );
    } finally {
      if (keyExprPtr != nullptr) malloc.free(keyExprPtr.cast());
      if (parametersPtr != nullptr) malloc.free(parametersPtr.cast());
      if (payloadPtr != nullptr) malloc.free(payloadPtr.cast());
      if (attachmentPtr != nullptr) malloc.free(attachmentPtr.cast());
      if (encodingPtr != nullptr) malloc.free(encodingPtr.cast());
      calloc
        ..free(outQuery)
        ..free(outKeyExpr)
        ..free(outKeyExprLen)
        ..free(outParameters)
        ..free(outParametersLen)
        ..free(outPayload)
        ..free(outPayloadLen)
        ..free(outAttachment)
        ..free(outAttachmentLen)
        ..free(outEncoding)
        ..free(outEncodingLen)
        ..free(outAccepts);
    }
  }

  /// Waits for the next query.
  ///
  /// Completes with:
  ///
  /// - [RecvData] as soon as a query is available — immediately if one is
  ///   already buffered, otherwise when the next one arrives.
  /// - [RecvDisconnected] when the producing end goes: this queryable is
  ///   [close]d, or its session closes. For a fifo, only after its buffered
  ///   queries have been handed over first.
  ///
  /// **It never completes [RecvEmpty]**, and it never hangs, for the same
  /// reason canon's own blocking recv is two-valued: it *waits* rather than
  /// reporting an empty buffer.
  ///
  /// No thread is parked and no isolate is created — the native side signals
  /// readiness and this future consumes through the ordinary synchronous
  /// [tryRecv].
  ///
  /// Throws [StateError] if a `recv()` is already pending — one pull at a time
  /// per handle. An interleaved [tryRecv] is fine and *wins*: it reaches the
  /// channel first, and the pending `recv()` re-arms for the next arrival.
  ///
  /// Throws [StateError] if this queryable has been [close]d.
  Future<RecvResult<Query>> recv() {
    if (_closed) throw StateError('PullQueryable has been closed');
    if (_pending != null) {
      throw StateError('a recv() is already pending on this PullQueryable');
    }

    final immediate = tryRecv();
    if (immediate is! RecvEmpty<Query>) {
      return Future<RecvResult<Query>>.value(immediate);
    }

    // REGISTER, THEN ARM, THEN LOOK AGAIN — the order closes the arm-vs-arrival
    // race. Dart is single-threaded, so no port message can be delivered into
    // the gap between the first look and the arming.
    final completer = Completer<RecvResult<Query>>();
    _pending = completer;
    bindings.zd_pull_tee_arm(_teeHandle);

    final afterArm = tryRecv();
    if (afterArm is! RecvEmpty<Query>) {
      _pending = null;
      // The arming stays set and the next delivery spends it on a single ping
      // that `_onWake` discards. Bounded at one, and self-clearing.
      return Future<RecvResult<Query>>.value(afterArm);
    }
    return completer.future;
  }

  /// Handles a readiness ping (an int) or the producer's drop sentinel (null).
  ///
  /// The signal never carries data; it only ever says *look again*.
  void _onWake(dynamic message) {
    final waiter = _pending;
    if (waiter == null) return; // a leftover ping from the arm-vs-arrival race
    if (_closed) return; // close() already completed this waiter

    final isSentinel = message == null;
    try {
      var result = tryRecv();
      if (result is RecvEmpty<Query>) {
        if (isSentinel) {
          // Canon cannot report an empty buffer on a dropped channel, so this
          // is unreachable; normalising it keeps "never completes RecvEmpty" a
          // structural property rather than an inherited hope.
          result = const RecvDisconnected<Query>();
        } else {
          // An interleaved tryRecv() took the query. RE-ARM: the delivery that
          // pinged us already cleared the flag, so without this the next
          // arrival would post nothing and this waiter would sleep until the
          // disconnect.
          bindings.zd_pull_tee_arm(_teeHandle);
          result = tryRecv();
          if (result is RecvEmpty<Query>) return; // keep awaiting
        }
      }
      _pending = null;
      waiter.complete(result);
    } on Object catch (error, stackTrace) {
      _pending = null;
      waiter.completeError(error, stackTrace);
    }
  }

  /// Undeclares the queryable and releases native resources.
  ///
  /// **Remote-visible**, which is why this is `close()` and not `dispose()`:
  /// getters stop reaching this queryable.
  ///
  /// **Returns even when the channel is full and nothing has been recv'd.** A
  /// [ChannelKind.fifo] channel in overflow used to hang the calling isolate
  /// here, permanently and unrecoverably; it no longer does, and
  /// `test/fifo_close_deadlock_test.dart` is what keeps that true.
  ///
  /// Queries still buffered in the channel are released with it — the native
  /// channel owns them, and its drop is what frees them, so nothing is
  /// orphaned. But they are also not delivered: drain first if you need them,
  /// and reply to anything already taken *before* calling this.
  ///
  /// **What their getters see, measured:** a query undelivered across this
  /// call completes its getter promptly — ~20 ms — with no reply of any kind,
  /// neither data nor a `Timeout` error. Nothing is orphaned and nothing
  /// hangs. Pinned in `test/fifo_close_window_test.dart`, whose measurement
  /// held the session open six seconds past the close so the completion is
  /// attributable to this call rather than to a session teardown behind it.
  ///
  /// A pending [recv] completes [RecvDisconnected] rather than hanging.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;

    // COMPLETE THE WAITER FIRST, before any native release. `_closed` is
    // already set, so nothing this completion runs can re-enter canon through a
    // handle we are about to release.
    final waiter = _pending;
    _pending = null;
    waiter?.complete(const RecvDisconnected<Query>());

    // CLOSE THE DEMAND GATE NEXT, still before any native drop. Same
    // principle as the waiter above: everything Dart-side that could re-enter
    // canon through a handle we are about to release is quiesced first.
    //
    // ⚠️ ON THIS COLUMN THE GATE'S RELEASE IS NOT A NO-OP. It disposes any
    // query still stashed -- the stash's second exit -- and the position
    // matters: the dispose runs while this queryable is still declared, and
    // dropping the query is what sends canon's `ResponseFinal`, so the
    // requester's getter completes promptly rather than waiting out its
    // timeout. Without it the retrieval remedy would trade a lost reply for a
    // leaked clone.
    //
    // OWNERSHIP, and the general rule this is the fourth instance of: a push
    // channel that hands out natively-backed objects must track what it has
    // DELIVERED, because only the undelivered ones have no other owner. Here
    // the stash is that set. Queued for promotion into
    // `development/reference/dart-api-conventions-20260806.md` rather than
    // restated per unit -- the release paths being: retrieved through the
    // handle, released at close(), released when the controller is already
    // closed.
    //
    // The step is also load-bearing for the controller itself in exactly one
    // teardown state -- a loop that paused inside `onData` and then stashed
    // one further arrival has EXITED, and nothing else can close it.
    _gate?.close();

    // DROP THE HANDLER FIRST, then undeclare, TEE LAST.
    //
    // ⚠️ THIS COMMENT REPLACES ONE THAT REASONED CORRECTLY AND REACHED A
    // DEADLOCKING CONCLUSION. It said "Undeclare FIRST: once canon has dropped
    // the closure no further query can be pushed, so the handler drop below
    // faces a bounded buffer rather than a moving target", and that
    // `zd_queryable_drop` "blocks until executing callbacks are destroyed
    // (#1221), which is what makes the tee release safe on this column even
    // before its reference count is considered." Both statements about #1221
    // were TRUE. Neither asked what happens if the undeclare NEVER RETURNS --
    // and on a full fifo it does not, because canon's fifo callback is a
    // `send()` on a bounded flume channel that blocks when full, and the only
    // consumer that could release it is the isolate now parked inside this
    // synchronous FFI call.
    //
    // ⭐ AND THE "MOVING TARGET" WORRY IS ANSWERED BY MEASUREMENT, not by
    // argument. After the reorder canon's closure IS still live between the
    // handler drop and the undeclare's return, so a query can be pushed into a
    // dropped receiver in that window. Measured through this binding
    // (`test/fifo_close_window_test.dart`, "the getter observable for a query
    // undelivered across close() is measured and pinned"): the send fails
    // against the dropped receiver, the query is dropped, and its getter is
    // finalized promptly with no reply at all. Nothing is orphaned; the target
    // moves, and moving is harmless.
    //
    // HANDLER FIRST, because dropping the receiving end makes a parked send
    // fail fast -- the callback completes, and the undeclare then finds
    // nothing running. Canon's own construction, already relied on by
    // `PullReplies.dispose` on the third column.
    bindings
      ..zd_query_handler_drop(_handlerHandle, _kind.value)
      ..zd_queryable_drop(_queryableHandle.cast())
      // ⚠️ TEE LAST -- the surviving half of `#1221`, standing on the head's
      // own reference count rather than on the undeclare's blocking: an
      // `atomic_int` initialised to 2, one decrement from canon's closure drop
      // and one from this handle, last one frees. Order-independent by
      // construction, and verified as a RESOURCE with a both-ways injected
      // calibration in `ffi_ownership_test.dart`.
      ..zd_pull_tee_drop(_teeHandle);
    _receivePort.close();
    calloc
      ..free(_queryableHandle)
      ..free(_handlerHandle);
  }
}
