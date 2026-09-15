// Seed #6 slices 9-10: async `recv()` on the reply channel.
//
// Canon's blocking `z_*_handler_reply_recv` parks the calling thread until a
// reply arrives or the channel dies, and it is UNINTERRUPTIBLE — no timeout or
// deadline variant exists anywhere in the API, and the only way to release a
// parked call is to drop the producer closure. Hosting it on a thread would
// make a clean release impossible; hosting it on a Dart isolate is the v0.6.2
// crash class. So nothing blocks: the shim interposes a readiness tee between
// zenoh and the channel, delivers to the channel SYNCHRONOUSLY on zenoh's own
// thread — which is what leaves fifo backpressure untouched — and only then
// posts a single wake to Dart if a waiter is armed. Correctness rests on
// `tryRecv`; the ping only ever says *look again*.
//
// The reply column needs one thing the sample column does not: a reference
// count on the tee context. On the sample path the entity drop blocks until
// executing callbacks are destroyed, which is what makes "the drop callback
// does not free" safe. Here there IS no entity — canon owns the closure and
// drops it at query completion — so a `dispose()` can race a delivery running
// inside the tee. Two owners, an atomic count, last one frees.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';
import 'helpers/poll.dart';

void main() {
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final replierSession = await Session.open(config: listener);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final getterSession = await Session.open(config: connector);
    await Future<void>.delayed(const Duration(seconds: 1));
    return (replierSession, getterSession);
  }

  group('Slice 9: recv() on the reply channel (TCP 19361)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19361);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Declares a queryable that replies once, after [delay], and finalises.
    void replyAfter(String key, Duration delay, {String payload = 'answer'}) {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) async {
        await Future<void>.delayed(delay);
        query
          ..reply(key, payload)
          ..dispose();
      });
    }

    /// Declares a queryable that receives queries and never replies, holding
    /// each one open so the channel stays connected.
    void holdOpen(String key) {
      final held = <Query>[];
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen(held.add);
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });
    }

    PullReplies channelOn(String key, {Duration? timeout}) {
      return getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        timeout: timeout ?? const Duration(seconds: 60),
      );
    }

    test('buffered data completes recv() immediately', () async {
      const key = 'zenoh/dart/test/s9/buffered';
      replyAfter(key, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key);
      addTearDown(replies.dispose);
      // Settle so the reply is already in the buffer before recv() is called:
      // this cell is about the "already there" path, not the parking one.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final result = await replies.recv().timeout(const Duration(seconds: 2));
      expect(result, isA<RecvData<Reply>>());
      expect((result as RecvData<Reply>).value.ok.payload, equals('answer'));
    });

    test('an empty channel parks and wakes on arrival', () async {
      const key = 'zenoh/dart/test/s9/park';
      // The replier waits well past the point where recv() must have parked, so
      // a recv() that only ever looked once would still be waiting.
      replyAfter(key, const Duration(seconds: 1), payload: 'late');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key);
      addTearDown(replies.dispose);

      final result = await replies.recv().timeout(const Duration(seconds: 10));
      expect(result, isA<RecvData<Reply>>());
      expect((result as RecvData<Reply>).value.ok.payload, equals('late'));
    });

    test('recv() never completes empty', () async {
      const key = 'zenoh/dart/test/s9/never-empty';
      replyAfter(key, const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key);
      addTearDown(replies.dispose);

      final first = await replies.recv().timeout(const Duration(seconds: 10));
      final second = await replies.recv().timeout(const Duration(seconds: 10));
      // The variant is structurally reachable -- the type is shared with
      // tryRecv -- and contractually impossible, exactly as canon's own
      // two-valued blocking recv is.
      expect(first, isNot(isA<RecvEmpty<Reply>>()));
      expect(second, isNot(isA<RecvEmpty<Reply>>()));
    });

    test(
      'a pending recv() resolves disconnected at query completion',
      () async {
        // The reply column's own terminal trigger: nothing is undeclared, the
        // query simply finishes.
        const key = 'zenoh/dart/test/s9/complete';
        final queryable = replierSession.declareQueryable(key);
        addTearDown(queryable.close);
        queryable.stream.listen((query) async {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          query.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = channelOn(key);
        addTearDown(replies.dispose);

        final result = await replies.recv().timeout(
          const Duration(seconds: 10),
        );
        expect(result, isA<RecvDisconnected<Reply>>());
      },
    );

    test('a pending recv() resolves disconnected at dispose()', () async {
      const key = 'zenoh/dart/test/s9/dispose-pending';
      holdOpen(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key);
      final pending = replies.recv();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      replies.dispose();

      // Completed FIRST, before any native release: that ordering is what
      // keeps a pending recv() from being either a hang or a use-after-free.
      final result = await pending.timeout(const Duration(seconds: 5));
      expect(result, isA<RecvDisconnected<Reply>>());
    });

    test('one pending recv() at a time', () async {
      const key = 'zenoh/dart/test/s9/one-pending';
      holdOpen(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key);
      addTearDown(replies.dispose);

      final pending = replies.recv();
      // The native handler is move-only and single-consumer, so a second
      // pending pull would invent fairness canon does not define.
      expect(replies.recv, throwsA(isA<StateError>()));

      replies.dispose();
      await pending.timeout(const Duration(seconds: 5));
    });

    test('an interleaved tryRecv() wins and the waiter re-arms', () async {
      // ⚠️ THE REPLIER RUNS IN ITS OWN PROCESS, and that is the whole
      // construction. Stealing an arriving reply out from under a pending
      // `recv()` requires taking it BEFORE the readiness ping is processed,
      // which needs a synchronous busy-poll with no `await` in it — and that
      // starves every in-process replier, because a queryable's stream callback
      // is an event-loop task too. Seed #5's equivalent cell had a synchronous
      // producer (`Session.put` is a plain FFI call); the reply column has
      // none, so the producer moves out of the isolate. `tryRecv` reads the
      // native channel directly, so it sees a reply zenoh's own thread pushed
      // with the Dart event loop stopped.
      const key = 'zenoh/dart/test/s9/rearm';
      const pacerPort = 19362;
      final pacer = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/helpers/paced_replier.dart',
        '$pacerPort',
        key,
        '1500',
      ], workingDirectory: Directory.current.path);
      addTearDown(() => pacer.kill(ProcessSignal.sigkill));
      final pacerOut = StringBuffer();
      pacer.stdout
          .transform(const SystemEncoding().decoder)
          .listen(
            pacerOut.write,
          );
      await waitForOutput(pacerOut, 'PACER_READY');

      final local = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$pacerPort"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      addTearDown(local.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = local.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 60),
      );
      addTearDown(replies.dispose);

      final pending = replies.recv();
      var pendingDone = false;
      RecvResult<Reply>? pendingResult;
      unawaited(
        pending.then((r) {
          pendingDone = true;
          pendingResult = r;
        }),
      );

      // ⚠️ NO `await` IN THIS LOOP. An await would yield, the readiness ping
      // would be delivered, and the PENDING recv's continuation would take the
      // reply — the opposite interleaving from the one this cell defines.
      var stolen = const RecvEmpty<Reply>() as RecvResult<Reply>;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (stolen is RecvEmpty<Reply> && DateTime.now().isBefore(deadline)) {
        stolen = replies.tryRecv();
      }
      expect(stolen, isA<RecvData<Reply>>());
      expect((stolen as RecvData<Reply>).value.ok.payload, equals('first'));

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        pendingDone,
        isFalse,
        reason:
            'the pending recv() must still be pending — the interleaved '
            'tryRecv took the only reply',
      );

      // THE RE-ARM LEG. The delivery that pinged us already cleared the armed
      // flag, so without the re-arm in `_onWake` the SECOND reply would post
      // nothing and this waiter would sleep until the disconnect.
      final result = await pending.timeout(const Duration(seconds: 20));
      expect(result, isA<RecvData<Reply>>());
      expect((result as RecvData<Reply>).value.ok.payload, equals('second'));
      expect(pendingResult, same(result));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('calls after dispose() are a handle-state error', () async {
      const key = 'zenoh/dart/test/s9/after-dispose';
      holdOpen(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = channelOn(key)..dispose();

      // The handle's OWN closed state, deliberately distinct from the
      // channel's RecvDisconnected.
      expect(replies.tryRecv, throwsA(isA<StateError>()));
      expect(replies.recv, throwsA(isA<StateError>()));
    });
  });
  // -------------------------------------------------------------------------
  // Slice 9's live-fire legs: the reply channel's own allocation guard, and the
  // tee's lifetime under a dispose that races a delivery.
  //
  // Both run as SUBPROCESSES, and both have to: glibc reads MALLOC_PERTURB_
  // once at startup, and the LD_PRELOAD injector has to be in place before
  // the process links. Both also carry a printed end-marker, because a process
  // that
  // died early would otherwise "pass" whatever the assertion was.
  group('Slice 9: reply channel live-fire legs', () {
    late Directory tmp;
    late String injectorPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_reply_allocguard');
      injectorPath = '${tmp.path}/malloc_fail_injector.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-o',
        injectorPath,
        'test/helpers/malloc_fail_injector.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<ProcessResult> runAllocHarness({required bool injected}) {
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/reply_channel_alloc_harness.dart'],
        environment: injected
            // EXACT size, not a threshold, and the change is load-bearing.
            // `Session.open` is offloaded now and its entry allocates two
            // blocks of its own before canon is called -- measured 2024 and 8
            // bytes on this very path, against 40 for the tee context under
            // test. The old `ZD_FAIL_MALLOC_OVER: 8` failed all three, so the
            // open died with ZD_OPEN_EALLOC and this cell read a failure from
            // the WRONG SITE while still looking like a pass for `code=11`.
            //
            // 40 is the tee context alone. A sizeof can drift, and this fails
            // SAFE when it does: the injector fires on nothing, INJECTOR_FIRED
            // disappears, and the positive control below goes red. It cannot
            // go falsely green.
            //
            // The injector only fails mallocs whose CALLER is
            // libzenoh_dart.so, so canon's own allocator is untouched and the
            // only NULL in the process is the one under test.
            ? {'ZD_FAIL_MALLOC_SIZE': '40', 'LD_PRELOAD': injectorPath}
            : null,
      );
    }

    test('the alloc harness discriminates: no injection, no throw', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }
      final control = await runAllocHarness(injected: false);
      final out = '${control.stdout}${control.stderr}';
      // THE CONTROL, and it is load-bearing: it establishes that the marker the
      // leg below reads is absent when nothing is injected, so its presence
      // there is attributable to the injected failure.
      expect(out, contains('HARNESS_OK'));
      expect(out, isNot(contains('HARNESS_THREW')));
      expect(out, isNot(contains('INJECTOR_FIRED')));
      expect(out, contains('HARNESS_DONE'));
      expect(control.exitCode, isZero);
    });

    test("zd_get_channel's allocation failure surfaces as ZenohException(11)", () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }
      final injected = await runAllocHarness(injected: true);
      final out = '${injected.stdout}${injected.stderr}';

      // Positive control on the instrument: the branch under test was entered.
      expect(
        out,
        contains('INJECTOR_FIRED'),
        reason: 'the injector must actually have failed a shim allocation',
      );
      // The declare channel's return space is SPLIT and this is its shim half:
      // 11 is the shim's own allocation failure, mapped to ZenohException while
      // 10 (out-of-range capacity) maps to ArgumentError. A single -1 would
      // have squatted on a live canon code.
      expect(out, contains('HARNESS_THREW=ZenohException code=11'));
      // ...and the process survived rather than writing through the NULL.
      expect(out, contains('HARNESS_DONE'));
      expect(injected.exitCode, isZero);
    });

    test('disposing mid-flight does not corrupt anything', () async {
      // THE TEE-LIFETIME CELL. The reply column has no entity drop to
      // serialise against, so `dispose()` can run while a delivery is executing
      // inside the tee on zenoh's own thread — and it can run either before or
      // after canon drops its closure. A premature free would be a
      // use-after-free on a block that still holds plausible bytes, which stays
      // SILENT under a normal allocator; MALLOC_PERTURB_ turns it into an
      // abort, so this leg discriminates rather than merely tolerating.
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/reply_dispose_race_harness.dart'],
        environment: {'MALLOC_PERTURB_': '165'},
      );
      final out = '${run.stdout}${run.stderr}';
      expect(out, contains('HARNESS_DISPOSED'));
      expect(
        out,
        contains('HARNESS_DONE'),
        reason:
            'the harness must reach its end -- an early death would '
            'otherwise pass an exit-code assertion for the wrong reason',
      );
      expect(run.exitCode, isZero, reason: out);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
  // -------------------------------------------------------------------------
  // Slice 10: MEASUREMENT — capacity 0 against `recv()`, per kind, through our
  // stack.
  //
  // Seed #5 measured the SAMPLE column: a capacity-0 fifo is a rendezvous —
  // full when it is empty — so a delivery blocks waiting for a concurrent
  // consumer, and the readiness signal a parked `recv()` waits on is only
  // raised
  // AFTER that delivery returns. The parked recv is the only consumer that
  // could
  // release it, so neither side moves. Whether the same holds for REPLIES was
  // unmeasured, and the reply column has a difference the sample column does
  // not:
  // it self-terminates at query completion.
  //
  // MEASURED 2026-08-19 (probe + verbatim output at
  // test/helpers/probes/probe_capacity0_recv.dart):
  //
  //   recv    cap0 ring: RecvDisconnected<Reply>
  //   recv    cap0 fifo: TIMED_OUT_UNRESOLVED
  //   tryRecv cap0 ring: recovered=0 terminal=true
  //   tryRecv cap0 fifo: recovered=1 terminal=true
  //
  // So the exclusion is FIFO-SPECIFIC on this column too, exactly as the
  // sample-column finding predicts — and `tryRecv` stays usable at capacity 0,
  // which is what the dartdoc tells callers to reach for.
  //
  // ⚠️ EVERY WAIT HERE IS BOUNDED, and every capacity-0 handle is DRAINED
  // before
  // it is disposed. An unbounded cell would not report a hang, it would BE one;
  // and a rendezvous left undrained moves the freeze into teardown.
  group('Slice 10: capacity 0 against recv(), per kind (TCP 19363)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19363);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    void replyOnce(String key) {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(key, 'answer')
          ..dispose();
      });
    }

    PullReplies zeroCapacity(String key, ChannelKind kind) {
      final replies = getterSession.pullGet(
        key,
        kind: kind,
        capacity: 0,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(() {
        // DRAIN BEFORE DISPOSING. On a rendezvous a blocked delivery has to be
        // released, or the freeze simply moves into teardown.
        var guard = 0;
        while (replies.tryRecv() is! RecvDisconnected<Reply> && guard++ < 50) {}
        replies.dispose();
      });
      return replies;
    }

    test(
      'recv() on a capacity-0 FIFO reply channel does not resolve',
      () async {
        const key = 'zenoh/dart/test/s10/fifo';
        replyOnce(key);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = zeroCapacity(key, ChannelKind.fifo);

        // PINNED AS MEASURED: it times out unresolved. The rendezvous needs a
        // concurrent consumer and the parked recv is the only candidate, so the
        // delivery and the wake wait on each other. This is not a defect to fix
        // here -- it is canon's capacity-0 semantics meeting an async waiter --
        // and the dartdoc says to use tryRecv at capacity 0 for exactly this
        // reason.
        var resolved = false;
        unawaited(replies.recv().then((_) => resolved = true));
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(resolved, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'recv() on a capacity-0 RING reply channel resolves — the control',
      () async {
        // The DISCRIMINATING control: it shows the exclusion is fifo-specific
        // rather than a property of capacity 0 or of the waiter. A ring never
        // blocks its producer, so the query completes and the closure's drop
        // sentinel wakes the waiter -- with nothing recovered, which is the
        // ring's own discard behaviour and not a failure of the waiter.
        const key = 'zenoh/dart/test/s10/ring';
        replyOnce(key);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = zeroCapacity(key, ChannelKind.ring);

        final result = await replies.recv().timeout(
          const Duration(seconds: 10),
        );
        expect(result, isA<RecvDisconnected<Reply>>());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'tryRecv() at capacity 0 stays usable — the positive control',
      () async {
        // Without this the two cells above could both be describing a topology
        // where nothing is ever delivered at capacity 0. A synchronous poll IS
        // the concurrent consumer the rendezvous needs, so the fifo hands the
        // reply over normally.
        const fifoKey = 'zenoh/dart/test/s10/fifo/try';
        replyOnce(fifoKey);
        const ringKey = 'zenoh/dart/test/s10/ring/try';
        replyOnce(ringKey);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final fifo = zeroCapacity(fifoKey, ChannelKind.fifo);
        final fifoDrained = await drainToTerminal(
          fifo.tryRecv,
          timeout: const Duration(seconds: 10),
        );
        expect(
          fifoDrained,
          hasLength(1),
          reason: 'a synchronous poll must release the rendezvous',
        );

        final ring = zeroCapacity(ringKey, ChannelKind.ring);
        final ringDrained = await drainToTerminal(
          ring.tryRecv,
          timeout: const Duration(seconds: 10),
        );
        expect(ringDrained, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
