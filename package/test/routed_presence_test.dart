@Timeout(Duration(minutes: 2))
library;

// Presence detection, with a router actually in the path.
//
// Seven cells in the default suite certify that a publisher learns of a
// matching subscriber, that an advanced publisher learns the same, and that a
// detecting advanced subscriber is told when an advanced publisher appears
// and disappears. Every one of them certifies it over a DIRECT peer link --
// the one shape a deployment never uses. This file adds their routed
// counterparts. Nothing here replaces anything: all seven originals stay
// exactly where they are, unedited, and keep certifying the direct path.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
//   test/publisher_test.dart:457 "hasMatchingSubscribers returns true when a
//   subscriber exists" (assertion at :471)
//     -> "a client publisher learns of a peer subscriber through the router"
//        (its hasMatchingSubscribers() leg)
//
//   test/publisher_test.dart:591 "matchingStatus stream emits true when
//   subscriber appears" (assertion at :611)
//     -> "a client publisher learns of a peer subscriber through the router"
//        (its matchingStatus leg)
//
//   test/publisher_test.dart:614 "matchingStatus stream emits false when
//   subscriber disappears" (assertions at :646 and :647)
//     -> "the publisher learns the subscriber is gone when it closes"
//
//   test/advanced_publisher_test.dart:362 "true with a live matching advanced
//   subscriber" (assertion at :386)
//     -> "an advanced publisher polls true for a routed advanced subscriber"
//
//   test/advanced_publisher_test.dart:471 "true on the first matching
//   subscriber, false when the last departs" (assertions at :517, :526, :530)
//     -> "the advanced matching stream reports the arrival and the departure"
//
//   test/advanced_detect_test.dart:71 "a publisher declared after the detect
//   stream produces a PUT" (assertion at :105)
//     -> "a publisher that appears after the detector produces a routed PUT"
//
//   test/advanced_detect_test.dart:236 "closing the publisher delivers a
//   DELETE-kind Sample" (assertions at :279 and :282)
//     -> "closing the publisher delivers a routed DELETE for the same token"
//
// Three cells have no original, and each states why where it stands: the
// split control below, and the two edges the slice asks for -- that detection
// names WHICH publisher appeared rather than merely counting one, and that a
// publisher already live when the detector attaches is recovered.
//
// WHY THE ROUTER IS REALLY IN THE PATH
//
// Pointing two sessions at a router is not routing them. Peers find each
// other by gossip and link DIRECTLY, so the router sits beside the path and
// the green is indistinguishable from the no-router case. Every leaf below is
// built by helpers/routed_topology.dart, which carries the three things that
// make the difference real: the router's endpoint only, both discovery
// mechanisms off, and at least one leaf in client mode.
//
// THE NEGATIVE CONTROL, AND WHY ITS ZERO IS WORTH READING
//
// "The publisher sees a match" needs a companion that could have caught a
// green produced by something other than the route. The split control is the
// same publisher leaf with the same flags dialling a SECOND, unlinked router:
// its matching listener must never report true. Its zero is only worth
// reading because the OBSERVED side's readiness is asserted first -- a probe
// leaf's publisher on the subscriber's own router reports a match, so the
// subscriber demonstrably declared and demonstrably crossed a router. It just
// did not cross THAT one.
//
// READINESS, AND THE TRAP IT WOULD OTHERWISE WALK INTO
//
// The detect cells gate on a probe leaf's throwaway advanced publisher, which
// produces events on the SAME stream the cell then asserts over. A gate that
// consumed from that stream would be part of the observation. _observeDetect
// therefore SPLITS at the listener by the probe leaf's zid and discards
// nothing: a probe event can neither satisfy nor falsify a cell's assertion,
// and a cell's event is never eaten by the gate.
//
// PORTS: 19870-19874, this file's block of the unit's 19800-19899 band.
// 19870 carries the plain matching cells; 19871 is the unlinked router the
// split control publishes into; 19872 is the advanced matching pair's; 19873
// is the detection group's. 19874 is unallocated.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/routed_topology.dart';

/// The router the plain matching cells cross.
const _routerPort = 19870;

/// The second router, deliberately unlinked from [_routerPort].
const _splitRouterPort = 19871;

/// The advanced matching pair's router.
const _advancedRouterPort = 19872;

/// The publisher-detection group's router.
const _detectRouterPort = 19873;

/// How long an absence cell waits before concluding nothing was observed.
///
/// It must exceed the positive path's convergence by a clear margin or a slow
/// green reads as a red. The positive cells here report a match in well under
/// a second once both leaves are attached; five seconds is the interval this
/// unit's other absence cells already use.
const _negativeWindow = Duration(seconds: 5);

/// A detect stream split into the cell's samples and the gate's probes.
typedef _Observed = ({List<Sample> samples, List<Sample> probes});

/// The zid segment of an advanced-publisher detection token.
///
/// Canon renders the token as `<key>/@adv/pub/<zid>/<uhlc|eid>/<meta>`, so the
/// zid is third from the end regardless of how many chunks the key expression
/// itself has. The whole shape is pinned in
/// test/advanced_detect_test.dart:156-192, and the same third-from-the-end
/// read is that cell's line 185; this file needs only the identity.
String _tokenZid(String tokenKeyExpr) {
  final segments = tokenKeyExpr.split('/');
  if (segments.length < 3) return '';
  return segments[segments.length - 3];
}

/// Collects [subscriber]'s detections, splitting the readiness gate's probes
/// out of the cell's own samples.
///
/// Splitting at the listener rather than filtering at the assertion is what
/// lets a cell read `hasLength(1)` and mean it. Nothing is discarded: the
/// gate below produces events on this very stream, so a gate that swallowed
/// them would be part of the observation rather than a precondition for it.
_Observed _observeDetect(AdvancedSubscriber subscriber, String probeZidHex) {
  addTearDown(subscriber.close);
  final samples = <Sample>[];
  final probes = <Sample>[];
  final subscription = subscriber.detectedPublishers!.listen((sample) {
    if (_tokenZid(sample.keyExpr) == probeZidHex) {
      probes.add(sample);
    } else {
      samples.add(sample);
    }
  });
  addTearDown(subscription.cancel);
  return (samples: samples, probes: probes);
}

/// Waits until a detect stream is live THROUGH the router.
///
/// THE EXACT GATE, and the reason it exists is that the cheaper ones do not
/// answer the question. `awaitAttached` says the transport linked; it says
/// nothing about the detector's liveliness subscription having crossed the
/// router -- and declaring the publisher before it has loses the appearance
/// event outright, because detection without history reports transitions only
/// and zenoh retains nothing for a subscriber that was not there yet.
///
/// A probe leaf declares a throwaway detection-enabled advanced publisher on
/// the same key and withdraws it; when the cell's own detector has SEEN one,
/// the path the cell depends on has demonstrably carried an event.
Future<void> _awaitRoutedDetector({
  required Session probeLeaf,
  required String key,
  required List<Sample> probes,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final probe = probeLeaf.declareAdvancedPublisher(
      key,
      options: const AdvancedPublisherOptions(publisherDetection: true),
    );
    final until = DateTime.now().add(const Duration(milliseconds: 300));
    while (probes.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    probe.close();
    if (probes.isNotEmpty) return;
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for a detect stream '
    'on "$key" to observe a probe publisher through the router.',
  );
}

/// Waits until an ALREADY-LIVE publisher on [key] is recoverable through the
/// router, witnessed by a third leaf.
///
/// The history cell's dual of [_awaitRoutedDetector]: there the detector had
/// to be live before the publisher, here the publisher has to be live before
/// the detector. A throwaway detector on a probe leaf recovering the token IS
/// that condition, and it is a third-party witness -- it reads neither the
/// cell's publisher nor the cell's detector.
Future<void> _awaitDetectableThroughRouter({
  required Session probeLeaf,
  required String key,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final probe = probeLeaf.declareAdvancedSubscriber(
      key,
      options: const AdvancedSubscriberOptions(
        detectPublishers: DetectPublishersOptions(history: true),
      ),
    );
    final seen = <Sample>[];
    final subscription = probe.detectedPublishers!.listen(seen.add);
    final until = DateTime.now().add(const Duration(milliseconds: 400));
    while (seen.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await subscription.cancel();
    probe.close();
    if (seen.isNotEmpty) return;
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for a live publisher '
    'on "$key" to be recoverable by a probe detector through the router.',
  );
}

void main() {
  group('Matching status crosses one hosted router (TCP 19870, split 19871)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;
    late Session publisherLeaf;
    late Session subscriberLeaf;
    late Session splitPublisherLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_routerPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);

      publisherLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      subscriberLeaf = await Session.open(
        config: router.leafConfig(LeafMode.peer),
      );
      // Identical flags and identical role to publisherLeaf. The ONLY
      // difference is which router it dials, which is what makes the split
      // control's zero attributable to the path rather than to the leaf.
      splitPublisherLeaf = await Session.open(
        config: splitRouter.leafConfig(LeafMode.client),
      );

      await router.awaitAttached(publisherLeaf);
      await router.awaitAttached(subscriberLeaf);
      await splitRouter.awaitAttached(splitPublisherLeaf);
    });

    tearDownAll(() {
      splitPublisherLeaf.close();
      subscriberLeaf.close();
      publisherLeaf.close();
      splitRouter.close();
      router.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      // The precondition every other cell in this group rests on, asserted
      // once: the two leaves are attached, to the router this file names, and
      // the split leaf is attached to a DIFFERENT one. Without it the split
      // control's zero would be satisfied by three leaves that connected to
      // nothing at all.
      expect(publisherLeaf.routersZid(), hasLength(1));
      expect(publisherLeaf.routersZid().single, equals(router.zid));
      expect(subscriberLeaf.routersZid(), hasLength(1));
      expect(subscriberLeaf.routersZid().single, equals(router.zid));

      expect(splitPublisherLeaf.routersZid(), hasLength(1));
      expect(splitPublisherLeaf.routersZid().single, equals(splitRouter.zid));
      expect(splitRouter.zid, isNot(equals(router.zid)));
    });

    test(
      'a client publisher learns of a peer subscriber through the router',
      () async {
        // Counterpart of publisher_test.dart:457 and :591, on the originals'
        // key. Both legs are here because both originals make the same claim
        // through different surfaces: the one-shot poll and the listener
        // stream. A routed hop could carry one and not the other.
        const key = 'zenoh/dart/test/match-yes';

        final publisher = publisherLeaf.declarePublisher(
          key,
          enableMatchingListener: true,
        );
        addTearDown(publisher.close);
        expect(publisher.matchingStatus, isNotNull);

        final statuses = <bool>[];
        final subscription = publisher.matchingStatus!.listen(statuses.add);
        addTearDown(subscription.cancel);

        // THE PRE-STATE. Without it a `true` below would say nothing about the
        // subscriber that arrives after it -- a publisher that reported a match
        // from the start would satisfy the cell having learnt nothing.
        expect(publisher.hasMatchingSubscribers(), isFalse);

        final subscriber = subscriberLeaf.declareSubscriber(key);
        addTearDown(subscriber.close);

        await awaitCondition(
          () => statuses.contains(true),
          description:
              'the routed publisher to be told of a matching '
              'subscriber',
        );
        expect(statuses, contains(true));
        expect(publisher.hasMatchingSubscribers(), isTrue);
      },
    );

    test(
      'the publisher learns the subscriber is gone when it closes',
      () async {
        // Counterpart of publisher_test.dart:614, on the original's key. The
        // TRANSITION is the subject, so the true is gated on before the
        // subscriber is closed: a lone false proves nothing about a departure.
        const key = 'zenoh/dart/test/match-stream2';

        final publisher = publisherLeaf.declarePublisher(
          key,
          enableMatchingListener: true,
        );
        addTearDown(publisher.close);

        final statuses = <bool>[];
        final subscription = publisher.matchingStatus!.listen(statuses.add);
        addTearDown(subscription.cancel);

        final subscriber = subscriberLeaf.declareSubscriber(key);
        await awaitCondition(
          () => statuses.contains(true),
          description:
              'the routed publisher to be told of a matching '
              'subscriber',
        );
        final trueAt = statuses.indexOf(true);

        subscriber.close();

        await awaitCondition(
          () => statuses.length > trueAt + 1 && !statuses.last,
          description: 'the routed publisher to be told the subscriber left',
        );
        expect(statuses, contains(true));
        expect(statuses.last, isFalse);
        // Order matters: false must FOLLOW true, or the stream is reporting
        // something other than the transition it claims to.
        expect(statuses.indexOf(true), lessThan(statuses.lastIndexOf(false)));
        expect(publisher.hasMatchingSubscribers(), isFalse);
      },
    );

    test('matching status does not cross two unlinked routers', () async {
      // THE SPLIT CONTROL, and this file's negative control. Same key, same
      // roles, same flags as the cell two above; the publisher dials the
      // other router.
      const key = 'zenoh/dart/test/match-split';

      final subscriber = subscriberLeaf.declareSubscriber(key);
      addTearDown(subscriber.close);

      // THE OBSERVED SIDE'S READINESS, ASSERTED FIRST, and it is exact: a
      // probe leaf's publisher on the subscriber's OWN router reports a
      // match, which is that subscriber's declaration having crossed a router
      // and come back. So the zero below is about which router, not about a
      // subscriber that never started.
      await awaitRoutedSubscriber(router, key);

      final publisher = splitPublisherLeaf.declarePublisher(
        key,
        enableMatchingListener: true,
      );
      addTearDown(publisher.close);

      final statuses = <bool>[];
      final subscription = publisher.matchingStatus!.listen(statuses.add);
      addTearDown(subscription.cancel);

      await Future<void>.delayed(_negativeWindow);

      expect(statuses, isNot(contains(true)));
      // A second, independent reading of the same absence, through the poll
      // rather than through the listener.
      expect(publisher.hasMatchingSubscribers(), isFalse);
    });
  });

  group(
    'Advanced matching crosses one hosted router (TCP 19872)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late HostedRouter router;
      late Session publisherLeaf;
      late Session subscriberLeaf;

      setUpAll(() async {
        router = await HostedRouter.open(_advancedRouterPort);
        // timestamping on both leaves, exactly as the originals configure
        // their sessions: the advanced entities require it.
        publisherLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        subscriberLeaf = await Session.open(
          config: router.leafConfig(LeafMode.peer)
            ..insertJson5('timestamping/enabled', 'true'),
        );

        await router.awaitAttached(publisherLeaf);
        await router.awaitAttached(subscriberLeaf);
        await router.awaitPeerLeaf(subscriberLeaf.zid);
      });

      tearDownAll(() {
        subscriberLeaf.close();
        publisherLeaf.close();
        router.close();
      });

      test(
        'an advanced publisher polls true for a routed advanced subscriber',
        () async {
          // Counterpart of advanced_publisher_test.dart:362, on the original's
          // key.
          const key = 'zenoh/dart/adv-match/paired';

          final publisher = publisherLeaf.declareAdvancedPublisher(key);
          addTearDown(publisher.close);
          expect(
            publisher.hasMatchingSubscribers(),
            isFalse,
            reason: 'the transition has to start from false to mean anything',
          );

          final subscriber = subscriberLeaf.declareAdvancedSubscriber(key);
          addTearDown(subscriber.close);

          await awaitMatching(publisher.hasMatchingSubscribers);
          expect(publisher.hasMatchingSubscribers(), isTrue);
        },
      );

      test(
        'the advanced matching stream reports the arrival and the departure',
        () async {
          // Counterpart of advanced_publisher_test.dart:471, on the original's
          // key. The transition PAIR is the fidelity cell for this value path:
          // the shim posts int64 0/1 and Dart decodes `!= 0`, so observing both
          // directions is what proves the decode rather than assuming it -- and
          // a routed hop must not lose either direction.
          const key = 'zenoh/dart/adv-match-stream/transition';

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(
              enableMatchingListener: true,
            ),
          );
          addTearDown(publisher.close);

          final seen = <bool>[];
          final subscription = publisher.matchingStatus!.listen(seen.add);
          addTearDown(subscription.cancel);

          final subscriber = subscriberLeaf.declareAdvancedSubscriber(key);

          await awaitCondition(
            () => seen.contains(true),
            description:
                'the advanced publisher to be told of the first '
                'matching subscriber',
          );
          final trueAt = seen.indexOf(true);

          subscriber.close();

          await awaitCondition(
            () => seen.length > trueAt + 1 && !seen.last,
            description:
                'the advanced publisher to be told the last '
                'subscriber departed',
          );
          expect(seen, contains(true));
          expect(seen, contains(false));
          expect(seen.indexOf(true), lessThan(seen.lastIndexOf(false)));
        },
      );
    },
  );

  group(
    'Publisher detection crosses one hosted router (TCP 19873)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late HostedRouter router;
      late Session publisherLeaf;
      late Session subscriberLeaf;
      late Session probeLeaf;
      late String probeZidHex;

      setUpAll(() async {
        router = await HostedRouter.open(_detectRouterPort);
        publisherLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        subscriberLeaf = await Session.open(
          config: router.leafConfig(LeafMode.peer)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        // The gate's leaf. It is a third party to every cell: it holds no
        // entity a cell asserts over, and its zid is what splits its events
        // out of the cells' streams.
        probeLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        probeZidHex = probeLeaf.zid.toHexString();

        await router.awaitAttached(publisherLeaf);
        await router.awaitAttached(subscriberLeaf);
        await router.awaitAttached(probeLeaf);
        await router.awaitPeerLeaf(subscriberLeaf.zid);
      });

      tearDownAll(() {
        probeLeaf.close();
        subscriberLeaf.close();
        publisherLeaf.close();
        router.close();
      });

      AdvancedSubscriber declareDetector(String key, {bool history = false}) =>
          subscriberLeaf.declareAdvancedSubscriber(
            key,
            options: AdvancedSubscriberOptions(
              detectPublishers: DetectPublishersOptions(history: history),
            ),
          );

      test(
        'a publisher that appears after the detector produces a routed PUT',
        () async {
          // Counterpart of advanced_detect_test.dart:71, on the original's key.
          const key = 'zenoh/dart/detect/appear';

          final observed = _observeDetect(declareDetector(key), probeZidHex);
          await _awaitRoutedDetector(
            probeLeaf: probeLeaf,
            key: key,
            probes: observed.probes,
          );

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          await awaitCondition(
            () => observed.samples.isNotEmpty,
            description: 'the routed detector to see the publisher appear',
          );
          expect(observed.samples.first.kind, equals(SampleKind.put));
        },
      );

      test(
        'closing the publisher delivers a routed DELETE for the same token',
        () async {
          // Counterpart of advanced_detect_test.dart:236, on the original's
          // key.
          const key = 'zenoh/dart/detect/disappear';

          final observed = _observeDetect(declareDetector(key), probeZidHex);
          await _awaitRoutedDetector(
            probeLeaf: probeLeaf,
            key: key,
            probes: observed.probes,
          );

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );

          await awaitCondition(
            () => observed.samples.isNotEmpty,
            description: 'the routed detector to see the publisher appear',
          );
          expect(observed.samples.first.kind, equals(SampleKind.put));
          final token = observed.samples.first.keyExpr;

          publisher.close();

          await awaitCondition(
            () => observed.samples.any((s) => s.kind == SampleKind.delete),
            description: 'the routed detector to see the publisher disappear',
          );
          final gone = observed.samples.firstWhere(
            (s) => s.kind == SampleKind.delete,
          );
          // The token is asserted too, not just the kind: a stray unrelated
          // DELETE from anywhere else could otherwise satisfy this cell.
          expect(gone.keyExpr, equals(token));
        },
      );

      test(
        'detection names which publisher appeared, not merely a count',
        () async {
          // NO ORIGINAL -- the slice's identity edge, and it exists because a
          // count is satisfiable by the wrong publisher. A stray leaf, attached
          // to the same router and publishing on the same key expression, must
          // not be able to satisfy detection: it announces nothing, and the one
          // event that does arrive names the leaf that did.
          const key = 'zenoh/dart/detect/identity';

          final observed = _observeDetect(declareDetector(key), probeZidHex);
          await _awaitRoutedDetector(
            probeLeaf: probeLeaf,
            key: key,
            probes: observed.probes,
          );

          final strayLeaf = await Session.open(
            config: router.leafConfig(LeafMode.client)
              ..insertJson5('timestamping/enabled', 'true'),
          );
          addTearDown(strayLeaf.close);
          await router.awaitAttached(strayLeaf);

          // Two strays on the SAME key, varying only what detection is about:
          // a plain publisher, and an advanced one with the knob off.
          final strayPlain = strayLeaf.declarePublisher(key);
          addTearDown(strayPlain.close);
          final strayAdvanced = strayLeaf.declareAdvancedPublisher(
            key,
            // Explicit although it IS the class default: the knob being off is
            // the entire content of this control.
            // ignore: avoid_redundant_argument_values
            options: const AdvancedPublisherOptions(publisherDetection: false),
          );
          addTearDown(strayAdvanced.close);

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          await awaitCondition(
            () => observed.samples.isNotEmpty,
            description: 'the routed detector to see the announcing publisher',
          );
          // The strays get the whole absence window to produce an event of
          // their own before the count is read.
          await Future<void>.delayed(_negativeWindow);

          expect(observed.samples, hasLength(1));
          final zid = _tokenZid(observed.samples.single.keyExpr);
          expect(zid, equals(publisherLeaf.zid.toHexString()));
          expect(zid, isNot(equals(strayLeaf.zid.toHexString())));
        },
      );

      test(
        'a publisher already live when the detector attaches is recovered',
        () async {
          // NO ORIGINAL over a router -- the slice's pre-existence edge. The
          // direct-path pair is advanced_detect_test.dart:464 ("a pre-existing
          // publisher is visible with history enabled"), which the unit's brief
          // does not list; this cell carries the same claim across a hop.
          //
          // History is what makes it detectable at all: without it, detection
          // reports transitions only, which advanced_detect_test.dart:453 pins.
          const key = 'zenoh/dart/detect/prelive';

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          // Readiness is the PUBLISHER's this time, and it is a third-party
          // witness: a probe leaf's throwaway history detector recovers the
          // token, so the cell's detector is declared against a token that has
          // demonstrably crossed the router already.
          await _awaitDetectableThroughRouter(probeLeaf: probeLeaf, key: key);

          final observed = _observeDetect(
            declareDetector(key, history: true),
            probeZidHex,
          );

          await awaitCondition(
            () => observed.samples.isNotEmpty,
            description: 'the routed detector to recover the live publisher',
          );
          expect(observed.samples.first.kind, equals(SampleKind.put));
          expect(
            _tokenZid(observed.samples.first.keyExpr),
            equals(publisherLeaf.zid.toHexString()),
          );
        },
      );
    },
  );
}
