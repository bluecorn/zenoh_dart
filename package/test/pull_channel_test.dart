import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

/// Seed #5's channel-kind surface: the fifo sample channel, bound end-to-end,
/// beside the ring channel that shipped first.
///
/// ⚠️ EVERY overflow / backpressure / drain cell in this file uses TWO
/// SESSIONS, and that is a hard bound rather than a stylistic preference.
/// Measured at canon (seed #5 survey, probe 1 cell E): publishing into a FULL
/// fifo from the same session that owns the subscriber blocks the putter
/// PERMANENTLY -- same-session local delivery pushes into the fifo on the
/// putter's own thread, so a single thread acting as both producer and only
/// consumer deadlocks inside a synchronous FFI call, unrecoverable from Dart.
/// A same-session fifo-full cell would not fail; it would freeze the suite.
void main() {
  /// Opens a listener/connector pair on [port] and returns (publisher,
  /// subscriber) sessions. Multicast and gossip are OFF: a test that inherits
  /// the LAN is testing the LAN.
  Future<(Session, Session)> sessionPair(
    int port, {
    bool timestamping = false,
  }) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    if (timestamping) {
      listener.insertJson5('timestamping/enabled', 'true');
    }
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

  group('Channel kinds, bound end-to-end (TCP 19270)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19270);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test('a fifo pull subscriber declares and delivers', () async {
      final pull = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/fifo/basic',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final payload = Uint8List.fromList([0x7a, 0x64, 0x00, 0xff, 0x2a]);
      pubSession.putBytes(
        'zenoh/dart/test/chan/fifo/basic',
        ZBytes.fromUint8List(payload),
      );

      final sample = await pollRecv(pull);
      expect(sample, isNotNull);
      // Byte-exact, not string-compared: the payload deliberately carries a
      // NUL and an invalid-UTF-8 byte, so a lossy path could not pass here.
      expect(sample!.payloadBytes, equals(payload));
    });

    test('ring remains the default and behaves exactly as before', () async {
      // No `kind:` argument at all -- the binding-decided default must be
      // ring, so every caller that predates this seed keeps its behaviour
      // byte-for-byte.
      final pull = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/default',
        capacity: 1,
      );
      addTearDown(pull.close);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      pubSession
        ..put('zenoh/dart/test/chan/default', 'first')
        ..put('zenoh/dart/test/chan/default', 'second');

      // Settle time for the burst, deliberately NOT a poll: with capacity 1
      // the buffer holds one at a time, so draining on first arrival would
      // consume 'first' and change what the cell means.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final result = pull.tryRecv();
      expect(result, isA<RecvData<Sample>>());
      // Drop-oldest: only the latest survived. That is the RING contract, and
      // it is the discriminator against the fifo cells below.
      expect((result as RecvData<Sample>).value.payload, equals('second'));
      expect(pull.tryRecv(), isA<RecvEmpty<Sample>>());
    });

    test('an empty live fifo reports empty, not disconnected', () {
      final pull = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/fifo/empty',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);

      // Nothing published. Canon's Z_CHANNEL_NODATA -- alive, keep polling --
      // pinned EXPLICITLY on the fifo kind. The drain cells only exercise it
      // implicitly, and "alive-and-empty" is exactly the state a fifo could
      // plausibly get wrong at capacity boundaries.
      expect(pull.tryRecv(), isA<RecvEmpty<Sample>>());
    });

    test('the kind crosses the seam as an explicit value', () {
      // CONV-1: an enum that crosses the FFI as an int carries an explicit
      // `value`, never `.index`. The two happen to coincide today, which is
      // precisely why this is pinned -- a reordering of the enum would
      // silently repoint the dispatch if `.index` were ever used.
      expect(ChannelKind.ring.value, equals(0));
      expect(ChannelKind.fifo.value, equals(1));
      expect(ChannelKind.values, hasLength(2));

      // ⚠️ These are OUR shim's dispatch codes, not canon's: canon has no
      // channel-kind enum at all, only two separately-named constructors.
    });
  });

  group('Channel kinds coexist (TCP 19271)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19271);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test('both kinds coexist on one session with no cross-talk', () async {
      final ring = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/both/**',
        capacity: 4,
      );
      addTearDown(ring.close);
      final fifo = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/both/**',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(fifo.close);

      await Future<void>.delayed(const Duration(milliseconds: 800));

      pubSession.put('zenoh/dart/test/chan/both/x', 'shared');

      // Each receives INDEPENDENTLY: two channels, two buffers, one wire
      // sample. If the kind dispatch shared state between the two handler
      // types, one of these would come up empty.
      final fromRing = await pollRecv(ring);
      final fromFifo = await pollRecv(fifo);
      expect(fromRing, isNotNull);
      expect(fromFifo, isNotNull);
      expect(fromRing!.payload, equals('shared'));
      expect(fromFifo!.payload, equals('shared'));

      // ...and neither drained the other.
      expect(ring.tryRecv(), isA<RecvEmpty<Sample>>());
      expect(fifo.tryRecv(), isA<RecvEmpty<Sample>>());
    });

    test('close releases the correct handler type for a fifo', () {
      final fifo = subSession.declarePullSubscriber(
        'zenoh/dart/test/chan/fifo/close',
        kind: ChannelKind.fifo,
        capacity: 2,
      );

      // The drop entry is kind-dispatched: a fifo handler slot released
      // through the ring drop would corrupt the heap rather than raise, so
      // "returns normally, twice, and the process is still alive to run the
      // next cell" is the observable. Idempotence is ours, not canon's.
      expect(fifo.close, returnsNormally);
      expect(fifo.close, returnsNormally);
    });
  });

  // ---------------------------------------------------------------------
  // Slice 4: fifo is lossless-bounded; ring is lossy. The prong-2 leg.
  //
  // ⚠️ WHAT THIS GROUP DOES **NOT** PROVE, stated up front so a later reader
  // does not read more into a green than is there.
  //
  // It does not observe PRODUCER-SIDE BLOCKING. In the only topology these
  // cells are permitted to use -- two sessions -- every `put` returns: the
  // block lands on the SUBSCRIBER's delivery thread, not in the publisher's
  // call. (The topology where producer-side blocking IS observable is the
  // same-session one, and that one deadlocks the suite rather than
  // demonstrating anything. It is barred, not merely avoided.)
  //
  // So the observable used instead is LOSSLESSNESS THROUGH OVERFLOW AGAINST A
  // LOSSY CONTROL: a slow consumer draining a fifo of capacity C while N >> C
  // samples are published receives ALL N, in order; the identical run on a
  // RING of the same capacity loses samples. Completeness alone would be
  // consistent with "the buffer was simply big enough"; the ring contrast at
  // the same capacity is what eliminates that reading.
  //
  // ⚠️ ATTRIBUTION, precisely. The ring control bounds the RING. The FIFO's
  // C-bound rests on canon-level measurement (survey GT 8: put #3 blocked on a
  // capacity-2 fifo -- capacity honoured, replicated with a ring control) plus
  // the structural capacity seam, NOT on the ring contrast. What the contrast
  // buys here is eliminating the buffer-absorbed-it reading of completeness.
  //
  // ⚠️ THE VOLUME IS BOUNDED CONSCIOUSLY, and the reason is written down.
  // Two sessions in one process means `put` under CongestionControl.block is a
  // synchronous FFI call on the ONLY thread that can drain. Push it far enough
  // and: fifo full -> delivery thread blocked in the push -> TCP rx window
  // fills -> the publisher's transport queue fills -> `put` blocks the very
  // thread that would have drained it. That is the same-session deadlock one
  // level up, transport-mediated. So N >> C here means SMALL N and SMALL
  // payloads, sized to stay inside the loopback and queue slack. If a cell
  // ever needs volume beyond that, the producer moves to a subprocess -- the
  // volume does not get raised in-process.
  // ---------------------------------------------------------------------
  group('fifo is lossless, ring is lossy (TCP 19280)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19280);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Drains to exhaustion, deadline-bounded so a stalled channel fails the
    /// cell instead of spinning. [perSample] is the slow-consumer pacing.
    Future<List<String>> drain(
      PullSubscriber pull, {
      required int expect,
      Duration perSample = Duration.zero,
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final got = <String>[];
      final deadline = DateTime.now().add(timeout);
      while (got.length < expect && DateTime.now().isBefore(deadline)) {
        switch (pull.tryRecv()) {
          case RecvData(:final value):
            got.add(value.payload);
            if (perSample > Duration.zero) {
              await Future<void>.delayed(perSample);
            }
          case RecvDisconnected():
            return got;
          case RecvEmpty():
            await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      return got;
    }

    test('fifo is lossless and in-order through overflow', () async {
      const ke = 'zenoh/dart/test/chan/thr/fifo4';
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 2,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Four into a capacity-2 fifo: twice the bound, so the channel MUST
      // have held the producer back rather than made room.
      for (var i = 0; i < 4; i++) {
        pubSession.put(ke, 'm$i');
      }

      final got = await drain(pull, expect: 4);
      expect(got, equals(['m0', 'm1', 'm2', 'm3']));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'ring drops oldest at the same capacity -- the contrast control',
      () async {
        const ke = 'zenoh/dart/test/chan/thr/ring4';
        final pull = subSession.declarePullSubscriber(ke, capacity: 2);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        for (var i = 0; i < 4; i++) {
          pubSession.put(ke, 'm$i');
        }
        // Settle for the burst rather than polling: polling would drain
        // mid-burst and change what the cell measures.
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final got = await drain(
          pull,
          expect: 4,
          timeout: const Duration(seconds: 3),
        );
        // Exactly the LAST two, in order. The identical publication that the
        // fifo delivered whole.
        expect(got, equals(['m2', 'm3']));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test('a slow consumer bounds the buffer without losing anything', () async {
      const ke = 'zenoh/dart/test/chan/thr/slow-fifo';
      const n = 20;
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // N >> capacity (20 vs 4), payloads tiny -- see the volume note above.
      // CongestionControl.block is the publisher half of "do not drop".
      final pub = pubSession.declarePublisher(
        ke,
        congestionControl: CongestionControl.block,
      );
      addTearDown(pub.close);
      for (var i = 0; i < n; i++) {
        pub.put('m$i');
      }

      // The slow consumer: a real per-sample delay, so the channel spends most
      // of the run at its bound with the producer held back.
      final got = await drain(
        pull,
        expect: n,
        perSample: const Duration(milliseconds: 25),
      );

      expect(got, hasLength(n));
      expect(got, equals([for (var i = 0; i < n; i++) 'm$i']));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'the same volume on ring loses -- the fake-bound discriminator',
      () async {
        const ke = 'zenoh/dart/test/chan/thr/slow-ring';
        const n = 20;
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
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final got = await drain(
          pull,
          expect: n,
          perSample: const Duration(milliseconds: 25),
          timeout: const Duration(seconds: 5),
        );

        // THE DISCRIMINATOR. This is what makes the fifo cell's completeness
        // evidence of backpressure rather than of a generous buffer: the same
        // volume, the same capacity, the same slow consumer, and the ring
        // cannot deliver it.
        // Bounded on BOTH sides. `lessThan(n)` alone would pass just as
        // happily on a ring that delivered NOTHING -- a broken topology, a
        // dead session, a subscriber that never matched -- which is the
        // vacuous green this pair exists to exclude. The lower bound says the
        // channel really was carrying traffic; the upper bound says it could
        // not carry all of it.
        expect(
          got,
          isNotEmpty,
          reason:
              'the ring must actually have received traffic, or the '
              'loss below is measuring a broken topology instead',
        );
        expect(
          got.length,
          lessThan(n),
          reason: 'a ring at capacity 4 cannot deliver 20 samples losslessly',
        );
        // What it does retain is a suffix, in order -- drop-OLDEST, not
        // drop-arbitrary.
        expect(got, equals(got.toList()..sort(_byIndex)));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test('capacity 1 fifo still delivers every sample', () async {
      const ke = 'zenoh/dart/test/chan/thr/fifo1';
      const n = 6;
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 1,
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

      // The tightest bound canon's fifo can be given without loss: every
      // sample must pass through a one-slot buffer, one at a time.
      final got = await drain(
        pull,
        expect: n,
        perSample: const Duration(milliseconds: 25),
      );
      expect(got, equals([for (var i = 0; i < n; i++) 'm$i']));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ---------------------------------------------------------------------
  // Slice 5: drain-by-kind at the END of a channel's life, and canon's own
  // polling idiom.
  //
  // The two kinds do OPPOSITE things when the producer dies, and no document
  // in canon or in any peer binding says so -- it was measured (survey GT 6).
  // The cpp peer's session-close doc even claims generically that it is
  // "still possible to process any already received messages", which is true
  // for fifo and false for ring. Rendered here unsmoothed: draining a ring's
  // residue on its behalf would fabricate behaviour canon does not have.
  //
  // Every cell is two-session, and each destroys its SUBSCRIBER session while
  // the publisher lives on -- that is what drops the producer closure and
  // makes the handler observe DISCONNECTED, with the handler itself still
  // alive and legal to call.
  // ---------------------------------------------------------------------
  group('drain-by-kind through tryRecv (TCP 19290)', () {
    /// A fresh pair per cell: these tests destroy their subscriber session.
    Future<(Session, Session)> pair() => sessionPair(19290);

    test('fifo drains its buffer, then reports disconnected', () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      const ke = 'zenoh/dart/test/chan/drain/fifo';

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

      // Kill the producer side with both samples still unread.
      subSession.close();

      // A fifo hands over what it holds FIRST, in order, and only reports
      // the terminal state once it is empty.
      final first = pull.tryRecv();
      expect(first, isA<RecvData<Sample>>());
      expect((first as RecvData<Sample>).value.payload, equals('a'));

      final second = pull.tryRecv();
      expect(second, isA<RecvData<Sample>>());
      expect((second as RecvData<Sample>).value.payload, equals('b'));

      expect(pull.tryRecv(), isA<RecvDisconnected<Sample>>());
      expect(pull.tryRecv(), isA<RecvDisconnected<Sample>>());
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'ring discards its buffer and reports disconnected immediately',
      () async {
        final (pubSession, subSession) = await pair();
        addTearDown(pubSession.close);
        const ke = 'zenoh/dart/test/chan/drain/ring';

        final pull = subSession.declarePullSubscriber(ke, capacity: 8);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // Identical setup to the fifo cell above -- same capacity, same two
        // samples, same unread state. Only the kind differs, which is what
        // makes the opposite outcome attributable to the kind.
        pubSession
          ..put(ke, 'a')
          ..put(ke, 'b');
        await Future<void>.delayed(const Duration(milliseconds: 800));

        subSession.close();

        expect(pull.tryRecv(), isA<RecvDisconnected<Sample>>());
        expect(pull.tryRecv(), isA<RecvDisconnected<Sample>>());
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test("canon's polling idiom is writable in Dart", () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      const ke = 'zenoh/dart/test/chan/drain/idiom';

      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      for (var i = 0; i < 3; i++) {
        pubSession.put(ke, 'm$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      subSession.close();

      // THE POINT OF THE WHOLE SEED, in one loop. This is the shape of
      // canon's own `z_non_blocking_get.c`:
      //
      //     while (try_recv != Z_CHANNEL_DISCONNECTED) {
      //       if (!OK) backoff;
      //     }
      //
      // Its terminal condition IS the discriminant. Against the old surface
      // it was unwritable: `null` meant both "back off" and "stop", so the
      // only way to leave was a timeout -- a guess about the network dressed
      // up as a loop condition.
      //
      // ⚠️ THERE IS DELIBERATELY NO DEADLINE IN THIS LOOP. That is the
      // assertion. If the discriminant did not reach the caller the loop
      // would never exit, and the cell's own timeout would fail it loudly.
      final collected = <String>[];
      var loop = true;
      while (loop) {
        switch (pull.tryRecv()) {
          case RecvData(:final value):
            collected.add(value.payload);
          case RecvEmpty():
            await Future<void>.delayed(const Duration(milliseconds: 10));
          case RecvDisconnected():
            loop = false;
        }
      }

      expect(collected, equals(['m0', 'm1', 'm2']));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'StateError and RecvDisconnected are pinned distinctly, both kinds',
      () async {
        for (final kind in ChannelKind.values) {
          final (pubSession, subSession) = await pair();
          const ke = 'zenoh/dart/test/chan/drain/distinct';

          final pull = subSession.declarePullSubscriber(
            ke,
            kind: kind,
            capacity: 4,
          );
          await Future<void>.delayed(const Duration(milliseconds: 400));

          subSession.close();

          // Canon's terminal STATE, on a live handle.
          expect(
            pull.tryRecv(),
            isA<RecvDisconnected<Sample>>(),
            reason: 'kind=$kind',
          );

          // Our disposed-handle guard, after we drop the handle ourselves.
          // These are different things and must never collapse into one: the
          // guard is what stands between Dart and canon's loan-on-gravestone,
          // which is undefined behaviour rather than a reported error.
          pull.close();
          expect(pull.tryRecv, throwsStateError, reason: 'kind=$kind');

          pubSession.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('the drain window closes at close()', () async {
      final (pubSession, subSession) = await pair();
      addTearDown(pubSession.close);
      addTearDown(subSession.close);
      const ke = 'zenoh/dart/test/chan/drain/window';

      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession
        ..put(ke, 'a')
        ..put(ke, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // Our handle owns BOTH halves of the channel -- the subscriber and the
      // handler -- so close() releases the buffer with whatever is still in
      // it. The cpp peer can hand the handler back from `undeclare() &&` and
      // keep draining; our recorded carve folds the handler into the owned
      // handle, so the honest consequence is that the drain window shuts
      // here. Drain-before-close is the documented pattern, and this is the
      // cell that pins it rather than leaving it to be discovered.
      pull.close();

      expect(pull.tryRecv, throwsStateError);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  // ---------------------------------------------------------------------
  // Slice 6: the capacity contract.
  //
  // Canon documents NOTHING about capacity -- no statement about 0, no
  // minimum, no fifo-full language, anywhere in zenoh-c's headers, docs,
  // examples, tests or README. Its constructors take a raw `size_t` and
  // return void: they cannot fail and cannot reject a value. No peer
  // validates it either (cpp takes `size_t` raw and never tests 0; kotlin has
  // no capacity surface at all). So every domain check that exists at all is
  // ours, and the domain seam is ours alone -- the peers' capacity types are
  // unsigned and never face the question a signed Dart `int` raises.
  //
  // ⚠️ EVERY CELL HERE IS TWO-SESSION, stated explicitly rather than left
  // implied by the port. The capacity-0 fifo cell is the one place where
  // same-session is both unmeasured and plausibly the deadlock at put #1: if
  // a capacity-0 fifo is a rendezvous rather than a clamp, it is
  // full-when-empty. The canon probe that measured capacity 0 was itself
  // two-session; the same-session probes used capacities 4 and 2, never 0.
  // ---------------------------------------------------------------------
  group('the capacity contract (TCP 19300)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      (pubSession, subSession) = await sessionPair(19300);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test('a negative capacity is rejected before any native call', () async {
      const ke = 'zenoh/dart/test/chan/cap/negative';
      final pub = pubSession.declarePublisher(ke);
      addTearDown(pub.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(pub.hasMatchingSubscribers(), isFalse);

      for (final kind in ChannelKind.values) {
        expect(
          () => subSession.declarePullSubscriber(ke, kind: kind, capacity: -1),
          throwsA(isA<ArgumentError>()),
          reason: 'kind=$kind',
        );
      }

      // NOTHING WAS DECLARED. The throw alone would not show that -- a
      // subscriber could have been declared and then thrown on the way out,
      // leaving a live declaration on the network. The publisher's matching
      // status is the outside view.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(pub.hasMatchingSubscribers(), isFalse);

      // CONTROL, and it is load-bearing: `isFalse` above would hold just as
      // well if matching status never went true for anything. A valid
      // subscriber on the same key expression must flip it, or the two
      // assertions above are measuring a blind instrument.
      final valid = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(valid.close);
      await waitUntil(
        pub.hasMatchingSubscribers,
        description: 'the publisher to see a VALID subscriber',
      );
      expect(pub.hasMatchingSubscribers(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('capacity zero declares and delivers on ring', () async {
      const ke = 'zenoh/dart/test/chan/cap/zero-ring';
      final pull = subSession.declarePullSubscriber(ke, capacity: 0);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession.put(ke, 'zero');

      // MEASURED AT 1.8.0, NOT PROMISED BY CANON. Zero is inside canon's
      // `size_t` domain, so rejecting it would narrow canon's surface on no
      // canon-intrinsic ground. This cell pins what it actually does, and
      // the dartdoc says exactly that.
      final sample = await pollRecv(pull);
      expect(sample, isNotNull);
      expect(sample!.payload, equals('zero'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('capacity zero declares and delivers on fifo', () async {
      const ke = 'zenoh/dart/test/chan/cap/zero-fifo';
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 0,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession.put(ke, 'zero');

      final sample = await pollRecv(pull);
      expect(sample, isNotNull);
      expect(sample!.payload, equals('zero'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('the shipped default is unchanged', () async {
      const ke = 'zenoh/dart/test/chan/cap/default';
      // No `capacity:` argument -- the binding-decided default, restated as
      // such because canon forces the caller to choose and offers no default
      // to defer to. 256 is what shipped; churning it would buy nothing.
      final pull = subSession.declarePullSubscriber(ke);
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Exercised against the drop-oldest boundary: 10 samples is far inside
      // 256, so a ring at the default must retain ALL of them. A default
      // that had quietly become small would lose the early ones.
      const n = 10;
      for (var i = 0; i < n; i++) {
        pubSession.put(ke, 'm$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));

      final got = <String>[];
      while (true) {
        if (pull.tryRecv() case RecvData(:final value)) {
          got.add(value.payload);
        } else {
          break;
        }
      }
      expect(got, equals([for (var i = 0; i < n; i++) 'm$i']));
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  // ---------------------------------------------------------------------
  // Slice 7: fidelity on the NEW fifo value path.
  //
  // Structural parity is necessary and not sufficient: a wrapper can match
  // the signature and still alter the value. This seed opens one wholly new
  // path (wire -> fifo channel -> tryRecv -> Dart), so it gets the full
  // round-trip treatment over the CONTRACT'S data domain rather than over
  // the data a typical consumer happens to send -- binary, invalid UTF-8,
  // empty, absent.
  //
  // ⚠️ WHAT THE SHARED EXTRACTION BUYS, and what it does not. Both kinds run
  // the ONE `zd_pull_subscriber_try_recv` body: only the loan and the
  // try_recv call are kind-dispatched. So these legs exercise structurally
  // the same code the ring cells already cover, and they are driven through
  // fifo anyway -- because "structurally the same" is an argument, and the
  // seed's floor asks for a measurement.
  // ---------------------------------------------------------------------
  group('fifo value-path fidelity (TCP 19310)', () {
    late Session pubSession;
    late Session subSession;

    setUpAll(() async {
      // Timestamping ON for this group, so the QoS/timestamp parity cell
      // below compares a REAL timestamp. Without it both sides report null
      // and `null == null` would pass while proving nothing about how a
      // timestamp is rendered per kind.
      (pubSession, subSession) = await sessionPair(19310, timestamping: true);
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    Future<Sample> receiveOne(String ke, void Function() publish) async {
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      publish();
      final sample = await pollRecv(pull);
      expect(sample, isNotNull, reason: 'the fifo must deliver one sample');
      return sample!;
    }

    test('an invalid-UTF-8 payload survives byte-exact through fifo', () async {
      const ke = 'zenoh/dart/test/chan/fid/binary';
      // Not decodable as UTF-8 by construction: a lone 0x80 continuation
      // byte, a 0xFE that is not a legal lead byte at all, and an interior
      // NUL. A UTF-8-validating extractor anywhere on this path empties or
      // mangles it.
      final binary = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final sample = await receiveOne(
        ke,
        () => pubSession.putBytes(ke, ZBytes.fromUint8List(binary)),
      );

      expect(sample.payloadBytes, equals(binary));
      // The DISPLAY string is lenient, never a throw: invalid sequences
      // become U+FFFD, and payloadBytes stays the exact ground truth.
      expect(sample.payload, contains('\u{FFFD}'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('an empty payload is empty, not absent', () async {
      const ke = 'zenoh/dart/test/chan/fid/empty-payload';
      final sample = await receiveOne(
        ke,
        () => pubSession.putBytes(ke, ZBytes.fromUint8List(Uint8List(0))),
      );

      // Zero-length is a VALUE. Rendering it as absent would be the same
      // NULL-vs-empty conflation the attachment path already fixed.
      expect(sample.payloadBytes, isNotNull);
      expect(sample.payloadBytes, hasLength(0));
      expect(sample.payload, equals(''));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('attachment empty-vs-absent is distinguished through fifo', () async {
      const keEmpty = 'zenoh/dart/test/chan/fid/att-empty';
      const keAbsent = 'zenoh/dart/test/chan/fid/att-absent';

      final withEmpty = await receiveOne(keEmpty, () {
        pubSession.declarePublisher(keEmpty)
          ..putBytes(
            ZBytes.fromString('p'),
            attachment: ZBytes.fromUint8List(Uint8List(0)),
          )
          ..close();
      });
      // Present but zero-length.
      expect(withEmpty.attachmentBytes, isNotNull);
      expect(withEmpty.attachmentBytes, hasLength(0));

      final withNone = await receiveOne(keAbsent, () {
        pubSession.declarePublisher(keAbsent)
          ..putBytes(ZBytes.fromString('p'))
          ..close();
      });
      // No attachment argument at all -- genuinely absent.
      expect(withNone.attachmentBytes, isNull);
      expect(withNone.attachment, isNull);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('both sample kinds arrive through fifo', () async {
      const ke = 'zenoh/dart/test/chan/fid/kinds';
      final pull = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      pubSession
        ..put(ke, 'alive')
        ..deleteResource(ke);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // A fifo is lossless and ordered, so both arrive and in this order --
      // which is also why this cell can assert the DELETE at all: on a
      // capacity-1 ring the PUT would have been dropped to make room.
      final first = pull.tryRecv();
      expect(first, isA<RecvData<Sample>>());
      expect((first as RecvData<Sample>).value.kind, equals(SampleKind.put));

      final second = pull.tryRecv();
      expect(second, isA<RecvData<Sample>>());
      expect(
        (second as RecvData<Sample>).value.kind,
        equals(SampleKind.delete),
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('the encoding value arrives through fifo', () async {
      const ke = 'zenoh/dart/test/chan/fid/encoding';
      final sample = await receiveOne(ke, () {
        pubSession.declarePublisher(ke)
          ..put('{}', encoding: Encoding.applicationJson)
          ..close();
      });

      expect(sample.encoding, equals(Encoding.applicationJson.mimeType));
    }, timeout: const Timeout(Duration(seconds: 40)));

    // ---------------------------------------------------------------
    // Slice 8: the D-7 encoding-render alignment.
    //
    // The pull path used to render a ZERO-LENGTH encoding as `null`
    // (absent) while the subscriber callback path rendered it as `''`
    // (present but empty) -- the same wire sample yielding two different
    // Dart values depending on which receive surface you used. The shim
    // branch now allocates unconditionally, exactly as the callback path
    // does, so both surfaces agree.
    //
    // ⚠️ THE VERIFICATION CLASS IS STRUCTURAL, and this comment is the
    // honest statement of it. The enc_len == 0 cell is UNREACHABLE from
    // our public API -- it needs a wire peer sending an
    // id-0xFFFF-no-schema encoding -- so no executable Dart test can
    // drive it. The evidence is branch-level identity with the callback
    // path, read at source. What IS executable, and is asserted below, is
    // that the change did not disturb the reachable case.
    // ---------------------------------------------------------------
    test('a present non-empty encoding is unchanged on both kinds', () async {
      const ke = 'zenoh/dart/test/chan/fid/enc-both';
      final fifo = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(fifo.close);
      final ring = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(ring.close);

      final publisher = pubSession.declarePublisher(ke);
      addTearDown(publisher.close);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      publisher.put('{}', encoding: Encoding.applicationJson);

      final viaFifo = await pollRecv(fifo);
      final viaRing = await pollRecv(ring);
      expect(viaFifo, isNotNull);
      expect(viaRing, isNotNull);

      // Identical to each other AND to what HEAD reported before the
      // alignment -- the unconditional malloc must not have changed the
      // reachable, non-empty case.
      expect(viaFifo!.encoding, equals(Encoding.applicationJson.mimeType));
      expect(viaRing!.encoding, equals(viaFifo.encoding));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('QoS and timestamp match the ring path', () async {
      const ke = 'zenoh/dart/test/chan/fid/qos';
      // ONE publication, TWO subscribers of different kinds. Comparing the
      // two renderings of the SAME wire sample is what makes this a parity
      // assertion rather than two independent observations that happen to
      // agree.
      final fifo = subSession.declarePullSubscriber(
        ke,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(fifo.close);
      final ring = subSession.declarePullSubscriber(ke, capacity: 4);
      addTearDown(ring.close);

      final publisher = pubSession.declarePublisher(
        ke,
        priority: Priority.realTime,
        congestionControl: CongestionControl.block,
        isExpress: true,
      );
      addTearDown(publisher.close);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      publisher.put('qos payload');

      final viaFifo = await pollRecv(fifo);
      final viaRing = await pollRecv(ring);
      expect(viaFifo, isNotNull);
      expect(viaRing, isNotNull);

      expect(viaFifo!.priority, equals(viaRing!.priority));
      expect(viaFifo.congestionControl, equals(viaRing.congestionControl));
      expect(viaFifo.express, equals(viaRing.express));

      // The timestamp leg needs its own guard against vacuity: with
      // timestamping off BOTH sides report null and `null == null` passes
      // while proving nothing. Assert one is actually present first.
      expect(
        viaFifo.timestamp,
        isNotNull,
        reason:
            'timestamping is enabled on the publisher session, so a '
            'null here means the parity assertion below is vacuous',
      );
      expect(
        viaFifo.timestamp?.toString(),
        equals(viaRing.timestamp?.toString()),
      );

      // ...and they agree with what was actually published, so "they match"
      // cannot be satisfied by both being wrong in the same way.
      expect(viaFifo.priority, equals(Priority.realTime));
      expect(viaFifo.congestionControl, equals(CongestionControl.block));
      expect(viaFifo.express, isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}

/// Orders `mN` payload labels numerically, so an "is this a suffix, in order?"
/// assertion cannot be satisfied by lexicographic luck (m10 < m2 as strings).
int _byIndex(String a, String b) =>
    int.parse(a.substring(1)).compareTo(int.parse(b.substring(1)));
