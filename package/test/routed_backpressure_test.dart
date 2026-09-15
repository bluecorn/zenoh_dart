@Timeout(Duration(minutes: 5))
library;

// Query dispatch under channel backpressure, with a router in the path.
//
// ⛔⛔ READ THIS BEFORE READING THE CELLS. THIS FILE SUPPLEMENTS AN ORIGINAL;
// IT DOES NOT REPLACE, MOVE, OR RE-STATE IT.
//
//   test/pull_queryable_recv_test.dart, test@256
//     'a co-hosted queryable KEEPS ANSWERING while the channel sits full'
//       -> "a getter on another leaf keeps being answered while a queryable's
//          channel sits full on the far side of a router"
//
// THE ORIGINAL STAYS EXACTLY WHERE IT IS, UNEDITED, and it must. The seed
// named it as the one genuine mis-instrumented case and the one place
// relocation was even on the table. It is not relocated, and the reason is not
// this unit's blanket prohibition -- it is that the standing ruling makes the
// SAME-SESSION topology a BOUND rather than a property of the cell. A bound is
// not moved by moving the cell that sits inside it; it is abandoned while
// appearing to have moved.
//
// ⛔ SO: WHAT THIS FILE CLAIMS, AND WHAT IT DOES NOT.
//
//   CLAIMS: that a getter on a SEPARATE leaf, reaching a queryable through a
//   router, keeps being answered while that queryable's pull channel sits
//   full. Cross-leaf dispatch across a routed hop.
//
//   DOES NOT CLAIM: anything whatever about the same-session fifo-full case.
//   That remains a recorded test-topology bound and a dartdoc obligation, and
//   the original cell is the only thing that pins it. A reader who takes this
//   file as having "covered" that case has been misled, which is why the
//   boundary is stated here and asserted by a cell below rather than left to
//   a comment nobody has to read.
//
// ⚠️ AND WHAT THE ORIGINAL LEAVES UNDETERMINED, WHICH THIS FILE DOES NOT
// SETTLE. The original's own comment records that it CONTRADICTS a
// canon-direct probe: the seed measured a session-wide inbound stall while a
// fifo query channel sits full, and through this stack it does not reproduce
// across five configurations including capacity 0 and a thirty-deep wedge.
// Whether the difference is the topology, the zenoh version, or the probe's
// own shape is NOT determined there, and it is NOT determined here either.
// This file adds a third topology to the record. It does not adjudicate the
// divergence, and a result consistent with the original is not evidence about
// its cause.
//
// PORTS: 19895-19899. 19895 carries the routed pair; 19896 is the unlinked
// router the split control queries into.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/routed_topology.dart';

const _routerPort = 19895;
const _splitRouterPort = 19896;

/// The wedge depth, matching the original's ten so the two are comparable.
const _wedgeDepth = 10;

/// Every wait here is bounded, and this is the widest.
///
/// ⛔ An unbounded wait in THIS file would be the most expensive failure the
/// unit can produce: the subject is a channel deliberately left full, so a
/// cell that hung would freeze the serial suite rather than fail it.
const _bound = Duration(seconds: 30);

void main() {
  group('A full channel on one leaf does not stall another (TCP 19895)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;
    late Session hostLeaf;
    late Session getterLeaf;
    late Session splitGetterLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_routerPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);

      // The queryable host is the PEER leaf; the getter is the CLIENT leaf.
      // At least one client is what makes the pair routed rather than
      // isolated.
      hostLeaf = await Session.open(config: router.leafConfig(LeafMode.peer));
      getterLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      splitGetterLeaf = await Session.open(
        config: splitRouter.leafConfig(LeafMode.client),
      );

      await router.awaitAttached(hostLeaf);
      await router.awaitAttached(getterLeaf);
      await splitRouter.awaitAttached(splitGetterLeaf);
      await router.awaitPeerLeaf(hostLeaf.zid);
    });

    tearDownAll(() {
      splitGetterLeaf.close();
      getterLeaf.close();
      hostLeaf.close();
      splitRouter.close();
      router.close();
    });

    test('a getter on another leaf keeps being answered while the channel '
        'sits full', () async {
      const wedgeKey = 'routed/backpressure/wedge';
      const canaryKey = 'routed/backpressure/canary';

      // The CANARY is an ordinary stream-path queryable on the host leaf, with
      // nothing to do with the channel. It is what a stall would silence.
      final canary = hostLeaf.declareQueryable(canaryKey);
      addTearDown(canary.close);
      canary.stream.listen((query) {
        query
          ..reply(canaryKey, 'canary')
          ..dispose();
      });

      final pull = hostLeaf.declarePullQueryable(
        wedgeKey,
        kind: ChannelKind.fifo,
        capacity: 1,
      );
      addTearDown(pull.close);

      // EXACT readiness for the canary, which auto-replies.
      await awaitRoutedQueryable(router, canaryKey, within: _bound);

      // ⛔⛔ AND NOT awaitRoutedQueryable FOR THE WEDGE KEY. It is served by a
      // PULL queryable, which replies only when the test drains it -- so a
      // gate waiting for an automatic reply can never succeed, and its probe
      // query would OCCUPY A SLOT in the capacity-1 channel this cell is about
      // to wedge. Both halves are Slice 13's trap in a new dress: a gate that
      // acts on the carrier the cell asserts over. (Measured: the first
      // version of this cell timed out in exactly that gate.)
      //
      // The gate that works is one that completes the round trip itself --
      // send a get, drain it, reply. It proves the routed path carries a query
      // AND a reply, and it leaves the channel EMPTY for the wedge.
      final primed = getterLeaf
          .get(wedgeKey, timeout: const Duration(seconds: 5))
          .toList();
      var served = false;
      final primeDeadline = DateTime.now().add(_bound);
      while (!served && DateTime.now().isBefore(primeDeadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Query>) {
          r.value
            ..reply(wedgeKey, 'prime')
            ..dispose();
          served = true;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(
        served,
        isTrue,
        reason:
            'the pull queryable never received a routed query, so the '
            'wedge below would have been wedging nothing',
      );
      await primed.timeout(_bound);

      Future<int> canaryReplies() async =>
          (await getterLeaf
                  .get(canaryKey, timeout: const Duration(seconds: 3))
                  .toList()
                  .timeout(_bound))
              .length;

      // PRE-WEDGE CONTROL. Without it, a during-wedge answer could be a canary
      // that answers regardless of anything, which would make the cell empty.
      expect(await canaryReplies(), equals(1), reason: 'canary before wedge');

      // Wedge it: far more getters than the channel can hold, none drained.
      final wedgeGets = <Future<List<Reply>>>[];
      for (var i = 0; i < _wedgeDepth; i++) {
        wedgeGets.add(
          getterLeaf
              .get(wedgeKey, timeout: const Duration(seconds: 60))
              .toList(),
        );
      }
      // Settle time, and it has no condition to poll: the wedge is defined by
      // queries having been SENT and not drained, which nothing observable
      // reports.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        await canaryReplies(),
        equals(1),
        reason:
            'MEASURED, ACROSS A ROUTER: the co-hosted queryable keeps '
            'answering a getter on a different leaf while the channel is full',
      );

      // The wedge was real, not an empty channel: draining recovers every
      // query that was sent, which is also the losslessness half and is what
      // stops the cell passing on a wedge that never happened.
      var drained = 0;
      final deadline = DateTime.now().add(_bound);
      while (drained < _wedgeDepth && DateTime.now().isBefore(deadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Query>) {
          drained++;
          r.value
            ..reply(wedgeKey, 'ack')
            ..dispose();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(drained, equals(_wedgeDepth), reason: 'the wedge must be real');
      for (final g in wedgeGets) {
        await g.timeout(const Duration(seconds: 60));
      }

      expect(await canaryReplies(), equals(1), reason: 'canary after drain');
    });

    test('the same exchange across two unlinked routers completes with no '
        'reply, and does not hang', () async {
      // THE SPLIT CONTROL. The getter is on the other router; every other flag
      // is identical. What it must show is BOTH halves: no reply, AND
      // completion inside the bound -- because "no reply" alone is also what a
      // hang looks like until the suite times out.
      const canaryKey = 'routed/backpressure/split-canary';

      final canary = hostLeaf.declareQueryable(canaryKey);
      addTearDown(canary.close);
      canary.stream.listen((query) {
        query
          ..reply(canaryKey, 'canary')
          ..dispose();
      });

      // Readiness asserted on the router the queryable IS attached to, so a
      // zero cannot be a queryable that never declared.
      await awaitRoutedQueryable(router, canaryKey, within: _bound);

      // ⭐ `.timeout(_bound)` IS the completion assertion: it throws if the
      // get has not finished inside the bound, so reaching the line below is
      // itself the proof that this completed rather than hung. An explicit
      // elapsed-time check here would add nothing and would read as a timing
      // bound on the routed path, which this unit does not assert anywhere.
      final replies = await splitGetterLeaf
          .get(canaryKey, timeout: const Duration(seconds: 3))
          .toList()
          .timeout(_bound);

      expect(replies, isEmpty);
    });
  });

  group('This file states which claim it makes and which it does not', () {
    test('the boundary against the same-session case is written down', () {
      // ⛔ The seed named this the one place relocation was on the table. The
      // ruling is KEEP AND SUPPLEMENT, and a reader has to be able to find
      // that without reconstructing it -- so the file says so and this cell
      // makes the saying non-optional.
      //
      // ⛔⛔ IT SCANS THE HEADER ONLY, AND THE FIRST VERSION WAS A BLIND CELL.
      // Reading the WHOLE file, a cell that asserts `contains('X')` can never
      // fail: the assertion line itself puts X in the file. Calibration caught
      // it -- the perturbation applied and the cell still passed. That is the
      // FOURTH self-reference defect in this unit, all of them mine, and the
      // fix is the same each time: the scanner must not be inside its own
      // subject.
      // ⛔ NORMALISED, and the first version was not. A header phrase wraps
      // across lines with a `// ` between, so a contiguous-substring match
      // fails on prose that is present and correct -- which is the SECOND time
      // this unit has pinned a phrase that wraps (the carve guard was the
      // first). Stripping the comment markers and collapsing whitespace
      // matches MEANING rather than line breaks, which is the property this
      // assertion actually wants: a later reflow must not turn it red.
      final header = File('test/routed_backpressure_test.dart')
          .readAsLinesSync()
          .takeWhile((l) => !l.startsWith('void main()'))
          .map((l) => l.replaceFirst(RegExp(r'^\s*//\s?'), ''))
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          // ...and lowercased, because prose capitalisation depends on
          // sentence position: the header reads "A bound is not moved", and a
          // case-sensitive match for the same clause mid-sentence fails on
          // text that is present and correct.
          .toLowerCase();

      // The needles are lowercase because the haystack is: see above.
      expect(
        header,
        contains('does not claim'),
        reason: 'the header must state what this file does not claim',
      );
      expect(header, contains('same-session fifo-full'));
      expect(header, contains('a bound is not moved by moving the cell'));
    });

    test('the original is unedited and still carries the bound', () {
      // The supplement is only honest if the original is still there making
      // its own claim. If this ever fails, the supplement has become a
      // replacement.
      // (This one reads a DIFFERENT file, so it was never self-referential --
      // noted so nobody "fixes" it into a header scan it does not need.)
      final original = File(
        'test/pull_queryable_recv_test.dart',
      ).readAsStringSync();

      expect(
        original,
        contains(
          'a co-hosted queryable KEEPS ANSWERING while the channel '
          'sits full',
        ),
      );
      // And the divergence it records is still recorded there, not here.
      expect(original, contains('CONTRADICTS THE SEED'));
    });
  });
}
