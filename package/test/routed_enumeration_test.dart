@Timeout(Duration(minutes: 2))
library;

// Peer enumeration, with a router actually in the path.
//
// Seven default-suite cells assert what a session's peer and router lists
// CONTAIN, and every one asserts it over a direct peer link. This file adds
// their routed counterparts. All seven originals stay exactly where they are.
//
// ⭐ THE CLASS IS INTERESTING BECAUSE THE ANSWER CHANGES, and canon says so.
// Behind a router a leaf has exactly ONE transport -- to the router -- so
// `peersZid()` is EMPTY and the router appears under `routersZid()`. The
// originals' "each connector sees exactly the listener, and not its siblings"
// becomes "each leaf sees exactly the ROUTER, and not its siblings", which is
// the same claim about a different topology rather than a weaker one. That
// asymmetry is canon-verified at runtime/mod.rs:221-233 and is used here as an
// EXPECTED VALUE; it is not re-derived.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
// (declaration lines measured, not copied from a spec; the plan's citations
//  are assertion sites, which is the noun the corpus classification uses)
//
//   test/session_test.dart
//     test@396 'two connected sessions see each other as peers'
//       -> "two leaves behind one router see the ROUTER, and not each other"
//     test@886 'small-N peers are all returned'
//       -> "a router returns all of its small-N peer leaves"
//
//   test/zid_collection_test.dart
//     test@103 'the collectors hand back a shim-owned buffer with an exact
//              count'
//     test@164 'the shipped public path is behaviour-preserving'
//       -> "the routed collectors hand back an exact count, and the public
//          path agrees with itself"
//     test@287 'the listener returns exactly the three peers that dialled it'
//       -> "the router returns exactly the three peer leaves that dialled it"
//     test@300 'each connector sees exactly the listener, and not its
//              siblings'
//       -> "each leaf sees exactly the router, and not its siblings"
//
//   test/zenoh_test.dart
//     test@37  'discovers a peer session'
//       -> "a leaf discovers the router it was pointed at, and nothing else"
//
// ⛔ TWO CARVES, DATED, AND THEY ARE NOT OMISSIONS
//
//   test/z_scout_cli_test.dart:46 'discovers a listening peer'
//   test/interop/session_info_interop.dart 'our z_scout discovers a canon peer
//     by its exact zid'
//
// Neither gains a routed counterpart, and the reason is canon-intrinsic rather
// than convenience: a scout Hello is a MULTICAST DATAGRAM on 224.0.0.224:7446.
// No router mediates it. "A router in the path" is therefore not a state the
// scout feature can be in, and a routed counterpart would satisfy "a router
// endpoint is configured" and nothing else -- the precise failure this unit
// exists to forbid. Canon's own z_scout also parses no arguments at all
// (z_scout.c calls z_config_default and never parse_args), so the reverse
// direction is unbuildable on any host. Both originals stay untouched on their
// multicast wiring. Carved 2026-09-08.
//
// The two cells asserting that these reasons are WRITTEN DOWN read a file under
// test/interop/, which the release leaves behind, so they live in
// test/dev/routed_enumeration_governance_test.dart — moved 2026-09-14, when
// certification in the public repository went red on them.
//
// ⚠️ A third absence, stated because a silent one would fail this unit's own
// criterion: the two z_info interop cells were CARVED from routed mode by
// Slice 5's routing red leg, which caught them passing while establishing
// nothing about routing. That carve is recorded at
// test/interop/canon.dart's `directArgs`.
//
// PORTS: 19880-19884. 19880 carries the star topology; 19881 is the unlinked
// router the split control attaches to.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/routed_topology.dart';

const _routerPort = 19880;
const _splitRouterPort = 19881;

void main() {
  group('A router partitions what its leaves can enumerate (TCP 19880)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;
    late Session clientLeaf;
    late Session peerA;
    late Session peerB;
    late Session peerC;
    late Session splitLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_routerPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);

      clientLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      peerA = await Session.open(config: router.leafConfig(LeafMode.peer));
      peerB = await Session.open(config: router.leafConfig(LeafMode.peer));
      peerC = await Session.open(config: router.leafConfig(LeafMode.peer));
      splitLeaf = await Session.open(
        config: splitRouter.leafConfig(LeafMode.peer),
      );

      // Readiness is each leaf's own view of its router, never a sleep.
      for (final leaf in [clientLeaf, peerA, peerB, peerC]) {
        await router.awaitAttached(leaf);
      }
      await splitRouter.awaitAttached(splitLeaf);

      // And the router's own view of the three peers, which is what the
      // star-topology cells read.
      for (final leaf in [peerA, peerB, peerC]) {
        await router.awaitPeerLeaf(leaf.zid);
      }
    });

    tearDownAll(() {
      splitLeaf.close();
      peerC.close();
      peerB.close();
      peerA.close();
      clientLeaf.close();
      splitRouter.close();
      router.close();
    });

    test(
      'the router returns exactly the three peer leaves that dialled it',
      () {
        // The routed counterpart of zid_collection_test.dart:287, which asserts
        // the same shape about a LISTENER on a direct link. Behind a router the
        // star's centre is the router, so the claim moves with it.
        final peers = router.peersZid();

        expect(peers.toSet(), equals({peerA.zid, peerB.zid, peerC.zid}));
        expect(peers, hasLength(3), reason: 'no duplicates');
        for (final id in peers) {
          expect(id.bytes, hasLength(16));
        }
      },
    );

    test('each leaf sees exactly the router, and not its siblings', () {
      // The routed counterpart of zid_collection_test.dart:300. On a direct
      // link a connector sees the listener and not its siblings; behind a
      // router it sees the ROUTER and not its siblings, because it has exactly
      // one transport.
      for (final leaf in [peerA, peerB, peerC, clientLeaf]) {
        expect(leaf.routersZid(), hasLength(1));
        expect(leaf.routersZid().single, equals(router.zid));

        // ⛔ An identity assertion, not a count. A count alone is satisfiable
        // by any stray zenoh process, which is what the suppression exists to
        // rule out.
        expect(leaf.peersZid(), isEmpty);
        for (final sibling in [peerA, peerB, peerC, clientLeaf]) {
          expect(leaf.routersZid(), isNot(contains(sibling.zid)));
        }
      }
    });

    test('the router partitions its own view by role', () {
      // Peer leaves land in peersZid; a client leaf does not. Canon-verified
      // and used here as the expected value.
      final peers = router.peersZid();

      expect(peers, contains(peerA.zid));
      expect(peers, isNot(contains(clientLeaf.zid)));
      expect(peers, isNot(contains(router.zid)));
      // The router knows no other router.
      expect(router.routersZid(), isEmpty);
    });

    test('two leaves behind one router see the router, and not each other', () {
      // The routed counterpart of session_test.dart:396, whose direct-path
      // claim is that two connected sessions see EACH OTHER as peers. Behind a
      // router that is structurally impossible, and this cell says so rather
      // than asserting a weaker version of the original.
      expect(peerA.peersZid(), isNot(contains(peerB.zid)));
      expect(peerB.peersZid(), isNot(contains(peerA.zid)));
      expect(peerA.routersZid(), equals(peerB.routersZid()));
    });

    test('a leaf on a second unlinked router reports a DIFFERENT router', () {
      // The discriminating half. Without it, "each leaf reports one router"
      // would be satisfied by an enumeration that returned any router at all.
      expect(splitLeaf.routersZid(), hasLength(1));
      expect(splitLeaf.routersZid().single, equals(splitRouter.zid));
      expect(splitLeaf.routersZid(), isNot(contains(router.zid)));
      expect(router.zid, isNot(equals(splitRouter.zid)));

      // And the two routers do not know each other.
      expect(router.peersZid(), isNot(contains(splitLeaf.zid)));
      expect(splitRouter.peersZid(), isNot(contains(peerA.zid)));
    });

    test(
      'the routed collectors hand back an exact count with no duplicates',
      () {
        // The routed counterpart of zid_collection_test.dart:103 and :164 --
        // the collector's own contract, which must survive the topology change:
        // an exact count, a stable public path, and 16-byte ids.
        final first = router.peersZid();
        final second = router.peersZid();

        expect(first.length, equals(second.length));
        expect(first.toSet(), equals(second.toSet()));
        expect(first.toSet(), hasLength(first.length), reason: 'no duplicates');
        for (final id in first) {
          expect(id.bytes, hasLength(16));
          expect(id.toHexString(), isNotEmpty);
        }
      },
    );

    test('a leaf discovers the router it was pointed at, and nothing else', () {
      // The routed counterpart of zenoh_test.dart:37 'discovers a peer
      // session'. With multicast and gossip both off, the configured endpoint
      // is the only route, so what a leaf discovers is exactly what it dialled
      // -- which is what makes this an identity claim rather than a liveness
      // one.
      final known = {...clientLeaf.routersZid(), ...clientLeaf.peersZid()};

      expect(known, equals({router.zid}));
    });
  });
}
