// Seed [MICRO-fifo-close] -- `close()` on a full fifo hangs the isolate
// forever.
//
// `PullSubscriber.close()` and `PullQueryable.close()` undeclared the entity
// BEFORE dropping the fifo handler. `z_undeclare_subscriber` blocks until
// executing callbacks are destroyed (zenoh-c 1.8.0 #1221); canon's fifo
// callback is a `send()` on a bounded flume channel, which blocks when the
// channel is full. So a delivery parked in `send()` at the moment of `close()`
// waited for a consumer that was the very isolate now frozen inside the
// synchronous FFI call. No timeout, no exception, no recovery.
//
// The fix is a three-statement reorder on each column: handler drop first
// (dropping the receiving end makes the parked send fail fast, which is what
// lets `wait_callbacks()` return at all), entity undeclare second, tee drop
// still LAST -- the one part of the original rationale that survives, because
// #1221 genuinely governs the tee.
//
// EVERY CELL HERE THAT COULD HANG RUNS ITS `close()` IN A SUBPROCESS under an
// OS-level kill. See `helpers/bounded_subprocess.dart` for why an in-process
// bound is mechanically unsatisfiable against this defect.
//
// PORTS: 19580 (slice 1 harness self-checks), 19581 (sample column),
// 19582 (query column). High-water before this unit was 19572, re-derived at
// planning with two independent instruments.
import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/bounded_subprocess.dart';

const _harness = 'test/helpers/fifo_close_harness.dart';
const _perturbHarness = 'test/helpers/fifo_close_perturb_harness.dart';

void main() {
  group('The bounded demonstration harness (slice 1)', () {
    // This group builds the instrument and proves the instrument works, before
    // any cell relies on it. It writes no production code and changes no
    // behaviour. Test 2 in particular is the positive control for the WHOLE
    // unit: without it, every "it did not freeze" below is an untested
    // instrument reporting success by construction.

    test('runs green on a configuration that cannot deadlock', () async {
      // A ring channel's push never blocks its producer, so no delivery can
      // ever be parked and this configuration has no way to reach the defect.
      // A red here is the harness itself being broken.
      final outcome = await runBoundedHarness(
        _harness,
        [
          '--role',
          'selfcontained',
          '--column',
          'sub',
          '--kind',
          'ring',
          '--capacity',
          '2',
          '--count',
          '20',
          '--port',
          '19580',
        ],
        deadline: const Duration(seconds: 60),
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      expect(
        outcome.markerValue('PUBLISHED='),
        equals(20),
        reason: outcome.diagnosis,
      );
      // ORDER, not merely presence. `CLOSE_RETURNED_MS=` is printed on the
      // line after `close()` returns, so its position after `CLOSING_MS=` is
      // what makes it evidence that the close came back rather than evidence
      // that the process reached the close.
      expect(
        outcome.markerOrder([
          'HARNESS_READY',
          'PUBLISHED=',
          'CLOSING_MS=',
          'CLOSE_RETURNED_MS=',
          'HARNESS_DONE',
        ]),
        equals([
          'HARNESS_READY',
          'PUBLISHED=',
          'CLOSING_MS=',
          'CLOSE_RETURNED_MS=',
          'HARNESS_DONE',
        ]),
        reason: outcome.diagnosis,
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the bound is real -- the helper kills a child that will not exit', () async {
      // THE POSITIVE CONTROL FOR THE UNIT. Every other cell's "frozen: false"
      // is worthless unless this instrument can produce "frozen: true" at all.
      // `--hang-forever` parks the child on an unreachable future immediately
      // after `CLOSING_MS=`, which is precisely where the real defect parks --
      // so this exercises the reporting path the defect would take, not a
      // convenient substitute.
      final sw = Stopwatch()..start();
      final outcome = await runBoundedHarness(
        _harness,
        [
          '--column',
          'sub',
          '--kind',
          'ring',
          '--capacity',
          '2',
          '--count',
          '0',
          '--port',
          '19580',
          '--hang-forever',
        ],
        deadline: const Duration(seconds: 5),
      );
      sw.stop();

      expect(outcome.frozen, isTrue, reason: outcome.diagnosis);
      expect(
        outcome.lastMarker,
        startsWith('CLOSING_MS='),
        reason: outcome.diagnosis,
      );
      expect(
        outcome.diagnosis,
        contains('column=sub'),
        reason: 'a freeze must name the column it froze on',
      );
      expect(
        outcome.diagnosis,
        contains('kind=ring'),
        reason: 'a freeze must name the kind it froze on',
      );
      // `awaitExit` awaits `exitCode` AFTER the SIGKILL, and that future
      // completing is what proves the child was reaped rather than merely
      // signalled. A non-zero code is the signal-terminated form.
      expect(outcome.exitCode, isNot(0), reason: outcome.diagnosis);
      expect(
        outcome.hasMarker('CLOSE_RETURNED_MS='),
        isFalse,
        reason: 'a child that never closed must not report a returned close',
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 30)),
        reason: 'the bound must fire near its deadline, not eventually',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the stdin trigger is deterministic', () async {
      // The positive control for slice 4's topology. Slice 4 needs "the close
      // happened after the getters were in flight" to be a SEQUENCED FACT, and
      // that rests entirely on the child parking on a command rather than on a
      // clock. Proven here, before slice 4 uses it.
      final child = await startBoundedHarness(
        _harness,
        [
          '--role',
          'listener',
          '--close-on',
          'stdin',
          '--column',
          'qbl',
          '--kind',
          'fifo',
          '--capacity',
          '2',
          '--port',
          '19580',
        ],
      );
      addTearDown(child.dispose);

      await child.waitForMarker(
        'AWAITING_CLOSE_CMD',
        const Duration(seconds: 30),
      );
      // Settle, not a race: the point is to give a timer-driven child ample
      // room to close on its own. If `CLOSING_MS=` appears during this window
      // the trigger is not the command and the assertion below fails.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      child.send('CLOSE');
      final outcome = await child.awaitExit(const Duration(seconds: 60));

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      expect(
        outcome.markerOrder([
          'AWAITING_CLOSE_CMD',
          'CLOSING_MS=',
          'CLOSE_RETURNED_MS=',
          'HARNESS_DONE',
        ]),
        equals([
          'AWAITING_CLOSE_CMD',
          'CLOSING_MS=',
          'CLOSE_RETURNED_MS=',
          'HARNESS_DONE',
        ]),
        reason: outcome.diagnosis,
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      test('an early death does not pass for a success', () async {
        // MARKER DISCIPLINE, stated as a cell. A child that died before ever
        // reaching the thing under test also does not freeze -- so
        // `frozen: false` alone is not a pass, and every cell in this unit
        // that asserts a clean close asserts `CLOSE_RETURNED_MS=` too. This
        // pins that the two are genuinely separable.
        //
        // `--capacity -1` is rejected by the shipped binding with an
        // `ArgumentError` before any session work, which makes it a death that
        // happens strictly earlier than any close could.
        final outcome = await runBoundedHarness(
          _harness,
          [
            '--column',
            'sub',
            '--kind',
            'fifo',
            '--capacity',
            '-1',
            '--count',
            '0',
            '--port',
            '19580',
          ],
          deadline: const Duration(seconds: 30),
        );

        expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
        expect(outcome.exitCode, isNot(0), reason: outcome.diagnosis);
        expect(
          outcome.hasMarker('CLOSE_RETURNED_MS='),
          isFalse,
          reason: outcome.diagnosis,
        );
        expect(
          outcome.hasMarker('HARNESS_DONE'),
          isFalse,
          reason: outcome.diagnosis,
        );
      }, timeout: const Timeout(Duration(seconds: 90)));
    });
  });

  group('Sample column: close() returns on a full fifo (slice 2)', () {
    // THE FIX: in `PullSubscriber.close()`, `zd_pull_handler_drop` moves ABOVE
    // `zd_subscriber_drop`; `zd_pull_tee_drop` stays LAST. Net sequence
    // handler -> entity -> tee.
    //
    // CRITERION B, BOTH WAYS. Every cell in this group was written and run
    // BEFORE the reorder. The verbatim pre-fix output is recorded in each
    // cell; that RED is the unfixed-tree demonstration for this column.

    test(
      'a full, undrained fifo does not hang close() -- the overflow trigger',
      () async {
        // 20 messages into a capacity-2 fifo with nothing drained, so at least
        // one delivery is parked inside the tee's inner call at the moment of
        // close. Two sessions, always: a same-session fifo-full cell blocks
        // inside put #N+1 and freezes BEFORE close() is ever reached -- the
        // producer-side form of this same failure mode, which would test
        // nothing here.
        //
        // MEASURED PRE-FIX (the RED, verbatim from the run before the reorder):
        //   FROZEN: fifo_close_harness.dart[column=sub kind=fifo capacity=2
        //   count=20] did not exit within 60s and was SIGKILLed;
        //   last marker: CLOSING_MS=1645
        // Standalone, same tree: HARNESS_READY / PUBLISHED=20 / CLOSING_MS=1645
        // and then nothing at all -- exit 124 from an external `timeout`, i.e.
        // the process had to be killed from outside.
        // MEASURED POST-FIX: frozen: false, CLOSE_RETURNED_MS=6, exit 0.
        final outcome = await runBoundedHarness(
          _harness,
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
            '19581',
          ],
          deadline: const Duration(seconds: 60),
        );

        expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
        expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
        expect(
          outcome.markerValue('PUBLISHED='),
          equals(20),
          reason: outcome.diagnosis,
        );
        expect(
          outcome.markerValue('CLOSE_RETURNED_MS='),
          lessThan(5000),
          reason: outcome.diagnosis,
        );
        expect(
          outcome.hasMarker('HARNESS_DONE'),
          isTrue,
          reason: outcome.diagnosis,
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('the trigger is an OVERFLOW, not a non-empty channel', () async {
      // THE D vs D' CONTROL, and it is what makes the 3-message arm evidence.
      // Canon-level measurement: exactly-at-capacity does NOT trigger the
      // hang; one message past capacity does. A cell that filled to capacity
      // and stopped would therefore have passed on broken code.
      //
      // MEASURED PRE-FIX, standalone, the asymmetry that proves the trigger:
      //   --count 2: HARNESS_READY / PUBLISHED=2 / CLOSING_MS=1646 /
      //              CLOSE_RETURNED_MS=8 / HARNESS_DONE, exit 0   (CLEAN)
      //   --count 3: HARNESS_READY / PUBLISHED=3 / CLOSING_MS=1645 /
      //              <nothing>, exit 124                          (FROZEN)
      // One message is the whole difference. MEASURED POST-FIX: both arms
      // frozen: false, exit 0 (CLOSE_RETURNED_MS=6 and =5 respectively).
      for (final count in ['2', '3']) {
        final outcome = await runBoundedHarness(
          _harness,
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
            count,
            '--port',
            '19581',
          ],
          deadline: const Duration(seconds: 60),
        );
        expect(
          outcome.frozen,
          isFalse,
          reason: 'count=$count arm:\n${outcome.diagnosis}',
        );
        expect(
          outcome.exitCode,
          isZero,
          reason: 'count=$count arm:\n${outcome.diagnosis}',
        );
        expect(
          outcome.hasMarker('CLOSE_RETURNED_MS='),
          isTrue,
          reason: 'count=$count arm:\n${outcome.diagnosis}',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('ring is unaffected in both directions', () async {
      // THE TOPOLOGY CONTROL. A ring's push never blocks its producer, so no
      // delivery can park and this arm must be green on the PRE-fix tree as
      // well as the fixed one. That is what proves the two-session overflow
      // topology alone does not cause the freeze -- without it, "the fifo arm
      // froze" could be an artifact of the harness rather than of the kind.
      //
      // MEASURED PRE-FIX: PUBLISHED=20 / CLOSING_MS=1648 /
      //   CLOSE_RETURNED_MS=6 / HARNESS_DONE, exit 0 -- green on BROKEN code,
      //   which is exactly what makes it a control rather than a test.
      // MEASURED POST-FIX: frozen: false, CLOSE_RETURNED_MS=5, exit 0.
      final outcome = await runBoundedHarness(
        _harness,
        [
          '--role',
          'selfcontained',
          '--column',
          'sub',
          '--kind',
          'ring',
          '--capacity',
          '2',
          '--count',
          '20',
          '--port',
          '19581',
        ],
        deadline: const Duration(seconds: 60),
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      expect(
        outcome.hasMarker('CLOSE_RETURNED_MS='),
        isTrue,
        reason: outcome.diagnosis,
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      test(
        'capacity 0 is a rendezvous trigger and the fix covers it',
        () async {
          // A MECHANICALLY DISTINCT ARM, not a duplicate of the overflow cells.
          // A capacity-0 fifo is a rendezvous: it is full when empty, so it
          // parks on the FIRST delivery rather than on capacity+1. "Capacity N,
          // more than N" is written for N >= 1 and does not reach this corner,
          // and zero has meant three different things on three surfaces in this
          // binding -- so it is pinned as its own cell with its own trigger
          // stated rather than folded into the wording above.
          //
          // MEASURED PRE-FIX:
          //   FROZEN: fifo_close_harness.dart[column=sub kind=fifo capacity=0
          //   count=5] did not exit within 60s and was SIGKILLed;
          //   last marker: CLOSING_MS=1643
          // Standalone, same tree: PUBLISHED=5 / CLOSING_MS=1643 / <nothing>,
          // exit 124. Note it parks after FIVE messages into a channel with no
          // capacity at all -- the first delivery is the trigger.
          // MEASURED POST-FIX: frozen: false, CLOSE_RETURNED_MS=7, exit 0.
          final outcome = await runBoundedHarness(
            _harness,
            [
              '--role',
              'selfcontained',
              '--column',
              'sub',
              '--kind',
              'fifo',
              '--capacity',
              '0',
              '--count',
              '5',
              '--port',
              '19581',
            ],
            deadline: const Duration(seconds: 60),
          );

          expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
          expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
          expect(
            outcome.markerValue('CLOSE_RETURNED_MS='),
            lessThan(5000),
            reason: outcome.diagnosis,
          );
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );

      test(
        'an empty fifo and a fully-drained fifo still close cleanly',
        () async {
          // CRITERION D, pinned unchanged. Driven IN-PROCESS deliberately:
          // neither arm can park a delivery -- one never publishes, the other
          // consumes everything it published before closing -- so the
          // subprocess bound the rest of this group runs behind does not apply
          // and would only add cost.
          final consumer = await Session.open(
            config: Config()
              ..insertJson5('mode', '"peer"')
              ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19581"]')
              ..insertJson5('scouting/multicast/enabled', 'false')
              ..insertJson5('scouting/gossip/enabled', 'false'),
          );
          addTearDown(consumer.close);
          final producer = await Session.open(
            config: Config()
              ..insertJson5('mode', '"peer"')
              ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19581"]')
              ..insertJson5('scouting/multicast/enabled', 'false')
              ..insertJson5('scouting/gossip/enabled', 'false'),
          );
          addTearDown(producer.close);

          final link = Stopwatch()..start();
          while (consumer.peersZid().isEmpty) {
            expect(
              link.elapsed,
              lessThan(const Duration(seconds: 20)),
              reason: 'the two peers never linked',
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }

          // Arm (a): nothing ever published.
          final empty = consumer.declarePullSubscriber(
            'zenoh/dart/fifoclose/empty',
            kind: ChannelKind.fifo,
            capacity: 2,
          );
          // Tear-offs hoisted so the assertions below read as assertions about
          // a CLOSED handle rather than as further calls on a live one.
          final emptyRecv = empty.tryRecv;
          final emptyClose = empty.close;
          empty.close();
          expect(emptyRecv, throwsStateError);
          expect(emptyClose, returnsNormally); // the double-close guard

          // Arm (b): 20 published, drained to RecvEmpty, then closed.
          const key = 'zenoh/dart/fifoclose/drained';
          final drainMe = consumer.declarePullSubscriber(
            key,
            kind: ChannelKind.fifo,
            capacity: 2,
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          for (var i = 0; i < 20; i++) {
            producer.put(key, 'x$i');
          }
          // Drain until ALL twenty are consumed, bounded. Stopping at the first
          // RecvEmpty would be a race: 18 could still be undelivered, the
          // delivery thread would park on the next push, and this cell would
          // become the very hang it is not testing.
          var drained = 0;
          final deadline = Stopwatch()..start();
          while (drained < 20) {
            expect(
              deadline.elapsed,
              lessThan(const Duration(seconds: 30)),
              reason: 'only $drained/20 samples arrived',
            );
            if (drainMe.tryRecv() case RecvData<Sample>()) {
              drained++;
            } else {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          expect(drainMe.tryRecv(), isA<RecvEmpty<Sample>>());

          final drainedRecv = drainMe.tryRecv;
          final drainedClose = drainMe.close;
          drainMe.close();
          expect(drainedRecv, throwsStateError);
          expect(drainedClose, returnsNormally); // the double-close guard
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    });
  });

  group('Query column: close() returns on a full fifo (slice 3)', () {
    // THE SAME REORDER, SECOND COLUMN: `zd_query_handler_drop` moves ABOVE
    // `zd_queryable_drop`; `zd_pull_tee_drop` stays LAST.
    //
    // A separate slice from the sample column because the driver is different
    // (in-flight `get()`s, not `put()`s) and the buffered payload is a
    // `z_owned_query_t` rather than a sample. Slice 2 has already landed, so a
    // freeze here is unambiguously the query column's.
    //
    // CRITERION B: written and run before this column's reorder.

    test('a full, undrained query fifo does not hang close()', () async {
      // 20 getters at capacity 2 with no tryRecv at all, so at least one query
      // delivery is parked inside the tee's inner call at the moment of close.
      //
      // MEASURED PRE-FIX, standalone:
      //   HARNESS_READY / PUBLISHED=20 / CLOSING_MS=1644 / <nothing>, exit 124
      // MEASURED POST-FIX: PUBLISHED=20 / CLOSE_RETURNED_MS=4 / HARNESS_DONE,
      //   exit 0.
      final outcome = await runBoundedHarness(
        _harness,
        [
          '--role',
          'selfcontained',
          '--column',
          'qbl',
          '--kind',
          'fifo',
          '--capacity',
          '2',
          '--count',
          '20',
          '--port',
          '19582',
        ],
        deadline: const Duration(seconds: 90),
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      expect(
        outcome.markerValue('PUBLISHED='),
        equals(20),
        reason: outcome.diagnosis,
      );
      expect(
        outcome.markerValue('CLOSE_RETURNED_MS='),
        lessThan(5000),
        reason: outcome.diagnosis,
      );
      expect(
        outcome.hasMarker('HARNESS_DONE'),
        isTrue,
        reason: outcome.diagnosis,
      );
    }, timeout: const Timeout(Duration(seconds: 180)));

    test(
      "the query column's overflow boundary matches the sample column's",
      () async {
        // The same D vs D' control, second column -- and the boundary lands in
        // the same place, which is what says this is one defect on two columns
        // rather than two coincidences.
        //
        // MEASURED PRE-FIX, standalone:
        //   --count 2: PUBLISHED=2 / CLOSING_MS=1646 / CLOSE_RETURNED_MS=4 /
        //              HARNESS_DONE, exit 0                          (CLEAN)
        //   --count 3: PUBLISHED=3 / CLOSING_MS=1646 / <nothing>, exit 124
        //                                                           (FROZEN)
        // MEASURED POST-FIX: both arms clean, exit 0 (the count=3 arm's
        // CLOSE_RETURNED_MS=5).
        for (final count in ['2', '3']) {
          final outcome = await runBoundedHarness(
            _harness,
            [
              '--role',
              'selfcontained',
              '--column',
              'qbl',
              '--kind',
              'fifo',
              '--capacity',
              '2',
              '--count',
              count,
              '--port',
              '19582',
            ],
            deadline: const Duration(seconds: 90),
          );
          expect(
            outcome.frozen,
            isFalse,
            reason: 'count=$count arm:\n${outcome.diagnosis}',
          );
          expect(
            outcome.exitCode,
            isZero,
            reason: 'count=$count arm:\n${outcome.diagnosis}',
          );
          expect(
            outcome.hasMarker('CLOSE_RETURNED_MS='),
            isTrue,
            reason: 'count=$count arm:\n${outcome.diagnosis}',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 240)),
    );

    group('Edge cases', () {
      test('a query taken out before close() is still replied to', () async {
        // CRITERION D on this column, pinned unchanged: reply-before-close and
        // the double-close guard. Driven IN-PROCESS deliberately -- one query
        // into a capacity-2 channel cannot park a delivery, so the subprocess
        // bound does not apply here.
        final host = await Session.open(
          config: Config()
            ..insertJson5('mode', '"peer"')
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19582"]')
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        addTearDown(host.close);
        final getter = await Session.open(
          config: Config()
            ..insertJson5('mode', '"peer"')
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19582"]')
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        addTearDown(getter.close);

        final link = Stopwatch()..start();
        while (host.peersZid().isEmpty) {
          expect(
            link.elapsed,
            lessThan(const Duration(seconds: 20)),
            reason: 'the two peers never linked',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        const key = 'zenoh/dart/fifoclose/reply-first';
        final qbl = host.declarePullQueryable(
          key,
          kind: ChannelKind.fifo,
          capacity: 2,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getter
            .get(key, timeout: const Duration(seconds: 8))
            .toList();

        // Poll for the query, bounded: an unbounded wait here would convert a
        // routing failure into a hang indistinguishable from the defect.
        Query? taken;
        final poll = Stopwatch()..start();
        while (taken == null) {
          expect(
            poll.elapsed,
            lessThan(const Duration(seconds: 20)),
            reason: 'no query ever reached the pull queryable',
          );
          if (qbl.tryRecv() case RecvData<Query>(:final value)) {
            taken = value;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        // The getter does not observe the reply until the Query is dropped,
        // so the reply and its drop are one act here.
        taken
          ..reply(key, 'pong')
          ..dispose();

        final got = await replies.timeout(const Duration(seconds: 30));
        expect(got, hasLength(1), reason: 'exactly one reply was sent');
        expect(got.single.isOk, isTrue);
        expect(got.single.ok.payload, equals('pong'));

        final qblRecv = qbl.tryRecv;
        final qblClose = qbl.close;
        qbl.close();
        expect(qblRecv, throwsStateError);
        expect(qblClose, returnsNormally); // the double-close guard
      }, timeout: const Timeout(Duration(seconds: 180)));
    });
  });

  group('S-4: the perturbed tee-race leg (slice 6)', () {
    // The counted legs in `ffi_ownership_test.dart` see a LEAK -- a release
    // that stopped happening. They cannot see a PREMATURE free: a block freed
    // too early is still freed, so its address is reusable and the count reads
    // clean. The discriminator for that class is poisoning, on a subprocess,
    // with a printed success marker.

    test('closing a full fifo while deliveries are still in flight corrupts '
        'nothing', () async {
      // 15 rounds of {declare fifo cap 2, pump puts from the second session
      // throughout, let the channel fill, close without draining}. The pump is
      // what makes this leg different from every other cell here: a tee block
      // freed early is only caught if something still REACHES it, and
      // `_zd_pull_tee_on_call` loans and calls `tee->inner`, so a quiescent
      // close would leave poisoned bytes untouched and pass.
      //
      // MEASURED, shipped tree, MALLOC_PERTURB_=165:
      //   ROUND=0 .. ROUND=14, PERTURB_CLOSED, PERTURB_DONE, exit 0.
      final outcome = await runBoundedHarness(
        _perturbHarness,
        const [],
        deadline: const Duration(seconds: 180),
        environment: {'MALLOC_PERTURB_': '165'},
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      for (var round = 0; round < 15; round++) {
        expect(
          outcome.hasMarker('ROUND=$round'),
          isTrue,
          reason: 'round $round never completed:\n${outcome.diagnosis}',
        );
      }
      expect(
        outcome.hasMarker('PERTURB_CLOSED'),
        isTrue,
        reason: outcome.diagnosis,
      );
      // The end marker is mandatory and is asserted SEPARATELY from the exit
      // code: a process that died early would otherwise satisfy an exit-code
      // assertion for the wrong reason.
      expect(
        outcome.hasMarker('PERTURB_DONE'),
        isTrue,
        reason: 'the harness must reach its end:\n${outcome.diagnosis}',
      );

      // ── THE BOTH-WAYS CALIBRATION, AND ITS VERDICT IS PARTIAL ────────────
      // Injection (temporary local edit, never committed): one extra
      //   bindings.zd_pull_tee_drop(
      //     Pointer<Uint8>.fromAddress(pull.teeAddressForTesting))
      // immediately BEFORE close(), while canon's closure is still live and
      // the pump is still delivering.
      //
      //   shipped,  MALLOC_PERTURB_=165 -> 15 rounds, both end markers, exit 0
      //   injected, MALLOC_PERTURB_=165 -> NO output at all, hung, killed 124
      //   injected, NO MALLOC_PERTURB_  -> NO output at all, hung, killed 124
      //
      // ⚠️ SEPARATION IS TOTAL, BUT THE POISONING IS NOT WHAT PRODUCES IT, AND
      // THAT IS SAID OUT LOUD RATHER THAN LEFT IMPLIED. The injected build
      // never completes even round 0, and it fails IDENTICALLY with and
      // without MALLOC_PERTURB_ -- the third line is the control on the
      // control, and it is what forbids claiming the poisoning discriminated.
      // The instrument that actually separated here is the harness's own
      // completion markers.
      //
      // WHY the injected arm hangs rather than faulting: the extra drop takes
      // the head's reference count to 1, so canon's closure drop inside
      // `zd_subscriber_drop` takes it to 0 and frees the tee WHILE a delivery
      // is parked inside it -- and the undeclare then waits on a callback that
      // can no longer complete. A premature free on this path is therefore
      // CATASTROPHIC AND LOUD, not silent, which is itself a partial answer to
      // S-4: this tee release is not quietly order-sensitive.
      //
      // WHAT THIS LEG THEREFORE DOES AND DOES NOT ESTABLISH.
      //   DOES: on the shipped tree, 15 rounds of close-while-delivering under
      //         an allocator that fills freed bytes with 0xA5 produce no
      //         fault, no crash and no corruption. That is a real negative in
      //         the configuration most likely to expose one.
      //   DOES NOT: prove that MALLOC_PERTURB_ would catch a SILENT
      //         use-after-free on this block, because no injection available
      //         from Dart gets far enough for a poisoned read to be taken.
      //         Producing one would need a shim change, which this unit's
      //         Dart-only position excludes.
      //
      // ▶ SO S-4's EVIDENCE RESTS ON THE OTHER TWO LEGS, DECLARED HERE RATHER
      // THAN ASSUMED: the four-way counted calibration in
      // `ffi_ownership_test.dart` (each release removed in turn, 50/50 leaking
      // vs 1-34/50 shipped, each injection moving only its own block), and the
      // tee head's reference count read at source -- `atomic_int refcount`
      // initialised to 2, decremented once by canon's closure drop and once by
      // the Dart handle, last one frees, so the free is order-independent by
      // construction. This leg corroborates them; it does not carry them.
    }, timeout: const Timeout(Duration(seconds: 300)));
  });

  group('The corrected contract (slice 7)', () {
    // The documentation's new claim is backed by a passing cell rather than by
    // prose, and the removed claim is the one this cell would have
    // contradicted.

    test('closing with no drain at all is a supported sequence', () async {
      // THE PRECISE SEQUENCE THE OLD DARTDOC DISCOURAGED. "Drain before you
      // close" read as a precondition; it is now residue guidance, and this is
      // what makes that rewrite checkable.
      final outcome = await runBoundedHarness(
        _harness,
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
          '19581',
        ],
        deadline: const Duration(seconds: 60),
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      expect(
        outcome.hasMarker('CLOSE_RETURNED_MS='),
        isTrue,
        reason: outcome.diagnosis,
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    group('Edge cases', () {
      test('the session-first teardown order is still a residual', () async {
        // ⚠️ THIS CELL PINS A LIMITATION, NOT A REQUIREMENT -- the
        // honest-absence form. Closing the consumer SESSION before the handle,
        // with a fifo in overflow, still stalls: that path is canon's own
        // session teardown and this unit deliberately does not fix it.
        //
        // It is here because a documented limitation with no pin is an
        // unfalsifiable rationale. The dartdoc now tells callers to close pull
        // handles before their session; without this cell that instruction
        // rests on prose. With it, the instruction is measured -- and the cell
        // goes RED as an ALARM if a future canon fixes the session-first path,
        // which is the correct signal to re-read the docs.
        //
        // MEASURED on the fixed tree: SESSION_CLOSED_MS=~10000 (canon's own
        // z_close watchdog), then no CLOSE_RETURNED_MS at all; the helper
        // reports frozen: true with last marker CLOSING_MS=.
        final outcome = await runBoundedHarness(
          _harness,
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
            '--mode',
            'session-first',
            '--port',
            '19580',
          ],
          deadline: const Duration(seconds: 40),
        );

        expect(
          outcome.hasMarker('SESSION_CLOSED_MS='),
          isTrue,
          reason:
              'the session close must have been reached and returned:\n'
              '${outcome.diagnosis}',
        );
        expect(
          outcome.frozen,
          isTrue,
          reason:
              'if this is now false the session-first path has been '
              'FIXED upstream -- that is good news, and it means the '
              'teardown-order guidance in the pull dartdocs is stale and '
              'must be re-read:\n${outcome.diagnosis}',
        );
        expect(
          outcome.lastMarker,
          startsWith('CLOSING_MS='),
          reason: outcome.diagnosis,
        );
        expect(
          outcome.hasMarker('CLOSE_RETURNED_MS='),
          isFalse,
          reason: outcome.diagnosis,
        );
      }, timeout: const Timeout(Duration(seconds: 120)));
    });
  });
}
