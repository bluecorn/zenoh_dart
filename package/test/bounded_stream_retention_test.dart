import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Seed `[DM-bounded-stream]`, criterion **E**: the bounded query variant
/// bounds NATIVE memory, not only Dart memory.
///
/// Every buffered query is a `z_owned_query_t` **clone** held on the native
/// side until it is disposed. `src/zenoh_dart.c:1774` clones exactly one per
/// push callback; `:2196` heap-wraps exactly one per successful `try_recv`,
/// and *"Nothing is allocated on a non-OK recv."*
///
/// ## The instrument — and the two that are UNFIT
///
/// Both plausible alternatives are engaged and DECLINED here, so that nobody
/// rediscovers the dead ends:
///
/// - **The shim's own alloc counter is blind to this block.** It defaults
///   `ZD_COUNT_CALLER` to `libzenoh_dart.so`, and the clone is a **zenoh-c**
///   block — so the counter filters out, by caller, the very allocation the
///   criterion is about.
/// - **Distinct-address counting sees leaks, not constructions.** That is the
///   right instrument for `verification.md` §3a's ownership question ("was
///   this block ever released?") and the wrong one for this question:
///   criterion E asks how many blocks are alive **at once**, and a perfectly
///   leak-free binding can still hold 64 of them simultaneously.
///
/// What this file counts instead is **live constructions, one-to-one**: the
/// number of queries a paused consumer can still take out and reply to **is**
/// the number of clones it retained. Exact, at the real size class, and not a
/// byte proxy.
///
/// ⚠️ Two sessions over TCP loopback throughout. Multicast and gossip are
/// OFF: a test that inherits the LAN is testing the LAN.
void main() {
  /// Opens a listener/connector pair on [port] and returns (getter, queryable)
  /// sessions.
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final getSession = await Session.open(config: listener);

    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final qblSession = await Session.open(config: connector);

    await Future<void>.delayed(const Duration(seconds: 1));
    return (getSession, qblSession);
  }

  group('Criterion E: retained native clones (TCP 19595)', () {
    late Session getSession;
    late Session qblSession;

    setUpAll(() async {
      (getSession, qblSession) = await sessionPair(19595);
    });

    tearDownAll(() {
      getSession.close();
      qblSession.close();
    });

    // Volume, capacity and window are stated once, here, and used by BOTH
    // arms, so the two counts are taken under identical conditions: 64 gets,
    // ring capacity 8, a ~2 s paused window, a 30 s getter timeout.
    const gets = 64;
    const capacity = 8;
    const pausedWindow = Duration(seconds: 2);
    const getterTimeout = Duration(seconds: 30);

    /// The body of one arm. Kept separate so `runArm` below is nothing but
    /// the `try/finally` that guarantees the handle is closed.
    Future<
      ({
        int delivered,
        int completedDuringWindow,
        List<Duration> windowCompletions,
        int gettersWithReply,
      })
    >
    runArmBody(String ke, Stream<Query> stream) async {
      // Settle time for the declaration to reach the getter session.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final queries = <Query>[];
      // PAUSED SYNCHRONOUSLY WITH THE LISTEN, before any traffic exists, so no
      // arrival can be consumed before the pause takes effect. The paused
      // consumer is the whole instrument: it is what forces the binding to
      // hold whatever it is going to hold.
      final sub = stream.listen(queries.add)..pause();

      final completions = <Duration>[];
      final fired = <(Future<void>, List<Reply>)>[];
      for (var i = 0; i < gets; i++) {
        final replies = <Reply>[];
        final sw = Stopwatch()..start();
        final done = getSession
            .get(
              ke,
              timeout: getterTimeout,
              consolidation: ConsolidationMode.none,
            )
            .listen(replies.add)
            .asFuture<void>()
            .then((_) => completions.add(sw.elapsed));
        fired.add((done, replies));
      }

      // ⚠️ THE PAUSED WINDOW IS DELIBERATELY SHORT (~2 s) AGAINST A LONG
      // (30 s) GETTER TIMEOUT. A long window lets queries age out, and the
      // count then measures the TIMEOUT rather than the retention -- an
      // earlier pass on this unit read `delivered=0` for exactly that reason.
      // Short window, long timeout: what is still deliverable at resume is
      // what was retained, not what happened to survive.
      await Future<void>.delayed(pausedWindow);
      final completedDuringWindow = completions.length;
      final windowCompletions = List<Duration>.of(completions);

      sub.resume();

      // Deadline-bounded drain: stop once the delivered count has been still
      // for `quiet`, or when `budget` expires. Never an unbounded wait -- a
      // broken implementation goes red on the counts below, it does not hang.
      const quiet = Duration(milliseconds: 1500);
      const budget = Duration(seconds: 20);
      final drainDeadline = DateTime.now().add(budget);
      var last = queries.length;
      var lastChange = DateTime.now();
      while (DateTime.now().isBefore(drainDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final now = queries.length;
        if (now != last) {
          last = now;
          lastChange = DateTime.now();
        } else if (DateTime.now().difference(lastChange) >= quiet) {
          break;
        }
      }
      final delivered = queries.length;

      // EVERY query taken is replied to and disposed. An undisposed query
      // holds its native clone open and would distort the other arm.
      for (final q in queries) {
        q
          ..reply(ke, 'r')
          ..dispose();
      }
      await sub.cancel();

      await Future.wait([for (final (done, _) in fired) done])
          .timeout(const Duration(seconds: 45));

      return (
        delivered: delivered,
        completedDuringWindow: completedDuringWindow,
        windowCompletions: windowCompletions,
        gettersWithReply: fired.where((f) => f.$2.any((r) => r.isOk)).length,
      );
    }

    /// Runs one arm of the comparison against [stream] on [ke], then [close]s
    /// the handle behind it.
    ///
    /// Fires [gets] gets over a paused window, resumes, drains against a
    /// deadline, and replies to and disposes every [Query] it takes. The two
    /// arms share this body so that the two counts are taken by one
    /// instrument, not by two that can drift apart.
    ///
    /// [close] runs in a `finally`: an arm that fails an assertion must still
    /// not strand a declared queryable holding native clones into the next.
    Future<
      ({
        int delivered,
        int completedDuringWindow,
        List<Duration> windowCompletions,
        int gettersWithReply,
      })
    >
    runArm(
      String ke,
      Stream<Query> stream,
      void Function() close,
    ) async {
      try {
        return await runArmBody(ke, stream);
      } finally {
        close();
      }
    }

    test('the bounded query stream retains at most capacity + 1 clones where '
        'the shipped push queryable retains all -- and the evicted clones are '
        'released', () async {
      // -- arm 1: the bounded variant ------------------------------------
      const boundedKe = 'zenoh/dart/test/bsretain/bounded';
      final qbl = qblSession.declarePullQueryable(
        boundedKe,
        kind: ChannelKind.ring,
        capacity: capacity,
      );
      final bounded = await runArm(boundedKe, qbl.stream, qbl.close);

      // -- arm 2: the shipped push queryable, THE SAME UNMODIFIED BUILD ---
      // This is what makes the number mean something: not a figure remembered
      // from another tree, but the defective arm compiled, linked and run in
      // the same process, seconds apart, over the same two sessions.
      const pushKe = 'zenoh/dart/test/bsretain/push';
      final push = qblSession.declareQueryable(pushKe);
      final pushed = await runArm(pushKe, push.stream, push.close);

      // ⭐ MEASURED, three consecutive runs identical (one through this cell,
      // two through a throwaway probe):
      //
      //   bounded: delivered=8  completedDuringWindow=56  gettersWithReply=8
      //   push:    delivered=64 completedDuringWindow=0   gettersWithReply=64
      //
      // 8 versus 64 -- an 8x separation in LIVE `z_owned_query_t` clones, from
      // one build, at one volume, minutes apart.
      //
      // ⚠️ AND THE POINT ESTIMATE IN THE PLAN IS NOT WHAT THE MACHINE SAYS.
      // `DemandGate`'s own dartdoc pins the retained bound at "`capacity + 1`,
      // always" (a full channel plus the one-slot stash). At this volume the
      // measurement is 8, not 9, and the stash IS occupied -- checked directly
      // via `stashHeldForTesting`, true at resume in every probe run. Swept
      // against capacity 8, ring, same topology:
      //
      //   n=5  -> delivered=5   (nothing lost)
      //   n=9  -> delivered=9   (== capacity + 1, the full bound)
      //   n=10 -> delivered=9   (1 evicted)
      //   n=20 -> delivered=8   (12 evicted)
      //   n=64 -> delivered=8   (56 evicted)
      //
      // So `capacity + 1` is an upper bound that is reached at the boundary
      // and sits one short of it under sustained overflow -- canon's ring
      // makes room before it inserts, and a burst of concurrent producers
      // leaves it one short. **The band is the honest claim; the point
      // estimate is not**, which is why both sides are asserted below rather
      // than an equality. Nothing here is lost that the bound promised: the
      // criterion is "at most", and 8 <= 9.
      expect(
        bounded.delivered,
        greaterThanOrEqualTo(1),
        reason:
            'BOUNDED ON BOTH SIDES: an arm that delivers nothing is a '
            'broken topology reading as bounded memory, not bounded memory; '
            'got ${bounded.delivered}',
      );
      expect(
        bounded.delivered,
        lessThanOrEqualTo(capacity + 1),
        reason:
            'the ring holds at most $capacity and the demand gate stashes '
            'one, so at most ${capacity + 1} clones can survive the paused '
            'window; got ${bounded.delivered}',
      );
      expect(
        pushed.delivered,
        greaterThanOrEqualTo(32),
        reason:
            'the shipped push queryable retains every arrival, so its '
            'lower bound is what excludes a dead topology; got '
            '${pushed.delivered} of $gets',
      );
      expect(
        pushed.delivered,
        greaterThanOrEqualTo(4 * bounded.delivered),
        reason:
            'the separation IS the criterion; bounded='
            '${bounded.delivered} push=${pushed.delivered}',
      );
      expect(
        bounded.gettersWithReply,
        equals(bounded.delivered),
        reason:
            'one reply per retained clone and no others -- the count is '
            'one-to-one, which is what makes it a clone count rather than a '
            'proxy; delivered=${bounded.delivered} '
            'replied=${bounded.gettersWithReply}',
      );

      // ── THE RELEASE HALF ────────────────────────────────────────────────
      //
      // The count above is the BINDING's retention. This takes it through to
      // CANON's release: `ResponseFinal` is sent only when the Rust `Query` is
      // dropped, so a getter whose query the ring evicted finalises promptly
      // -- with no reply, because nobody ever saw it.
      //
      // ⭐ BRANCH **(α)** IS WHAT THE MACHINE SHOWED, and it is asserted here
      // because it is what ran, not because it was aimed at. Verbatim, from
      // the run that produced the numbers above:
      //
      //   bounded: 56 of 64 getters completed DURING the 2 s paused window
      //            elapsed, sorted, first five: [2, 2, 2, 2, 2] ms
      //                              last five: [4, 2, 2, 2, 2] ms
      //
      // 2-4 ms, against a 30 s timeout -- four orders of magnitude clear of
      // branch (β), so the discriminator is not a close call. It also agrees
      // with the two independent pins on the same observable: ~20 ms in
      // `fifo_close_window_test.dart` and 24 ms in the sibling
      // `bounded_stream_query_test.dart`. Same neighbourhood, third
      // instrument.
      //
      // Criterion E is therefore discharged THROUGH TO CANON'S RELEASE: the
      // clones the bounded arm did not retain were not merely uncounted, they
      // were released, and the requester saw it happen.
      expect(
        bounded.windowCompletions,
        isNotEmpty,
        reason:
            'branch (beta) would leave this empty: every evicted getter '
            'waiting out its 30 s timeout instead of being finalised',
      );
      expect(
        bounded.completedDuringWindow,
        equals(gets - bounded.delivered),
        reason:
            'branch (alpha): EVERY getter whose query the ring evicted '
            'finalises inside the paused window -- ${bounded.delivered} '
            'retained, so ${gets - bounded.delivered} evicted, and '
            '${bounded.completedDuringWindow} completed',
      );
      expect(
        bounded.windowCompletions.reduce((a, b) => a > b ? a : b),
        lessThan(const Duration(seconds: 1)),
        reason:
            'branch (alpha) versus (beta) is prompt finalisation versus a '
            'full 30 s timeout; slowest was '
            '${bounded.windowCompletions.reduce((a, b) => a > b ? a : b)}',
      );
      expect(
        pushed.completedDuringWindow,
        isZero,
        reason:
            'the mirror image, from the defective arm: the push queryable '
            'releases NOTHING during the window because it retains '
            'everything, so not one of its $gets getters finalises early; got '
            '${pushed.completedDuringWindow}',
      );
    }, timeout: const Timeout(Duration(seconds: 300)));

    // ────────────────────────────────────────────────────────────────────────
    // Test 33 — the instrument's reach, stated rather than overclaimed
    // **[inspection]** — deliberately NOT an executable cell.
    //
    // WHAT THE COUNT COVERS. `delivered` counts the clones that were still
    // alive and reachable at resume: the ones held in canon's ring channel,
    // the one held in the demand gate's one-slot stash, and the Dart `Query`
    // wrappers that carry their heap addresses. It is one-to-one with the
    // shim's own allocation sites (`:1774` clone per push callback, `:2196`
    // heap wrapper per OK `try_recv`, nothing on a non-OK recv), which is why
    // it is a count of native constructions and not a byte proxy for one.
    //
    // WHAT THE RELEASE HALF ESTABLISHED. Under branch (α), measured above, the
    // 56 evicted clones were not merely absent from our count -- canon dropped
    // the Rust `Query` behind each of them, and each requester observed the
    // resulting `ResponseFinal` within 2-4 ms. So the criterion reaches past
    // "the binding holds fewer" to "the ones it does not hold are released".
    //
    // WHAT IT SAYS NOTHING ABOUT. It says nothing about canon's OPAQUE
    // INTERIORS. A `z_owned_query_t` is a handle; whatever it points into --
    // the Rust `Query`, its payload, its attachment, its routing state -- is
    // invisible from here. Sixty-four handles versus eight is a statement
    // about handles. That the interiors scale with them is an inference from
    // canon's ownership model, not something this leg measured.
    //
    // AND: **NO `MALLOC_PERTURB_` RUN WAS MADE.** Every query this file takes
    // is replied to and disposed, but a use-after-free on a block that was
    // freed and then never touched is silent on a normal allocator -- it reads
    // as correct behaviour. Nothing in this leg excludes that class. It would
    // take a `MALLOC_PERTURB_` run (`verification.md`'s instrument for exactly
    // this), and none was made here.
    // ────────────────────────────────────────────────────────────────────────
  });
}
