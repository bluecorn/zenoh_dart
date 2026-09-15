import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Get/Queryable integration (TCP 17470)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic get receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/basic', 'hello from queryable')
          ..dispose();
      });

      // Small delay to let queryable register
      await Future<void>.delayed(const Duration(milliseconds: 200));

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
        query
          ..reply('zenoh/dart/test/q/params', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q/params', parameters: 'key=value')
          .toList();

      final params = await receivedParams.future.timeout(
        const Duration(seconds: 5),
      );
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
        query
          ..reply('zenoh/dart/test/q/payload', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final zbytes = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
      addTearDown(zbytes.dispose);

      await sessionB.get('zenoh/dart/test/q/payload', payload: zbytes).toList();

      final payload = await receivedPayload.future.timeout(
        const Duration(seconds: 5),
      );
      expect(payload, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('empty parameters', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/noparams');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query
          ..reply('zenoh/dart/test/q/noparams', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q/noparams').toList();

      final params = await receivedParams.future.timeout(
        const Duration(seconds: 5),
      );
      expect(params, isEmpty);
    });

    test('get timeout with no queryable', () async {
      final replies = await sessionB
          .get(
            'zenoh/dart/test/q/nonexistent',
            timeout: const Duration(seconds: 1),
          )
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

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/noreply', timeout: const Duration(seconds: 2))
          .toList();

      expect(replies, isEmpty);
    });

    test('query dispose after reply is idempotent', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/idempotent',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/idempotent', 'ok')
          ..dispose();
        // Second dispose should be a no-op
        expect(() => query.dispose(), returnsNormally);
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/idempotent')
          .toList();

      // The idempotence check lives inside the queryable callback, so it only
      // runs if a query was actually delivered. Without this outer assertion an
      // undelivered query means zero expectations execute -- and a test that
      // asserts nothing passes. Anchoring on the reply proves the callback ran.
      expect(replies, hasLength(1));
    });

    test('reply keyExpr matches query keyExpr', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/keycheck');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/keycheck', 'response')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/keycheck').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.keyExpr, equals('zenoh/dart/test/q/keycheck'));
    });

    test('Session.get() on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
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
      // Close queryable immediately
      sessionA.declareQueryable('zenoh/dart/test/q/closedq').close();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/closedq', timeout: const Duration(seconds: 1))
          .toList();

      expect(replies, isEmpty);
    });

    test('Query.reply with string value', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/strreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q/strreply', 'hello string reply')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
        query
          ..replyBytes(
            'zenoh/dart/test/q/bytereply',
            ZBytes.fromUint8List(Uint8List.fromList([0xDE, 0xAD])),
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
        query
          ..replyBytes(
            'zenoh/dart/test/q/binreply',
            ZBytes.fromUint8List(
              Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
            ),
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
        query
          ..replyBytes(
            'zenoh/dart/test/q/emptyreply',
            ZBytes.fromUint8List(Uint8List(0)),
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
          query
            ..reply('zenoh/dart/test/q/binquery', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final zbytes = ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        );

        await sessionB
            .get('zenoh/dart/test/q/binquery', payload: zbytes)
            .toList();

        final payload = await receivedPayload.future.timeout(
          const Duration(seconds: 5),
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
          query
            ..reply('zenoh/dart/test/q/nopayload', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB.get('zenoh/dart/test/q/nopayload').toList();

        final payload = await receivedPayload.future.timeout(
          const Duration(seconds: 5),
        );
        expect(payload, isNull);
      },
    );
  });

  group('Phase 7: Session.get with ZBytes payload (TCP 17472)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17472"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17472"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('Session.get with no payload receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q7/basic', 'hello')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
          query
            ..reply('zenoh/dart/test/q7/zbytes', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final zbytes = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
        addTearDown(zbytes.dispose);

        await sessionB
            .get('zenoh/dart/test/q7/zbytes', payload: zbytes)
            .toList();

        final payload = await receivedPayload.future.timeout(
          const Duration(seconds: 5),
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
        query
          ..reply('zenoh/dart/test/q7/nullp', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q7/nullp').toList();

      final hasPayload = await receivedHasPayload.future.timeout(
        const Duration(seconds: 5),
      );
      expect(hasPayload, isFalse);
    });

    test('ZBytes payload is consumed after Session.get', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q7/consumed',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q7/consumed', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
        query
          ..replyBytes('zenoh/dart/test/q7/replybytes', replyPayload)
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
          query
            ..reply('zenoh/dart/test/q7/strconv', 'hello string')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

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

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17473"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17473"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
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

    // Test 2: present-but-empty query payload distinguishable from absent
    // (e2e).
    test(
      'present-but-empty query payload distinguishable from absent',
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

        await Future<void>.delayed(const Duration(milliseconds: 200));

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
            .get('zenoh/dart/test/q5/emptyvabsent', parameters: 'mode=absent')
            .toList();

        final empty = await emptyResult.future.timeout(
          const Duration(seconds: 5),
        );
        final absent = await absentResult.future.timeout(
          const Duration(seconds: 5),
        );

        expect(empty, isNotNull, reason: 'present-but-empty must be non-null');
        expect(empty, isEmpty, reason: 'present-but-empty must be empty bytes');
        expect(absent, isNull, reason: 'absent payload must be null');
      },
    );

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

      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q5/noattach').toList();

      final attach = await received.future.timeout(const Duration(seconds: 5));
      expect(attach, isNull);
    });

    // Test 4 (Edge): zd_query_payload reads exact bytes via the sync path
    // (rc of z_bytes_reader_read checked; no uninitialized tail).
    test(
      'zd_query_payload returns byte-exact payload (no garbage tail)',
      () async {
        final result = Completer<Uint8List>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q5/syncread',
        );
        addTearDown(queryable.close);

        final sent = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);

        queryable.stream.listen((query) {
          // Read via the sync zd_query_payload C path directly.
          final cap =
              sent.length + 8; // over-allocate to expose any garbage tail
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

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get(
              'zenoh/dart/test/q5/syncread',
              payload: ZBytes.fromUint8List(sent),
            )
            .toList();

        final out = await result.future.timeout(const Duration(seconds: 5));
        expect(out, equals(sent));
      },
    );
  });

  group('Slice 6: Session.get attachment send + matrix (TCP 17474)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17474"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17474"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: Session.get delivers binary attachment to the queryable
    // byte-exact (promotes Slice 5 Test 1 to e2e).
    test(
      'Session.get delivers binary attachment to queryable byte-exact',
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

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get(
              'zenoh/dart/test/q6/attach',
              attachment: ZBytes.fromUint8List(
                Uint8List.fromList([0xFF, 0xFE, 0x80]),
              ),
            )
            .toList();

        final attach = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect(attach, equals(Uint8List.fromList([0xFF, 0xFE, 0x80])));
      },
    );

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

      await Future<void>.delayed(const Duration(milliseconds: 200));

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
          .get('zenoh/dart/test/q6/matrix', parameters: 'mode=absent')
          .toList();

      await Future.wait(
        done.values.map((c) => c.future),
      ).timeout(const Duration(seconds: 10));

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
      await Future<void>.delayed(const Duration(milliseconds: 200));

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
    });

    // Test 3b: invalid selector is a PRE-move early-return -- zd_get's
    // z_view_keyexpr_from_str returns -1 before any z_bytes_move runs, so the
    // caller retains ownership and the ZBytes must NOT be marked consumed.
    test(
      'get on invalid selector does NOT consume (pre-move early-return)',
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
      },
    );

    // Test 4 (Edge): get encoding surfaces no silent substitution.
    //
    // CAVEAT (documented, matches Slice 3): z_encoding_from_str accepts any
    // string as a custom encoding and cannot be made to fail observably for a
    // junk MIME in zenoh-c 1.7.2. The rc-check in zd_get is therefore kept
    // DEFENSIVE (it will drop+return on a future failing case). Here we assert
    // a valid custom encoding round-trips faithfully -- proving no
    // silent-default-substitution path remains.
    // This test used to complete its own completer and then await it -- a
    // condition satisfied by construction, with `query.encoding` never read.
    // It is rewritten rather than deleted because :1014-1015 is the only site
    // in this file where a get carries `payload:` and `encoding:` together;
    // deleting it would lose that combined leg. The instrument is the Slice-2
    // one: read the encoding inside the callback and assert its value.
    test('valid custom get encoding round-trips faithfully', () async {
      const customEncoding = 'application/vnd.dart.test';
      final received = Completer<String?>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q6/enc');
      addTearDown(queryable.close);
      queryable.stream.listen((q) {
        received.complete(q.encoding);
        q
          ..replyBytes('zenoh/dart/test/q6/enc', ZBytes.fromString('r'))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get(
            'zenoh/dart/test/q6/enc',
            payload: ZBytes.fromString('q'),
            encoding: const Encoding(customEncoding),
          )
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      // The encoding is what the test names: a custom MIME sent alongside a
      // payload must arrive on the query side unchanged. A silently dropped
      // encoding reads as null here.
      final encoding = await received.future.timeout(
        const Duration(seconds: 5),
      );
      expect(encoding, equals(customEncoding));
    });
  });

  group('Slice 8: Query.reply attachment send + reply-ok pair (TCP 17475)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17475"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17475"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: a queryable replies with a binary attachment; the getter
    // receives it byte-exact on reply.ok.attachmentBytes (the reply-ok
    // attachment PAIR, completed via Slice 1's Sample.attachmentBytes).
    test(
      'reply ok-sample carries binary attachment byte-exact (via get)',
      () async {
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q8/attach',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          query
            ..replyBytes(
              'zenoh/dart/test/q8/attach',
              ZBytes.fromString('ok'),
              attachment: ZBytes.fromUint8List(
                Uint8List.fromList([0xFF, 0xFE, 0x80]),
              ),
            )
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replies = await sessionB
            .get('zenoh/dart/test/q8/attach')
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(replies, isNotEmpty);
        expect(replies.first.isOk, isTrue);
        expect(
          replies.first.ok.attachmentBytes,
          equals(Uint8List.fromList([0xFF, 0xFE, 0x80])),
        );
      },
    );

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

      await Future<void>.delayed(const Duration(milliseconds: 200));

      Future<Reply> getOne(String mode) async {
        final replies = await sessionB
            .get('zenoh/dart/test/q8/matrix', parameters: 'mode=$mode')
            .toList()
            .timeout(const Duration(seconds: 5));
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
    test(
      'reply marks payload + attachment consumed unconditionally (post-move)',
      () async {
        late ZBytes payload;
        late ZBytes attachment;
        final replied = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q8/consume',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          payload = ZBytes.fromUint8List(
            Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
          );
          attachment = ZBytes.fromUint8List(
            Uint8List.fromList([0xFF, 0xFE, 0x80]),
          );
          query
            ..replyBytes(
              'zenoh/dart/test/q8/consume',
              payload,
              attachment: attachment,
            )
            ..dispose();
          replied.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q8/consume')
            .toList()
            .timeout(const Duration(seconds: 5));
        await replied.future.timeout(const Duration(seconds: 5));

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
      },
    );

    // Test 4 (a) PRE-move early-return: replying on a DISPOSED query is a
    // genuine pre-move early-return (Query.replyBytes throws before any
    // z_bytes_move), so the caller retains ownership and the payload +
    // attachment ZBytes must NOT be marked consumed.
    test(
      'reply on disposed query does NOT consume (pre-move early-return)',
      () async {
        late Query captured;
        final got = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q8/disposed',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          // Reply once so the get completes, then dispose and capture the
          // handle.
          query
            ..reply('zenoh/dart/test/q8/disposed', 'ack')
            ..dispose();
          captured = query;
          got.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q8/disposed')
            .toList()
            .timeout(const Duration(seconds: 5));
        await got.future.timeout(const Duration(seconds: 5));

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
      },
    );
  });

  group('Slice 9: Query.replyErr (error reply) + ReplyError.payloadBytes '
      '(TCP 17476)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17476"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17476"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
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
        query
          ..replyErrBytes(
            ZBytes.fromUint8List(
              Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
            ),
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q9/bin')
          .toList()
          .timeout(const Duration(seconds: 5));

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
        query
          ..replyErr('error', encoding: Encoding.applicationJson)
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q9/enc')
          .toList()
          .timeout(const Duration(seconds: 5));

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

      await Future<void>.delayed(const Duration(milliseconds: 200));

      Future<Reply> getOne(String mode) async {
        final replies = await sessionB
            .get('zenoh/dart/test/q9/matrix', parameters: 'mode=$mode')
            .toList()
            .timeout(const Duration(seconds: 5));
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
    // cannot reliably drive a genuine POST-move NON-zero rc
    // (z_encoding_from_str accepts any custom MIME and a valid query makes
    // z_query_reply_err succeed in zenoh-c 1.7.2), so we drive the success
    // path and assert the payload is consumed unconditionally -- documented,
    // same as Slice 8. NOTE: encoding is a MIME string in Dart (not a
    // caller-owned ZBytes); the C-side owned_encoding move is internal, so
    // only the payload ZBytes is the Dart-side markConsumed concern.
    test(
      'replyErr marks payload consumed unconditionally (post-move)',
      () async {
        late ZBytes payload;
        final replied = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q9/consume',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          payload = ZBytes.fromUint8List(
            Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
          );
          query
            ..replyErrBytes(payload)
            ..dispose();
          replied.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q9/consume')
            .toList()
            .timeout(const Duration(seconds: 5));
        await replied.future.timeout(const Duration(seconds: 5));

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
      },
    );

    // Test 4 (a) PRE-move early-return: replyErr on a DISPOSED query throws
    // before any z_bytes_move, so the caller retains ownership and the payload
    // ZBytes must NOT be marked consumed.
    test(
      'replyErr on disposed query does NOT consume (pre-move early-return)',
      () async {
        late Query captured;
        final got = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q9/disposed',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          // Reply once so the get completes, then dispose and capture the
          // handle.
          query
            ..replyErr('ack')
            ..dispose();
          captured = query;
          got.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q9/disposed')
            .toList()
            .timeout(const Duration(seconds: 5));
        await got.future.timeout(const Duration(seconds: 5));

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
      },
    );

    // Test 5 (Edge): replyErr exposes NO attachment parameter (carve-out).
    // This is a signature/compile-time assertion: the calls below pass ONLY a
    // payload (+ optional encoding). There is deliberately no `attachment:`
    // named argument on replyErr / replyErrBytes -- the file would not compile
    // if one were added and required, and the carve-out is honored by the fact
    // that no attachment is ever passed here. We additionally smoke-test the
    // String + ZBytes forms accept only payload + encoding.
    test(
      'replyErr accepts only payload + encoding (no attachment param)',
      () async {
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q9/noattach',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          // String form: payload only.
          query
            ..replyErr('e1')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replies = await sessionB
            .get('zenoh/dart/test/q9/noattach')
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(replies, isNotEmpty);
        expect(replies.first.isOk, isFalse);
        expect(replies.first.error.payload, equals('e1'));
      },
    );
  });

  // Slice 4: Sample metadata on the reply-ok path (Session.get). Per N3,
  // reply-ok QoS is deprecated -> assert the four fields are EXPOSED
  // (populated defaults, not dropped) and timestamp is null on a plain reply
  // (the reply-path timestamp round-trip is Slice 7). Test 3 confirms the
  // ok-branch change did not disturb the error branch.
  group('Slice 4: reply-ok metadata exposure via get (TCP 17533)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17533"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17533"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: a plain reply exposes priority/congestion/express (non-null
    // defaults) and a null timestamp -- the metadata is populated, not dropped.
    test('get reply-ok exposes all four metadata fields', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q4/meta');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q4/meta', 'reply-value')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q4/meta')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      final sample = replies.first.ok;
      expect(sample.payload, equals('reply-value'));
      // Values, not `isNotNull`. All three fields are non-nullable with
      // constructor defaults (sample.dart), so `isNotNull` on them cannot fail
      // under any code change -- a parser that dropped reply QoS entirely
      // produced the same green.
      //
      // Reach, stated precisely so this is not re-flagged: congestionControl
      // is the discriminating one. A reply arrives with BLOCK, which is *not*
      // the constructor default (drop) -- measured, not assumed -- so a parser
      // that stopped reading the field would fail here. priority and express
      // coincide with their constructor defaults, so those two remain
      // default-echo pins: they catch a mis-indexed enum or a flipped bool,
      // not a dropped field. Reply QoS is not injectable (N3), so this is the
      // strongest form available on this path.
      expect(sample.congestionControl, equals(CongestionControl.block));
      expect(sample.priority, equals(Priority.data));
      expect(sample.express, isFalse);
      // Plain reply carries no timestamp.
      expect(sample.timestamp, isNull);
    });

    // Test 3: an error reply is unaffected by the ok-branch change.
    test('error reply unaffected by ok-branch metadata change', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q4/err');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..replyErrBytes(
            ZBytes.fromUint8List(Uint8List.fromList([0x00, 0xFF, 0xFE, 0x41])),
            encoding: Encoding.applicationJson,
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q4/err')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isFalse);
      expect(
        replies.first.error.payloadBytes,
        equals(Uint8List.fromList([0x00, 0xFF, 0xFE, 0x41])),
      );
      expect(replies.first.error.encoding, equals('application/json'));
    });
  });

  group('Slice 7: Query.reply timestamp send + reply-ok round-trip '
      '(TCP 17537)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17537"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17537"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: the queryable replies via Query.reply with an explicit timestamp
    // created on its own session; the get ok-reply Sample.timestamp round-trips
    // bit-exact (NTP64 time AND id). This is the deterministic reply-path
    // round-trip Slice 4 wired but could not drive in-process.
    test('reply ok timestamp round-trips through get bit-exact', () async {
      final ts = sessionA.newTimestamp();

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/rt');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q7/rt', 'reply-value', timestamp: ts)
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q7/rt')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      final sample = replies.first.ok;
      expect(sample.payload, equals('reply-value'));
      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp, equals(ts));
      expect(sample.timestamp!.time, equals(ts.time));
      expect(sample.timestamp!.id, equals(ts.id));
    });

    // Test 2: replyBytes accepts the same timestamp param; ok-reply round-trips
    // bit-exact.
    test('replyBytes ok timestamp round-trips through get bit-exact', () async {
      final ts = sessionA.newTimestamp();

      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/rtb');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..replyBytes(
            'zenoh/dart/test/q7/rtb',
            ZBytes.fromString('reply-value'),
            timestamp: ts,
          )
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q7/rtb')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      final sample = replies.first.ok;
      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp, equals(ts));
      expect(sample.timestamp!.time, equals(ts.time));
      expect(sample.timestamp!.id, equals(ts.id));
    });

    // Test 3 (Edge): a reply with no timestamp yields a null Sample.timestamp
    // on the get side (absent preserved). Both sessions are default (no
    // timestamping/enabled), so no HLC stamps one implicitly.
    test('reply without timestamp yields null on get', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q7/none');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..reply('zenoh/dart/test/q7/none', 'reply-value')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q7/none')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.timestamp, isNull);
    });

    // Test 4 (Edge): the borrowed-timestamp field does not perturb the
    // pre-move/post-move markConsumed discipline. A successful reply with
    // payload + attachment + timestamp moves payload + attachment into
    // zenoh-c; both are consumed exactly once (a second use throws StateError).
    test(
      'reply with timestamp preserves payload+attachment markConsumed',
      () async {
        final ts = sessionA.newTimestamp();
        late ZBytes payload;
        late ZBytes attachment;
        final replied = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q7/consume',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          payload = ZBytes.fromUint8List(
            Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
          );
          attachment = ZBytes.fromUint8List(
            Uint8List.fromList([0xFF, 0xFE, 0x80]),
          );
          query
            ..replyBytes(
              'zenoh/dart/test/q7/consume',
              payload,
              attachment: attachment,
              timestamp: ts,
            )
            ..dispose();
          replied.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q7/consume')
            .toList()
            .timeout(const Duration(seconds: 5));
        await replied.future.timeout(const Duration(seconds: 5));

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
      },
    );
  });

  group(
    'Slice 2: Query.encoding (requester declared encoding) (TCP 17540)',
    () {
      late Session sessionA;
      late Session sessionB;

      setUp(() async {
        sessionA = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17540"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        sessionB = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17540"]'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      tearDown(() async {
        sessionB.close();
        sessionA.close();
      });

      // Test 1: encoding set on get round-trips to the received Query.
      test('encoding set on get round-trips to the query', () async {
        final received = Completer<String?>();
        final queryable = sessionA.declareQueryable('zenoh/dart/test/q2/enc');
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          received.complete(query.encoding);
          query
            ..reply('zenoh/dart/test/q2/enc', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q2/enc', encoding: Encoding.applicationJson)
            .toList()
            .timeout(const Duration(seconds: 5));

        final encoding = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect(encoding, equals('application/json'));
      });

      // Test 2: absent encoding (no encoding, no payload) reads as null.
      test('absent encoding reads as null', () async {
        final received = Completer<String?>();
        final queryable = sessionA.declareQueryable('zenoh/dart/test/q2/none');
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          received.complete(query.encoding);
          query
            ..reply('zenoh/dart/test/q2/none', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q2/none')
            .toList()
            .timeout(const Duration(seconds: 5));

        final encoding = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect(encoding, isNull);
      });

      // Test 3 (edge): custom MIME round-trips verbatim.
      test('custom MIME encoding round-trips verbatim', () async {
        final received = Completer<String?>();
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q2/custom',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          received.complete(query.encoding);
          query
            ..reply('zenoh/dart/test/q2/custom', 'ok')
            ..dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get(
              'zenoh/dart/test/q2/custom',
              encoding: const Encoding('application/x-my-proto'),
            )
            .toList()
            .timeout(const Duration(seconds: 5));

        final encoding = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect(encoding, equals('application/x-my-proto'));
      });
    },
  );

  group('Slice 3: Query.acceptsReplies + ReplyKeyExpr enum (TCP 17541)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17541"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17541"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: a default get carries the matchingQuery accept-replies policy.
    // This test IS the confirmation of the zenoh-c default (there is no header
    // constant to read; it is a runtime property of the query).
    test('default acceptsReplies is matchingQuery', () async {
      final received = Completer<ReplyKeyExpr>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q3/accept');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        received.complete(query.acceptsReplies);
        query
          ..reply('zenoh/dart/test/q3/accept', 'ok')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q3/accept')
          .toList()
          .timeout(const Duration(seconds: 5));

      final accepts = await received.future.timeout(const Duration(seconds: 5));
      expect(accepts, equals(ReplyKeyExpr.matchingQuery));
    });

    // Test 2 (edge): the enum ordinals align to zenoh-c z_reply_keyexpr_t
    // (ANY=0, MATCHING_QUERY=1). Pure Dart, no network.
    test('ReplyKeyExpr ordinals align to z_reply_keyexpr_t', () {
      expect(ReplyKeyExpr.any.index, equals(0));
      expect(ReplyKeyExpr.matchingQuery.index, equals(1));
    });
  });

  group('Slice 4: Query.replyDel (DELETE-kind reply) (TCP 17542)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17542"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17542"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: replyDel delivers a DELETE-kind reply. The getter receives an
    // ok reply whose Sample.kind is SampleKind.delete (the request/response
    // DELETE half, mirroring z_query_reply_del).
    test('replyDel delivers a DELETE-kind reply', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q4/del');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..replyDel('zenoh/dart/test/q4/del')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q4/del')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.kind, equals(SampleKind.delete));
    });

    // Test 2: attachment round-trips byte-exact over the data domain
    // {valid-UTF-8, invalid-UTF-8/binary, empty}. A DELETE-kind reply carries
    // no payload but still conveys an attachment.
    test(
      'replyDel attachment round-trips byte-exact over the data domain',
      () async {
        final utf8Attach = Uint8List.fromList(utf8.encode('héllo-attach'));
        final binAttach = Uint8List.fromList([0xFF, 0xFE, 0x80]);
        final emptyAttach = Uint8List(0);

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q4/attach',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          final mode = query.parameters
              .split('&')
              .firstWhere((p) => p.startsWith('mode='))
              .substring('mode='.length);
          switch (mode) {
            case 'utf8':
              query.replyDel(
                'zenoh/dart/test/q4/attach',
                attachment: ZBytes.fromUint8List(utf8Attach),
              );
            case 'binary':
              query.replyDel(
                'zenoh/dart/test/q4/attach',
                attachment: ZBytes.fromUint8List(binAttach),
              );
            case 'empty':
              query.replyDel(
                'zenoh/dart/test/q4/attach',
                attachment: ZBytes.fromUint8List(emptyAttach),
              );
          }
          query.dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        Future<Reply> getOne(String mode) async {
          final replies = await sessionB
              .get('zenoh/dart/test/q4/attach', parameters: 'mode=$mode')
              .toList()
              .timeout(const Duration(seconds: 5));
          expect(replies, isNotEmpty);
          return replies.first;
        }

        final utf8R = await getOne('utf8');
        final binary = await getOne('binary');
        final empty = await getOne('empty');

        expect(utf8R.isOk, isTrue);
        expect(utf8R.ok.kind, equals(SampleKind.delete));
        expect(utf8R.ok.attachmentBytes, equals(utf8Attach));

        expect(binary.ok.attachmentBytes, equals(binAttach));

        // present-but-empty attachment: non-null, empty (empty != absent)
        expect(empty.ok.attachmentBytes, isNotNull);
        expect(empty.ok.attachmentBytes, isEmpty);
      },
    );

    // Test 3 (edge): absent attachment yields a null attachmentBytes on the
    // get side (absent != empty).
    test('replyDel without attachment yields null attachmentBytes', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q4/noattach',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query
          ..replyDel('zenoh/dart/test/q4/noattach')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q4/noattach')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.attachmentBytes, isNull);
    });

    // Test 4: the optional borrowed timestamp round-trips bit-exact on the
    // DELETE-kind reply; omitted -> null. Both sessions are default (no
    // timestamping/enabled) so no HLC stamps one implicitly.
    test(
      'replyDel timestamp round-trips bit-exact; omitted yields null',
      () async {
        final ts = sessionA.newTimestamp();

        final queryable = sessionA.declareQueryable('zenoh/dart/test/q4/ts');
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          final mode = query.parameters
              .split('&')
              .firstWhere((p) => p.startsWith('mode='))
              .substring('mode='.length);
          if (mode == 'ts') {
            query.replyDel('zenoh/dart/test/q4/ts', timestamp: ts);
          } else {
            query.replyDel('zenoh/dart/test/q4/ts');
          }
          query.dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final withTs = await sessionB
            .get('zenoh/dart/test/q4/ts', parameters: 'mode=ts')
            .toList()
            .timeout(const Duration(seconds: 5));
        final noTs = await sessionB
            .get('zenoh/dart/test/q4/ts', parameters: 'mode=none')
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(withTs, isNotEmpty);
        expect(withTs.first.isOk, isTrue);
        final sample = withTs.first.ok;
        expect(sample.kind, equals(SampleKind.delete));
        expect(sample.timestamp, isNotNull);
        expect(sample.timestamp, equals(ts));
        expect(sample.timestamp!.time, equals(ts.time));
        expect(sample.timestamp!.id, equals(ts.id));

        expect(noTs, isNotEmpty);
        expect(noTs.first.ok.timestamp, isNull);
      },
    );

    // Test 5 (edge): replyDel on a DISPOSED query is a genuine pre-move
    // early-return -- Query.replyDel throws StateError before any z_bytes_move,
    // so the caller retains ownership and the attachment ZBytes must NOT be
    // marked consumed.
    test(
      'replyDel on disposed query does NOT consume (pre-move early-return)',
      () async {
        late Query captured;
        final got = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q4/disposed',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          // Reply once so the get completes, then dispose and capture the
          // handle.
          query
            ..reply('zenoh/dart/test/q4/disposed', 'ack')
            ..dispose();
          captured = query;
          got.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await sessionB
            .get('zenoh/dart/test/q4/disposed')
            .toList()
            .timeout(const Duration(seconds: 5));
        await got.future.timeout(const Duration(seconds: 5));

        final attachment = ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        );

        expect(
          () => captured.replyDel(
            'zenoh/dart/test/q4/disposed',
            attachment: attachment,
          ),
          throwsA(isA<StateError>()),
        );

        // Still owned: reading it must succeed (no use-after-move).
        expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));
      },
    );

    // Test 6 (edge): replyDel with an invalid key expression is a pre-move
    // early-return (Query.replyDel validates the keyexpr before any
    // z_bytes_move), so it throws ZenohException and the attachment is NOT
    // consumed; native temporaries are freed.
    test(
      'replyDel on invalid keyExpr does NOT consume (pre-move early-return)',
      () async {
        late Query captured;
        final got = Completer<void>();

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/test/q4/invalid',
        );
        addTearDown(queryable.close);

        queryable.stream.listen((query) {
          // Capture a LIVE query so the failing path is the invalid keyexpr,
          // not a disposed handle. Do not reply and do not dispose yet -- the
          // query must stay live through the replyDel assertion below.
          captured = query;
          got.complete();
        });

        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Fire the get to route a query to the queryable; do not await it here
        // (an ok reply is only delivered to the getter once the query is
        // dropped, and we keep it live for the assertion). Drained after
        // dispose.
        final getFuture = sessionB.get('zenoh/dart/test/q4/invalid').toList();
        await got.future.timeout(const Duration(seconds: 5));

        final attachment = ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        );

        expect(
          () => captured.replyDel('', attachment: attachment),
          throwsA(isA<ZenohException>()),
        );

        // Still owned: reading it must succeed (no use-after-move).
        expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));

        // Dispose finalizes the query so the getter's stream completes.
        captured.dispose();
        await getFuture.timeout(const Duration(seconds: 5));
      },
    );
  });

  group('Slice 8: Session.declareBackgroundQueryable (C3) (TCP 17546)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17546"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17546"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    // Test 1: a background queryable (no handle) answers a get. A declares the
    // background queryable, B issues get(K), A's stream yields the Query, A
    // replies, and B receives the reply Sample for K.
    test('background queryable answers a get', () async {
      final stream = sessionA.declareBackgroundQueryable(
        'zenoh/dart/test/bgq/answer',
      );

      final sub = stream.listen((query) {
        query
          ..reply('zenoh/dart/test/bgq/answer', 'bg-reply')
          ..dispose();
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/bgq/answer')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.keyExpr, equals('zenoh/dart/test/bgq/answer'));
      expect(replies.first.ok.payload, equals('bg-reply'));
    });

    // Test 2: the delivered Query is fully replyable and disposable, behaving
    // exactly like one from handle-based declareQueryable (inspect fields,
    // reply, dispose).
    test('delivered Query is fully replyable and disposable', () async {
      final stream = sessionA.declareBackgroundQueryable(
        'zenoh/dart/test/bgq/replyable',
      );

      Query? captured;
      final sub = stream.listen((query) {
        captured = query;
        // Inspect fields like a handle-based query.
        expect(query.keyExpr, equals('zenoh/dart/test/bgq/replyable'));
        expect(query.parameters, contains('mode=x'));
        expect(query.payloadBytes, isNotNull);
        expect(
          utf8.decode(query.payloadBytes!, allowMalformed: true),
          equals('req-payload'),
        );
        query
          ..replyBytes(
            'zenoh/dart/test/bgq/replyable',
            ZBytes.fromUint8List(Uint8List.fromList(utf8.encode('ok-body'))),
          )
          ..dispose();
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final replies = await sessionB
          .get(
            'zenoh/dart/test/bgq/replyable',
            parameters: 'mode=x',
            payload: ZBytes.fromString('req-payload'),
          )
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(replies, isNotEmpty);
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payloadBytes, equals(utf8.encode('ok-body')));
      expect(captured, isNotNull);
    });

    // Test 3: the stream completes when the session closes (fire-and-forget,
    // no handle, no explicit close call).
    test('stream completes on session close', () async {
      final stream = sessionA.declareBackgroundQueryable(
        'zenoh/dart/test/bgq/complete',
      );

      final done = Completer<void>();
      final sub = stream.listen((_) {}, onDone: done.complete);
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Closing the session drops the background queryable; its sentinel drop
      // posts the null completion sentinel.
      sessionA.close();

      await done.future.timeout(const Duration(seconds: 5));
    });

    // Test 4 (edge): an invalid key expression throws ZenohException; the
    // receive port and controller are cleaned up (no dangling stream).
    test('invalid key expression throws', () async {
      expect(
        () => sessionA.declareBackgroundQueryable('bad ke ***'),
        throwsA(isA<ZenohException>()),
      );
    });
  });

  // R3: disjoint-reply rejection, and what cancelling a get subscription does.
  //
  // Both are shipped surface that nothing observed. They share a session pair
  // because both need a queryable that misbehaves or stalls on purpose.
  group('R3: reply-key rejection and get-stream cancel (TCP 18850)', () {
    late Session sessionA;
    late Session sessionB;

    setUpAll(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18850"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18850"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      sessionB.close();
      sessionA.close();
    });

    // A reply must land on a key expression the query asked for. Nothing in the
    // corpus established what happens when it does not -- silently dropped
    // downstream, delivered anyway, or refused at the source are three very
    // different contracts, and only the last is safe to build on.
    //
    // Measured: refused at the source. `Query.reply` throws ZenohException
    // (rc -128) for a non-intersecting key, and the getter never sees it.
    // The on-key reply issued from the same callback is the positive control:
    // it proves the callback ran, the query was live, and the reply channel
    // worked -- so the rejection is about the key, not about a broken setup.
    test('a reply on a disjoint key is refused at the replier', () async {
      const asked = 'zenoh/dart/test/r3/disjoint/asked';
      const unrelated = 'zenoh/dart/test/r3/disjoint/unrelated';

      final queryable = sessionA.declareQueryable(asked);
      addTearDown(queryable.close);

      Object? disjointError;
      queryable.stream.listen((query) {
        try {
          query.reply(unrelated, 'off-key');
        } on Object catch (e) {
          disjointError = e;
        }
        // Positive control, same query, same callback.
        query
          ..reply(asked, 'on-key')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = await sessionB
          .get(asked, consolidation: ConsolidationMode.none)
          .toList();

      expect(
        disjointError,
        isA<ZenohException>(),
        reason: 'replying off-key silently succeeded',
      );
      expect((disjointError! as ZenohException).returnCode, equals(-128));

      // Only the on-key reply arrives, and it does arrive.
      expect(replies, hasLength(1));
      expect(replies.single.isOk, isTrue);
      expect(replies.single.ok.keyExpr, equals(asked));
      expect(replies.single.ok.payload, equals('on-key'));
    });

    // What cancelling a Session.get subscription does TODAY.
    //
    // This is a pin on shipped behaviour, not an endorsement of it: there is no
    // cancellation API on Session.get, so cancelling the Dart subscription is
    // the only thing a caller can do to walk away from a query in flight, and
    // until now nothing recorded whether that was safe. (Whether the native
    // query is also released is a resource question a behavioural assertion
    // cannot see -- verification.md 3a -- and instrumenting it is out of this
    // round's scope. What is established here is that it does not throw, does
    // not hang, and does not poison the session.)
    //
    // The query is held open by a queryable that receives and never finalizes,
    // so the cancel lands mid-flight rather than after the get already
    // completed -- otherwise this would pin nothing.
    test('cancelling a get subscription mid-flight is quiet and safe', () async {
      const hanging = 'zenoh/dart/test/r3/cancel/hang';

      final heldQueries = <Query>[];
      final queryable = sessionA.declareQueryable(hanging);
      addTearDown(() {
        for (final query in heldQueries) {
          query.dispose();
        }
        queryable.close();
      });
      queryable.stream.listen(heldQueries.add); // never replies, never disposes

      await Future<void>.delayed(const Duration(milliseconds: 300));

      final events = <String>[];
      var doneFired = false;
      final subscription = sessionB
          .get(hanging, timeout: const Duration(seconds: 3))
          .listen(
            (_) => events.add('reply'),
            onDone: () => doneFired = true,
            onError: (Object e) => events.add('error'),
          );

      // Let the query reach the queryable, so this is a live cancel.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        heldQueries,
        isNotEmpty,
        reason: 'query never reached the queryable',
      );

      await subscription.cancel();

      // Past the query's own timeout: nothing arrives after a cancel, not even
      // the Timeout error reply the un-cancelled query would have produced
      // (the sibling test in get_queryable_advanced_test proves that error is
      // real, so its absence here is a consequence of the cancel).
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(events, isEmpty, reason: 'events delivered after cancel');
      expect(doneFired, isFalse, reason: 'cancel now completes the stream');
    });

    test('the session still serves queries after a cancelled get', () async {
      const key = 'zenoh/dart/test/r3/cancel/after';

      // Cancel a get that nothing will ever answer...
      final subscription = sessionB
          .get('zenoh/dart/test/r3/cancel/nobody')
          .listen((_) {});
      await subscription.cancel();

      // ...then prove the session is undamaged with a real query/reply.
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(key, 'still-works')
          ..dispose();
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = await sessionB.get(key).toList();

      expect(replies, hasLength(1));
      expect(replies.single.ok.payload, equals('still-works'));
    });
  });
  // -------------------------------------------------------------------------
  // Seed #6 Slice 1: the timeout-zero contract.
  //
  // Canon's `z_get_options_t.timeout_ms == 0` means "default query timeout from
  // zenoh configuration" (zenoh_commons.h:1026-1029), so a Dart caller passing
  // `Duration.zero` -- meaning "expire immediately" by every reasonable reading
  // -- silently got ~10 s instead. That is a silent default substitution, one
  // of the forbidden transforms the fidelity doctrine names, so the binding
  // refuses the value rather than smuggling it onto canon's sentinel.
  //
  // The refusal keys on the MARSHALLED WIRE VALUE, not on `Duration.zero`
  // identity: `Duration(microseconds: 500).inMilliseconds == 0` truncates onto
  // the same sentinel, and a positive sub-millisecond timeout collapsing into
  // "canon decides" is the identical defect wearing a different constructor.
  group('Slice 1: the timeout-zero contract (TCP 19330)', () {
    late Session sessionA;
    late Session sessionB;

    // Discovery off on both sides: a LAN peer answering these queries would
    // change when the stream completes, which is exactly what these cells
    // measure.
    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19330"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19330"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    /// Declares a queryable that receives queries and NEVER replies, holding
    /// each [Query] alive so the getter's query stays in flight.
    ///
    /// The held queries are disposed at teardown. Not disposing them is the
    /// point: a disposed query sends ResponseFinal and completes the get, which
    /// would make every expiry cell below measure instant completion instead of
    /// a timeout (Decision log 7's instrument lesson).
    Queryable declareHeldOpenQueryable(String key) {
      final held = <Query>[];
      final queryable = sessionA.declareQueryable(key);
      queryable.stream.listen(held.add);
      addTearDown(() {
        for (final query in held) {
          query.dispose();
        }
        queryable.close();
      });
      return queryable;
    }

    test('Duration.zero is refused on Session.get', () async {
      expect(
        () => sessionB.get(
          'zenoh/dart/test/s1/zero',
          timeout: Duration.zero,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            equals('timeout'),
          ),
        ),
      );
    });

    test('a null timeout means canon decides, and canon is not instant', () async {
      const key = 'zenoh/dart/test/s1/null-timeout';
      declareHeldOpenQueryable(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      var completed = false;
      final subscription = sessionB
          .get(key)
          .listen(
            (_) {},
            onDone: () => completed = true,
          );
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(seconds: 2));

      // The wire 0 reached canon as its CONFIG-DEFAULT sentinel (~10 s), not as
      // an immediate expiry. Had 0 meant "expire now", this would be done.
      expect(completed, isFalse);
    });

    test('an explicit sub-second timeout is honoured', () async {
      const key = 'zenoh/dart/test/s1/short-timeout';
      declareHeldOpenQueryable(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The positive control for the cell above: with an explicit timeout the
      // same held-open topology DOES complete, so that cell's `isFalse` is the
      // timeout's doing and not a dead stream.
      await sessionB
          .get(key, timeout: const Duration(milliseconds: 400))
          .toList()
          .timeout(const Duration(seconds: 2));
    });

    test(
      'a positive sub-millisecond timeout is refused on the wire value',
      () async {
        // Duration(microseconds: 500).inMilliseconds == 0: the truncation lands
        // on canon's config-default sentinel, so refusing only Duration.zero
        // would leave the silent substitution reachable through a value the
        // caller believes is a real, positive timeout.
        expect(
          () => sessionB.get(
            'zenoh/dart/test/s1/submilli',
            timeout: const Duration(microseconds: 500),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('timeout'),
            ),
          ),
        );
      },
    );
  });
}
