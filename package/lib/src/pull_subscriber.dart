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
import 'package:zenoh_dart/src/demand_gated_stream.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/recv_result.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/subscriber.dart' show Subscriber;
import 'package:zenoh_dart/src/timestamp.dart';

/// A zenoh pull subscriber: samples accumulate in a bounded channel and the
/// caller takes them out on demand.
///
/// Unlike [Subscriber], which pushes samples into a stream as they arrive,
/// a PullSubscriber buffers them and hands them over one at a time when
/// [tryRecv] is called — so the consumer sets the pace.
///
/// The [kind] chosen at declaration decides what happens when the buffer
/// fills: [ChannelKind.ring] drops the oldest sample and never blocks the
/// publisher, [ChannelKind.fifo] keeps every sample and blocks the publisher
/// instead. The kinds also differ at the END of a channel's life: when the
/// producer dies, a fifo drains what it still holds before reporting
/// disconnected, while a ring discards it. Both behaviours are canon's own,
/// measured at 1.8.0, and rendered here unsmoothed.
///
/// **Drain only if the residue matters.** [close] releases the channel with
/// whatever it still holds — our handle owns both halves, so there is no
/// post-close drain window. Poll to exhaustion first if you need those
/// samples.
///
/// ⚠️ **This used to read "drain before you close", and it silently carried a
/// CORRECTNESS claim it could not honour.** Closing an undrained, overflowing
/// fifo once hung the calling isolate permanently. That is fixed at the source
/// — [close] now releases the receiving end before undeclaring — and draining
/// could never have prevented it from one isolate anyway: measured at canon
/// level, the hang persisted even after the producer was gone. Draining is
/// residue guidance, and nothing more.
///
/// ⚠️ **One teardown ORDER still matters, and it is canon's, not this
/// binding's:** close pull handles *before* closing their session when a fifo
/// may be in overflow. A session closed first still stalls — measured, and
/// pinned as a residual in `test/fifo_close_deadlock_test.dart`. This unit
/// does not fix that path.
///
/// Call [close] when done to undeclare the subscriber and release native
/// resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: its
/// `close()` is seven steps of which four are Dart-side — completing a pending
/// waiter, releasing the demand gate, closing a `ReceivePort` — and a finalizer
/// callback has no isolate to run them in. It is also never collected in
/// practice, so a finalizer there would be dead code.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class PullSubscriber implements Finalizable {
  /// Internal constructor. Use `Session.declarePullSubscriber` instead.
  PullSubscriber(
    this._subscriberHandle,
    this._handlerHandle,
    this._teeHandle,
    this._receivePort,
    this._keyExpr,
    this._kind, [
    // Positional rather than named: `_retainPayload` is private, and this is
    // an internal constructor reached only from Session/Querier.
    // ignore: avoid_positional_boolean_parameters
    this._retainPayload = false,
  ]) {
    _receivePort.listen(_onWake);
  }

  final Pointer<Uint8> _subscriberHandle;
  final Pointer<Uint8> _handlerHandle;
  final Pointer<Uint8> _teeHandle;
  final ReceivePort _receivePort;
  final String _keyExpr;
  final ChannelKind _kind;

  /// Whether each pulled sample carries a retained [Sample.payloadZBytes].
  final bool _retainPayload;
  bool _closed = false;

  /// The single outstanding [recv] waiter, or null.
  ///
  /// One at a time, deliberately: the native handler is move-only and
  /// single-consumer, so a second pending pull would invent fairness canon
  /// does not define.
  Completer<RecvResult<Sample>>? _pending;

  /// The demand gate behind [stream], created on first access to it.
  ///
  /// Null until someone asks for [stream]: a caller who never does has no gate
  /// at all, which is what keeps [tryRecv] and [recv] byte-identical for them.
  DemandGate<Sample>? _gate;

  /// The key expression this pull subscriber is declared on.
  String get keyExpr => _keyExpr;

  /// The bounded channel kind backing this subscriber.
  ChannelKind get kind => _kind;

  /// A bounded, demand-gated [Stream] view over this handle's own [recv].
  ///
  /// Unlike `Session.declareSubscriber`'s stream, which pushes every arrival
  /// into an unbounded `StreamController` seam, this one **pulls**: it takes
  /// one sample at a time out of the bounded native channel, and only while
  /// the subscription is demanding.
  ///
  /// ## Pausing this subscription really stops the flow
  ///
  /// Nothing is taken out of the native channel while paused, so what
  /// accumulates is the channel's own `capacity` and **at most one
  /// already-pulled sample** — never a queue that grows with traffic. What
  /// happens to the traffic that does not fit is the channel's [kind],
  /// unchanged: a [ChannelKind.ring] drops its oldest *channel* entry and the
  /// publisher keeps running; a [ChannelKind.fifo] holds the publisher back.
  /// **Those are two different promises, and [kind] is where you choose
  /// between them.**
  ///
  /// The "at most one" is structural rather than incidental: the first pull
  /// starts synchronously inside `onListen`, so at most one pull is ever in
  /// flight and the sample completing it goes to a one-slot stash. The
  /// retained amount is therefore **at most `capacity + 1`** — a single
  /// ceiling, rather than one that depends on how the pause was reached.
  ///
  /// ⚠️ A ceiling, not an equality. On this column it is reached even under
  /// heavy overflow — measured, 1024 samples into a `ring, capacity: 8` left
  /// exactly 9. On the query column, where arrivals are concurrent rather than
  /// serial, the same configuration sits one short: canon's ring makes room
  /// *before* it inserts.
  ///
  /// ## ⚠️ This getter is a MODE SWITCH
  ///
  /// Once the returned stream has a listener, the drive loop owns this
  /// handle's [recv]: calling [recv] yourself throws [StateError] while a pull
  /// is in flight, and an interleaved [tryRecv] competes with the loop for
  /// arrivals. Pick one consumption idiom per handle.
  ///
  /// A sample that completed a pull into a paused or cancelled subscription is
  /// **stashed, not dropped**: [tryRecv] hands it back before it touches the
  /// channel, and [close] releases anything still held. Measured: three
  /// samples published after a `cancel()` came back as three, where releasing
  /// the orphaned pull's sample instead returned two.
  ///
  /// ## What the ring drops is the oldest CHANNEL entry, not the oldest sample
  ///
  /// Because the stashed sample is not in the channel, it survives an
  /// eviction the channel makes. Measured on a `ring, capacity: 4` with the
  /// subscription paused before any traffic: six samples in, five delivered —
  /// `m0` (the stash) followed by `m2 … m5`. **The entry evicted was `m1`.**
  ///
  /// ## ⚠️ Capacity 0, measured per kind — this column only
  ///
  /// On a [ChannelKind.fifo] at capacity 0 this stream delivers **nothing**
  /// while nothing else consumes it. That is [recv]'s documented rendezvous
  /// restriction, inherited: the loop drives [recv], and the parked [recv] is
  /// the only consumer that could release the delivery it is waiting on.
  /// ⚠️ **A single interleaved [tryRecv] un-wedges the chain and the stream
  /// then delivers the rest** — measured: the poll took the first sample and
  /// the stream then delivered the remaining three. On [ChannelKind.ring] at
  /// capacity 0 the stream **does** deliver.
  ///
  /// ## Teardown, and who closes the stream in each state
  ///
  /// With a pull still in flight — paused or not — [close] completes it and
  /// the loop's own terminal arm closes the stream. With the loop already
  /// exited holding a stash (a `pause()` taken inside `onData`, then one
  /// further arrival) only [close]'s own gate step can close it. Closing the
  /// **session** before this handle reaches the same terminal arm. ⚠️ Closing
  /// the session first while a fifo is in overflow stalls exactly as it does
  /// for the polling handle today — pinned in
  /// `test/fifo_close_deadlock_test.dart`, and unchanged by this stream.
  ///
  /// ⚠️ On a liveliness carrier (`Session.declarePullLivelinessSubscriber`,
  /// which returns this same type, so this stream is already available there)
  /// the choice of [kind] carries an extra hazard — see that method's own
  /// "Think twice before choosing ring here".
  ///
  /// Single-subscription, like every other stream in this package. Throws
  /// [StateError] if this subscriber has been [close]d, exactly as [tryRecv]
  /// and [recv] do.
  Stream<Sample> get stream {
    if (_closed) throw StateError('PullSubscriber is closed');
    return (_gate ??= DemandGate<Sample>(
      pull: recv,
      // A Sample holds no native resource, so there is nothing to release.
      release: (_) {},
    )).stream;
  }

  /// Whether the [stream] drive loop has a pull outstanding right now.
  /// **Test instrument only.**
  ///
  /// The drive loop's state is not inferable from a recipe — whether a pause
  /// leaves a pull in flight depends on where in the loop it landed — and
  /// cells that inferred it instead of asserting it were the failure this
  /// observable exists to prevent. Same precedent as [teeAddressForTesting].
  ///
  /// Reads `false` when [stream] was never accessed: no gate, no loop.
  @internal
  @visibleForTesting
  bool get pullInFlightForTesting => _gate?.inFlight ?? false;

  /// Whether the [stream] gate is holding a stashed sample. **Test instrument
  /// only.** See [pullInFlightForTesting].
  @internal
  @visibleForTesting
  bool get stashHeldForTesting => _gate?.hasStash ?? false;

  /// The shim-owned readiness-tee block's address. **Test instrument only.**
  ///
  /// A resource defect is invisible to a behavioural assertion: a leaked tee
  /// context neither throws nor corrupts, and every lifecycle test passes
  /// identically on leaking and on fixed code. The only instrument that can
  /// see it is counting DISTINCT BLOCK ADDRESSES over many cycles, which
  /// needs the address. A same-size probe was the alternative and is recorded
  /// in `ffi_ownership_test.dart` as non-discriminating for the neighbouring
  /// case -- declaration churns the arena enough to swamp a small proxy.
  @internal
  @visibleForTesting
  int get teeAddressForTesting => _teeHandle.address;

  /// The owned handler slot's address. **Test instrument only.** See
  /// [teeAddressForTesting].
  @internal
  @visibleForTesting
  int get handlerAddressForTesting => _handlerHandle.address;

  /// Tries to receive a sample, without waiting.
  ///
  /// Returns canon's own three-way outcome, undiluted:
  ///
  /// - [RecvData] -- a sample was taken out of the buffer.
  /// - [RecvEmpty] -- the channel is alive and its buffer is empty right
  ///   now. Back off and call again; a later call may well succeed.
  /// - [RecvDisconnected] -- the producing end is gone (its subscriber was
  ///   undeclared, or its session closed). Terminal and sticky: every
  ///   subsequent call reports it again. Stop polling.
  ///
  /// This is the loop canon's own `z_non_blocking_get.c` writes, and the
  /// discriminant is what makes its exit condition expressible:
  ///
  /// ```dart
  /// loop:
  /// while (true) {
  ///   switch (pull.tryRecv()) {
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
  /// Throws [ZenohException] if the call itself failed -- an allocation
  /// sized by the remote publisher could not be satisfied. That is a fault,
  /// not a channel state, so it is thrown rather than returned: no switch
  /// site should have to handle conditions canon calls call failures.
  ///
  /// Throws [StateError] if this subscriber has been closed. That guard is
  /// ours, not canon's, and it is load-bearing rather than defensive:
  /// loaning a dropped handler is undefined behaviour in canon, never an
  /// error it reports.
  RecvResult<Sample> tryRecv() {
    if (_closed) throw StateError('PullSubscriber is closed');

    // THE STASH IS CONSULTED FIRST, ahead of the native channel.
    //
    // A sample that completed the [stream] drive loop's pull into a paused or
    // cancelled subscription is held in a one-slot stash rather than dropped,
    // and this is its retrieval exit. Taking it before the channel is what
    // preserves the ordering [recv]'s own dartdoc already publishes: an
    // interleaved `tryRecv` "is fine and *wins*". Measured without this
    // branch, three samples published after a cancel came back as two.
    //
    // A caller who never touched [stream] has no gate at all, so this reads
    // null and the path below is byte-identical to what shipped.
    final stashed = _gate?.takeStash();
    if (stashed != null) return RecvData(stashed);

    final outKeyexpr = calloc<Pointer<Uint8>>();
    final outKeyexprLen = calloc<Size>();
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
    // Seed [10a]: the retained-payload slot. ALLOCATE-LAST and only when this
    // carrier opted in — a retention-off pull pays nothing. The size comes
    // from zd_bytes_sizeof() at run time, never a literal: it is 40 on the
    // unstable build and 32 on stable.
    final retainSlot = _retainPayload
        ? calloc.allocate<Uint8>(bindings.zd_bytes_sizeof())
        : nullptr;
    final outHasRetained = calloc<Int32>();

    // The five buffers the SHIM mallocs and hands over. Captured here so the
    // finally can release them: they used to be freed by straight-line code in
    // the try body, which any throw between the rc check and those lines
    // skipped -- all five leaked together.
    Pointer<Uint8> keyExprPtr = nullptr;
    Pointer<Uint8> payloadPtr = nullptr;
    Pointer<Char> encodingPtr = nullptr;
    Pointer<Uint8> attachmentPtr = nullptr;
    Pointer<Uint8> timestampPtr = nullptr;

    // Whether a ZBytes took ownership of [retainSlot]. Until it does, the slot
    // is ours and the finally releases it -- an EMPTY or DISCONNECTED result,
    // or any throw, must not leak it.
    var slotAdopted = false;

    try {
      final rc = bindings.zd_pull_subscriber_try_recv(
        _handlerHandle,
        _kind.value,
        outKeyexpr.cast(),
        outKeyexprLen,
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
        retainSlot,
        outHasRetained,
      );

      // Canon's own codes, passed through by the shim and preserved here.
      // These two are STATES, not failures: they are the only positive
      // result codes in the zenoh-c API, deliberately outside its negative
      // error space, and a consumer switches on them.
      if (rc == 1) return const RecvDisconnected<Sample>();
      if (rc == 2) return const RecvEmpty<Sample>();
      // Anything else is the call itself failing. Today that is only the
      // shim's -1, raised when one of the four remote-length-driven mallocs
      // returns NULL; the shim has already released whatever it held, so
      // there is nothing here to reclaim beyond the finally below. It used
      // to be swallowed into the same `null` as an empty buffer, which made
      // an out-of-memory indistinguishable from "nothing published yet".
      if (rc != 0) {
        throw ZenohException('Failed to receive from pull subscriber', rc);
      }

      // Extract fields from malloc'd pointers
      keyExprPtr = outKeyexpr.value;
      payloadPtr = outPayload.value;
      encodingPtr = outEncoding.value;
      attachmentPtr = outAttachment.value;
      timestampPtr = outTimestamp.value;

      // Length-carried, never strlen-measured: the key expression grammar
      // permits an interior NUL and canon carries one byte-exact, so reading
      // this buffer as a C string would silently truncate a real value.
      final keyExprStr = utf8.decode(
        keyExprPtr.asTypedList(outKeyexprLen.value),
        allowMalformed: true,
      );

      final payloadLen = outPayloadLen.value;
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

      // Length-carried, exactly like the key expression above and for the
      // same reason: a rendered MIME string is an arbitrary byte sequence and
      // canon carries an interior NUL in one byte-exact. Reading to the first
      // NUL truncated it.
      //
      // ⚠️ This replaces a helper whose doc comment said the opposite by
      // implication -- "only the encoding still arrives this way; the key
      // expression is length-carried, because its domain genuinely does admit
      // an interior NUL". The contrast was false: BOTH domains admit one. The
      // reason it carried (ownership sweep F-R1, which probe-refuted the remote
      // non-UTF-8 trigger for this field) is true and is about a different
      // property -- a strict-decode CRASH, not length carriage.
      //
      // The decode stays LENIENT, which is the part of that helper worth
      // keeping: an invalid sequence becomes U+FFFD rather than throwing
      // `FormatException`, as on every other receive surface here.
      // (`Pointer<Utf8>.toDartString()` decodes strictly and has no lenient
      // mode, which is why this is spelled out rather than delegated.)
      //
      // Empty is not absent -- the shim allocates unconditionally, so a
      // present-but-empty encoding is a NON-NULL pointer at length 0 and reads
      // as '' here, matching the push path.
      String? encodingStr;
      Uint8List? encodingBytes;
      if (encodingPtr != nullptr) {
        encodingBytes = Uint8List.fromList(
          encodingPtr.cast<Uint8>().asTypedList(outEncodingLen.value),
        );
        encodingStr = utf8.decode(encodingBytes, allowMalformed: true);
      }

      final attachmentLen = outAttachmentLen.value;
      String? attachmentStr;
      Uint8List? attachmentBytes;
      // Empty != absent: a present-but-empty attachment comes back as a
      // non-null pointer with len 0 (the C shim mallocs >= 1 byte so the
      // pointer is non-null). Key on the pointer, not the length, so an empty
      // attachment surfaces as a non-null empty Uint8List rather than null.
      if (attachmentPtr != nullptr) {
        attachmentBytes = Uint8List.fromList(
          attachmentPtr.asTypedList(attachmentLen),
        );
        attachmentStr = utf8.decode(attachmentBytes, allowMalformed: true);
      }

      // Timestamp (nullable): present when the C side malloc'd a 24-byte image.
      Timestamp? timestamp;
      if (timestampPtr != nullptr) {
        timestamp = Timestamp.fromRaw(
          Uint8List.fromList(timestampPtr.asTypedList(24)),
        );
      }

      // QoS: wire priority is 1..7 -> Priority.fromWire; congestion is
      // 0/1 -> CongestionControl.fromWire; express is a 0/1 flag.
      final priority = Priority.fromWire(outPriority.value);
      final congestionControl = CongestionControl.fromWire(outCongestion.value);
      final express = outExpress.value != 0;

      // Seed [10a]: adopt the retained slot. The slot is Dart-allocated, which
      // is exactly what ZBytes.dispose() and the finalizer both require, so
      // ownership passes to the ZBytes and the finally must NOT free it.
      ZBytes? retained;
      if (retainSlot != nullptr && outHasRetained.value != 0) {
        retained = ZBytes.fromNative(retainSlot.cast());
        slotAdopted = true;
      }

      return RecvData(
        Sample(
          keyExpr: keyExprStr,
          payload: payloadStr,
          payloadBytes: payloadBytes,
          kind: kind == 0 ? SampleKind.put : SampleKind.delete,
          attachment: attachmentStr,
          attachmentBytes: attachmentBytes,
          encoding: encodingStr,
          encodingBytes: encodingBytes,
          timestamp: timestamp,
          priority: priority,
          congestionControl: congestionControl,
          express: express,
          payloadZBytes: retained,
        ),
      );
    } finally {
      // The shim-transferred buffers first (see the declarations above), then
      // our own out-parameter cells.
      if (keyExprPtr != nullptr) malloc.free(keyExprPtr.cast());
      if (payloadPtr != nullptr) malloc.free(payloadPtr.cast());
      if (encodingPtr != nullptr) malloc.free(encodingPtr.cast());
      if (attachmentPtr != nullptr) malloc.free(attachmentPtr.cast());
      if (timestampPtr != nullptr) malloc.free(timestampPtr.cast());
      calloc
        ..free(outKeyexpr)
        ..free(outKeyexprLen)
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
        ..free(outHasRetained);
      if (retainSlot != nullptr && !slotAdopted) {
        calloc.free(retainSlot);
      }
    }
  }

  /// Waits for the next sample.
  ///
  /// Completes with:
  ///
  /// - [RecvData] as soon as a sample is available — immediately if one is
  ///   already buffered, otherwise when the next one arrives.
  /// - [RecvDisconnected] when the channel dies (its session closes, or this
  ///   subscriber is [close]d) — for a fifo, only after its buffered samples
  ///   have been handed over first.
  ///
  /// **It never completes [RecvEmpty]**, and it never hangs. Canon's blocking
  /// `recv` is two-valued for the same reason: it *waits* rather than
  /// reporting an empty buffer, so "nothing right now" is not an outcome it
  /// can report. The type is shared with [tryRecv] — exactly as the C++
  /// binding shares one result type across both — so [RecvEmpty] is
  /// structurally reachable and contractually impossible.
  ///
  /// No thread is parked anywhere. Canon's blocking `recv` is
  /// uninterruptible, so hosting it would make a clean [close] impossible;
  /// instead the native side signals readiness and this future does its
  /// consuming through the ordinary synchronous [tryRecv]. Nothing
  /// accumulates while nobody is waiting: what a slow consumer retains is the
  /// channel's own `capacity`, not a queue that grows with traffic.
  ///
  /// Throws [StateError] if a `recv()` is already pending — one pull at a
  /// time per handle. An interleaved [tryRecv] is fine and *wins*: it reaches
  /// the channel first and takes the sample, and the pending `recv()` simply
  /// stays pending until the next arrival.
  ///
  /// Throws [StateError] if this subscriber has been closed.
  ///
  /// ## ⚠️ Not usable on a `fifo` channel of capacity 0
  ///
  /// **Measured at zenoh-c 1.8.0:** a capacity-0 fifo is a *rendezvous*, not
  /// a one-slot buffer — it is full when it is empty. A publisher's delivery
  /// therefore blocks waiting for a concurrent consumer, and the readiness
  /// signal this future waits on is only raised *after* that delivery
  /// returns. The parked `recv()` is the only consumer that could unblock it,
  /// so neither side moves and the future does not complete until the
  /// channel closes.
  ///
  /// Use [tryRecv] at capacity 0 — a synchronous poll *is* the concurrent
  /// consumer, so it releases the delivery and works normally. Or use any
  /// capacity of 1 or more, where the two conditions cannot coincide and
  /// `recv()` behaves exactly as documented above.
  ///
  /// This affects no other configuration: every capacity ≥ 1 on either kind,
  /// and every capacity on [ChannelKind.ring], are unaffected.
  Future<RecvResult<Sample>> recv() {
    if (_closed) throw StateError('PullSubscriber is closed');
    if (_pending != null) {
      throw StateError('a recv() is already pending on this PullSubscriber');
    }

    // Buffered already? Then there is nothing to wait for.
    final immediate = tryRecv();
    if (immediate is! RecvEmpty<Sample>) {
      return Future<RecvResult<Sample>>.value(immediate);
    }

    // REGISTER, THEN ARM, THEN LOOK AGAIN. The order closes the arm-vs-arrival
    // race: the waiter is in place before the native side can signal, and the
    // second look catches a sample that landed between the first look and the
    // arming. Dart is single-threaded, so no port message can be delivered
    // into the gap.
    final completer = Completer<RecvResult<Sample>>();
    _pending = completer;
    bindings.zd_pull_tee_arm(_teeHandle);

    final afterArm = tryRecv();
    if (afterArm is! RecvEmpty<Sample>) {
      _pending = null;
      // The arming stays set and the next delivery spends it on a single ping
      // that `_onWake` discards. Bounded at one, and self-clearing.
      return Future<RecvResult<Sample>>.value(afterArm);
    }

    // At this point the producer closure is alive (canon defines NODATA as
    // "the channel is still alive"), so it has exactly two futures: it
    // delivers — ping — or it is dropped — sentinel. Both wake us.
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
    // close() already completed this waiter and dropped the native handles.
    if (_closed) return;

    final isSentinel = message == null;
    try {
      var result = tryRecv();
      if (result is RecvEmpty<Sample>) {
        if (isSentinel) {
          // Canon cannot report an empty buffer on a dropped channel — its
          // recv family is a total match with no such arm — so this is
          // unreachable. Normalising it keeps "never completes RecvEmpty" a
          // structural property of this method rather than an inherited hope.
          result = const RecvDisconnected<Sample>();
        } else {
          // An interleaved tryRecv() took the sample. RE-ARM before waiting
          // again: the delivery that pinged us already cleared the flag, so
          // without this the NEXT arrival would post nothing and this waiter
          // would sleep until the disconnect rather than "until the next
          // arrival" as documented.
          bindings.zd_pull_tee_arm(_teeHandle);
          result = tryRecv();
          if (result is RecvEmpty<Sample>) return; // keep awaiting
        }
      }
      _pending = null;
      waiter.complete(result);
    } on Object catch (error, stackTrace) {
      // tryRecv() throws only on a call failure (an allocation the shim could
      // not satisfy). Surfacing it through the future is better than letting
      // it escape into the port's zone as an unhandled async error.
      _pending = null;
      waiter.completeError(error, stackTrace);
    }
  }

  /// Closes the pull subscriber and releases native resources.
  ///
  /// A pending [recv] completes [RecvDisconnected] rather than hanging.
  ///
  /// **Returns even when the channel is full and nothing has been drained.**
  /// A [ChannelKind.fifo] channel in overflow used to hang the calling isolate
  /// here, permanently and unrecoverably; it no longer does, and
  /// `test/fifo_close_deadlock_test.dart` is what keeps that true.
  ///
  /// Any samples still buffered are released with the channel — drain first if
  /// you need them, not because closing otherwise misbehaves.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;

    // COMPLETE THE WAITER FIRST, before any native drop. `_closed` is already
    // set, so nothing this completion runs can re-enter canon through a
    // handle we are about to release -- which is what keeps a pending recv()
    // from being either a hang or a use-after-free.
    final waiter = _pending;
    _pending = null;
    waiter?.complete(const RecvDisconnected<Sample>());

    // CLOSE THE DEMAND GATE NEXT, still before any native drop. Same
    // principle as the waiter above: everything Dart-side that could re-enter
    // canon through a handle we are about to release is quiesced first, and
    // the gate's own closed flag is what stops its loop calling [recv] again.
    //
    // It also releases whatever the gate still had stashed -- the stash's
    // second exit, so the retrieval remedy does not trade a lost sample for a
    // leak. On this column the release is a no-op (a Sample holds no native
    // resource); on the query column it is `Query.dispose`.
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
    // ⚠️ THIS STEP IS LOAD-BEARING IN EXACTLY ONE TEARDOWN STATE, and the
    // other two are what make that measurable. With a pull still in flight --
    // paused or not -- the waiter completion above reaches the loop's own
    // terminal arm and the controller closes without this line (measured:
    // `onDone fired=true` either way). But a loop that PAUSED INSIDE `onData`
    // and then stashed one further arrival has EXITED; nothing else can close
    // the controller. Measured without this line: `onDone fired=false`.
    _gate?.close();

    // DROP THE HANDLER FIRST, then undeclare, TEE LAST.
    //
    // ⚠️ THIS COMMENT REPLACES ONE THAT REASONED CORRECTLY AND REACHED A
    // DEADLOCKING CONCLUSION. It said the tee drop must come after
    // `zd_subscriber_drop` because that call "blocks until executing callbacks
    // are destroyed (zenoh-c 1.8.0 #1221), so by here no delivery can still be
    // inside the tee." Every clause of that was TRUE. What it never asked was
    // what happens if the undeclare NEVER RETURNS -- and on a full fifo it does
    // not, because canon's fifo callback is a `send()` on a bounded flume
    // channel that blocks when full, and the only consumer that could release
    // it is the isolate now parked inside this synchronous FFI call. Three
    // reviews passed over it. The `#1221` constraint it encodes is real and is
    // preserved on the tee drop below; only the conclusion drawn from it was
    // wrong.
    //
    // HANDLER FIRST, because dropping the receiving end makes a parked send
    // fail fast against a dropped receiver -- the callback completes, and the
    // undeclare then finds nothing running. That is canon's own construction,
    // and `PullReplies.dispose` already relies on it on the third column.
    //
    // The handler goes through the entry matching the kind it was declared
    // with, because the two owned handler types are distinct and releasing
    // one through the other's entry is undefined behaviour rather than a
    // reported error.
    bindings
      ..zd_pull_handler_drop(_handlerHandle, _kind.value)
      ..zd_subscriber_drop(_subscriberHandle.cast())
      // ⚠️ TEE LAST -- the surviving half of `#1221`, and it now stands on its
      // own ground rather than on the undeclare's. The head carries an
      // `atomic_int refcount` initialised to 2, decremented once by canon's
      // closure drop and once by this handle, last one frees
      // (`src/zenoh_dart.c:756-788`, `:813-824`, `:898-904`) -- so the free is
      // order-INDEPENDENT by construction, and both decrements still occur
      // exactly once after the reorder. Verified as a RESOURCE rather than
      // asserted: `ffi_ownership_test.dart`'s counted legs carry a four-way
      // injected calibration in this exact overflow configuration.
      ..zd_pull_tee_drop(_teeHandle);
    _receivePort.close();
    // Free allocated handle memory (ours; the tee block was the shim's).
    calloc
      ..free(_subscriberHandle)
      ..free(_handlerHandle);
  }
}
