import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/locality.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart' show Session;
import 'package:zenoh_dart/src/timestamp.dart';

/// A zenoh subscriber that receives samples on a key expression.
///
/// Wraps `z_owned_subscriber_t`. Samples are delivered asynchronously
/// via a [Stream]. Call [close] when done to undeclare the subscriber
/// and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: the
/// resource a user holds is the STREAM, and the stream does not reference this
/// wrapper — so it is collected while still in use. Measured: 3 samples
/// delivered becomes 0.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class Subscriber implements Finalizable {
  /// Creates a subscriber on the given session and key expression.
  ///
  /// This is called internally by [Session.declareSubscriber].
  factory Subscriber.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe, {
    required String keyExpr,
    Locality? allowedOrigin,
    bool retainPayload = false,
  }) {
    final size = bindings.zd_subscriber_sizeof();
    final ptr = calloc.allocate<Void>(size);

    final channel = createSampleChannel(retainPayload: retainPayload);

    final rc = bindings.zd_declare_subscriber(
      loanedSession.cast(),
      ptr.cast(),
      loanedKe.cast(),
      channel.receivePort.sendPort.nativePort,
      allowedOrigin?.value ?? -1,
      retainPayload ? 1 : 0,
    );

    if (rc != 0) {
      // Declaration failure: nothing has arrived, so there is nothing to
      // release -- abandon() asserts that rather than draining.
      channel.abandon();
      calloc.free(ptr);
      throw ZenohException('Failed to declare subscriber', rc);
    }

    return Subscriber._(ptr, channel, keyExpr);
  }

  Subscriber._(this._ptr, this._channel, this._keyExpr);

  /// Creates a Subscriber from a pre-allocated native handle and a
  /// [SampleChannel].
  ///
  /// Used by [Session.declareLivelinessSubscriber] where the native
  /// subscriber is declared through a different C shim function but
  /// uses the same `z_owned_subscriber_t` type.
  factory Subscriber.fromParts(
    Pointer<Void> ptr,
    SampleChannel channel,
    String keyExpr,
  ) {
    return Subscriber._(ptr, channel, keyExpr);
  }

  final Pointer<Void> _ptr;
  final SampleChannel _channel;
  final String _keyExpr;
  bool _closed = false;

  /// The key expression this subscriber is declared on.
  ///
  /// The declared expression as the caller gave it, whether that was a
  /// `String` or a `KeyExpr` — both entry forms of the union reach the same
  /// value.
  ///
  /// Dart-side state, so it survives [close] and the session's own close.
  /// That is deliberate and matches `PullSubscriber`, `Queryable` and
  /// `LivelinessToken`: reading back what you declared is not an operation on
  /// the native handle, so there is nothing for a disposed-handle guard to
  /// protect.
  String get keyExpr => _keyExpr;

  /// Sets up the [ReceivePort] / [StreamController] pair that parses incoming
  /// NativePort sample messages into [Sample] objects.
  ///
  /// Returns a [SampleChannel]. The caller passes
  /// `channel.receivePort.sendPort.nativePort` to the C shim, calls
  /// [SampleChannel.abandon] if the declaration itself fails, and
  /// [SampleChannel.closeAndDrain] on close.
  ///
  /// [retainPayload] must match what was passed to the shim. It arms the
  /// delivered-tracking that releases retained handles nobody received; with
  /// retention off nothing is tracked and the stream is the bare controller.
  static SampleChannel createSampleChannel({bool retainPayload = false}) {
    final receivePort = ReceivePort();
    final controller = StreamController<Sample>();
    final channel = SampleChannel._(receivePort, controller, retainPayload);

    receivePort.listen((dynamic message) {
      if (message == null) {
        receivePort.close();
        unawaited(controller.close());
      } else if (message is List) {
        // The key expression arrives length-carried, not as a C string, so an
        // interior NUL survives -- the grammar permits one and canon carries
        // it byte-exact. Decoded leniently like every other display string
        // here: an invalid sequence becomes U+FFFD rather than throwing.
        final keyExprBytes = message[0] as Uint8List;
        final keyExpr = utf8.decode(keyExprBytes, allowMalformed: true);
        // ⛔ A VALUE THAT COULD NOT BE CONVERTED IS AN ERROR, NEVER AN
        // EMPTY SUCCESS. The shim used to post a zero-length buffer when
        // canon refused the conversion, which is indistinguishable from a
        // legitimately empty value — and empty is legitimate on every one of
        // these paths. Following the shipped call-failure rule: the error
        // goes to the error channel and the stream KEEPS RUNNING, because a
        // conversion failure is a failed call and not a dead channel.
        final payloadFailure = undecodableRc(message[1]);
        if (payloadFailure != null) {
          controller.addError(undecodableError('a payload', payloadFailure));
          return;
        }
        final attachmentFailure = undecodableRc(message[3]);
        if (attachmentFailure != null) {
          controller.addError(
            undecodableError('an attachment', attachmentFailure),
          );
          return;
        }
        final payloadBytes = message[1] as Uint8List;
        final kind = message[2] as int;
        final attachmentBytes = message[3] as Uint8List?;
        // The encoding arrives length-carried too, for the same reason the key
        // expression does: a rendered MIME string is an arbitrary byte
        // sequence and canon carries an interior NUL across the wire
        // byte-exact. The lenient String is a display view; encodingBytes is
        // the ground truth.
        final encodingBytes = message.length > 4
            ? message[4] as Uint8List?
            : null;
        // Slice 2: QoS/timestamp metadata (length-guarded, defensive).
        final timestampBytes = message.length > 5
            ? message[5] as Uint8List?
            : null;
        final priorityRaw = message.length > 6 ? message[6] as int : null;
        final congestionRaw = message.length > 7 ? message[7] as int : null;
        final expressRaw = message.length > 8 ? message[8] as int : null;
        // Seed [10a] element 9: the retained payload handle image, or null
        // when this carrier did not opt in. Length-guarded like every element
        // above it, so a retention-off carrier and an older message shape both
        // land on null rather than tripping a range error.
        final retainedImage = message.length > 9
            ? message[9] as Uint8List?
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
          // Wire priority is 1..7 -> Priority.fromWire (send symmetric).
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

        if (controller.isClosed) {
          // DRAIN BRANCH: closeAndDrain() already ran and this message was
          // still sitting in the port queue. Nobody can ever receive it, so
          // release its retained handle here instead of orphaning it.
          sample.payloadZBytes?.dispose();
          return;
        }

        final retained = sample.payloadZBytes;
        if (retained != null) {
          channel._undelivered.add(retained);
        }
        controller.add(sample);
      }
    });

    return channel;
  }

  /// A stream of [Sample]s received by this subscriber.
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
  /// the channel's `ChannelKind` — `ring` drops and keeps the publisher
  /// running, `fifo` holds the publisher back.
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
  Stream<Sample> get stream => _channel.stream;

  /// Undeclares the subscriber and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_subscriber_drop(_ptr.cast());
    // closeAndDrain, not a bare port close: a retained handle that arrived and
    // was never delivered has no other owner, so this is its only release.
    _channel.closeAndDrain();
    calloc.free(_ptr);
  }
}

/// The [ReceivePort] / [StreamController] pair behind every sample-carrying
/// surface, plus the delivered-tracking that a **retained payload** needs.
///
/// Modelled directly on `QueryChannel`, which solved the same problem for the
/// query column: a carrier that hands a caller an object backed by native
/// memory must track what it has **delivered**, because only the *undelivered*
/// ones have no other owner.
///
/// ## ⛔ Why the filter is armed by the flag rather than applied always
///
/// `QueryChannel` can write its stream as
/// `_controller.stream.where(_undelivered.remove)` because **every** query it
/// parses enters the set. Samples do not: with
/// retention off no handle exists and nothing is ever added, so that same
/// filter would return `false` for every sample and the subscriber would
/// **deliver nothing at all**. Arming it on the flag is what makes the shape
/// transfer — and it is also why retention-off carriers pay nothing here: no
/// set, no filter, no per-sample work.
class SampleChannel {
  SampleChannel._(this.receivePort, this._controller, this._retainPayload);

  /// The port the C shim posts sample messages to.
  final ReceivePort receivePort;

  final StreamController<Sample> _controller;

  /// Whether this carrier asked the shim for retained payload handles.
  final bool _retainPayload;

  /// Retained handles parsed off the port that no listener has received yet.
  ///
  /// Identity-based: two distinct handles over equal bytes are never "equal",
  /// and it is the handle, not the [Sample], that has a release.
  final Set<ZBytes> _undelivered = Set<ZBytes>.identity();

  /// Samples as the consumer sees them.
  ///
  /// Passing through the filter **is** delivery — a sample still buffered in
  /// the controller has not reached anyone, which is what makes [_undelivered]
  /// exact. It doubles as the suppression point: [closeAndDrain] disposes the
  /// undelivered handles and clears the set, so any sample the closing
  /// controller still flushes is filtered out rather than handed over carrying
  /// an already-disposed handle.
  Stream<Sample> get stream => _retainPayload
      ? _controller.stream.where(_markDelivered)
      : _controller.stream;

  bool _markDelivered(Sample sample) {
    final retained = sample.payloadZBytes;
    // A sample with no handle has nothing to track and is never suppressed —
    // a DELETE with retention off, or a shape that carried no element 9.
    if (retained == null) return true;
    return _undelivered.remove(retained);
  }

  /// Tears the channel down when the declaration itself failed.
  ///
  /// No sample can have arrived, so there is nothing to drain — asserting the
  /// absence is the whole content of this path.
  void abandon() {
    receivePort.close();
    unawaited(_controller.close());
  }

  /// Releases every retained handle that arrived but was never delivered,
  /// then closes.
  ///
  /// Two halves, because a handle can be stranded in either of two places:
  ///
  /// 1. **Controller buffer** — parsed into a [Sample] but not yet delivered.
  ///    Disposed directly from [_undelivered].
  /// 2. **Port queue** — still an unparsed NativePort message. Closing the
  ///    port in the same turn discards these; deferring the close by one
  ///    event-loop turn delivers them, and the listener's `isClosed` branch
  ///    disposes each as it lands. So the close is deferred.
  void closeAndDrain() {
    for (final retained in _undelivered) {
      retained.dispose();
    }
    _undelivered.clear();
    // isClosed flips synchronously here — that is what arms the listener's
    // drain branch for half 2 above.
    unawaited(_controller.close());
    unawaited(Future<void>(receivePort.close));
  }
}
