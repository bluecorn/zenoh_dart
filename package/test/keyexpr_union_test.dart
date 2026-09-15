// The `String | KeyExpr` union across the op surface.
//
// Every key expression parameter is typed `Object` and runtime-dispatched, so
// one method per operation serves both arms. The analyzer no longer checks the
// argument, and that cost is pinned rather than hoped away: each family
// carries a wrong-type leg asserting an ArgumentError that names the parameter
// and both accepted types, thrown before any native allocation and before any
// move.
//
// The `String` arm's behaviour is unchanged by construction -- `String` is an
// `Object` -- and the existing per-feature suites are the control for that.
import 'dart:async';
// `hide Encoding`: dart:convert exports an abstract Encoding that shadows
// zenoh's. Only utf8 is wanted from here.
import 'dart:convert' hide Encoding;

import 'package:test/test.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/consolidation_mode.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/query_target.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart';

import 'helpers/poll.dart';

Future<Session> _quietSession() {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  return Session.open(config: config);
}

/// Matches the union's wrong-type rejection: named parameter, both types.
Matcher throwsUnionArgumentError(String paramName) => throwsA(
  isA<ArgumentError>()
      .having((e) => e.name, 'name', paramName)
      .having(
        (e) => e.message.toString(),
        'message',
        allOf(contains('String'), contains('KeyExpr')),
      ),
);

void main() {
  group('union -- push family', () {
    late Session sessionA;
    late Session sessionB;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19030"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionA = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19030"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionB = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      sessionA.close();
      sessionB.close();
    });

    test(
      'a declared key expression publishes identically to its string form',
      () async {
        final received = <Sample>[];
        final subscriber = sessionB.declareSubscriber('zenoh/dart/f5/push/**');
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final declared = sessionA.declareKeyExpr('zenoh/dart/f5/push/a');
        sessionA
          ..put(declared, 'payload')
          ..put('zenoh/dart/f5/push/a', 'payload');

        await waitUntil(
          () => received.length >= 2,
          description: 'both the declared-handle and string-form samples',
        );
        expect(received[0].keyExpr, equals(received[1].keyExpr));
        expect(received[0].payload, equals(received[1].payload));
        expect(received[0].keyExpr, equals('zenoh/dart/f5/push/a'));

        sessionA.undeclareKeyExpr(declared);
      },
    );

    test('every push entry point accepts both arms', () async {
      final received = <Sample>[];
      final subscriber = sessionB.declareSubscriber('zenoh/dart/f5/every/**');
      final sub = subscriber.stream.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        subscriber.close();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final declared = sessionA.declareKeyExpr('zenoh/dart/f5/every/a');

      sessionA
        ..put(declared, 'put')
        ..putBytes(declared, ZBytes.fromString('putBytes'));

      final publisher = sessionA.declarePublisher(declared);
      addTearDown(publisher.close);
      publisher.put('publisher');

      sessionA.deleteResource(declared);

      await waitUntil(
        () => received.length >= 4,
        description: 'put, putBytes, publisher.put and delete',
      );
      expect(
        received.map((s) => s.keyExpr).toSet(),
        equals(<String>{'zenoh/dart/f5/every/a'}),
      );
      expect(
        received.where((s) => s.kind == SampleKind.delete).length,
        equals(1),
      );

      sessionA.undeclareKeyExpr(declared);
    });

    test('a KeyExpr argument survives the call', () {
      final ke = KeyExpr('zenoh/dart/f5/survive');
      sessionA.put(ke, 'first');

      // Only a temp built from a String argument is disposed by the callee.
      expect(ke.value, equals('zenoh/dart/f5/survive'));
      expect(() => sessionA.put(ke, 'second'), returnsNormally);

      ke.dispose();
    });

    test(
      'a space-carrying key expression survives a full delivery round-trip '
      'byte-exact',
      () async {
        // Criterion E's delivery column, driven with the widest domain member
        // that survives the whole path in this zenoh version.
        //
        // Two members are deliberately NOT used here, each for a measured
        // reason:
        //   * interior NUL -- this leg predates PR #89, which made every
        //     receive surface length-carried; the truncation it was written
        //     around is gone, and `keyexpr_receive_fidelity_test.dart` now
        //     drives the NUL through delivery. Left as-is because a space is
        //     still the right vector for what THIS leg is about.
        //   * non-ASCII -- see the skipped leg below: it aborts the process
        //     inside zenoh's routing layer.
        // A space is in the contract's domain (the grammar forbids only `//`,
        // an edge `/`, and `?#$`) and is not a character any ASCII-shaped
        // assumption downstream would survive by luck.
        const expr = 'zenoh/dart/f5/uni/a b/c';
        final received = <Sample>[];
        final subscriber = sessionB.declareSubscriber(expr);
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final declared = sessionA.declareKeyExpr(expr);
        sessionA
          ..put(expr, 'as-string')
          ..put(declared, 'as-declared');

        await waitUntil(
          () => received.length >= 2,
          description: 'both the string and declared publications',
        );
        for (final sample in received) {
          expect(
            utf8.encode(sample.keyExpr),
            equals(utf8.encode(expr)),
            reason: 'received keyExpr was not byte-identical to the source',
          );
        }

        sessionA.undeclareKeyExpr(declared);
      },
    );

    test(
      'a non-ASCII key expression survives a full delivery round-trip '
      'byte-exact',
      () async {
        const expr = 'デモ/例/テスト';
        final received = <Sample>[];
        final subscriber = sessionB.declareSubscriber(expr);
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        sessionA.put(expr, 'as-string');

        await waitUntil(
          () => received.isNotEmpty,
          description: 'the non-ASCII publication',
        );
        expect(utf8.encode(received.single.keyExpr), equals(utf8.encode(expr)));
      },
      // ⚠️ DO NOT UN-SKIP without checking upstream first: this does not fail,
      // it ABORTS THE PROCESS and takes the rest of the suite with it.
      //
      // Measured (2026-08-17): every session-level operation on a non-ASCII
      // key expression panics in zenoh 1.8.0's routing layer --
      //
      //   zenoh/src/net/routing/dispatcher/resource.rs:574
      //   byte index 1 is not a char boundary; it is inside 'デ'
      //   (bytes 0..3) of `デモ/例/テスト`
      //
      // -- for put, declareSubscriber AND declareKeyExpr, on a single local
      // session as well as over TCP. Reproduced on `main` at d358682 before
      // any of this seed's commits, so it is upstream and pre-existing, not
      // ours. The keyexpr layer itself is clean: construction, value, concat,
      // join, clone and the relations triad all round-trip CJK, accented Latin
      // and emoji byte-exact (keyexpr_test.dart's domain leg), so the defect is
      // strictly in zenoh's resource/routing code slicing a key expression by
      // byte index.
      skip:
          'zenoh 1.8.0 panics on non-ASCII key expressions in the routing '
          'layer (resource.rs:574) -- upstream, reproduced on main; aborts '
          'the process rather than failing',
    );

    test(
      'a handle declared on one session works in an operation driven from '
      'another',
      () async {
        // The runtime pin for the ship-no-guard disposition: canon neither
        // documents nor tests cross-session use, so without this leg a future
        // canon change would invalidate the decision silently. The string
        // control is required -- a test where nothing is delivered would pass
        // the "no misrouting" claim vacuously.
        final received = <Sample>[];
        final subscriber = sessionA.declareSubscriber('zenoh/dart/f5/xs/**');
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final declaredOnA = sessionA.declareKeyExpr('zenoh/dart/f5/xs/a');

        sessionB
          ..put('zenoh/dart/f5/xs/a', 'control')
          ..put(declaredOnA, 'foreign');

        await waitUntil(
          () => received.length >= 2,
          description: 'the control and the foreign-session publication',
        );
        expect(
          received.map((s) => s.keyExpr).toSet(),
          equals(<String>{'zenoh/dart/f5/xs/a'}),
        );
        expect(
          received.map((s) => s.payload).toSet(),
          equals(<String>{'control', 'foreign'}),
        );

        sessionA.undeclareKeyExpr(declaredOnA);
      },
    );
  });

  group('union -- subscriber family', () {
    late Session sessionA;
    late Session sessionB;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19040"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionA = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19040"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionB = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      sessionA.close();
      sessionB.close();
    });

    test('a declared key expression drives a subscriber round-trip', () async {
      final declared = sessionB.declareKeyExpr('zenoh/dart/f5/sub/a');
      final subscriber = sessionB.declareSubscriber(declared);
      addTearDown(subscriber.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      sessionA.put('zenoh/dart/f5/sub/a', 'hello');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(sample.keyExpr, equals('zenoh/dart/f5/sub/a'));
      expect(sample.payload, equals('hello'));

      sessionB.undeclareKeyExpr(declared);
    });

    test('the background subscriber accepts both arms', () async {
      final declared = sessionB.declareKeyExpr('zenoh/dart/f5/bg/a');
      final fromKe = sessionB.declareBackgroundSubscriber(declared);
      final fromString = sessionB.declareBackgroundSubscriber(
        'zenoh/dart/f5/bg/a',
      );
      final seenKe = <Sample>[];
      final seenString = <Sample>[];
      final s1 = fromKe.listen(seenKe.add);
      final s2 = fromString.listen(seenString.add);
      addTearDown(() async {
        await s1.cancel();
        await s2.cancel();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      sessionA.put('zenoh/dart/f5/bg/a', 'both');

      await waitUntil(
        () => seenKe.isNotEmpty && seenString.isNotEmpty,
        description: 'both background subscribers to deliver',
      );
      expect(seenKe.first.payload, equals(seenString.first.payload));

      sessionB.undeclareKeyExpr(declared);
    });

    test(
      'the pull subscriber accepts both arms and keeps its string getter',
      () async {
        final declared = sessionB.declareKeyExpr('zenoh/dart/f5/pull/a');
        final puller = sessionB.declarePullSubscriber(declared);
        addTearDown(puller.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        sessionA.put('zenoh/dart/f5/pull/a', 'pulled');

        final sample = await pollRecv(puller);
        expect(sample, isNotNull);
        expect(sample!.payload, equals('pulled'));
        // The getter's type is unchanged.
        expect(puller.keyExpr, equals('zenoh/dart/f5/pull/a'));

        sessionB.undeclareKeyExpr(declared);
      },
    );
  });

  group('union -- queryable and get family', () {
    late Session server;
    late Session client;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19050"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      server = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19050"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      client = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      server.close();
      client.close();
    });

    test('a declared key expression serves a queryable', () async {
      final declared = server.declareKeyExpr('zenoh/dart/f5/q/a');
      final queryable = server.declareQueryable(declared);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/f5/q/a', 'served')
          ..dispose();
      });
      // The getter's type is unchanged.
      expect(queryable.keyExpr, equals('zenoh/dart/f5/q/a'));
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await client
          .get('zenoh/dart/f5/q/a', timeout: const Duration(seconds: 3))
          .toList();
      expect(replies, hasLength(1));
      expect(replies.single.ok.payload, equals('served'));

      server.undeclareKeyExpr(declared);
    });

    test('get accepts a declared selector', () async {
      final queryable = server.declareQueryable('zenoh/dart/f5/q/b');
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/f5/q/b', 'served-b')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final declared = client.declareKeyExpr('zenoh/dart/f5/q/b');
      final replies = await client
          .get(declared, timeout: const Duration(seconds: 3))
          .toList();
      expect(replies, hasLength(1));
      expect(replies.single.ok.payload, equals('served-b'));

      client.undeclareKeyExpr(declared);
    });

    test('the background queryable accepts both arms', () async {
      final declared = server.declareKeyExpr('zenoh/dart/f5/q/c');
      server.declareBackgroundQueryable(declared).listen((query) {
        query
          ..reply('zenoh/dart/f5/q/c', 'served-c')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await client
          .get('zenoh/dart/f5/q/c', timeout: const Duration(seconds: 3))
          .toList();
      expect(replies, hasLength(1));
      expect(replies.single.ok.payload, equals('served-c'));

      server.undeclareKeyExpr(declared);
    });
  });

  // The reply trio.
  //
  // ⚠️ The validation collapse -- one reply() used to validate the same string
  // three times (in reply, in replyBytes, and again in the shim) and now
  // validates it once -- has NO behavioural discriminator. Validating a string
  // three times and validating it once produce identical observable behaviour,
  // so no Given/When/Then can separate them, and the address-counting
  // instrument cannot either: three sequential temps that each free before the
  // next reuse the same address, so both cases read as one distinct address.
  // The evidence for that leg is structural -- Query.reply no longer
  // constructing a throwaway KeyExpr, which is greppable -- plus these tests
  // and the reply suites staying green.
  group('union -- reply trio', () {
    late Session server;
    late Session client;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19060"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      server = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19060"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      client = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      server.close();
      client.close();
    });

    test('a reply sent with a declared key expression is received', () async {
      final declared = server.declareKeyExpr('zenoh/dart/f5/reply/a');
      final queryable = server.declareQueryable('zenoh/dart/f5/reply/a');
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(declared, 'declared-reply')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await client
          .get('zenoh/dart/f5/reply/a', timeout: const Duration(seconds: 3))
          .toList();
      expect(replies, hasLength(1));
      expect(replies.single.ok.keyExpr, equals('zenoh/dart/f5/reply/a'));
      expect(replies.single.ok.payload, equals('declared-reply'));

      server.undeclareKeyExpr(declared);
    });

    test('all three reply methods accept both arms', () async {
      final declared = server.declareKeyExpr('zenoh/dart/f5/reply/b');
      final queryable = server.declareQueryable('zenoh/dart/f5/reply/b');
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(declared, 'r1')
          ..replyBytes(declared, ZBytes.fromString('r2'))
          ..replyDel(declared)
          ..dispose();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await client
          .get(
            'zenoh/dart/f5/reply/b',
            // Three replies land on ONE key expression, which `auto`
            // deduplicates down to one -- correctly. `none` is what lets this
            // test see all three.
            consolidation: ConsolidationMode.none,
            timeout: const Duration(seconds: 3),
          )
          .toList();
      expect(replies, hasLength(3));
      expect(
        replies.where((r) => r.ok.kind == SampleKind.delete).length,
        equals(1),
      );
      expect(
        replies.map((r) => r.ok.payload).toSet(),
        containsAll(<String>['r1', 'r2']),
      );

      server.undeclareKeyExpr(declared);
    });

    test('the reply guards fire in the documented order', () async {
      final queryable = server.declareQueryable('zenoh/dart/f5/reply/c');
      addTearDown(queryable.close);

      final checked = Completer<void>();
      queryable.stream.listen((query) {
        // An invalid key expression string throws pre-move: the payload is
        // still the caller's afterwards.
        final p1 = ZBytes.fromString('untouched');
        expect(
          () => query.replyBytes('demo//x', p1),
          throwsA(
            isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
          ),
        );
        expect(p1.clone, returnsNormally);
        p1.dispose();

        // A wrong-typed key expression is an ArgumentError, also pre-move.
        final p2 = ZBytes.fromString('untouched');
        expect(
          () => query.replyBytes(42, p2),
          throwsUnionArgumentError('keyExpr'),
        );
        expect(p2.clone, returnsNormally);
        p2.dispose();

        // The query guard runs FIRST: a disposed query wins over an invalid
        // key expression.
        query.dispose();
        final p3 = ZBytes.fromString('untouched');
        expect(() => query.replyBytes('demo//x', p3), throwsStateError);
        p3.dispose();

        checked.complete();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      await client
          .get('zenoh/dart/f5/reply/c', timeout: const Duration(seconds: 3))
          .toList();
      await checked.future.timeout(const Duration(seconds: 5));
    });
  });

  group('union -- querier', () {
    late Session server;
    late Session client;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19070"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      server = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19070"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      client = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      server.close();
      client.close();
    });

    test(
      'a querier declared with a declared key expression queries normally, '
      'with its declaration-time options intact',
      () async {
        final queryable = server.declareQueryable('zenoh/dart/f5/qr/a');
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          query
            ..reply('zenoh/dart/f5/qr/a', 'qr')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final declared = client.declareKeyExpr('zenoh/dart/f5/qr/a');
        final querier = client.declareQuerier(
          declared,
          target: QueryTarget.all,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 3),
        );
        addTearDown(querier.close);

        // The getter's type is unchanged.
        expect(querier.keyExpr, equals('zenoh/dart/f5/qr/a'));

        final first = await querier.get().toList();
        final second = await querier.get().toList();
        expect(first, hasLength(1));
        expect(second, hasLength(1));
        expect(first.single.ok.payload, equals('qr'));
        expect(second.single.ok.payload, equals('qr'));

        client.undeclareKeyExpr(declared);
      },
    );
  });

  group('union -- querier rejections', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('an invalid string is rejected before the querier slot', () {
      expect(
        () => session.declareQuerier('demo/x/'),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
        ),
      );
    });

    test('a wrong-typed argument is an ArgumentError', () {
      expect(
        () => session.declareQuerier(3.5),
        throwsUnionArgumentError('keyExpr'),
      );
    });
  });

  group('union -- liveliness family', () {
    late Session watcher;
    late Session announcer;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19080"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      watcher = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19080"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      announcer = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      watcher.close();
      announcer.close();
    });

    test(
      'a token declared with a declared key expression is observed, and '
      'both subscriber arms see it',
      () async {
        final pattern = watcher.declareKeyExpr('zenoh/dart/f5/live/**');
        final subscriber = watcher.declareLivelinessSubscriber(pattern);
        addTearDown(subscriber.close);
        final seen = <Sample>[];
        final s1 = subscriber.stream.listen(seen.add);

        final bgSeen = <Sample>[];
        final s2 = watcher
            .declareBackgroundLivelinessSubscriber(pattern)
            .listen(bgSeen.add);
        addTearDown(() async {
          await s1.cancel();
          await s2.cancel();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final tokenKe = announcer.declareKeyExpr('zenoh/dart/f5/live/a');
        final token = announcer.declareLivelinessToken(tokenKe);
        // The getter's type is unchanged.
        expect(token.keyExpr, equals('zenoh/dart/f5/live/a'));

        await waitUntil(
          () => seen.isNotEmpty && bgSeen.isNotEmpty,
          description: 'the token appearance on both subscribers',
        );
        expect(seen.first.keyExpr, equals('zenoh/dart/f5/live/a'));
        expect(seen.first.kind, equals(SampleKind.put));

        // livelinessGet accepts both arms too.
        final alive = await watcher
            .livelinessGet(pattern, timeout: const Duration(seconds: 3))
            .toList();
        expect(alive, hasLength(1));
        expect(alive.single.ok.keyExpr, equals('zenoh/dart/f5/live/a'));

        token.close();
        await waitUntil(
          () => seen.any((s) => s.kind == SampleKind.delete),
          description: 'the DELETE on token close',
        );

        announcer.undeclareKeyExpr(tokenKe);
        watcher.undeclareKeyExpr(pattern);
      },
    );
  });

  group('union -- liveliness family rejections', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('an invalid string is rejected without leaking the channel', () {
      // An open ReceivePort would pin the isolate alive; this file
      // terminating at all is part of the assertion.
      expect(
        () => session.livelinessGet(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('a wrong-typed argument is an ArgumentError', () {
      expect(
        () => session.declareLivelinessToken(<int>[1, 2]),
        throwsUnionArgumentError('keyExpr'),
      );
      expect(
        () => session.declareLivelinessSubscriber(<int>[1, 2]),
        throwsUnionArgumentError('keyExpr'),
      );
      expect(
        () => session.declareBackgroundLivelinessSubscriber(<int>[1, 2]),
        throwsUnionArgumentError('keyExpr'),
      );
      expect(
        () => session.livelinessGet(<int>[1, 2]),
        throwsUnionArgumentError('keyExpr'),
      );
    });
  });

  group('union -- queryable and get family rejections', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('an invalid selector throws before the payload is moved', () {
      final payload = ZBytes.fromString('untouched');
      expect(
        () => session.get('demo//x', payload: payload),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
        ),
      );
      expect(payload.clone, returnsNormally);
      payload.dispose();
    });

    test('a wrong-typed selector leaves no open ReceivePort', () {
      // The reply channel is created inside the dispatch, so the throw
      // precedes it. An open ReceivePort would pin the isolate alive; this
      // test file terminating at all is part of the assertion.
      expect(() => session.get(42), throwsUnionArgumentError('selector'));
      expect(
        () => session.declareQueryable(42),
        throwsUnionArgumentError('keyExpr'),
      );
      expect(
        () => session.declareBackgroundQueryable(42),
        throwsUnionArgumentError('keyExpr'),
      );
    });
  });

  group('union -- subscriber family rejections', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('an invalid string is rejected in Dart, not in the shim', () {
      // Validation moved out of the shim into the union dispatch's temp
      // KeyExpr, and throws the same exception with canon's own code. Nothing
      // downstream of it is allocated, so no channel or ring buffer is
      // stranded -- an open ReceivePort would keep this isolate alive.
      expect(
        () => session.declareBackgroundSubscriber('demo//x'),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
        ),
      );
      expect(
        () => session.declarePullSubscriber('demo//x'),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
        ),
      );
    });

    test('a wrong-typed argument is an ArgumentError', () {
      expect(
        () => session.declarePullSubscriber(42),
        throwsUnionArgumentError('keyExpr'),
      );
      expect(
        () => session.declareBackgroundSubscriber(42),
        throwsUnionArgumentError('keyExpr'),
      );
    });
  });

  group('union -- push family rejections', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('a wrong-typed argument fails loudly and early', () {
      // `null` is deliberately absent from this list: the parameter is a
      // non-nullable `Object`, so null is rejected at COMPILE time rather than
      // reaching this guard -- a stronger result than the ArgumentError, and
      // one no runtime test can express.
      for (final bad in <Object>[
        42,
        <String>['a', 'b'],
        3.5,
      ]) {
        final payload = ZBytes.fromString('untouched');
        expect(
          () => session.putBytes(bad, payload),
          throwsUnionArgumentError('keyExpr'),
        );
        // The throw preceded every native allocation and every move: a
        // consumed payload would throw StateError from clone().
        expect(payload.clone, returnsNormally);
        payload.dispose();
      }
    });

    test('an invalid string still throws exactly as before', () {
      final payload = ZBytes.fromString('untouched');
      expect(
        () => session.putBytes('demo//x', payload),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
        ),
      );
      // The pre-move guard discipline is unchanged.
      expect(payload.clone, returnsNormally);
      payload.dispose();
    });

    test('a disposed KeyExpr argument is rejected', () {
      final dead = KeyExpr('zenoh/dart/f5/dead')..dispose();
      expect(() => session.deleteResource(dead), throwsStateError);
    });
  });
}
