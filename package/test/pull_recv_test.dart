import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// `PullSubscriber.recv()` — the blocking half of canon's consumption
/// surface, rendered async.
///
/// Canon pairs every handler with a blocking `recv` beside its `try_recv`.
/// A Dart call that parks its isolate's thread is the named over-translation,
/// so the faithful rendering is a `Future` driven by a readiness signal, with
/// consumption still going through the synchronous `try_recv`. Correctness
/// rests on `try_recv`; the readiness signal only ever supplies *when to
/// look*.
///
/// ⚠️ EVERY CELL IS TIMEOUT-BOUNDED. These are the cells that can hang rather
/// than fail, so a defect must surface as a red test and not as a frozen
/// suite.
void main() {
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

  group('recv() delivery (TCP 19320)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19320);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test('buffered data completes the future immediately', () async {
      const ke = 'zenoh/dart/test/recv/buffered';
      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession.put(ke, 'already here');
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // The sample is ALREADY in the buffer. recv() must hand it over without
      // waiting for any further delivery -- if it armed and awaited instead,
      // this would sit until the next publication that never comes.
      final result = await pull.recv().timeout(const Duration(seconds: 5));
      expect(result, isA<RecvData<Sample>>());
      expect(
        (result as RecvData<Sample>).value.payload,
        equals('already here'),
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('an empty channel parks, then unblocks on arrival', () async {
      const ke = 'zenoh/dart/test/recv/parks';
      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Nothing buffered: this future MUST park.
      final pending = pull.recv();

      var completedEarly = false;
      unawaited(pending.then((_) => completedEarly = true));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        completedEarly,
        isFalse,
        reason:
            'recv() on an empty live channel must not complete before '
            'anything is published -- otherwise the cell below proves nothing',
      );

      // ...and then unblock on the arrival. Neither canon nor the cpp peer
      // constructs this cell; it is the one the async rendering exists for.
      pubSession.put(ke, 'arrived later');

      final result = await pending.timeout(const Duration(seconds: 10));
      expect(result, isA<RecvData<Sample>>());
      expect(
        (result as RecvData<Sample>).value.payload,
        equals('arrived later'),
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('recv() never completes empty', () async {
      const ke = 'zenoh/dart/test/recv/never-empty';
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Drive it through both of its reachable outcomes: a parked completion
      // and an immediate one. Canon's blocking recv is 2-valued -- it waits
      // rather than reporting an empty buffer -- and the type is shared with
      // tryRecv exactly as the cpp peer shares it, so RecvEmpty is
      // structurally reachable and must never actually occur.
      final parked = pull.recv();
      pubSession.put(ke, 'one');
      final first = await parked.timeout(const Duration(seconds: 10));
      expect(first, isNot(isA<RecvEmpty<Sample>>()));

      pubSession.put(ke, 'two');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final second = await pull.recv().timeout(const Duration(seconds: 5));
      expect(second, isNot(isA<RecvEmpty<Sample>>()));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'nothing accumulates on the Dart side when nobody is waiting',
      () async {
        const ke = 'zenoh/dart/test/recv/no-accumulation';
        const capacity = 4;
        const n = 20;
        final pull = subSession.declarePullSubscriber(ke, capacity: capacity);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // N >> C published while the consumer stays completely idle -- no
        // recv(), no tryRecv(). THE ANTI-FAKE-BOUND CELL: if the readiness
        // mechanism queued one message per delivered sample, the retained set
        // would be N (memory growing with traffic rather than bounded by
        // capacity). What must be retained is the CHANNEL's bound.
        for (var i = 0; i < n; i++) {
          pubSession.put(ke, 'm$i');
        }
        await Future<void>.delayed(const Duration(seconds: 2));

        final drained = <String>[];
        while (true) {
          if (pull.tryRecv() case RecvData(:final value)) {
            drained.add(value.payload);
          } else {
            break;
          }
        }
        expect(
          drained,
          equals([for (var i = n - capacity; i < n; i++) 'm$i']),
          reason:
              'exactly the last $capacity published, in order -- the '
              "channel's bound, not a Dart-side queue that grew to $n",
        );

        // The post-drain publication is load-bearing: after the drain the
        // channel is alive and EMPTY, so without it the recv() below would have
        // nothing to complete on and the cell could only time out.
        pubSession.put(ke, 'after-drain');
        final result = await pull.recv().timeout(const Duration(seconds: 10));
        expect(result, isA<RecvData<Sample>>());
        // The new sample, not a replay of anything the drain consumed.
        expect(
          (result as RecvData<Sample>).value.payload,
          equals('after-drain'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('a second concurrent recv() is rejected', () async {
      const ke = 'zenoh/dart/test/recv/second';
      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final first = pull.recv();

      // The handler is move-only and single-consumer. Queueing would invent
      // fairness canon does not define; serialising would hide the misuse.
      expect(pull.recv, throwsStateError);

      // ...and the first is UNAFFECTED -- the rejection must not have
      // disturbed the waiter it refused to join.
      pubSession.put(ke, 'for the first');
      final result = await first.timeout(const Duration(seconds: 10));
      expect(result, isA<RecvData<Sample>>());
      expect(
        (result as RecvData<Sample>).value.payload,
        equals('for the first'),
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'tryRecv() interleaved with a pending recv() takes the sample',
      () async {
        const ke = 'zenoh/dart/test/recv/interleaved';
        final pull = subSession.declarePullSubscriber(ke, capacity: 4);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final pending = pull.recv();
        var pendingDone = false;
        unawaited(pending.then((_) => pendingDone = true));

        // Publish, then take it SYNCHRONOUSLY before the pending recv's
        // continuation can run.
        //
        // ⚠️ THERE IS NO `await` IN THIS LOOP, and that is the whole
        // construction. `tryRecv` reads the native channel directly, so it sees
        // a sample the zenoh delivery thread pushed without the Dart event loop
        // running at all. An `await` here would yield, the readiness ping would
        // be processed, and the PENDING recv's continuation would take the
        // sample -- the opposite interleaving from the one this cell defines.
        // (Measured: with an awaited poll this assertion fails with RecvEmpty,
        // because the pending recv won every time.)
        pubSession.put(ke, 'stolen');
        RecvResult<Sample> stolen = const RecvEmpty<Sample>();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (stolen is RecvEmpty<Sample> &&
            DateTime.now().isBefore(deadline)) {
          stolen = pull.tryRecv();
        }
        expect(stolen, isA<RecvData<Sample>>());
        expect((stolen as RecvData<Sample>).value.payload, equals('stolen'));

        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          pendingDone,
          isFalse,
          reason:
              'the pending recv() must still be pending -- the interleaved '
              'tryRecv took the only sample',
        );

        // ⚠️ THE RE-ARM LEG, and the reason this cell has a second half. With
        // no interleaved tryRecv this time, the pending future must complete on
        // the NEXT arrival. If the wake handler did not re-arm after waking to
        // an empty channel, the readiness flag would stay cleared, this
        // publication would post no signal, and the waiter would sleep until
        // the disconnect. The first half of this cell passes either way.
        pubSession.put(ke, 'for the waiter');
        final result = await pending.timeout(const Duration(seconds: 10));
        expect(result, isA<RecvData<Sample>>());
        expect(
          (result as RecvData<Sample>).value.payload,
          equals('for the waiter'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('recv() on a closed subscriber throws', () async {
      const ke = 'zenoh/dart/test/recv/closed';
      final pull = subSession.declarePullSubscriber(ke, capacity: 4)..close();

      // StateError, never a future that completes RecvDisconnected: the
      // disposed-handle guard and the channel state are different things.
      expect(pull.recv, throwsStateError);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('recv() on a capacity-0 fifo (TCP 19321)', () {
    // ⚠️ THE ONE CORNER THE NEVER-HANGS PROOF DOES NOT CLOSE -- and it is now
    // MEASURED rather than reasoned about. The measurement went against the
    // benign reading.
    //
    // The proof rests on "buffer empty" (the arming precondition) and "buffer
    // full" (the push-blocking precondition) being mutually exclusive. That
    // holds for every capacity >= 1. Capacity 0 is the single value where they
    // coincide, and canon's capacity-0 fifo turns out to be a RENDEZVOUS
    // rather than a clamp-to-1: it is full-when-empty.
    //
    // So the sequence is:
    //
    //   recv() finds the channel empty, arms, and parks
    //   a sample is published
    //   the delivery thread enters the tee and calls the inner closure
    //   the push BLOCKS -- a rendezvous needs a concurrent popper
    //   the readiness ping is posted only AFTER that call returns
    //   the only would-be popper is the parked recv()
    //   => neither side moves
    //
    // MEASURED 2026-08-18: the future did not complete within 10s. The cell
    // below now pins that, rather than a timeout being widened or the cell
    // deleted. Ping-BEFORE-push is explicitly not the fix -- it introduces a
    // wake-before-data race that strands the sample until the next delivery.
    // The remedy is a documented restriction on `recv()` at capacity 0 on the
    // fifo kind, which the dartdoc now carries, and the design question is
    // routed as a follow-up.
    //
    // ⚠️ NOT A GENERAL recv() DEFECT, and this is what bounds it: at every
    // capacity >= 1 the two preconditions cannot coincide, and the cells in
    // the group above pass. `tryRecv` at capacity 0 is unaffected either --
    // pinned green in pull_channel_test.dart -- because a synchronous pop is
    // exactly what releases the blocked push.
    test('recv() parks on a capacity-0 fifo until a synchronous pop releases '
        'the push', () async {
      final (pubSession, subSession) = await sessionPair(19321);
      addTearDown(pubSession.close);
      addTearDown(subSession.close);
      const ke = 'zenoh/dart/test/recv/cap0';

      // Two-session, doubly required here: a capacity-0 fifo is
      // full-when-empty, so same-session would risk the deadlock at put #1.
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final pending = pull.recv();
      var completed = false;
      unawaited(pending.then((_) => completed = true));

      pubSession.put(ke, 'through the eye of a needle');
      await Future<void>.delayed(const Duration(seconds: 3));

      // THE MEASUREMENT. At any capacity >= 1 this would have completed.
      expect(
        completed,
        isFalse,
        reason:
            'a capacity-0 fifo is a rendezvous: the delivery thread is '
            "blocked inside the tee's inner call, so the readiness ping "
            'cannot have been posted yet',
      );

      // ...and a SYNCHRONOUS pop is what breaks the standoff -- the same
      // mechanism that makes tryRecv work at capacity 0. Note the sample goes
      // to this pop, not to the parked recv().
      RecvResult<Sample> popped = const RecvEmpty<Sample>();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (popped is RecvEmpty<Sample> && DateTime.now().isBefore(deadline)) {
        popped = pull.tryRecv();
      }
      expect(
        popped,
        isA<RecvData<Sample>>(),
        reason: 'the push must have been released by the pop',
      );
      expect(
        (popped as RecvData<Sample>).value.payload,
        equals('through the eye of a needle'),
      );

      // The teardown drains before closing. ⚠️ THE ORIGINAL REASON FOR THIS
      // IS NOW STALE, and it is corrected rather than deleted because the
      // drain itself is still harmless and this cell still passes. It read:
      // closing with a rendezvous-blocked push still inside the tee's inner
      // call "would move the freeze out of this timeout-bounded cell and into
      // teardown, where no timeout protects it." That was TRUE WHEN WRITTEN
      // and is not true now: close() releases the receiving end before
      // undeclaring, so a parked push fails fast and the close returns. See
      // `fifo_close_deadlock_test.dart` (seed [MICRO-fifo-close],
      // 2026-08-25), whose capacity-0 cell closes exactly this configuration
      // without draining.
      //
      // ⚠️ AND THE STALE REASON WAS ITSELF A SYMPTOM: it treated a PRODUCT
      // DEFECT as a harness problem to be worked around by draining. The
      // drain stays as a courtesy -- it keeps this cell's teardown quiet --
      // not as freeze-avoidance.
      while (true) {
        if (pull.tryRecv() case RecvData()) {
          continue;
        }
        break;
      }
      // close() completes the still-parked recv() rather than leaving it
      // hanging -- the lifecycle guarantee holds even in this corner.
      pull.close();
      expect(await pending, isA<RecvDisconnected<Sample>>());
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ---------------------------------------------------------------------
  // Slice 10: recv()'s terminal states.
  //
  // A pending recv() MUST complete when the channel dies -- it never hangs
  // and never throws on a lifecycle path. Two ways for the producer to go
  // (the session closes, or this subscriber closes), and the two kinds do
  // opposite things with whatever is still buffered, so both are driven
  // through recv() and not only through tryRecv.
  //
  // Every cell is two-session and destroys the SUBSCRIBER session (or the
  // subscriber) while the publisher lives on. Every cell is timeout-bounded.
  // ---------------------------------------------------------------------
  group('recv() terminal states (TCP 19322)', () {
    Future<(Session, Session)> pair() => sessionPair(19322);

    test(
      'a pending recv() completes disconnected when the session closes',
      () async {
        final (pubSession, subSession) = await pair();
        addTearDown(pubSession.close);
        const ke = 'zenoh/dart/test/recv/term/session';

        final pull = subSession.declarePullSubscriber(ke, capacity: 4);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // Parked on an empty LIVE channel...
        final pending = pull.recv();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // ...and the producer goes away underneath it.
        subSession.close();

        final result = await pending.timeout(const Duration(seconds: 10));
        // Neither a hang nor a throw: a lifecycle event is a STATE.
        expect(result, isA<RecvDisconnected<Sample>>());
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'a pending recv() completes disconnected when the subscriber closes',
      () async {
        final (pubSession, subSession) = await pair();
        addTearDown(pubSession.close);
        addTearDown(subSession.close);
        const ke = 'zenoh/dart/test/recv/term/subscriber';

        final pull = subSession.declarePullSubscriber(ke, capacity: 4);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final pending = pull.recv();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // close() completes the waiter itself, synchronously, BEFORE it drops
        // anything native -- which is what makes this neither a hang nor a
        // use-after-free.
        pull.close();

        expect(
          await pending.timeout(const Duration(seconds: 10)),
          isA<RecvDisconnected<Sample>>(),
        );
        // ...and the handle is now disposed, which is a different thing from
        // the channel being dead.
        expect(pull.recv, throwsStateError);
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'fifo yields buffered data before disconnecting, through recv()',
      () async {
        final (pubSession, subSession) = await pair();
        addTearDown(pubSession.close);
        const ke = 'zenoh/dart/test/recv/term/fifo-drain';

        final pull = subSession.declarePullSubscriber(
          ke,
          kind: ChannelKind.fifo,
          capacity: 8,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        pubSession
          ..put(ke, 'a')
          ..put(ke, 'b');
        await Future<void>.delayed(const Duration(milliseconds: 800));

        subSession.close();

        // The drain-by-kind asymmetry, through the BLOCKING half of the surface
        // rather than only through tryRecv: buffered samples first, in order,
        // and the terminal state only once the buffer is empty.
        final first = await pull.recv().timeout(const Duration(seconds: 10));
        expect(first, isA<RecvData<Sample>>());
        expect((first as RecvData<Sample>).value.payload, equals('a'));

        final second = await pull.recv().timeout(const Duration(seconds: 10));
        expect(second, isA<RecvData<Sample>>());
        expect((second as RecvData<Sample>).value.payload, equals('b'));

        expect(
          await pull.recv().timeout(const Duration(seconds: 10)),
          isA<RecvDisconnected<Sample>>(),
        );
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test('ring disconnects immediately, through recv()', () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      const ke = 'zenoh/dart/test/recv/term/ring-discard';

      // Identical to the fifo cell except for the kind -- which is what makes
      // the opposite outcome attributable to the kind.
      final pull = subSession.declarePullSubscriber(ke, capacity: 8);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession
        ..put(ke, 'a')
        ..put(ke, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 800));

      subSession.close();

      // The ring discards its buffer: the samples that were demonstrably
      // there are gone, and recv() reports the terminal state at once rather
      // than parking forever waiting for a producer that no longer exists.
      expect(
        await pull.recv().timeout(const Duration(seconds: 10)),
        isA<RecvDisconnected<Sample>>(),
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('recv() after the producer already died never parks', () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      const ke = 'zenoh/dart/test/recv/term/already-dead';

      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      subSession.close();
      // Well after the fact: no readiness signal is coming, and none is
      // needed. recv() consults try_recv first, and canon's DISCONNECTED is
      // sticky and synchronously observable -- which is the fourth leg of the
      // never-hangs argument, driven here rather than asserted.
      await Future<void>.delayed(const Duration(seconds: 1));

      final result = await pull.recv().timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail(
          'recv() parked on an already-dead channel: it must have consulted '
          'try_recv first rather than arming and waiting for a signal that '
          'can never arrive',
        ),
      );
      expect(result, isA<RecvDisconnected<Sample>>());
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('repeated recv() on a dead channel stays terminal', () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      const ke = 'zenoh/dart/test/recv/term/sticky';

      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      subSession.close();

      // Canon's terminal state is a permanent property of the handler, not a
      // one-shot notification -- so a second and third call report it again
      // rather than parking.
      for (var i = 0; i < 3; i++) {
        expect(
          await pull.recv().timeout(const Duration(seconds: 5)),
          isA<RecvDisconnected<Sample>>(),
          reason: 'call ${i + 1}',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
