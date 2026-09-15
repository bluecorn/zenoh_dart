import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/channel_kind.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/recv_result.dart';
import 'package:zenoh_dart/src/reply.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart' show Session;
import 'package:zenoh_dart/src/timestamp.dart';

/// A bounded channel of query replies: replies accumulate and the caller takes
/// them out on demand.
///
/// The channel-mode sibling of the stream returned by [Session.get]. Where the
/// stream pushes every reply as it arrives and buffers without bound, this
/// holds at most `capacity` replies and lets the consumer set the pace.
///
/// The [kind] chosen at the call decides what happens when the buffer fills:
/// [ChannelKind.ring] drops the oldest reply and never blocks the replier,
/// [ChannelKind.fifo] keeps every reply and blocks the replier instead. Both
/// behaviours are canon's own, rendered here unsmoothed.
///
/// **This channel terminates by itself.** Unlike a subscriber's channel, there
/// is no entity to undeclare: canon drops the reply closure *once all replies
/// are processed*, so [RecvDisconnected] here means "this query is finished".
/// That is also why the release below is [dispose] and not `close` — dropping
/// the receiving end tells no peer anything, and the query still runs to
/// completion natively.
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
class PullReplies implements Finalizable {
  /// Internal constructor. Use [Session.pullGet] instead.
  PullReplies(
    this._handlerHandle,
    this._teeHandle,
    this._receivePort,
    this._kind, [
    // Positional rather than named: `_retainPayload` is private, and this is
    // an internal constructor reached only from Session/Querier.
    // ignore: avoid_positional_boolean_parameters
    this._retainPayload = false,
  ]) {
    _receivePort.listen(_onWake);
  }

  final Pointer<Uint8> _handlerHandle;
  final Pointer<Uint8> _teeHandle;
  final ReceivePort _receivePort;
  final ChannelKind _kind;

  /// Whether each pulled OK reply carries a retained [Sample.payloadZBytes].
  ///
  /// ⛔ The ERROR arm never carries one — that is the carve.
  final bool _retainPayload;
  bool _closed = false;

  /// The single outstanding [recv] waiter, or null.
  ///
  /// One at a time, deliberately: the native handler is move-only and
  /// single-consumer, so a second pending pull would invent fairness canon
  /// does not define.
  Completer<RecvResult<Reply>>? _pending;

  /// The bounded channel kind backing this handle.
  ChannelKind get kind => _kind;

  /// The shim-owned readiness-tee block's address. **Test instrument only.**
  ///
  /// A resource defect is invisible to a behavioural assertion: a leaked tee
  /// context neither throws nor corrupts, and every lifecycle test passes
  /// identically on leaking and on fixed code. The only instrument that can see
  /// it is counting DISTINCT BLOCK ADDRESSES over many cycles, which needs the
  /// address. Same precedent as `PullSubscriber.teeAddressForTesting`.
  @internal
  @visibleForTesting
  int get teeAddressForTesting => _teeHandle.address;

  /// The owned handler slot's address. **Test instrument only.** See
  /// [teeAddressForTesting].
  @internal
  @visibleForTesting
  int get handlerAddressForTesting => _handlerHandle.address;

  /// Tries to take one reply, without waiting.
  ///
  /// Returns canon's own three-way outcome, undiluted:
  ///
  /// - [RecvData] — a reply was taken out of the buffer. It carries the same
  ///   [Reply] the stream path delivers, ok/error discriminant included.
  /// - [RecvEmpty] — the query is still in flight and nothing is buffered
  ///   right now. Back off and call again.
  /// - [RecvDisconnected] — the query has completed. Terminal and sticky:
  ///   every subsequent call reports it again. Stop polling.
  ///
  /// This is the loop canon's own `z_non_blocking_get.c` writes:
  ///
  /// ```dart
  /// loop:
  /// while (true) {
  ///   switch (replies.tryRecv()) {
  ///     case RecvData(:final value):
  ///       handle(value);
  ///     case RecvEmpty():
  ///       await Future<void>.delayed(backoff);
  ///     case RecvDisconnected():
  ///       break loop;
  ///   }
  /// }
  /// ```
  ///
  /// ⚠️ **A ring channel recovers nothing once the query has completed** — see
  /// [ChannelKind.ring]'s discard-at-disconnect behaviour. A get's completion
  /// normally follows its replies immediately, so a ring reply channel has to
  /// be polled *while the query is in flight*. A **fifo** hands its buffer over
  /// first and only then reports [RecvDisconnected].
  ///
  /// ⚠️ **Timeout expiry is not silent.** When the get's clock runs out, canon
  /// delivers an ERROR reply whose payload is `'Timeout'` through this channel,
  /// and the channel disconnects after it. A consumer that treats every
  /// [RecvDisconnected] as a clean end will report a failed query as a
  /// successful empty one.
  ///
  /// Throws [ZenohException] if the call itself failed — an allocation sized
  /// by the replier could not be satisfied. That is a fault, not a channel
  /// state, so it is thrown rather than returned.
  ///
  /// ## ⚠️ Not usable on a `fifo` channel of capacity 0
  ///
  /// **Measured through this stack, per kind:** a capacity-0 fifo is a
  /// *rendezvous*, not a one-slot buffer — it is full when it is empty. A
  /// delivery therefore blocks waiting for a concurrent consumer, and the
  /// readiness signal this future waits on is only raised *after* that delivery
  /// returns. The parked `recv()` is the only consumer that could release it,
  /// so neither side moves and the future does not resolve.
  ///
  /// Use [tryRecv] at capacity 0 — a synchronous poll *is* the concurrent
  /// consumer, so it releases the delivery and works normally. A capacity-0
  /// **ring** is unaffected (it never blocks its producer), and so is every
  /// capacity of 1 or more on either kind.
  ///
  /// Throws [StateError] if this handle has been [dispose]d. That guard is
  /// ours, not canon's, and it is load-bearing rather than defensive: loaning
  /// a dropped handler is undefined behaviour in canon, never an error it
  /// reports.
  RecvResult<Reply> tryRecv() {
    if (_closed) throw StateError('PullReplies has been disposed');

    final outIsOk = calloc<Int8>();
    final outKeyExpr = calloc<Pointer<Uint8>>();
    final outKeyExprLen = calloc<Size>();
    final outPayload = calloc<Pointer<Uint8>>();
    final outPayloadLen = calloc<Size>();
    final outKind = calloc<Int8>();
    final outEncoding = calloc<Pointer<Char>>();
    final outEncodingLen = calloc<Size>();
    final outAttachment = calloc<Pointer<Uint8>>();
    final outAttachmentLen = calloc<Size>();
    final outTimestamp = calloc<Pointer<Uint8>>();
    final outPriority = calloc<Int8>();
    final outCongestion = calloc<Int8>();
    final outExpress = calloc<Int8>();
    final outReplierZid = calloc<Pointer<Uint8>>();
    final outReplierEid = calloc<Int64>();
    // Seed [10a]: the retained-payload slot, only when this carrier opted in.
    // Sized from zd_bytes_sizeof() at run time, never a literal: 40 unstable,
    // 32 stable.
    final retainSlot = _retainPayload
        ? calloc.allocate<Uint8>(bindings.zd_bytes_sizeof())
        : nullptr;
    final outHasRetained = calloc<Int32>();
    // Whether a ZBytes took ownership of [retainSlot]. Until it does the slot
    // is ours, and the finally releases it on every other path.
    var slotAdopted = false;

    // The buffers the SHIM mallocs and hands over. Captured out here so the
    // finally releases them on every path, including a throw between the rc
    // check and the reads.
    Pointer<Uint8> keyExprPtr = nullptr;
    Pointer<Uint8> payloadPtr = nullptr;
    Pointer<Char> encodingPtr = nullptr;
    Pointer<Uint8> attachmentPtr = nullptr;
    Pointer<Uint8> timestampPtr = nullptr;
    Pointer<Uint8> replierZidPtr = nullptr;

    try {
      final rc = bindings.zd_reply_channel_try_recv(
        _handlerHandle,
        _kind.value,
        outIsOk,
        outKeyExpr.cast(),
        outKeyExprLen,
        outPayload.cast(),
        outPayloadLen,
        outKind,
        outEncoding.cast(),
        outEncodingLen,
        outAttachment.cast(),
        outAttachmentLen,
        outTimestamp.cast(),
        outPriority,
        outCongestion,
        outExpress,
        outReplierZid.cast(),
        outReplierEid,
        retainSlot,
        outHasRetained,
      );

      // Canon's own codes, passed through by the shim and preserved here.
      // These two are STATES, not failures: the only positive result codes in
      // the zenoh-c API, deliberately outside its negative error space.
      if (rc == 1) return const RecvDisconnected<Reply>();
      if (rc == 2) return const RecvEmpty<Reply>();
      if (rc != 0) {
        throw ZenohException('Failed to receive from reply channel', rc);
      }

      keyExprPtr = outKeyExpr.value;
      payloadPtr = outPayload.value;
      encodingPtr = outEncoding.value;
      attachmentPtr = outAttachment.value;
      timestampPtr = outTimestamp.value;
      replierZidPtr = outReplierZid.value;

      final payloadLen = outPayloadLen.value;
      final payloadBytes = (payloadLen > 0 && payloadPtr != nullptr)
          ? Uint8List.fromList(payloadPtr.asTypedList(payloadLen))
          : Uint8List(0);

      // Present on BOTH branches where the unstable API is compiled in; a null
      // zid pointer is the absence discriminator, so the parse is identical on
      // the stable variant rather than shape-dependent.
      final replierId = replierZidPtr == nullptr
          ? null
          : EntityGlobalId(
              ZenohId(Uint8List.fromList(replierZidPtr.asTypedList(16))),
              outReplierEid.value,
            );

      // Length-carried, exactly like the key expression below and for the same
      // reason: a rendered MIME string is an arbitrary byte sequence and canon
      // carries an interior NUL in one byte-exact. The shim allocates
      // unconditionally, so a present-but-empty encoding is a non-NULL pointer
      // at length 0 and reads as '' here, matching the push path.
      final encodingBytes = encodingPtr == nullptr
          ? null
          : Uint8List.fromList(
              encodingPtr.cast<Uint8>().asTypedList(outEncodingLen.value),
            );
      final encodingStr = encodingBytes == null
          ? null
          : utf8.decode(encodingBytes, allowMalformed: true);

      if (outIsOk.value == 0) {
        return RecvData(
          Reply.error(
            ReplyError(
              payloadBytes: payloadBytes,
              payload: utf8.decode(payloadBytes, allowMalformed: true),
              encoding: encodingStr,
              encodingBytes: encodingBytes,
            ),
            replierId: replierId,
          ),
        );
      }

      // Empty != absent: a present-but-empty attachment comes back as a
      // non-null pointer at length 0 (the shim mallocs >= 1 byte), so the
      // discriminator is the POINTER, never the length.
      final attachmentBytes = attachmentPtr == nullptr
          ? null
          : Uint8List.fromList(
              attachmentPtr.asTypedList(outAttachmentLen.value),
            );

      // Length-carried, never strlen-measured: the key expression grammar
      // permits an interior NUL and canon carries one byte-exact, so reading
      // this buffer as a C string would silently truncate a real value.
      final keyExprStr = keyExprPtr == nullptr
          ? ''
          : utf8.decode(
              keyExprPtr.asTypedList(outKeyExprLen.value),
              allowMalformed: true,
            );

      // Seed [10a]: adopt the retained slot. Ownership passes to the ZBytes,
      // whose dispose() and finalizer both release with Dart's allocator --
      // which is exactly why the slot is Dart-allocated.
      ZBytes? retained;
      if (retainSlot != nullptr && outHasRetained.value != 0) {
        retained = ZBytes.fromNative(retainSlot.cast());
        slotAdopted = true;
      }

      return RecvData(
        Reply.ok(
          Sample(
            keyExpr: keyExprStr,
            payload: utf8.decode(payloadBytes, allowMalformed: true),
            payloadBytes: payloadBytes,
            kind: outKind.value == 0 ? SampleKind.put : SampleKind.delete,
            attachment: attachmentBytes == null
                ? null
                : utf8.decode(attachmentBytes, allowMalformed: true),
            attachmentBytes: attachmentBytes,
            encoding: encodingStr,
            encodingBytes: encodingBytes,
            timestamp: timestampPtr == nullptr
                ? null
                : Timestamp.fromRaw(
                    Uint8List.fromList(timestampPtr.asTypedList(24)),
                  ),
            priority: Priority.fromWire(outPriority.value),
            congestionControl: CongestionControl.fromWire(outCongestion.value),
            express: outExpress.value != 0,
            payloadZBytes: retained,
          ),
          replierId: replierId,
        ),
      );
    } finally {
      if (keyExprPtr != nullptr) malloc.free(keyExprPtr.cast());
      if (payloadPtr != nullptr) malloc.free(payloadPtr.cast());
      if (encodingPtr != nullptr) malloc.free(encodingPtr.cast());
      if (attachmentPtr != nullptr) malloc.free(attachmentPtr.cast());
      if (timestampPtr != nullptr) malloc.free(timestampPtr.cast());
      if (replierZidPtr != nullptr) malloc.free(replierZidPtr.cast());
      calloc
        ..free(outIsOk)
        ..free(outKeyExpr)
        ..free(outKeyExprLen)
        ..free(outPayload)
        ..free(outPayloadLen)
        ..free(outKind)
        ..free(outEncoding)
        ..free(outEncodingLen)
        ..free(outAttachment)
        ..free(outAttachmentLen)
        ..free(outTimestamp)
        ..free(outPriority)
        ..free(outCongestion)
        ..free(outExpress)
        ..free(outHasRetained)
        ..free(outReplierZid)
        ..free(outReplierEid);
      if (retainSlot != nullptr && !slotAdopted) {
        calloc.free(retainSlot);
      }
    }
  }

  /// Waits for the next reply.
  ///
  /// Completes with:
  ///
  /// - [RecvData] as soon as a reply is available — immediately if one is
  ///   already buffered, otherwise when the next one arrives.
  /// - [RecvDisconnected] when the query completes, or when this handle is
  ///   [dispose]d — for a fifo, only after its buffered replies have been
  ///   handed over first.
  ///
  /// **It never completes [RecvEmpty]**, and it never hangs. Canon's blocking
  /// `recv` is two-valued for the same reason: it *waits* rather than reporting
  /// an empty buffer, so "nothing right now" is not an outcome it can report.
  /// The type is shared with [tryRecv], so [RecvEmpty] is structurally
  /// reachable and contractually impossible.
  ///
  /// No thread is parked anywhere and no isolate is created. Canon's blocking
  /// `recv` is uninterruptible, so hosting it would make a clean [dispose]
  /// impossible; instead the native side signals readiness and this future does
  /// its consuming through the ordinary synchronous [tryRecv]. Nothing
  /// accumulates while nobody is waiting: what a slow consumer retains is the
  /// channel's own `capacity`, not a queue that grows with traffic.
  ///
  /// Throws [StateError] if a `recv()` is already pending — one pull at a time
  /// per handle. An interleaved [tryRecv] is fine and *wins*: it reaches the
  /// channel first and takes the reply, and the pending `recv()` re-arms and
  /// waits for the next arrival.
  ///
  /// Throws [StateError] if this handle has been [dispose]d.
  Future<RecvResult<Reply>> recv() {
    if (_closed) throw StateError('PullReplies has been disposed');
    if (_pending != null) {
      throw StateError('a recv() is already pending on this PullReplies');
    }

    // Buffered already? Then there is nothing to wait for.
    final immediate = tryRecv();
    if (immediate is! RecvEmpty<Reply>) {
      return Future<RecvResult<Reply>>.value(immediate);
    }

    // REGISTER, THEN ARM, THEN LOOK AGAIN. The order closes the arm-vs-arrival
    // race: the waiter is in place before the native side can signal, and the
    // second look catches a reply that landed between the first look and the
    // arming. Dart is single-threaded, so no port message can be delivered into
    // the gap.
    final completer = Completer<RecvResult<Reply>>();
    _pending = completer;
    bindings.zd_pull_tee_arm(_teeHandle);

    final afterArm = tryRecv();
    if (afterArm is! RecvEmpty<Reply>) {
      _pending = null;
      // The arming stays set and the next delivery spends it on a single ping
      // that `_onWake` discards. Bounded at one, and self-clearing.
      return Future<RecvResult<Reply>>.value(afterArm);
    }

    // At this point the producer closure is alive (canon defines NODATA as
    // "the channel is still alive"), so it has exactly two futures: it
    // delivers — ping — or it is dropped at query completion — sentinel. Both
    // wake us.
    return completer.future;
  }

  /// Handles a readiness ping (an int) or the producer's drop sentinel (null).
  ///
  /// The signal never carries data; it only ever says *look again*.
  void _onWake(dynamic message) {
    final waiter = _pending;
    // No waiter: a ping left over from the arm-vs-arrival race in [recv].
    // Discarding it is correct and it is bounded at one.
    if (waiter == null) return;
    // dispose() already completed this waiter and released the handles.
    if (_closed) return;

    final isSentinel = message == null;
    try {
      var result = tryRecv();
      if (result is RecvEmpty<Reply>) {
        if (isSentinel) {
          // Canon cannot report an empty buffer on a dropped channel — its
          // recv family is a total match with no such arm — so this is
          // unreachable. Normalising it keeps "never completes RecvEmpty" a
          // structural property of this method rather than an inherited hope.
          result = const RecvDisconnected<Reply>();
        } else {
          // An interleaved tryRecv() took the reply. RE-ARM before waiting
          // again: the delivery that pinged us already cleared the flag, so
          // without this the NEXT arrival would post nothing and this waiter
          // would sleep until the disconnect rather than "until the next
          // arrival" as documented.
          bindings.zd_pull_tee_arm(_teeHandle);
          result = tryRecv();
          if (result is RecvEmpty<Reply>) return; // keep awaiting
        }
      }
      _pending = null;
      waiter.complete(result);
    } on Object catch (error, stackTrace) {
      // tryRecv() throws only on a call failure (an allocation the shim could
      // not satisfy). Surfacing it through the future is better than letting it
      // escape into the port's zone as an unhandled async error.
      _pending = null;
      waiter.completeError(error, stackTrace);
    }
  }

  /// Releases this handle.
  ///
  /// **Local only.** Dropping the receiving end of a reply channel undeclares
  /// nothing and tells no peer anything: the query itself still runs to
  /// completion natively, and canon's sender side simply fails fast against a
  /// dropped receiver. That is why this is `dispose()` rather than `close()` —
  /// the binding spells a remote-visible release the second way.
  ///
  /// Any replies still buffered are released with the channel. Drain first if
  /// the residue matters.
  ///
  /// A pending [recv] completes [RecvDisconnected] rather than hanging.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  void dispose() {
    if (_closed) return;
    _closed = true;

    // COMPLETE THE WAITER FIRST, before any native release. `_closed` is
    // already set, so nothing this completion runs can re-enter canon through a
    // handle we are about to release -- which is what keeps a pending recv()
    // from being either a hang or a use-after-free.
    final waiter = _pending;
    _pending = null;
    waiter?.complete(const RecvDisconnected<Reply>());

    // Through the entry matching the kind it was constructed with; the two
    // owned handler types are distinct. Dropping the receiving end while
    // canon's sender may still be live is safe by canon's own construction --
    // its send fails fast against a dropped receiver.
    bindings
      ..zd_reply_handler_drop(_handlerHandle, _kind.value)
      // The Dart handle's side of the tee's reference count. Unlike the sample
      // column there is no entity drop to serialise against, so this may
      // run BEFORE canon drops its closure (and on the normal path it runs
      // after) -- the count is what makes both orders safe.
      ..zd_pull_tee_drop(_teeHandle);
    _receivePort.close();
    calloc.free(_handlerHandle);
  }
}
