import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Get/Queryable advanced integration (TCP 17471)', () {
    late Session sessionA;
    late Session sessionB;

    // Discovery is disabled on both sides so the pair is linked by the
    // configured TCP endpoint and nothing else. Left on, a LAN peer running a
    // matching queryable could answer these queries, and the reply-count
    // assertions below -- which is the whole point of the consolidation matrix
    // -- would be counting strangers.
    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17471"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17471"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('multiple queryables on same keyexpr with target=ALL', () async {
      // Declare two queryables on the SAME key expression so both
      // receive the query. Wildcard overlap does not guarantee delivery
      // in peer mode, but same-keyexpr with target=ALL should.
      final queryable1 = sessionA.declareQueryable('zenoh/dart/test/q/multi/a');
      addTearDown(queryable1.close);

      final queryable2 = sessionA.declareQueryable('zenoh/dart/test/q/multi/a');
      addTearDown(queryable2.close);

      queryable1.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/multi/a', 'reply-q1')
          ..dispose();
      });

      queryable2.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/multi/a', 'reply-q2')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get(
            'zenoh/dart/test/q/multi/a',
            target: QueryTarget.all,
            consolidation: ConsolidationMode.none,
          )
          .toList();

      // target=ALL with no consolidation should deliver replies from
      // both queryables
      expect(replies.length, greaterThanOrEqualTo(2));
      final payloads = replies
          .where((r) => r.isOk)
          .map((r) => r.ok.payload)
          .toList();
      expect(payloads, containsAll(['reply-q1', 'reply-q2']));
    });

    test('single queryable sends multiple replies to one query', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/multireply',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/multireply', 'r1')
          ..reply('zenoh/dart/test/q/multireply', 'r2')
          ..reply('zenoh/dart/test/q/multireply', 'r3')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/multireply')
          .toList();

      // zenoh-c supports multiple replies per query; the DEFAULT consolidation
      // then deduplicates by key expression and keeps only the latest. The
      // assertions were `>= 1` and `contains('r3')`, which a path delivering
      // all three -- or one delivering a single wrong reply plus r3 -- also
      // satisfies. The consolidation matrix below establishes that this
      // three-replies-one-key setup is deterministic per mode, so the exact
      // value can be pinned here too.
      expect(replies, hasLength(1));
      final payloads = replies
          .where((r) => r.isOk)
          .map((r) => r.ok.payload)
          .toList();
      expect(payloads, equals(['r3']));
    });

    test('encoding round-trip via queryable reply', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/enc');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply(
            'zenoh/dart/test/q/enc',
            '{"status":"ok"}',
            encoding: Encoding.applicationJson,
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/enc').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.encoding, equals('application/json'));
    });

    // R3: the consolidation behavioural pins.
    //
    // What was here asserted `replies.length <= 2 && >= 1` against two
    // queryables each replying once, with a comment conceding that peer-mode
    // dedup "may not apply strictly". That range spans every outcome the setup
    // can produce, so ConsolidationMode.latest could have been ignored
    // entirely -- or wired to any other mode -- and the test would not move.
    // The two-queryable design is what forced the hedge: whether both replies
    // reach the getter is a routing question, not a consolidation one.
    //
    // ONE queryable sending three replies on ONE key isolates consolidation
    // from routing, and is deterministic: measured 3x3 across all four modes,
    // every run identical.
    //   auto      -> 1 reply  [r3]
    //   none      -> 3 replies [r1, r2, r3]
    //   monotonic -> 3 replies [r1, r2, r3]
    //   latest    -> 1 reply  [r3]
    // The modes therefore split into two observably different classes, and
    // that split is what these tests pin -- a mode wired to the wrong value
    // now crosses the class boundary and reds.

    // Issue one query under [mode] against a queryable that answers r1,r2,r3
    // on a single key, and return the ok-reply payloads in arrival order.
    Future<List<String>> payloadsUnder(
      ConsolidationMode mode,
      String key,
    ) async {
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply(key, 'r1')
          ..reply(key, 'r2')
          ..reply(key, 'r3')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = await sessionB.get(key, consolidation: mode).toList();
      expect(replies.every((r) => r.isOk), isTrue);
      return replies.map((r) => r.ok.payload).toList();
    }

    test('consolidation none delivers every reply in order', () async {
      expect(
        await payloadsUnder(
          ConsolidationMode.none,
          'zenoh/dart/test/q/consol/none',
        ),
        equals(['r1', 'r2', 'r3']),
      );
    });

    test('consolidation latest delivers only the last reply', () async {
      expect(
        await payloadsUnder(
          ConsolidationMode.latest,
          'zenoh/dart/test/q/consol/latest',
        ),
        equals(['r3']),
      );
    });

    test('consolidation monotonic delivers every reply in order', () async {
      // Monotonic drops replies older than one already delivered rather than
      // buffering to pick a winner, so on a strictly increasing sequence from
      // a single source it passes all three through -- the same observable as
      // `none` here, and deliberately pinned as such: the pair below is what
      // makes the claim that monotonic != latest checkable.
      expect(
        await payloadsUnder(
          ConsolidationMode.monotonic,
          'zenoh/dart/test/q/consol/monotonic',
        ),
        equals(['r1', 'r2', 'r3']),
      );
    });

    test('consolidation auto behaves as latest for this shape', () async {
      expect(
        await payloadsUnder(
          ConsolidationMode.auto,
          'zenoh/dart/test/q/consol/auto',
        ),
        equals(['r3']),
      );
    });

    // R3: the custom-timeout repair, and the harness it needed.
    //
    // The test this replaces queried a key with NO queryable behind it and
    // asserted `elapsed <= 5s`. Measured: that get returns in **0 ms**, because
    // a query with no matching queryable finalizes immediately. The timeout was
    // never reached, so the assertion held for any timeout value, including
    // none at all.
    //
    // Reaching a timeout needs a queryable that receives the query and then
    // never finalizes it. Holding the Query object undisposed is exactly that:
    // the getter does not observe completion until the Query is dropped, so the
    // get is forced to run out its clock. The held queries are released in
    // tearDown.
    //
    // With that harness the elapsed time tracks the requested timeout (measured
    // 2002 ms for 2 s, 4002 ms for 4 s) and the stream carries one ERROR reply
    // whose payload is 'Timeout' -- a marker that cannot exist unless the
    // timeout actually fired.
    group('custom timeout (non-finalizing queryable)', () {
      late Queryable hangingQueryable;
      late List<Query> heldQueries;

      setUp(() async {
        heldQueries = [];
        hangingQueryable = sessionA.declareQueryable(
          'zenoh/dart/test/q/customto',
        );
        // Receive and hold: never reply, never dispose.
        hangingQueryable.stream.listen(heldQueries.add);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      tearDown(() {
        for (final query in heldQueries) {
          query.dispose();
        }
        hangingQueryable.close();
      });

      // Run one get against the hanging queryable and report what happened.
      Future<(Duration, List<Reply>)> getUnderTimeout(Duration timeout) async {
        final stopwatch = Stopwatch()..start();
        final replies = await sessionB
            .get('zenoh/dart/test/q/customto', timeout: timeout)
            .toList();
        stopwatch.stop();
        return (stopwatch.elapsed, replies);
      }

      test('the query runs out its clock and reports Timeout', () async {
        final (elapsed, replies) = await getUnderTimeout(
          const Duration(seconds: 2),
        );

        // The marker that cannot exist unless the timeout fired.
        expect(replies, hasLength(1));
        expect(replies.single.isOk, isFalse);
        expect(replies.single.error.payload, contains('Timeout'));

        // And it waited for it: the 0 ms return the old test accepted is now
        // out of range in both directions.
        expect(elapsed.inMilliseconds, greaterThan(1500));
        expect(elapsed.inMilliseconds, lessThan(5000));
      });

      test('a longer timeout waits measurably longer', () async {
        // The discriminating leg. A single timeout value cannot distinguish
        // "the requested duration reached zenoh" from "some fixed timeout
        // exists"; two values that must order correctly can.
        final (short, _) = await getUnderTimeout(const Duration(seconds: 2));
        final (long, _) = await getUnderTimeout(const Duration(seconds: 4));

        expect(short.inMilliseconds, greaterThan(1500));
        expect(short.inMilliseconds, lessThan(3000));
        expect(long.inMilliseconds, greaterThan(3500));
        expect(long.inMilliseconds, lessThan(6000));
        expect(long.inMilliseconds, greaterThan(short.inMilliseconds + 1000));
      });
    });

    // The honest form of what the replaced test actually measured, kept
    // because it is a real property worth pinning: an unmatched get does not
    // wait for its timeout, it finalizes at once.
    test('a get with no matching queryable finalizes immediately', () async {
      final stopwatch = Stopwatch()..start();

      final replies = await sessionB
          .get(
            'zenoh/dart/test/q/nobody-home',
            timeout: const Duration(seconds: 10),
          )
          .toList();

      stopwatch.stop();

      expect(replies, isEmpty);
      // Far below the 10 s timeout it was given -- so this is the
      // no-queryable fast path, not a timeout.
      expect(stopwatch.elapsed.inMilliseconds, lessThan(1000));
    });

    test('queryable with complete=true receives queries', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/complete',
        complete: true,
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/complete', 'complete-reply')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/complete').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('complete-reply'));
    });
  });
}
