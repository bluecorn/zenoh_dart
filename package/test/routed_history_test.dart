@Timeout(Duration(minutes: 3))
library;

// Late-join history recovery, with a router actually in the path.
//
// Four cells in the default suite certify that an advanced subscriber which
// arrives AFTER a publisher recovers what it missed. Every one of them
// certifies it over a DIRECT peer link -- the one shape a deployment never
// uses, and the one shape in which "a pre-existing entity was recovered" is
// cheapest to satisfy, because the two sessions are already talking to each
// other and nothing has to be re-advertised anywhere. This file adds the
// routed counterparts. Nothing here replaces anything: all four originals
// stay exactly where they are, unedited, and keep certifying the direct path.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
//   test/advanced_subscriber_test.dart:233 "AdvancedSubscriber with history
//   receives cached samples" (assertions at :281 and :283-285)
//     -> "a late advanced subscriber recovers the cached samples through the
//        router"
//
//   test/advanced_subscriber_test.dart:296 "AdvancedSubscriber with history
//   receives cached then live" (assertion at :365, ordering at :381)
//     -> "the cache drains through the router before the live samples"
//
//   test/advanced_detect_test.dart:488 "history does not suppress live
//   detection" (assertion at :521)
//     -> "history does not suppress live detection through the router"
//
//   test/advanced_detect_test.dart:464 "a pre-existing publisher is visible
//   with history enabled" (assertion at :472)
//     -> ALREADY CARRIED, and deliberately NOT duplicated here:
//        test/routed_presence_test.dart:658 "a publisher already live when
//        the detector attaches is recovered" states that original as its
//        direct-path pair and asserts the same claim across a hop, plus the
//        identity of the recovered token. Writing a second copy would put
//        one claim in two files, which is the shape that goes stale in one
//        of them. The live-detection cell below names it where the pair
//        matters, so a reader of this file is never left looking for it.
//
// Three cells have no original, and each states why where it stands: the
// split control, the empty-cache edge, and the miss-listener reading.
//
// THE BOUNDARY THIS FILE KEEPS SHARP: advanced_cache_test.dart GAINS NOTHING
//
// test/advanced_cache_test.dart:117, :134, :161 and :182 also recover a
// cache, and they are deliberately left without a routed counterpart. Their
// assertions are `hasLength(1)`, `hasLength(1)`, `hasLength(5)` and
// `isEmpty` (:131, :158, :175, :199) -- a BOUNDED COUNT tied to the numeric
// `AdvancedPublisherCacheOptions.maxSamples`. That is value fidelity read out
// through delivery: the subject is whether a number we marshal reaches canon
// intact, and a router hop cannot make a 5 into a 4. The four originals this
// file does counterpart assert something else -- that a pre-existing entity
// was RECOVERED AT ALL -- and recovery is exactly what a router hop can
// break, because it needs a declaration to be re-advertised across the hop
// and a query to be routed back over it.
//
// That is why every positive cell below identifies what it recovered BY ITS
// VALUES rather than by a count. A `hasLength(3)` here would read as the
// bucket the boundary keeps out.
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
// READINESS, AND THE TRAP THIS FAMILY WALKS STRAIGHT INTO
//
// History replay arrives WITH the declaration. A readiness gate that
// consumed from the carrier a history cell then reads would therefore eat
// the very thing the cell is about, and the cell would pass identically with
// its subject removed. Neither gate here touches a cell's carrier:
//
//   _awaitRecoverableThroughRouter declares a THROWAWAY advanced subscriber
//   on a PROBE leaf and reads its stream, never the cell's. A cache query is
//   non-destructive -- the publisher answers it from a queryable and keeps
//   everything -- so the probe recovering the samples proves the route works
//   without spending what the cell will recover.
//
//   _awaitRoutedDetector produces events on the SAME stream its cell asserts
//   over, so _observeDetect SPLITS at the listener by the probe leaf's zid
//   and discards nothing: a probe event can neither satisfy nor falsify the
//   cell, and the cell's event is never eaten by the gate.
//
// THE NEGATIVE CONTROL, AND WHY ITS ZERO IS WORTH READING
//
// The split control is the same publisher, the same options and the same
// three payloads, published into a SECOND router that is not linked to the
// first. Its zero is only worth reading because both sides' readiness is
// asserted before it: a probe leaf on the split router demonstrably RECOVERS
// that cache, so the publisher works and the cache is populated; and the
// observing leaf is demonstrably attached to the other router. The cache is
// recoverable. It is just not recoverable from there.
//
// PORTS: 19890-19892, this file's block of the unit's 19800-19899 band.
// 19890 carries the history group; 19891 is the unlinked router the split
// control publishes into; 19892 is the detection group's. 19893 and 19894
// are unallocated.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/routed_topology.dart';

/// The router every history cell crosses.
const _routerPort = 19890;

/// The second router, deliberately unlinked from [_routerPort].
const _splitRouterPort = 19891;

/// The detection group's router.
const _detectRouterPort = 19892;

/// How long an absence cell waits before concluding nothing arrived.
///
/// It must exceed the positive path's convergence by a clear margin or a slow
/// green reads as a red. The positive cells here recover a cache in well
/// under a second once the probe has shown the route carries one; five
/// seconds is the interval this unit's other absence cells already use.
const _negativeWindow = Duration(seconds: 5);

/// The publisher options every cell in the history group publishes with.
///
/// The cache is what makes recovery possible at all, and the bound is the
/// originals' own: advanced_subscriber_test.dart:252 declares six.
const _cachingPublisher = AdvancedPublisherOptions(
  cache: AdvancedPublisherCacheOptions(maxSamples: 6),
  publisherDetection: true,
  sampleMissDetection: true,
);

/// The subscriber options every recovering cell declares with.
///
/// Copied field for field from advanced_subscriber_test.dart:267-272, so a
/// difference between a counterpart and its original can never be a
/// difference in what was asked for.
const _recoveringSubscriber = AdvancedSubscriberOptions(
  history: true,
  detectLatePublishers: true,
  recovery: true,
  lastSampleMissDetection: true,
  subscriberDetection: true,
);

/// A detect stream split into the cell's samples and the gate's probes.
typedef _Observed = ({List<Sample> samples, List<Sample> probes});

/// Collects everything [stream] delivers, closing the declaration after.
///
/// Collecting into a list rather than awaiting `stream.first` is what lets
/// the absence cells assert a zero at all: `first` can only time out, and a
/// timeout reads identically whether nothing was sent or the subscriber
/// never started.
List<Sample> _collect(Stream<Sample> stream, void Function() close) {
  addTearDown(close);
  final samples = <Sample>[];
  final subscription = stream.listen(samples.add);
  addTearDown(subscription.cancel);
  return samples;
}

/// The advanced-subscriber form of [_collect].
List<Sample> _collectAdvanced(AdvancedSubscriber subscriber) =>
    _collect(subscriber.stream, subscriber.close);

/// The payloads of [samples], in arrival order.
List<String> _payloads(List<Sample> samples) =>
    samples.map((s) => s.payload).toList();

/// The zid segment of an advanced-publisher detection token.
///
/// Canon renders the token as `<key>/@adv/pub/<zid>/<uhlc|eid>/<meta>`, so
/// the zid is third from the end regardless of how many chunks the key
/// expression itself has. The whole shape is pinned in
/// test/advanced_detect_test.dart:108-192.
String _tokenZid(String tokenKeyExpr) {
  final segments = tokenKeyExpr.split('/');
  if (segments.length < 3) return '';
  return segments[segments.length - 3];
}

/// Waits until an ALREADY-PUBLISHED cache on [key] is recoverable through the
/// router that [probeLeaf] is attached to.
///
/// THE EXACT GATE for every history cell, and the reason it exists is that
/// the cheaper ones do not answer the question. `awaitAttached` says the
/// transport linked. `awaitMatching` says a data declaration came back.
/// NEITHER says the publisher's CACHE is queryable across the hop -- and a
/// history subscriber declared before it is loses its recovery outright,
/// because the recovery query is asked once, at declaration.
///
/// A throwaway advanced subscriber on a probe leaf recovering [expected] IS
/// that condition, and it is a third-party witness: it reads neither the
/// cell's publisher nor the cell's subscriber. Nothing is consumed by asking
/// -- the cache answers a query from a queryable and keeps what it holds --
/// so this gate cannot spend what the cell is about to recover.
Future<void> _awaitRecoverableThroughRouter({
  required Session probeLeaf,
  required String key,
  required List<String> expected,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final probe = probeLeaf.declareAdvancedSubscriber(
      key,
      options: const AdvancedSubscriberOptions(history: true),
    );
    final seen = <String>[];
    final subscription = probe.stream.listen((s) => seen.add(s.payload));
    final until = DateTime.now().add(const Duration(milliseconds: 400));
    while (!expected.every(seen.contains) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await subscription.cancel();
    probe.close();
    if (expected.every(seen.contains)) return;
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for a probe '
    'subscriber to recover $expected on "$key" through a hosted router.',
  );
}

/// Collects [subscriber]'s detections, splitting the gate's probes out of the
/// cell's own samples.
///
/// Splitting at the listener rather than filtering at the assertion is what
/// keeps the readiness gate out of the observation. Nothing is discarded.
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
/// A probe leaf declares a throwaway detection-enabled advanced publisher on
/// the same key and withdraws it; when the cell's own detector has SEEN one,
/// the path the cell depends on has demonstrably carried an event.
///
/// This is what makes the live-detection cell below stronger than its
/// original, which sleeps 500ms instead. With history enabled a detector
/// RECOVERS a publisher that was already up, so a cell whose detector was not
/// yet live would still see an event -- and would be reading history while
/// claiming to read a live transition. Proving the detector live first is the
/// only thing that tells those two apart.
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

void main() {
  group(
    'History recovery crosses one hosted router (TCP 19890, split 19891)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late HostedRouter router;
      late HostedRouter splitRouter;
      late Session publisherLeaf;
      late Session subscriberLeaf;
      late Session probeLeaf;
      late Session splitPublisherLeaf;
      late Session splitProbeLeaf;

      setUpAll(() async {
        router = await HostedRouter.open(_routerPort);
        splitRouter = await HostedRouter.open(_splitRouterPort);

        // timestamping on every publishing leaf, exactly as the originals
        // configure their session1: the advanced publisher's cache and miss
        // detection require it. The subscribing leaf is left without it, as
        // the originals leave their session2.
        publisherLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        subscriberLeaf = await Session.open(
          config: router.leafConfig(LeafMode.peer),
        );
        // The gate's leaf. It is a third party to every cell: it holds no
        // entity a cell asserts over.
        probeLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client),
        );
        // Identical flags and identical role to publisherLeaf. The ONLY
        // difference is which router it dials, which is what makes the split
        // control's zero attributable to the path rather than to the leaf.
        splitPublisherLeaf = await Session.open(
          config: splitRouter.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        splitProbeLeaf = await Session.open(
          config: splitRouter.leafConfig(LeafMode.client),
        );

        await router.awaitAttached(publisherLeaf);
        await router.awaitAttached(subscriberLeaf);
        await router.awaitAttached(probeLeaf);
        await router.awaitPeerLeaf(subscriberLeaf.zid);
        await splitRouter.awaitAttached(splitPublisherLeaf);
        await splitRouter.awaitAttached(splitProbeLeaf);
      });

      tearDownAll(() {
        splitProbeLeaf.close();
        splitPublisherLeaf.close();
        probeLeaf.close();
        subscriberLeaf.close();
        publisherLeaf.close();
        splitRouter.close();
        router.close();
      });

      test('each leaf reports exactly the router it was pointed at', () {
        // The precondition every other cell in this group rests on, asserted
        // once: the recovering pair and its probe are attached to the router
        // this file names, the split pair to a DIFFERENT one. Without it the
        // split control's zero would be satisfied by five leaves that
        // connected to nothing at all.
        expect(publisherLeaf.routersZid(), hasLength(1));
        expect(publisherLeaf.routersZid().single, equals(router.zid));
        expect(subscriberLeaf.routersZid(), hasLength(1));
        expect(subscriberLeaf.routersZid().single, equals(router.zid));
        expect(probeLeaf.routersZid(), hasLength(1));
        expect(probeLeaf.routersZid().single, equals(router.zid));

        expect(splitPublisherLeaf.routersZid(), hasLength(1));
        expect(
          splitPublisherLeaf.routersZid().single,
          equals(splitRouter.zid),
        );
        expect(splitProbeLeaf.routersZid(), hasLength(1));
        expect(splitProbeLeaf.routersZid().single, equals(splitRouter.zid));
        expect(splitRouter.zid, isNot(equals(router.zid)));
      });

      test('a late advanced subscriber recovers the cached samples through '
          'the router', () async {
        // Counterpart of advanced_subscriber_test.dart:233, on the
        // original's key and the original's three payloads.
        const key = 'zenoh/dart/test/adv-int/history';
        const cached = ['cached_1', 'cached_2', 'cached_3'];

        final publisher =
            publisherLeaf.declareAdvancedPublisher(
                key,
                options: _cachingPublisher,
              )
              // Published BEFORE any subscriber exists anywhere. That is the
              // whole subject: nothing is listening, so nothing but the cache
              // can produce these later.
              ..put(cached[0])
              ..put(cached[1])
              ..put(cached[2]);
        addTearDown(publisher.close);

        // EXACT readiness, and a third party's: a probe leaf's throwaway
        // subscriber recovers the same three through the router. So the
        // cell's subscriber is declared against a cache that has
        // demonstrably crossed the hop already.
        await _awaitRecoverableThroughRouter(
          probeLeaf: probeLeaf,
          key: key,
          expected: cached,
        );

        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(
            key,
            options: _recoveringSubscriber,
          ),
        );

        await awaitCondition(
          () => samples.length >= cached.length,
          description:
              'the late advanced subscriber to recover the cache '
              'through the router',
        );
        // BY VALUE, never by count -- see the boundary note in the header.
        // The recovered payloads ARE the published ones, in the order they
        // were published, and there is nothing else in the stream.
        expect(_payloads(samples), equals(cached));
      });

      test('no history is recovered across two unlinked routers', () async {
        // THE SPLIT CONTROL. No original: the direct-path cells have no
        // route to be wrong about. Same publisher options, same three
        // payloads, same subscriber options as the cell above; the publisher
        // dials the other router.
        const key = 'zenoh/dart/test/adv-int/history-split';
        const cached = ['split_1', 'split_2', 'split_3'];

        final publisher =
            splitPublisherLeaf.declareAdvancedPublisher(
                key,
                options: _cachingPublisher,
              )
              ..put(cached[0])
              ..put(cached[1])
              ..put(cached[2]);
        addTearDown(publisher.close);

        // READINESS OF BOTH SIDES, before the zero is read. First the
        // published side: a probe on the SPLIT router recovers all three, so
        // the cache exists, is populated and is recoverable -- across a
        // router hop, just not across this one.
        await _awaitRecoverableThroughRouter(
          probeLeaf: splitProbeLeaf,
          key: key,
          expected: cached,
        );
        // Then the observing side: the router's own view of its leaf. There
        // is no matching status to poll here -- the whole point is that no
        // route exists.
        await router.awaitPeerLeaf(subscriberLeaf.zid);

        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(
            key,
            options: _recoveringSubscriber,
          ),
        );
        await Future<void>.delayed(_negativeWindow);

        expect(samples, isEmpty);

        // ...and the same subscriber DOES recover from a publisher on the
        // LINKED router, which is what stops the zero above being a
        // subscriber that never worked.
        final linked = publisherLeaf.declareAdvancedPublisher(
          key,
          options: _cachingPublisher,
        );
        addTearDown(linked.close);
        await awaitMatching(linked.hasMatchingSubscribers);
        linked.put('from the linked router');

        await awaitCondition(
          () => samples.isNotEmpty,
          description:
              'the same subscriber to receive from the linked '
              'router',
        );
        expect(_payloads(samples), equals(['from the linked router']));
      });

      test(
        'the cache drains through the router before the live samples',
        () async {
          // Counterpart of advanced_subscriber_test.dart:296, on the
          // original's key and its six payloads. The original states the
          // property twice -- the whole sequence at :365, and the ordering
          // relation on its own at :381 so a failure says which half broke --
          // and both readings are kept here.
          const key = 'zenoh/dart/test/adv-int/order';
          const cached = ['value_1', 'value_2', 'value_3'];
          const live = ['value_4', 'value_5', 'value_6'];

          final publisher =
              publisherLeaf.declareAdvancedPublisher(
                  key,
                  options: const AdvancedPublisherOptions(
                    cache: AdvancedPublisherCacheOptions(maxSamples: 10),
                    publisherDetection: true,
                    sampleMissDetection: true,
                  ),
                )
                ..put(cached[0])
                ..put(cached[1])
                ..put(cached[2]);
          addTearDown(publisher.close);

          await _awaitRecoverableThroughRouter(
            probeLeaf: probeLeaf,
            key: key,
            expected: cached,
          );
          // MEASURED, and it cost one intermittent red before it was here: the
          // gate above declares throwaway subscribers on THIS key, so a
          // `hasMatchingSubscribers` read taken straight after it can be
          // reporting the PROBE rather than this cell's subscriber. The live
          // puts would then be made before this subscriber's declaration had
          // crossed the router, and zenoh retains nothing for a subscriber
          // that was not there yet -- so the cell would time out waiting for
          // samples that were never sent to it. Waiting for the probe's
          // departure first is what makes the true below unambiguous.
          await awaitCondition(
            () => !publisher.hasMatchingSubscribers(),
            description:
                'the gate probe subscriber to be undeclared through '
                'the router',
          );

          final samples = _collectAdvanced(
            subscriberLeaf.declareAdvancedSubscriber(
              key,
              options: _recoveringSubscriber,
            ),
          );

          // NOTE: the ONLY wait between the subscriber and the live puts is the
          // exact matching gate, and it is deliberately the weakest one that
          // does not lose the samples. Waiting for the cache to arrive first
          // would make the ordering assertion below assert an order this cell
          // had itself imposed -- the subject is that the subscriber holds the
          // live samples back until its recovery query has finished, so the
          // live puts must be made as early as the route allows.
          await awaitMatching(publisher.hasMatchingSubscribers);
          publisher
            ..put(live[0])
            ..put(live[1])
            ..put(live[2]);

          await awaitCondition(
            () => samples.length >= cached.length + live.length,
            description:
                'the advanced subscriber to receive the cached and '
                'the live samples through the router',
          );

          final payloads = _payloads(samples);
          expect(payloads, equals([...cached, ...live]));
          // Stated as its own assertion so a failure says which property
          // broke: every cached sample precedes every live one.
          expect(
            payloads.indexOf(cached.last),
            lessThan(payloads.indexOf(live.first)),
            reason: 'a live sample arrived before the cache drained',
          );
        },
      );

      test('a subscriber that attaches before anything is published recovers '
          'nothing and does not hang', () async {
        // NO ORIGINAL -- the slice's empty-recovery edge. A history query
        // that finds nothing must complete rather than stall the
        // declaration, and a router hop is where a query that is never
        // answered would show up as a subscriber that never delivers again.
        const key = 'zenoh/dart/test/adv-int/history-empty';

        final publisher = publisherLeaf.declareAdvancedPublisher(
          key,
          options: _cachingPublisher,
        );
        addTearDown(publisher.close);
        // Nothing has been published on this key and nothing is subscribed
        // to it, stated rather than assumed -- it is the premise of the
        // whole cell.
        expect(publisher.hasMatchingSubscribers(), isFalse);

        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(
            key,
            options: _recoveringSubscriber,
          ),
        );

        // Exact readiness for the ABSENCE: the publisher reporting a match
        // is the subscriber's declaration having crossed the router and come
        // back, so the zero below is about an empty cache and not about a
        // subscriber that was still connecting.
        await awaitMatching(publisher.hasMatchingSubscribers);
        await Future<void>.delayed(_negativeWindow);

        expect(samples, isEmpty);

        // ...and the subscriber is still live afterwards, which is the "does
        // not hang" half: an empty recovery must not wedge the stream.
        publisher.put('published after the empty recovery');
        await awaitCondition(
          () => samples.isNotEmpty,
          description: 'the subscriber to deliver after an empty recovery',
        );
        expect(
          _payloads(samples),
          equals(['published after the empty recovery']),
        );
      });

      test(
        'the routed hop reports no missed sample for a complete sequence',
        () async {
          // NO ORIGINAL, and the slice asked for a POSITIVE routed miss. It is
          // not writable here, and the reason is recorded rather than chased:
          //
          //   Over reliable TCP nothing is ever dropped, so no arrangement of
          //   real publishers and subscribers drives a miss -- the corpus
          //   already recorded that, and retired a cell that self-skipped on
          //   every run for it (advanced_subscriber_test.dart:767-785). The
          //   ONLY executed coverage of the bridge is
          //   test/advanced_miss_inject_test.dart, which drives it from a
          //   canon-C process publishing a crafted source sequence number.
          //   That injector takes a LISTEN endpoint and always listens
          //   (test/helpers/miss_injector.c:75-85, and its mode is left at
          //   canon's default), so a routed variant of it would need the
          //   injector changed -- which would edit a helper the existing cell
          //   depends on. Adding a router hop cannot make the loopback path
          //   lossy either, so the positive cell would have nothing to observe
          //   even if the injector could dial a router.
          //
          // What IS a routed claim, and what this cell asserts, is the dual: a
          // router hop must not MANUFACTURE a miss. A hop that reordered or
          // dropped under the covers would be reported by the very listener
          // the positive cell cannot drive, so this reads the same bridge from
          // the other side.
          const key = 'zenoh/dart/test/adv-int/miss-none';
          const payloads = ['seq_1', 'seq_2', 'seq_3', 'seq_4', 'seq_5'];

          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: _cachingPublisher,
          );
          addTearDown(publisher.close);

          final subscriber = subscriberLeaf.declareAdvancedSubscriber(
            key,
            options: const AdvancedSubscriberOptions(
              history: true,
              detectLatePublishers: true,
              recovery: true,
              lastSampleMissDetection: true,
              subscriberDetection: true,
              enableMissListener: true,
            ),
          );
          final samples = _collectAdvanced(subscriber);
          expect(subscriber.missEvents, isNotNull);
          final misses = <MissEvent>[];
          final missSubscription = subscriber.missEvents!.listen(misses.add);
          addTearDown(missSubscription.cancel);

          await awaitMatching(publisher.hasMatchingSubscribers);
          payloads.forEach(publisher.put);

          await awaitCondition(
            () => samples.length >= payloads.length,
            description:
                'the advanced subscriber to receive the whole routed '
                'sequence',
          );
          // The sequence arrives complete and in order -- which is what makes
          // the zero below a reading about the miss listener rather than a
          // reading about a path that carried nothing.
          expect(_payloads(samples), equals(payloads));

          await Future<void>.delayed(_negativeWindow);
          expect(misses, isEmpty);
        },
      );
    },
  );

  group(
    'Detection history crosses one hosted router (TCP 19892)',
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

      test(
        'history does not suppress live detection through the router',
        () async {
          // Counterpart of advanced_detect_test.dart:488, on the original's
          // key. Its claim is that enabling history ADDS the past rather than
          // replacing the present.
          //
          // Its dual -- that the past is added at all across a hop -- is
          // already carried at routed_presence_test.dart:658, so it is not
          // repeated here. This cell is the half that pair was missing.
          const key = 'zenoh/dart/detect/hist/live';

          final observed = _observeDetect(
            subscriberLeaf.declareAdvancedSubscriber(
              key,
              options: const AdvancedSubscriberOptions(
                detectPublishers: DetectPublishersOptions(history: true),
              ),
            ),
            probeZidHex,
          );

          // The gate is what makes this a LIVE reading. With history on, a
          // detector that was not yet live would recover the publisher anyway
          // and the cell would be green for the other reason entirely.
          await _awaitRoutedDetector(
            probeLeaf: probeLeaf,
            key: key,
            probes: observed.probes,
          );

          // Nothing of the cell's own pre-exists, so this PUT can only be the
          // live one.
          final publisher = publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          await awaitCondition(
            () => observed.samples.isNotEmpty,
            description:
                'the routed detector to see the live publisher '
                'appear',
          );
          expect(observed.samples.first.kind, equals(SampleKind.put));
          // MEASURED, so nobody reaches for the wrong conclusion later: this
          // cell also passes with `history` turned OFF, and that is the
          // claim, not a hole in it. "History does not SUPPRESS live
          // detection" is asserted by running the live case WITH history on;
          // the same case with it off is a different cell, and
          // routed_presence_test.dart:538 already carries it. What would make
          // this one blind is the reverse -- a detector that was not yet live
          // when the publisher declared, which history alone would then
          // recover -- and the gate above is what rules that out.
          //
          // Identified, not counted: the token names the leaf that declared
          // it, so a stray announcement from anywhere else cannot satisfy
          // this cell.
          expect(
            _tokenZid(observed.samples.first.keyExpr),
            equals(publisherLeaf.zid.toHexString()),
          );
        },
      );
    },
  );
}
