@Timeout(Duration(minutes: 2))
library;

// Delivery across a link, with a router actually in the path.
//
// Seven cells in the default suite certify that a publication reaches a
// subscriber, and every one of them certifies it over a DIRECT peer link --
// the one shape a deployment never uses. This file adds their routed
// counterparts. Nothing here replaces anything: all seven originals stay
// exactly where they are, unedited, and keep certifying the direct path.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
//   test/publisher_test.dart:173 "Publisher.put received by subscriber as
//   PUT sample" (assertion at :186)
//     -> "a publisher put crosses the router to the subscriber"
//
//   test/publisher_test.dart:191 "Publisher.deleteResource received by
//   subscriber as DELETE sample" (assertion at :208)
//     -> "a publisher delete crosses the router to the subscriber"
//
//   test/publisher_test.dart:333 "Multiple publishers on different keys each
//   received by correct subscriber" (assertion at :358)
//     -> "two publishers on different keys reach their own subscribers"
//
//   test/publisher_test.dart:542 "Publisher with isExpress true can publish
//   and subscriber receives" (assertion at :562)
//     -> "an express publication is delivered through the router"
//
//   test/advanced_subscriber_test.dart:175 "AdvancedPublisher put received by
//   AdvancedSubscriber" (assertion at :198)
//     -> "an advanced put reaches the advanced subscriber"
//
//   test/advanced_subscriber_test.dart:202 "AdvancedPublisher deleteResource
//   received by AdvancedSubscriber" (assertion at :227)
//     -> "an advanced delete reaches the advanced subscriber"
//
//   test/advanced_subscriber_test.dart:397 "AdvancedPublisher putBytes
//   received by AdvancedSubscriber" (assertion at :433)
//     -> "an advanced putBytes reaches the advanced subscriber"
//
// WHY DELIVERY ITSELF IS THE OBSERVABLE HERE
//
// Pointing two sessions at a router is not routing them. Peers find each
// other by gossip and link DIRECTLY, so the router sits beside the path and
// the green is indistinguishable from the no-router case. Every leaf below
// is built by helpers/routed_topology.dart, which carries the three things
// that make the difference real: the router's endpoint only, both discovery
// mechanisms off, and at least one leaf in client mode. With those in place
// no leaf-to-leaf link can form, so anything that arrives was carried by the
// router.
//
// THE TWO NEGATIVE CONTROLS, AND WHY EACH IS NOT VACUOUS
//
// A cell whose subject is "it arrives" needs a companion that could have
// caught a green produced by something other than the route.
//
//   * THE SPLIT CONTROL. The same two leaves with the same flags, the
//     publisher dialling a SECOND, unlinked router. Nothing may arrive. Its
//     zero is only worth reading because the subscriber's attachment is
//     asserted from the router's own view before anything is published, and
//     because the identical pair on one router delivers in the cell above it.
//
//   * THE PRE-ATTACH CONTROL. A publication made before any subscriber
//     exists is not retained by zenoh, so a late subscriber must see nothing
//     of it. That cell then publishes AGAIN and requires the same subscriber
//     to receive it, so its zero cannot be a subscriber that never worked.
//
// Every wait in this file has a ceiling and states it: the positive paths
// poll through awaitCondition/awaitMatching, and the two absence windows are
// a fixed, stated interval that the positive path beats by a wide margin.
//
// PORTS: 19820-19829, this file's block of the unit's 19800-19899 band.
// 19820 carries every positive cell; 19821 is the unlinked router the split
// control publishes into; 19822 is the advanced pair's.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/routed_topology.dart';

/// The router every positive cell in the first group crosses.
const _routerPort = 19820;

/// The second router, deliberately unlinked from [_routerPort].
const _splitRouterPort = 19821;

/// The advanced pair's router.
const _advancedRouterPort = 19822;

/// How long a negative control waits before concluding nothing arrived.
///
/// It must exceed the positive path's convergence by a clear margin or a slow
/// green reads as a red. The positive cells here deliver in well under a
/// second once the publisher reports a matching subscriber; five seconds is
/// the interval the unit's other absence cells already use.
const _negativeWindow = Duration(seconds: 5);

/// Collects everything [stream] delivers, closing the declaration after.
///
/// Collecting into a list rather than awaiting `stream.first` is what lets
/// the absence cells assert a zero at all: `first` can only time out, and a
/// timeout reads identically whether nothing was sent or the subscriber never
/// started. Registers its own teardown, so a cell states the key once and
/// then reads a list.
List<Sample> _collect(Stream<Sample> stream, void Function() close) {
  addTearDown(close);
  final samples = <Sample>[];
  final subscription = stream.listen(samples.add);
  addTearDown(subscription.cancel);
  return samples;
}

/// Declares a subscriber on [leaf] for [key] and collects what it delivers.
List<Sample> _subscribeCollecting(Session leaf, String key) {
  final subscriber = leaf.declareSubscriber(key);
  return _collect(subscriber.stream, subscriber.close);
}

/// The advanced-subscriber form of [_subscribeCollecting].
List<Sample> _collectAdvanced(AdvancedSubscriber subscriber) =>
    _collect(subscriber.stream, subscriber.close);

void main() {
  group('A publication crosses one hosted router (TCP 19820, split 19821)', () {
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

      // Readiness is each leaf's own view of its router, never a sleep.
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
      // once: the two leaves are attached, to the routers this file names,
      // and the split leaf is attached to a DIFFERENT one. Without it a
      // universal zero would be satisfied by three leaves that connected to
      // nothing at all.
      expect(publisherLeaf.routersZid(), hasLength(1));
      expect(publisherLeaf.routersZid().single, equals(router.zid));
      expect(subscriberLeaf.routersZid(), hasLength(1));
      expect(subscriberLeaf.routersZid().single, equals(router.zid));

      expect(splitPublisherLeaf.routersZid(), hasLength(1));
      expect(splitPublisherLeaf.routersZid().single, equals(splitRouter.zid));
      expect(splitRouter.zid, isNot(equals(router.zid)));
    });

    test('a publisher put crosses the router to the subscriber', () async {
      // Counterpart of publisher_test.dart:173, on the same key and payload.
      const key = 'zenoh/dart/test/pub-put';
      final samples = _subscribeCollecting(subscriberLeaf, key);

      final publisher = publisherLeaf.declarePublisher(key);
      addTearDown(publisher.close);

      // EXACT readiness, not a settle. awaitAttached in setUpAll witnessed
      // that the transport linked; it says nothing about the subscriber's
      // declaration having reached the router. A publisher reporting a match
      // IS that declaration having been propagated back, so this cannot pass
      // early -- and publishing without it loses the sample, because zenoh
      // retains nothing for a subscriber that was not there yet.
      await awaitMatching(publisher.hasMatchingSubscribers);

      publisher.put('hello from pub');

      await awaitCondition(
        () => samples.isNotEmpty,
        description: 'the routed subscriber to receive the put',
      );
      expect(samples.single.payload, equals('hello from pub'));
      expect(samples.single.kind, equals(SampleKind.put));
      expect(samples.single.keyExpr, equals(key));
    });

    test(
      'the same publication across two unlinked routers is not received',
      () async {
        // THE SPLIT CONTROL. Same key, same payload, same pair of roles as the
        // cell above; the publisher dials the other router.
        const key = 'zenoh/dart/test/pub-put';
        final samples = _subscribeCollecting(subscriberLeaf, key);

        // Readiness FIRST, so a zero can never be a subscriber that failed to
        // start: the router's own view of the leaf, then the settle that gives
        // the declaration every chance to propagate. There is no matching
        // status to poll here -- the whole point is that no route exists.
        await router.awaitPeerLeaf(subscriberLeaf.zid);
        await settleForDeclaration();

        final publisher = splitPublisherLeaf.declarePublisher(key);
        addTearDown(publisher.close);

        publisher.put('hello from pub');
        await Future<void>.delayed(_negativeWindow);

        expect(samples, isEmpty);
        // A second, independent reading of the same absence: the publisher on
        // the other router never sees the subscriber either.
        expect(publisher.hasMatchingSubscribers(), isFalse);
      },
    );

    test('a publisher delete crosses the router to the subscriber', () async {
      // Counterpart of publisher_test.dart:191. The original asserts the
      // delete's KIND only; this one puts first so the delete is observed
      // against a value that was already delivered, as the slice specifies.
      const key = 'zenoh/dart/test/pub-del';
      final samples = _subscribeCollecting(subscriberLeaf, key);

      final publisher = publisherLeaf.declarePublisher(key);
      addTearDown(publisher.close);
      await awaitMatching(publisher.hasMatchingSubscribers);

      publisher.put('value before the delete');
      await awaitCondition(
        () => samples.isNotEmpty,
        description: 'the routed subscriber to receive the put',
      );

      publisher.deleteResource();
      await awaitCondition(
        () => samples.length >= 2,
        description: 'the routed subscriber to receive the delete',
      );

      expect(samples[0].kind, equals(SampleKind.put));
      expect(samples[1].kind, equals(SampleKind.delete));
      expect(samples[1].keyExpr, equals(key));
    });

    test(
      'two publishers on different keys reach their own subscribers',
      () async {
        // Counterpart of publisher_test.dart:333, on the same keys and
        // payloads. Its claim is discrimination, not delivery: the router must
        // carry each publication to the matching subscriber and to no other.
        const keyA = 'zenoh/dart/test/pub-a';
        const keyB = 'zenoh/dart/test/pub-b';
        final samplesA = _subscribeCollecting(subscriberLeaf, keyA);
        final samplesB = _subscribeCollecting(subscriberLeaf, keyB);

        final pubA = publisherLeaf.declarePublisher(keyA);
        addTearDown(pubA.close);
        final pubB = publisherLeaf.declarePublisher(keyB);
        addTearDown(pubB.close);
        await awaitMatching(pubA.hasMatchingSubscribers);
        await awaitMatching(pubB.hasMatchingSubscribers);

        pubA.put('alpha');
        pubB.put('beta');

        await awaitCondition(
          () => samplesA.isNotEmpty && samplesB.isNotEmpty,
          description: 'both routed subscribers to receive their publication',
        );

        expect(samplesA.single.payload, equals('alpha'));
        expect(samplesA.single.keyExpr, equals(keyA));
        expect(samplesB.single.payload, equals('beta'));
        expect(samplesB.single.keyExpr, equals(keyB));
      },
    );

    test('an express publication is delivered through the router', () async {
      // Counterpart of publisher_test.dart:542. The express class travels a
      // different path inside zenoh's transport; the routed hop must not
      // silently drop it.
      const key = 'zenoh/dart/test/express-pub';
      final samples = _subscribeCollecting(subscriberLeaf, key);

      final publisher = publisherLeaf.declarePublisher(key, isExpress: true);
      addTearDown(publisher.close);
      await awaitMatching(publisher.hasMatchingSubscribers);

      publisher.put('express message');

      await awaitCondition(
        () => samples.isNotEmpty,
        description: 'the routed subscriber to receive the express put',
      );
      expect(samples.single.payload, equals('express message'));
      expect(samples.single.kind, equals(SampleKind.put));
    });

    test(
      'a publication made before the subscriber attached is not delivered',
      () async {
        // THE PRE-ATTACH CONTROL. zenoh retains nothing for a subscriber that
        // was not there yet, so the routed path must not conjure one either.
        const key = 'zenoh/dart/test/pub-put-late';

        final publisher = publisherLeaf.declarePublisher(key);
        addTearDown(publisher.close);
        // Nothing anywhere is subscribed to this key yet, stated rather than
        // assumed -- it is the premise of the whole cell.
        expect(publisher.hasMatchingSubscribers(), isFalse);

        publisher.put('published before anyone was listening');

        // The subscriber arrives afterwards, on a leaf that did not exist when
        // the publication was made.
        final lateLeaf = await Session.open(
          config: router.leafConfig(LeafMode.peer),
        );
        addTearDown(lateLeaf.close);
        final samples = _subscribeCollecting(lateLeaf, key);

        // The readiness gate is the ROUTER's own view of the new leaf, not a
        // fixed sleep: the leaf really is attached by the time the window
        // opens, so the zero below is about retention and not about a leaf that
        // was still connecting.
        await router.awaitAttached(lateLeaf);
        await router.awaitPeerLeaf(lateLeaf.zid);
        await Future<void>.delayed(_negativeWindow);

        expect(samples, isEmpty);

        // ...and the same subscriber DOES receive what comes after it, which is
        // what stops the zero above being a subscriber that never worked.
        await awaitMatching(publisher.hasMatchingSubscribers);
        publisher.put('published after the subscriber attached');
        await awaitCondition(
          () => samples.isNotEmpty,
          description: 'the late subscriber to receive a later publication',
        );
        expect(
          samples.single.payload,
          equals('published after the subscriber attached'),
        );
      },
    );
  });

  group(
    'An advanced pair exchanges through the hosted router (TCP 19822)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late HostedRouter router;
      late Session publisherLeaf;
      late Session subscriberLeaf;

      setUpAll(() async {
        router = await HostedRouter.open(_advancedRouterPort);
        // timestamping on the publisher's leaf, exactly as the originals
        // configure their session1: the advanced publisher's cache and miss
        // detection require it.
        publisherLeaf = await Session.open(
          config: router.leafConfig(LeafMode.client)
            ..insertJson5('timestamping/enabled', 'true'),
        );
        subscriberLeaf = await Session.open(
          config: router.leafConfig(LeafMode.peer),
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

      // ⭐ CORRECTED at CI verification. This block previously took the
      // helper's settle, on the ground that "the advanced publisher exposes
      // matching status as a STREAM rather than as a poll". That ground is
      // FALSE: AdvancedPublisher carries the same one-shot
      // `hasMatchingSubscribers()` the plain Publisher does
      // (advanced_publisher.dart:263). What actually blocked the exact gate
      // was the HELPER's signature -- it took a `Publisher`, and
      // AdvancedPublisher does not implement Publisher, it `implements
      // Finalizable` independently. `awaitMatching` now takes the predicate,
      // so these three cells get the exact readiness instead of a hopeful
      // 2 s sleep each.
      AdvancedPublisher declareAdvancedFor(String key) =>
          publisherLeaf.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: 5),
              publisherDetection: true,
              sampleMissDetection: true,
            ),
          );

      test('an advanced put reaches the advanced subscriber', () async {
        // Counterpart of advanced_subscriber_test.dart:175.
        const key = 'zenoh/dart/test/adv-int/put';
        final publisher = declareAdvancedFor(key);
        addTearDown(publisher.close);
        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(key),
        );

        await awaitMatching(publisher.hasMatchingSubscribers);
        publisher.put('live message');

        await awaitCondition(
          () => samples.isNotEmpty,
          description: 'the advanced subscriber to receive the routed put',
        );
        expect(samples.single.payload, equals('live message'));
        expect(samples.single.kind, equals(SampleKind.put));
      });

      test('an advanced putBytes reaches the advanced subscriber', () async {
        // Counterpart of advanced_subscriber_test.dart:397.
        const key = 'zenoh/dart/test/adv-int/bytes';
        final publisher = declareAdvancedFor(key);
        addTearDown(publisher.close);
        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(key),
        );

        await awaitMatching(publisher.hasMatchingSubscribers);
        publisher.putBytes(ZBytes.fromString('binary data'));

        await awaitCondition(
          () => samples.isNotEmpty,
          description: 'the advanced subscriber to receive the routed bytes',
        );
        expect(samples.single.payload, equals('binary data'));
      });

      test('an advanced delete reaches the advanced subscriber', () async {
        // Counterpart of advanced_subscriber_test.dart:202, which asserts the
        // delete's KIND only.
        const key = 'zenoh/dart/test/adv-int/del';
        final publisher = declareAdvancedFor(key);
        addTearDown(publisher.close);
        final samples = _collectAdvanced(
          subscriberLeaf.declareAdvancedSubscriber(key),
        );

        await awaitMatching(publisher.hasMatchingSubscribers);
        publisher.deleteResource();

        await awaitCondition(
          () => samples.isNotEmpty,
          description: 'the advanced subscriber to receive the routed delete',
        );
        expect(samples.single.kind, equals(SampleKind.delete));
      });
    },
  );
}
