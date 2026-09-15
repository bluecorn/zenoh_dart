// Seed [MICRO-fifo-close] slice 4 -- MEASUREMENT: what the reorder's window
// actually does to an undelivered query.
//
// THE QUESTION. After the reorder, canon's closure is still live between the
// handler drop and the undeclare's return, so a query can be pushed into a
// DROPPED receiver in that window. Where does it go, and what does its getter
// see? That is a correctness question, not a tidiness one -- un-recv'd queries
// live in the native channel and were released by the handler drop, which
// after the reorder no longer sees the final set.
//
// THE HOUSE FORM FOR AN OPEN DESIGN QUESTION IS A MEASUREMENT CELL THAT PINS
// THE OBSERVED BEHAVIOUR, NOT AN ARGUMENT. A candidate mechanism was offered
// for this plan to VERIFY rather than adopt: that a query arriving in the
// window fails its flume send, is dropped, and `QueryInner::drop` sends
// `ResponseFinal` to the getter -- so the getter observes "a prompt completion
// with no reply, the same observable as a ring drop." Those two halves
// contradict each other in this tree, and the cells below settle it by
// measuring rather than by citing.
//
// PROCESS TOPOLOGY -- split across processes, deliberately and asymmetrically:
//
//   CHILD  owns the queryable session and nothing else. It declares the
//          PullQueryable, prints HARNESS_READY and AWAITING_CLOSE_CMD, and
//          then does nothing at all until CLOSE arrives on stdin. It never
//          recv's, never replies, and produces no getter traffic.
//   PARENT (this test process) owns the getter session and EVERY measurement.
//          That is what makes the healthy-parent justification true rather
//          than assumed: the parent never calls the deadlocking close(), so
//          its event loop runs and its `Future.timeout` genuinely works. The
//          child is the one calling close(), and the parent bounds it at the
//          OS level.
//
// The trigger is stdin, not a clock (proven deterministic by slice 1's third
// cell), so "the queries were pending when the close happened" is a SEQUENCED
// FACT rather than a timing hope, and no cross-process clock comparison is
// needed. No getter datum crosses stdout: elapsed, reply counts and the
// Timeout flag are all parent-side values read from the parent's own
// subscriptions.
//
// PORT: 19583 only. Keyexprs ASCII.
import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/bounded_subprocess.dart';

const _harness = 'test/helpers/fifo_close_harness.dart';
const _perturbHarness = 'test/helpers/fifo_close_window_perturb_harness.dart';

// The child derives its key from its column, so the parent must use the same
// string. Kept as one constant rather than two literals.
const _key = 'zenoh/dart/fifoclose/qbl';
const _getters = 10;
const _getterTimeout = Duration(seconds: 4);

/// One getter's measured outcome. Deliberately splits OK replies from error
/// replies: the two candidate branches differ in whether a `Timeout` ERROR
/// reply arrives, and both branches have zero OK replies -- so a single
/// "reply count" would not discriminate them.
class _GetterProfile {
  _GetterProfile(
    this.index,
    this.elapsedMs,
    this.okReplies,
    this.errorReplies, {
    required this.sawTimeoutError,
  });

  final int index;
  final int elapsedMs;
  final int okReplies;
  final int errorReplies;
  final bool sawTimeoutError;

  @override
  String toString() =>
      'get#$index  elapsed=${elapsedMs}ms  ok=$okReplies  '
      'err=$errorReplies  timeoutError=$sawTimeoutError';
}

/// (α) prompt, or (β) timeout, or a mixed profile (which would itself be the
/// finding).
String _classify(List<_GetterProfile> profiles) {
  if (profiles.isEmpty) return 'EMPTY';
  bool promptly(_GetterProfile p) =>
      !p.sawTimeoutError && p.elapsedMs < _getterTimeout.inMilliseconds ~/ 2;
  bool timedOut(_GetterProfile p) =>
      p.sawTimeoutError && p.elapsedMs >= _getterTimeout.inMilliseconds ~/ 2;
  if (profiles.every(promptly)) return 'alpha-prompt';
  if (profiles.every(timedOut)) return 'beta-timeout';
  return 'MIXED';
}

/// Fires [_getters] getters, returns their profiles once all have completed.
///
/// Every await carries an explicit deadline: the parent's isolate is healthy,
/// which is exactly why a bound here is meaningful rather than decorative.
Future<List<_GetterProfile>> _fireAndMeasure(
  Session getter,
  BoundedChild child,
) async {
  // The measured getters are only fired once a queryable demonstrably matches.
  await _awaitQueryableReachable(getter);

  final profiles = <_GetterProfile>[];
  final done = <Future<void>>[];

  for (var i = 0; i < _getters; i++) {
    final index = i;
    final sw = Stopwatch()..start();
    var ok = 0;
    var err = 0;
    var sawTimeout = false;
    done.add(
      getter
          .get(
            _key,
            timeout: _getterTimeout,
            consolidation: ConsolidationMode.none,
          )
          .listen((r) {
            if (r.isOk) {
              ok++;
            } else {
              err++;
              if (r.error.payload == 'Timeout') sawTimeout = true;
            }
          })
          .asFuture<void>()
          .then((_) {
            profiles.add(
              _GetterProfile(
                index,
                sw.elapsedMilliseconds,
                ok,
                err,
                sawTimeoutError: sawTimeout,
              ),
            );
          }),
    );
  }

  // Settle, not a race: the queries must reach the child and fill its
  // capacity-2 channel before the close. "A delivery is now parked" has no
  // observable -- being parked is precisely the state that emits nothing --
  // so there is nothing to poll for here.
  await Future<void>.delayed(const Duration(milliseconds: 800));

  child.send('CLOSE');

  await Future.wait(done).timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw StateError(
      'a getter never completed; ${profiles.length}/$_getters finished:\n'
      '${profiles.join('\n')}',
    ),
  );
  profiles.sort((a, b) => a.index.compareTo(b.index));
  return profiles;
}

/// Polls until a query fired at [_key] is demonstrably HELD by a matching
/// queryable, bounded.
///
/// ⚠️ THIS EXISTS BECAUSE ITS ABSENCE PRODUCED A VACUOUS MEASUREMENT.
/// `peersZid()` reporting a peer means the TRANSPORT linked; not that the
/// child's queryable declaration has propagated. Fired too early, every getter
/// finalized at elapsed=0 ms with nothing at all -- the signature of "no
/// queryable matched", which looks exactly like a prompt completion and would
/// have been recorded as one. Measured on the ring arm of the first run: ten
/// getters, all 0 ms.
///
/// The probe discriminates by TIME: a query with no matching queryable
/// finalizes immediately, while one held by a queryable that never answers
/// runs to its own timeout. So a probe that takes most of its timeout is proof
/// a queryable is reachable.
Future<void> _awaitQueryableReachable(Session getter) async {
  const probeTimeout = Duration(milliseconds: 600);
  final deadline = Stopwatch()..start();
  while (true) {
    final sw = Stopwatch()..start();
    await getter
        .get(_key, timeout: probeTimeout, consolidation: ConsolidationMode.none)
        .drain<void>()
        .timeout(const Duration(seconds: 5));
    if (sw.elapsedMilliseconds >= probeTimeout.inMilliseconds * 2 ~/ 3) return;
    if (deadline.elapsed > const Duration(seconds: 20)) {
      throw StateError(
        'no queryable ever became reachable at $_key: the probe kept '
        'finalizing in ${sw.elapsedMilliseconds}ms, which is the '
        'no-match signature',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Session> _openGetterSession() async {
  final getter = await Session.open(
    config: Config()
      ..insertJson5('mode', '"peer"')
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19583"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  final link = Stopwatch()..start();
  while (getter.peersZid().isEmpty) {
    if (link.elapsed > const Duration(seconds: 20)) {
      getter.close();
      throw StateError('the getter session never linked to the child');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return getter;
}

Future<BoundedChild> _startListener(String kind) async {
  final child = await startBoundedHarness(
    _harness,
    [
      '--role', 'listener',
      '--close-on', 'stdin',
      '--column', 'qbl',
      '--kind', kind,
      '--capacity', '2',
      '--port', '19583',
      // THE DISCRIMINATOR. The child holds its session OPEN for 6 s after
      // close() returns -- longer than the getters' own 4 s timeout. Without
      // it the child exits ~20 ms after the close, and a prompt getter
      // completion could equally be the session teardown rather than the
      // close. Measured: it IS the close (see the pin in the cell below).
      '--linger-ms', '6000',
    ],
  );
  await child.waitForMarker('HARNESS_READY', const Duration(seconds: 30));
  await child.waitForMarker('AWAITING_CLOSE_CMD', const Duration(seconds: 30));
  return child;
}

void main() {
  group('The reorder window (slice 4)', () {
    test('the getter observable for a query undelivered across close() is '
        'measured and pinned', () async {
      final child = await _startListener('fifo');
      addTearDown(child.dispose);
      final getter = await _openGetterSession();
      addTearDown(getter.close);

      final profiles = await _fireAndMeasure(getter, child);
      final outcome = await child.awaitExit(const Duration(seconds: 90));
      final branch = _classify(profiles);
      final table = profiles.join('\n');

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(
        outcome.markerValue('CLOSE_RETURNED_MS='),
        lessThan(5000),
        reason: outcome.diagnosis,
      );
      expect(
        profiles,
        hasLength(_getters),
        reason: 'every getter must complete; none may hang:\n$table',
      );
      expect(
        profiles.every((p) => p.okReplies == 0),
        isTrue,
        reason:
            'the child never replies, so no OK reply is possible:\n'
            '$table',
      );

      // ── THE PIN ───────────────────────────────────────────────────────────
      // MEASURED, verbatim, all ten getters. fifo capacity 2; the child holds
      // its session OPEN for 6 s after close() returns (--linger-ms 6000);
      // the getters' own timeout is 4 s; the stopwatches start at fire time
      // and CLOSE is sent at ~800 ms:
      //
      //   get#0  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#1  elapsed=819ms  ok=0  err=0  timeoutError=false
      //   get#2  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#3  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#4  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#5  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#6  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#7  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#8  elapsed=820ms  ok=0  err=0  timeoutError=false
      //   get#9  elapsed=820ms  ok=0  err=0  timeoutError=false
      //
      // BRANCH (α) PROMPT, uniformly across all ten. Every getter completes
      // ~20 ms after the close, with NO reply of any kind -- not a data reply
      // and not a Timeout error reply. The stream simply closes.
      //
      // ⚠️ ATTRIBUTION, and it is the whole reason --linger-ms exists. The
      // child stays alive for six further seconds, so the transport, the
      // session and the peer are all still up when these getters finalize.
      // The completion is therefore caused by the CLOSE, not by the session
      // teardown. WITHOUT the linger the child exited ~20 ms after close()
      // and the two were indistinguishable -- the first run of this cell
      // measured exactly that and could not have told them apart.
      //
      // ⭐ SO (α) IS CONFIRMED AND (β) IS REFUTED -- and that is the OPPOSITE
      // of the direction this plan's own §5 leaned. The plan carried a
      // finding that the candidate mechanism's "prompt completion" half was
      // contradicted by two citations. Measured through this binding, under
      // the conditions stated above, the candidate is right and the plan's
      // reading of those two citations was wrong:
      //
      //   - `session.dart:785` ("Remotely that is the dropped getter's
      //     timeout: it waited and got nothing") describes the RING drop, and
      //     the ring control below measures that claim directly -- it is also
      //     not what happens. That dartdoc is corrected in slice 7.
      //   - the CA2 probe README's "getters finalized without timeout: 0/50"
      //     was taken in ONE process, at 50 getters, with no linger. Its
      //     conditions are not these conditions, and a measurement cited
      //     without its conditions is a different claim. It is recorded here
      //     as a divergence to be re-derived under matching conditions if it
      //     is ever load-bearing, NOT as a number this cell overturns.
      //
      // What it means for the fix: nothing is orphaned and nothing hangs. A
      // query lost in the reorder's window fails its send against the dropped
      // receiver, is dropped, and its getter is finalized immediately with no
      // reply -- an observable this binding already produces elsewhere.
      expect(
        branch,
        equals('alpha-prompt'),
        reason:
            'the measured branch is (α) prompt -- every getter '
            'completes promptly after the close with no reply at all, and '
            'no getter ever waits out its own timeout. (β) is refuted. '
            'Measured:\n$table',
      );
      // The close, not an eager drop: on a fifo nothing is discarded, so no
      // getter may finalize before CLOSE is sent at ~800 ms. This is the
      // assertion that separates the fifo profile from the ring one below.
      expect(
        profiles.every((p) => p.elapsedMs >= 700),
        isTrue,
        reason:
            'a fifo holds every query until the close; none may '
            'finalize early:\n$table',
      );
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('the same window on a ring query channel is the control', () async {
      // THIS IS THE COMPARISON THAT MAKES "the same observable as a ring drop"
      // CHECKABLE RATHER THAN QUOTED. The claim was inherited as prose; here
      // the ring profile is measured under the identical driver and compared
      // to the fifo profile above, and the cell asserts whichever it finds.
      final child = await _startListener('ring');
      addTearDown(child.dispose);
      final getter = await _openGetterSession();
      addTearDown(getter.close);

      final profiles = await _fireAndMeasure(getter, child);
      final outcome = await child.awaitExit(const Duration(seconds: 90));
      final branch = _classify(profiles);
      final table = profiles.join('\n');

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(profiles, hasLength(_getters), reason: table);
      expect(profiles.every((p) => p.okReplies == 0), isTrue, reason: table);

      // MEASURED, ring, capacity 2, identical driver and identical linger:
      //
      //   get#0  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#1  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#2  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#3  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#4  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#5  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#6  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#7  elapsed=1ms    ok=0  err=0  timeoutError=false
      //   get#8  elapsed=811ms  ok=0  err=0  timeoutError=false
      //   get#9  elapsed=811ms  ok=0  err=0  timeoutError=false
      //
      // TWO THINGS ARE MEASURED HERE, and they answer different questions.
      //
      // 1. ON THE (α)/(β) AXIS THE TWO PROFILES MATCH. Both columns finalize
      //    every getter promptly, with zero replies and no Timeout error. So
      //    "the same observable as a ring drop" is now a MEASURED fact on
      //    this binding rather than an inherited quotation -- which is the
      //    comparison this control exists to make checkable.
      //
      // 2. THE TIMING DISTRIBUTIONS DIFFER, and the difference is the ring's
      //    own documented lossiness rather than anything close() does. Eight
      //    of the ten finalize at ~1 ms -- dropped as newer queries arrived,
      //    long before the 800 ms settle and long before CLOSE. Only the two
      //    still resident in the capacity-2 channel wait for the close. On the
      //    fifo column nothing is discarded, so all ten wait.
      //
      // ⚠️ AND THAT SECOND READING FALSIFIES A SHIPPED DARTDOC LINE.
      // `session.dart:785` says of a ring-dropped query: "Remotely that is
      // the dropped getter's timeout: it waited and got nothing." Measured,
      // the dropped getter does NOT wait and does NOT time out -- it is
      // finalized at ~1 ms with nothing. The claim's conclusion ("got
      // nothing") is right; its mechanism ("its timeout") is wrong. Corrected
      // in slice 7, which is where this unit's documentation work lives.
      expect(
        branch,
        equals('alpha-prompt'),
        reason:
            'the ring control measured the SAME branch as the fifo '
            'cell, which is what makes the ring-drop comparison checkable. '
            'Measured:\n$table',
      );
      // The eager-drop signature, and the one thing the fifo arm cannot
      // produce: a ring discards on overflow, so some getters are finalized
      // long before the close is even requested. Asserted at >= 1 rather than
      // at the measured 8, because the exact split is a scheduling artifact
      // while the existence of early drops is the structural claim.
      expect(
        profiles.any((p) => p.elapsedMs < 100),
        isTrue,
        reason:
            'a ring drops on overflow, so some getters must finalize '
            'before the close; the fifo arm has none:\n$table',
      );
    }, timeout: const Timeout(Duration(seconds: 240)));

    group('Edge cases', () {
      test('nothing is orphaned when queries arrive inside the window', () async {
        // The counting legs of slice 5 cannot see a PREMATURE free -- a block
        // freed too early is still freed, so its address is reusable and the
        // count reads clean. The discriminator for that class is poisoning, on
        // a subprocess (glibc reads MALLOC_PERTURB_ once at startup), with a
        // printed success marker so a process that died early cannot satisfy
        // an exit-code assertion for the wrong reason.
        final outcome = await runBoundedHarness(
          _perturbHarness,
          const [],
          deadline: const Duration(seconds: 120),
          environment: {'MALLOC_PERTURB_': '165'},
        );

        expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
        expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
        for (var round = 0; round < 8; round++) {
          expect(
            outcome.hasMarker('ROUND=$round'),
            isTrue,
            reason: 'round $round never completed:\n${outcome.diagnosis}',
          );
        }
        expect(
          outcome.hasMarker('WINDOW_DONE'),
          isTrue,
          reason:
              'the harness must reach its end -- an early death would '
              'otherwise pass the exit-code assertion for the wrong '
              'reason:\n${outcome.diagnosis}',
        );
      }, timeout: const Timeout(Duration(seconds: 240)));
    });
  });
}
