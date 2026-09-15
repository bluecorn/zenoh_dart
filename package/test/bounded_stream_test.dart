import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/bounded_subprocess.dart';
import 'helpers/poll.dart';

/// Seed `[DM-bounded-stream]`: the demand-gated `Stream` view over the two
/// shipped pull handles, on the sample column.
///
/// The default push `Stream` is unbounded and its `pause()` is inert — nothing
/// in `package/lib` wires `onPause`, `onResume`, `onListen` or `onCancel`, so a
/// paused consumer's samples pile up in an unbounded `StreamController` seam.
/// `PullSubscriber.stream` is the bounded answer: a `Stream` that pulls through
/// the handle's own `recv()` only while the subscription is demanding.
///
/// ⚠️ **THE PINNED IN-FLIGHT SEMANTICS.** The first pull starts
/// *synchronously* inside `onListen`, so a synchronous `listen(); pause();`
/// leaves exactly ONE pull in flight and the element that completes it is
/// STASHED. What a paused consumer retains is therefore the channel's own
/// `capacity` plus at most one stashed element — `capacity + 1`, uniformly,
/// rather than a bound that depends on how the pause was reached. Test 4 is
/// that decision's own pin: an implementation that deferred the first pull
/// fails there, before any arithmetic depends on it.
///
/// ⚠️ Every cell here uses TWO SESSIONS over TCP loopback. That is a hard
/// bound rather than a preference: publishing into a full fifo from the session
/// that owns the subscriber blocks the putter permanently inside a synchronous
/// FFI call (measured at canon; see `channel_kind.dart`'s `fifo` doc).
void main() {
  /// Opens a listener/connector pair on [port] and returns (publisher,
  /// subscriber) sessions. Multicast and gossip are OFF: a test that inherits
  /// the LAN is testing the LAN.
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final pubSession = await Session.open(config: listener);

    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final subSession = await Session.open(config: connector);

    await Future<void>.delayed(const Duration(seconds: 1));
    return (pubSession, subSession);
  }

  group('The demand gate on the sample column (TCP 19590)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19590);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test(
      'the bounded stream delivers what the channel holds, in order',
      () async {
        const ke = 'zenoh/dart/test/bstream/order';
        // Capacity 32 against 10 small samples: the channel never reaches its
        // bound here, so this cell is about delivery and order, not about the
        // bound. Volume: 10 x tens of bytes.
        final pull = subSession.declarePullSubscriber(ke, capacity: 32);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final got = <String>[];
        var done = false;
        final sub = pull.stream.listen(
          (s) => got.add(s.payload),
          onDone: () => done = true,
        );
        addTearDown(sub.cancel);

        for (var i = 0; i < 10; i++) {
          pubSession.put(ke, 'm$i');
        }

        await waitUntil(
          () => got.length >= 10,
          timeout: const Duration(seconds: 15),
          description: '10 samples through the bounded stream',
        );
        expect(got, equals([for (var i = 0; i < 10; i++) 'm$i']));
        expect(done, isFalse, reason: 'the stream is still open');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('nothing is pulled until someone listens -- the onListen gate', () async {
      const ke = 'zenoh/dart/test/bstream/onlisten';
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // 4 x tens of bytes into a capacity-8 ring: below the bound, so all four
      // are still there for the poll below. Settle for the burst rather than
      // polling -- polling would consume what the cell is about.
      for (var i = 0; i < 4; i++) {
        pubSession.put(ke, 'g$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));

      // ACCESSED, never listened to. The getter creates the gate; only
      // `onListen` starts the pull.
      final stream = pull.stream;
      expect(stream, isA<Stream<Sample>>());
      expect(
        pull.pullInFlightForTesting,
        isFalse,
        reason: 'the getter alone must not start a pull',
      );

      final got = <String>[];
      for (var i = 0; i < 4; i++) {
        final r = pull.tryRecv();
        expect(
          r,
          isA<RecvData<Sample>>(),
          reason: 'sample $i should still be in the channel, undriven',
        );
        got.add((r as RecvData<Sample>).value.payload);
      }
      expect(got, equals(['g0', 'g1', 'g2', 'g3']));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the stream is single-subscription', () async {
      const ke = 'zenoh/dart/test/bstream/single';
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final got = <String>[];
      final first = pull.stream.listen((s) => got.add(s.payload));
      addTearDown(first.cancel);

      expect(() => pull.stream.listen((_) {}), throwsStateError);

      // ...and the first listener is unharmed by the refusal.
      pubSession.put(ke, 'still-here');
      await waitUntil(
        () => got.contains('still-here'),
        timeout: const Duration(seconds: 10),
        description: 'the first listener still receiving',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the pinned in-flight semantics are real, and the state observable '
        'can see them', () async {
      const ke = 'zenoh/dart/test/bstream/inflight';
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // The pause is SYNCHRONOUS with the listen -- cascaded onto it, so
      // nothing at all runs between them.
      final sub = pull.stream.listen((_) {})..pause();
      // Resume before cancelling: the gate is what is being left behind, and
      // a paused subscription would hold its stash past the teardown.
      addTearDown(() async {
        sub.resume();
        await sub.cancel();
      });

      // The pin: `onListen` ran the drive loop to its first `await`, so
      // `recv()`'s synchronous prelude has executed and a pull IS in flight by
      // the time `pause()` is reached. An implementation that deferred the
      // first pull reads `false` here.
      expect(
        pull.pullInFlightForTesting,
        isTrue,
        reason: 'the first pull must start synchronously inside onListen',
      );
      expect(pull.stashHeldForTesting, isFalse);

      // One sample, published and settled: it completes the in-flight pull,
      // lands in the stash because the gate is paused, and the loop exits.
      pubSession.put(ke, 'x0');
      await waitUntil(
        () => pull.stashHeldForTesting,
        timeout: const Duration(seconds: 10),
        description: 'the arrival to complete the in-flight pull and stash',
      );
      expect(
        pull.pullInFlightForTesting,
        isFalse,
        reason: 'the loop exits once it has stashed into a paused gate',
      );
      expect(pull.stashHeldForTesting, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    group('Edge cases', () {
      test(
        'stream after close() throws, like the other two accessors',
        () async {
          const ke = 'zenoh/dart/test/bstream/closed';
          final pull = subSession.declarePullSubscriber(ke, capacity: 8);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          pull.close();

          expect(() => pull.stream, throwsStateError);
          expect(pull.tryRecv, throwsStateError);
          expect(pull.recv, throwsStateError);
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('close() without ever touching stream, and a double close(), are '
          'both no-ops', () async {
        const ke = 'zenoh/dart/test/bstream/noGate';
        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        await Future<void>.delayed(const Duration(milliseconds: 400));

        // No gate was ever created, so there is nothing to release.
        expect(pull.stashHeldForTesting, isFalse);
        expect(pull.pullInFlightForTesting, isFalse);
        expect(pull.close, returnsNormally);
        expect(pull.close, returnsNormally);
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  });

  group('Handle integration: the gate-close step and the stash (TCP 19590)', () {
    late Session pubSession;
    late Session subSession;

    // ⚠️ THE FREEZE GUARD, and it is not this plan's -- it is the shipped
    // precedent from `ffi_ownership_test.dart`'s close-under-overflow group,
    // reused verbatim because the hazard is identical. One edge case below
    // calls `close()` on a fifo in overflow IN THIS PROCESS. If the merged
    // handler-drop-first fix were ever to regress, that call would park the
    // isolate inside a synchronous FFI call, `package:test`'s own timeout
    // timer would never get to run, and the whole serial suite would freeze
    // with no output -- the most expensive possible failure here
    // (`development/discipline/verification.md`, "An expensive run is ONE
    // sampling opportunity").
    //
    // So the same configuration is driven FIRST in a subprocess under an
    // OS-level bound. A tree where it does not return skips the in-process
    // cell with a stated reason instead of taking the suite down.
    //
    // Port 19584 rather than one of this unit's 19590-19597: it is the same
    // harness in the same role as the shipped guard, the child is a separate
    // process, and the suite is serial.
    var overflowCloseReturns = false;
    var overflowDiagnosis = '';

    setUpAll(() async {
      final guard = await runBoundedHarness(
        'test/helpers/fifo_close_harness.dart',
        [
          '--role',
          'selfcontained',
          '--column',
          'sub',
          '--kind',
          'fifo',
          '--capacity',
          '2',
          '--count',
          '20',
          '--port',
          '19584',
        ],
        deadline: const Duration(seconds: 60),
      );
      overflowCloseReturns = !guard.frozen && guard.exitCode == 0;
      overflowDiagnosis = guard.diagnosis;

      (pubSession, subSession) = await sessionPair(19590);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Whether [done] completed within [within]. Bounded and self-diagnosing:
    /// a `false` is a result the cell asserts on, never a hang.
    Future<bool> firedWithin(Completer<void> done, Duration within) =>
        done.future.then((_) => true).timeout(within, onTimeout: () => false);

    /// Polls `tryRecv` to exhaustion, returning the payloads it handed over.
    List<String> drainPayloads(PullSubscriber pull) {
      final got = <String>[];
      while (true) {
        final r = pull.tryRecv();
        if (r is RecvData<Sample>) {
          got.add(r.value.payload);
        } else {
          return got;
        }
      }
    }

    test(
      'state (a) -- parked and unpaused; close() completes the waiter',
      () async {
        const ke = 'zenoh/dart/test/bstream/state-a';
        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final got = <String>[];
        final errors = <Object>[];
        final done = Completer<void>();
        final sub = pull.stream.listen(
          (s) => got.add(s.payload),
          onError: errors.add,
          onDone: done.complete,
        );
        addTearDown(sub.cancel);

        pubSession.put(ke, 'a0');
        await waitUntil(
          () => got.isNotEmpty,
          timeout: const Duration(seconds: 10),
          description: 'the first sample, so the loop is parked in recv()',
        );
        // ASSERTED, not inferred: the channel is drained and the loop is
        // awaiting the next arrival.
        expect(pull.pullInFlightForTesting, isTrue);
        expect(pull.stashHeldForTesting, isFalse);

        final sw = Stopwatch()..start();
        pull.close();
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));

        // ⚠️ THIS CELL DOES NOT DEPEND ON THE GATE-CLOSE STEP, and saying so is
        // the point of it. `close()` completes the pending waiter
        // `RecvDisconnected`, and the drive loop's OWN terminal arm closes the
        // controller. Measured on the tree before the step existed: `onDone
        // fired=true`. What separates this cell from the next two is the state
        // it asserts, not the outcome it observes.
        expect(
          await firedWithin(done, const Duration(seconds: 5)),
          isTrue,
          reason: 'onDone must fire after close() from state (a)',
        );
        expect(errors, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'state (a-prime) -- parked and PAUSED is not the discriminating state',
      () async {
        const ke = 'zenoh/dart/test/bstream/state-a-prime';
        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final done = Completer<void>();
        final sub = pull.stream.listen((_) {}, onDone: done.complete)..pause();
        addTearDown(sub.cancel);

        // The state assertion IS the cell's content. An earlier draft used this
        // recipe believing it reached state (b); it does not, and a teardown
        // cell written to it would have been vacuous.
        expect(pull.pullInFlightForTesting, isTrue);
        expect(pull.stashHeldForTesting, isFalse);

        pull.close();
        sub.resume();

        // Measured without the gate-close step: `onDone fired=true`. The pull
        // in flight is completed `RecvDisconnected` by close(), and the loop's
        // own terminal arm closes the controller -- exactly as in state (a).
        expect(
          await firedWithin(done, const Duration(seconds: 5)),
          isTrue,
          reason: 'onDone must fire after close() from state (a-prime)',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('state (b) -- exited with a stash; the ONLY state the gate-close step '
        'is load-bearing in', () async {
      const ke = 'zenoh/dart/test/bstream/state-b';
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      var seen = 0;
      final done = Completer<void>();
      late StreamSubscription<Sample> sub;
      sub = pull.stream.listen(
        (_) {
          seen++;
          sub.pause();
        },
        onDone: done.complete,
      );
      addTearDown(sub.cancel);

      pubSession.put(ke, 'b0');
      await waitUntil(
        () => seen == 1,
        timeout: const Duration(seconds: 10),
        description: 'the first sample, so onData can pause inside itself',
      );
      // One further arrival: it completes the pull that was still in flight
      // when the in-callback pause landed, and the gate stashes it. The loop
      // then finds no demand and EXITS -- nothing is left to close the
      // controller.
      pubSession.put(ke, 'b1');
      await waitUntil(
        () => pull.stashHeldForTesting,
        timeout: const Duration(seconds: 10),
        description: 'the second arrival to be stashed',
      );
      expect(pull.stashHeldForTesting, isTrue);
      expect(
        pull.pullInFlightForTesting,
        isFalse,
        reason: 'state (b) is the EXITED loop -- no pull outstanding',
      );

      pull.close();
      sub.resume();

      // ⚠️ PRE-FIX EVIDENCE, verbatim from this cell run against the tree of
      // the previous slice -- `DemandGate.close()` existing but never called:
      //
      //   onDone fired=false
      //
      // and with the step in `PullSubscriber.close()`:
      //
      //   onDone fired=true
      //
      // That is the both-ways calibration for this slice. Cells 7 and 8 read
      // `true` on BOTH trees, which is why neither of them can stand in for
      // this one.
      expect(
        await firedWithin(done, const Duration(seconds: 5)),
        isTrue,
        reason:
            'onDone must fire after close() from state (b) -- this is the '
            'state where only the gate-close step can close the controller',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'cancel loses NOTHING -- the stash is retrievable through the handle',
      () async {
        const ke = 'zenoh/dart/test/bstream/cancel';
        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final sub = pull.stream.listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          pull.pullInFlightForTesting,
          isTrue,
          reason: 'the loop must be parked in recv() before the cancel',
        );
        await sub.cancel();

        // 3 x tens of bytes into a capacity-8 ring: below the bound, so loss
        // here can only be the gate's doing.
        for (var i = 0; i < 3; i++) {
          pubSession.put(ke, 'c$i');
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));

        // ⚠️ PRE-FIX EVIDENCE, verbatim from this cell run against the previous
        // slice's tree -- the gate stashes on cancel but `tryRecv()` does not
        // consult the stash:
        //
        //   [c1, c2]
        //
        // One element lost. With the stash-first accessor: [c0, c1, c2]. The
        // ordering this preserves is one the binding already publishes --
        // `recv()`'s own dartdoc says an interleaved `tryRecv` "is fine and
        // *wins*: it reaches the channel first and takes the sample".
        expect(
          drainPayloads(pull),
          equals(['c0', 'c1', 'c2']),
          reason:
              "the orphaned pull's element must come back through the "
              'stash-first accessor, in arrival order',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('criterion C -- a caller who never listens is byte-identical', () async {
      const ke = 'zenoh/dart/test/bstream/criterion-c';
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // `stream` is NEVER accessed here, so no gate exists and the stash-first
      // branch cannot be taken. This is criterion C ASSERTED rather than
      // assumed: the accessor is the one place this unit could have changed
      // behaviour for an existing caller.
      for (var i = 0; i < 3; i++) {
        pubSession.put(ke, 'k$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));

      final got = <String>[];
      for (var i = 0; i < 3; i++) {
        final r = pull.tryRecv();
        expect(r, isA<RecvData<Sample>>());
        got.add((r as RecvData<Sample>).value.payload);
      }
      expect(got, equals(['k0', 'k1', 'k2']));
      expect(pull.stashHeldForTesting, isFalse);
      expect(pull.pullInFlightForTesting, isFalse);

      final pending = pull.recv();
      pubSession.put(ke, 'k3');
      final fourth = await pending.timeout(const Duration(seconds: 10));
      expect(fourth, isA<RecvData<Sample>>());
      expect((fourth as RecvData<Sample>).value.payload, equals('k3'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    group('Edge cases', () {
      test('state (b) with a FULL fifo -- the close-under-overflow '
          'precondition, reached through the Stream path', () async {
        if (!overflowCloseReturns) {
          markTestSkipped(
            'close-under-overflow does not return on this tree; this cell '
            'would freeze the serial suite. Guard output:\n$overflowDiagnosis',
          );
          return;
        }
        const ke = 'zenoh/dart/test/bstream/full-fifo';
        // fifo capacity 4 against 33 small samples: eight times the bound, so
        // a delivery really is parked in `send()` when close() is called.
        // Volume: 33 x tens of bytes, two sessions (mandate 10) -- a
        // same-session publish into a full fifo blocks the putter forever.
        final pull = subSession.declarePullSubscriber(
          ke,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));

        var seen = 0;
        final done = Completer<void>();
        late StreamSubscription<Sample> sub;
        sub = pull.stream.listen(
          (_) {
            seen++;
            sub.pause();
          },
          onDone: done.complete,
        );
        addTearDown(sub.cancel);

        final pub = pubSession.declarePublisher(
          ke,
          congestionControl: CongestionControl.block,
        );
        addTearDown(pub.close);
        pub.put('f0');
        await waitUntil(
          () => seen == 1,
          timeout: const Duration(seconds: 10),
          description: 'the first sample, so onData can pause inside itself',
        );
        for (var i = 1; i <= 32; i++) {
          pub.put('f$i');
        }
        await waitUntil(
          () => pull.stashHeldForTesting,
          timeout: const Duration(seconds: 15),
          description: 'the arrival that completes the in-flight pull',
        );

        // Channel-fullness proven by TWO successive peeks: the first drains
        // the stash (the stash-first accessor hands it over ahead of the
        // channel), and only the SECOND is evidence about the channel itself.
        expect(pull.tryRecv(), isA<RecvData<Sample>>());
        expect(
          pull.tryRecv(),
          isA<RecvData<Sample>>(),
          reason:
              'the second peek is the one that proves the CHANNEL is '
              'non-empty; the first only drained the stash',
        );

        final sw = Stopwatch()..start();
        pull.close();
        final closeMs = sw.elapsedMilliseconds;
        // MEASURED close() duration under fifo overflow through the Stream
        // path, recorded rather than merely bounded: 4 ms with the gate-close
        // step, 0 ms without it (this cell's own pre-fix run). The shipped
        // handler-drop-before-undeclare fix is what keeps either number off
        // the permanent hang that configuration used to produce, and the
        // subprocess guard in `setUpAll` is what makes running it here safe.
        expect(
          closeMs,
          lessThan(5000),
          reason: 'close() took ${closeMs}ms under fifo overflow',
        );
        printOnFailure('close() under fifo overflow returned in ${closeMs}ms');

        sub.resume();
        expect(
          await firedWithin(done, const Duration(seconds: 5)),
          isTrue,
          reason:
              'onDone must fire after a close() taken from state (b) on a '
              'fifo in overflow',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));

      test("the loop's own RecvDisconnected arm -- session closed first", () async {
        const ke = 'zenoh/dart/test/bstream/session-first';
        // A THIRD session, closed inside the cell: closing the group's own
        // subscriber session would take every other cell with it.
        final ownSession = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19590"]')
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        await Future<void>.delayed(const Duration(seconds: 1));

        final pull = ownSession.declarePullSubscriber(ke, capacity: 8);
        final done = Completer<void>();
        final sub = pull.stream.listen((_) {}, onDone: done.complete);
        addTearDown(sub.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 400));

        // Empty channel, listener parked unpaused: the loop is inside recv().
        expect(pull.pullInFlightForTesting, isTrue);
        expect(pull.stashHeldForTesting, isFalse);

        // The SESSION goes first, with the handle still open. This is the only
        // path that reaches the loop's own terminal arm -- every handle-close
        // path closes the gate first.
        ownSession.close();

        expect(
          await firedWithin(done, const Duration(seconds: 10)),
          isTrue,
          reason: "the loop's RecvDisconnected arm must close the controller",
        );
        // Distinct from the overflow residual pinned at
        // `fifo_close_deadlock_test.dart:708`, which this cell does not
        // duplicate: the channel here is EMPTY.
        pull.close();
      }, timeout: const Timeout(Duration(seconds: 90)));
    });
  });

  group('The fake-bound discriminator (TCP 19590)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19590);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Waits until the SETTLE SENTINEL has seen [n] samples, then allows a
    /// declared slack.
    ///
    /// ⚠️ Draining a channel while delivery is still in flight OVER-COUNTS,
    /// and the arithmetic every cell here rests on is then meaningless: the
    /// plan's own probe published 8 into a capacity-4 fifo and drained SEVEN,
    /// because the transport was feeding the channel as the drain ran. So the
    /// resume is gated on an observable that says the link delivered
    /// everything TO THIS PEER -- a plain push subscriber on the same keyexpr
    /// and the same session, which runs on the same delivery path the ring's
    /// callback does.
    ///
    /// The 50 ms is **settle time for callback ordering between two
    /// subscribers on one delivery**, declared as such. It is not the race
    /// guard; the sentinel is.
    Future<void> awaitSettled(List<Sample> sentinel, int n) async {
      await waitUntil(
        () => sentinel.length >= n,
        timeout: const Duration(seconds: 30),
        description:
            '$n samples delivered to this peer (settle sentinel); '
            'saw ${sentinel.length}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    /// Waits until [got] stops growing, bounded, and returns it.
    ///
    /// Deadline-bounded and self-diagnosing: a loop that never quiesces fails
    /// the cell rather than hanging the serial suite.
    Future<List<String>> drainUntilQuiet(List<String> got) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      var quiet = 0;
      var last = got.length;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (got.length == last) {
          if (++quiet == 3) return got;
        } else {
          quiet = 0;
          last = got.length;
        }
      }
      fail(
        'the bounded stream never stopped delivering (${got.length} so far)',
      );
    }

    test('a paused bounded stream retains at most capacity + 1, the stash is '
        'first, and the survivors are the newest', () async {
      const ke = 'zenoh/dart/test/bstream/fake-bound';
      const n = 1024;
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      // The settle sentinel, on the same session and keyexpr.
      final sentinel = <Sample>[];
      final watch = subSession.declareSubscriber(ke);
      addTearDown(watch.close);
      final watching = watch.stream.listen(sentinel.add);
      addTearDown(watching.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final got = <String>[];
      final sub = pull.stream.listen((s) => got.add(s.payload))..pause();
      addTearDown(() async {
        sub.resume();
        await sub.cancel();
      });
      expect(pull.pullInFlightForTesting, isTrue);

      // Volume: 1024 x tens of bytes on a capacity-8 RING, which never blocks,
      // so the producer runs to completion -- asserted below rather than
      // assumed. `CongestionControl.block` plus a yield every 64 puts so
      // nothing is dropped at the transport and the sentinel can reach 1024
      // (the F-14 remedy, applied here for the same reason it is applied to
      // the next cell).
      final pub = pubSession.declarePublisher(
        ke,
        congestionControl: CongestionControl.block,
      );
      addTearDown(pub.close);
      var published = 0;

      // ⚠️ THE FIRST SAMPLE IS PUBLISHED ALONE AND THE STASH IS THEN ASSERTED,
      // rather than the cell inferring that `seq0` is what completes the pull
      // in flight. On a RING that inference is FALSE under a burst: nothing
      // runs the Dart event loop between the puts, so by the time the pending
      // `recv()` is completed the ring has already evicted the early
      // arrivals. Measured on the burst-only form of this cell, the stash held
      // `seq94`, not `seq0`. This is F-1's own lesson -- assert the drive
      // loop's state through the observable; never read it off a recipe.
      pub.put('seq0');
      published++;
      await waitUntil(
        () => pull.stashHeldForTesting,
        timeout: const Duration(seconds: 10),
        description: 'seq0 to complete the in-flight pull and be stashed',
      );
      expect(pull.pullInFlightForTesting, isFalse);

      for (var i = 1; i < n; i++) {
        pub.put('seq$i');
        published++;
        if (i % 64 == 63) await Future<void>.delayed(Duration.zero);
      }
      expect(published, equals(n), reason: 'a ring never holds the producer');

      await awaitSettled(sentinel, n);
      sub.resume();
      await drainUntilQuiet(got);

      // BOUNDED ON BOTH SIDES. `lessThan(1024)` alone would pass on a topology
      // that delivered nothing at all, which is the failure this project has
      // paid for before.
      //
      // MEASURED, for the record and because the bound alone understates how
      // sharp the result is -- 1024 published, NINE delivered, and they are
      // exactly the stash plus the ring's last eight:
      //
      //   delivered=9 [seq0, seq1016, seq1017, seq1018, seq1019, seq1020,
      //                seq1021, seq1022, seq1023]
      expect(got.length, greaterThanOrEqualTo(1));
      expect(
        got.length,
        lessThanOrEqualTo(9),
        reason:
            'capacity 8 + one stashed sample; an eager drain into an '
            'unbounded controller seam delivers ~1024 here',
      );
      expect(
        got.first,
        equals('seq0'),
        reason: 'the stash is flushed BEFORE the next pull, so it leads',
      );
      expect(
        got.last,
        equals('seq${n - 1}'),
        reason: 'the ring kept the newest',
      );
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('the loop can carry the volume -- the control that makes the small '
        'number attributable', () async {
      const ke = 'zenoh/dart/test/bstream/carry';
      const n = 200;
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final got = <String>[];
      final sub = pull.stream.listen((s) => got.add(s.payload));
      addTearDown(sub.cancel);

      // Volume: 200 x tens of bytes into a capacity-8 FIFO, never paused.
      // ⚠️ YIELDING EVERY 10 PUTS so the drive loop can drain. 200
      // same-isolate puts under `CongestionControl.block` would otherwise rest
      // wholly on loopback and queue slack: the shipped precedent measures
      // fine at 20 and the plan's probe at 8, and the margin at 200 is not
      // established.
      final pub = pubSession.declarePublisher(
        ke,
        congestionControl: CongestionControl.block,
      );
      addTearDown(pub.close);
      for (var i = 0; i < n; i++) {
        pub.put('m$i');
        if (i % 10 == 9) await Future<void>.delayed(Duration.zero);
      }

      await waitUntil(
        () => got.length >= n,
        timeout: const Duration(seconds: 60),
        description:
            'all $n samples through the bounded stream; '
            'saw ${got.length}',
      );
      expect(got, equals([for (var i = 0; i < n; i++) 'm$i']));
    }, timeout: const Timeout(Duration(seconds: 180)));

    group('Edge cases', () {
      test('an unlistened stream retains nothing beyond the channel', () async {
        const ke = 'zenoh/dart/test/bstream/unlistened';
        const n = 1024;
        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        addTearDown(pull.close);
        final sentinel = <Sample>[];
        final watch = subSession.declareSubscriber(ke);
        addTearDown(watch.close);
        final watching = watch.stream.listen(sentinel.add);
        addTearDown(watching.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 800));

        // ACCESSED, never listened to -- so no gate ran, and no stash exists.
        expect(pull.stream, isA<Stream<Sample>>());

        final pub = pubSession.declarePublisher(
          ke,
          congestionControl: CongestionControl.block,
        );
        addTearDown(pub.close);
        for (var i = 0; i < n; i++) {
          pub.put('u$i');
          if (i % 64 == 63) await Future<void>.delayed(Duration.zero);
        }
        await awaitSettled(sentinel, n);

        final got = <String>[];
        while (true) {
          final r = pull.tryRecv();
          if (r is RecvData<Sample>) {
            got.add(r.value.payload);
          } else {
            break;
          }
        }
        expect(got.length, greaterThanOrEqualTo(1));
        expect(
          got.length,
          lessThanOrEqualTo(8),
          reason:
              'the channel is the ONLY buffer here: no gate ran, so no '
              'second one was added',
        );
        expect(pull.stashHeldForTesting, isFalse);
      }, timeout: const Timeout(Duration(seconds: 180)));
    });
  });

  group('The liveliness free-ride (TCP 19590)', () {
    late Session tokenSession;
    late Session subSession;

    setUpAll(() async {
      (tokenSession, subSession) = await sessionPair(19590);
    });

    tearDownAll(() {
      tokenSession.close();
      subSession.close();
    });

    // The seed's one-line question, answered by a cell rather than an
    // argument: the mechanism reaches this column BECAUSE THE RETURN TYPE IS
    // SHARED. `Session.declarePullLivelinessSubscriber` returns the same
    // `PullSubscriber`, so `.stream` is already there.
    //
    // ⚠️ This slice adds ZERO lines to `package/lib`, and that is the evidence
    // for the "at no extra cost" answer -- not a claim about it.

    test('liveliness transitions arrive through the bounded stream, with no '
        'new code', () async {
      const ke = 'zenoh/dart/test/bslive/group1/one';
      final pull = subSession.declarePullLivelinessSubscriber(
        ke,
        kind: ChannelKind.ring,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final kinds = <SampleKind>[];
      final sub = pull.stream.listen((s) => kinds.add(s.kind));
      addTearDown(sub.cancel);

      final token = tokenSession.declareLivelinessToken(ke);
      await waitUntil(
        () => kinds.isNotEmpty,
        timeout: const Duration(seconds: 15),
        description: 'the PUT that announces the token',
      );
      expect(kinds.first, equals(SampleKind.put));

      token.close();
      await waitUntil(
        () => kinds.length >= 2,
        timeout: const Duration(seconds: 15),
        description: 'the DELETE that retracts the token',
      );
      expect(kinds[1], equals(SampleKind.delete));
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      test('the shared type means the shared contract -- teardown state (b) '
          'behaves identically here', () async {
        const ke = 'zenoh/dart/test/bslive/group1/two';
        final pull = subSession.declarePullLivelinessSubscriber(
          ke,
          kind: ChannelKind.ring,
          capacity: 8,
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));

        var seen = 0;
        final done = Completer<void>();
        late StreamSubscription<Sample> sub;
        sub = pull.stream.listen(
          (_) {
            seen++;
            sub.pause();
          },
          onDone: done.complete,
        );
        addTearDown(sub.cancel);

        // ⚠️ THE RECIPE PAUSES INSIDE `onData` ON THE PUT, so the DELETE is
        // what completes the pull still in flight and is STASHED. That reaches
        // state (b) -- the exited loop -- which is the only teardown state the
        // gate-close step is load-bearing in. A recipe that merely paused
        // after listening would reach state (a-prime) and pass WITHOUT the
        // step, which is the vacuity this cell exists to avoid.
        final token = tokenSession.declareLivelinessToken(ke);
        await waitUntil(
          () => seen == 1,
          timeout: const Duration(seconds: 15),
          description: 'the PUT, so onData can pause inside itself',
        );
        token.close();
        await waitUntil(
          () => pull.stashHeldForTesting,
          timeout: const Duration(seconds: 15),
          description: 'the DELETE to complete the in-flight pull and stash',
        );
        expect(
          pull.pullInFlightForTesting,
          isFalse,
          reason: 'state (b) is the EXITED loop -- no pull outstanding',
        );

        pull.close();
        sub.resume();
        expect(
          await done.future
              .then((_) => true)
              .timeout(const Duration(seconds: 5), onTimeout: () => false),
          isTrue,
          reason:
              'the liveliness carrier inherits the teardown contract '
              'without a second implementation',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));
    });
  });
}
