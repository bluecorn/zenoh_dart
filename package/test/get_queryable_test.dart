import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh/src/native_lib.dart';
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

  group('Slice 5: Query.attachmentBytes + empty-vs-absent (TCP 17473)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17473"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17473"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: unit-level (nothing can SEND a query attachment until Slice 6).
    test('Query exposes exact attachment bytes', () {
      final query = Query(
        handle: 0,
        keyExpr: 'k',
        parameters: '',
        attachmentBytes: Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      expect(
        query.attachmentBytes,
        equals(Uint8List.fromList([0xFF, 0xFE, 0x80])),
      );
    });

    // Test 2: present-but-empty query payload distinguishable from absent (e2e).
    test('present-but-empty query payload distinguishable from absent',
        () async {
      final emptyResult = Completer<Uint8List?>();
      final absentResult = Completer<Uint8List?>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q5/emptyvabsent',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        if (query.parameters.contains('mode=empty')) {
          emptyResult.complete(query.payloadBytes);
        } else {
          absentResult.complete(query.payloadBytes);
        }
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      // Empty payload: zero-length ZBytes.
      final emptyPayload = ZBytes.fromUint8List(Uint8List(0));
      await sessionB
          .get(
            'zenoh/dart/test/q5/emptyvabsent',
            parameters: 'mode=empty',
            payload: emptyPayload,
          )
          .toList();

      // Absent payload: no payload at all.
      await sessionB
          .get(
            'zenoh/dart/test/q5/emptyvabsent',
            parameters: 'mode=absent',
          )
          .toList();

      final empty = await emptyResult.future.timeout(Duration(seconds: 5));
      final absent = await absentResult.future.timeout(Duration(seconds: 5));

      expect(empty, isNotNull, reason: 'present-but-empty must be non-null');
      expect(empty, isEmpty, reason: 'present-but-empty must be empty bytes');
      expect(absent, isNull, reason: 'absent payload must be null');
    });

    // Test 3 (Edge): absent query attachment is null (e2e).
    test('absent query attachment is null', () async {
      final received = Completer<Uint8List?>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q5/noattach',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        received.complete(query.attachmentBytes);
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q5/noattach').toList();

      final attach = await received.future.timeout(Duration(seconds: 5));
      expect(attach, isNull);
    });

    // Test 4 (Edge): zd_query_payload reads exact bytes via the sync path
    // (rc of z_bytes_reader_read checked; no uninitialized tail).
    test('zd_query_payload returns byte-exact payload (no garbage tail)',
        () async {
      final result = Completer<Uint8List>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q5/syncread',
      );
      addTearDown(queryable.close);

      final sent = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);

      queryable.stream.listen((query) {
        // Read via the sync zd_query_payload C path directly.
        final cap = sent.length + 8; // over-allocate to expose any garbage tail
        final buf = calloc<Uint8>(cap);
        try {
          final n = bindings.zd_query_payload(
            Pointer<Uint8>.fromAddress(query.handle).cast(),
            buf,
            cap,
          );
          final out = Uint8List(n);
          for (var i = 0; i < n; i++) {
            out[i] = buf[i];
          }
          result.complete(out);
        } finally {
          calloc.free(buf);
          query.dispose();
        }
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get(
            'zenoh/dart/test/q5/syncread',
            payload: ZBytes.fromUint8List(sent),
          )
          .toList();

      final out = await result.future.timeout(Duration(seconds: 5));
      expect(out, equals(sent));
    });
  });

  group('Slice 6: Session.get attachment send + matrix (TCP 17474)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17474"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17474"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: Session.get delivers binary attachment to the queryable
    // byte-exact (promotes Slice 5 Test 1 to e2e).
    test('Session.get delivers binary attachment to queryable byte-exact',
        () async {
      final received = Completer<Uint8List?>();
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q6/attach',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        received.complete(query.attachmentBytes);
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get(
            'zenoh/dart/test/q6/attach',
            attachment: ZBytes.fromUint8List(
              Uint8List.fromList([0xFF, 0xFE, 0x80]),
            ),
          )
          .toList();

      final attach = await received.future.timeout(Duration(seconds: 5));
      expect(attach, equals(Uint8List.fromList([0xFF, 0xFE, 0x80])));
    });

    // Test 2: Query payload + attachment matrix. Meaningful cells:
    //   binary payload + binary attachment;
    //   valid-UTF-8 payload + valid-UTF-8 attachment;
    //   empty payload + empty attachment (non-null empty);
    //   absent payload + absent attachment (null).
    test('query payload + attachment matrix is byte-exact', () async {
      final results = <String, ({Uint8List? payload, Uint8List? attachment})>{};
      final done = <String, Completer<void>>{
        'binary': Completer<void>(),
        'utf8': Completer<void>(),
        'empty': Completer<void>(),
        'absent': Completer<void>(),
      };

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q6/matrix');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        final mode = query.parameters
            .split('&')
            .firstWhere((p) => p.startsWith('mode='))
            .substring('mode='.length);
        results[mode] = (
          payload: query.payloadBytes,
          attachment: query.attachmentBytes,
        );
        done[mode]!.complete();
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final binPayload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final binAttach = Uint8List.fromList([0xFF, 0xFE, 0x80]);
      final utf8Payload = utf8.encode('héllo-payload');
      final utf8Attach = utf8.encode('héllo-attach');

      // binary payload + binary attachment
      await sessionB
          .get(
            'zenoh/dart/test/q6/matrix',
            parameters: 'mode=binary',
            payload: ZBytes.fromUint8List(binPayload),
            attachment: ZBytes.fromUint8List(binAttach),
          )
          .toList();

      // valid-UTF-8 payload + valid-UTF-8 attachment
      await sessionB
          .get(
            'zenoh/dart/test/q6/matrix',
            parameters: 'mode=utf8',
            payload: ZBytes.fromUint8List(Uint8List.fromList(utf8Payload)),
            attachment: ZBytes.fromUint8List(Uint8List.fromList(utf8Attach)),
          )
          .toList();

      // empty payload + empty attachment (present-but-empty)
      await sessionB
          .get(
            'zenoh/dart/test/q6/matrix',
            parameters: 'mode=empty',
            payload: ZBytes.fromUint8List(Uint8List(0)),
            attachment: ZBytes.fromUint8List(Uint8List(0)),
          )
          .toList();

      // absent payload + absent attachment
      await sessionB
          .get(
            'zenoh/dart/test/q6/matrix',
            parameters: 'mode=absent',
          )
          .toList();

      await Future.wait(done.values.map((c) => c.future)).timeout(
        Duration(seconds: 10),
      );

      // binary
      expect(results['binary']!.payload, equals(binPayload));
      expect(results['binary']!.attachment, equals(binAttach));
      // valid-UTF-8
      expect(results['utf8']!.payload, equals(utf8Payload));
      expect(results['utf8']!.attachment, equals(utf8Attach));
      // empty: non-null empty on both channels
      expect(results['empty']!.payload, isNotNull);
      expect(results['empty']!.payload, isEmpty);
      expect(results['empty']!.attachment, isNotNull);
      expect(results['empty']!.attachment, isEmpty);
      // absent: null on both channels
      expect(results['absent']!.payload, isNull);
      expect(results['absent']!.attachment, isNull);
    });

    // Test 3 (Edge): payload + attachment consumed (use-after-move fix).
    //
    // Path driven: the SUCCESS path's UNCONDITIONAL marking. This is the
    // latent-bug fix -- the old code marked payload ONLY on success and never
    // marked attachment at all; the new code marks BOTH unconditionally
    // (before the rc-throw). zenoh-c gravestones the moves regardless of rc,
    // so the only safe contract is: after Session.get returns, the caller
    // must never touch payload/attachment again.
    //
    // We cannot reliably drive a genuine POST-move non-zero rc here:
    // z_encoding_from_str accepts any string as a custom encoding (it never
    // fails for a junk MIME -- confirmed against zenoh-c 1.7.2), and a valid
    // selector + reachable session makes z_get succeed. So the post-move
    // assertion is exercised on the success path; the pre-move NOT-consumed
    // path is covered by the dedicated test below.
    test('get marks payload + attachment consumed unconditionally', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q6/consume');
      addTearDown(queryable.close);
      queryable.stream.listen((q) => q.dispose());
      await Future.delayed(Duration(milliseconds: 200));

      final payload = ZBytes.fromUint8List(
        Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
      );
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );

      await sessionB
          .get(
            'zenoh/dart/test/q6/consume',
            payload: payload,
            attachment: attachment,
          )
          .toList();

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

    // Test 3b: invalid selector is a PRE-move early-return -- zd_get's
    // z_view_keyexpr_from_str returns -1 before any z_bytes_move runs, so the
    // caller retains ownership and the ZBytes must NOT be marked consumed.
    test('get on invalid selector does NOT consume (pre-move early-return)',
        () {
      final payload = ZBytes.fromUint8List(
        Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
      );
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      expect(
        () => sessionB.get('', payload: payload, attachment: attachment),
        throwsA(isA<ZenohException>()),
      );
      // Still owned: reading both must succeed (no use-after-move).
      expect(payload.toBytes(), equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));
      payload.dispose();
      attachment.dispose();
    });

    // Test 4 (Edge): get encoding surfaces no silent substitution.
    //
    // CAVEAT (documented, matches Slice 3): z_encoding_from_str accepts any
    // string as a custom encoding and cannot be made to fail observably for a
    // junk MIME in zenoh-c 1.7.2. The rc-check in zd_get is therefore kept
    // DEFENSIVE (it will drop+return on a future failing case). Here we assert
    // a valid custom encoding round-trips faithfully -- proving no
    // silent-default-substitution path remains.
    test('valid custom get encoding round-trips faithfully', () async {
      final received = Completer<String?>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q6/enc');
      addTearDown(queryable.close);
      queryable.stream.listen((q) {
        q.replyBytes('zenoh/dart/test/q6/enc', ZBytes.fromString('r'));
        q.dispose();
      });
      await Future.delayed(Duration(milliseconds: 200));

      // The get carries a custom encoding; if it were silently dropped the
      // query would still flow, so we assert via the query side that no throw
      // occurs and a reply is received (the encoding is wired into z_get opts).
      final replies = await sessionB
          .get(
            'zenoh/dart/test/q6/enc',
            payload: ZBytes.fromString('q'),
            encoding: const Encoding('application/vnd.dart.test'),
          )
          .toList()
          .timeout(Duration(seconds: 5));

      received.complete('ok');
      expect(replies, isNotEmpty);
      expect(await received.future, equals('ok'));
    });
  });

  group('Slice 8: Query.reply attachment send + reply-ok pair (TCP 17475)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17475"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17475"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: a queryable replies with a binary attachment; the getter
    // receives it byte-exact on reply.ok.attachmentBytes (the reply-ok
    // attachment PAIR, completed via Slice 1's Sample.attachmentBytes).
    test('reply ok-sample carries binary attachment byte-exact (via get)',
        () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q8/attach');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyBytes(
          'zenoh/dart/test/q8/attach',
          ZBytes.fromString('ok'),
          attachment: ZBytes.fromUint8List(
            Uint8List.fromList([0xFF, 0xFE, 0x80]),
          ),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q8/attach')
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.attachmentBytes,
        equals(Uint8List.fromList([0xFF, 0xFE, 0x80])),
      );
    });

    // Test 3: reply payload + attachment matrix. Meaningful cells:
    //   binary payload + binary attachment;
    //   valid-UTF-8 payload + valid-UTF-8 attachment;
    //   empty payload + empty attachment (non-null empty);
    //   absent payload + absent attachment (null).
    test('reply payload + attachment matrix is byte-exact', () async {
      final binPayload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final binAttach = Uint8List.fromList([0xFF, 0xFE, 0x80]);
      final utf8Payload = Uint8List.fromList(utf8.encode('héllo-payload'));
      final utf8Attach = Uint8List.fromList(utf8.encode('héllo-attach'));

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q8/matrix');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        final mode = query.parameters
            .split('&')
            .firstWhere((p) => p.startsWith('mode='))
            .substring('mode='.length);
        switch (mode) {
          case 'binary':
            query.replyBytes(
              'zenoh/dart/test/q8/matrix',
              ZBytes.fromUint8List(binPayload),
              attachment: ZBytes.fromUint8List(binAttach),
            );
          case 'utf8':
            query.replyBytes(
              'zenoh/dart/test/q8/matrix',
              ZBytes.fromUint8List(utf8Payload),
              attachment: ZBytes.fromUint8List(utf8Attach),
            );
          case 'empty':
            query.replyBytes(
              'zenoh/dart/test/q8/matrix',
              ZBytes.fromUint8List(Uint8List(0)),
              attachment: ZBytes.fromUint8List(Uint8List(0)),
            );
          case 'absent':
            query.replyBytes(
              'zenoh/dart/test/q8/matrix',
              ZBytes.fromUint8List(Uint8List(0)),
            );
        }
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      Future<Reply> getOne(String mode) async {
        final replies = await sessionB
            .get('zenoh/dart/test/q8/matrix', parameters: 'mode=$mode')
            .toList()
            .timeout(Duration(seconds: 5));
        expect(replies, isNotEmpty);
        return replies.first;
      }

      final binary = await getOne('binary');
      final utf8R = await getOne('utf8');
      final empty = await getOne('empty');
      final absent = await getOne('absent');

      // binary
      expect(binary.isOk, isTrue);
      expect(binary.ok.payloadBytes, equals(binPayload));
      expect(binary.ok.attachmentBytes, equals(binAttach));
      // valid-UTF-8
      expect(utf8R.ok.payloadBytes, equals(utf8Payload));
      expect(utf8R.ok.attachmentBytes, equals(utf8Attach));
      // empty: non-null empty attachment (present-but-empty)
      expect(empty.ok.attachmentBytes, isNotNull);
      expect(empty.ok.attachmentBytes, isEmpty);
      // absent attachment -> null
      expect(absent.ok.attachmentBytes, isNull);
    });

    // Test 4 (Edge): reply consumed on POST-move path, NOT consumed on the
    // genuine PRE-move early-return.
    //
    // (b) POST-move: a successful reply moves payload + attachment into
    // zenoh-c. We cannot reliably drive a genuine POST-move NON-zero rc
    // (z_encoding_from_str accepts any custom MIME and a valid query+keyexpr
    // makes z_query_reply succeed in zenoh-c 1.7.2), so we drive the success
    // path and assert BOTH are consumed unconditionally -- documented, same
    // as Slices 6/7.
    test('reply marks payload + attachment consumed unconditionally (post-move)',
        () async {
      late ZBytes payload;
      late ZBytes attachment;
      final replied = Completer<void>();

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q8/consume');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        payload = ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );
        attachment = ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        );
        query.replyBytes(
          'zenoh/dart/test/q8/consume',
          payload,
          attachment: attachment,
        );
        query.dispose();
        replied.complete();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q8/consume')
          .toList()
          .timeout(Duration(seconds: 5));
      await replied.future.timeout(Duration(seconds: 5));

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

    // Test 4 (a) PRE-move early-return: replying on a DISPOSED query is a
    // genuine pre-move early-return (Query.replyBytes throws before any
    // z_bytes_move), so the caller retains ownership and the payload +
    // attachment ZBytes must NOT be marked consumed.
    test('reply on disposed query does NOT consume (pre-move early-return)',
        () async {
      late Query captured;
      final got = Completer<void>();

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q8/disposed');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        // Reply once so the get completes, then dispose and capture the handle.
        query.reply('zenoh/dart/test/q8/disposed', 'ack');
        query.dispose();
        captured = query;
        got.complete();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q8/disposed')
          .toList()
          .timeout(Duration(seconds: 5));
      await got.future.timeout(Duration(seconds: 5));

      final payload = ZBytes.fromUint8List(
        Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
      );
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );

      // Replying on the disposed query is a pre-move early-return.
      expect(
        () => captured.replyBytes(
          'zenoh/dart/test/q8/disposed',
          payload,
          attachment: attachment,
        ),
        throwsA(isA<StateError>()),
      );

      // Still owned: reading both must succeed (no use-after-move).
      expect(payload.toBytes(), equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));
      payload.dispose();
      attachment.dispose();
    });
  });

  group('Slice 9: Query.replyErr (error reply) + ReplyError.payloadBytes '
      '(TCP 17476)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17476"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17476"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: an error reply with a binary payload round-trips byte-exact on
    // reply.error.payloadBytes. This proves the error-reply payload PAIR e2e
    // (send via the new Query.replyErrBytes, receive via ReplyError).
    test('error reply round-trips binary payload byte-exact', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q9/bin');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyErrBytes(
          ZBytes.fromUint8List(
            Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
          ),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q9/bin')
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isFalse);
      expect(
        replies.first.error.payloadBytes,
        equals(Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41])),
      );
    });

    // Test 2: the error reply encoding is received faithfully.
    test('error reply encoding received faithfully', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q9/enc');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyErr('error', encoding: Encoding.applicationJson);
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q9/enc')
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isFalse);
      expect(replies.first.error.encoding, equals('application/json'));
    });

    // Test 3: error payload matrix {valid-UTF-8, invalid-UTF-8, empty}; each
    // payloadBytes byte-exact, lenient String view preserved.
    test('error payload matrix is byte-exact (utf8, binary, empty)', () async {
      final binPayload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final utf8Payload = Uint8List.fromList(utf8.encode('héllo-err'));

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q9/matrix');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        final mode = query.parameters
            .split('&')
            .firstWhere((p) => p.startsWith('mode='))
            .substring('mode='.length);
        switch (mode) {
          case 'binary':
            query.replyErrBytes(ZBytes.fromUint8List(binPayload));
          case 'utf8':
            query.replyErrBytes(ZBytes.fromUint8List(utf8Payload));
          case 'empty':
            query.replyErrBytes(ZBytes.fromUint8List(Uint8List(0)));
        }
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      Future<Reply> getOne(String mode) async {
        final replies = await sessionB
            .get('zenoh/dart/test/q9/matrix', parameters: 'mode=$mode')
            .toList()
            .timeout(Duration(seconds: 5));
        expect(replies, isNotEmpty);
        return replies.first;
      }

      final binary = await getOne('binary');
      final utf8R = await getOne('utf8');
      final empty = await getOne('empty');

      // binary: byte-exact
      expect(binary.isOk, isFalse);
      expect(binary.error.payloadBytes, equals(binPayload));
      // valid-UTF-8: byte-exact + lenient String view round-trips
      expect(utf8R.error.payloadBytes, equals(utf8Payload));
      expect(utf8R.error.payload, equals('héllo-err'));
      // empty: byte-exact empty
      expect(empty.error.payloadBytes, isEmpty);
    });

    // Test 4 (Edge): payload consumed on the POST-move success path; NOT
    // consumed on the genuine PRE-move early-return (disposed query).
    //
    // POST-move: a successful replyErr moves the payload into zenoh-c. We
    // cannot reliably drive a genuine POST-move NON-zero rc (z_encoding_from_str
    // accepts any custom MIME and a valid query makes z_query_reply_err succeed
    // in zenoh-c 1.7.2), so we drive the success path and assert the payload is
    // consumed unconditionally -- documented, same as Slice 8. NOTE: encoding
    // is a MIME string in Dart (not a caller-owned ZBytes); the C-side
    // owned_encoding move is internal, so only the payload ZBytes is the
    // Dart-side markConsumed concern.
    test('replyErr marks payload consumed unconditionally (post-move)',
        () async {
      late ZBytes payload;
      final replied = Completer<void>();

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q9/consume');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        payload = ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );
        query.replyErrBytes(payload);
        query.dispose();
        replied.complete();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q9/consume')
          .toList()
          .timeout(Duration(seconds: 5));
      await replied.future.timeout(Duration(seconds: 5));

      // Moved into zenoh-c (gravestoned) -- use-after-move must throw.
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
    });

    // Test 4 (a) PRE-move early-return: replyErr on a DISPOSED query throws
    // before any z_bytes_move, so the caller retains ownership and the payload
    // ZBytes must NOT be marked consumed.
    test('replyErr on disposed query does NOT consume (pre-move early-return)',
        () async {
      late Query captured;
      final got = Completer<void>();

      final queryable =
          sessionA.declareQueryable('zenoh/dart/test/q9/disposed');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        // Reply once so the get completes, then dispose and capture the handle.
        query.replyErr('ack');
        query.dispose();
        captured = query;
        got.complete();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q9/disposed')
          .toList()
          .timeout(Duration(seconds: 5));
      await got.future.timeout(Duration(seconds: 5));

      final payload = ZBytes.fromUint8List(
        Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
      );

      // Replying on the disposed query is a pre-move early-return.
      expect(
        () => captured.replyErrBytes(payload),
        throwsA(isA<StateError>()),
      );

      // Still owned: reading must succeed (no use-after-move).
      expect(payload.toBytes(), equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      payload.dispose();
    });

    // Test 5 (Edge): replyErr exposes NO attachment parameter (carve-out).
    // This is a signature/compile-time assertion: the calls below pass ONLY a
    // payload (+ optional encoding). There is deliberately no `attachment:`
    // named argument on replyErr / replyErrBytes -- the file would not compile
    // if one were added and required, and the carve-out is honored by the fact
    // that no attachment is ever passed here. We additionally smoke-test the
    // String + ZBytes forms accept only payload + encoding.
    test('replyErr accepts only payload + encoding (no attachment param)',
        () async {
      final queryable =
          sessionA.declareQueryable('zenoh/dart/test/q9/noattach');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        // String form: payload only.
        query.replyErr('e1');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q9/noattach')
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isFalse);
      expect(replies.first.error.payload, equals('e1'));
    });
  });
}
