// Liveliness token, subscriber, and get tests (Phase 11)
import 'dart:async';
import 'dart:io' show pid;

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Per-PROCESS liveliness namespace.
///
/// ⛔ WHY A NONCE. Liveliness keys live in a namespace shared by every zenoh
/// peer on the machine, and this file's cells assert over a WILDCARD — one of
/// them asserts that *nothing* is alive under it. That assertion is true only
/// while nothing else on the machine declares under the same prefix, which is
/// a property of the machine, not of this file. Nothing in this suite does
/// today (the prefix appears in this file only), so the hazard is latent
/// rather than active — but a second copy of the suite on one machine, or a
/// developer's own peer, reaches it, and the assertion has no way to tell that
/// apart from a product defect.
///
/// ⚠️ THIS IS NOT WHAT MADE THE CELL RED UNDER `--concurrency=4`. That red was
/// `Failed to open session (code: -4)` raised in `setUp`; the assertion never
/// ran. Re-scoping fixes a real latent defect and does NOT clear that red, and
/// reporting it as though it did would be a false green.
final _ns = 'zenoh/liveliness/test/$pid';

void main() {
  group('LivelinessToken lifecycle', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareLivelinessToken returns a LivelinessToken', () {
      final token = session.declareLivelinessToken(
        'demo/example/liveliness-test',
      );
      expect(token, isA<LivelinessToken>());
      token.close();
    });

    test('LivelinessToken.keyExpr returns declared key expression', () {
      final token = session.declareLivelinessToken(
        'demo/example/liveliness-test',
      );
      expect(token.keyExpr, equals('demo/example/liveliness-test'));
      token.close();
    });

    test('LivelinessToken.close completes without error', () {
      final token = session.declareLivelinessToken(
        'demo/example/liveliness-test',
      );
      expect(token.close, returnsNormally);
    });

    test('LivelinessToken.close is idempotent', () {
      final token = session.declareLivelinessToken(
        'demo/example/liveliness-test',
      )..close();
      expect(token.close, returnsNormally);
    });

    test(
      'declareLivelinessToken on closed session throws StateError',
      () async {
        final closedSession = await Session.open()
          ..close();
        expect(
          () => closedSession.declareLivelinessToken(
            'demo/example/liveliness-test',
          ),
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

    test('declareLivelinessToken with invalid key expression throws '
        'ZenohException', () {
      expect(
        () => session.declareLivelinessToken(''),
        throwsA(isA<ZenohException>()),
      );
    });
  });

  group('Liveliness Subscriber (TCP 17500)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17500"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17500"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('declareLivelinessSubscriber returns a Subscriber', () {
      final sub = sessionB.declareLivelinessSubscriber(
        '$_ns/**',
      );
      expect(sub, isA<Subscriber>());
      sub.close();
    });

    test('Subscriber receives PUT when token is declared', () async {
      final sub = sessionB.declareLivelinessSubscriber(
        '$_ns/*',
      );
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final token = sessionA.declareLivelinessToken('$_ns/1');
      addTearDown(token.close);

      final sample = await sub.stream.first.timeout(const Duration(seconds: 5));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('$_ns/1'));
    });

    test('Subscriber receives DELETE when token is closed', () async {
      final sub = sessionB.declareLivelinessSubscriber(
        '$_ns/*',
      );
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final token = sessionA.declareLivelinessToken('$_ns/1');

      // Collect PUT + DELETE in a single subscription
      final samplesFuture = sub.stream
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 10));

      // Close the token after a brief delay to trigger DELETE
      await Future<void>.delayed(const Duration(seconds: 1));
      token.close();

      final samples = await samplesFuture;
      expect(samples[0].kind, equals(SampleKind.put));
      expect(samples[1].kind, equals(SampleKind.delete));
      expect(samples[1].keyExpr, contains('$_ns/1'));
    });

    test(
      'Multiple tokens produce multiple PUT and individual DELETE',
      () async {
        final sub = sessionB.declareLivelinessSubscriber(
          '$_ns/*',
        );
        addTearDown(sub.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Collect all 4 samples (2 PUTs + 2 DELETEs) in a single subscription
        final samplesFuture = sub.stream
            .take(4)
            .toList()
            .timeout(const Duration(seconds: 15));

        final token1 = sessionA.declareLivelinessToken(
          '$_ns/1',
        );
        final token2 = sessionA.declareLivelinessToken(
          '$_ns/2',
        );

        // Wait for PUTs to be delivered before closing
        await Future<void>.delayed(const Duration(seconds: 2));

        // Close tokens sequentially
        token1.close();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        token2.close();

        final samples = await samplesFuture;
        expect(samples, hasLength(4));

        final puts = samples.where((s) => s.kind == SampleKind.put).toList();
        final deletes = samples
            .where((s) => s.kind == SampleKind.delete)
            .toList();
        expect(puts, hasLength(2));
        expect(deletes, hasLength(2));
      },
    );

    test(
      'declareLivelinessSubscriber on closed session throws StateError',
      () async {
        final closedSession = await Session.open()
          ..close();
        expect(
          () => closedSession.declareLivelinessSubscriber(
            '$_ns/**',
          ),
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

    test('declareLivelinessSubscriber with invalid key expression throws '
        'ZenohException', () {
      expect(
        () => sessionA.declareLivelinessSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('Liveliness subscriber close is idempotent', () {
      final sub = sessionA.declareLivelinessSubscriber(
        '$_ns/**',
      )..close();
      expect(sub.close, returnsNormally);
    });
  });

  group('Liveliness Get (TCP 17502)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17502"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17502"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('livelinessGet returns alive token', () async {
      final token = sessionA.declareLivelinessToken(
        '$_ns/get1',
      );
      addTearDown(token.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await sessionB
          .livelinessGet('$_ns/*')
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(replies, hasLength(1));
      expect(replies[0].isOk, isTrue);
      expect(replies[0].ok.keyExpr, contains('$_ns/get1'));
    });

    test('livelinessGet returns empty stream when no tokens alive', () async {
      final replies = await sessionB
          .livelinessGet(
            '$_ns/*',
            timeout: const Duration(seconds: 2),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(replies, isEmpty);
    });

    test('livelinessGet returns empty after token dropped', () async {
      final token = sessionA.declareLivelinessToken(
        '$_ns/get3',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      token.close();
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await sessionB
          .livelinessGet(
            '$_ns/*',
            timeout: const Duration(seconds: 2),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(replies, isEmpty);
    });

    test('livelinessGet with custom timeout', () async {
      final token = sessionA.declareLivelinessToken(
        '$_ns/get4',
      );
      addTearDown(token.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await sessionB
          .livelinessGet(
            '$_ns/*',
            timeout: const Duration(seconds: 5),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(replies, hasLength(1));
      expect(replies[0].isOk, isTrue);
    });

    test('livelinessGet on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.livelinessGet('$_ns/*'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('livelinessGet with invalid key expression throws ZenohException', () {
      expect(() => sessionA.livelinessGet(''), throwsA(isA<ZenohException>()));
    });
  });

  group('Background Liveliness Subscriber (F9, TCP 17545)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17545"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17545"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('token declare/undeclare delivers PUT then DELETE', () async {
      final stream = sessionB.declareBackgroundLivelinessSubscriber(
        'zenoh/liveliness/bg/*',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final samplesFuture = stream
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 10));

      final token = sessionA.declareLivelinessToken('zenoh/liveliness/bg/1');
      await Future<void>.delayed(const Duration(seconds: 1));
      token.close();

      final samples = await samplesFuture;
      expect(samples[0].kind, equals(SampleKind.put));
      expect(samples[1].kind, equals(SampleKind.delete));
      expect(samples[1].keyExpr, contains('zenoh/liveliness/bg/1'));
    });

    test('history replays a pre-existing token as PUT', () async {
      // Session A declares a token BEFORE session B subscribes.
      final token = sessionA.declareLivelinessToken('zenoh/liveliness/bg/hist');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final stream = sessionB.declareBackgroundLivelinessSubscriber(
        'zenoh/liveliness/bg/*',
        history: true,
      );

      final sample = await stream.first.timeout(const Duration(seconds: 5));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('zenoh/liveliness/bg/hist'));
    });

    test('stream completes on session close (no handle, no leak)', () async {
      final stream = sessionB.declareBackgroundLivelinessSubscriber(
        'zenoh/liveliness/bg/*',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Hold the stream, then close B's session — the background subscriber is
      // dropped internally by zenoh-c, posting a null sentinel that completes
      // the stream. No explicit close call on the stream.
      final doneFuture = stream.toList().timeout(const Duration(seconds: 5));
      sessionB.close();

      // Completion is the assertion: toList resolves without timing out.
      await doneFuture;
    });

    test('invalid key expression throws ZenohException', () {
      expect(
        () => sessionA.declareBackgroundLivelinessSubscriber(
          'not a valid ke ***',
        ),
        throwsA(isA<ZenohException>()),
      );
    });
  });

  group('Liveliness Subscriber History (TCP 17501)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17501"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17501"]'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('history=true receives existing alive tokens as PUT', () async {
      // Session A declares a token BEFORE session B subscribes
      final token = sessionA.declareLivelinessToken(
        '$_ns/hist1',
      );
      addTearDown(token.close);

      // Wait for token to propagate
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Session B subscribes with history: true — should receive existing token
      final sub = sessionB.declareLivelinessSubscriber(
        '$_ns/*',
        history: true,
      );
      addTearDown(sub.close);

      final sample = await sub.stream.first.timeout(const Duration(seconds: 5));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('$_ns/hist1'));
    });

    test('history=false does NOT receive existing alive tokens', () async {
      // Session A declares a token BEFORE session B subscribes
      final token = sessionA.declareLivelinessToken(
        '$_ns/hist2',
      );
      addTearDown(token.close);

      // Wait for token to propagate
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Session B subscribes with history: false (default) — should NOT
      // receive the existing token
      final sub = sessionB.declareLivelinessSubscriber(
        '$_ns/*',
      );
      addTearDown(sub.close);

      // Wait 2 seconds and verify no sample arrives
      expect(
        () => sub.stream.first.timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
  // -------------------------------------------------------------------------
  // Seed #6 Slice 1: the timeout-zero contract on the liveliness get.
  //
  // The asymmetry with `Session.get` is canon's, not ours. `z_get` treats
  // `timeout_ms == 0` as "use the config default"; `z_liveliness_get` applies
  // the value unconditionally (measured; recorded at zenoh_dart.h's
  // zd_liveliness_get contract). So on this entry zero is a real, expressible
  // value -- an immediate expiry -- and refusing it would be the binding
  // inventing a restriction canon does not have.
  group('Slice 1: liveliness timeout-zero is a real value (TCP 19331)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19331"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19331"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('Duration.zero is accepted on livelinessGet and delivery survives', () async {
      final token = sessionA.declareLivelinessToken('zenoh/live/s1/zero');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await sessionB
          .livelinessGet('zenoh/live/s1/*', timeout: Duration.zero)
          .toList()
          .timeout(const Duration(seconds: 5));

      // MEASURED, and it is not what the plan predicted. A zero liveliness
      // timeout does NOT expire the get: the alive token's reply arrives, 30/30
      // over repeated runs (probe + verbatim output at
      // development/research/probes-seed6-ci-20260819/). The cell pins the
      // observation rather than the wish.
      //
      // The sentinel-vs-literal question behind it is NOT discriminable through
      // this stack: a liveliness get completes as soon as the peers have
      // answered -- 0-2 ms with or without an alive token, at every timeout
      // value -- so the timer never bites and both readings predict this same
      // observable. THAT is why zero is honoured here while Session.get refuses
      // it: on `get` the substitution is observable (an instant-expiry request
      // silently waits ~10 s); here there is no observable to be wrong about,
      // and refusing would invent a restriction with nothing behind it.
      expect(replies, hasLength(1));
      expect(replies.single.isOk, isTrue);
      expect(replies.single.ok.keyExpr, contains('zenoh/live/s1/zero'));
    });

    test('a null liveliness timeout still uses the explicit 10 s', () async {
      final token = sessionA.declareLivelinessToken('zenoh/live/s1/null');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      // The positive control for the cell above: the same topology WITH the
      // binding's explicit 10000 delivers, so the empty result there is the
      // zero timeout's doing and not a dead route.
      final replies = await sessionB
          .livelinessGet('zenoh/live/s1/*')
          .toList()
          .timeout(const Duration(seconds: 15));

      expect(replies, hasLength(1));
      expect(replies.single.isOk, isTrue);
      expect(replies.single.ok.keyExpr, contains('zenoh/live/s1/null'));
    });
  });
  // -------------------------------------------------------------------------
  // Slice 16: the liveliness-get channel carrier.
  //
  // The other thin reply carrier: same handler type, same tee, same shared
  // construction and extraction bodies, same `PullReplies` class as
  // `Session.pullGet`. Only the canon entry and its options struct differ.
  group('Slice 16: pullLivelinessGet (TCP 19381)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19381"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19381"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    Future<List<Reply>> drain(PullReplies replies) async {
      final got = <Reply>[];
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        final r = replies.tryRecv();
        if (r is RecvData<Reply>) {
          got.add(r.value);
        } else if (r is RecvDisconnected<Reply>) {
          return got;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      return got;
    }

    test('a fifo channel delivers alive tokens, then disconnects', () async {
      final token = sessionA.declareLivelinessToken('zenoh/live/s16/fifo');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = sessionB.pullLivelinessGet(
        'zenoh/live/s16/*',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(replies.dispose);

      final got = await drain(replies);
      expect(got, hasLength(1));
      expect(got.single.isOk, isTrue);
      expect(got.single.ok.keyExpr, contains('zenoh/live/s16/fifo'));
      expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'the channel reaches the terminal state with no tokens alive',
      () async {
        final replies = sessionB.pullLivelinessGet(
          'zenoh/live/s16/nobody/*',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(replies.dispose);

        expect(await drain(replies), isEmpty);
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('the ring channel reports the measured discard, deterministically', () async {
      final token = sessionA.declareLivelinessToken('zenoh/live/s16/ring');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = sessionB.pullLivelinessGet(
        'zenoh/live/s16/ring',
        kind: ChannelKind.ring,
        capacity: 4,
      );
      addTearDown(replies.dispose);

      // SETTLE TIME, not a race: a liveliness get completes in milliseconds, so
      // this is "let it finish before looking" -- and the point of the cell is
      // to look AFTER completion, where a ring has discarded its buffer.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        await drain(replies),
        isEmpty,
        reason: 'a ring recovers nothing once the channel has disconnected',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Duration.zero is honoured here too', () async {
      // Matching the Slice 1 ruling for this carrier: the liveliness entries
      // accept zero, and the channel mode inherits that contract rather than
      // inventing a stricter one.
      final token = sessionA.declareLivelinessToken('zenoh/live/s16/zero');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = sessionB.pullLivelinessGet(
        'zenoh/live/s16/zero',
        kind: ChannelKind.fifo,
        capacity: 4,
        timeout: Duration.zero,
      );
      addTearDown(replies.dispose);

      expect(await drain(replies), hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a negative capacity is refused before any native call', () {
      for (final kind in ChannelKind.values) {
        expect(
          () => sessionB.pullLivelinessGet(
            'zenoh/live/s16/neg',
            kind: kind,
            capacity: -1,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('capacity'),
            ),
          ),
          reason: 'kind=$kind',
        );
      }
    });
  });
  // -------------------------------------------------------------------------
  // Slice 17: the fifth carrier — the liveliness subscriber's channel mode.
  //
  // The thinnest of the six channel-mode entries: canon's liveliness declare
  // consumes the SAMPLE closure, so this reuses seed #5's shipped tee,
  // handlers, `RecvResult<Sample>`, capacity contract, extraction body and
  // handle class wholesale. Only the canon entry and its one-field options
  // struct differ, which is why these cells are smoke rather than a fourth
  // full matrix.
  //
  // What it delivers is the alive/gone TRANSITIONS, with history — a different
  // capability from `livelinessGet`'s snapshot of who is alive now.
  group('Slice 17: declarePullLivelinessSubscriber (TCP 19382)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19382"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19382"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    Future<List<Sample>> collect(
      PullSubscriber pull,
      int want, {
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final got = <Sample>[];
      final deadline = DateTime.now().add(timeout);
      while (got.length < want && DateTime.now().isBefore(deadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Sample>) {
          got.add(r.value);
        } else if (r is RecvDisconnected<Sample>) {
          break;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      return got;
    }

    test(
      'token appearance and disappearance arrive as put then delete',
      () async {
        final pull = sessionB.declarePullLivelinessSubscriber(
          'zenoh/live/s17/**',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        final token = sessionA.declareLivelinessToken('zenoh/live/s17/fifo');
        await Future<void>.delayed(const Duration(seconds: 1));
        token.close();

        final got = await collect(pull, 2);
        expect(got, hasLength(2));
        expect(got[0].kind, equals(SampleKind.put));
        expect(got[0].keyExpr, contains('zenoh/live/s17/fifo'));
        expect(got[1].kind, equals(SampleKind.delete));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('the same transitions arrive through a ring channel', () async {
      final pull = sessionB.declarePullLivelinessSubscriber(
        'zenoh/live/s17r/**',
        kind: ChannelKind.ring,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final token = sessionA.declareLivelinessToken('zenoh/live/s17r/ring');
      await Future<void>.delayed(const Duration(seconds: 1));
      token.close();

      final got = await collect(pull, 2);
      expect(got, hasLength(2));
      expect(
        got.map((s) => s.kind).toList(),
        equals([SampleKind.put, SampleKind.delete]),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('history: true replays a token that was already alive', () async {
      final token = sessionA.declareLivelinessToken('zenoh/live/s17h/pre');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final pull = sessionB.declarePullLivelinessSubscriber(
        'zenoh/live/s17h/**',
        kind: ChannelKind.fifo,
        capacity: 4,
        history: true,
      );
      addTearDown(pull.close);

      final got = await collect(pull, 1);
      expect(got, hasLength(1));
      expect(got.single.kind, equals(SampleKind.put));
      expect(got.single.keyExpr, contains('zenoh/live/s17h/pre'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('history omitted does NOT replay a pre-existing token', () async {
      // THE CONTROL that makes the cell above a real observation rather than a
      // token that happened to be re-announced.
      final token = sessionA.declareLivelinessToken('zenoh/live/s17n/pre');
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final pull = sessionB.declarePullLivelinessSubscriber(
        'zenoh/live/s17n/**',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);

      expect(
        await collect(pull, 1, timeout: const Duration(seconds: 3)),
        isEmpty,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('recv() parks and wakes on this carrier', () async {
      // The park-then-wake path through THIS entry — the only thing that
      // exercises the tee interposition on the fifth carrier's own declare.
      final pull = sessionB.declarePullLivelinessSubscriber(
        'zenoh/live/s17w/**',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final pending = pull.recv();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final token = sessionA.declareLivelinessToken('zenoh/live/s17w/late');
      addTearDown(token.close);

      final result = await pending.timeout(const Duration(seconds: 15));
      expect(result, isA<RecvData<Sample>>());
      final sample = (result as RecvData<Sample>).value;
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('zenoh/live/s17w/late'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the per-kind drain contract holds at the terminal trigger', () async {
      // ⚠️ THE TRIGGER IS THE SUBSCRIBER'S OWN SESSION CLOSING, not the token
      // publisher's — and getting that wrong is what a first version of this
      // cell did. A subscriber's channel is fed by ITS session's closure, so
      // closing the token's session leaves the channel wide open and the ring
      // still holding everything it buffered (measured: 2 recovered where 0 was
      // expected). Closing the subscriber's session under a RETAINED handle is
      // the one terminal trigger that leaves the handle alive to be polled,
      // exactly as on the query column.
      for (final kind in ChannelKind.values) {
        final port = kind == ChannelKind.fifo ? 19383 : 19384;
        final producer = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final consumer = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        await Future<void>.delayed(const Duration(seconds: 1));

        final pull = consumer.declarePullLivelinessSubscriber(
          'zenoh/live/s17d/**',
          kind: kind,
          capacity: 4,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final token = producer.declareLivelinessToken('zenoh/live/s17d/tok');
        await Future<void>.delayed(const Duration(seconds: 1));
        token.close();
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Buffered and unread, then the SUBSCRIBER's session dies under the
        // retained handle.
        consumer.close();
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final drained = <Sample>[];
        var terminal = false;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!terminal && DateTime.now().isBefore(deadline)) {
          final r = pull.tryRecv();
          if (r is RecvData<Sample>) {
            drained.add(r.value);
          } else if (r is RecvDisconnected<Sample>) {
            terminal = true;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        if (kind == ChannelKind.fifo) {
          expect(drained, isNotEmpty, reason: 'fifo drains what it holds');
        } else {
          expect(drained, isEmpty, reason: 'ring discards at disconnect');
        }
        pull.close();
        producer.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a negative capacity is refused before any native declaration', () {
      for (final kind in ChannelKind.values) {
        expect(
          () => sessionB.declarePullLivelinessSubscriber(
            'zenoh/live/s17/neg',
            kind: kind,
            capacity: -1,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('capacity'),
            ),
          ),
          reason: 'kind=$kind',
        );
      }
    });
  });
}
