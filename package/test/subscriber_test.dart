import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/src/bytes.dart';
import 'package:zenoh/src/bytes_writer.dart';
import 'package:zenoh/src/config.dart';
import 'package:zenoh/src/exceptions.dart';
import 'package:zenoh/src/sample.dart';
import 'package:zenoh/src/session.dart';
import 'package:zenoh/src/subscriber.dart';

void main() {
  group('SampleKind', () {
    test('has put and delete values that are distinct', () {
      expect(SampleKind.put, isNotNull);
      expect(SampleKind.delete, isNotNull);
      expect(SampleKind.put, isNot(equals(SampleKind.delete)));
    });
  });

  group('Sample', () {
    test('roundtrips all fields including nullable attachment', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
        attachment: 'metadata',
      );
      expect(sample.keyExpr, equals('demo/test'));
      expect(sample.payload, equals('hello'));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.attachment, equals('metadata'));

      final sampleNoAttachment = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
      );
      expect(sampleNoAttachment.attachment, isNull);
    });

    test('accepts optional encoding parameter', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
        encoding: 'text/plain',
      );
      expect(sample.encoding, equals('text/plain'));
    });

    test('defaults encoding to null', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
      );
      expect(sample.encoding, isNull);
    });
  });

  group('Sample payloadBytes', () {
    test('Sample constructor accepts payloadBytes parameter', () {
      final bytes = Uint8List.fromList([104, 101, 108, 108, 111]);
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: bytes,
        kind: SampleKind.put,
      );
      expect(sample.payloadBytes, equals([104, 101, 108, 108, 111]));
      expect(sample.payload, equals('hello'));
    });

    test('Sample payloadBytes is independent of payload string', () {
      final bytes = Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01]);
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: '',
        payloadBytes: bytes,
        kind: SampleKind.put,
      );
      expect(sample.payloadBytes, equals([0xFF, 0xFE, 0x00, 0x01]));
      expect(sample.payload, equals(''));
    });

    test('Sample payloadBytes with empty payload', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: '',
        payloadBytes: Uint8List(0),
        kind: SampleKind.put,
      );
      expect(sample.payloadBytes, hasLength(0));
      expect(sample.payload, equals(''));
    });
  });

  group('Subscriber lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareSubscriber returns a Subscriber on valid key expression', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      expect(subscriber, isA<Subscriber>());
      subscriber.close();
    });

    test('Subscriber.close completes without error', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      expect(() => subscriber.close(), returnsNormally);
    });

    test('Subscriber.close is idempotent (double-close safe)', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      subscriber.close();
      expect(() => subscriber.close(), returnsNormally);
    });

    test('declareSubscriber on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declareSubscriber('demo/example/test'),
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
      'declareSubscriber with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareSubscriber(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  });

  group('Subscriber integration (NativePort bridge)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Sessions must be explicitly connected via TCP for same-process
      // peer-to-peer routing (multicast scouting doesn't work within
      // a single process).
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17448"]');
      session1 = Session.open(config: config1);

      // Small delay to let session1's listener bind
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17448"]');
      session2 = Session.open(config: config2);

      // Allow session link establishment
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('receives PUT sample from session.put on same key', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/sub');
      addTearDown(subscriber.close);

      // Allow routing propagation
      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/sub', 'hello world');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.keyExpr, equals('zenoh/dart/test/sub'));
      expect(sample.payload, equals('hello world'));
      expect(sample.kind, equals(SampleKind.put));
    });

    test('receives multiple PUT samples in order', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/multi');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/multi', 'first');
      session1.put('zenoh/dart/test/multi', 'second');
      session1.put('zenoh/dart/test/multi', 'third');

      final samples = await subscriber.stream
          .take(3)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(samples, hasLength(3));
      expect(samples[0].payload, equals('first'));
      expect(samples[1].payload, equals('second'));
      expect(samples[2].payload, equals('third'));
    });

    test('receives samples matching wildcard key expression', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/wild/**');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/wild/a', 'alpha');
      session1.put('zenoh/dart/test/wild/b', 'beta');

      final samples = await subscriber.stream
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(samples, hasLength(2));
      final keyExprs = samples.map((s) => s.keyExpr).toSet();
      expect(keyExprs, contains('zenoh/dart/test/wild/a'));
      expect(keyExprs, contains('zenoh/dart/test/wild/b'));
    });

    test('stream does not emit for non-matching key expressions', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/specific');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/other', 'unrelated');

      // Wait a bit and verify no samples arrive
      await expectLater(
        subscriber.stream.first.timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('receives encoding from published data', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/enc');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/enc', 'hello');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // Session.put uses default encoding; verify encoding field is populated
      expect(sample.encoding, isNotNull);
      expect(sample.keyExpr, equals('zenoh/dart/test/enc'));
      expect(sample.payload, equals('hello'));
      expect(sample.kind, equals(SampleKind.put));
    });

    test('receives DELETE sample from session.deleteResource', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/del');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.deleteResource('zenoh/dart/test/del');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.keyExpr, equals('zenoh/dart/test/del'));
      expect(sample.kind, equals(SampleKind.delete));
    });
  });

  group('Subscriber stream close behavior', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Use port 17449 to avoid conflicts with the integration group above
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17449"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17449"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('stream closes when subscriber is closed', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/close1');

      final doneCompleter = Completer<void>();
      subscriber.stream.listen((_) {}, onDone: () => doneCompleter.complete());

      subscriber.close();

      // The done callback should fire within a reasonable time
      await doneCompleter.future.timeout(const Duration(seconds: 5));
    });

    test(
      'stream closes after receiving samples when subscriber is closed',
      () async {
        final subscriber = session2.declareSubscriber('zenoh/dart/test/close2');

        await Future<void>.delayed(const Duration(seconds: 1));

        // Set up a single subscription that tracks both samples and done
        final samples = <Sample>[];
        final doneCompleter = Completer<void>();
        subscriber.stream.listen(
          samples.add,
          onDone: () => doneCompleter.complete(),
        );

        // Send a sample first
        session1.put('zenoh/dart/test/close2', 'before close');

        // Wait for the sample to arrive
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(samples, isNotEmpty);
        expect(samples.first.payload, equals('before close'));
        expect(samples.first.kind, equals(SampleKind.put));

        // Now close and verify stream completes
        subscriber.close();

        await doneCompleter.future.timeout(const Duration(seconds: 5));
      },
    );

    test('closing subscriber before any samples emits zero events', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/close3');

      final samples = <Sample>[];
      final doneCompleter = Completer<void>();
      subscriber.stream.listen(
        samples.add,
        onDone: () => doneCompleter.complete(),
      );

      // Close immediately without sending any puts
      subscriber.close();

      await doneCompleter.future.timeout(const Duration(seconds: 5));
      expect(samples, isEmpty);
    });
  });

  group('Multiple subscribers', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Use port 17450 to avoid conflicts with other test groups
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17450"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17450"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('multiple subscribers on same key each receive all samples', () async {
      final sub1 = session2.declareSubscriber('zenoh/dart/test/multi-sub');
      addTearDown(sub1.close);
      final sub2 = session2.declareSubscriber('zenoh/dart/test/multi-sub');
      addTearDown(sub2.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/multi-sub', 'broadcast');

      final sample1 = await sub1.stream.first.timeout(
        const Duration(seconds: 5),
      );
      final sample2 = await sub2.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample1.payload, equals('broadcast'));
      expect(sample2.payload, equals('broadcast'));
    });

    test(
      'multiple subscribers on different keys receive only their matching samples',
      () async {
        final subA = session2.declareSubscriber('zenoh/dart/test/a');
        addTearDown(subA.close);
        final subB = session2.declareSubscriber('zenoh/dart/test/b');
        addTearDown(subB.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put('zenoh/dart/test/a', 'for-a');
        session1.put('zenoh/dart/test/b', 'for-b');

        final sampleA = await subA.stream.first.timeout(
          const Duration(seconds: 5),
        );
        final sampleB = await subB.stream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(sampleA.payload, equals('for-a'));
        expect(sampleB.payload, equals('for-b'));
      },
    );

    test('closing one subscriber does not affect another', () async {
      final sub1 = session2.declareSubscriber('zenoh/dart/test/independent');
      final sub2 = session2.declareSubscriber('zenoh/dart/test/independent');
      addTearDown(sub2.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Close sub1 first
      sub1.close();

      // Verify sub1's stream is done
      final doneCompleter = Completer<void>();
      sub1.stream.listen((_) {}, onDone: () => doneCompleter.complete());
      await doneCompleter.future.timeout(const Duration(seconds: 5));

      // Now put a sample -- sub2 should still receive it
      session1.put('zenoh/dart/test/independent', 'after-close');

      final sample = await sub2.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payload, equals('after-close'));
    });
  });

  group('Subscriber payloadBytes E2E', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17451"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17451"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('delivers payloadBytes matching published string', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/payload-bytes',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/payload-bytes', 'hello world');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payload, equals('hello world'));
      expect(sample.payloadBytes, equals(utf8.encode('hello world')));
    });

    test('delivers invalid-UTF-8 binary payload faithfully', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/binary-rt',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final binary = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      session1.putBytes(
        'zenoh/dart/test/binary-rt',
        ZBytes.fromUint8List(binary),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      expect(sample.payload, contains('\u{FFFD}'));
    });

    test('delivers float64-LE payload faithfully', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/float64-le',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final byteData = ByteData(8)..setFloat64(0, 0.25, Endian.little);
      final binary = byteData.buffer.asUint8List();
      session1.putBytes(
        'zenoh/dart/test/float64-le',
        ZBytes.fromUint8List(binary),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(binary));
      final received = ByteData.sublistView(sample.payloadBytes);
      expect(received.getFloat64(0, Endian.little), equals(0.25));
    });

    test('binary attachment does not drop the carrying sample', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/binary-att',
      );
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher('zenoh/dart/test/binary-att');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.putBytes(
        ZBytes.fromString('valid payload'),
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        ),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(utf8.encode('valid payload')));
      expect(sample.attachment, isNotNull);
      expect(sample.attachment, contains('\u{FFFD}'));
    });

    test(
      'multi-fragment binary payload delivers flattened and exact',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/binary-frag',
        );
        addTearDown(subscriber.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        final writer = ZBytesWriter();
        writer.writeAll(Uint8List.fromList([0xFF, 0xFE]));
        writer.writeAll(Uint8List.fromList([0x80, 0x41]));
        final fragmented = writer.finish();

        session1.putBytes('zenoh/dart/test/binary-frag', fragmented);

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(sample.payloadBytes, equals([0xFF, 0xFE, 0x80, 0x41]));
      },
    );

    test('empty ZBytes payload still delivers', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/binary-empty',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.putBytes(
        'zenoh/dart/test/binary-empty',
        ZBytes.fromUint8List(Uint8List(0)),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, hasLength(0));
      expect(sample.payload, equals(''));
    });

    test('delivers empty payloadBytes for delete samples', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/del-bytes',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.deleteResource('zenoh/dart/test/del-bytes');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.kind, equals(SampleKind.delete));
      expect(sample.payloadBytes, hasLength(0));
      expect(sample.payload, equals(''));
    });

    test('payloadBytes and payload coexist across multiple samples', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/multi-bytes',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/multi-bytes', 'first');
      session1.put('zenoh/dart/test/multi-bytes', 'second');

      final samples = await subscriber.stream
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(samples, hasLength(2));
      expect(samples[0].payload, equals('first'));
      expect(samples[0].payloadBytes, equals(utf8.encode('first')));
      expect(samples[1].payload, equals('second'));
      expect(samples[1].payloadBytes, equals(utf8.encode('second')));
    });
  });

  // Background subscriber tests - no handle, lives until session closes
  group('Background Subscriber (TCP 17512-17514)', () {
    group('basic operations (TCP 17512)', () {
      late Session session1;
      late Session session2;

      setUpAll(() async {
        final config1 = Config();
        config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17512"]');
        session1 = Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config();
        config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17512"]');
        session2 = Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        session1.close();
        session2.close();
      });

      test('receives PUT sample', () async {
        final stream = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-put',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put('zenoh/dart/test/bg-put', 'bg-hello');

        final sample = await stream.first.timeout(const Duration(seconds: 5));

        expect(sample.keyExpr, equals('zenoh/dart/test/bg-put'));
        expect(sample.payload, equals('bg-hello'));
        expect(sample.kind, equals(SampleKind.put));
      });

      test('receives multiple samples in order', () async {
        final stream = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-multi',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put('zenoh/dart/test/bg-multi', 'first');
        session1.put('zenoh/dart/test/bg-multi', 'second');
        session1.put('zenoh/dart/test/bg-multi', 'third');

        final samples = await stream
            .take(3)
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(samples, hasLength(3));
        expect(samples[0].payload, equals('first'));
        expect(samples[1].payload, equals('second'));
        expect(samples[2].payload, equals('third'));
      });

      test('delivers invalid-UTF-8 binary payload faithfully', () async {
        final stream = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-binary',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        final binary = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
        session1.putBytes(
          'zenoh/dart/test/bg-binary',
          ZBytes.fromUint8List(binary),
        );

        final sample = await stream.first.timeout(const Duration(seconds: 5));

        expect(sample.payloadBytes, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
        expect(sample.payload, contains('\u{FFFD}'));
      });

      test('receives wildcard-matched samples', () async {
        final stream = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-wild/**',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put('zenoh/dart/test/bg-wild/a', 'alpha');
        session1.put('zenoh/dart/test/bg-wild/b', 'beta');

        final samples = await stream
            .take(2)
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(samples, hasLength(2));
        final keyExprs = samples.map((s) => s.keyExpr).toSet();
        expect(keyExprs, contains('zenoh/dart/test/bg-wild/a'));
        expect(keyExprs, contains('zenoh/dart/test/bg-wild/b'));
      });
    });

    test('on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declareBackgroundSubscriber('demo/example/test'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('with invalid keyexpr throws ZenohException', () {
      final session = Session.open();
      addTearDown(session.close);
      expect(
        () => session.declareBackgroundSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });

    group('stream closes on session close (TCP 17513)', () {
      test('stream onDone fires when session closes', () async {
        final config1 = Config();
        config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17513"]');
        final s1 = Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config();
        config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17513"]');
        final s2 = Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        final stream = s2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-close',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        // Send a sample to confirm the subscriber works
        s1.put('zenoh/dart/test/bg-close', 'before-close');

        final doneCompleter = Completer<void>();
        final samples = <Sample>[];
        stream.listen(samples.add, onDone: () => doneCompleter.complete());

        // Wait for sample to arrive
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(samples, isNotEmpty);

        // Close subscriber's session -- stream should complete
        s2.close();
        s1.close();

        await doneCompleter.future.timeout(const Duration(seconds: 5));
      });
    });

    group('multiple background subscribers (TCP 17514)', () {
      late Session session1;
      late Session session2;

      setUpAll(() async {
        final config1 = Config();
        config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17514"]');
        session1 = Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config();
        config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17514"]');
        session2 = Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        session1.close();
        session2.close();
      });

      test('two bg subscribers on same key both receive sample', () async {
        final stream1 = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-dual',
        );
        final stream2 = session2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-dual',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put('zenoh/dart/test/bg-dual', 'for-both');

        final sample1 = await stream1.first.timeout(const Duration(seconds: 5));
        final sample2 = await stream2.first.timeout(const Duration(seconds: 5));

        expect(sample1.payload, equals('for-both'));
        expect(sample2.payload, equals('for-both'));
      });
    });
  });
}
