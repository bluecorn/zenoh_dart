import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

/// Seed `[DM-bounded-stream]`, criterion B: the two channel KINDS seen through
/// the demand-gated `Stream`, the ring's own boundary, and capacity zero.
///
/// **This file changes no production code.** Every behaviour it drives already
/// shipped; what is new is that all of it is driven through
/// `PullSubscriber.stream` rather than through `tryRecv`.
///
/// ## The ruled prong-2 observables, quoted verbatim
///
/// From `development/planning/20260818_1030_seed5_ch_channels.md:430-432`:
///
/// > *"**The prong-2 observable redesign is accepted** -- producer-side
/// > put-blocking is unobservable in the only permitted topology, so the
/// > **lossless-through-overflow-versus-lossy-ring contrast** plus the
/// > **exactly-capacity retention cell** are the honest observables."*
///
/// ## ⚠️ The put-timing half of that "exactly-capacity" cell is DROPPED
///
/// Not deferred and not forgotten: **measured dead.** A probe published 8
/// samples into a capacity-4 fifo and **all eight puts returned in 0 ms**,
/// which contradicts the ruling quoted three lines above it. Producer-side
/// blocking is not observable from the publishing session at all here, because
/// the callback that blocks runs on the SUBSCRIBER's native thread; the
/// publisher only ever sees it as transport backpressure, and four tiny
/// samples never reach that.
///
/// Its replacement is the consumer-side ring-boundary pair below -- cells 19
/// and 20 -- and it is stronger than either half it replaces: it pins the
/// exact delivered SEQUENCE at `capacity + 1` and at `capacity + 2`, so the
/// channel's bound and the gate's one-slot stash are both asserted by value
/// rather than by count.
///
/// ⚠️ Every cell here uses TWO SESSIONS over TCP loopback, and that is a hard
/// bound rather than a preference: publishing into a full fifo from the
/// session that owns the subscriber blocks the putter permanently inside a
/// synchronous FFI call, which would freeze the whole serial suite rather than
/// fail a cell.
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

  group('Criterion B: kinds and boundaries on the sample column (TCP 19591)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19591);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Waits until the SETTLE SENTINEL has seen [n] samples, then allows a
    /// declared slack.
    ///
    /// ⚠️ Draining a channel while delivery is still in flight OVER-COUNTS,
    /// and the exact-sequence arithmetic in cells 19 and 20 is then
    /// meaningless: a probe published 8 into a capacity-4 fifo and drained
    /// SEVEN, because the transport was feeding the channel as the drain ran.
    /// So the resume is gated on an observable that says the link delivered
    /// everything TO THIS PEER -- a plain push subscriber on the same keyexpr
    /// and the same session, running on the same delivery path the ring's own
    /// callback does.
    ///
    /// The 50 ms is **settle time for callback ordering between two
    /// subscribers on one delivery**, declared as such. It is NOT the race
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
    /// Deadline-bounded and self-diagnosing: a stream that never quiesces
    /// fails the cell rather than hanging the serial suite.
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

    /// Drives the ring-boundary recipe on [ke] with [n] samples `m0..m{n-1}`
    /// and returns what the RESUMED bounded stream delivered.
    ///
    /// Shared by cells 19 and 20, which differ only in [n] and in the sequence
    /// they assert.
    Future<List<String>> ringBoundaryRun(String ke, int n) async {
      // Volume: n x tens of bytes (n is 5 or 6) into a capacity-4 RING --
      // `kind` is omitted because ring is the declared default.
      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);

      // THE SETTLE SENTINEL: a plain push subscriber on the same session and
      // keyexpr. See `awaitSettled`.
      final sentinel = <Sample>[];
      final watch = subSession.declareSubscriber(ke);
      addTearDown(watch.close);
      final watching = watch.stream.listen(sentinel.add);
      addTearDown(watching.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final got = <String>[];
      // Synchronously paused BEFORE any traffic: cascaded onto the listen, so
      // nothing at all runs between them.
      final sub = pull.stream.listen((s) => got.add(s.payload))..pause();
      addTearDown(() async {
        sub.resume();
        await sub.cancel();
      });
      expect(
        pull.pullInFlightForTesting,
        isTrue,
        reason: 'the first pull must start synchronously inside onListen',
      );
      expect(pull.stashHeldForTesting, isFalse);

      final pub = pubSession.declarePublisher(
        ke,
        congestionControl: CongestionControl.block,
      );
      addTearDown(pub.close);

      // ⚠️ THE FIRST SAMPLE IS PUBLISHED ALONE AND THE STASH IS THEN
      // ASSERTED, rather than the cell inferring that `m0` is what completes
      // the pull in flight. Under a burst that inference is FALSE on a ring:
      // nothing runs the Dart event loop between the puts, so by the time the
      // pending `recv()` is completed the ring has already evicted the early
      // arrivals. Measured on the burst-only form of a sibling cell, the stash
      // held `seq94`, not `seq0`. Assert the drive loop's state through the
      // observable; never read it off a recipe.
      pub.put('m0');
      await waitUntil(
        () => pull.stashHeldForTesting,
        timeout: const Duration(seconds: 10),
        description: 'm0 to complete the in-flight pull and be stashed',
      );
      expect(
        pull.pullInFlightForTesting,
        isFalse,
        reason: 'the loop exits once it has stashed into a paused gate',
      );

      // Only NOW the rest, which therefore land purely in the channel: the
      // drive loop has exited and issues no further pull while paused.
      for (var i = 1; i < n; i++) {
        pub.put('m$i');
      }

      await awaitSettled(sentinel, n);
      sub.resume();
      return drainUntilQuiet(got);
    }

    test(
      'fifo is lossless through overflow, consumed through the Stream',
      () async {
        const ke = 'zenoh/dart/test/bskind/fifo-lossless';
        const n = 20;
        // Volume: 20 x tens of bytes into a capacity-4 FIFO -- five times the
        // bound, so the channel must have held the producer back rather than
        // made room. Two sessions, because a same-session publish into a full
        // fifo blocks the putter forever.
        final pull = subSession.declarePullSubscriber(
          ke,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final pub = pubSession.declarePublisher(
          ke,
          congestionControl: CongestionControl.block,
        );
        addTearDown(pub.close);
        for (var i = 0; i < n; i++) {
          pub.put('m$i');
        }
        // Settle time for the burst, declared as such: consumption must not
        // start mid-publish, or the channel never reaches its bound and the
        // cell measures a generous buffer instead of backpressure.
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final got = <String>[];
        // `await for` IS the demand-gated idiom: the subscription is paused for
        // the duration of every loop body, so pause/resume is exercised on
        // EVERY element rather than once. It will not terminate on its own here
        // -- the stream stays open -- so the loop breaks at n.
        Future<void> consume() async {
          await for (final s in pull.stream) {
            got.add(s.payload);
            if (got.length >= n) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }

        await consume().timeout(
          const Duration(seconds: 60),
          onTimeout: () => fail(
            'only ${got.length} of $n samples arrived through the bounded '
            'stream: $got',
          ),
        );

        // The slow consumer cost throughput, not data. MEASURED: all 20, in
        // publication order, [m0 .. m19].
        expect(got, hasLength(n));
        expect(got, equals([for (var i = 0; i < n; i++) 'm$i']));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('ring at the same capacity loses -- the contrast control', () async {
      const ke = 'zenoh/dart/test/bskind/ring-lossy';
      const n = 20;
      // Identical volume (20 x tens of bytes), identical capacity (4),
      // identical 25 ms pacing and the identical two-session topology as the
      // fifo cell above. Only `kind` differs -- and it is omitted here
      // because ring is the declared default.
      final pull = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final pub = pubSession.declarePublisher(
        ke,
        congestionControl: CongestionControl.block,
      );
      addTearDown(pub.close);
      for (var i = 0; i < n; i++) {
        pub.put('m$i');
      }
      // Settle for the burst rather than polling: polling would consume
      // mid-burst and change what the cell measures.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final got = <String>[];
      Future<void> consume() async {
        await for (final s in pull.stream) {
          got.add(s.payload);
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }

      // No count to wait for -- the survivors are not predictable in advance,
      // which is the whole point of the cell -- so a BOUNDED quiescence drain
      // stands in for one. The consuming future is ended by the teardown
      // below closing the handle, which closes the gate's controller.
      final consuming = consume();
      addTearDown(() async {
        pull.close();
        await consuming;
      });
      await drainUntilQuiet(got);

      // BOUNDED ON BOTH SIDES. `lessThan(n)` alone would pass just as happily
      // on a topology that delivered NOTHING -- a dead session, a subscriber
      // that never matched -- which is the vacuous green this pair exists to
      // exclude.
      //
      // MEASURED, for the record and because the bound alone understates how
      // sharp the contrast is -- 20 published, FOUR delivered, and they are
      // exactly the ring's last four:
      //
      //   [m16, m17, m18, m19]
      //
      // The identical publication the fifo cell above delivered whole.
      expect(
        got.length,
        greaterThanOrEqualTo(1),
        reason:
            'the ring must actually have received traffic, or the loss '
            'below is measuring a broken topology instead',
      );
      expect(
        got.length,
        lessThan(n),
        reason: 'the identical volume the fifo delivered whole: $got',
      );

      // DROP-OLDEST, NOT DROP-ARBITRARY: whatever survived is a monotonic
      // subsequence of the published order.
      final indices = [
        for (final p in got) int.parse(p.substring(1)),
      ];
      for (var i = 1; i < indices.length; i++) {
        expect(
          indices[i],
          greaterThan(indices[i - 1]),
          reason: 'a drop-oldest ring keeps a monotonic subsequence; got $got',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the ring boundary at capacity + 1 -- everything is kept', () async {
      // 5 x tens of bytes: one stashed by the paused gate, four exactly
      // filling the capacity-4 ring. Nothing is evicted, so nothing is lost
      // even on the kind that CAN lose.
      final got = await ringBoundaryRun(
        'zenoh/dart/test/bskind/ring-boundary-1',
        5,
      );
      expect(
        got,
        equals(['m0', 'm1', 'm2', 'm3', 'm4']),
        reason:
            'm0 in the stash plus m1..m4 exactly filling capacity 4; the '
            'stash is flushed BEFORE the next pull, so it leads',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the ring boundary at capacity + 2 -- exactly one dropped, and it is '
        'the SECOND', () async {
      // 6 x tens of bytes: one stashed by the paused gate, five offered to a
      // capacity-4 ring, so exactly one entry is evicted.
      //
      // ⚠️ THIS IS THE TRAP. The intuitive assertion -- "the ring drops the
      // OLDEST, so m0 is gone" -- is FALSE here, because m0 is not in the
      // channel at all: it completed the pull that was in flight when the
      // gate was paused and is sitting in the one-slot stash. The oldest
      // entry the RING holds is m1, and m1 is what it evicts.
      //
      // The two failure branches, named with their diagnoses:
      //
      //   [m1, m2, m3, m4, m5] => no stash existed; the pinned in-flight
      //                           semantics are violated (cell 4 of
      //                           bounded_stream_test.dart should already
      //                           have caught it).
      //   [m0, m1, m2, m3, m4] => the ring did not evict at capacity.
      final got = await ringBoundaryRun(
        'zenoh/dart/test/bskind/ring-boundary-2',
        6,
      );
      expect(
        got,
        equals(['m0', 'm2', 'm3', 'm4', 'm5']),
        reason:
            'm0 survives in the STASH, so the entry the ring evicted is '
            'm1 -- not the oldest sample, the oldest CHANNEL entry',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      test('capacity 0 fifo: the Stream starves, and the handle still recovers '
          'a sample', () async {
        const ke = 'zenoh/dart/test/bskind/cap0-fifo';
        // Volume: 4 x tens of bytes into a capacity-0 FIFO, two sessions. At
        // capacity 0 a fifo is a RENDEZVOUS -- full when it is empty -- so
        // the delivery blocks waiting for a concurrent consumer and the
        // readiness signal `recv()` waits on is only raised after that
        // delivery returns. The drive loop is the only consumer that could
        // release it, and it is parked in `recv()`. `recv()` is documented as
        // not usable in exactly this configuration.
        final pull = subSession.declarePullSubscriber(
          ke,
          kind: ChannelKind.fifo,
          capacity: 0,
        );
        addTearDown(pull.close);

        final viaStream = <String>[];
        final sub = pull.stream.listen((s) => viaStream.add(s.payload));
        addTearDown(sub.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final pub = pubSession.declarePublisher(
          ke,
          congestionControl: CongestionControl.block,
        );
        addTearDown(pub.close);
        for (var i = 0; i < 4; i++) {
          pub.put('a$i');
        }

        // (i) A bounded window with NO poller at all. Listening and unpaused
        // throughout, so this is starvation rather than absent demand.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(
          viaStream,
          isEmpty,
          reason:
              'a capacity-0 fifo is a rendezvous: the parked recv() is '
              'the only consumer that could release the delivery it is '
              'waiting on',
        );

        // (ii) The same handle, polled synchronously. A `tryRecv` IS the
        // concurrent consumer the rendezvous needs, so it releases the
        // delivery and recovers a sample.
        //
        // ⚠️ THIS CELL DELIBERATELY DOES NOT ASSERT THAT THE STREAM STAYED
        // STARVED DURING (ii). It does not: a single interleaved poll
        // un-wedges the rendezvous chain and the Stream then delivers the
        // rest. Measured: `viaPoll=[a0] viaStream=[a1, a2, a3]`. An earlier
        // draft asserted both and was red-or-flaky. No guard is added at
        // capacity 0 either -- that was explicitly declined upstream.
        final viaPoll = <String>[];
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (viaPoll.isEmpty && DateTime.now().isBefore(deadline)) {
          if (pull.tryRecv() case RecvData(:final value)) {
            viaPoll.add(value.payload);
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        // MEASURED HERE, and it reproduces the plan's own probe: phase (i)
        // `viaStream=[]`, phase (ii) `viaPoll=[a0]`.
        expect(
          viaPoll,
          isNotEmpty,
          reason:
              'the synchronous poll is the concurrent consumer, so at '
              'least one sample must come back through the handle',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));

      test(
        'capacity 0 ring: pinned as measured, on this column and this kind',
        () async {
          const ke = 'zenoh/dart/test/bskind/cap0-ring';
          // Volume: 4 x tens of bytes into a capacity-0 RING, two sessions.
          // `kind` omitted -- ring is the declared default.
          final published = [for (var i = 0; i < 4; i++) 'r$i'];
          final pull = subSession.declarePullSubscriber(ke, capacity: 0);
          addTearDown(pull.close);

          final viaStream = <String>[];
          final sub = pull.stream.listen((s) => viaStream.add(s.payload));
          addTearDown(sub.cancel);
          await Future<void>.delayed(const Duration(milliseconds: 800));

          final pub = pubSession.declarePublisher(
            ke,
            congestionControl: CongestionControl.block,
          );
          addTearDown(pub.close);
          published.forEach(pub.put);
          await Future<void>.delayed(const Duration(milliseconds: 1500));

          // ⭐ PINNED AS MEASURED ON THIS COLUMN AND THIS KIND, and nowhere
          // else. Branch **(β)**: the bounded Stream DOES deliver at capacity 0
          // on a ring. Observed verbatim on this machine, four published:
          //
          //   viaStream=[r3]
          //
          // -- the newest, so a capacity-0 ring behaves as a drop-oldest ring
          // that holds one, not as the fifo's rendezvous. That matches the
          // shipped `recv()` dartdoc, which excludes only `fifo` at capacity 0
          // and says every capacity on a ring is unaffected.
          //
          // The ASSERTION is branch (β) as the plan defines it -- "delivers at
          // least one" -- rather than the exact `[r3]`: which single element
          // survives a burst nothing yields between is a timing artefact, and
          // pinning it would pin the machine rather than the contract. The
          // observation is recorded above so a future change of behaviour is
          // still legible.
          //
          // ⚠️ NO EXTRAPOLATION TO THE QUERY COLUMN. Capacity 0 is pinned per
          // column and per kind; the query column is pinned by its own cell.
          expect(
            viaStream,
            isNotEmpty,
            reason:
                'branch (beta): a capacity-0 ring delivers through the '
                'bounded Stream; got $viaStream',
          );
          expect(
            viaStream.every(published.contains),
            isTrue,
            reason:
                'everything delivered must be something published, or the '
                'branch above is reading noise; got $viaStream',
          );
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    });
  });
}
