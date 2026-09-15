import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Publisher lifecycle', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declarePublisher returns a Publisher on valid key expression', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(publisher, isA<Publisher>());
      publisher.close();
    });

    test('Publisher.keyExpr returns the declared key expression', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(publisher.keyExpr, equals('demo/example/pub'));
      publisher.close();
    });

    test('Publisher.close completes without error', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(publisher.close, returnsNormally);
    });

    test('Publisher.close is idempotent (double-close safe)', () {
      final publisher = session.declarePublisher('demo/example/pub')..close();
      expect(publisher.close, returnsNormally);
    });

    test('declarePublisher on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.declarePublisher('demo/example/pub'),
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
      'declarePublisher with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declarePublisher(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );

    test('Publisher.put publishes a string value without error', () {
      final publisher = session.declarePublisher('demo/example/pub-put');
      addTearDown(publisher.close);
      expect(() => publisher.put('Hello from publisher'), returnsNormally);
    });

    test('Publisher.putBytes publishes ZBytes and consumes the payload', () {
      final publisher = session.declarePublisher('demo/example/pub-bytes');
      addTearDown(publisher.close);
      final payload = ZBytes.fromString('raw data');
      expect(() => publisher.putBytes(payload), returnsNormally);
      expect(() => payload.nativePtr, throwsA(isA<StateError>()));
    });

    test('Publisher.put with encoding override succeeds', () {
      final publisher = session.declarePublisher('demo/example/pub-enc');
      addTearDown(publisher.close);
      expect(
        () => publisher.put('json data', encoding: Encoding.applicationJson),
        returnsNormally,
      );
    });

    test('Publisher.put with attachment succeeds and consumes attachment', () {
      final publisher = session.declarePublisher('demo/example/pub-att');
      addTearDown(publisher.close);
      final attachment = ZBytes.fromString('metadata');
      expect(
        () => publisher.put('value', attachment: attachment),
        returnsNormally,
      );
      expect(() => attachment.nativePtr, throwsA(isA<StateError>()));
    });

    test('Publisher.putBytes with encoding and attachment succeeds', () {
      final publisher = session.declarePublisher('demo/example/pub-full');
      addTearDown(publisher.close);
      final payload = ZBytes.fromString('data');
      final attachment = ZBytes.fromString('meta');
      expect(
        () => publisher.putBytes(
          payload,
          encoding: Encoding.textPlain,
          attachment: attachment,
        ),
        returnsNormally,
      );
      expect(() => payload.nativePtr, throwsA(isA<StateError>()));
      expect(() => attachment.nativePtr, throwsA(isA<StateError>()));
    });

    test('Publisher.put after close throws StateError', () {
      final publisher = session.declarePublisher('demo/example/pub-closed')
        ..close();
      expect(() => publisher.put('test'), throwsA(isA<StateError>()));
    });

    test('Publisher operations after close throw StateError', () {
      final publisher = session.declarePublisher('demo/example/pub')..close();

      expect(() => publisher.put('test'), throwsA(isA<StateError>()));
      expect(
        () => publisher.putBytes(ZBytes.fromString('test')),
        throwsA(isA<StateError>()),
      );
      expect(publisher.deleteResource, throwsA(isA<StateError>()));
      expect(() => publisher.keyExpr, throwsA(isA<StateError>()));
      expect(
        publisher.hasMatchingSubscribers,
        throwsA(isA<StateError>()),
      );
    });

    test('Publisher.deleteResource completes without error', () {
      final publisher = session.declarePublisher('demo/example/pub-del');
      addTearDown(publisher.close);
      expect(publisher.deleteResource, returnsNormally);
    });

    test('Publisher.deleteResource after close throws StateError', () {
      final publisher = session.declarePublisher('demo/example/pub-del2')
        ..close();
      expect(publisher.deleteResource, throwsA(isA<StateError>()));
    });
  });

  group('Publisher pub/sub integration', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17452"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17452"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('Publisher.put received by subscriber as PUT sample', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/pub-put');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/test/pub-put');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('hello from pub');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(sample.payload, equals('hello from pub'));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, equals('zenoh/dart/test/pub-put'));
    });

    test(
      'Publisher.deleteResource received by subscriber as DELETE sample',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/pub-del',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher('zenoh/dart/test/pub-del');
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.deleteResource();

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.kind, equals(SampleKind.delete));
      },
    );

    test('Publisher.put with attachment received by subscriber', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/pub-att');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/test/pub-att');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('value', attachment: ZBytes.fromString('meta'));

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(sample.payload, equals('value'));
      expect(sample.attachment, equals('meta'));
    });

    test(
      'Publisher.put with encoding received by subscriber with encoding',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/pub-enc',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/pub-enc',
          encoding: Encoding.applicationJson,
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put('{"key":"value"}');

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.encoding, contains('application/json'));
      },
    );

    // Slice 10: the two remaining z_encoding_from_str rc-discards are now
    // checked in zd_publisher_put and zd_declare_publisher. As established in
    // Slices 3/6/7/8, z_encoding_from_str does NOT fail observably for junk
    // MIME in zenoh-c 1.7.2, so we cannot force a throw. Instead we assert a
    // valid custom encoding survives the rc-checked path (no silent default
    // substitution) -- the rc IS now checked.
    test(
      'Publisher.put custom encoding round-trips (rc-checked path)',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/pub-enc-put-custom',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/pub-enc-put-custom',
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put(
          'data',
          encoding: const Encoding('application/vnd.dart.pub-put'),
        );

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.encoding, contains('application/vnd.dart.pub-put'));
      },
    );

    test(
      'declarePublisher custom encoding round-trips (rc-checked path)',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/pub-enc-decl-custom',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/pub-enc-decl-custom',
          encoding: const Encoding('application/vnd.dart.pub-decl'),
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put('data');

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.encoding, contains('application/vnd.dart.pub-decl'));
      },
    );
  });

  group('Multiple publishers integration', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17453"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17453"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test(
      'Multiple publishers on different keys each received by correct '
      'subscriber',
      () async {
        final subA = session2.declareSubscriber('zenoh/dart/test/pub-a');
        addTearDown(subA.close);
        final subB = session2.declareSubscriber('zenoh/dart/test/pub-b');
        addTearDown(subB.close);
        final pubA = session1.declarePublisher('zenoh/dart/test/pub-a');
        addTearDown(pubA.close);
        final pubB = session1.declarePublisher('zenoh/dart/test/pub-b');
        addTearDown(pubB.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        pubA.put('alpha');
        pubB.put('beta');

        final sampleA = await subA.stream.first.timeout(
          const Duration(seconds: 5),
        );
        final sampleB = await subB.stream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(sampleA.payload, equals('alpha'));
        expect(sampleB.payload, equals('beta'));
      },
    );
  });

  group('Publisher QoS options', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    // `.block` rather than `.drop`: drop is `declarePublisher`'s own default
    // (session.dart), so passing it explicitly produces a call byte-identical
    // to the plain-declare smoke test one group up -- the test could not fail
    // for the reason its name gives. `.block` is the discriminating leg, and
    // nothing else in this file declares with it.
    test('Publisher declared with CongestionControl.block does not throw', () {
      final publisher = session.declarePublisher(
        'demo/qos',
        congestionControl: CongestionControl.block,
      );
      expect(publisher, isA<Publisher>());
      publisher.close();
    });

    test('Publisher declared with Priority.realTime does not throw', () {
      final publisher = session.declarePublisher(
        'demo/qos',
        priority: Priority.realTime,
      );
      expect(publisher, isA<Publisher>());
      publisher.close();
    });

    test('Publisher declared with all options succeeds', () {
      final publisher = session.declarePublisher(
        'demo/full',
        encoding: Encoding.applicationJson,
        priority: Priority.interactiveHigh,
        enableMatchingListener: true,
      );
      expect(publisher.matchingStatus, isNotNull);
      expect(publisher.keyExpr, equals('demo/full'));
      publisher.close();
    });
  });

  group('Matching status one-shot', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Scouting off: `hasMatchingSubscribers` is a network-wide question, so
      // the false-case below is only a real negative if this session cannot
      // discover anything beyond the peer it is paired with. With multicast on
      // it green-lit whenever the LAN happened to be quiet -- any wildcard
      // subscriber elsewhere on the network flips it.
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17454"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17454"]')
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
      'hasMatchingSubscribers returns false when no subscribers exist',
      () async {
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/match-none',
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        expect(publisher.hasMatchingSubscribers(), isFalse);
      },
    );

    test(
      'hasMatchingSubscribers returns true when a subscriber exists',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/match-yes',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/match-yes',
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        expect(publisher.hasMatchingSubscribers(), isTrue);
      },
    );

    test('matchingStatus is null when listener not enabled', () {
      final publisher = session1.declarePublisher('zenoh/dart/test/match-null');
      addTearDown(publisher.close);
      expect(publisher.matchingStatus, isNull);
    });

    test('hasMatchingSubscribers after close throws StateError', () {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/match-closed',
      )..close();
      expect(
        publisher.hasMatchingSubscribers,
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Publisher isExpress option', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('Publisher with isExpress true creates publisher', () {
      final publisher = session.declarePublisher(
        'demo/express/true',
        isExpress: true,
      );
      expect(publisher, isA<Publisher>());
      publisher.close();
    });

    test('Publisher with isExpress false (default) is backward compatible', () {
      final publisher = session.declarePublisher('demo/express/default');
      expect(publisher, isA<Publisher>());
      publisher.close();
    });
  });

  group('Publisher isExpress pub/sub integration', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17510"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17510"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test(
      'Publisher with isExpress true can publish and subscriber receives',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/express-pub',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/express-pub',
          isExpress: true,
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put('express message');

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.payload, equals('express message'));
        expect(sample.kind, equals(SampleKind.put));
      },
    );
  });

  group('Matching status stream', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17455"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17455"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('matchingStatus stream emits true when subscriber appears', () async {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/match-stream',
        enableMatchingListener: true,
      );
      addTearDown(publisher.close);

      expect(publisher.matchingStatus, isNotNull);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Declare subscriber to trigger matching
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/match-stream',
      );
      addTearDown(subscriber.close);

      final status = await publisher.matchingStatus!.first.timeout(
        const Duration(seconds: 5),
      );
      expect(status, isTrue);
    });

    test(
      'matchingStatus stream emits false when subscriber disappears',
      () async {
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/match-stream2',
          enableMatchingListener: true,
        );
        addTearDown(publisher.close);

        final statuses = <bool>[];
        final gotFalse = Completer<void>();
        publisher.matchingStatus!.listen((status) {
          statuses.add(status);
          if (!status && statuses.length > 1) {
            if (!gotFalse.isCompleted) gotFalse.complete();
          }
        });

        await Future<void>.delayed(const Duration(seconds: 1));

        // Declare then close subscriber
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/match-stream2',
        );

        // Wait for routing propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        subscriber.close();

        // Wait for "false" status
        await gotFalse.future.timeout(const Duration(seconds: 5));
        expect(statuses, contains(true));
        expect(statuses.last, isFalse);
      },
    );

    test('matchingStatus stream closes when publisher is closed', () async {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/match-close',
        enableMatchingListener: true,
      );

      final doneCompleter = Completer<void>();
      publisher.matchingStatus!.listen((_) {}, onDone: doneCompleter.complete);

      publisher.close();

      await doneCompleter.future.timeout(const Duration(seconds: 5));
    });
  });

  group('Publisher put/delete timestamp (send)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17536"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17536"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('Publisher.put timestamp round-trips bit-exact', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/pub/ts');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/pub/ts');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      publisher.put('hello from pub', timestamp: ts);

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp, equals(ts));
      // NTP64 time AND id bit-exact (the whole 24 bytes).
      expect(sample.timestamp!.time, equals(ts.time));
      expect(sample.timestamp!.id, equals(ts.id));
    });

    test('Publisher.deleteResource carries a timestamp', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/pub/del-ts');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/pub/del-ts');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      publisher.deleteResource(timestamp: ts);

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.kind, equals(SampleKind.delete));
      expect(sample.timestamp, equals(ts));
    });

    test('Publisher.put natural session timestamp (>2^62) round-trips '
        'with no narrowing', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/pub/ts-u64');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/pub/ts-u64');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      // The natural NTP64 time today has bit 62 set (a large positive int):
      // proves the wire path conveys the full unsigned-64 with no
      // clamp/narrow/stringify. (The >2^63 sign-bit case is documented
      // not-injectable-via-canon and is not tested here.)
      expect(ts.time & (1 << 62) != 0, isTrue);

      publisher.put('u64 fidelity', timestamp: ts);

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp!.time, equals(ts.time));
    });

    test('Publisher.put without a timestamp yields null on receive', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/pub/no-ts');
      addTearDown(subscriber.close);
      final publisher = session1.declarePublisher('zenoh/dart/pub/no-ts');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('no timestamp');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNull);
    });

    test(
      'Publisher.putBytes accepts the same timestamp param (bit-exact)',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/pub/bytes-ts',
        );
        addTearDown(subscriber.close);
        final publisher = session1.declarePublisher('zenoh/dart/pub/bytes-ts');
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        final ts = session1.newTimestamp();
        publisher.putBytes(ZBytes.fromString('hello bytes'), timestamp: ts);

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(sample.timestamp, isNotNull);
        expect(sample.timestamp, equals(ts));
        expect(sample.timestamp!.time, equals(ts.time));
        expect(sample.timestamp!.id, equals(ts.id));
      },
    );
  });
}
