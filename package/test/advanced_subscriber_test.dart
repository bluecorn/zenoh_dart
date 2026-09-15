import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

void main() {
  group(
    'AdvancedSubscriber',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session;

      setUpAll(() async {
        final config = Config()..insertJson5('timestamping/enabled', 'true');
        session = await Session.open(config: config);
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
        expect(subscriber.close, returnsNormally);
      });

      test('AdvancedSubscriber.close is idempotent', () {
        final subscriber = session.declareAdvancedSubscriber(
          'demo/example/adv-sub',
        )..close();
        expect(subscriber.close, returnsNormally);
      });

      test(
        'declareAdvancedSubscriber on closed session throws StateError',
        () async {
          final closedConfig = Config()
            ..insertJson5('timestamping/enabled', 'true');
          final closedSession = await Session.open(config: closedConfig)
            ..close();
          expect(
            () =>
                closedSession.declareAdvancedSubscriber('demo/example/adv-sub'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('closed'),
              ),
            ),
          );
        },
      );

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
        'declareAdvancedSubscriber with invalid key expression throws '
        'ZenohException',
        () {
          expect(
            () => session.declareAdvancedSubscriber(''),
            throwsA(isA<ZenohException>()),
          );
        },
      );

      // --- Seed #8 Slice 1: AdvancedSubscriber.keyExpr ------------------
      // The CACHED, close-surviving discipline (`Subscriber.keyExpr`'s), not
      // the native read. Reading back what you declared is not an operation on
      // the native handle, so there is nothing for a disposed-handle guard to
      // protect -- `subscriber.dart:78-88`'s committed reasoning, transferred.

      test('keyExpr returns the declared String', () {
        final subscriber = session.declareAdvancedSubscriber(
          'demo/example/adv-sub-ke',
        );
        addTearDown(subscriber.close);
        expect(subscriber.keyExpr, equals('demo/example/adv-sub-ke'));
      });

      test('keyExpr returns the value of a declared KeyExpr', () {
        final ke = KeyExpr('demo/example/adv-sub-ke-obj');
        addTearDown(ke.dispose);
        final subscriber = session.declareAdvancedSubscriber(ke);
        addTearDown(subscriber.close);
        // Both entry forms of the union reach the same string.
        expect(subscriber.keyExpr, equals(ke.value));
        expect(subscriber.keyExpr, equals('demo/example/adv-sub-ke-obj'));
      });

      test('keyExpr survives close', () {
        final subscriber = session.declareAdvancedSubscriber(
          'demo/example/adv-sub-ke-closed',
        )..close();
        // Dart-side state: it survives close and the session's own close.
        expect(subscriber.keyExpr, equals('demo/example/adv-sub-ke-closed'));
        expect(() => subscriber.keyExpr, returnsNormally);
      });

      // Edge case: the cached discipline carries the declare-time string
      // exactly, so the settled interior-NUL domain is inherited rather than
      // re-derived. Spelled with the `\x00` escape, never a raw NUL byte --
      // every test file classifies as text.
      test('interior-NUL key expression round-trips through the cache', () {
        const declared = 'zenoh/dart/adv\x00sub/ke';
        final subscriber = session.declareAdvancedSubscriber(declared);
        addTearDown(subscriber.close);
        expect(subscriber.keyExpr, equals(declared));
        // Byte-exact, not merely equal-looking: the NUL is still interior.
        expect(utf8.encode(subscriber.keyExpr), equals(utf8.encode(declared)));
        expect(utf8.encode(subscriber.keyExpr), hasLength(21));
      });
    },
  ); // AdvancedSubscriber group

  group(
    'AdvancedSubscriber Integration (TCP 17520-17523, 17525)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      // --- Tests 1 & 2: live pub/sub and delete (port 17520) ---
      group('live pub/sub (port 17520)', () {
        late Session session1;
        late Session session2;

        setUpAll(() async {
          final config1 = Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17520"]')
            ..insertJson5('timestamping/enabled', 'true');
          session1 = await Session.open(config: config1);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final config2 = Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17520"]');
          session2 = await Session.open(config: config2);

          await Future<void>.delayed(const Duration(seconds: 1));
        });

        tearDownAll(() {
          session1.close();
          session2.close();
        });

        test('AdvancedPublisher put received by AdvancedSubscriber', () async {
          final publisher = session1.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/put',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
              options: const AdvancedPublisherOptions(
                cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17521"]')
          ..insertJson5('timestamping/enabled', 'true');
        final session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17521"]');
        final session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        try {
          final publisher =
              session1.declareAdvancedPublisher(
                  'zenoh/dart/test/adv-int/history',
                  options: const AdvancedPublisherOptions(
                    cache: AdvancedPublisherCacheOptions(maxSamples: 6),
                    publisherDetection: true,
                    sampleMissDetection: true,
                  ),
                )
                // Publish BEFORE subscriber
                ..put('cached_1')
                ..put('cached_2')
                ..put('cached_3');

          // Wait for cache to settle
          await Future<void>.delayed(const Duration(seconds: 2));

          final subscriber = session2.declareAdvancedSubscriber(
            'zenoh/dart/test/adv-int/history',
            options: const AdvancedSubscriberOptions(
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
      test(
        'AdvancedSubscriber with history receives cached then live',
        () async {
          final config1 = Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17522"]')
            ..insertJson5('timestamping/enabled', 'true');
          final session1 = await Session.open(config: config1);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final config2 = Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17522"]');
          final session2 = await Session.open(config: config2);

          await Future<void>.delayed(const Duration(seconds: 1));

          try {
            final publisher =
                session1.declareAdvancedPublisher(
                    'zenoh/dart/test/adv-int/order',
                    options: const AdvancedPublisherOptions(
                      cache: AdvancedPublisherCacheOptions(maxSamples: 10),
                      publisherDetection: true,
                      sampleMissDetection: true,
                    ),
                  )
                  // Publish 3 samples BEFORE subscriber
                  ..put('value_1')
                  ..put('value_2')
                  ..put('value_3');

            await Future<void>.delayed(const Duration(seconds: 2));

            final subscriber = session2.declareAdvancedSubscriber(
              'zenoh/dart/test/adv-int/order',
              options: const AdvancedSubscriberOptions(
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
            publisher
              ..put('value_4')
              ..put('value_5')
              ..put('value_6');

            final samples = await subscriber.stream
                .take(6)
                .toList()
                .timeout(const Duration(seconds: 10));

            // R3: the test is named "cached THEN live", and it used to collapse
            // the arrivals into a Set and assert containsAll -- which discards
            // the one property the name claims. Every interleaving passed,
            // including live-before-cached, which is the failure a history
            // implementation actually produces.
            //
            // Order is kept now. Measured deterministic across three runs:
            // the three cached samples arrive first, in publication order,
            // then the three live ones.
            final payloads = samples.map((s) => s.payload).toList();

            expect(
              payloads,
              equals([
                'value_1',
                'value_2',
                'value_3',
                'value_4',
                'value_5',
                'value_6',
              ]),
            );

            // Stated as its own assertion so a failure says which property
            // broke: every cached sample precedes every live one.
            final lastCached = payloads.indexOf('value_3');
            final firstLive = payloads.indexOf('value_4');
            expect(
              lastCached,
              lessThan(firstLive),
              reason: 'a live sample arrived before the cache drained',
            );

            subscriber.close();
            publisher.close();
          } finally {
            session1.close();
            session2.close();
          }
        },
      );

      // --- Test 5: putBytes (port 17523) ---
      test(
        'AdvancedPublisher putBytes received by AdvancedSubscriber',
        () async {
          final config1 = Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17523"]')
            ..insertJson5('timestamping/enabled', 'true');
          final session1 = await Session.open(config: config1);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final config2 = Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17523"]');
          final session2 = await Session.open(config: config2);

          await Future<void>.delayed(const Duration(seconds: 1));

          try {
            final publisher = session1.declareAdvancedPublisher(
              'zenoh/dart/test/adv-int/bytes',
              options: const AdvancedPublisherOptions(
                cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
        },
      );
      // --- Test 6: binary payload delivery (port 17525) ---
      test('AdvancedPublisher binary putBytes delivered faithfully', () async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17525"]')
          ..insertJson5('timestamping/enabled', 'true');
        final session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17525"]');
        final session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        try {
          final publisher = session1.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/binary',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
      test(
        'AdvancedPublisher putBytes delivers binary attachment byte-exact',
        () async {
          final config1 = Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17526"]')
            ..insertJson5('timestamping/enabled', 'true');
          final session1 = await Session.open(config: config1);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final config2 = Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17526"]');
          final session2 = await Session.open(config: config2);

          await Future<void>.delayed(const Duration(seconds: 1));

          try {
            final publisher = session1.declareAdvancedPublisher(
              'zenoh/dart/test/adv-int/att-bin',
              options: const AdvancedPublisherOptions(
                cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
        },
      );

      // Test 2: encoding received faithfully (port 17527)
      test('AdvancedPublisher put encoding received faithfully', () async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17527"]')
          ..insertJson5('timestamping/enabled', 'true');
        final session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17527"]');
        final session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        try {
          final publisher = session1.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/enc',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17528"]')
          ..insertJson5('timestamping/enabled', 'true');
        final session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17528"]');
        final session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        try {
          final publisher = session1.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/empty-absent',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: 5),
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

          final empty = samples.firstWhere((s) => s.payload == 'with-empty');
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
      test('AdvancedPublisher putBytes marks attachment consumed', () async {
        final config = Config()..insertJson5('timestamping/enabled', 'true');
        final s = await Session.open(config: config);
        try {
          final publisher = s.declareAdvancedPublisher(
            'zenoh/dart/test/adv-int/consume',
            options: const AdvancedPublisherOptions(publisherDetection: true),
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
            attachment.toBytes,
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
    },
  ); // AdvancedSubscriber Integration group

  group(
    'Miss Listener',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session;

      setUpAll(() async {
        final config = Config()..insertJson5('timestamping/enabled', 'true');
        session = await Session.open(config: config);
      });

      tearDownAll(() {
        session.close();
      });

      test(
        'AdvancedSubscriber with enableMissListener has non-null missEvents '
        'stream',
        () {
          final subscriber = session.declareAdvancedSubscriber(
            'demo/example/adv-miss',
            options: const AdvancedSubscriberOptions(
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

      // Note (d): accepted breaking change — MissEvent.sourceId is now an
      // EntityGlobalId (zid + eid), not a bare ZenohId. The eid distinguishing
      // two entities on one session must no longer be dropped (Seed B §5).
      test('MissEvent has sourceId (EntityGlobalId) and count fields', () {
        final sourceId = EntityGlobalId(ZenohId(Uint8List(16)), 5);
        final event = MissEvent(sourceId: sourceId, count: 3);

        expect(event.sourceId, equals(sourceId));
        expect(event.sourceId.zid, equals(ZenohId(Uint8List(16))));
        expect(event.sourceId.eid, equals(5));
        expect(event.count, equals(3));
      });

      // Slice 7 Test 2 (edge): the miss source's eid is retained (an int, not
      // dropped to a bare ZenohId) and the count semantics are unchanged.
      // Proven deterministically at the value level — see the note below Test 1
      // on why the live-network miss cannot be driven deterministically
      // in-process.
      test(
        'MissEvent sourceId retains eid (no flatten) and preserves count',
        () {
          final zidBytes = Uint8List.fromList(
            List<int>.generate(16, (i) => i + 1),
          );
          final sourceId = EntityGlobalId(ZenohId(zidBytes), 42);
          final event = MissEvent(sourceId: sourceId, count: 7);

          // The eid is retained, not dropped to a bare ZenohId.
          expect(event.sourceId, isA<EntityGlobalId>());
          expect(event.sourceId, isNot(isA<ZenohId>()));
          expect(event.sourceId.eid, equals(42));
          expect(event.sourceId.zid, equals(ZenohId(zidBytes)));
          // Count semantics unchanged from prior behavior.
          expect(event.count, equals(7));

          // Anti-flatten: same zid, different eid must be a different sourceId.
          final other = EntityGlobalId(ZenohId(zidBytes), 43);
          expect(event.sourceId == other, isFalse);
        },
      );

      // ⚠️ THE PERMANENT SELF-SKIP THAT LIVED HERE IS RETIRED, and so is the
      // debt it recorded.
      //
      // It drove ten puts through a real advanced pair over loopback, hoped a
      // miss would fire, and called markTestSkipped when none did — which was
      // every run. Its own message stated why that was not a resting state
      // (corpus audit 2026-07-28, B2 finding 6): "the native miss-callback
      // bridge has NO executed end-to-end coverage -- a broken bridge is
      // indistinguishable from a skipped test." It named its own revisit
      // condition too: "a driveable miss mechanism".
      //
      // That mechanism now exists. `test/advanced_miss_inject_test.dart` drives
      // the bridge through a canon-C injector that publishes a crafted source
      // sequence number, so the gap is one we chose and the assertions are
      // identity- and count-EXACT rather than best-effort: exactly one
      // MissEvent, count equal to the injected gap, sourceId zid and eid equal
      // to the identity the injector printed. Those assertions are strictly
      // stronger than the block that stood here, which is why it is removed
      // rather than kept beside them.

      test(
        'AdvancedSubscriber with all options including miss listener declares '
        'successfully',
        () async {
          final config1 = Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17524"]')
            ..insertJson5('timestamping/enabled', 'true');
          final session1 = await Session.open(config: config1);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final config2 = Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17524"]');
          final session2 = await Session.open(config: config2);

          await Future<void>.delayed(const Duration(seconds: 1));

          try {
            final subscriber = session2.declareAdvancedSubscriber(
              'demo/example/adv-miss-all',
              options: const AdvancedSubscriberOptions(
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
          options: const AdvancedSubscriberOptions(
            enableMissListener: true,
            recovery: true,
            lastSampleMissDetection: true,
          ),
        );
        expect(subscriber.close, returnsNormally);
      });
    },
  ); // Miss Listener group
}
