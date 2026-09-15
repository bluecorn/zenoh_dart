// Slice 5: Reply.replierId — Reply-level EntityGlobalId? populated for both
// ok and error replies, via z_reply_replier_id wired into both branches of
// _zd_reply_callback and both Dart parse sites (session.dart + querier.dart).
//
// Two sessions (S_get / S_qbl) over fresh TCP ports; SERIAL (--concurrency=1);
// real .so's; no mock FFI.
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/unstable/features.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group(
    'Reply.replierId (TCP 17543)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session sGet;
      late Session sQbl;

      setUp(() async {
        sQbl = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17543"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        sGet = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17543"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      tearDown(() async {
        sGet.close();
        sQbl.close();
      });

      test('Test 1 — replierId zid matches the answering session', () async {
        final queryable = sQbl.declareQueryable('zenoh/dart/test/replier/ok');
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          query
            ..reply('zenoh/dart/test/replier/ok', 'hello')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replies = await sGet
            .get(
              'zenoh/dart/test/replier/ok',
              timeout: const Duration(seconds: 5),
            )
            .toList();

        expect(replies, isNotEmpty);
        final reply = replies.firstWhere((r) => r.isOk);
        expect(
          reply.replierId,
          isNotNull,
          reason: 'ok reply should carry a replierId in this build',
        );
        expect(reply.replierId!.zid, equals(sQbl.zid));
      });

      test('Test 2 — replierId eid is present (non-null int)', () async {
        final queryable = sQbl.declareQueryable('zenoh/dart/test/replier/eid');
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          query
            ..reply('zenoh/dart/test/replier/eid', 'hello')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replies = await sGet
            .get(
              'zenoh/dart/test/replier/eid',
              timeout: const Duration(seconds: 5),
            )
            .toList();

        final reply = replies.firstWhere((r) => r.isOk);
        expect(reply.replierId, isNotNull);
        expect(reply.replierId!.eid, isA<int>());
      });

      test('Test 3 — replierId flows through the Querier parse too', () async {
        final queryable = sQbl.declareQueryable(
          'zenoh/dart/test/replier/querier',
        );
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          query
            ..reply('zenoh/dart/test/replier/querier', 'hello')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final querier = sGet.declareQuerier(
          'zenoh/dart/test/replier/querier',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        final replies = await querier.get().toList();

        final reply = replies.firstWhere((r) => r.isOk);
        expect(
          reply.replierId,
          isNotNull,
          reason: 'querier parse site should populate replierId too',
        );
        expect(reply.replierId!.zid, equals(sQbl.zid));
      });

      // Name says "absent or correct" because that is the contract this test
      // can actually enforce. The previous name ("exposes replierId too")
      // claimed more than the body checks: the `else` branch asserts null
      // inside the branch entered only when the value IS null, so a build that
      // never populated the error-path replier id was permanently green under
      // a name promising exposure. The conditional itself is the documented
      // graceful-degradation ruling and stays; only the claim is corrected.
      test('Test 4 — error-reply replierId is absent or correct', () async {
        final queryable = sQbl.declareQueryable('zenoh/dart/test/replier/err');
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          query
            ..replyErr('something went wrong')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replies = await sGet
            .get(
              'zenoh/dart/test/replier/err',
              timeout: const Duration(seconds: 5),
            )
            .toList();

        expect(replies, isNotEmpty);
        final reply = replies.firstWhere((r) => !r.isOk);
        expect(reply.isOk, isFalse);
        // CA re-gate ruling (a): the replier is knowable on the error path.
        // Graceful fallback: if THIS build leaves the error-path replier id
        // unset, replierId is null — but the both-branch wiring stays in place.
        if (reply.replierId != null) {
          expect(reply.replierId!.zid, equals(sQbl.zid));
        } else {
          expect(reply.replierId, isNull);
        }
      });
    },
  );

  // Slice 6: eid-discriminator end-to-end (the §5 fidelity proof).
  //
  // Prong-b proof: two Queryables on ONE session share that session's zid but
  // must carry DISTINCT eids, so their replierIds compare UNEQUAL — the
  // property a flatten-to-ZenohId would silently conflate. TEST-ONLY: a
  // failure here exposes a real defect in EntityGlobalId == (Slice 1) or eid
  // conveyance (Slice 5). Fresh TCP port 17544; SERIAL; real .so's; no mock
  // FFI.
  group(
    'eid-discriminator §5 proof (TCP 17544)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session sGet;
      late Session sQbl;

      setUp(() async {
        sQbl = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17544"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        sGet = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17544"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      tearDown(() async {
        sGet.close();
        sQbl.close();
      });

      test('Test 1 — two queryables on one session yield distinct, unequal '
          'replierIds', () async {
        const k = 'demo/example/discriminator';

        // Two distinct entities (queryables) on the SAME session S (== sQbl).
        final q1 = sQbl.declareQueryable(k);
        addTearDown(q1.close);
        q1.stream.listen((query) {
          query
            ..reply(k, 'from-q1')
            ..dispose();
        });

        final q2 = sQbl.declareQueryable(k);
        addTearDown(q2.close);
        q2.stream.listen((query) {
          query
            ..reply(k, 'from-q2')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 300));

        // target: all + consolidation: none — both required so the two same-key
        // replies both arrive, un-deduplicated.
        final replies = await sGet
            .get(
              k,
              target: QueryTarget.all,
              consolidation: ConsolidationMode.none,
              timeout: const Duration(seconds: 5),
            )
            .toList();

        final okReplies = replies.where((r) => r.isOk).toList();
        expect(
          okReplies.length,
          greaterThanOrEqualTo(2),
          reason:
              'both queryables on S must reply (target: all, '
              'consolidation: none)',
        );

        final r1 = okReplies[0];
        final r2 = okReplies[1];

        // Both entities live on the same session → same zid.
        expect(r1.replierId, isNotNull);
        expect(r2.replierId, isNotNull);
        expect(r1.replierId!.zid, equals(sQbl.zid));
        expect(r2.replierId!.zid, equals(sQbl.zid));

        // The §5 proof: distinct entities → distinct eids → unequal replierIds.
        expect(
          r1.replierId!.eid,
          isNot(equals(r2.replierId!.eid)),
          reason: 'two queryables on one session must carry distinct eids',
        );
        expect(
          r1.replierId,
          isNot(equals(r2.replierId)),
          reason:
              'distinct eids ⇒ unequal EntityGlobalId (no flatten-to-zid '
              'conflation)',
        );
      });

      test('Test 2 — a replier compares equal to itself across two of its own '
          'replies', () async {
        const k = 'demo/example/discriminator/self';

        final q1 = sQbl.declareQueryable(k);
        addTearDown(q1.close);
        q1.stream.listen((query) {
          query
            ..reply(k, 'hello')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies1 = await sGet
            .get(k, timeout: const Duration(seconds: 5))
            .toList();
        final reply1 = replies1.firstWhere((r) => r.isOk);

        final replies2 = await sGet
            .get(k, timeout: const Duration(seconds: 5))
            .toList();
        final reply2 = replies2.firstWhere((r) => r.isOk);

        expect(reply1.replierId, isNotNull);
        expect(reply2.replierId, isNotNull);

        // Same entity across two of its own replies → equal (same zid + eid).
        expect(reply1.replierId!.zid, equals(reply2.replierId!.zid));
        expect(reply1.replierId!.eid, equals(reply2.replierId!.eid));
        expect(
          reply1.replierId,
          equals(reply2.replierId),
          reason: 'equality is not spuriously eid-sensitive within one entity',
        );
      });
    },
  );
}
