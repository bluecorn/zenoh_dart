import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/src/bytes.dart';
import 'package:zenoh/src/config.dart';
import 'package:zenoh/src/encoding.dart';
import 'package:zenoh/src/exceptions.dart';
import 'package:zenoh/src/id.dart';
import 'package:zenoh/src/session.dart';

void main() {
  group('Session lifecycle', () {
    test('open session with default config', () {
      final session = Session.open();
      expect(session, isA<Session>());
      session.close();
    });

    test('open session with explicit config', () {
      final config = Config();
      config.insertJson5('mode', '"peer"');

      final session = Session.open(config: config);
      expect(session, isA<Session>());

      // Verify config is consumed by checking that further use throws
      expect(
        () => config.insertJson5('mode', '"peer"'),
        throwsA(isA<StateError>()),
      );

      session.close();
    });

    test('close session gracefully', () {
      final session = Session.open();
      expect(() => session.close(), returnsNormally);
    });

    test('close session is idempotent (double-close safe)', () {
      final session = Session.open();
      session.close();
      expect(() => session.close(), returnsNormally);
    });

    test('reusing consumed Config throws StateError', () {
      final config = Config();
      final session = Session.open(config: config);

      expect(
        () => config.insertJson5('mode', '"peer"'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );

      session.close();
    });
  });

  group('Session operations', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('session remains usable across tests', () {
      // Session opened in setUpAll is still valid
      expect(session, isA<Session>());
    });
  });

  group('Put and delete operations', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('put succeeds with valid key expression', () {
      expect(() => session.put('demo/example/test', 'hello'), returnsNormally);
    });

    test('putBytes succeeds and consumes the payload', () {
      final payload = ZBytes.fromString('hello bytes');
      session.putBytes('demo/example/test', payload);
      // Payload should be consumed -- toStr() should throw
      expect(
        () => payload.toStr(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test('put with invalid key expression throws ZenohException', () {
      expect(() => session.put('', 'hello'), throwsA(isA<ZenohException>()));
    });

    test('putBytes with already-disposed ZBytes throws StateError', () {
      final payload = ZBytes.fromString('disposable');
      payload.dispose();
      expect(
        () => session.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    test('putBytes with already-consumed ZBytes throws StateError', () {
      final payload = ZBytes.fromString('consume me');
      session.putBytes('demo/example/test', payload);
      expect(
        () => session.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test('put on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.put('demo/example/test', 'hello'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('putBytes on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      final payload = ZBytes.fromString('hello');
      expect(
        () => closedSession.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      payload.dispose();
    });

    test('deleteResource succeeds with valid key expression', () {
      expect(
        () => session.deleteResource('demo/example/test'),
        returnsNormally,
      );
    });

    test('deleteResource on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.deleteResource('demo/example/test'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('deleteResource on non-existent key succeeds', () {
      // fire-and-forget semantics -- no error even if no data published
      expect(
        () => session.deleteResource('demo/example/nonexistent'),
        returnsNormally,
      );
    });

    test(
      'deleteResource with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.deleteResource(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  });

  group('Session info', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('zid returns non-zero ZenohId with 16 bytes', () {
      final zid = session.zid;
      expect(zid, isA<ZenohId>());
      expect(zid.bytes.length, equals(16));
      // At least one byte should be non-zero
      expect(zid.bytes.any((b) => b != 0), isTrue);
    });

    test('zid is consistent across multiple accesses', () {
      final zid1 = session.zid;
      final zid2 = session.zid;
      expect(zid1, equals(zid2));
    });

    test('zid.toHexString returns non-empty hex string', () {
      final zid = session.zid;
      final hex = zid.toHexString();
      expect(hex, isNotEmpty);
      // Should be 32 hex chars (16 bytes * 2 chars each)
      expect(hex.length, equals(32));
      // Should only contain hex characters
      expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('zid on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.zid,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('routersZid returns a list', () {
      final result = session.routersZid();
      expect(result, isA<List<ZenohId>>());
    });

    test('peersZid returns a list', () {
      final result = session.peersZid();
      expect(result, isA<List<ZenohId>>());
    });

    test('routersZid on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.routersZid(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('peersZid on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.peersZid(),
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

  group('Session peer discovery', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17460"]');
      session1 = Session.open(config: config1);

      // Wait for listener to bind
      await Future.delayed(Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17460"]');
      session2 = Session.open(config: config2);

      // Wait for link establishment
      await Future.delayed(Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('two connected sessions see each other as peers', () {
      final peers1 = session1.peersZid();
      final peers2 = session2.peersZid();

      expect(
        peers1.contains(session2.zid),
        isTrue,
        reason: 'session1 should see session2 as a peer',
      );
      expect(
        peers2.contains(session1.zid),
        isTrue,
        reason: 'session2 should see session1 as a peer',
      );
    });

    test('two connected sessions have different ZIDs', () {
      expect(session1.zid, isNot(equals(session2.zid)));
    });
  });

  group('Session put attachment + encoding (send)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17470"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17470"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('putBytes delivers binary attachment byte-exact', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/bin-att');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final payload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      session1.putBytes(
        'zenoh/dart/put/bin-att',
        ZBytes.fromUint8List(payload),
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        ),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(payload));
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('put sets encoding received faithfully', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/enc');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(
        'zenoh/dart/put/enc',
        'hello',
        encoding: Encoding.applicationJson,
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.encoding, equals('application/json'));
    });

    test('valid custom encoding round-trips faithfully', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/enc-custom');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(
        'zenoh/dart/put/enc-custom',
        'hello',
        encoding: const Encoding('application/vnd.dart.test'),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // No silent substitution: the custom MIME survives the rc-checked path.
      expect(sample.encoding, contains('application/vnd.dart.test'));
    });

    test('putBytes marks attachment consumed on success', () {
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      session1.putBytes(
        'zenoh/dart/put/consume',
        ZBytes.fromString('payload'),
        attachment: attachment,
      );
      // Attachment ownership moved to zenoh-c -- use-after-move must throw.
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

    test('putBytes on invalid keyexpr is a pre-move early-return '
        '(attachment NOT consumed, caller retains ownership)', () {
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      // An invalid key expression fails in the KeyExpr constructor BEFORE
      // zd_put runs, so z_bytes_move never gravestones the attachment.
      // Per the markConsumed discipline, a genuine pre-move early-return
      // must NOT mark consumed -- the caller still owns the ZBytes.
      expect(
        () => session1.putBytes(
          '',
          ZBytes.fromString('payload'),
          attachment: attachment,
        ),
        throwsA(isA<ZenohException>()),
      );
      // Still owned: reading and disposing it must succeed (no use-after-move).
      expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));
      attachment.dispose();
    });

    test('absent attachment/encoding behaves as before', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/absent');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/put/absent', 'plain');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(utf8.encode('plain')));
      expect(sample.attachmentBytes, isNull);
      // Default encoding still present (existing behavior unchanged).
      expect(sample.encoding, isNotNull);
    });
  });
}
