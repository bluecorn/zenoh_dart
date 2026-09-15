import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/subscriber.dart';

/// Options for detecting matching advanced publishers.
///
/// The *presence* of this object on
/// [AdvancedSubscriberOptions.detectPublishers] enables detection; this object
/// carries only the history flag. Splitting the two axes makes the invalid
/// combination — asking for history with detection off — unrepresentable
/// rather than silently ignored.
///
/// Canon models the same thing as a struct
/// (`z_liveliness_subscriber_options_t`), which is why a presence carries the
/// enable axis here while `enableMatchingListener` on the publisher side is a
/// bare `bool`: canon's matching listener has no options struct to stand in
/// for.
class DetectPublishersOptions {
  /// Creates detect-publishers options.
  const DetectPublishersOptions({this.history, this.retainPayload = false});

  /// Whether to receive events for advanced publishers that were already
  /// live when detection was declared.
  ///
  /// `null` means **canon decides** — NULL options are passed and canon's own
  /// default applies, which is `false`.
  final bool? history;

  /// Whether detection samples carry a retained [Sample.payloadZBytes].
  ///
  /// This is the SIXTH sample-carrying registration in the shim, and it takes
  /// its own flag rather than inheriting the subscriber's: it is a separate
  /// closure on a separate port, so a caller retaining data samples has not
  /// thereby asked to retain detection samples.
  final bool retainPayload;
}

/// Options for configuring an advanced subscriber.
class AdvancedSubscriberOptions {
  /// Creates advanced subscriber options.
  const AdvancedSubscriberOptions({
    this.detectPublishers,
    this.history = false,
    this.detectLatePublishers = false,
    this.recovery = false,
    this.lastSampleMissDetection = false,
    this.periodicQueriesPeriodMs = 0,
    this.subscriberDetection = false,
    this.enableMissListener = false,
    this.retainPayload = false,
  });

  /// Publisher detection, or `null` to not detect publishers.
  ///
  /// Presence enables detection and makes
  /// [AdvancedSubscriber.detectedPublishers] non-null; the object carries the
  /// history flag.
  final DetectPublishersOptions? detectPublishers;

  /// Whether to recover historical data on subscription.
  final bool history;

  /// Whether to detect late publishers and recover their history.
  final bool detectLatePublishers;

  /// Whether to enable sample recovery.
  final bool recovery;

  /// Whether to enable last sample miss detection for recovery.
  final bool lastSampleMissDetection;

  /// Period in milliseconds for periodic recovery queries.
  ///
  /// `0` is canon's own default and means "leave canon's setting alone", not
  /// "disabled" — the shim only assigns this field when it is greater than
  /// zero. The earlier "(0 = disabled)" wording claimed a behaviour the code
  /// does not implement; it happens to be harmless, because canon's default
  /// for this field is also 0.
  final int periodicQueriesPeriodMs;

  /// Whether to enable subscriber detection.
  final bool subscriberDetection;

  /// Whether to enable the miss event listener.
  final bool enableMissListener;

  /// Whether each delivered sample carries a retained [Sample.payloadZBytes].
  ///
  /// See `Session.declareSubscriber` for what retention costs and promises.
  /// Off by default, like every other retention entry.
  ///
  /// ⚠️ This governs the advanced subscriber's OWN sample stream only. The
  /// publisher-detection stream is a separate registration with its own
  /// [DetectPublishersOptions.retainPayload].
  final bool retainPayload;
}

/// Information about missed samples from a source.
class MissEvent {
  /// Creates a MissEvent.
  const MissEvent({required this.sourceId, required this.count});

  /// The [EntityGlobalId] (zid + eid) of the source that missed samples.
  final EntityGlobalId sourceId;

  /// The number of missed samples.
  final int count;
}

/// An advanced subscriber with history recovery and miss detection.
///
/// Wraps `ze_owned_advanced_subscriber_t`. Samples are delivered
/// asynchronously via a [Stream]. Call [close] when done to undeclare
/// the subscriber and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: as
/// `Subscriber` — the stream a user holds does not reference this wrapper, so
/// it is collected while still in use.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class AdvancedSubscriber implements Finalizable {
  /// Creates an advanced subscriber on the given session and key expression.
  ///
  /// This is called internally by `Session.declareAdvancedSubscriber`.
  factory AdvancedSubscriber.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe,
    String keyExpr, {
    AdvancedSubscriberOptions options = const AdvancedSubscriberOptions(),
  }) {
    final size = bindings.zd_advanced_subscriber_sizeof();
    final ptr = calloc.allocate<Void>(size);

    final sampleChannel = Subscriber.createSampleChannel(
      retainPayload: options.retainPayload,
    );

    final rc = bindings.zd_declare_advanced_subscriber(
      loanedSession.cast(),
      ptr.cast(),
      loanedKe.cast(),
      sampleChannel.receivePort.sendPort.nativePort,
      options.history,
      options.detectLatePublishers,
      options.recovery,
      options.lastSampleMissDetection,
      options.periodicQueriesPeriodMs,
      options.subscriberDetection,
      options.retainPayload ? 1 : 0,
    );

    if (rc != 0) {
      sampleChannel.abandon();
      calloc.free(ptr);
      throw ZenohException('Failed to declare advanced subscriber', rc);
    }

    ReceivePort? missPort;
    StreamController<MissEvent>? missController;

    if (options.enableMissListener) {
      missPort = ReceivePort();
      missController = StreamController<MissEvent>();

      missPort.listen((dynamic message) {
        if (message is List) {
          final zidBytes = message[0] as Uint8List;
          final count = message[1] as int;
          // eid appended at index 2 by _zd_miss_callback; length-guarded so a
          // stale/short array (defensive) degrades to eid 0 rather than throwing.
          final eid = message.length > 2 ? message[2] as int : 0;
          final sourceId = EntityGlobalId(ZenohId(zidBytes), eid);
          missController!.add(MissEvent(sourceId: sourceId, count: count));
        }
      });

      final loaned = bindings.zd_advanced_subscriber_loan(ptr.cast());
      final missRc = bindings
          .zd_advanced_subscriber_declare_background_sample_miss_listener(
            loaned,
            missPort.sendPort.nativePort,
          );

      if (missRc != 0) {
        missPort.close();
        unawaited(missController.close());
        sampleChannel.abandon();
        bindings.zd_advanced_subscriber_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare miss listener', missRc);
      }
    }

    SampleChannel? detectChannel;

    final detect = options.detectPublishers;
    if (detect != null) {
      detectChannel = Subscriber.createSampleChannel(
        retainPayload: detect.retainPayload,
      );

      final loaned = bindings.zd_advanced_subscriber_loan(ptr.cast());
      final detectRc = bindings
          .zd_advanced_subscriber_detect_publishers_background(
            loaned,
            detectChannel.receivePort.sendPort.nativePort,
            // -1 = unspecified -> NULL options -> canon's own default.
            detect.history == null ? -1 : (detect.history! ? 1 : 0),
            detect.retainPayload ? 1 : 0,
          );

      if (detectRc != 0) {
        // The shipped teardown template, extended by one pair: everything
        // declared above this point comes down before the throw.
        detectChannel.abandon();
        missPort?.close();
        unawaited(missController?.close());
        sampleChannel.abandon();
        bindings.zd_advanced_subscriber_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare publisher detection', detectRc);
      }
    }

    return AdvancedSubscriber._(
      ptr,
      sampleChannel,
      missPort,
      missController,
      detectChannel,
      keyExpr,
    );
  }

  AdvancedSubscriber._(
    this._ptr,
    this._sampleChannel,
    this._missPort,
    this._missController,
    this._detectChannel,
    this._keyExpr,
  );

  final Pointer<Void> _ptr;
  final SampleChannel _sampleChannel;
  final ReceivePort? _missPort;
  final StreamController<MissEvent>? _missController;
  final SampleChannel? _detectChannel;
  final String _keyExpr;
  bool _closed = false;

  /// The key expression this advanced subscriber is declared on.
  ///
  /// The declared expression as the caller gave it, whether that was a
  /// `String` or a `KeyExpr` — both entry forms of the union reach the same
  /// value.
  ///
  /// Dart-side state, so it survives [close] and the session's own close.
  /// That is deliberate and matches `Subscriber`, `PullSubscriber`,
  /// `Queryable` and `LivelinessToken`: reading back what you declared is not
  /// an operation on the native handle, so there is nothing for a
  /// disposed-handle guard to protect.
  ///
  /// Canon's own `ze_advanced_subscriber_keyexpr` native read is deliberately
  /// left unbound: binding it would ship a second key-expression contract on
  /// one class and buy nothing this getter does not already give.
  String get keyExpr => _keyExpr;

  /// A stream of [Sample]s received by this advanced subscriber.
  ///
  /// **Lifetime.** This stream is bound to this entity: [close] completes it.
  /// If the *session* is closed while this subscriber is still open, the
  /// stream goes **quiet without completing** — no more samples arrive, but no
  /// `done` is delivered either, because nothing posts a completion sentinel
  /// on this path. That differs from [detectedPublishers], whose listener
  /// canon owns at session scope and which therefore does complete; the
  /// asymmetry is canon's, not this binding's.
  /// ⚠️ **UNBOUNDED, and pausing it does not stop the flow** — see
  /// `Session.declareSubscriber` for the measurement. **This family has no
  /// bounded entry point at all**: there is no channel-mode advanced
  /// subscriber, so unlike the plain surfaces there is no bounded alternative
  /// to point you at. That gap is carved rather than fixed here, and it is
  /// tracked as parity debt.
  Stream<Sample> get stream => _sampleChannel.stream;

  /// A stream of [MissEvent]s when samples are missed, or null if the
  /// miss listener was not enabled.
  ///
  /// **Lifetime.** As [stream]: bound to this entity, completed by [close],
  /// and quiet-without-completing if the session is closed first.
  /// ⚠️ **Unbounded, like every push stream here** — but this is an
  /// edge-signal channel, not a data channel: it carries transitions, not
  /// traffic, so there is deliberately no bounded form of it.
  ///
  Stream<MissEvent>? get missEvents => _missController?.stream;

  /// A stream of matching advanced publishers appearing and disappearing, or
  /// `null` if [AdvancedSubscriberOptions.detectPublishers] was not set.
  ///
  /// Canon backs detection with liveliness tokens, so each event is an
  /// ordinary [Sample]: [SampleKind.put] when a publisher appears,
  /// [SampleKind.delete] when it goes away. Canon's own constraint:
  /// *"Only advanced publishers, enabling publisher detection can be
  /// detected"* — a plain publisher, or an advanced one with
  /// `AdvancedPublisherOptions.publisherDetection` left off, is invisible
  /// here.
  ///
  /// The event's `keyExpr` is the liveliness token's, not the data key
  /// expression: `<key>/@adv/pub/<32 hex zid>/<sn-source>/<metadata>`. Two of
  /// those segments vary with the *publisher's* configuration — the
  /// sn-source is the numeric entity id when that publisher enables sample
  /// miss detection and the literal `uhlc` when it does not, and the trailing
  /// slot carries an announced detection metadata key expression, or `_` when
  /// none is announced. The payload carries nothing this binding interprets.
  ///
  /// **Lifetime — and it differs from this class's other two streams.** Canon
  /// binds this listener to the **session**: it runs until the session is
  /// closed or dropped, and it outlives this advanced subscriber. So:
  ///
  /// * [close] completes this stream, because the Dart side stops listening;
  /// * closing the **session** also completes it, via a sentinel canon's own
  ///   drop of the background closure delivers;
  /// * by contrast [stream] and [missEvents] are bound to this entity, and on
  ///   session close with this subscriber still open they simply go quiet —
  ///   they do not complete.
  ///
  /// **The foreground variant is deliberately not bound, and the cost is
  /// larger here than elsewhere.** Cancelling a subscription to this stream
  /// stops delivery on the Dart side, but the native liveliness subscription
  /// canon declared stays alive until the session closes. Canon's foreground
  /// `ze_advanced_subscriber_detect_publishers` fills an independently
  /// undeclarable `z_owned_subscriber_t` — *"Destroying the subscriber cancels
  /// the subscription"* — and is canon's only way to stop and reclaim that
  /// native subscription early. No other listener in this binding gives up
  /// that much: the matching and sample-miss handles canon's own docs bind to
  /// their parent's lifetime anyway.
  /// ⚠️ **Unbounded, like every push stream here** — but this is an
  /// edge-signal channel, not a data channel: it carries transitions, not
  /// traffic, so there is deliberately no bounded form of it.
  ///
  Stream<Sample>? get detectedPublishers => _detectChannel?.stream;

  /// Undeclares the advanced subscriber and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_advanced_subscriber_drop(_ptr.cast());
    // closeAndDrain, not a bare port close: a retained handle that arrived and
    // was never delivered has no other owner, so this is its only release.
    _sampleChannel.closeAndDrain();
    _missPort?.close();
    unawaited(_missController?.close());
    _detectChannel?.closeAndDrain();
    calloc.free(_ptr);
  }
}
