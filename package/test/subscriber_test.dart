import 'dart:async';
// `hide Encoding`: dart:convert exports an abstract Encoding of its own, which
// shadows zenoh's. Only utf8 is wanted from here.
import 'dart:convert' hide Encoding;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/bytes_writer.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/subscriber.dart';
import 'package:zenoh_dart/src/timestamp.dart';
import 'package:zenoh_dart/src/unstable/advanced_subscriber.dart';
import 'package:zenoh_dart/src/unstable/features.dart';
import 'package:zenoh_dart/src/unstable/session_advanced_ext.dart';

import 'helpers/poll.dart';

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

    setUpAll(() async {
      session = await Session.open();
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
      expect(subscriber.close, returnsNormally);
    });

    test('Subscriber.close is idempotent (double-close safe)', () {
      final subscriber = session.declareSubscriber('demo/example/test')
        ..close();
      expect(subscriber.close, returnsNormally);
    });

    test('declareSubscriber on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
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
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17448"]');
      session1 = await Session.open(config: config1);

      // Small delay to let session1's listener bind
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17448"]');
      session2 = await Session.open(config: config2);

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

      session1
        ..put('zenoh/dart/test/multi', 'first')
        ..put('zenoh/dart/test/multi', 'second')
        ..put('zenoh/dart/test/multi', 'third');

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

      session1
        ..put('zenoh/dart/test/wild/a', 'alpha')
        ..put('zenoh/dart/test/wild/b', 'beta');

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
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17449"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17449"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('stream closes when subscriber is closed', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/close1');

      final doneCompleter = Completer<void>();
      subscriber.stream.listen((_) {}, onDone: doneCompleter.complete);

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
          onDone: doneCompleter.complete,
        );

        // Send a sample first
        session1.put('zenoh/dart/test/close2', 'before close');

        // Poll for arrival rather than sleeping: "wait until the sample has
        // been delivered" is a condition, and asserting isNotEmpty after a
        // fixed 2 s asserts the machine's speed instead.
        await waitUntil(() => samples.isNotEmpty, description: 'first sample');
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
        onDone: doneCompleter.complete,
      );

      // Close immediately without sending any puts
      subscriber.close();

      await doneCompleter.future.timeout(const Duration(seconds: 5));
      expect(samples, isEmpty);
    });
  });

  // R3: the Subscriber's terminal state when the SESSION closes underneath it.
  //
  // The group above covers closing the subscriber. Nothing covered closing the
  // session first, which is the ordering a consumer hits on shutdown and the
  // one where a use-after-free would live: Session.close() calls
  // zd_close_session and then frees the native handle, while the Subscriber
  // holds a separately-declared handle of its own.
  //
  // These pin measured behaviour, not desired behaviour. In particular the
  // first test records something worth knowing and NOT obviously right: the
  // stream does NOT complete when the session closes. A consumer awaiting
  // `subscriber.stream.first` after its session went away waits forever rather
  // than getting a done event. Reported at the round-3 gate as a finding --
  // changing it means changing package/lib/**, which is outside this round.
  group('Subscriber terminal state after session close (TCP 18860)', () {
    // Each test needs a session it is allowed to destroy, so the session is
    // per-test rather than per-group.
    Future<Session> isolatedSession() {
      final config = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18860"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      return Session.open(config: config);
    }

    test('stream does NOT complete when the session closes', () async {
      final session = await isolatedSession();
      final subscriber = session.declareSubscriber('zenoh/dart/test/sc/stream');

      var done = false;
      Object? error;
      subscriber.stream.listen(
        (_) {},
        onDone: () => done = true,
        onError: (Object e) => error = e,
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      session.close();
      // Long enough that a done event travelling the NativePort bridge would
      // have landed -- the sibling group's own done events arrive well inside
      // this window.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(done, isFalse, reason: 'session close now completes the stream');
      expect(error, isNull, reason: 'session close now errors the stream');

      // Still safe to close afterwards, which is the half that matters for
      // memory: this is the drop-after-session-drop ordering.
      expect(subscriber.close, returnsNormally);
    });

    test(
      'close() after the session is closed is safe and idempotent',
      () async {
        final session = await isolatedSession();
        final subscriber = session.declareSubscriber(
          'zenoh/dart/test/sc/close',
        );

        session.close();

        expect(subscriber.close, returnsNormally);
        expect(subscriber.close, returnsNormally);
      },
    );

    test('declaring on an already-closed session throws StateError', () async {
      final session = (await isolatedSession())..close();

      expect(
        () => session.declareSubscriber('zenoh/dart/test/sc/late'),
        throwsStateError,
      );
    });
  });

  group('Multiple subscribers', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Use port 17450 to avoid conflicts with other test groups
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17450"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17450"]');
      session2 = await Session.open(config: config2);

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
      'multiple subscribers on different keys receive only their matching '
      'samples',
      () async {
        final subA = session2.declareSubscriber('zenoh/dart/test/a');
        addTearDown(subA.close);
        final subB = session2.declareSubscriber('zenoh/dart/test/b');
        addTearDown(subB.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        session1
          ..put('zenoh/dart/test/a', 'for-a')
          ..put('zenoh/dart/test/b', 'for-b');

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
      sub1.stream.listen((_) {}, onDone: doneCompleter.complete);
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
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17451"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17451"]');
      session2 = await Session.open(config: config2);

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

    test('receives binary attachment byte-exact', () async {
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
      // Byte-exact recovery of the invalid-UTF-8 attachment (no U+FFFD).
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('receives valid-UTF-8 attachment byte-exact and as string', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/utf8-att');
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher('zenoh/dart/test/utf8-att');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      const original = 'gid:robot-42';
      publisher.putBytes(
        ZBytes.fromString('valid payload'),
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList(utf8.encode(original)),
        ),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.attachmentBytes, equals(utf8.encode(original)));
      expect(sample.attachment, equals(original));
    });

    test('present-but-empty attachment is non-null empty', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/empty-att',
      );
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher('zenoh/dart/test/empty-att');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.putBytes(
        ZBytes.fromString('payload'),
        attachment: ZBytes.fromUint8List(Uint8List(0)),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // Empty (non-null) is distinct from absent (null).
      expect(sample.attachmentBytes, isNotNull);
      expect(sample.attachmentBytes, hasLength(0));
    });

    test('absent attachment is null', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/no-att');
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher('zenoh/dart/test/no-att');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // No attachment argument at all.
      publisher.putBytes(ZBytes.fromString('payload'));

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.attachmentBytes, isNull);
      expect(sample.attachment, isNull);
    });

    test(
      'multi-fragment binary payload delivers flattened and exact',
      () async {
        final subscriber = session2.declareSubscriber(
          'zenoh/dart/test/binary-frag',
        );
        addTearDown(subscriber.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        final writer = ZBytesWriter()
          ..writeAll(Uint8List.fromList([0xFF, 0xFE]))
          ..writeAll(Uint8List.fromList([0x80, 0x41]));
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

      session1
        ..put('zenoh/dart/test/multi-bytes', 'first')
        ..put('zenoh/dart/test/multi-bytes', 'second');

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
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17512"]');
        session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17512"]');
        session2 = await Session.open(config: config2);

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

        session1
          ..put('zenoh/dart/test/bg-multi', 'first')
          ..put('zenoh/dart/test/bg-multi', 'second')
          ..put('zenoh/dart/test/bg-multi', 'third');

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

        session1
          ..put('zenoh/dart/test/bg-wild/a', 'alpha')
          ..put('zenoh/dart/test/bg-wild/b', 'beta');

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

    test('on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
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

    test('with invalid keyexpr throws ZenohException', () async {
      final session = await Session.open();
      addTearDown(session.close);
      expect(
        () => session.declareBackgroundSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });

    group('stream closes on session close (TCP 17513)', () {
      test('stream onDone fires when session closes', () async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17513"]');
        final s1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17513"]');
        final s2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));

        final stream = s2.declareBackgroundSubscriber(
          'zenoh/dart/test/bg-close',
        );

        await Future<void>.delayed(const Duration(seconds: 1));

        // Send a sample to confirm the subscriber works
        s1.put('zenoh/dart/test/bg-close', 'before-close');

        final doneCompleter = Completer<void>();
        final samples = <Sample>[];
        stream.listen(samples.add, onDone: doneCompleter.complete);

        // Poll for arrival rather than sleeping (see the sibling above).
        await waitUntil(() => samples.isNotEmpty, description: 'first sample');
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
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17514"]');
        session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17514"]');
        session2 = await Session.open(config: config2);

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

  // Slice 2: Sample QoS/timestamp metadata on the subscriber callback path.
  group('Sample QoS/timestamp metadata (TCP 17530)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17530"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17530"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test(
      'received sample reflects publisher priority/congestion/express',
      () async {
        final subscriber = session2.declareSubscriber('zenoh/dart/test/qos');
        addTearDown(subscriber.close);

        // Every QoS field is set to a NON-default value so each assertion
        // below proves propagation. Asserting the default (drop) would pass
        // even if congestion control never reached the sample.
        final publisher = session1.declarePublisher(
          'zenoh/dart/test/qos',
          priority: Priority.dataHigh,
          congestionControl: CongestionControl.block,
          isExpress: true,
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        publisher.put('qos payload');

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(sample.priority, equals(Priority.dataHigh));
        expect(sample.congestionControl, equals(CongestionControl.block));
        expect(sample.express, isTrue);
      },
    );

    test('sample without a timestamp reports null', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/no-ts');
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher('zenoh/dart/test/no-ts');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // No timestamp attached on the send path.
      publisher.put('no timestamp');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNull);
    });

    test('default publisher yields default metadata, never null', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/defaults');
      addTearDown(subscriber.close);

      // Default declaration: priority data, congestion drop, express false.
      final publisher = session1.declarePublisher('zenoh/dart/test/defaults');
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('defaults');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.priority, equals(Priority.data));
      expect(sample.congestionControl, equals(CongestionControl.drop));
      expect(sample.express, isFalse);
      expect(sample.timestamp, isNull);
    });

    test('default Session.put delegates to canon DROP', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/put-default-cc',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/put-default-cc', 'x');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // Session.put takes no congestion param and delegates to
      // z_put_options_default (DROP). Confirms the delegation path is already
      // canon-correct — no param added.
      expect(sample.congestionControl, equals(CongestionControl.drop));
    });

    test('metadata does not corrupt binary payload/attachment', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/test/qos-bin');
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher(
        'zenoh/dart/test/qos-bin',
        priority: Priority.dataHigh,
        isExpress: true,
      );
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final payload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final attachment = Uint8List.fromList([0xFF, 0xFE, 0x80]);
      publisher.putBytes(
        ZBytes.fromUint8List(payload),
        attachment: ZBytes.fromUint8List(attachment),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // Payload/attachment remain byte-exact alongside the new metadata.
      expect(sample.payloadBytes, equals([0x00, 0xFF, 0xFE, 0x80, 0x41]));
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
      // And the metadata is populated.
      expect(sample.priority, equals(Priority.dataHigh));
      expect(sample.express, isTrue);
    });
  });

  // Slice 2 Test 5 (CA2 ruling a): empirical all-surfaces proof on the
  // advanced-subscriber surface -- it funnels through the same
  // _zd_sample_callback / createSampleChannel path.
  group(
    'Advanced subscriber receives QoS metadata (TCP 17531)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session1;
      late Session session2;

      setUpAll(() async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17531"]')
          ..insertJson5('timestamping/enabled', 'true');
        session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17531"]')
          ..insertJson5('timestamping/enabled', 'true');
        session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        session1.close();
        session2.close();
      });

      test(
        'advanced subscriber sample exposes priority/express and timestamp',
        () async {
          final subscriber = session2.declareAdvancedSubscriber(
            'zenoh/dart/test/adv-qos',
          );
          addTearDown(subscriber.close);
          expect(subscriber, isA<AdvancedSubscriber>());

          final publisher = session1.declarePublisher(
            'zenoh/dart/test/adv-qos',
            priority: Priority.dataHigh,
            isExpress: true,
          );
          addTearDown(publisher.close);

          await Future<void>.delayed(const Duration(seconds: 1));

          publisher.put('adv qos payload');

          final sample = await subscriber.stream.first.timeout(
            const Duration(seconds: 5),
          );

          expect(sample.priority, equals(Priority.dataHigh));
          expect(sample.express, isTrue);
          // The advanced-sub session runs with timestamping/enabled, so the
          // network assigns a timestamp even though the publisher set none.
          // That is a statement about what must happen, so it is asserted --
          // the previous `if (ts != null)` guard silently skipped the check in
          // exactly the case it exists to catch: a timestamp path regressing to
          // null greened forever.
          final ts = sample.timestamp;
          expect(ts, isNotNull);
          expect(Timestamp.fromRaw(ts!.rawBytes), equals(ts));
        },
      );
    },
  );

  // Slice 8 (F13): the dedicated QoS-propagation boundary matrix.
  // Value-carrying QoS lives on the subscriber/Publisher path (N3 -- reply QoS
  // is deprecated), so every case declares a Publisher with a specific
  // declaration QoS, puts, and asserts the received Sample reflects it
  // exactly. Test-only: exercises the Slice-2 receive path + existing
  // Publisher declaration QoS. A failure here reveals a real
  // cross-field-corruption or mapping bug in the extractor.
  group('F13 QoS propagation (TCP 17538)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17538"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17538"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    // Helper: declare a subscriber on `key`, a publisher on `key` with the
    // given declaration QoS, put `payload`, and return the first received
    // sample.
    Future<Sample> receiveWithQoS(
      String key, {
      Priority? priority,
      CongestionControl? congestionControl,
      bool? isExpress,
      String payload = 'f13',
    }) async {
      final subscriber = session2.declareSubscriber(key);
      addTearDown(subscriber.close);

      final publisher = session1.declarePublisher(
        key,
        priority: priority ?? Priority.data,
        congestionControl: congestionControl ?? CongestionControl.drop,
        isExpress: isExpress ?? false,
      );
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put(payload);

      return subscriber.stream.first.timeout(const Duration(seconds: 5));
    }

    test('priority propagates at both enum boundaries', () async {
      // realTime = wire 1 (index 0), background = wire 7 (index 6): the
      // extremes of the 7-value enum.
      final high = await receiveWithQoS(
        'zenoh/dart/test/f13/prio-rt',
        priority: Priority.realTime,
      );
      expect(high.priority, equals(Priority.realTime));

      final low = await receiveWithQoS(
        'zenoh/dart/test/f13/prio-bg',
        priority: Priority.background,
      );
      expect(low.priority, equals(Priority.background));
    });

    test('congestion control propagates for both strategies', () async {
      final block = await receiveWithQoS(
        'zenoh/dart/test/f13/cc-block',
        congestionControl: CongestionControl.block,
      );
      expect(block.congestionControl, equals(CongestionControl.block));

      final drop = await receiveWithQoS(
        'zenoh/dart/test/f13/cc-drop',
        congestionControl: CongestionControl.drop,
      );
      expect(drop.congestionControl, equals(CongestionControl.drop));
    });

    test(
      'blockFirst congestion round-trips end-to-end',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
      () async {
        final sample = await receiveWithQoS(
          'zenoh/dart/test/f13/cc-blockfirst',
          congestionControl: CongestionControl.blockFirst,
        );
        expect(sample.congestionControl, equals(CongestionControl.blockFirst));
      },
    );

    // [CC] A2's unstable half for `Session.put`.
    //
    // ⛔ THE CELL ABOVE DOES NOT COVER IT. That one drives the PUBLISHER
    // declaration (`publisher.dart:75`); this drives `Session.put`'s own
    // marshal expression (`session.dart:512`). Two sites, two expressions — a
    // guard keyed on the door rather than the native, or one that fires
    // unconditionally, breaks this and leaves the other green.
    //
    // Forward-gated on the native, never inversely: an inverse gate would
    // make this cell's green mean "never ran".
    test(
      'blockFirst still reaches the wire from Session.put',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
      () async {
        const key = 'zenoh/dart/test/f13/cc-blockfirst-put';
        final subscriber = session2.declareSubscriber(key);
        addTearDown(subscriber.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        session1.put(
          key,
          'f13-put',
          congestionControl: CongestionControl.blockFirst,
        );

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(sample.congestionControl, equals(CongestionControl.blockFirst));
      },
    );

    // [CC] A2's unstable half for the remaining three sample-emitting sites.
    //
    // ⛔ ONE CELL, THREE SITES, and they are genuinely different marshal
    // expressions: `session.dart:598` (putBytes), `:656` (deleteResource) and
    // `publisher.dart:75` (declarePublisher). The delete arm also pins the
    // sample KIND, because a delete arriving as a put would satisfy a
    // congestion assertion while carrying the wrong operation.
    test(
      'blockFirst still reaches the wire from putBytes, deleteResource and a '
      'declared publisher',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
      () async {
        Future<Sample> firstOn(String key, void Function() send) async {
          final subscriber = session2.declareSubscriber(key);
          addTearDown(subscriber.close);
          await Future<void>.delayed(const Duration(seconds: 1));
          send();
          return subscriber.stream.first.timeout(const Duration(seconds: 5));
        }

        const bytesKey = 'zenoh/dart/test/f13/cc-blockfirst-putbytes';
        final fromBytes = await firstOn(
          bytesKey,
          () => session1.putBytes(
            bytesKey,
            ZBytes.fromString('f13-bytes'),
            congestionControl: CongestionControl.blockFirst,
          ),
        );
        expect(
          fromBytes.congestionControl,
          equals(CongestionControl.blockFirst),
        );

        const deleteKey = 'zenoh/dart/test/f13/cc-blockfirst-delete';
        final fromDelete = await firstOn(
          deleteKey,
          () => session1.deleteResource(
            deleteKey,
            congestionControl: CongestionControl.blockFirst,
          ),
        );
        expect(
          fromDelete.congestionControl,
          equals(CongestionControl.blockFirst),
        );
        expect(fromDelete.kind, equals(SampleKind.delete));

        const pubKey = 'zenoh/dart/test/f13/cc-blockfirst-declpub';
        final publisher = session1.declarePublisher(
          pubKey,
          congestionControl: CongestionControl.blockFirst,
        );
        addTearDown(publisher.close);
        final fromPublisher = await firstOn(pubKey, () => publisher.put('f13'));
        expect(
          fromPublisher.congestionControl,
          equals(CongestionControl.blockFirst),
        );
      },
    );

    test('express propagates for both states', () async {
      final express = await receiveWithQoS(
        'zenoh/dart/test/f13/express-on',
        isExpress: true,
      );
      expect(express.express, isTrue);

      final notExpress = await receiveWithQoS(
        'zenoh/dart/test/f13/express-off',
        isExpress: false,
      );
      expect(notExpress.express, isFalse);
    });

    test(
      'all three fields co-propagate on one message without corruption',
      () async {
        // Distinct value on each axis simultaneously: proves the extractor maps
        // each field independently (no cross-field corruption).
        final sample = await receiveWithQoS(
          'zenoh/dart/test/f13/combined',
          priority: Priority.dataLow,
          congestionControl: CongestionControl.drop,
          isExpress: true,
        );

        expect(sample.priority, equals(Priority.dataLow));
        expect(sample.congestionControl, equals(CongestionControl.drop));
        expect(sample.express, isTrue);
      },
    );
  });

  // R3: the `id;schema` encoding round-trip.
  //
  // zenoh encodings are two-part -- a (possibly well-known) id and an optional
  // `;schema` suffix that carries application-level type information. The only
  // encoding assertion in the corpus before this group was 'receives encoding
  // from published data', which asserts `isNotNull` against a put that never
  // set an encoding: it proves the field is populated by *something*, and would
  // stay green if the shim dropped the schema half, returned a constant, or
  // truncated at the semicolon. Since the schema is where the payload's type
  // rides ([[zenoh-type-conveyance]]), losing it silently is the v0.18.1 shape
  // one field over.
  //
  // Each leg below publishes a distinct id;schema pair and demands the exact
  // string back.
  //
  // EXTENDED: the four legs this group shipped with were not enough, and the
  // shape of the gap is worth naming, because it is the same shape twice.
  // Every one of those legs composed its schema into the mime string and
  // asked only "did the suffix survive?". None of them ever sent a byte that
  // a NUL-terminated channel would swallow -- so all four sat green for the
  // whole time the encoding channel truncated at the first interior NUL. A
  // group that exercises a string channel without ever sending an interior
  // NUL cannot tell a length-carried channel from a NUL-terminated one; it
  // reports on the values it happened to pick, not on the channel. That
  // question is now the first leg below, in this group, rather than in a
  // second harness beside it.
  //
  // The remaining new legs close the other half of the same gap. An encoding
  // is two channels (mime and schema), and composing into the mime string is
  // only one route to them: where both routes can express a pair they must
  // arrive identical, and where they cannot -- an empty schema on a
  // well-known id -- only the structured route reaches the value at all.
  group('Encoding id;schema wire round-trip (TCP 18800)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18800"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18800"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    // Publish once on [key] with [encoding] and return the received sample.
    Future<Sample> receiveWithEncoding(String key, Encoding encoding) async {
      final subscriber = session2.declareSubscriber(key);
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(key, 'payload', encoding: encoding);

      return subscriber.stream.first.timeout(const Duration(seconds: 5));
    }

    test('well-known id with a schema arrives intact', () async {
      final sample = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/known',
        const Encoding('application/json;my-schema'),
      );

      expect(sample.encoding, equals('application/json;my-schema'));
    });

    test('custom id with a schema arrives intact', () async {
      final sample = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/custom',
        const Encoding('application/x-custom;v=2'),
      );

      expect(sample.encoding, equals('application/x-custom;v=2'));
    });

    // The discriminating pair: same id, different schema. If the schema half
    // were dropped anywhere on the path, both legs would report the bare id and
    // the two would be indistinguishable -- so this is the assertion that a
    // truncate-at-semicolon defect cannot satisfy.
    test('two schemas on the same id stay distinct', () async {
      final a = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/a',
        const Encoding('text/plain;charset=utf-8'),
      );
      final b = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/b',
        const Encoding('text/plain;charset=ascii'),
      );

      expect(a.encoding, equals('text/plain;charset=utf-8'));
      expect(b.encoding, equals('text/plain;charset=ascii'));
      expect(a.encoding, isNot(equals(b.encoding)));
    });

    // The no-schema control for the three legs above: proves the bare id does
    // NOT arrive with a stray separator or an empty schema appended, so the
    // schema assertions are reading a real suffix rather than noise.
    test('an id with no schema arrives with no separator', () async {
      final sample = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/bare',
        Encoding.applicationJson,
      );

      expect(sample.encoding, equals('application/json'));
      expect(sample.encoding, isNot(contains(';')));
    });

    // The leg whose absence is the reason this group grew. The NUL is built
    // at runtime and never spelled in this file: a literal NUL byte in the
    // source would make git treat the file as binary. It is an ordinary byte
    // of the mime value here -- canon takes the mime as pointer+length -- so
    // a channel that stopped at it would deliver 'application/x-nul' and the
    // four legs above would all still pass.
    test('a mime with an interior NUL arrives byte-identical', () async {
      final mime = 'application/x-nul${String.fromCharCode(0)}tail';

      final sample = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/nul',
        Encoding(mime),
      );

      expect(sample.encoding, equals(mime));
      expect(sample.encodingBytes, equals(utf8.encode(mime)));
    });

    // Where both routes can express the pair they must be observationally
    // equal on arrival. Otherwise the structured route would be a second,
    // subtly different encoding surface rather than another spelling of the
    // same one.
    test('the structured and composed routes agree where both work', () async {
      final structured = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/structured',
        Encoding.applicationJson.withSchema('my-schema'),
      );
      final composed = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/composed',
        const Encoding('application/json;my-schema'),
      );

      expect(structured.encoding, equals('application/json;my-schema'));
      expect(composed.encoding, equals('application/json;my-schema'));
      expect(structured.encoding, equals(composed.encoding));
    });

    // And where they cannot: an empty schema. Composed into the mime string
    // of a WELL-KNOWN id, the trailing separator is normalized away by
    // canon's id lookup and the encoding arrives bare -- empty collapses into
    // absent. Set as a value on the schema channel it survives. So the
    // structured route is not sugar over composition; it reaches a wire value
    // composition cannot express, which is exactly why it exists.
    test('only the structured route can carry an empty schema', () async {
      final structured = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/empty-structured',
        Encoding.applicationJson.withSchema(''),
      );
      final composed = await receiveWithEncoding(
        'zenoh/dart/test/enc-schema/empty-composed',
        const Encoding('application/json;'),
      );

      expect(structured.encoding, equals('application/json;'));
      expect(composed.encoding, equals('application/json'));
      expect(structured.encoding, isNot(equals(composed.encoding)));
    });
  });

  // R3: the empty-vs-absent attachment distinction, driven through the real
  // path.
  //
  // sample_test.dart already asserts this distinction, but it does so against
  // a Sample the test constructs itself -- so what it actually pins is that
  // Dart's own constructor stores the two arguments it was handed. Every layer
  // that could conflate empty with absent (the shim's optional-attachment
  // sentinel, the NativePort message encoding, the callback's null handling)
  // sits outside what that test can see; all four of its tests stay green with
  // the entire wire path removed.
  //
  // advanced_subscriber_test.dart drives the same distinction for real, but
  // only on the AdvancedPublisher path, which is unstable-gated and skipped
  // entirely on the stable native. On the stable variant nothing covered this.
  //
  // The legs below publish through plain Session.put/putBytes and read what
  // comes back off the wire.
  group('Attachment empty-vs-absent over the wire (TCP 18880)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18880"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18880"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    // The decisive leg: both messages travel the same path in the same test, so
    // a layer that conflated the two cases would deliver identical attachment
    // views and this cannot pass. Distinct payloads identify which is which
    // without relying on arrival order.
    test('empty attachment and absent attachment stay distinct', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/attach-wire/pair',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final collected = subscriber.stream
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 10));

      session1
        ..put(
          'zenoh/dart/test/attach-wire/pair',
          'with-empty',
          attachment: ZBytes.fromUint8List(Uint8List(0)),
        )
        ..put('zenoh/dart/test/attach-wire/pair', 'with-none');

      final samples = await collected;
      expect(samples, hasLength(2));

      final empty = samples.firstWhere((s) => s.payload == 'with-empty');
      final absent = samples.firstWhere((s) => s.payload == 'with-none');

      // Present-but-empty: a non-null, zero-length attachment.
      expect(
        empty.attachmentBytes,
        isNotNull,
        reason: 'empty attachment arrived as absent',
      );
      expect(empty.attachmentBytes, isEmpty);
      expect(empty.attachment, equals(''));

      // Absent: null on both views.
      expect(
        absent.attachmentBytes,
        isNull,
        reason: 'absent attachment arrived as present',
      );
      expect(absent.attachment, isNull);
    });

    // The non-empty control for the leg above: proves the receive path can
    // produce a populated attachment at all, so `isEmpty` there is a real
    // zero-length read rather than a path that always yields nothing. Binary
    // content also re-checks byte fidelity on the attachment channel, which is
    // where the v0.18.1 class lived.
    test('binary attachment arrives byte-exact over the wire', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/test/attach-wire/binary',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(
        'zenoh/dart/test/attach-wire/binary',
        'payload',
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        ),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(
        sample.attachmentBytes,
        equals([0x00, 0xFF, 0xFE, 0x80, 0x41]),
        reason: 'attachment bytes must be exact, not UTF-8 round-tripped',
      );
      // The lenient String view coexists with the exact bytes: invalid
      // sequences become U+FFFD there and stay exact above.
      expect(sample.attachment, contains('\u{FFFD}'));
    });
  });

  // ---------------------------------------------------------------------
  // Seed #5 rider: `Subscriber.keyExpr`.
  //
  // The plain Subscriber was the ONE entity class without a keyexpr getter --
  // Publisher, Querier, Query, Queryable, Sample and PullSubscriber all have
  // one, and canon exposes `z_subscriber_keyexpr` as part of a uniform
  // six-getter pattern. The caller's key expression was in scope at the
  // declaration site the whole time and simply was never threaded in.
  //
  // MECHANISM: a Dart-side stored string, not a shim read-back. Both were
  // available. The stored string is the majority precedent for entities whose
  // key expression the caller supplies (PullSubscriber, Queryable,
  // LivelinessToken), the `keyExprString` helper that normalizes the
  // String-or-KeyExpr union already exists and is already called at four
  // session.dart sites, and a read-back would have added an export plus a
  // length-carried extraction for a value that never leaves Dart's hands.
  group('Subscriber.keyExpr', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
    });

    tearDownAll(() => session.close());

    test('the getter returns a String-declared key expression', () {
      final sub = session.declareSubscriber('zenoh/dart/sub/ke');
      addTearDown(sub.close);

      expect(sub.keyExpr, equals('zenoh/dart/sub/ke'));
    });

    test('the getter returns a KeyExpr-declared key expression', () {
      final ke = KeyExpr('zenoh/dart/sub/obj');
      addTearDown(ke.dispose);
      final sub = session.declareSubscriber(ke);
      addTearDown(sub.close);

      // Both entry forms of the String-or-KeyExpr union must reach the same
      // value: the getter reads what the union NORMALIZED, not which overload
      // the caller happened to pick.
      expect(sub.keyExpr, equals('zenoh/dart/sub/obj'));
    });

    test('a liveliness subscriber carries it too', () {
      final sub = session.declareLivelinessSubscriber('group1/**');
      addTearDown(sub.close);

      // A different declaration path -- a different C shim entry, and the
      // `fromParts` constructor rather than `declare` -- so it needs its own
      // cell: threading the value through one and not the other would leave
      // this one empty.
      expect(sub.keyExpr, equals('group1/**'));
    });

    test('a wildcard expression reads back exactly as declared', () {
      final sub = session.declareSubscriber('demo/example/**');
      addTearDown(sub.close);

      // No canon round-trip: this is Dart-side storage, so what comes back is
      // the caller's own string rather than anything canon might normalize.
      expect(sub.keyExpr, equals('demo/example/**'));
    });

    test('the value survives close and session close', () async {
      final owner = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      final sub = owner.declareSubscriber('zenoh/dart/sub/survives');

      owner.close();
      sub.close();

      // NO CLOSED-GUARD, deliberately. Reading back what you declared is not
      // an operation on the native handle, so there is nothing for a guard to
      // protect -- and this matches PullSubscriber, whose surviving-keyexpr
      // behaviour is already pinned. The Querier's guard is the outlier here
      // and is deliberately not propagated.
      expect(sub.keyExpr, equals('zenoh/dart/sub/survives'));
    });
  });
}
