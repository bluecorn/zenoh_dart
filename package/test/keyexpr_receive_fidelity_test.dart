// Receive-side key expression fidelity.
//
// Since the declared-key-expression seed, the SEND side carries the full key
// expression domain byte-exact: construction, declaration, composition and the
// wire all preserve an interior NUL. This file measures the other half of the
// round trip -- the postings that carry a key expression from the C shim back
// into Dart:
//
//   1. the sample callback          -> Sample.keyExpr (subscriber, background,
//                                      liveliness, advanced -- one shared
//                                      Dart parse in subscriber.dart)
//   2. the query callback           -> Query.keyExpr at a queryable
//   3. the reply callback           -> reply sample keyExpr, parsed at TWO
//                                      independent Dart sites (session.dart's
//                                      get channel and querier.dart's own)
//   4. zd_pull_subscriber_try_recv  -> PullSubscriber.tryRecv().keyExpr
//
// Every assertion compares Uint8List, never String: a `String ==` cannot tell
// a value truncated at the NUL from a carried one when the truncated prefix is
// itself a valid string. Each leg asserts arrival BEFORE byte-exactness, so a
// routing failure presents as "nothing arrived" rather than masquerading as a
// fidelity failure.
//
// The ASCII controls in each group prove the leg's own plumbing: they use the
// same publish/query/reply path with no NUL, so a leg that goes red on the NUL
// case while its control is green is measuring the posting, not the transport.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/poll.dart';

/// The interior NUL, built rather than escaped so no raw NUL byte reaches this
/// file (a raw NUL makes `grep` treat the whole file as binary and silently
/// suppress every match in it).
final String nul = String.fromCharCode(0);

/// A session that cannot discover anything on the LAN: the local legs below
/// assert about this process only, so inherited discovery would make a green
/// ambiguous.
Future<Session> _quietSession({bool timestamping = false}) {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (timestamping) {
    config.insertJson5('timestamping/enabled', 'true');
  }
  return Session.open(config: config);
}

void main() {
  // ---------------------------------------------------------------------
  // 1. The sample callback -- one C posting, one shared Dart parse
  //    (Subscriber.createSampleChannel), four declaration surfaces.
  // ---------------------------------------------------------------------
  group('Sample.keyExpr fidelity', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('a subscriber receives an interior NUL byte-exact', () async {
      final expr = 'zenoh/dart/recv/sub/a${nul}b';
      final received = <Sample>[];
      final subscriber = session.declareSubscriber(expr);
      final sub = subscriber.stream.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        subscriber.close();
      });

      session.put(expr, 'payload');
      await waitUntil(
        () => received.isNotEmpty,
        description: 'a sample on the NUL-carrying key expression',
      );

      expect(
        utf8.encode(received.single.keyExpr),
        equals(utf8.encode(expr)),
        reason: 'the key expression must survive the posting byte-exact',
      );
    });

    test(
      'a background subscriber receives an interior NUL byte-exact',
      () async {
        final expr = 'zenoh/dart/recv/bg/a${nul}b';
        final received = <Sample>[];
        final sub = session
            .declareBackgroundSubscriber(expr)
            .listen(received.add);
        addTearDown(sub.cancel);

        session.put(expr, 'payload');
        await waitUntil(
          () => received.isNotEmpty,
          description: 'a background sample on the NUL-carrying key expression',
        );

        expect(utf8.encode(received.single.keyExpr), equals(utf8.encode(expr)));
      },
    );

    test('an ASCII key expression is unchanged (control)', () async {
      const expr = 'zenoh/dart/recv/sub/ascii';
      final received = <Sample>[];
      final subscriber = session.declareSubscriber(expr);
      final sub = subscriber.stream.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        subscriber.close();
      });

      session.put(expr, 'payload');
      await waitUntil(
        () => received.isNotEmpty,
        description: 'a sample on the ASCII key expression',
      );

      expect(utf8.encode(received.single.keyExpr), equals(utf8.encode(expr)));
    });
  });

  // ---------------------------------------------------------------------
  // 4. zd_pull_subscriber_try_recv -- the one synchronous receive surface,
  //    which hands its key expression over as a malloc'd out-parameter.
  // ---------------------------------------------------------------------
  group('PullSubscriber.tryRecv key expression fidelity', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('tryRecv reports an interior NUL byte-exact', () async {
      final expr = 'zenoh/dart/recv/pull/a${nul}b';
      final pull = session.declarePullSubscriber(expr);
      addTearDown(pull.close);

      session.put(expr, 'payload');
      final sample = await pollRecv(pull);

      expect(sample, isNotNull, reason: 'the ring must deliver one sample');
      expect(utf8.encode(sample!.keyExpr), equals(utf8.encode(expr)));
    });

    test('tryRecv reports an interior NUL byte-exact through a FIFO', () async {
      // The same length-carried extraction, driven through the OTHER channel
      // kind. Both kinds share one extraction body, so this is structurally
      // the same code the ring cell above covers -- and driven anyway,
      // because "structurally the same" is an argument and this is a
      // measurement.
      //
      // Same-session is legal HERE and the reasoning is not skipped: the
      // two-session MUST governs cells that can FILL a fifo, and a capacity-8
      // channel receiving one sample cannot.
      final expr = 'zenoh/dart/recv/pull/fifo/a${nul}b';
      final pull = session.declarePullSubscriber(
        expr,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);

      session.put(expr, 'payload');
      final sample = await pollRecv(pull);

      expect(sample, isNotNull, reason: 'the fifo must deliver one sample');
      expect(utf8.encode(sample!.keyExpr), equals(utf8.encode(expr)));
    });

    test('an ASCII key expression is unchanged (control)', () async {
      const expr = 'zenoh/dart/recv/pull/ascii';
      final pull = session.declarePullSubscriber(expr);
      addTearDown(pull.close);

      session.put(expr, 'payload');
      final sample = await pollRecv(pull);

      expect(sample, isNotNull);
      expect(utf8.encode(sample!.keyExpr), equals(utf8.encode(expr)));
    });
  });

  // ---------------------------------------------------------------------
  // 2 + 3. The query and reply callbacks. Two sessions over TCP so the query
  //        and its replies genuinely cross the wire, mirroring the shape the
  //        replier-id suite uses.
  // ---------------------------------------------------------------------
  group('Query and Reply key expression fidelity (TCP 19110)', () {
    late Session sGet;
    late Session sQbl;

    setUpAll(() async {
      sQbl = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19110"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sGet = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19110"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDownAll(() {
      sGet.close();
      sQbl.close();
    });

    test('Query.keyExpr carries an interior NUL byte-exact', () async {
      final expr = 'zenoh/dart/recv/qbl/a${nul}b';
      final seen = Completer<String>();
      final queryable = sQbl.declareQueryable(expr);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        if (!seen.isCompleted) seen.complete(query.keyExpr);
        query
          ..reply(expr, 'answer')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sGet.get(expr, timeout: const Duration(seconds: 5)).toList();

      final observed = await seen.future.timeout(const Duration(seconds: 5));
      expect(utf8.encode(observed), equals(utf8.encode(expr)));
    });

    test('a reply sample carries an interior NUL byte-exact', () async {
      final expr = 'zenoh/dart/recv/reply/a${nul}b';
      final queryable = sQbl.declareQueryable(expr);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(expr, 'answer')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sGet
          .get(expr, timeout: const Duration(seconds: 5))
          .toList();

      expect(replies, isNotEmpty, reason: 'the queryable must answer');
      final ok = replies.firstWhere((r) => r.isOk);
      expect(utf8.encode(ok.ok.keyExpr), equals(utf8.encode(expr)));
    });

    test('the Querier parse site carries an interior NUL too', () async {
      // querier.dart parses the reply posting independently of
      // session.dart's get channel, so it needs its own leg.
      final expr = 'zenoh/dart/recv/querier/a${nul}b';
      final queryable = sQbl.declareQueryable(expr);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(expr, 'answer')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sGet.declareQuerier(
        expr,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList();

      expect(replies, isNotEmpty, reason: 'the queryable must answer');
      final ok = replies.firstWhere((r) => r.isOk);
      expect(utf8.encode(ok.ok.keyExpr), equals(utf8.encode(expr)));
    });

    test('an ASCII query and reply are unchanged (control)', () async {
      const expr = 'zenoh/dart/recv/qbl/ascii';
      final seen = Completer<String>();
      final queryable = sQbl.declareQueryable(expr);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        if (!seen.isCompleted) seen.complete(query.keyExpr);
        query
          ..reply(expr, 'answer')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sGet
          .get(expr, timeout: const Duration(seconds: 5))
          .toList();

      expect(replies, isNotEmpty);
      expect(
        utf8.encode(replies.firstWhere((r) => r.isOk).ok.keyExpr),
        equals(utf8.encode(expr)),
      );
      final observed = await seen.future.timeout(const Duration(seconds: 5));
      expect(utf8.encode(observed), equals(utf8.encode(expr)));
    });
  });

  // ---------------------------------------------------------------------
  // The advanced subscriber rides the same sample callback as the plain one.
  // One leg proves the shared posting reaches that surface too.
  // ---------------------------------------------------------------------
  group(
    'AdvancedSubscriber key expression fidelity',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session;

      setUpAll(() async {
        session = await _quietSession(timestamping: true);
      });

      tearDownAll(() {
        session.close();
      });

      test(
        'an advanced subscriber receives an interior NUL byte-exact',
        () async {
          final expr = 'zenoh/dart/recv/adv/a${nul}b';
          final received = <Sample>[];
          final subscriber = session.declareAdvancedSubscriber(expr);
          final sub = subscriber.stream.listen(received.add);
          addTearDown(() async {
            await sub.cancel();
            subscriber.close();
          });

          session.put(expr, 'payload');
          await waitUntil(
            () => received.isNotEmpty,
            description:
                'an advanced sample on the NUL-carrying key expression',
          );

          expect(
            utf8.encode(received.first.keyExpr),
            equals(utf8.encode(expr)),
          );
        },
      );
    },
  );
}
