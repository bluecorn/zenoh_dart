// Querier lifecycle, get, and matching status tests (slices 2-4)
// Slice 4: Querier matching status (one-shot and stream)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Querier lifecycle', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareQuerier returns a Querier instance', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(querier, isA<Querier>());
      querier.close();
    });

    test('Querier.keyExpr returns declared key expression', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(querier.keyExpr, equals('demo/example/querier'));
      querier.close();
    });

    test('Querier.close completes without error', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(querier.close, returnsNormally);
    });

    test('Querier.close is idempotent', () {
      final querier = session.declareQuerier('demo/example/querier')..close();
      expect(querier.close, returnsNormally);
    });

    test('declareQuerier on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.declareQuerier('demo/example/querier'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test(
      'declareQuerier with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareQuerier(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );

    test('declareQuerier with non-default options succeeds', () {
      final querier = session.declareQuerier(
        'demo/example/querier-opts',
        target: QueryTarget.all,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 5),
      );
      expect(querier, isA<Querier>());
      expect(querier.keyExpr, equals('demo/example/querier-opts'));
      querier.close();
    });
  });

  group('Basic Querier Get (TCP 17490)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic querier get receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/qr/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/qr/basic', 'hello from queryable')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/basic',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello from queryable'));
    });

    test(
      'querier get with parameters passes parameters to queryable',
      () async {
        final receivedParams = Completer<String>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/qr/params',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          receivedParams.complete(query.parameters);
          query
            ..reply('zenoh/dart/test/qr/params', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/params',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        await querier.get(parameters: 'key=value').toList();

        final params = await receivedParams.future.timeout(
          const Duration(seconds: 5),
        );
        expect(params, equals('key=value'));
      },
    );

    test(
      'querier get timeout with no queryable returns empty stream',
      () async {
        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/timeout',
          timeout: const Duration(seconds: 1),
        );
        addTearDown(querier.close);

        final replies = await querier.get().toList().timeout(
          const Duration(seconds: 5),
        );

        expect(replies, isEmpty);
      },
    );

    test('querier repeated gets return correct replies each time', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/qr/repeat');
      addTearDown(queryable.close);

      var queryCount = 0;
      queryable.stream.listen((query) {
        queryCount++;
        query
          ..reply('zenoh/dart/test/qr/repeat', 'reply-$queryCount')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/repeat',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      for (var i = 0; i < 3; i++) {
        final replies = await querier.get().toList();
        expect(replies, hasLength(1));
        expect(replies.first.isOk, isTrue);
      }
    });

    test(
      'querier delivers invalid-UTF-8 binary reply payload faithfully',
      () async {
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/qr/binreply',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          query
            ..replyBytes(
              'zenoh/dart/test/qr/binreply',
              ZBytes.fromUint8List(
                Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
              ),
            )
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/binreply',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        final replies = await querier.get().toList();

        expect(replies, hasLength(1));
        expect(replies.first.isOk, isTrue);
        expect(
          replies.first.ok.payloadBytes,
          equals([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );
        expect(replies.first.ok.payload, contains('\u{FFFD}'));
      },
    );

    test('querier get after close throws StateError', () {
      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/closed',
        timeout: const Duration(seconds: 5),
      )..close();

      expect(
        querier.get,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });
  });

  group('Querier Get with Payload and Encoding (TCP 17491)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17491"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17491"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test(
      'querier get with ZBytes payload delivers payload to queryable',
      () async {
        final receivedPayload = Completer<Uint8List?>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/qr/payload',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          receivedPayload.complete(query.payloadBytes);
          query
            ..reply('zenoh/dart/test/qr/payload', 'ack')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/payload',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        final payload = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
        await querier.get(payload: payload).toList();

        final received = await receivedPayload.future.timeout(
          const Duration(seconds: 5),
        );
        expect(received, isNotNull);
        expect(received, equals(Uint8List.fromList([1, 2, 3])));
      },
    );

    test('ZBytes payload is consumed after querier get', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr/consumed',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/qr/consumed', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/consumed',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final payload = ZBytes.fromUint8List(Uint8List.fromList([4, 5, 6]));
      await querier.get(payload: payload).toList();

      expect(() => payload.nativePtr, throwsA(isA<StateError>()));
    });

    test('querier get with encoding round-trips through reply', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr/encoding',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply(
            'zenoh/dart/test/qr/encoding',
            '{"status":"ok"}',
            encoding: Encoding.applicationJson,
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/encoding',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.encoding, contains('application/json'));
    });

    test('querier get with null payload sends no payload', () async {
      final receivedPayload = Completer<Uint8List?>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr/nopayload',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedPayload.complete(query.payloadBytes);
        query
          ..reply('zenoh/dart/test/qr/nopayload', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/nopayload',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier.get().toList();

      final received = await receivedPayload.future.timeout(
        const Duration(seconds: 5),
      );
      expect(received, isNull);
    });

    test('querier get with empty parameters passes empty string', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr/emptyparams',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query
          ..reply('zenoh/dart/test/qr/emptyparams', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/emptyparams',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier.get().toList();

      final params = await receivedParams.future.timeout(
        const Duration(seconds: 5),
      );
      expect(params, equals(''));
    });
  });

  group('Querier matching status one-shot (TCP 17492)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Scouting off: `hasMatchingQueryables` is a network-wide question, so
      // the false-case below is only a real negative if this session cannot
      // discover anything beyond the peer it is paired with. With multicast on
      // its green only proved the LAN was quiet.
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17492"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17492"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test(
      'hasMatchingQueryables returns false when no queryables exist',
      () async {
        final querier = session1.declareQuerier(
          'zenoh/dart/test/qrmatch/none',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        expect(querier.hasMatchingQueryables(), isFalse);
      },
    );

    test('hasMatchingQueryables returns true when queryable exists', () async {
      final queryable = session2.declareQueryable(
        'zenoh/dart/test/qrmatch/yes',
      );
      addTearDown(queryable.close);
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/yes',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      expect(querier.hasMatchingQueryables(), isTrue);
    });

    test('hasMatchingQueryables after close throws StateError', () {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/closed',
        timeout: const Duration(seconds: 5),
      )..close();
      expect(querier.hasMatchingQueryables, throwsA(isA<StateError>()));
    });
  });

  group('Querier matching status stream (TCP 17493)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17493"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17493"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('matchingStatus is null when listener not enabled', () {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/null',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);
      expect(querier.matchingStatus, isNull);
    });

    test('matchingStatus stream emits true when queryable appears', () async {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/stream',
        timeout: const Duration(seconds: 5),
        enableMatchingListener: true,
      );
      addTearDown(querier.close);

      expect(querier.matchingStatus, isNotNull);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Declare queryable to trigger matching
      final queryable = session2.declareQueryable(
        'zenoh/dart/test/qrmatch/stream',
      );
      addTearDown(queryable.close);

      final status = await querier.matchingStatus!.first.timeout(
        const Duration(seconds: 5),
      );
      expect(status, isTrue);
    });

    test(
      'matchingStatus stream emits false when queryable disappears',
      () async {
        final querier = session1.declareQuerier(
          'zenoh/dart/test/qrmatch/stream2',
          timeout: const Duration(seconds: 5),
          enableMatchingListener: true,
        );
        addTearDown(querier.close);

        final statuses = <bool>[];
        final gotFalse = Completer<void>();
        querier.matchingStatus!.listen((status) {
          statuses.add(status);
          if (!status && statuses.length > 1) {
            if (!gotFalse.isCompleted) gotFalse.complete();
          }
        });

        await Future<void>.delayed(const Duration(seconds: 1));

        final queryable = session2.declareQueryable(
          'zenoh/dart/test/qrmatch/stream2',
        );

        await Future<void>.delayed(const Duration(seconds: 1));
        queryable.close();

        await gotFalse.future.timeout(const Duration(seconds: 5));

        expect(statuses, contains(true));
        expect(statuses.last, isFalse);
      },
    );

    test('matchingStatus stream closes when querier is closed', () async {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/close',
        timeout: const Duration(seconds: 5),
        enableMatchingListener: true,
      );

      final doneCompleter = Completer<void>();
      querier.matchingStatus!.listen((_) {}, onDone: doneCompleter.complete);

      querier.close();

      await doneCompleter.future.timeout(const Duration(seconds: 5));
    });
  });

  // Slice 7: Querier.get attachment send + payload matrix + use-after-move fix.
  group('Querier Get Attachment Send (TCP 17494)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17494"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17494"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: Querier.get delivers a binary attachment to the queryable
    // byte-exact (incl. invalid-UTF-8 bytes).
    test('querier get delivers binary attachment byte-exact', () async {
      final receivedAttachment = Completer<Uint8List?>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/qr7/attach');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedAttachment.complete(query.attachmentBytes);
        query
          ..reply('zenoh/dart/test/qr7/attach', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/attach',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier
          .get(
            attachment: ZBytes.fromUint8List(
              Uint8List.fromList([0xFF, 0xFE, 0x80]),
            ),
          )
          .toList();

      final received = await receivedAttachment.future.timeout(
        const Duration(seconds: 5),
      );
      expect(received, isNotNull);
      expect(received, equals(Uint8List.fromList([0xFF, 0xFE, 0x80])));
    });

    // Test 2: Querier query payload matrix -- {valid-UTF-8, invalid-UTF-8,
    // empty, absent} each arrives byte-exact (or null for absent).
    test('querier query payload matrix delivers byte-exact', () async {
      final results = <String, Uint8List?>{};
      final completers = {
        'valid': Completer<void>(),
        'invalid': Completer<void>(),
        'empty': Completer<void>(),
        'absent': Completer<void>(),
      };

      final queryable = sessionA.declareQueryable('zenoh/dart/test/qr7/matrix');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        final params = query.parameters;
        results[params] = query.payloadBytes;
        completers[params]?.complete();
        query
          ..reply('zenoh/dart/test/qr7/matrix', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/matrix',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final validBytes = Uint8List.fromList(utf8.encode('hello'));
      final invalidBytes = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);

      await querier
          .get(parameters: 'valid', payload: ZBytes.fromUint8List(validBytes))
          .toList();
      await querier
          .get(
            parameters: 'invalid',
            payload: ZBytes.fromUint8List(invalidBytes),
          )
          .toList();
      await querier
          .get(parameters: 'empty', payload: ZBytes.fromUint8List(Uint8List(0)))
          .toList();
      await querier.get(parameters: 'absent').toList();

      await Future.wait(
        completers.values.map((c) => c.future),
      ).timeout(const Duration(seconds: 10));

      expect(results['valid'], equals(validBytes));
      expect(results['invalid'], equals(invalidBytes));
      // empty payload -> non-null empty bytes.
      expect(results['empty'], isNotNull);
      expect(results['empty'], isEmpty);
      // absent payload -> null.
      expect(results['absent'], isNull);
    });

    // Test 3 (Edge): payload + attachment consumed (use-after-move fix).
    //
    // Path driven: the SUCCESS path's UNCONDITIONAL marking. This is the
    // latent-bug fix -- the old code marked payload ONLY on success (after the
    // rc-throw) and never marked attachment at all. zenoh-c gravestones the
    // moves regardless of rc, so the only safe contract is: after Querier.get
    // returns, the caller must never touch payload/attachment again.
    //
    // We cannot reliably drive a genuine POST-move non-zero rc here:
    // z_encoding_from_str accepts any string as a custom encoding (it never
    // fails for a junk MIME in zenoh-c 1.7.2), and a valid querier + reachable
    // queryable makes z_querier_get succeed. So the post-move consumption
    // assertion is exercised on the success path.
    test(
      'querier get marks payload + attachment consumed unconditionally',
      () async {
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/qr7/consume',
        );
        addTearDown(queryable.close);
        queryable.stream.listen((q) {
          q
            ..reply('zenoh/dart/test/qr7/consume', 'ack')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr7/consume',
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);

        final payload = ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );
        final attachment = ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        );

        await querier.get(payload: payload, attachment: attachment).toList();

        // Both moved into zenoh-c (gravestoned) -- use-after-move must throw.
        expect(
          payload.toBytes,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('consumed'),
            ),
          ),
        );
        expect(
          attachment.toBytes,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('consumed'),
            ),
          ),
        );
      },
    );

    // Test 4 (Edge): empty vs absent attachment via the querier.
    test('querier empty vs absent attachment', () async {
      final results = <String, Uint8List?>{};
      final completers = {
        'empty': Completer<void>(),
        'none': Completer<void>(),
      };

      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr7/emptyattach',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        results[query.parameters] = query.attachmentBytes;
        completers[query.parameters]?.complete();
        query
          ..reply('zenoh/dart/test/qr7/emptyattach', 'ack')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/emptyattach',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier
          .get(
            parameters: 'empty',
            attachment: ZBytes.fromUint8List(Uint8List(0)),
          )
          .toList();
      await querier.get(parameters: 'none').toList();

      await Future.wait(
        completers.values.map((c) => c.future),
      ).timeout(const Duration(seconds: 10));

      // empty attachment -> non-null empty bytes.
      expect(results['empty'], isNotNull);
      expect(results['empty'], isEmpty);
      // absent attachment -> null.
      expect(results['none'], isNull);
    });
  });

  group('Slice 8: Querier receives reply-ok attachment (TCP 17495)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17495"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17495"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 2: a queryable replies with a binary attachment; a declared querier
    // receives it byte-exact on reply.ok.attachmentBytes.
    test('querier receives reply-ok binary attachment byte-exact', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q8r/attach');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..replyBytes(
            'zenoh/dart/test/q8r/attach',
            ZBytes.fromString('ok'),
            attachment: ZBytes.fromUint8List(
              Uint8List.fromList([0xFF, 0xFE, 0x80]),
            ),
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/q8r/attach',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList().timeout(
        const Duration(seconds: 5),
      );

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.attachmentBytes,
        equals(Uint8List.fromList([0xFF, 0xFE, 0x80])),
      );
    });
  });

  // Slice 4: reply-ok metadata exposure via the Querier path. The querier
  // re-implements reply parsing inline (it does not reuse Session's parser),
  // so this proves the independent querier parse site was updated too. Per N3
  // assert EXPOSURE (populated defaults, not dropped) + null timestamp on a
  // plain reply.
  group('Slice 4: Querier reply-ok metadata exposure (TCP 17534)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17534"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17534"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 2: a Querier reply-ok exposes priority/congestion/express
    // (non-null defaults) and a null timestamp on a plain reply.
    test('querier reply-ok exposes all four metadata fields', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q4r/meta');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q4r/meta', 'reply-value')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/q4r/meta',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList().timeout(
        const Duration(seconds: 5),
      );

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      final sample = replies.first.ok;
      expect(sample.payload, equals('reply-value'));
      // Values, not `isNotNull` -- see the get-side twin in
      // get_queryable_test.dart for the full reasoning. Short form: the three
      // fields are non-nullable with constructor defaults, so `isNotNull`
      // could not fail; congestionControl is the discriminating pin (a reply
      // arrives BLOCK, not the constructor's drop), while priority and express
      // are default-echo pins that catch a mis-indexed enum, not a dropped
      // field. This is what makes the test able to prove what its comment
      // claims -- that the querier's independent parse site was updated.
      expect(sample.congestionControl, equals(CongestionControl.block));
      expect(sample.priority, equals(Priority.data));
      expect(sample.express, isFalse);
      expect(sample.timestamp, isNull);
    });
  });
  // -------------------------------------------------------------------------
  // Seed #6 Slice 1: the timeout-zero contract at querier declaration.
  //
  // A querier's timeout is fixed at DECLARATION time (canon's per-get options
  // struct carries no timeout field), so the refusal has to land there. One
  // public contract that rejects zero on `Session.get` and silently substitutes
  // on its querier sibling would be worse than either rule alone.
  group('Slice 1: the timeout-zero contract on declareQuerier', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
    });

    tearDownAll(() {
      session.close();
    });

    test('Duration.zero is refused before any native declaration', () {
      expect(
        () => session.declareQuerier(
          'zenoh/dart/test/s1/querier-zero',
          timeout: Duration.zero,
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', equals('timeout')),
        ),
      );
    });

    test('a positive sub-millisecond timeout is refused on the wire value', () {
      // Same wire-value keying as Session.get: inMilliseconds == 0 is the
      // collapse onto canon's config-default sentinel, whatever Duration
      // constructor produced it.
      expect(
        () => session.declareQuerier(
          'zenoh/dart/test/s1/querier-submilli',
          timeout: const Duration(microseconds: 500),
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', equals('timeout')),
        ),
      );
    });

    test('a positive millisecond-representable timeout is accepted', () {
      // The control: the guard rejects the sentinel collapse and nothing else.
      final querier = session.declareQuerier(
        'zenoh/dart/test/s1/querier-ok',
        timeout: const Duration(milliseconds: 1),
      );
      addTearDown(querier.close);
      expect(querier.keyExpr, equals('zenoh/dart/test/s1/querier-ok'));
    });
  });
  // -------------------------------------------------------------------------
  // Slice 16: the querier's channel-mode carrier.
  //
  // A THIN carrier: it reuses the same handler type, the same tee, the same
  // shared channel-construction body, the same extraction body and the same
  // `PullReplies` class as `Session.pullGet`. Only which canon entry is called
  // and which options struct is filled differ, so the cells here are the
  // stated smoke allocation rather than a second full matrix — a defect in the
  // shared machinery fails on the full-matrix carrier, and these target the
  // thin wiring.
  group('Slice 16: Querier.pullGet (TCP 19380)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19380"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19380"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    /// A queryable that answers once and finalises.
    void replyOnce(String key, {String payload = 'querier-answer'}) {
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(key, payload)
          ..dispose();
      });
    }

    Future<RecvResult<Reply>> pollFirst(PullReplies replies) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var last = replies.tryRecv();
      while (last is RecvEmpty<Reply> && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        last = replies.tryRecv();
      }
      return last;
    }

    test('a querier delivers replies through a fifo channel', () async {
      const key = 'zenoh/dart/test/s16/querier/fifo';
      replyOnce(key);
      final querier = sessionB.declareQuerier(
        key,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(querier.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = querier.pullGet(kind: ChannelKind.fifo, capacity: 4);
      addTearDown(replies.dispose);

      final first = await pollFirst(replies);
      expect(first, isA<RecvData<Reply>>());
      expect(
        (first as RecvData<Reply>).value.ok.payload,
        equals('querier-answer'),
      );

      // ...and the channel reaches its terminal state at query completion.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var terminal = replies.tryRecv();
      while (terminal is! RecvDisconnected<Reply> &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        terminal = replies.tryRecv();
      }
      expect(terminal, isA<RecvDisconnected<Reply>>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a querier delivers through a ring channel while in flight', () async {
      const key = 'zenoh/dart/test/s16/querier/ring';
      // Held open, so the channel stays connected while the poll runs -- a ring
      // discards its buffer at disconnect, so polling after completion would
      // recover nothing.
      final held = <Query>[];
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query.reply(key, 'in-flight');
        held.add(query);
      });
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });

      final querier = sessionB.declareQuerier(
        key,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(querier.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = querier.pullGet(kind: ChannelKind.ring, capacity: 4);
      addTearDown(replies.dispose);

      final first = await pollFirst(replies);
      expect(first, isA<RecvData<Reply>>());
      expect(
        (first as RecvData<Reply>).value.ok.payload,
        equals('in-flight'),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test("pullGet carries its stream sibling's option surface", () async {
      const key = 'zenoh/dart/test/s16/querier/options';
      final observed =
          Completer<
            ({
              String parameters,
              Uint8List? payload,
              Uint8List? attachment,
              String? encoding,
            })
          >();
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        if (!observed.isCompleted) {
          observed.complete((
            parameters: query.parameters,
            payload: query.payloadBytes,
            attachment: query.attachmentBytes,
            encoding: query.encoding,
          ));
        }
        query
          ..reply(key, 'ok')
          ..dispose();
      });

      final querier = sessionB.declareQuerier(
        key,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(querier.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = querier.pullGet(
        kind: ChannelKind.fifo,
        capacity: 4,
        // Interior NUL: the querier's send seam was rebased onto canon's
        // length-carried sibling, and this checks the CHANNEL mode inherits it.
        parameters: 'x=1\x00y=2',
        payload: ZBytes.fromString('body'),
        encoding: Encoding.applicationJson,
        attachment: ZBytes.fromString('att'),
      );
      addTearDown(replies.dispose);

      final seen = await observed.future.timeout(const Duration(seconds: 15));
      expect(seen.parameters, equals('x=1\x00y=2'));
      expect(seen.payload, equals(utf8.encode('body')));
      expect(seen.attachment, equals(utf8.encode('att')));
      expect(seen.encoding, equals(Encoding.applicationJson.mimeType));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test("a querier's recv() parks and wakes through the new entry", () async {
      // The only path that exercises the tee interposition on THIS carrier's
      // entry, which is why it is here rather than left to the shared cells.
      const key = 'zenoh/dart/test/s16/querier/park';
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        query
          ..reply(key, 'late')
          ..dispose();
      });

      final querier = sessionB.declareQuerier(
        key,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(querier.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = querier.pullGet(kind: ChannelKind.fifo, capacity: 4);
      addTearDown(replies.dispose);

      final result = await replies.recv().timeout(const Duration(seconds: 15));
      expect(result, isA<RecvData<Reply>>());
      expect((result as RecvData<Reply>).value.ok.payload, equals('late'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a negative capacity is refused before any native call', () async {
      final querier = sessionB.declareQuerier('zenoh/dart/test/s16/neg');
      addTearDown(querier.close);
      for (final kind in ChannelKind.values) {
        expect(
          () => querier.pullGet(kind: kind, capacity: -1),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('capacity'),
            ),
          ),
          reason: 'kind=$kind',
        );
      }
    });
  });
}
