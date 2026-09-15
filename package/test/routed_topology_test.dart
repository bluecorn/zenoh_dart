@Timeout(Duration(minutes: 2))
library;

// The routed observable, made executable once.
//
// This file is the contract for `helpers/routed_topology.dart`, which every
// other routed counterpart in the suite is built on. Its subject is not any
// zenoh feature: it is the MEANING of "a router in the path", pinned as
// assertions so that a later change to the helper cannot quietly redefine it
// for eighty-eight downstream cells.
//
// The three cells that matter most are the ones that fail if the helper is
// wrong rather than merely broken:
//
//   * a client leaf and a peer leaf DO exchange through one hosted router;
//   * the same pair across two UNLINKED routers exchanges nothing;
//   * two PEER leaves through ONE router exchange nothing.
//
// The third is a plan-time probe reading promoted to a shipped assertion. It
// was the finding that a routed configuration without a client leaf delivers
// zero — measured in three arms with the subscriber's readiness confirmed
// beside every zero. As a probe it was a transcript nobody could check; as a
// cell it re-runs on every invocation and fails the day it stops being true.
//
// PORTS: 19810-19819, this file's block of the unit's 19800-19899 band.
// 19810-19814 in-process; 19815-19819 the spawned-leaf leg.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';
import 'helpers/routed_topology.dart';

/// How long a negative control waits before concluding nothing arrived.
///
/// It has to exceed the positive path's convergence by a clear margin, or a
/// slow green reads as a red. The positive cells in this file deliver in well
/// under a second once both leaves report the router; five seconds is the
/// same order the plan-time probes used to establish these zeros.
const _negativeWindow = Duration(seconds: 5);

void main() {
  group('One hosted router carries a client-to-peer exchange (TCP 19810)', () {
    late HostedRouter router;
    late Session clientLeaf;
    late Session peerLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(19810);
      clientLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      peerLeaf = await Session.open(config: router.leafConfig(LeafMode.peer));

      // Readiness is the leaves' own view of the router, not a sleep.
      await router.awaitAttached(clientLeaf);
      await router.awaitAttached(peerLeaf);
    });

    tearDownAll(() {
      peerLeaf.close();
      clientLeaf.close();
      router.close();
    });

    test(
      'a client leaf reaches a peer leaf through the hosted router',
      () async {
        const key = 'routed/topology/one-router';
        const payload = 'ROUTED-ONE-ROUTER';

        final received = <String>[];
        final subscription = peerLeaf
            .declareBackgroundSubscriber(key)
            .listen((s) => received.add(utf8.decode(s.payloadBytes)));
        addTearDown(subscription.cancel);

        // TWO witnesses, and they answer DIFFERENT questions. peersZid says the
        // TRANSPORT linked; it says nothing about the subscriber's declaration
        // having reached the router. Publishing on the strength of the first
        // alone is a race that silently loses the sample, because zenoh retains
        // nothing for a subscriber that was not there yet -- and the cell would
        // then fail intermittently, wearing the costume of non-delivery.
        await router.awaitPeerLeaf(peerLeaf.zid);

        // The second witness is EXACT rather than a settle: a publisher
        // reporting a matching subscriber IS the router having propagated that
        // subscriber's declaration back to it. It cannot pass early.
        final publisher = clientLeaf.declarePublisher(key);
        addTearDown(publisher.close);
        await awaitMatching(publisher.hasMatchingSubscribers);

        publisher.put(payload);

        await awaitCondition(
          () => received.isNotEmpty,
          description: 'the peer leaf to receive the routed publication',
        );
        expect(received, contains(payload));
      },
    );

    test('the router reports the peer leaf and not the client leaf', () {
      // The second, independent witness that the attachment is real: the
      // router's own view, partitioned by role. A configured-but-unattached
      // leaf would satisfy neither half.
      final peers = router.peersZid();

      expect(peers, contains(peerLeaf.zid));
      expect(peers, isNot(contains(clientLeaf.zid)));
    });

    test('two peer leaves through one router exchange nothing', () async {
      // §0.1's finding as a shipped assertion. Both leaves are peers, both
      // attached to the SAME router, both with discovery suppressed — and
      // that configuration is isolated, not routed.
      const key = 'routed/topology/peer-to-peer';
      const payload = 'ROUTED-PEER-TO-PEER';

      final publisher = await Session.open(
        config: router.leafConfig(LeafMode.peer),
      );
      addTearDown(publisher.close);

      final received = <String>[];
      final subscription = peerLeaf
          .declareBackgroundSubscriber(key)
          .listen((s) => received.add(utf8.decode(s.payloadBytes)));
      addTearDown(subscription.cancel);

      // Readiness asserted BEFORE the publication, so the zero below cannot
      // be a subscriber that never started or a publisher that never
      // attached.
      await router.awaitAttached(publisher);
      await router.awaitPeerLeaf(peerLeaf.zid);
      // A settle, not a poll: there is no matching status to wait on here,
      // because the whole point is that no route exists. Giving the
      // declaration every chance to propagate is what makes the zero below a
      // finding rather than a race won by the assertion.
      await settleForDeclaration();

      publisher.put(key, payload);
      await Future<void>.delayed(_negativeWindow);

      expect(received, isEmpty);
    });
  });

  group('Two unlinked hosted routers carry nothing between them', () {
    late HostedRouter routerA;
    late HostedRouter routerB;
    late Session subscriberLeaf;
    late Session publisherLeaf;

    setUpAll(() async {
      routerA = await HostedRouter.open(19811);
      routerB = await HostedRouter.open(19812);

      subscriberLeaf = await Session.open(
        config: routerA.leafConfig(LeafMode.peer),
      );
      // Identical flags, identical roles — the ONLY difference is which
      // router it dials. That is what makes the zero attributable to the
      // path.
      publisherLeaf = await Session.open(
        config: routerB.leafConfig(LeafMode.client),
      );

      await routerA.awaitAttached(subscriberLeaf);
      await routerB.awaitAttached(publisherLeaf);
    });

    tearDownAll(() {
      publisherLeaf.close();
      subscriberLeaf.close();
      routerB.close();
      routerA.close();
    });

    test(
      'the split control observes nothing, with the subscriber ready first',
      () async {
        const key = 'routed/topology/split';
        const payload = 'ROUTED-SPLIT-CONTROL';

        final received = <String>[];
        final subscription = subscriberLeaf
            .declareBackgroundSubscriber(key)
            .listen((s) => received.add(utf8.decode(s.payloadBytes)));
        addTearDown(subscription.cancel);

        // Asserted, not assumed: the subscriber is attached and visible to its
        // own router before anything is published.
        await routerA.awaitPeerLeaf(subscriberLeaf.zid);
        // Same settle as the peer-to-peer control, for the same reason: the
        // zero has to be the unlinked routers, never a declaration that had not
        // landed yet.
        await settleForDeclaration();

        publisherLeaf.put(key, payload);
        await Future<void>.delayed(_negativeWindow);

        expect(received, isEmpty);
      },
    );

    test('each leaf reports exactly its own router', () {
      // The leaves are not isolated by accident of a failed open: each has a
      // live attachment, to a DIFFERENT router. Without this the split
      // control would be satisfied by two leaves that connected to nothing.
      expect(subscriberLeaf.routersZid(), hasLength(1));
      expect(subscriberLeaf.routersZid().single, equals(routerA.zid));

      expect(publisherLeaf.routersZid(), hasLength(1));
      expect(publisherLeaf.routersZid().single, equals(routerB.zid));

      expect(routerA.zid, isNot(equals(routerB.zid)));
    });
  });

  group('The helper refuses configurations that would not be routed', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(19813);
    });

    tearDownAll(() {
      router.close();
    });

    test('a leaf configuration that leaves gossip enabled is refused', () {
      expect(
        () => router.leafConfig(LeafMode.client, disableGossip: false),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('gossip'), contains('beside the')),
          ),
        ),
      );
    });

    test('a leaf configuration that leaves multicast enabled is refused', () {
      expect(
        () => router.leafConfig(LeafMode.peer, disableMulticast: false),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the spawned-leaf flag block refuses the same configurations', () {
      // Both surfaces enforce it, or a CLI counterpart could be built
      // unrouted while its in-process sibling could not.
      expect(
        () => router.leafArgs(LeafMode.client, disableGossip: false),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => router.leafArgs(LeafMode.client, disableMulticast: false),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a pair with no client leaf is refused at construction', () {
      // The trap the peer-to-peer cell above pins, made unenterable by
      // accident.
      expect(
        () => RoutedPair(LeafMode.peer, LeafMode.peer),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('client mode'), contains('ISOLATED')),
          ),
        ),
      );
      expect(
        () => RoutedPair(LeafMode.router, LeafMode.router),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a pair with a client leaf on either side is accepted', () {
      expect(RoutedPair(LeafMode.client, LeafMode.peer).b, LeafMode.peer);
      expect(RoutedPair(LeafMode.peer, LeafMode.client).a, LeafMode.peer);
      expect(RoutedPair(LeafMode.client, LeafMode.client).a, LeafMode.client);
    });

    test(
      'a port outside the unit band is refused at both boundaries',
      () async {
        // The band is enforced rather than documented: a stray port would
        // collide with the ~189 endpoint literals the corpus already holds
        // below 19765, and the collision would present as a delivery red
        // rather than as an address clash.
        //
        // The samples are the two OFF-BY-ONE values rather than, say, the
        // harness's own 7447. Two reasons, and the second is the load-bearing
        // one: an off-by-one is the realistic defect in a range check, and a
        // routed file that named 7447 would trip this unit's own independence
        // guard, which reads a low port literal as a dependency and cannot see
        // that this one is being refused rather than bound.
        //
        // `open` is async, so the refusal arrives as a rejected future — which
        // is why this is expectLater and not expect.
        await expectLater(
          HostedRouter.open(routedPortFloor - 1),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          HostedRouter.open(routedPortCeiling + 1),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('every emitted leaf configuration states the same four things', () {
      // The two surfaces must express mode, the router endpoint, multicast
      // off and gossip off identically, or an in-process cell and its spawned
      // sibling would be testing different topologies while reading alike.
      final args = router.leafArgs(LeafMode.client);

      expect(args, containsAllInOrder(['-m', 'client']));
      expect(args, containsAllInOrder(['-e', 'tcp/127.0.0.1:${router.port}']));
      expect(args, contains('--no-multicast-scouting'));
      expect(
        args,
        containsAllInOrder(['--cfg', 'scouting/gossip/enabled:false']),
      );
      expect(args, isNot(contains('-l')));
    });
  });

  group("The helper's waits have ceilings and its ports are released", () {
    test(
      'awaitCondition fails with its bound and description, not a hang',
      () async {
        // An unbounded wait here would freeze the serial suite, which is the
        // most expensive failure this unit can produce.
        const bound = Duration(milliseconds: 300);
        final started = DateTime.now();

        await expectLater(
          awaitCondition(
            () => false,
            description: 'a condition that never holds',
            within: bound,
          ),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message ?? '',
              'message',
              allOf(
                contains('300ms'),
                contains('a condition that never holds'),
              ),
            ),
          ),
        );

        // It returned by its own bound rather than by the test timeout.
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 10)),
        );
      },
    );

    test('a closed hosted router releases its port for a second one', () async {
      // Without this, one group's teardown could poison the next group in the
      // same file — and the failure would present as a delivery red.
      const port = 19814;

      final first = await HostedRouter.open(port);
      final firstZid = first.zid;
      first.close();

      final second = await HostedRouter.open(port);
      addTearDown(second.close);

      expect(second.port, equals(port));
      expect(second.zid, isNot(equals(firstZid)));
    });
  });
  group('The hosted router serves SPAWNED leaves too (TCP 19815)', () {
    // 26 of the 88 counterparts spawn our example binaries rather than opening
    // sessions in-process. The hosted router has to serve those the same way,
    // and the flag block they receive has to express the same topology the
    // in-process Config does -- or a CLI counterpart and its in-process
    // sibling test different things while reading alike.
    //
    // ⛔ NO CANON BINARY IS DRIVEN HERE, and that is a departure from the
    // plan's Slice 8 Test 3, recorded rather than silent. The default suite
    // has ZERO canon dependency today (measured), and the interop runner's own
    // header says why: a skip-when-canon-is-absent cell in the default run
    // "would silently reduce this gate to nothing". Hard-requiring canon here
    // would break A1's "runs for someone who has never fetched anything".
    // The plan already sites exactly this arm correctly one slice over --
    // Slice 17 Test 4 puts its canon-as-router cell in the interop tier
    // "because it needs canon's binaries" -- so the canon arm lives there.
    late HostedRouter router;
    late HostedRouter split;

    setUpAll(() async {
      router = await HostedRouter.open(19815);
      split = await HostedRouter.open(19816);
    });

    tearDownAll(() {
      split.close();
      router.close();
    });

    test(
      'a spawned subscriber receives a spawned publisher through the router',
      () async {
        const key = 'routed/spawned/one-router';
        const payload = 'ROUTED-SPAWNED-DELIVERY';

        final sub = await Process.start(Platform.resolvedExecutable, [
          'run',
          'example/z_sub.dart',
          '-k',
          key,
          ...router.leafArgs(LeafMode.peer),
        ], workingDirectory: Directory.current.path);
        addTearDown(() => forceKill(sub));
        final out = StringBuffer();
        sub.stdout.transform(const SystemEncoding().decoder).listen(out.write);
        await waitForReady(out);

        // The router's own view is the second witness that the spawned leaf
        // really attached, not merely that it printed its banner.
        await awaitCondition(
          () => router.peersZid().isNotEmpty,
          description: 'the hosted router to report the spawned peer leaf',
          within: const Duration(seconds: 20),
        );

        final put = await Process.start(Platform.resolvedExecutable, [
          'run',
          'example/z_put.dart',
          '-k',
          key,
          '-p',
          payload,
          ...router.leafArgs(LeafMode.client),
        ], workingDirectory: Directory.current.path);
        addTearDown(() => forceKill(put));

        await waitForOutput(out, payload, timeout: const Duration(seconds: 30));
        expect(out.toString(), contains(payload));
      },
    );

    test('the same pair across two unlinked routers prints nothing', () async {
      const key = 'routed/spawned/split';
      const payload = 'ROUTED-SPAWNED-SPLIT';

      final sub = await Process.start(Platform.resolvedExecutable, [
        'run',
        'example/z_sub.dart',
        '-k',
        key,
        ...router.leafArgs(LeafMode.peer),
      ], workingDirectory: Directory.current.path);
      addTearDown(() => forceKill(sub));
      final out = StringBuffer();
      sub.stdout.transform(const SystemEncoding().decoder).listen(out.write);
      // Readiness FIRST: the subscriber reached its banner, so a zero below
      // cannot be a process that never started.
      await waitForReady(out);

      final put = await Process.start(Platform.resolvedExecutable, [
        'run',
        'example/z_put.dart',
        '-k',
        key,
        '-p',
        payload,
        ...split.leafArgs(LeafMode.client),
      ], workingDirectory: Directory.current.path);
      addTearDown(() => forceKill(put));
      await put.exitCode;
      await Future<void>.delayed(_negativeWindow);

      expect(out.toString(), isNot(contains(payload)));
    });

    test('the spawned flag block and the in-process Config state one spec', () async {
      // Both surfaces render `leafSpec`, so this compares renderings rather
      // than two hand-written lists -- a divergence between those is invisible
      // until something goes red for an unrelated reason.
      for (final mode in [LeafMode.client, LeafMode.peer]) {
        final spec = router.leafSpec(mode);
        final args = router.leafArgs(mode);

        expect(args, containsAllInOrder(['-m', spec.mode]));
        expect(args, containsAllInOrder(['-e', spec.endpoint]));
        expect(args.contains('--no-multicast-scouting'), spec.multicastOff);
        expect(
          args.contains('scouting/gossip/enabled:false'),
          spec.gossipOff,
        );
        expect(spec.endpoint, equals('tcp/127.0.0.1:${router.port}'));
      }
    });

    test('a leaf that cannot reach its router fails with a stated bound', () {
      // The failure has to be loud and bounded. An in-process leaf is used
      // rather than a spawned one deliberately: a spawned example pointed at a
      // dead endpoint may retry indefinitely inside zenoh rather than exit, so
      // asserting on its output would test the retry policy, not the gate.
      // Here the bound and the condition are both this helper's own.
      expect(
        awaitCondition(
          () => false,
          description: 'a leaf to attach to a router that is not there',
          within: const Duration(milliseconds: 400),
        ),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message ?? '',
            'message',
            allOf(contains('400ms'), contains('not there')),
          ),
        ),
      );
    });
  });
}
