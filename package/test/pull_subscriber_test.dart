import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('PullSubscriber lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declarePullSubscriber returns a PullSubscriber', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull');
      expect(pullSub, isA<PullSubscriber>());
      pullSub.close();
    });

    test('PullSubscriber.keyExpr returns declared key expression', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull/ke');
      expect(pullSub.keyExpr, equals('demo/example/pull/ke'));
      pullSub.close();
    });

    test('tryRecv returns null when buffer is empty', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull/empty');
      addTearDown(pullSub.close);

      final sample = pullSub.tryRecv();
      expect(sample, isNull);
    });

    test('PullSubscriber.close is idempotent', () {
      final pullSub = session.declarePullSubscriber(
        'demo/example/pull/idempotent',
      );
      pullSub.close();
      expect(() => pullSub.close(), returnsNormally);
    });

    test('tryRecv on closed PullSubscriber throws StateError', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull/closed');
      pullSub.close();
      expect(() => pullSub.tryRecv(), throwsA(isA<StateError>()));
    });
  });

  group('Ring buffer lossy behavior (TCP 17481)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17481"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17481"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('ring buffer drops oldest when full (capacity 3)', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/lossy',
        capacity: 3,
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Publish 10 messages rapidly
      for (var i = 0; i < 10; i++) {
        session1.put('zenoh/dart/test/pull/lossy', 'msg-$i');
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Drain the ring buffer
      final samples = <Sample>[];
      for (var i = 0; i < 20; i++) {
        final s = pullSub.tryRecv();
        if (s == null) break;
        samples.add(s);
      }

      // Ring buffer capacity is 3, so at most 3 samples retained
      expect(samples.length, lessThanOrEqualTo(3));
      expect(samples, isNotEmpty);

      // The retained samples should be among the most recent
      for (final s in samples) {
        final msgNum = int.parse(s.payload.replaceFirst('msg-', ''));
        expect(
          msgNum,
          greaterThanOrEqualTo(7),
          reason: 'Expected recent messages (7-9), got msg-$msgNum',
        );
      }
    });

    test('ring buffer capacity 1 keeps only latest', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/cap1',
        capacity: 1,
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/cap1', 'first');
      session1.put('zenoh/dart/test/pull/cap1', 'second');
      session1.put('zenoh/dart/test/pull/cap1', 'third');

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      // With capacity 1, only the latest should remain
      expect(sample!.payload, equals('third'));

      // Next tryRecv should return null
      expect(pullSub.tryRecv(), isNull);
    });

    test('tryRecv returns binary payload faithfully', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/binary-rt',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final binary = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      session1.putBytes(
        'zenoh/dart/test/pull/binary-rt',
        ZBytes.fromUint8List(binary),
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.payloadBytes, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      expect(sample.payload, contains('\u{FFFD}'));
    });

    test('tryRecv returns binary attachment byte-exact', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/binary-att',
      );
      addTearDown(pullSub.close);

      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/binary-att',
      );
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.putBytes(
        ZBytes.fromString('valid payload'),
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        ),
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.payloadBytes, equals(utf8.encode('valid payload')));
      // Byte-exact recovery of the invalid-UTF-8 attachment (no U+FFFD).
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('tryRecv reports present-but-empty attachment as non-null empty',
        () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/empty-att',
      );
      addTearDown(pullSub.close);

      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/empty-att',
      );
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Present but zero-length attachment.
      publisher.putBytes(
        ZBytes.fromString('payload'),
        attachment: ZBytes.fromUint8List(Uint8List(0)),
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      // Empty (non-null) is distinct from absent (null) -- conflation fixed.
      expect(sample!.attachmentBytes, isNotNull);
      expect(sample.attachmentBytes, hasLength(0));
    });

    test('tryRecv reports absent attachment as null', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/no-att',
      );
      addTearDown(pullSub.close);

      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/no-att',
      );
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // No attachment argument at all.
      publisher.putBytes(ZBytes.fromString('payload'));

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.attachmentBytes, isNull);
      expect(sample.attachment, isNull);
    });

    // Edge case "tryRecv on empty buffer still returns null" is covered by
    // the existing test 'tryRecv returns null when buffer is empty' in the
    // PullSubscriber lifecycle group above.

    test('DELETE samples received through ring buffer', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/del',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.deleteResource('zenoh/dart/test/pull/del');

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.kind, equals(SampleKind.delete));
    });
  });

  group('Lifecycle and error handling (TCP 17482)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17482"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17482"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('PullSubscriber.close is idempotent', () {
      final pullSub = session1.declarePullSubscriber(
        'zenoh/dart/test/pull/idem2',
      );
      pullSub.close();
      expect(() => pullSub.close(), returnsNormally);
    });

    test('tryRecv after close throws StateError', () {
      final pullSub = session1.declarePullSubscriber(
        'zenoh/dart/test/pull/closed2',
      );
      pullSub.close();
      expect(
        () => pullSub.tryRecv(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('declarePullSubscriber on closed session throws StateError', () {
      final tempConfig = Config();
      final tempSession = Session.open(config: tempConfig);
      tempSession.close();
      expect(
        () => tempSession.declarePullSubscriber('zenoh/dart/test/pull/x'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('invalid keyexpr throws ZenohException', () {
      expect(
        () => session1.declarePullSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('wildcard key expression matches published sub-keys', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/wild/**',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/wild/a', 'alpha');
      session1.put('zenoh/dart/test/pull/wild/b', 'beta');

      await Future<void>.delayed(const Duration(seconds: 1));

      final samples = <Sample>[];
      for (var i = 0; i < 10; i++) {
        final s = pullSub.tryRecv();
        if (s == null) break;
        samples.add(s);
      }

      expect(samples, hasLength(2));

      final keyExprs = samples.map((s) => s.keyExpr).toSet();
      expect(keyExprs, contains('zenoh/dart/test/pull/wild/a'));
      expect(keyExprs, contains('zenoh/dart/test/pull/wild/b'));

      final payloads = samples.map((s) => s.payload).toSet();
      expect(payloads, contains('alpha'));
      expect(payloads, contains('beta'));
    });
  });

  group('PullSubscriber integration (two sessions, TCP 17480)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17480"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17480"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('basic pull receives sample', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/basic',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/basic', 'hello pull');

      // Give time for the sample to arrive in the ring buffer
      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.keyExpr, equals('zenoh/dart/test/pull/basic'));
      expect(sample.payload, equals('hello pull'));
      expect(sample.kind, equals(SampleKind.put));
    });

    test('sample fields correct (payloadBytes, encoding)', () async {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/enc',
        encoding: Encoding.textPlain,
      );
      addTearDown(publisher.close);

      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/enc',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('encoded data');

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.payload, equals('encoded data'));
      expect(sample.payloadBytes, isNotEmpty);
      // Encoding should be present
      expect(sample.encoding, isNotNull);
    });

    test('multiple tryRecv drains buffer', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/multi',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/multi', 'msg1');
      session1.put('zenoh/dart/test/pull/multi', 'msg2');
      session1.put('zenoh/dart/test/pull/multi', 'msg3');

      await Future<void>.delayed(const Duration(seconds: 1));

      final samples = <Sample>[];
      for (var i = 0; i < 4; i++) {
        final s = pullSub.tryRecv();
        if (s == null) break;
        samples.add(s);
      }

      expect(samples, hasLength(3));
      expect(samples[0].payload, equals('msg1'));
      expect(samples[1].payload, equals('msg2'));
      expect(samples[2].payload, equals('msg3'));

      // 4th tryRecv should return null
      expect(pullSub.tryRecv(), isNull);
    });
  });
}
