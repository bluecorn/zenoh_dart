import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

void main() {
  group('PullSubscriber lifecycle', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
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

    test('tryRecv reports an empty live channel as empty, not absent', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull/empty');
      addTearDown(pullSub.close);

      // Canon's Z_CHANNEL_NODATA: "the channel is still alive, but its buffer
      // is empty" -- a later call may well succeed. Until the retype this and
      // a DEAD channel were the same `null`, so a poller could not tell "back
      // off and try again" from "stop, nothing will ever come".
      expect(pullSub.tryRecv(), isA<RecvEmpty<Sample>>());
    });

    test('PullSubscriber.close is idempotent', () {
      final pullSub = session.declarePullSubscriber(
        'demo/example/pull/idempotent',
      )..close();
      expect(pullSub.close, returnsNormally);
    });

    test('tryRecv on closed PullSubscriber throws StateError', () {
      final pullSub = session.declarePullSubscriber('demo/example/pull/closed')
        ..close();
      expect(pullSub.tryRecv, throwsA(isA<StateError>()));
    });
  });

  group('Ring buffer lossy behavior (TCP 17481)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17481"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17481"]');
      session2 = await Session.open(config: config2);

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

      // Settle time for the 10-message burst, deliberately NOT converted to a
      // poll: the eviction assertion below is about which samples survive, so
      // draining as soon as the first arrives would read a mid-burst ring.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Drain the ring buffer
      final samples = <Sample>[];
      for (var i = 0; i < 20; i++) {
        final r = pullSub.tryRecv();
        if (r case RecvData(:final value)) {
          samples.add(value);
        } else {
          break;
        }
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

      session1
        ..put('zenoh/dart/test/pull/cap1', 'first')
        ..put('zenoh/dart/test/pull/cap1', 'second')
        ..put('zenoh/dart/test/pull/cap1', 'third');

      // Settle time for the burst, deliberately NOT converted to a poll: with
      // capacity 1 the ring holds one sample at a time, so draining as soon as
      // anything arrives would consume 'first' and change what the test means.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final result = pullSub.tryRecv();
      expect(result, isA<RecvData<Sample>>());
      // With capacity 1, only the latest should remain
      expect((result as RecvData<Sample>).value.payload, equals('third'));

      // Drained, but still ALIVE -- empty, not disconnected.
      expect(pullSub.tryRecv(), isA<RecvEmpty<Sample>>());
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

      final sample = await pollRecv(pullSub);
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

      final sample = await pollRecv(pullSub);
      expect(sample, isNotNull);
      expect(sample!.payloadBytes, equals(utf8.encode('valid payload')));
      // Byte-exact recovery of the invalid-UTF-8 attachment (no U+FFFD).
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test(
      'tryRecv reports present-but-empty attachment as non-null empty',
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

        final sample = await pollRecv(pullSub);
        expect(sample, isNotNull);
        // Empty (non-null) is distinct from absent (null) -- conflation fixed.
        expect(sample!.attachmentBytes, isNotNull);
        expect(sample.attachmentBytes, hasLength(0));
      },
    );

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

      final sample = await pollRecv(pullSub);
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

      final sample = await pollRecv(pullSub);
      expect(sample, isNotNull);
      expect(sample!.kind, equals(SampleKind.delete));
    });
  });

  group('Lifecycle and error handling (TCP 17482)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17482"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17482"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('PullSubscriber.close is idempotent', () {
      final pullSub = session1.declarePullSubscriber(
        'zenoh/dart/test/pull/idem2',
      )..close();
      expect(pullSub.close, returnsNormally);
    });

    test('tryRecv after close throws StateError', () {
      final pullSub = session1.declarePullSubscriber(
        'zenoh/dart/test/pull/closed2',
      )..close();
      expect(
        pullSub.tryRecv,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('declarePullSubscriber on closed session throws StateError', () async {
      final tempConfig = Config();
      final tempSession = await Session.open(config: tempConfig)
        ..close();
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

      session1
        ..put('zenoh/dart/test/pull/wild/a', 'alpha')
        ..put('zenoh/dart/test/pull/wild/b', 'beta');

      // Drain repeatedly until both samples have arrived, rather than sleeping
      // once and draining once. The condition is "both puts delivered", which
      // is pollable; a single drain behind a fixed sleep reads whatever
      // happened to be in the ring at that instant.
      final samples = <Sample>[];
      await waitUntil(() {
        while (true) {
          if (pullSub.tryRecv() case RecvData(:final value)) {
            samples.add(value);
          } else {
            break;
          }
        }
        return samples.length >= 2;
      }, description: 'both wildcard samples');

      expect(samples, hasLength(2));

      final keyExprs = samples.map((s) => s.keyExpr).toSet();
      expect(keyExprs, contains('zenoh/dart/test/pull/wild/a'));
      expect(keyExprs, contains('zenoh/dart/test/pull/wild/b'));

      final payloads = samples.map((s) => s.payload).toSet();
      expect(payloads, contains('alpha'));
      expect(payloads, contains('beta'));
    });
  });

  group('Pull-subscriber QoS/timestamp metadata (TCP 17532)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17532"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17532"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('pull-received sample carries publisher QoS', () async {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/qos',
        priority: Priority.realTime,
        congestionControl: CongestionControl.block,
      );
      addTearDown(publisher.close);

      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/qos',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('qos payload');

      final sample = await pollRecv(pullSub);
      expect(sample, isNotNull);
      expect(sample!.priority, equals(Priority.realTime));
      expect(sample.congestionControl, equals(CongestionControl.block));
      expect(sample.express, isFalse);
    });

    test('pull-received sample without timestamp reports null', () async {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/no-ts',
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Plain put on a non-timestamping session -> no timestamp attached.
      session1.put('zenoh/dart/test/pull/no-ts', 'no timestamp');

      final sample = await pollRecv(pullSub);
      expect(sample, isNotNull);
      expect(sample!.timestamp, isNull);
    });

    test('empty buffer reports empty cleanly with widened signature', () {
      final pullSub = session2.declarePullSubscriber(
        'zenoh/dart/test/pull/qos-empty',
      );
      addTearDown(pullSub.close);

      // No data published -> tryRecv must not touch the new out-params and
      // reports the alive-and-empty state cleanly (no crash/leak from the
      // widened signature).
      expect(pullSub.tryRecv(), isA<RecvEmpty<Sample>>());
    });
  });

  group('PullSubscriber integration (two sessions, TCP 17480)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17480"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17480"]');
      session2 = await Session.open(config: config2);

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
      final sample = await pollRecv(pullSub);
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

      final sample = await pollRecv(pullSub);
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

      session1
        ..put('zenoh/dart/test/pull/multi', 'msg1')
        ..put('zenoh/dart/test/pull/multi', 'msg2')
        ..put('zenoh/dart/test/pull/multi', 'msg3');

      // Poll until all three have arrived (see the wildcard test above).
      final samples = <Sample>[];
      await waitUntil(() {
        while (true) {
          if (pullSub.tryRecv() case RecvData(:final value)) {
            samples.add(value);
          } else {
            break;
          }
        }
        return samples.length >= 3;
      }, description: 'all three samples');

      expect(samples, hasLength(3));
      expect(samples[0].payload, equals('msg1'));
      expect(samples[1].payload, equals('msg2'));
      expect(samples[2].payload, equals('msg3'));

      // 4th tryRecv: drained but alive -- empty, not disconnected.
      expect(pullSub.tryRecv(), isA<RecvEmpty<Sample>>());
    });
  });

  // R3: the PullSubscriber's terminal state when the SESSION closes underneath
  // it -- the shutdown ordering nothing covered.
  //
  // This matters more here than for the callback Subscriber. tryRecv() is
  // synchronous and reaches into the native channel on the calling thread,
  // so if the session's teardown invalidated anything the buffer refers to,
  // this is where a use-after-free would surface, and it would surface as a
  // plausible-looking return value rather than a crash.
  //
  // The distinction these tests draw is now THREE-way, which is seed #5's
  // primary RED. Before the retype the group asserted that after the session
  // closes tryRecv() "reports nothing available (null)" -- the same null an
  // alive-but-empty channel returns, and the same null the shim's
  // allocation-failure leg returned. Canon has never conflated them: the
  // session's teardown drops the producer closure, so the handler observes
  // Z_CHANNEL_DISCONNECTED (1), which is a DIFFERENT code from
  // Z_CHANNEL_NODATA (2). What the surface reports now:
  //
  //   session closed underneath a live handle -> RecvDisconnected (terminal)
  //   alive, nothing buffered                 -> RecvEmpty       (keep polling)
  //   this subscriber's own close()           -> StateError      (misuse)
  //
  // The last is ours, not canon's, and it is load-bearing rather than
  // decorative: loaning a dropped handler is undefined behaviour in canon
  // (`unwrap_unchecked`), never an error it reports.
  group('PullSubscriber terminal state after session close (TCP 18861)', () {
    // Each test destroys its session, so the session is per-test.
    Future<Session> isolatedSession() {
      final config = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18861"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      return Session.open(config: config);
    }

    // A buffered sample is DROPPED when the session closes -- and this test
    // proves that rather than asserting it: the same subscriber is shown
    // returning a real sample first (the positive control), so the terminal
    // answer after the close cannot be the vacuous "nothing was ever
    // published" one. The second sample is buffered and never read before the
    // close, so what the channel reports is a sample that existed and is gone.
    //
    // This is canon's RING behaviour, rendered unsmoothed: a ring discards its
    // buffer on disconnect. The fifo kind does the opposite -- it drains what
    // it holds and only then reports disconnected -- and that asymmetry is
    // canon's own, measured, and documented per kind rather than papered over.
    test('a buffered ring sample is lost at session close, and the channel '
        'reports disconnected', () async {
      final listener = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18862"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      final publisherSession = await Session.open(config: listener);
      addTearDown(publisherSession.close);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connector = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18862"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      final subscriberSession = await Session.open(config: connector);

      await Future<void>.delayed(const Duration(seconds: 1));

      final pullSub = subscriberSession.declarePullSubscriber(
        'zenoh/dart/test/psc/recv',
        capacity: 8,
      );
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      // Positive control: the ring delivers.
      publisherSession.put('zenoh/dart/test/psc/recv', 'first');
      Sample? first;
      await waitUntil(() {
        if (pullSub.tryRecv() case RecvData(:final value)) {
          first = value;
          return true;
        }
        return false;
      }, description: 'first sample buffered');
      expect(first!.payload, equals('first'));

      // Buffer a second sample and deliberately do NOT read it.
      publisherSession.put('zenoh/dart/test/psc/recv', 'second');
      await Future<void>.delayed(const Duration(seconds: 1));

      subscriberSession.close();

      // Legal call, TERMINAL answer -- not a StateError, which is what the
      // subscriber's own close produces (a later test), and not RecvEmpty,
      // which would mean "keep polling". The unread 'second' sample is gone
      // with the session: this is the ring discarding its buffer.
      expect(pullSub.tryRecv(), isA<RecvDisconnected<Sample>>());
      // Repeated: a first call that corrupted state would show up here.
      expect(pullSub.tryRecv(), isA<RecvDisconnected<Sample>>());
    });

    // NEW cell (seed #5). The one above needs a buffered sample to make its
    // point about loss; this one isolates the terminal state itself, on a
    // channel that never held anything, and pins that it is STICKY. Canon
    // makes disconnected a permanent property of the handler rather than a
    // one-shot notification, and the whole never-hangs argument for the async
    // recv() rests on that: a lost readiness signal cannot become a hang,
    // because every subsequent try_recv still reports the terminal state.
    test('a dead channel reports disconnected, repeatably', () async {
      final session = await isolatedSession();
      final pullSub = session.declarePullSubscriber(
        'zenoh/dart/test/psc/sticky',
        capacity: 8,
      );

      // Alive and empty FIRST -- the control. Without it a green below would
      // be indistinguishable from a subscriber that reported disconnected
      // from the moment it was declared.
      expect(pullSub.tryRecv(), isA<RecvEmpty<Sample>>());

      session.close();

      expect(pullSub.tryRecv(), isA<RecvDisconnected<Sample>>());
      expect(pullSub.tryRecv(), isA<RecvDisconnected<Sample>>());
      expect(pullSub.tryRecv(), isA<RecvDisconnected<Sample>>());

      // ...and our own guard is a DIFFERENT thing from canon's state.
      pullSub.close();
      expect(pullSub.tryRecv, throwsStateError);
    });

    test('tryRecv after the subscriber closes throws StateError', () async {
      final session = await isolatedSession();
      final pullSub = session.declarePullSubscriber(
        'zenoh/dart/test/psc/closed',
        capacity: 8,
      );
      addTearDown(session.close);

      pullSub.close();

      expect(pullSub.tryRecv, throwsStateError);
    });

    test('keyExpr survives session close, and close() stays safe', () async {
      final session = await isolatedSession();
      final pullSub = session.declarePullSubscriber(
        'zenoh/dart/test/psc/keyexpr',
        capacity: 8,
      );

      session.close();

      // keyExpr is Dart-side state, so it must not be lost with the session.
      expect(pullSub.keyExpr, equals('zenoh/dart/test/psc/keyexpr'));
      expect(pullSub.close, returnsNormally);
      expect(pullSub.close, returnsNormally);
    });
  });
}
