import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('AdvancedSubscriber', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('timestamping/enabled', 'true');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test('declareAdvancedSubscriber returns an AdvancedSubscriber', () {
      final subscriber = session.declareAdvancedSubscriber(
        'demo/example/adv-sub',
      );
      expect(subscriber, isA<AdvancedSubscriber>());
      subscriber.close();
    });

    test('AdvancedSubscriber.stream is a Stream of Sample', () {
      final subscriber = session.declareAdvancedSubscriber(
        'demo/example/adv-sub',
      );
      addTearDown(subscriber.close);
      expect(subscriber.stream, isA<Stream<Sample>>());
      expect(subscriber.stream, isNotNull);
    });

    test('AdvancedSubscriber.close completes without error', () {
      final subscriber = session.declareAdvancedSubscriber(
        'demo/example/adv-sub',
      );
      expect(() => subscriber.close(), returnsNormally);
    });

    test('AdvancedSubscriber.close is idempotent', () {
      final subscriber = session.declareAdvancedSubscriber(
        'demo/example/adv-sub',
      );
      subscriber.close();
      expect(() => subscriber.close(), returnsNormally);
    });

    test('declareAdvancedSubscriber on closed session throws StateError', () {
      final closedConfig = Config();
      closedConfig.insertJson5('timestamping/enabled', 'true');
      final closedSession = Session.open(config: closedConfig);
      closedSession.close();
      expect(
        () => closedSession.declareAdvancedSubscriber('demo/example/adv-sub'),
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
      'AdvancedSubscriber.missEvents is null when miss listener not enabled',
      () {
        final subscriber = session.declareAdvancedSubscriber(
          'demo/example/adv-sub',
        );
        addTearDown(subscriber.close);
        expect(subscriber.missEvents, isNull);
      },
    );

    test(
      'declareAdvancedSubscriber with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareAdvancedSubscriber(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  }); // AdvancedSubscriber group

  group('AdvancedSubscriber Integration (TCP 17520-17523, 17525)', () {
    // --- Tests 1 & 2: live pub/sub and delete (port 17520) ---
    group('live pub/sub (port 17520)', () {
      late Session session1;
      late Session session2;

      setUpAll(() async {
        final config1 = Config();
        config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17520"]');
        config1.insertJson5('timestamping/enabled', 'true');
        session1 = Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config();
        config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17520"]');
        session2 = Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        session1.close();
        session2.close();
      });

      test('AdvancedPublisher put received by AdvancedSubscriber', () async {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/put',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
            sampleMissDetection: true,
          ),
        );
        addTearDown(publisher.close);

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/put',
        );
        addTearDown(subscriber.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put('live message');

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.payload, equals('live message'));
        expect(sample.kind, equals(SampleKind.put));
      });

      test(
        'AdvancedPublisher deleteResource received by AdvancedSubscriber',
        () async {
          final publisher = session1.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/del',
            options: AdvancedPublisherOptions(
              cacheMaxSamples: 5,
              publisherDetection: true,
              sampleMissDetection: true,
            ),
          );
          addTearDown(publisher.close);

          final subscriber = session2.declareAdvancedSubscriber(
            'zenoh/dart/test/adv-int/del',
          );
          addTearDown(subscriber.close);

          await Future<void>.delayed(const Duration(seconds: 1));

          publisher.deleteResource();

          final sample = await subscriber.stream.first.timeout(
            const Duration(seconds: 5),
          );
          expect(sample.kind, equals(SampleKind.delete));
        },
      );
    });

    // --- Test 3: history recovery (port 17521) ---
    test('AdvancedSubscriber with history receives cached samples', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17521"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17521"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/history',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 6,
            publisherDetection: true,
            sampleMissDetection: true,
          ),
        );

        // Publish BEFORE subscriber
        publisher.put('cached_1');
        publisher.put('cached_2');
        publisher.put('cached_3');

        // Wait for cache to settle
        await Future<void>.delayed(const Duration(seconds: 2));

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/history',
          options: AdvancedSubscriberOptions(
            history: true,
            detectLatePublishers: true,
            recovery: true,
            lastSampleMissDetection: true,
            subscriberDetection: true,
          ),
        );

        final samples = await subscriber.stream
            .take(3)
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(samples.length, greaterThanOrEqualTo(3));
        final payloads = samples.map((s) => s.payload).toList();
        expect(payloads, contains('cached_1'));
        expect(payloads, contains('cached_2'));
        expect(payloads, contains('cached_3'));

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });

    // --- Test 4: cached + live ordering (port 17522) ---
    test('AdvancedSubscriber with history receives cached then live', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17522"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17522"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/order',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 10,
            publisherDetection: true,
            sampleMissDetection: true,
          ),
        );

        // Publish 3 samples BEFORE subscriber
        publisher.put('value_1');
        publisher.put('value_2');
        publisher.put('value_3');

        await Future<void>.delayed(const Duration(seconds: 2));

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/order',
          options: AdvancedSubscriberOptions(
            history: true,
            detectLatePublishers: true,
            recovery: true,
            lastSampleMissDetection: true,
            subscriberDetection: true,
          ),
        );

        // Wait a bit for history recovery before publishing live samples
        await Future<void>.delayed(const Duration(seconds: 2));

        // Publish 3 more AFTER subscriber
        publisher.put('value_4');
        publisher.put('value_5');
        publisher.put('value_6');

        final samples = await subscriber.stream
            .take(6)
            .toList()
            .timeout(const Duration(seconds: 10));

        final payloads = samples.map((s) => s.payload).toSet();
        expect(
          payloads,
          containsAll([
            'value_1',
            'value_2',
            'value_3',
            'value_4',
            'value_5',
            'value_6',
          ]),
        );

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });

    // --- Test 5: putBytes (port 17523) ---
    test('AdvancedPublisher putBytes received by AdvancedSubscriber', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17523"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17523"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/bytes',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
          ),
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/bytes',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.putBytes(ZBytes.fromString('binary data'));

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.payload, equals('binary data'));

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });
    // --- Test 6: binary payload delivery (port 17525) ---
    test('AdvancedPublisher binary putBytes delivered faithfully', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17525"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17525"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/binary',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
          ),
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/binary',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        final binary = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
        publisher.putBytes(ZBytes.fromUint8List(binary));

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.payloadBytes, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });
    // --- Slice 4: attachment + encoding (send) ---
    // Test 1: binary attachment byte-exact (port 17526)
    test('AdvancedPublisher putBytes delivers binary attachment byte-exact',
        () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17526"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17526"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/att-bin',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
          ),
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/att-bin',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.putBytes(
          ZBytes.fromString('payload'),
          attachment: ZBytes.fromUint8List(
            Uint8List.fromList([0xFF, 0xFE, 0x80]),
          ),
        );

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });

    // Test 2: encoding received faithfully (port 17527)
    test('AdvancedPublisher put encoding received faithfully', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17527"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17527"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/enc',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
          ),
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/enc',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put(
          'octet payload',
          encoding: Encoding.applicationOctetStream,
        );

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.encoding, equals('application/octet-stream'));

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });

    // Test 3 (Edge): empty vs absent advanced attachment (port 17528)
    test('AdvancedPublisher empty attachment differs from absent', () async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17528"]');
      config1.insertJson5('timestamping/enabled', 'true');
      final session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17528"]');
      final session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));

      try {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/empty-absent',
          options: AdvancedPublisherOptions(
            cacheMaxSamples: 5,
            publisherDetection: true,
          ),
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/test/adv-int/empty-absent',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        final samples = <Sample>[];
        final sub = subscriber.stream.listen(samples.add);

        // First: empty attachment (non-null, zero length).
        publisher.putBytes(
          ZBytes.fromString('with-empty'),
          attachment: ZBytes.fromUint8List(Uint8List(0)),
        );

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Second: no attachment at all.
        publisher.putBytes(ZBytes.fromString('no-attachment'));

        await Future<void>.delayed(const Duration(seconds: 1));
        await sub.cancel();

        final empty = samples.firstWhere(
          (s) => s.payload == 'with-empty',
        );
        final absent = samples.firstWhere(
          (s) => s.payload == 'no-attachment',
        );

        // Empty -> non-null empty; absent -> null.
        expect(empty.attachmentBytes, isNotNull);
        expect(empty.attachmentBytes, isEmpty);
        expect(absent.attachmentBytes, isNull);

        subscriber.close();
        publisher.close();
      } finally {
        session1.close();
        session2.close();
      }
    });

    // Test 4 (Edge): attachment consumed on any rc (no network needed).
    test('AdvancedPublisher putBytes marks attachment consumed', () {
      final config = Config();
      config.insertJson5('timestamping/enabled', 'true');
      final s = Session.open(config: config);
      try {
        final publisher = s.declareAdvancedPublisher(
          'zenoh/dart/test/adv-int/consume',
          options: AdvancedPublisherOptions(publisherDetection: true),
        );
        final attachment = ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        );
        publisher.putBytes(
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
        publisher.close();
      } finally {
        s.close();
      }
    });
  }); // AdvancedSubscriber Integration group

  group('Miss Listener', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('timestamping/enabled', 'true');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test(
      'AdvancedSubscriber with enableMissListener has non-null missEvents stream',
      () {
        final subscriber = session.declareAdvancedSubscriber(
          'demo/example/adv-miss',
          options: AdvancedSubscriberOptions(
            enableMissListener: true,
            recovery: true,
            lastSampleMissDetection: true,
          ),
        );
        addTearDown(subscriber.close);

        expect(subscriber.missEvents, isNotNull);
        expect(subscriber.missEvents, isA<Stream<MissEvent>>());
      },
    );

    test('MissEvent has sourceId and count fields', () {
      final zid = ZenohId(Uint8List(16));
      final event = MissEvent(sourceId: zid, count: 3);

      expect(event.sourceId, equals(zid));
      expect(event.count, equals(3));
    });

    test(
      'AdvancedSubscriber with all options including miss listener declares successfully',
      () async {
        final config1 = Config();
        config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17524"]');
        config1.insertJson5('timestamping/enabled', 'true');
        final session1 = Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config();
        config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17524"]');
        final session2 = Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        try {
          final subscriber = session2.declareAdvancedSubscriber(
            'demo/example/adv-miss-all',
            options: AdvancedSubscriberOptions(
              history: true,
              detectLatePublishers: true,
              recovery: true,
              lastSampleMissDetection: true,
              periodicQueriesPeriodMs: 1000,
              subscriberDetection: true,
              enableMissListener: true,
            ),
          );

          expect(subscriber.stream, isNotNull);
          expect(subscriber.missEvents, isNotNull);

          subscriber.close();
        } finally {
          session1.close();
          session2.close();
        }
      },
    );

    test('AdvancedSubscriber close cleans up miss listener resources', () {
      final subscriber = session.declareAdvancedSubscriber(
        'demo/example/adv-miss-close',
        options: AdvancedSubscriberOptions(
          enableMissListener: true,
          recovery: true,
          lastSampleMissDetection: true,
        ),
      );
      expect(() => subscriber.close(), returnsNormally);
    });
  }); // Miss Listener group
}
