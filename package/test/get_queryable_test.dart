import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Get/Queryable integration (TCP 17470)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic get receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/basic', 'hello from queryable');
        query.dispose();
      });

      // Small delay to let queryable register
      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/basic').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello from queryable'));
    });

    test('get with parameters', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/params');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query.reply('zenoh/dart/test/q/params', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q/params', parameters: 'key=value')
          .toList();

      final params = await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, equals('key=value'));
    });

    test('get with payload (ZBytes)', () async {
      final receivedPayload = Completer<Uint8List>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/payload');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        if (query.payloadBytes != null) {
          receivedPayload.complete(query.payloadBytes!);
        } else {
          receivedPayload.completeError('No payload received');
        }
        query.reply('zenoh/dart/test/q/payload', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final zbytes = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
      addTearDown(zbytes.dispose);

      await sessionB.get('zenoh/dart/test/q/payload', payload: zbytes).toList();

      final payload = await receivedPayload.future.timeout(
        Duration(seconds: 5),
      );
      expect(payload, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('empty parameters', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/noparams');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query.reply('zenoh/dart/test/q/noparams', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q/noparams').toList();

      final params = await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, isEmpty);
    });

    test('get timeout with no queryable', () async {
      final replies = await sessionB
          .get('zenoh/dart/test/q/nonexistent', timeout: Duration(seconds: 1))
          .toList();

      expect(replies, isEmpty);
    });

    test('query dispose without reply', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/noreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        // Dispose without replying
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/noreply', timeout: Duration(seconds: 2))
          .toList();

      expect(replies, isEmpty);
    });

    test('query dispose after reply is idempotent', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/idempotent',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/idempotent', 'ok');
        query.dispose();
        // Second dispose should be a no-op
        expect(() => query.dispose(), returnsNormally);
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q/idempotent').toList();
    });

    test('reply keyExpr matches query keyExpr', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/keycheck');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/keycheck', 'response');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/keycheck').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.keyExpr, equals('zenoh/dart/test/q/keycheck'));
    });

    test('Session.get() on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.get('zenoh/dart/test/q/closed'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('queryable close stops receiving queries', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/closedq');
      // Close queryable immediately
      queryable.close();

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/closedq', timeout: Duration(seconds: 1))
          .toList();

      expect(replies, isEmpty);
    });

    test('Query.reply with string value', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/strreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/strreply', 'hello string reply');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/strreply').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello string reply'));
    });

    test('Query.replyBytes with raw bytes', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/bytereply',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyBytes(
          'zenoh/dart/test/q/bytereply',
          ZBytes.fromUint8List(Uint8List.fromList([0xDE, 0xAD])),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/bytereply')
          .toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.payloadBytes,
        equals(Uint8List.fromList([0xDE, 0xAD])),
      );
    });

    test('delivers invalid-UTF-8 binary reply payload faithfully', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/binreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyBytes(
          'zenoh/dart/test/q/binreply',
          ZBytes.fromUint8List(
            Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
          ),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/binreply').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.payloadBytes,
        equals([0x00, 0xFF, 0xFE, 0x80, 0x41]),
      );
      expect(replies.first.ok.payload, contains('\u{FFFD}'));
    });

    test('empty reply payload still delivers', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/emptyreply',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyBytes(
          'zenoh/dart/test/q/emptyreply',
          ZBytes.fromUint8List(Uint8List(0)),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/emptyreply')
          .toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payloadBytes, isEmpty);
      expect(replies.first.ok.payload, equals(''));
    });

    test(
      'queryable receives invalid-UTF-8 binary query payload faithfully',
      () async {
        final receivedPayload = Completer<Uint8List?>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q/binquery',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          receivedPayload.complete(query.payloadBytes);
          query.reply('zenoh/dart/test/q/binquery', 'ok');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final zbytes = ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );

        await sessionB
            .get('zenoh/dart/test/q/binquery', payload: zbytes)
            .toList();

        final payload = await receivedPayload.future.timeout(
          Duration(seconds: 5),
        );
        expect(payload, isNotNull);
        expect(payload, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      },
    );

    test(
      'query with no payload still delivers with null payloadBytes',
      () async {
        final receivedPayload = Completer<Uint8List?>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q/nopayload',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          receivedPayload.complete(query.payloadBytes);
          query.reply('zenoh/dart/test/q/nopayload', 'ok');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        await sessionB.get('zenoh/dart/test/q/nopayload').toList();

        final payload = await receivedPayload.future.timeout(
          Duration(seconds: 5),
        );
        expect(payload, isNull);
      },
    );
  });

  group('Phase 7: Session.get with ZBytes payload (TCP 17472)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17472"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17472"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('Session.get with no payload receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q7/basic', 'hello');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q7/basic').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello'));
    });

    test(
      'Session.get with ZBytes payload delivers payload to queryable',
      () async {
        final receivedPayload = Completer<Uint8List>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q7/zbytes',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          if (query.payloadBytes != null) {
            receivedPayload.complete(query.payloadBytes!);
          } else {
            receivedPayload.completeError('No payload received');
          }
          query.reply('zenoh/dart/test/q7/zbytes', 'ok');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final zbytes = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
        addTearDown(zbytes.dispose);

        await sessionB
            .get('zenoh/dart/test/q7/zbytes', payload: zbytes)
            .toList();

        final payload = await receivedPayload.future.timeout(
          Duration(seconds: 5),
        );
        expect(payload, equals(Uint8List.fromList([1, 2, 3])));
      },
    );

    test('Session.get with null payload sends no payload', () async {
      final receivedHasPayload = Completer<bool>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/nullp');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedHasPayload.complete(query.payloadBytes != null);
        query.reply('zenoh/dart/test/q7/nullp', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q7/nullp').toList();

      final hasPayload = await receivedHasPayload.future.timeout(
        Duration(seconds: 5),
      );
      expect(hasPayload, isFalse);
    });

    test('ZBytes payload is consumed after Session.get', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q7/consumed',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q7/consumed', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final zbytes = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));

      await sessionB
          .get('zenoh/dart/test/q7/consumed', payload: zbytes)
          .toList();

      // After get() consumes the ZBytes, accessing nativePtr should throw
      expect(() => zbytes.nativePtr, throwsA(isA<StateError>()));
    });

    test('Query.replyBytes with ZBytes delivers correct payload', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q7/replybytes',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        final replyPayload = ZBytes.fromUint8List(
          Uint8List.fromList([0xDE, 0xAD]),
        );
        query.replyBytes('zenoh/dart/test/q7/replybytes', replyPayload);
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q7/replybytes')
          .toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.payloadBytes,
        equals(Uint8List.fromList([0xDE, 0xAD])),
      );
    });

    test(
      'Query.reply string convenience still works after replyBytes change',
      () async {
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q7/strconv',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          query.reply('zenoh/dart/test/q7/strconv', 'hello string');
          query.dispose();
        });

        await Future.delayed(Duration(milliseconds: 200));

        final replies = await sessionB
            .get('zenoh/dart/test/q7/strconv')
            .toList();

        expect(replies, hasLength(1));
        expect(replies.first.isOk, isTrue);
        expect(replies.first.ok.payload, equals('hello string'));
      },
    );

    test('ZBytes payload is consumed after Query.replyBytes', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q7/replyconsumed',
      );
      addTearDown(queryable.close);

      late ZBytes replyPayload;
      queryable.stream.listen((query) {
        replyPayload = ZBytes.fromUint8List(Uint8List.fromList([0xCA, 0xFE]));
        query.replyBytes('zenoh/dart/test/q7/replyconsumed', replyPayload);
        // After replyBytes consumes the ZBytes, nativePtr should throw
        expect(() => replyPayload.nativePtr, throwsA(isA<StateError>()));
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q7/replyconsumed')
          .toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
    });
  });
}
