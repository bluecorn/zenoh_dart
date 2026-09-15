import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

/// Seed `[DM-bounded-stream]`: the demand-gated `Stream` on the QUERY column.
///
/// This is the column where the bound costs native memory rather than only
/// Dart memory. Every buffered query is a `z_owned_query_t` **clone** held on
/// the native side until it is disposed, so a slow consumer on the shipped
/// push queryable grows both the Dart queue and native memory.
///
/// It is also the column where the cancel contract has a price. On the sample
/// column a stashed `Sample` that nobody retrieves costs nothing — a `Sample`
/// holds no native resource. Here it costs a **reply**: the requester's getter
/// sits waiting out its own timeout while a clone the consumer will never see
/// is held open. So the stash's two exits are both driven here —
/// **retrieved through the handle** (cells 28) and **released at `close()`**
/// (cells 27 and 29) — and cell 27 carries the injected calibration that
/// proves the release leg is doing the work.
///
/// ⚠️ Every fifo cell uses TWO SESSIONS over TCP loopback. That is a hard
/// bound rather than a preference: a same-session publish into a full fifo
/// blocks the caller permanently inside a synchronous FFI call.
void main() {
  /// Opens a listener/connector pair on [port] and returns (getter, queryable)
  /// sessions. Multicast and gossip are OFF: a test that inherits the LAN is
  /// testing the LAN.
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

  group('The query column through the demand gate (TCP 19594)', () {
    late Session getSession;
    late Session qblSession;

    setUpAll(() async {
      (getSession, qblSession) = await sessionPair(19594);
    });

    tearDownAll(() {
      getSession.close();
      qblSession.close();
    });

    /// Fires one get and returns (its completion future, its replies, its
    /// stopwatch).
    ///
    /// The stopwatch starts at fire time, so the elapsed time on completion IS
    /// the observable: a query whose clone was dropped is finalized by canon's
    /// `ResponseFinal` promptly, while an orphaned one waits out [timeout].
    (Future<void>, List<Reply>, Stopwatch) fireGet(
      String ke, {
      Duration timeout = const Duration(seconds: 30),
    }) {
      final replies = <Reply>[];
      final sw = Stopwatch()..start();
      final done = getSession
          .get(ke, timeout: timeout, consolidation: ConsolidationMode.none)
          .listen(replies.add)
          .asFuture<void>();
      return (done, replies, sw);
    }

    test('the query stream delivers queries and they are repliable', () async {
      const ke = 'zenoh/dart/test/bsquery/basic';
      final qbl = qblSession.declarePullQueryable(
        ke,
        kind: ChannelKind.ring,
        capacity: 8,
      );
      addTearDown(qbl.close);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final queries = <Query>[];
      final sub = qbl.stream.listen(queries.add);
      addTearDown(sub.cancel);

      final fired = [for (var i = 0; i < 3; i++) fireGet(ke)];
      await waitUntil(
        () => queries.length >= 3,
        timeout: const Duration(seconds: 20),
        description:
            '3 queries through the bounded stream; '
            'saw ${queries.length}',
      );

      for (final q in queries) {
        q
          ..reply(ke, 'reply from the bounded query stream')
          ..dispose();
      }

      await Future.wait([for (final (done, _, _) in fired) done])
          .timeout(const Duration(seconds: 20));
      for (final (_, replies, _) in fired) {
        expect(
          replies.where((r) => r.isOk),
          isNotEmpty,
          reason: 'every getter must receive its reply',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a stashed query that is never delivered is DISPOSED at close(), not '
        'orphaned', () async {
      const ke = 'zenoh/dart/test/bsquery/stash-release';
      final qbl = qblSession.declarePullQueryable(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // Paused synchronously with the listen, so the pull started inside
      // `onListen` is still in flight and the arrival will be stashed.
      final sub = qbl.stream.listen((_) {})..pause();
      addTearDown(sub.cancel);
      expect(qbl.pullInFlightForTesting, isTrue);

      final (done, replies, sw) = fireGet(ke);

      // ⚠️ THE STATE IS ESTABLISHED BY THE OBSERVABLES, NOT BY A CONSUMING
      // PEEK. Under the stash-first accessor a `tryRecv()` here would take the
      // very query this cell is about, and the cell would then be measuring
      // its own probe.
      await waitUntil(
        () => qbl.stashHeldForTesting,
        timeout: const Duration(seconds: 20),
        description: 'the query to complete the in-flight pull and be stashed',
      );
      expect(qbl.pullInFlightForTesting, isFalse);

      qbl.close();

      // ⚠️ INJECTED CALIBRATION, BOTH WAYS, run before this cell was accepted
      // and RESTORED afterwards (`grep -c INJECTED` = 0). The injection is
      // `DemandGate.close()`'s `_release(stashed)` disabled -- the stash is
      // still taken, so the Query is dropped WITHOUT `dispose()` and its
      // native clone is never released. A temporary local edit, NEVER
      // committed. Measured:
      //
      //   release REMOVED  -> still waiting at 25000 ms (the cell's own bound;
      //                       the getter was heading for its 30 s timeout)
      //   release SHIPPED  -> 24 ms
      //
      // ~1000x, TOTAL SEPARATION. That is what makes this leg evidence rather
      // than decoration: a resource defect is invisible to a behavioural
      // assertion -- every lifecycle assertion here passes identically on
      // leaking and on fixed code -- so a leg that reads the same either way
      // is worth nothing while looking like proof.
      //
      // The 24 ms also agrees with the independently pinned getter observable
      // for a query dropped at close(), `fifo_close_window_test.dart` (~20
      // ms), which is a second instrument reaching the same number.
      await done.timeout(
        const Duration(seconds: 25),
        onTimeout: () => fail(
          'the getter never completed: the stashed query was orphaned rather '
          'than disposed at close()',
        ),
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'dropping the query sends canon ResponseFinal, so the getter '
            'finalizes promptly rather than waiting out its 30 s timeout '
            '(took ${sw.elapsedMilliseconds}ms)',
      );
      expect(
        replies.where((r) => r.isOk),
        isEmpty,
        reason: 'nothing ever replied to it',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('cancel-while-stashed loses nothing -- the query comes back through '
        'the handle and is still repliable', () async {
      const ke = 'zenoh/dart/test/bsquery/cancel-retrieve';
      final qbl = qblSession.declarePullQueryable(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(qbl.close);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final sub = qbl.stream.listen((_) {})..pause();
      expect(qbl.pullInFlightForTesting, isTrue);

      final (done, replies, _) = fireGet(ke);
      await waitUntil(
        () => qbl.stashHeldForTesting,
        timeout: const Duration(seconds: 20),
        description: 'the query to be stashed',
      );

      // ⚠️ THE QUERY IS *NOT* DISPOSED AT CANCEL, and that is a deliberate
      // departure from the alternative of releasing it here. Remedy (ii)
      // makes the HANDLE the owner, so cancel is not a release point;
      // disposing here would reintroduce exactly the loss the remedy exists
      // to fix -- on this column, a reply the requester never gets.
      await sub.cancel();
      expect(
        qbl.stashHeldForTesting,
        isTrue,
        reason: 'cancel must not release the stash',
      );

      final taken = qbl.tryRecv();
      expect(
        taken,
        isA<RecvData<Query>>(),
        reason: 'the stash-first accessor hands the orphaned query back',
      );
      (taken as RecvData<Query>).value
        ..reply(ke, 'replied after cancel, from the stash')
        ..dispose();

      await done.timeout(const Duration(seconds: 25));
      expect(
        replies.where((r) => r.isOk),
        isNotEmpty,
        reason:
            'a query retrieved through the handle after cancel is still '
            'repliable, and its getter still gets the reply',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('cancel-while-stashed, never retrieved -- the remedy does not trade a '
        'loss for a leak', () async {
      const ke = 'zenoh/dart/test/bsquery/cancel-release';
      final qbl = qblSession.declarePullQueryable(
        ke,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final sub = qbl.stream.listen((_) {})..pause();
      expect(qbl.pullInFlightForTesting, isTrue);

      final (done, replies, sw) = fireGet(ke);
      await waitUntil(
        () => qbl.stashHeldForTesting,
        timeout: const Duration(seconds: 20),
        description: 'the query to be stashed',
      );
      await sub.cancel();
      expect(qbl.stashHeldForTesting, isTrue);

      // Never retrieved through the handle -- so the SECOND exit has to fire,
      // or the clone is simply leaked and the getter hangs to its timeout.
      //
      // Under the SAME injection as the cell above (the stash release
      // disabled), this cell also went red: still waiting at 25000 ms, against
      // 22 ms shipped. Both of the stash's exits are therefore calibrated,
      // not just the one.
      qbl.close();

      await done.timeout(
        const Duration(seconds: 25),
        onTimeout: () => fail(
          'the getter never completed: a stash held across cancel was neither '
          'retrievable nor released',
        ),
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'close() must dispose a stash held across cancel '
            '(took ${sw.elapsedMilliseconds}ms)',
      );
      expect(replies.where((r) => r.isOk), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      /// Fires [n] gets at a capacity-0 handle and reports what the bounded
      /// stream delivered within a bounded window.
      ///
      /// Shared by the two capacity-0 cells, which differ only in `kind` and
      /// in the branch they pin.
      Future<int> capacityZeroRun(String ke, ChannelKind kind) async {
        final qbl = qblSession.declarePullQueryable(
          ke,
          kind: kind,
          capacity: 0,
        );
        addTearDown(qbl.close);
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final queries = <Query>[];
        final sub = qbl.stream.listen(queries.add);
        addTearDown(sub.cancel);

        // 4 gets, listening and UNPAUSED throughout, so anything not
        // delivered is starvation rather than absent demand.
        final fired = [
          for (var i = 0; i < 4; i++)
            fireGet(ke, timeout: const Duration(seconds: 4)),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        final delivered = queries.length;

        for (final q in queries) {
          q
            ..reply(ke, 'r')
            ..dispose();
        }
        await Future.wait([for (final (done, _, _) in fired) done])
            .timeout(const Duration(seconds: 20));
        return delivered;
      }

      test('capacity 0 fifo on the query column: pinned as measured', () async {
        final delivered = await capacityZeroRun(
          'zenoh/dart/test/bsquery/cap0-fifo',
          ChannelKind.fifo,
        );
        // ⭐ PINNED AS MEASURED, ON THIS COLUMN AND THIS KIND, and nowhere
        // else. Branch **(α)**: the bounded Stream delivers NOTHING at
        // capacity 0 on a fifo. Observed verbatim, four gets fired:
        //
        //   delivered=0 of 4
        //
        // ⚠️ AND THIS IS NOT THE SHIPPED DARTDOC'S PICTURE -- WITHOUT
        // CONTRADICTING IT. `Session.declarePullQueryable`'s own dartdoc says
        // that at capacity 0 *"both kinds hand a query over UNDER POLLING and
        // the getter gets its reply"*, because across two sessions the getter
        // is never the blocked party on this column. That statement is about
        // `tryRecv`, and it remains true. The bounded Stream does not poll --
        // it drives `recv()`, and `recv()` is the one accessor a capacity-0
        // fifo cannot serve on EITHER column: the rendezvous is full when it
        // is empty, so the delivery waits for a concurrent consumer while the
        // only consumer that could be one is parked inside `recv()`.
        //
        // So the axis is the ACCESSOR, not the column -- which is why this is
        // pinned per column and per kind by measurement rather than reasoned
        // across from the polling result. Carrying a measurement past the
        // conditions it was taken under is how a correct number becomes a
        // false claim.
        expect(
          delivered,
          isZero,
          reason:
              'branch (alpha): a capacity-0 fifo starves the bounded '
              'Stream on the query column too, because the Stream drives '
              'recv(); got $delivered',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));

      test('capacity 0 ring on the query column: pinned as measured', () async {
        final delivered = await capacityZeroRun(
          'zenoh/dart/test/bsquery/cap0-ring',
          ChannelKind.ring,
        );
        // ⭐ PINNED AS MEASURED. Branch **(β)**: the bounded Stream DOES
        // deliver at capacity 0 on a ring. Observed verbatim, four gets
        // fired:
        //
        //   delivered=1 of 4
        //
        // The contrast with the fifo cell above is the whole content of the
        // pair: same column, same accessor, same volume, opposite outcome --
        // so the capacity-0 restriction really does travel with `kind`, and
        // the sample column's own capacity-0 ring result is NOT what is being
        // relied on here. Pinned for this column and this kind only.
        //
        // The assertion is "delivers at least one" rather than the exact 1:
        // how many of a four-get burst a rendezvous-sized ring passes before
        // evicting is a timing artefact, and pinning it would pin the machine
        // rather than the contract.
        expect(
          delivered,
          greaterThanOrEqualTo(1),
          reason:
              'branch (beta): a capacity-0 ring delivers on the query '
              'column; got $delivered',
        );
      }, timeout: const Timeout(Duration(seconds: 120)));
    });
  });
}
