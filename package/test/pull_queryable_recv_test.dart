// Seed #6 slice 15: async `recv()` on the query channel, and the query-side
// overflow prong.
//
// The recv machinery is the reply column's, pointed at a query-typed tee — the
// head is payload-agnostic and the two exported entries are shared. What is NOT
// shared is the overflow behaviour, and it is the seed's second mandatory
// prong: while a fifo query channel sits full, the hosting session's INBOUND
// QUERY DELIVERY STALLS SESSION-WIDE. A co-hosted queryable goes unanswered
// until the channel is drained, which is a sharper edge than "your own channel
// is full" and is exactly what a user needs told.
//
// ⚠️ TWO SESSIONS for every overflow cell. Same-session delivery runs inside
// the getter's own `z_get` call, so a full fifo there freezes that call
// inside the FFI boundary with no timeout escape.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final hostSession = await Session.open(config: listener);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final getterSession = await Session.open(config: connector);
    await Future<void>.delayed(const Duration(seconds: 1));
    return (hostSession, getterSession);
  }

  group('Slice 15: recv() on the query channel (TCP 19391)', () {
    late Session hostSession;
    late Session getterSession;

    setUpAll(() async {
      (hostSession, getterSession) = await sessionPair(19391);
    });

    tearDownAll(() {
      getterSession.close();
      hostSession.close();
    });

    PullQueryable channelOn(String key) => hostSession.declarePullQueryable(
      key,
      kind: ChannelKind.fifo,
      capacity: 4,
    );

    test('buffered data completes recv() immediately; an empty channel parks', () async {
      const bufferedKey = 'zenoh/dart/test/s15/buffered';
      final buffered = channelOn(bufferedKey);
      addTearDown(buffered.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      unawaited(
        getterSession
            .get(bufferedKey, timeout: const Duration(seconds: 20))
            .toList(),
      );
      // Settle so the query is already in the buffer: this half is about the
      // "already there" path, not the parking one.
      await Future<void>.delayed(const Duration(seconds: 1));
      final immediate = await buffered.recv().timeout(
        const Duration(seconds: 5),
      );
      expect(immediate, isA<RecvData<Query>>());
      (immediate as RecvData<Query>).value.dispose();

      const parkKey = 'zenoh/dart/test/s15/park';
      final parking = channelOn(parkKey);
      addTearDown(parking.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final pending = parking.recv();
      // The getter goes out AFTER the waiter has parked, so a recv() that only
      // ever looked once would still be waiting.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      unawaited(
        getterSession
            .get(parkKey, timeout: const Duration(seconds: 20))
            .toList(),
      );

      final woken = await pending.timeout(const Duration(seconds: 15));
      expect(woken, isA<RecvData<Query>>());
      (woken as RecvData<Query>).value.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a pending recv() resolves disconnected at close()', () async {
      final pull = channelOn('zenoh/dart/test/s15/close-pending');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final pending = pull.recv();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      pull.close();

      // Completed FIRST, before any native release.
      final result = await pending.timeout(const Duration(seconds: 5));
      expect(result, isA<RecvDisconnected<Query>>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('one pending recv() at a time, and an interleaved tryRecv re-arms', () async {
      const key = 'zenoh/dart/test/s15/rearm';
      final pull = channelOn(key);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final pending = pull.recv();
      var pendingDone = false;
      RecvResult<Query>? pendingResult;
      unawaited(
        pending.then((r) {
          pendingDone = true;
          pendingResult = r;
        }),
      );

      // One at a time: the native handler is move-only and single-consumer.
      expect(pull.recv, throwsA(isA<StateError>()));

      // ⚠️ NO `await` IN THIS LOOP. `Session.get` pushes the query through a
      // SYNCHRONOUS FFI call, so — unlike the reply column, which needed a
      // subprocess producer — the query arrives with the Dart event loop
      // stopped, and `tryRecv` reads the native channel directly. An await here
      // would let the readiness ping be delivered and the pending recv would
      // take the query instead, which is the opposite interleaving.
      unawaited(
        getterSession
            .get(key, parameters: 'n=1', timeout: const Duration(seconds: 30))
            .toList(),
      );
      var stolen = const RecvEmpty<Query>() as RecvResult<Query>;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (stolen is RecvEmpty<Query> && DateTime.now().isBefore(deadline)) {
        stolen = pull.tryRecv();
      }
      expect(stolen, isA<RecvData<Query>>());
      (stolen as RecvData<Query>).value.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        pendingDone,
        isFalse,
        reason:
            'the pending recv() must still be pending — the interleaved '
            'tryRecv took the only query',
      );

      // THE RE-ARM LEG: the delivery that pinged us already cleared the flag,
      // so without the re-arm the next arrival would post nothing.
      unawaited(
        getterSession
            .get(key, parameters: 'n=2', timeout: const Duration(seconds: 30))
            .toList(),
      );
      final result = await pending.timeout(const Duration(seconds: 20));
      expect(result, isA<RecvData<Query>>());
      final query = (result as RecvData<Query>).value;
      expect(query.parameters, equals('n=2'));
      query.dispose();
      expect(pendingResult, same(result));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a pending recv() resolves disconnected when the session closes', () async {
      // The other terminal trigger, through the same tee-sentinel path as
      // close() — differing only in what drops the closure. No fifo-full state
      // can arise here, because nothing is ever sent.
      final (ownHost, ownGetter) = await sessionPair(19392);
      addTearDown(ownGetter.close);

      final pull = ownHost.declarePullQueryable(
        'zenoh/dart/test/s15/session-close',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final pending = pull.recv();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      ownHost.close();

      final result = await pending.timeout(const Duration(seconds: 15));
      expect(result, isA<RecvDisconnected<Query>>());
      pull.close();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ---------------------------------------------------------------------------
  // Slice 15's second half: the query-side overflow prong and its co-hosted
  // stall — criterion C's twin.
  group('Slice 15: query-side overflow and the co-hosted stall', () {
    test('a fifo query channel at capacity is lossless once drained, and every '
        'getter call returns', () async {
      final (hostSession, getterSession) = await sessionPair(19393);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      const key = 'zenoh/dart/test/s15/overflow/fifo';
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 1,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Three getters against a capacity-1 channel that is not drained until
      // all three have been sent. Across two sessions the GETTER IS NEVER THE
      // BLOCKED PARTY, which is the property the first assertion pins.
      final gets = <Future<List<Reply>>>[];
      for (var i = 0; i < 3; i++) {
        gets.add(
          getterSession
              .get(
                key,
                parameters: 'n=$i',
                timeout: const Duration(seconds: 30),
              )
              .toList(),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));

      final drained = <String>[];
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (drained.length < 3 && DateTime.now().isBefore(deadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Query>) {
          drained.add(r.value.parameters);
          r.value
            ..reply(key, 'ack')
            ..dispose();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      expect(drained, equals(['n=0', 'n=1', 'n=2']));
      for (final g in gets) {
        expect(
          await g.timeout(const Duration(seconds: 30)),
          hasLength(1),
          reason: 'every getter call must have returned and been answered',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('a co-hosted queryable KEEPS ANSWERING while the channel sits full', () async {
      // ⚠️ THIS CELL PINS A MEASUREMENT THAT CONTRADICTS THE SEED'S GROUND
      // TRUTH, and it is written that way deliberately rather than tuned until
      // it agreed. The seed records, from a canon-direct probe, that while a
      // fifo query channel sits full the hosting session's inbound query
      // delivery stalls SESSION-WIDE — a co-hosted queryable's canary going
      // unanswered during the wedge and answering again after the drain.
      //
      // Through this stack it does not reproduce. MEASURED 2026-08-19 over five
      // configurations (probe + verbatim output at
      // test/helpers/probes/probe_query_stall.dart):
      //
      //   baseline                          canary=1
      //   cap=1 volume=4   duringWedge=1  drained=4   after=1
      //   cap=1 volume=10  duringWedge=1  drained=10  after=1
      //   cap=2 volume=10  duringWedge=1  drained=10  after=1
      //   cap=1 volume=30  duringWedge=1  drained=30  after=1
      //   cap=0 volume=4   duringWedge=1  drained=4   after=1
      //
      // The canary answers in every configuration, including capacity 0 and a
      // thirty-deep wedge — and every wedge query is still recovered once
      // drained, so the queries are queueing upstream of the delivery path that
      // serves other queryables rather than blocking it. Whether the difference
      // is the topology, the zenoh version, or the canon-direct probe's own
      // shape is NOT determined here, and no explanation is asserted: the cell
      // records the observable and the divergence is reported.
      //
      // What this cell is therefore FOR: it is a regression pin on the
      // favourable behaviour. If a future change does introduce a session-wide
      // stall, this goes red and names it.
      final (hostSession, getterSession) = await sessionPair(19394);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      const wedgeKey = 'zenoh/dart/test/s15/stall/wedge';
      const canaryKey = 'zenoh/dart/test/s15/stall/canary';

      // The CANARY is an ordinary Stream-path queryable, CO-HOSTED on the same
      // session, with nothing to do with the channel.
      final canary = hostSession.declareQueryable(canaryKey);
      addTearDown(canary.close);
      canary.stream.listen((query) {
        query
          ..reply(canaryKey, 'canary')
          ..dispose();
      });

      final pull = hostSession.declarePullQueryable(
        wedgeKey,
        kind: ChannelKind.fifo,
        capacity: 1,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      Future<int> canaryReplies() async =>
          (await getterSession
                  .get(canaryKey, timeout: const Duration(seconds: 3))
                  .toList()
                  .timeout(const Duration(seconds: 15)))
              .length;

      // PRE-WEDGE CONTROL: without it, a during-wedge answer could be a canary
      // that answers regardless of anything, which would make the cell empty.
      expect(await canaryReplies(), equals(1), reason: 'canary before wedge');

      // Wedge it: far more getters than the channel can hold, none drained.
      final wedgeGets = <Future<List<Reply>>>[];
      for (var i = 0; i < 10; i++) {
        wedgeGets.add(
          getterSession
              .get(wedgeKey, timeout: const Duration(seconds: 60))
              .toList(),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        await canaryReplies(),
        equals(1),
        reason: 'MEASURED: the co-hosted queryable keeps answering',
      );

      // The wedge is real, not an empty channel: draining recovers every query
      // that was sent, which is also the losslessness half.
      var drained = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (drained < 10 && DateTime.now().isBefore(deadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Query>) {
          drained++;
          r.value
            ..reply(wedgeKey, 'ack')
            ..dispose();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(drained, equals(10), reason: 'the wedge must have been real');
      for (final g in wedgeGets) {
        await g.timeout(const Duration(seconds: 60));
      }

      expect(await canaryReplies(), equals(1), reason: 'canary after drain');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the ring twin loses, remote-visible as a getter timeout', () async {
      final (hostSession, getterSession) = await sessionPair(19395);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      const key = 'zenoh/dart/test/s15/overflow/ring';
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.ring,
        capacity: 1,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final gets = <Future<List<Reply>>>[];
      for (var i = 0; i < 3; i++) {
        gets.add(
          getterSession
              .get(key, parameters: 'n=$i', timeout: const Duration(seconds: 5))
              .toList(),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));

      var drained = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final r = pull.tryRecv();
        if (r is RecvData<Query>) {
          drained++;
          r.value
            ..reply(key, 'ack')
            ..dispose();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      final answered = <int>[];
      for (final g in gets) {
        answered.add((await g.timeout(const Duration(seconds: 30))).length);
      }

      // A ring at capacity 1 cannot hold three queries, so some getter's query
      // was dropped — and remotely that is simply a getter that waited and got
      // nothing. Lossy is the trade a ring makes to never stall the producer.
      expect(drained, lessThan(3));
      expect(answered.where((n) => n == 0), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 180)));

    test(
      'closing while queries are still arriving does not corrupt anything',
      () async {
        // Under MALLOC_PERTURB_ in a SUBPROCESS, because glibc reads it once at
        // startup and because a premature free of the tee would otherwise read
        // plausible bytes silently.
        final run = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'test/helpers/query_close_race_harness.dart'],
          environment: {'MALLOC_PERTURB_': '165'},
        );
        final out = '${run.stdout}${run.stderr}';
        expect(out, contains('HARNESS_CLOSED'));
        expect(
          out,
          contains('HARNESS_DONE'),
          reason:
              'the harness must reach its end — an early death would '
              'otherwise pass an exit-code assertion for the wrong reason',
        );
        expect(run.exitCode, isZero, reason: out);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
