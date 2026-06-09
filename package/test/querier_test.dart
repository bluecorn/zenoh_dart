// Querier lifecycle, get, and matching status tests (slices 2-4)
// Slice 4: Querier matching status (one-shot and stream)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Querier lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
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
      expect(() => querier.close(), returnsNormally);
    });

    test('Querier.close is idempotent', () {
      final querier = session.declareQuerier('demo/example/querier');
      querier.close();
      expect(() => querier.close(), returnsNormally);
    });

    test('declareQuerier on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
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
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic querier get receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/qr/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/qr/basic', 'hello from queryable');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/basic',
        timeout: Duration(seconds: 5),
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
          query.reply('zenoh/dart/test/qr/params', 'ok');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/params',
          timeout: Duration(seconds: 5),
        );
        addTearDown(querier.close);

        await querier.get(parameters: 'key=value').toList();

        final params = await receivedParams.future.timeout(
          Duration(seconds: 5),
        );
        expect(params, equals('key=value'));
      },
    );

    test(
      'querier get timeout with no queryable returns empty stream',
      () async {
        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/timeout',
          timeout: Duration(seconds: 1),
        );
        addTearDown(querier.close);

        final replies = await querier.get().toList().timeout(
          Duration(seconds: 5),
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
        query.reply('zenoh/dart/test/qr/repeat', 'reply-$queryCount');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/repeat',
        timeout: Duration(seconds: 5),
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
          query.replyBytes(
            'zenoh/dart/test/qr/binreply',
            ZBytes.fromUint8List(
              Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
            ),
          );
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/binreply',
          timeout: Duration(seconds: 5),
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
        timeout: Duration(seconds: 5),
      );
      querier.close();

      expect(
        () => querier.get(),
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
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17491"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17491"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
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
          query.reply('zenoh/dart/test/qr/payload', 'ack');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final querier = sessionB.declareQuerier(
          'zenoh/dart/test/qr/payload',
          timeout: Duration(seconds: 5),
        );
        addTearDown(querier.close);

        final payload = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
        await querier.get(payload: payload).toList();

        final received = await receivedPayload.future.timeout(
          Duration(seconds: 5),
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
        query.reply('zenoh/dart/test/qr/consumed', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/consumed',
        timeout: Duration(seconds: 5),
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
        query.reply(
          'zenoh/dart/test/qr/encoding',
          '{"status":"ok"}',
          encoding: Encoding.applicationJson,
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/encoding',
        timeout: Duration(seconds: 5),
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
        query.reply('zenoh/dart/test/qr/nopayload', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/nopayload',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier.get().toList();

      final received = await receivedPayload.future.timeout(
        Duration(seconds: 5),
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
        query.reply('zenoh/dart/test/qr/emptyparams', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/emptyparams',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier.get().toList();

      final params = await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, equals(''));
    });
  });

  group('Querier matching status one-shot (TCP 17492)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17492"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17492"]');
      session2 = Session.open(config: config2);

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
          timeout: Duration(seconds: 5),
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
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      expect(querier.hasMatchingQueryables(), isTrue);
    });

    test('hasMatchingQueryables after close throws StateError', () {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/closed',
        timeout: Duration(seconds: 5),
      );
      querier.close();
      expect(() => querier.hasMatchingQueryables(), throwsA(isA<StateError>()));
    });
  });

  group('Querier matching status stream (TCP 17493)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17493"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17493"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('matchingStatus is null when listener not enabled', () {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/null',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);
      expect(querier.matchingStatus, isNull);
    });

    test('matchingStatus stream emits true when queryable appears', () async {
      final querier = session1.declareQuerier(
        'zenoh/dart/test/qrmatch/stream',
        timeout: Duration(seconds: 5),
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
          timeout: Duration(seconds: 5),
          enableMatchingListener: true,
        );
        addTearDown(querier.close);

        final statuses = <bool>[];
        final gotFalse = Completer<void>();
        querier.matchingStatus!.listen((status) {
          statuses.add(status);
          if (status == false && statuses.length > 1) {
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
        timeout: Duration(seconds: 5),
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
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17494"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17494"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
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
        query.reply('zenoh/dart/test/qr7/attach', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/attach',
        timeout: Duration(seconds: 5),
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
        Duration(seconds: 5),
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
        query.reply('zenoh/dart/test/qr7/matrix', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/matrix',
        timeout: Duration(seconds: 5),
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
          .get(
            parameters: 'empty',
            payload: ZBytes.fromUint8List(Uint8List(0)),
          )
          .toList();
      await querier.get(parameters: 'absent').toList();

      await Future.wait(completers.values.map((c) => c.future))
          .timeout(Duration(seconds: 10));

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
    test('querier get marks payload + attachment consumed unconditionally',
        () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/qr7/consume',
      );
      addTearDown(queryable.close);
      queryable.stream.listen((q) {
        q.reply('zenoh/dart/test/qr7/consume', 'ack');
        q.dispose();
      });
      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/consume',
        timeout: Duration(seconds: 5),
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
        () => payload.toBytes(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
      expect(
        () => attachment.toBytes(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

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
        query.reply('zenoh/dart/test/qr7/emptyattach', 'ack');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr7/emptyattach',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier
          .get(
            parameters: 'empty',
            attachment: ZBytes.fromUint8List(Uint8List(0)),
          )
          .toList();
      await querier.get(parameters: 'none').toList();

      await Future.wait(completers.values.map((c) => c.future))
          .timeout(Duration(seconds: 10));

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
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17495"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17495"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
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
        query.replyBytes(
          'zenoh/dart/test/q8r/attach',
          ZBytes.fromString('ok'),
          attachment: ZBytes.fromUint8List(
            Uint8List.fromList([0xFF, 0xFE, 0x80]),
          ),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/q8r/attach',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier
          .get()
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.attachmentBytes,
        equals(Uint8List.fromList([0xFF, 0xFE, 0x80])),
      );
    });
  });
}
