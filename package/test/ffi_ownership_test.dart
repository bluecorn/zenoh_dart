@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh.dart';
import 'package:zenoh_dart/zenoh_unstable.dart'
    show AllocAlignment, AllocOk, AllocResult, ShmProvider, ZenohFeatures;

import 'helpers/bounded_subprocess.dart';

/// Resource-observability legs for the FFI ownership fix-round.
///
/// These tests measure a RESOURCE, not a behaviour. A leak neither throws nor
/// corrupts, so every behavioural assertion in the suite passes identically on
/// leaking and on fixed code (`development/discipline/verification.md` §3a).
/// The instrument is the house one: run N cycles and count how many DISTINCT
/// heap addresses the allocator had to hand out. Released => the same block is
/// reissued and the set stays tiny. Leaked => every cycle needs a fresh block
/// and the set grows to N.
///
/// Counted, never sampled once: a single "same address before and after" check
/// passes for the wrong reason whenever unrelated churn recycles that one
/// address.
/// A non-null sentinel written into an out-cell before a call, so that "the
/// shim did not write" is distinguishable from "the shim wrote NULL". Never
/// dereferenced — every use asserts the cell moved off it.
const _poison = 0xDEAD0000;

void main() {
  group('Query wrapper block ownership (TCP 18930)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18930"]')
          ..insertJson5('scouting/multicast/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18930"]')
          ..insertJson5('scouting/multicast/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test(
      'a disposed query returns its wrapper block to the allocator',
      () async {
        const cycles = 100;
        final addresses = <int>{};
        var delivered = 0;

        final queryable = sessionA.declareQueryable(
          'zenoh/dart/own/q/disposed',
        );
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          delivered++;
          // Captured BEFORE dispose -- handle throws once disposed.
          addresses.add(query.handle);
          query
            ..reply('zenoh/dart/own/q/disposed', 'ok')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        for (var i = 0; i < cycles; i++) {
          await sessionB.get('zenoh/dart/own/q/disposed').toList();
        }

        // Positive control on the instrument: a short loop, or a queryable
        // that never received anything, must not pass for the wrong reason.
        expect(delivered, cycles);

        // Leaking => every cycle needs a fresh block, so the set grows to
        // `cycles`. Released => zd_query_drop's free() hands the block back
        // and the allocator reissues it. The fixed floor is not 1: the query
        // callback runs on tokio worker threads, and glibc gives each thread
        // its own arena, so the reissued blocks come from a handful of pools.
        //
        // ⚠️ THE FIXED SIDE IS A DRAW, NOT A CONSTANT, and the original
        // threshold of 40 was pinned to a single sample of it (12, measured on
        // the unstable variant). It is not a property of the code: the count is
        // bounded by however many arenas the tokio pool happened to use, which
        // moves with the variant and with machine load. The stable variant runs
        // 2-3x higher than the unstable one, so the pin was latent-flaky from
        // the day it was written and went red on a stable-leg matrix run.
        //
        // RE-MEASURED over 21 runs, both variants, and on `main` as well as on
        // the branch that surfaced it -- so the fixed band is characterised
        // rather than sampled:
        //
        //   free() present, unstable :  19  20  24  26  28  31
        //   free() present, stable   :  35  49  52  53  55  60  64  64  67  69
        //   free() REMOVED, either   : 100 100 100 100 100
        //
        // The leaking side is not a draw at all -- it is exactly `cycles`,
        // every time, because a leak means no block is ever reused. So the
        // discriminator is "at least some blocks came back", and the threshold
        // sits between a fixed maximum of 69 and a leaking value of 100 with
        // comparable margin on each side.
        expect(addresses.length, lessThan(85));
      },
    );

    // NAMED TEST -- the undelivered-query-disposal case. It pins the invariant
    // that Queryable.close() must not strand a query that arrived but was
    // never delivered, and it must survive seed #11's lifecycle-cascade work
    // (roadmap §10 decision 6). Do not rename it without updating that record.
    test(
      'Queryable.close disposes undelivered queries (remote sees final)',
      () async {
        // No listener on the stream, so every query that arrives is parsed and
        // buffered -- undelivered by construction, not by timing.
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/own/q/undelivered',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // A long timeout is what makes this discriminate: the getter completes
        // early ONLY because the dropped query sends ResponseFinal. Without
        // the drop it waits the full 10 s out.
        final replies = sessionB
            .get(
              'zenoh/dart/own/q/undelivered',
              timeout: const Duration(seconds: 10),
            )
            .toList();

        // Let the query arrive and buffer.
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final watch = Stopwatch()..start();
        queryable.close();
        await replies;
        watch.stop();

        // Red leg (pre-fix): ~10 000 ms -- the query is never dropped, so the
        // getter waits out its own timeout. Green: prompt finalisation.
        expect(watch.elapsedMilliseconds, lessThan(3000));
      },
    );

    test(
      'Queryable.close drains queries still in the port queue',
      () async {
        // Half 2 of the F2 fix: a NativePort message that has landed but has
        // not been parsed yet. ReceivePort.close() discards such messages
        // (measured: 0 of 5 delivered), so the fix defers the close by one
        // event-loop turn and drops each message as it arrives.
        //
        // Blocking the isolate is what puts a message in that state: the
        // native tokio thread posts while Dart cannot run its listener.

        // POSITIVE CONTROL -- prove the busy-wait window really does contain
        // the native post, so the leg below is not passing because the query
        // never arrived.
        final control = sessionA.declareQueryable('zenoh/dart/own/q/queued/a');
        var controlReceived = 0;
        control.stream.listen((query) {
          controlReceived++;
          query.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final controlReplies = sessionB
            .get(
              'zenoh/dart/own/q/queued/a',
              timeout: const Duration(seconds: 5),
            )
            .toList();
        _blockIsolate(const Duration(milliseconds: 600));
        // One turn is enough because the message was already queued.
        await Future<void>.delayed(Duration.zero);
        expect(
          controlReceived,
          1,
          reason:
              'the busy-wait window must contain the native post, '
              'or the drain leg below proves nothing',
        );
        await controlReplies;
        control.close();

        // THE LEG -- same construction, but close() runs before the isolate
        // ever returns to the event loop, so the message is still in the port
        // queue when the queryable is torn down.
        final queryable = sessionA.declareQueryable(
          'zenoh/dart/own/q/queued/b',
        );
        var received = 0;
        queryable.stream.listen((query) {
          received++;
          query.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = sessionB
            .get(
              'zenoh/dart/own/q/queued/b',
              timeout: const Duration(seconds: 10),
            )
            .toList();
        _blockIsolate(const Duration(milliseconds: 600));

        final watch = Stopwatch()..start();
        queryable.close();
        await replies;
        watch.stop();

        // The consumer never sees a query the queryable dropped.
        expect(received, 0);
        // Red leg (pre-fix): the queued message is discarded with the port, so
        // nothing ever drops the query and the getter waits out its timeout.
        expect(watch.elapsedMilliseconds, lessThan(3000));
      },
    );
  });

  _throwPathGroup();
  _slicesGroup();
  _variantOverrideGroup();
  _allocGuardGroup();
  _pullChannelOwnershipGroup();
  _fifoCloseOverflowOwnershipGroup();
  _channelBlockOwnershipGroup();
  _pullQueryWrapperOwnershipGroup();
  _pullPortLifecycleGroup();
  _shimContextCountingGroup();
  _encodingCarrierCountingGroup();
  _offloadedOpenOwnershipGroup();
}

/// Seed #8: the two new shim-side context blocks, counted rather than asserted.
///
/// A leak is invisible to every behavioural assertion, so the discipline is to
/// measure the resource — and the usual instrument in this file, the block's
/// own address exposed to Dart, DOES NOT EXIST for these two. The shim mallocs
/// `zd_matching_context_t` and `zd_subscriber_context_t` and hands them to
/// canon; Dart never sees an address, and this seed adds no accessor for one.
///
/// The other fallback in this file — a same-size proxy allocated per cycle —
/// is measured NON-discriminating at the size class in question. This file's
/// own comments record both failures: a 32-byte proxy swamped by declare churn
/// (13 distinct fixed vs 6 leaking, the leak making the assertion pass MORE
/// easily) and a ~48-byte block a coin toss with `Session.open` in the loop
/// (16 vs 20, "a margin of 4, which is not an instrument"). Both new contexts
/// are a single `Dart_Port_DL` — EIGHT bytes, the busiest size class in the
/// process. A proxy there would be worse than either.
///
/// So the legs below take the **interposition** form the amended criterion
/// authorizes, using the mechanism this file already established for Group E:
/// an LD_PRELOAD that counts `malloc`/`free` for one size class, filtered to
/// allocations whose CALLER is libzenoh_dart.so. That filter is what keeps
/// Dart's and canon's own 8-byte traffic out of the number, and it is why this
/// instrument discriminates where a proxy cannot.
///
/// ═══ CALIBRATION, measured at implementation time (2026-08-19) ═══
///
/// Each leg run against correct code and against a build with the matching
/// `free()` deleted — a temporary local edit, never committed:
///
///   matching, 20 entity cycles   correct: allocs=20 frees=20 outstanding=0
///                                leaking: allocs=20 frees= 0 outstanding=20
///   detect,   10 session cycles  correct: allocs=20 frees=20 outstanding=0
///                                leaking: allocs=20 frees=10 outstanding=10
///
/// Total separation in both, with no margin to argue about. That is the
/// outcome that authorizes these as counting legs rather than as the
/// structural review the amended criterion would otherwise require.
///
/// One instrument-calibration note, because it cost a wrong reading: the
/// harness must NOT call `exit()`. Dart's `exit` does not unwind the process,
/// so the counter's destructor never runs and the leg reports `allocs=0` —
/// a zero that reads exactly like a clean run.
/// Seed #10 — the encoding carrier's allocations, counted on BOTH sides.
///
/// ⚠️ THE INSTRUMENT HAD TO BE EXTENDED BEFORE IT COULD SEE THIS, and the
/// measurement that forced it is worth stating: the counter tracked `malloc`
/// only, filtered to callers inside libzenoh_dart.so. The send-side buffers are
/// allocated by DART (`package:ffi`'s calloc), so they were invisible on both
/// axes — five deliberately leaked blocks read `outstanding=0`, a clean count
/// on a leaking program. `calloc` is now intercepted and `ZD_COUNT_CALLER`
/// makes the caller filter optional.
///
/// TWO FURTHER PROPERTIES OF THE INSTRUMENT, both measured, both load-bearing
/// for the size classes below:
///
///  * `dladdr` resolves NO shared object for the Dart-side allocation sites, so
///    they can never be caller-filtered. The size class has to do all the work.
///  * Dart's FFI allocator serves SMALL blocks from an internal pool that never
///    reaches libc. Measured: a 200-byte `calloc<Uint8>` is invisible to the
///    counter, 512 is visible but crowded, 768 and 1021 are visible and clean.
///    A small fixture here would silently measure nothing.
void _encodingCarrierCountingGroup() {
  group('Seed #10 — the encoding carrier, counted', () {
    late Directory tmp;
    late String counterPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_enccount');
      counterPath = '${tmp.path}/shim_alloc_counter.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-o',
        counterPath,
        'test/helpers/shim_alloc_counter.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    /// Runs the encoding cycle harness under the counter and returns its
    /// report for the harness process itself.
    Future<({int allocs, int frees, int outstanding})> runCycles(
      String mode,
      int n, {
      required int size,
      String? caller,
    }) async {
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/encoding_cycle_harness.dart', mode, '$n'],
        environment: {
          'ZD_COUNT_SIZE': '$size',
          'ZD_COUNT_CALLER': caller ?? 'libzenoh_dart.so',
          'LD_PRELOAD': counterPath,
        },
      );
      final all = '${r.stdout}${r.stderr}';
      expect(
        all,
        contains('HARNESS_DONE $mode $n'),
        reason: 'the harness did not complete its cycles:\n$all',
      );
      // The launcher processes inherit LD_PRELOAD and each print a line of
      // their own; they allocate nothing in this class, so the one line with a
      // non-zero `allocs` is the harness's. Picked by that property rather than
      // by position, which would be a guess about the process tree.
      final pattern = RegExp(
        'SHIM_ALLOC_COUNTER size=$size allocs=(\\d+) frees=(\\d+) '
        r'outstanding=(\d+) overflow=(\d+)',
      );
      final reports = pattern
          .allMatches(all)
          .where((m) => m.group(1) != '0')
          .toList();
      expect(
        reports,
        hasLength(1),
        reason: 'expected exactly one counting process, got:\n$all',
      );
      final m = reports.single;
      // overflow=1 means the tracking table filled and the numbers are NOT
      // trustworthy. A truncated count reads exactly like a clean one, so this
      // fails the cell rather than being quietly accepted.
      expect(m.group(4), equals('0'), reason: 'counter table overflowed');
      return (
        allocs: int.parse(m.group(1)!),
        frees: int.parse(m.group(2)!),
        outstanding: int.parse(m.group(3)!),
      );
    }

    // ⚠️ THE SEND LEG IS DRIVEN ON THE THROW PATH, DELIBERATELY, and this is
    // the one design choice in this group worth reading.
    //
    // On the SUCCESS path the size class is crowded: zenoh copies the encoding
    // itself, measured at five tracked allocations per cycle against the two
    // that are ours, and `outstanding` drifts with in-flight state at process
    // exit (0 at n=20, 24 at n=60). Nothing there is attributable.
    //
    // On the THROW path nothing reaches the wire, so the class contains ONLY
    // our two buffers — `allocs` is exactly 2N, which is itself the proof that
    // the count is ours. And it is the STRONGER property: releasing on the
    // happy path is the easy case; releasing when the key expression is refused
    // AFTER both buffers are live is what the outer `finally` exists for. If
    // the release sat inside the `_withKeyExprArg` closure — which is never
    // entered on this path — both buffers would leak every cycle and no
    // behavioural cell would notice.
    test('the send buffers are released when the call throws', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the counter');
        return;
      }
      // Measured 2026-08-21, both ways:
      //   fixed:   n=20 -> 40/40/0     n=60 -> 120/120/0
      //   leaking: n=20 -> 40/0/40     (the two calloc.free deleted)
      final small = await runCycles('send-throw', 20, size: 1021, caller: '*');
      expect(small.allocs, equals(40), reason: 'two buffers per cycle');
      expect(small.outstanding, isZero);

      final large = await runCycles('send-throw', 60, size: 1021, caller: '*');
      expect(large.allocs, equals(120));
      expect(large.outstanding, isZero);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the receive extractor buffer is released per tryRecv', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the counter');
        return;
      }
      // The default caller filter is exactly right here: these ARE allocated
      // inside libzenoh_dart.so, so the filter selects them and the size class
      // is only a second sieve. One per delivered sample.
      //
      // Measured 2026-08-21, both ways:
      //   fixed:   n=40 -> 40/40/0
      //   leaking: n=40 -> 40/0/40   (the malloc.free in pull_subscriber
      //                               deleted)
      final r = await runCycles('recv', 40, size: 202);
      expect(r.allocs, equals(40), reason: 'one extractor buffer per sample');
      expect(r.outstanding, isZero);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an abandoned tryRecv result still releases', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the counter');
        return;
      }
      // The consumer drops the RecvData without reading it. The shim's buffers
      // are released inside tryRecv's own finally either way, which is the
      // property being counted — an abandoned result must not strand them.
      final r = await runCycles('recv-abandon', 40, size: 202);
      expect(r.allocs, equals(40));
      expect(r.outstanding, isZero);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

void _shimContextCountingGroup() {
  // ⚠️ THE GATE BELOW IS NOT OPTIONAL, and it is written trailing so the body
  // keeps this file's indentation. Every cell here spawns a harness that
  // declares an ADVANCED entity, so under the stable variant the child dies on
  // requireUnstable() before printing anything — measured on the matrix's
  // stable leg: three reds whose cause was the absent gate, not the counter.
  // Same rule as the miss injector's group one file over, which links against
  // the unstable native for the same reason.
  group(
    'Seed #8 — shim context blocks, counted',
    () {
      late Directory tmp;
      late String counterPath;
      var haveClang = false;

      setUpAll(() async {
        tmp = await Directory.systemTemp.createTemp('zd_ctxcount');
        counterPath = '${tmp.path}/shim_alloc_counter.so';
        final build = await Process.run('clang', [
          '-shared',
          '-fPIC',
          '-O0',
          '-o',
          counterPath,
          'test/helpers/shim_alloc_counter.c',
          '-ldl',
        ]);
        haveClang = build.exitCode == 0;
      });

      tearDownAll(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      /// Runs the cycle harness under the counter and returns its reported
      /// `outstanding` for the harness process itself.
      ///
      /// The `fvm`/launcher processes inherit LD_PRELOAD too and each print a
      /// line of their own; they allocate nothing from libzenoh_dart.so, so the
      /// one line with a non-zero `allocs` is the harness's. Picking it by that
      /// property rather than by position is deliberate — position would be a
      /// guess about the launcher's process tree.
      Future<({int allocs, int frees, int outstanding})> runCycles(
        String mode,
        int n, {
        // ⛔ PER MODE, because the two modes count DIFFERENT STRUCTS. `matching`
        // counts the matching-listener context (8 bytes); `detect` counts
        // `zd_subscriber_context_t`, which seed [10a] grew from 8 to 16 by
        // adding an `int retain_payload`. One hardcoded size cannot serve both:
        // at 8 the detect legs matched NOTHING and reported allocs=0, and at 16
        // the matching leg does the same. A clean zero from an instrument
        // pointed at the wrong size class looks exactly like a passing count
        // until the cell's own filter catches it.
        required int contextSize,
      }) async {
        final r = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'test/helpers/context_cycle_harness.dart', mode, '$n'],
          environment: {
            // ⛔ 16, NOT 8 — AND THIS NUMBER TRACKS A STRUCT, so it moves when
            // that struct does. `zd_subscriber_context_t` is what the detect
            // path allocates, and seed [10a] added an `int retain_payload` to
            // it: sizeof went 8 -> 16 (8 for the port, 4 for the flag, padded).
            //
            // Left at 8 the counter matched NOTHING on this path — it reported
            // `allocs=0 frees=0`, the cell's filter found no counting process,
            // and it failed with "expected exactly one counting process". A
            // clean zero from an instrument pointed at the wrong size class.
            //
            // ⚠️ Recalibrated, NOT widened: widening to a range would let a real
            // leak of one context hide inside it, which is the same trade the
            // exclusion below refused for a different reason.
            'ZD_COUNT_SIZE': '$contextSize',
            // ⚠️ Kept, though the 8-byte session block no longer collides with
            // the 16-byte class. Removing it is a separate judgement from this
            // repair, and a redundant exclusion costs nothing.
            //
            // Its original reason: zd_open_session_async
            // allocates a z_owned_session_t of exactly EIGHT bytes from inside
            // libzenoh_dart.so -- the counter's own size class and shared
            // object. Without this every session open counted as a context and
            // these cells read one high per open (measured 21/20, 30/20, 11/10).
            // Excluding at the site keeps `allocs` meaning "contexts", rather
            // than widening the expected numbers into a total that could absorb
            // a real leak of one against the other.
            'ZD_COUNT_EXCLUDE_SYM': 'zd_open_session_async',
            'LD_PRELOAD': counterPath,
          },
        );
        final all = '${r.stdout}${r.stderr}';
        expect(
          all,
          contains('HARNESS_DONE $mode $n'),
          reason: 'the harness did not complete its cycles:\n$all',
        );
        // ⚠️ The size in this pattern must track ZD_COUNT_SIZE above. It was
        // hardcoded to 8 and silently stopped matching when the class moved,
        // which reads as "no counting process" rather than as a mismatch.
        final pattern = RegExp(
          'SHIM_ALLOC_COUNTER size=$contextSize '
          r'allocs=(\d+) frees=(\d+) outstanding=(\d+) overflow=(\d+)',
        );
        final reports = pattern
            .allMatches(all)
            .where((m) => m.group(1) != '0')
            .toList();
        expect(
          reports,
          hasLength(1),
          reason: 'expected exactly one counting process, got:\n$all',
        );
        final m = reports.single;
        expect(m.group(4), equals('0'), reason: 'counter table overflowed');
        return (
          allocs: int.parse(m.group(1)!),
          frees: int.parse(m.group(2)!),
          outstanding: int.parse(m.group(3)!),
        );
      }

      // markTestSkipped rather than fail-loud here, and the distinction is the
      // one the seed draws: the miss-injection cell is the SOLE coverage of a
      // bridge with a recorded zero-coverage debt, so it must never skip. These
      // are supplementary resource legs beside behavioural cells that already
      // run, which is the case this file's Group E already treats this way.
      test('the matching context is reclaimed per ENTITY cycle', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the counter');
          return;
        }
        final r = await runCycles('matching', 20, contextSize: 8);
        // Correct here because _zd_matching_drop runs at publisher drop, exactly
        // as it does for the two shipped consumers of the same bridge.
        // Measured: 20/20/0 fixed, 20/0/20 with the free deleted.
        expect(r.allocs, equals(20));
        expect(r.outstanding, isZero);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('the detect context is reclaimed per SESSION cycle', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the counter');
          return;
        }
        // Two tracked blocks per cycle: the advanced subscriber's own sample
        // context and the detect context. Both must come back.
        //
        // The harness awaits the null SENTINEL before each cycle ends, not
        // `close()` returning. The free happens inside
        // _zd_sample_drop_with_sentinel, which canon invokes when it drops the
        // background closure, and nothing measures that this has finished by the
        // time Session.close() returns — gating on the return would let the next
        // cycle allocate before the previous block came back and read high on
        // correct code.
        //
        // Measured: 20/20/0 fixed, 20/10/10 with the sentinel drop's free
        // deleted.
        final r = await runCycles('detect', 10, contextSize: 16);
        expect(r.allocs, equals(20));
        expect(r.outstanding, isZero);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('an entity-cycle leg on the detect context would be WRONG', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the counter');
          return;
        }
        // The trap, measured rather than asserted. Ten entity cycles with the
        // session left open leave TEN blocks outstanding on CORRECT code,
        // because canon binds the detect listener to the session and dropping
        // the advanced subscriber does not release it. Written as a leak
        // assertion, an entity-cycle leg would fail on code behaving exactly as
        // canon documents — which is why the leg above closes the session.
        final r = await runCycles('detect-entity', 10, contextSize: 16);
        expect(r.outstanding, equals(10));
      }, timeout: const Timeout(Duration(minutes: 2)));

      // ⚠️ WHAT IS NOT COUNTED HERE, and why, so the absences are decisions.
      //
      // The ZD_DECLARE_EALLOC arms of both new entries have NO SELECTIVE DRIVER.
      // test/helpers/malloc_fail_injector.c selects by size THRESHOLD, and both
      // new contexts share their 8-byte class with the advanced subscriber's own
      // context, which is allocated first — so the first induced failure is
      // always the wrong one. These arms are covered structurally instead: the rc
      // mapping and the teardown ordering are gate-reviewable. An nth-allocation
      // mode on the injector would supply the driver; adding one is a bonus, not
      // an obligation of this seed.
      //
      // AdvancedSubscriber.keyExpr adds no heap block class at all — it is a
      // cached Dart String — so criterion H is n/a for it rather than skipped.
      //
      // BOTH failure directions are reportable, not just the false green. If one
      // of the legs above ever reads high on code believed correct, that is a
      // churn-swamped FALSE RED — an instrument finding — and the answer is to
      // report it and fall back to the structural form, never to widen a bound
      // until it passes. The symmetric case, an injected defect that fails to go
      // red, is a false green and is reported the same way.
    },
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
  );
}

/// Riders S-7 and S-9: the loader's variant selector.
void _variantOverrideGroup() {
  group('Riders S-7/S-9 — ZENOH_DART_VARIANT selection', () {
    Future<String> runLoader(String? variant) async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/variant_override_harness.dart'],
        environment: variant == null ? null : {'ZENOH_DART_VARIANT': variant},
      );
      return '${result.stdout}${result.stderr}';
    }

    test('a valid variant still loads (control)', () async {
      // Without this, "it threw" below proves nothing — the harness might be
      // failing for a reason that has nothing to do with the override.
      final out = await runLoader('unstable');
      expect(out, contains('LOADED='));
      expect(out, contains('/unstable/'));
    });

    test(
      'a typo throws instead of silently delivering another variant',
      () async {
        // RED LEG (pre-fix): `stbale` was interpolated into a path that never
        // existed, the probe fell through to the build hook's staged copy, and
        // the process loaded whichever variant the toolchain had selected —
        // printing LOADED=... with no diagnostic at all.
        final out = await runLoader('stbale');
        expect(out, contains('THREW='));
        expect(out, contains('stbale'));
        expect(out, isNot(contains('LOADED=')));
      },
    );

    test(
      'a malformed override surfaces instead of demoting to CWD probing',
      () async {
        // S-9: a value containing `?` or `#` made File.fromUri throw
        // ArgumentError, which the over-broad `on Object catch (_)` swallowed.
        // RED LEG (pre-fix): swallowed, then silently demoted to CWD probing.
        final out = await runLoader('stable?evil');
        expect(out, contains('THREW='));
        expect(out, isNot(contains('LOADED=')));
      },
    );

    test('a valid but unbuilt variant throws rather than falling through', () async {
      // Nothing is staged under native/linux/x86_64/<v>/ for a variant that
      // was never built, so the request cannot be honoured. Falling through to
      // the hook output would silently hand back the other variant.
      final tmp = await Directory.systemTemp.createTemp('zd_variant');
      addTearDown(() => tmp.delete(recursive: true));

      // Run from a directory with no package resolution and no staged output.
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          '${Directory.current.path}/test/helpers/variant_override_harness.dart',
        ],
        environment: {'ZENOH_DART_VARIANT': 'stable'},
        workingDirectory: tmp.path,
      );
      final out = '${result.stdout}${result.stderr}';
      // Either the loader refuses, or package resolution still finds the
      // staged stable build — both are correct; what must NOT happen is
      // loading a path that is not the stable variant.
      expect(out, isNot(contains('/unstable/')));
    });
  });
}

/// Group C: `ZBytes.slices` abandoned mid-iteration.
void _slicesGroup() {
  group('Group C — abandoned slice iteration', () {
    test('abandoning slices does not strand the native iterator structs', () {
      // Counting ABANDONS would be behavioural. This counts blocks: the two
      // native structs are the same size class as the probes freed just
      // before each cycle, so a leak takes them.
      const cycles = 50;
      final iterSize = bindings.zd_bytes_slice_iterator_sizeof();
      final addresses = <int>{};
      var abandoned = 0;

      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(iterSize);
        addresses.add(probe.address);
        calloc.free(probe);

        final bytes = ZBytes.fromString('slice-abandon-probe-$i');
        // `.first` is the sharpest form: it takes one element and walks away.
        // A sync* generator's finally never runs for that iterator.
        expect(bytes.slices.first, isNotEmpty);
        abandoned++;
        bytes.dispose();
      }

      expect(abandoned, cycles, reason: 'every cycle must have abandoned');
      // MEASURED both ways (50 cycles): sync* 50 distinct, materialized 3.
      expect(addresses.length, lessThan(10));
    });

    test('slices still yields every fragment, in order', () {
      final bytes = ZBytes.fromString('hello world');
      addTearDown(bytes.dispose);
      final joined = bytes.slices.expand((s) => s).toList();
      expect(joined, equals(bytes.toBytes()));
    });
  });
}

/// Group B: an operational throw between an allocation and its release.
///
/// Counting THROWS would prove the throw happened, not that the block was
/// released — so each leg counts BLOCKS. The leaked blocks are all internal,
/// with no address the API exposes, so they are probed the way
/// `config_test.dart` probes the internal config: allocate an observable block
/// of the same size class, free it, run one throwing cycle, and see whether
/// the next cycle gets that block back. Leaking => a fresh block every cycle.
void _throwPathGroup() {
  group('Group B — throw between allocation and release', () {
    // A deliberately odd length, so the probe lands in a size class the rest
    // of the process is not churning through.
    final longMime = 'application/x-zenoh-dart-probe-${'a' * 97}';

    test('Session.open does not strand its slot when the config throws', () async {
      // ⚠️ RETARGETED FOR THE OFFLOAD. This leg used to carry a second
      // assertion: a `calloc<Uint8>(zd_session_sizeof())` probe per cycle,
      // watching whether the address of a stranded DART-SIDE session slot got
      // reused (`expect(addresses.length, lessThan(35))`, measured 49 distinct
      // pre-fix against 9-18 fixed).
      //
      // ⛔ THAT PREMISE IS GONE, NOT MERELY PERTURBED. `Session.open` no longer
      // allocates a Dart-side slot at all -- the block is shim-malloc'd and
      // shim-freed at zd_session_close_drop -- so there is nothing for a Dart
      // probe to be stranded by, and the assertion would now measure only how
      // many glibc arenas the tokio pool happened to use. Its fixed-side count
      // was already recorded as "a draw" for that reason.
      //
      // The resource question moved to an instrument that can still answer it:
      // _offloadedOpenOwnershipGroup counts the real shim blocks over 200
      // cycles under LD_PRELOAD, calibrated both ways. What stays HERE is the
      // behaviour that instrument cannot see -- that a spent config throws
      // SYNCHRONOUSLY, 50 times running.
      const cycles = 50;
      var throws = 0;

      for (var i = 0; i < cycles; i++) {
        // A config consumed by a previous open: nativePtr throws StateError.
        final spent = Config();
        (await Session.open(config: spent)).close();

        // ⚠️ DELIBERATELY A TEAR-OFF, AND DELIBERATELY NOT AWAITED. This is
        // the cell the retype could have turned falsely green, so it says why
        // it still discriminates: `Session.open` is NOT an `async` body, so
        // the spent-config check runs before any future exists and throws
        // SYNCHRONOUSLY -- which is what `throwsA` on a callback catches. Had
        // `open` been written `async`, the same line would still compile, the
        // tear-off would return a rejected future instead of throwing, and
        // `throwsA` would report `Instance of Future` rather than a
        // StateError. That is a red, not a false green -- but only because
        // the matcher names the class. A cell asserting merely "something
        // threw" would pass either way.
        expect(() => Session.open(config: spent), throwsA(isA<StateError>()));
        throws++;
      }

      expect(throws, cycles, reason: 'every cycle must have thrown');
    });

    test('Session.put does not strand the encoding string when the key '
        'expression is invalid', () async {
      const cycles = 50;
      final session = await Session.open(
        config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
      );
      addTearDown(session.close);

      final addresses = <int>{};
      var throws = 0;
      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(longMime.length + 1);
        addresses.add(probe.address);
        calloc.free(probe);

        expect(
          () => session.put('', 'value', encoding: Encoding(longMime)),
          throwsA(isA<ZenohException>()),
        );
        throws++;
      }

      expect(throws, cycles);
      // MEASURED both ways (50 cycles): pre-fix 50 distinct, fixed 1.
      expect(addresses.length, lessThan(10));
    });

    test('Publisher.put does not strand its payload when the attachment '
        'is disposed', () async {
      const cycles = 50;
      final session = await Session.open(
        config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
      );
      addTearDown(session.close);
      final publisher = session.declarePublisher('zenoh/dart/own/b/pub');
      addTearDown(publisher.close);

      final bytesWrapperSize = bindings.zd_bytes_sizeof();
      final addresses = <int>{};
      var throws = 0;
      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(bytesWrapperSize);
        addresses.add(probe.address);
        calloc.free(probe);

        final attachment = ZBytes.fromString('att')..dispose();
        expect(
          () => publisher.put('value', attachment: attachment),
          throwsA(isA<StateError>()),
        );
        throws++;
      }

      expect(throws, cycles);
      // Pre-fix the internally-created payload ZBytes wrapper was stranded on
      // every throw — nothing else held a reference to it.
      // MEASURED both ways (50 cycles): pre-fix 49 distinct, fixed 1.
      expect(addresses.length, lessThan(10));
    });

    test('Session.get closes its reply channel when the payload throws', () async {
      // F12 is a PORT leak, not a heap one, so the instrument is different: an
      // open ReceivePort keeps the isolate alive, and no native sentinel can
      // ever arrive because zd_get never ran. The observable consequence is a
      // process that reaches the end of main() and still never exits.
      //
      // Started rather than run, with a kill on timeout: the RED state is a
      // hang, and a hang must present as a failing test rather than as a
      // wedged suite.
      final proc = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/helpers/get_throw_exit_harness.dart',
      ]);
      final out = StringBuffer();
      proc.stdout.transform(utf8.decoder).listen(out.write);
      proc.stderr.transform(utf8.decoder).listen(out.write);

      final exitCode = await proc.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      // The throw itself still happens on both legs — proving the harness
      // exercised the path rather than skipping it.
      expect(out.toString(), contains('THREW'));
      // MEASURED both ways: pre-fix the harness prints THREW and EXITING and
      // then never terminates (killed at 25 s, signal 143); fixed, exit 0.
      expect(
        exitCode,
        0,
        reason:
            'a stranded ReceivePort keeps the isolate alive, so the '
            'process never exits',
      );
    });
  });
}

/// Group E's live leg: a remote-length-driven `malloc` guard, driven under an
/// INDUCED allocation failure.
///
/// The failure has to be induced, not waited for. A 1 GiB `malloc` succeeds on
/// 64-bit Linux with overcommit, `MALLOC_PERTURB_` never induces failure at
/// all, and an `ulimit -v` tight enough to make our allocation fail makes
/// canon's fail first — Rust's allocator ABORTS instead of returning NULL, so
/// the process dies inside zenoh before the shim is reached (measured: a
/// 400 MB payload under `ulimit -v 2000000` prints "memory allocation of
/// 419430400 bytes failed / Aborted (core dumped)").
///
/// So the failure is injected surgically: an LD_PRELOAD interposer fails
/// `malloc` only when the caller is libzenoh_dart.so and the request is over a
/// threshold. See test/helpers/malloc_fail_injector.c.
void _allocGuardGroup() {
  group('Group E — induced allocation failure', () {
    late Directory tmp;
    late String injectorPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_allocguard');
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

    Future<ProcessResult> runHarness({required bool injected}) {
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/alloc_guard_harness.dart', '1048576'],
        environment: injected
            ? {'ZD_FAIL_MALLOC_OVER': '600000', 'LD_PRELOAD': injectorPath}
            : null,
      );
    }

    // THE LIVE-FIRE CONTROL, now its own declaration.
    //
    // It is not decoration. The marker this group reads changed with seed #5:
    // the harness used to print `HARNESS_RECV=null` on the guarded path,
    // because tryRecv() returned `null` for an allocation failure exactly as
    // it did for an empty buffer. That collapse is what the seed retires, so
    // the guarded path now THROWS and the harness prints HARNESS_THREW.
    //
    // A marker that fires unconditionally would pass the leg below while
    // proving nothing -- the "check the control" case. This run establishes
    // that HARNESS_THREW is absent when nothing is injected, so its presence
    // in the injected run is attributable to the injected failure.
    test(
      'the alloc-guard harness discriminates: no injection, no throw',
      () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the injector');
          return;
        }

        final control = await runHarness(injected: false);
        final controlOut = '${control.stdout}${control.stderr}';

        // The sample really arrived, at its full remote-driven size.
        expect(controlOut, contains('HARNESS_RECV=1048576'));
        expect(controlOut, contains('HARNESS_DONE'));
        expect(controlOut, isNot(contains('INJECTOR_FIRED')));
        // The discriminating half: the new marker stays silent.
        expect(
          controlOut,
          isNot(contains('HARNESS_THREW')),
          reason: 'the thrown-form marker must fire only on a real failure',
        );
        expect(control.exitCode, 0);
      },
    );

    test('a remote-length-driven malloc failure throws, and the process '
        'survives', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }

      final injectedRun = await runHarness(injected: true);
      final out = '${injectedRun.stdout}${injectedRun.stderr}';

      // Positive control on the instrument: the branch under test was entered.
      // Without this, a harness that simply never allocated would "pass".
      expect(
        out,
        contains('INJECTOR_FIRED size=1048576'),
        reason: 'the injector must actually have failed the shim allocation',
      );
      // The guard converted the NULL into a THROWN ZenohException -- seed #5's
      // S3 line: canon's channel STATES are variants, a call failure is an
      // exception. Before the retype this same leg asserted
      // `HARNESS_RECV=null`, i.e. an out-of-memory presenting to the caller as
      // an ordinary empty buffer.
      expect(out, contains('HARNESS_THREW=ZenohException'));
      expect(out, isNot(contains('HARNESS_RECV=')));
      // ...and the process survived to the end.
      //
      // RED LEG, measured on the pre-guard shim: the same run printed
      //   INJECTOR_FIRED size=1048576
      //   si_signo=Segmentation fault(11), si_code=SEGV_MAPERR(1),
      //   si_addr=(nil) / Aborted (core dumped)
      // -- the induced NULL written straight through by the memcpy.
      expect(out, contains('HARNESS_DONE'));
      expect(injectedRun.exitCode, 0);
    });

    // -----------------------------------------------------------------
    // Seed #9 — the zid collection-allocation failure arm, driven.
    //
    // The enumeration's buffer grows by `realloc` INSIDE canon's closure, at a
    // size the network chooses. The closure is `void` and canon offers no
    // early stop, so the contract is: record the failure, let canon finish
    // calling, have the WRAPPER release the partial buffer, and report.
    //
    // ⚠️ THREE LINKED SESSIONS, AND THE INJECTOR ARMED AT EXACT SIZE 32 —
    // the ladder's SECOND rung, not its first. With a pair the listener
    // observes one id, the ladder runs `realloc(NULL, 16)` alone, and failing
    // it leaves `buf == NULL`: "the wrapper released the partial buffer"
    // degrades to a `free(NULL)` no-op and the cell would pass identically
    // against a wrapper that freed nothing. Three sessions give two observed
    // ids, so the failure fires with a LIVE 16-byte buffer that must be
    // released. Stated here so a later "simplification" back to a linked pair
    // cannot silently hollow this out.
    // -----------------------------------------------------------------

    Future<ProcessResult> runZidHarness({required bool injected}) {
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/zid_alloc_fail_harness.dart'],
        environment: injected
            // ZD_FAIL_MALLOC_OVER is deliberately left unset: only the realloc
            // arm is armed, so `malloc` is untouched anywhere in the process.
            ? {'ZD_FAIL_REALLOC_SIZE': '32', 'LD_PRELOAD': injectorPath}
            : null,
      );
    }

    // The no-injection control, its OWN declared cell rather than a clause
    // inside the injected one.
    test('the zid harness discriminates with nothing injected', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }

      final control = await runZidHarness(injected: false);
      final out = '${control.stdout}${control.stderr}';

      // HARNESS_ZIDS=2 is not decoration: it is the PRECONDITION the arming
      // size depends on. Two observed ids means the growth ladder reached a
      // second rung, so there is a live buffer for the injected run to have
      // to release. A control reading 1 would silently invalidate the cell
      // below.
      expect(out, contains('HARNESS_ZIDS=2'));
      expect(out, contains('HARNESS_DONE'));
      expect(out, isNot(contains('HARNESS_NOCONVERGE')));
      expect(out, isNot(contains('INJECTOR_FIRED')));
      expect(
        out,
        isNot(contains('HARNESS_THREW')),
        reason: 'the thrown-form marker must fire only on a real failure',
      );
      expect(control.exitCode, 0);
    });

    test('an injected collection-allocation failure throws, and the process '
        'survives', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }

      final injectedRun = await runZidHarness(injected: true);
      final out = '${injectedRun.stdout}${injectedRun.stderr}';

      // Positive control on the instrument: the branch under test was entered.
      expect(
        out,
        contains('INJECTOR_FIRED realloc size=32'),
        reason: 'the injector must actually have failed the growth allocation',
      );
      // The shim recorded the flag, canon kept calling, the wrapper released
      // the partial buffer and reported 11 -- its own "an allocation the shim
      // itself needed failed" code, reused rather than minted.
      expect(out, contains('HARNESS_THREW=ZenohException'));
      expect(out, contains('(code: 11)'));
      // ...and the process survived to the end.
      //
      // RED LEG, MEASURED at this seed on a deliberately unguarded shim (the
      // `if (!tmp) { ctx->failed = 1; return; }` replaced by a bare
      // `ctx->buf = realloc(ctx->buf, ...)`; temporary local edit, never
      // committed). The same run printed:
      //   INJECTOR_FIRED realloc size=32
      //   si_signo=Segmentation fault(11), si_code=SEGV_MAPERR(1),
      //   si_addr=0x10
      // and exited 134 with no HARNESS_DONE -- the lost pointer written
      // through at NULL+16, which is exactly the second id's slot. Total
      // separation from the assertions above.
      expect(out, contains('HARNESS_DONE'));
      expect(injectedRun.exitCode, 0);
    });

    test(
      'the injected failure is not reported as an empty enumeration',
      () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the injector');
          return;
        }

        final injectedRun = await runZidHarness(injected: true);
        final out = '${injectedRun.stdout}${injectedRun.stderr}';

        expect(out, contains('INJECTOR_FIRED realloc size=32'));
        // The conflation the superseded path had -- failure -> -1 -> a silent
        // [] -- cannot reappear on the new path. The success marker never
        // prints at all, so there is no count for a caller to mistake for an
        // answer.
        expect(
          out,
          isNot(contains('HARNESS_ZIDS=')),
          reason: 'a failed enumeration must never present as a result',
        );
      },
    );
  });

  // Declared key expressions (seed #3).
  //
  // ⚠️ THE INSTRUMENT'S REACH, stated rather than overclaimed. It counts
  // distinct addresses of the DART-`calloc`'d slot. A dispose() that frees the
  // slot but skips the native `zd_keyexpr_drop` leaks the Rust-side
  // allocation INVISIBLY -- the distinct count stays small either way. That
  // half is not countable by any leg in this file, and never has been: every
  // existing leg counts slots, and opaque native interiors were never in
  // reach. The native drop-half's evidence is CODE-LEVEL, read rather than
  // counted, and it is this:
  //
  //   dispose(), owned backing   -> zd_keyexpr_drop THEN calloc.free(_kePtr)
  //   dispose(), view backing    -> malloc.free(_nativeStr) THEN calloc.free
  //   undeclareFrom()            -> canon's z_undeclare_keyexpr already TOOK
  //                                 the value (that IS the native release),
  //                                 then calloc.free(_kePtr). No drop is owed
  //                                 on a gravestone.
  //   ctor / declareOn / concat / clone, rc != 0
  //                              -> canon wrote a gravestone, so there is no
  //                                 native value to drop; the slot is freed
  //                                 and nothing wraps the out-param.
  //
  // Every path that frees an owned backing's slot has released the native side
  // first. Each Then below claims only what the instrument can actually see.
  group('Declared key expression handle ownership', () {
    late Session session;
    late int keSlotSize;

    setUp(() async {
      session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      keSlotSize = bindings.zd_keyexpr_sizeof();
    });

    tearDown(() => session.close());

    test('a declare-then-undeclare cycle returns its blocks', () {
      // Observes the SLOT ITSELF, not a same-size probe. A probe was tried
      // first and measured NON-DISCRIMINATING here: 13 distinct fixed vs 6
      // leaking, i.e. the leak made `lessThan` pass MORE easily. Declaring
      // churns the arena enough to swamp a 32-byte proxy. The handle's own
      // address has no such problem -- if the slot is released, the next
      // declare reuses it.
      const cycles = 50;
      final addresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final declared = session.declareKeyExpr('zenoh/dart/own/ke/undecl');
        addresses.add(declared.nativePtr.address);
        session.undeclareKeyExpr(declared);
      }
      // MEASURED both ways (50 cycles), release removed = the Dart
      // `calloc.free(_kePtr)` in KeyExpr.undeclareFrom:
      //   removed -> 50 distinct   present -> 16 distinct
      expect(addresses.length, lessThan(35));
    });

    test('a declare-then-dispose cycle returns its Dart-side slots', () {
      const cycles = 50;
      final addresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final declared = session.declareKeyExpr('zenoh/dart/own/ke/drop');
        addresses.add(declared.nativePtr.address);
        declared.dispose();
      }
      // This proves dispose() frees THE DART-`calloc`'d SLOT rather than only
      // flipping a flag. It does NOT prove the native zd_keyexpr_drop ran --
      // that half is outside this instrument's reach (see the group comment).
      //
      // MEASURED both ways (50 cycles), release removed = the Dart
      // `calloc.free(_kePtr)` in KeyExpr.dispose:
      //   removed -> 50 distinct   present -> 13 distinct
      expect(addresses.length, lessThan(35));
    });

    test('a clone cycle returns both blocks', () {
      const cycles = 50;
      final sourceAddresses = <int>{};
      final cloneAddresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final source = KeyExpr('zenoh/dart/own/ke/clone');
        final copy = source.clone();
        sourceAddresses.add(source.nativePtr.address);
        cloneAddresses.add(copy.nativePtr.address);
        copy.dispose();
        source.dispose();
      }
      // MEASURED both ways (50 cycles), release removed = the Dart
      // `calloc.free(_kePtr)` in KeyExpr.dispose (which serves both backings):
      //   removed -> 50 / 50 distinct   present -> 1 / 1 distinct
      expect(sourceAddresses.length, lessThan(10));
      expect(cloneAddresses.length, lessThan(10));
    });

    test('the String path per-call temp does not accumulate on a CONVERTED op', () {
      // declareQueryable is one of the TWELVE ops this seed converted from a
      // string-taking shim signature to a loaned one, which is what the leak
      // mandate points at: those wrappers are new code with their own
      // allocation ordering. `put` would not meet the letter -- it was already
      // loaned before this seed.
      const cycles = 50;
      final addresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(bindings.zd_view_keyexpr_sizeof());
        addresses.add(probe.address);
        calloc.free(probe);

        session.declareQueryable('zenoh/dart/own/ke/temp').close();
      }
      // MEASURED both ways (50 cycles), release removed = `temp.dispose()` in
      // withLoanedKeyExpr's finally:
      //   removed -> 50 distinct   present -> 19-25 distinct (the declaration
      //   itself churns the arena, so the floor is not 1 here)
      expect(addresses.length, lessThan(40));
    });

    test('a failing compose does not accumulate', () {
      const cycles = 50;
      final addresses = <int>{};
      var throws = 0;
      final left = KeyExpr('foo/*');
      addTearDown(left.dispose);
      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(keSlotSize);
        addresses.add(probe.address);
        calloc.free(probe);

        expect(() => left.concat('*bar'), throwsA(isA<ZenohException>()));
        throws++;
      }
      // The throw count alone cannot see the leak -- both legs throw 50 times.
      expect(throws, cycles);
      // MEASURED both ways (50 cycles), release removed = `calloc.free(slot)`
      // on KeyExpr.concat's rc-failure path:
      //   removed -> 49 distinct   present -> 2 distinct
      expect(addresses.length, lessThan(10));
    });

    test('a rejected key expression does not accumulate', () {
      const cycles = 50;
      final addresses = <int>{};
      var throws = 0;
      for (var i = 0; i < cycles; i++) {
        final probe = calloc<Uint8>(bindings.zd_view_keyexpr_sizeof());
        addresses.add(probe.address);
        calloc.free(probe);

        expect(
          () => session.put('demo//x', 'value'),
          throwsA(isA<ZenohException>()),
        );
        throws++;
      }
      expect(throws, cycles);
      // MEASURED both ways (50 cycles), release removed = `calloc.free(_kePtr)`
      // on KeyExpr's constructor rc-failure path:
      //   removed -> 49 distinct   present -> 1 distinct
      expect(addresses.length, lessThan(10));
    });
  });

  // Key expression canonization (seed #4).
  //
  // ⚠️ THE INSTRUMENT'S REACH, stated rather than overclaimed. These legs see
  // the DART-side per-call blocks -- the writable input copy, the length cell
  // and the owned slot -- which is the whole of what the three new members
  // allocate. What no leg here can see is canon's interior allocation behind
  // `zd_keyexpr_drop`; that half is CODE-LEVEL evidence, read rather than
  // counted, exactly as the declared-key-expression group above says, and it
  // is this:
  //
  //   KeyExpr.isCanon      -> malloc.free(exprPtr) in a finally enclosing the
  //                           native call. Canon produces no owned value.
  //   KeyExpr.canonize     -> malloc.free(buf) + calloc.free(lenCell) in a
  //                           finally enclosing the call, the rc check AND the
  //                           decode. Canon produces no owned value.
  //   KeyExpr.autocanonize -> the slot is allocated last and freed on the
  //                           rc-failure path; on success it becomes an owned
  //                           backing whose native release is dispose()'s
  //                           zd_keyexpr_drop, already covered above. The
  //                           input copy and the length cell are released in
  //                           the outer finally on BOTH paths.
  //
  // 🔬 TWO probe classes, because one could not see everything.
  //
  // The small-block legs use a PAIRED probe (`_pairedProbeCycles`), and that
  // is load-bearing rather than decorative: with a SINGLE probe, removing
  // `calloc.free(lenCell)` from canonize measured 2 distinct -- i.e. GREEN
  // while leaking one block per cycle -- because the buffer freed in the same
  // cycle kept feeding the probe while the arena grew behind it. The paired
  // probe reads 51 for that same defect. The single-probe version of this leg
  // was written first, and it was a false green.
  //
  // The slot leg needs its own probe class: a 32-byte `z_owned_keyexpr_t`
  // slot lands in a different glibc size class from the 4-byte input copy, so
  // the small probe measured 2 distinct with the factory's rc-failure
  // `calloc.free(slot)` removed -- also a false green, also caught by running
  // the injection rather than by reasoning about it.
  group('Key expression canonization block ownership', () {
    test('repeated canonize calls do not accumulate their per-call blocks', () {
      const vector = 'a/**/**/c';
      final distinct = _pairedProbeCycles(
        vector.length + 1,
        () => KeyExpr.canonize(vector),
      );
      // MEASURED both ways (50 cycles), and both of this member's releases
      // were removed in turn, because the paired probe can see both:
      //   `malloc.free(buf)`        removed -> 52   present -> 3
      //   `calloc.free(lenCell)`    removed -> 51   present -> 3
      // Threshold at 15: the observed floor across every run of this group
      // was 4, and every injected leg cleared 50.
      expect(distinct, lessThan(15));
    });

    test('repeated isCanon calls do not accumulate', () {
      const vector = 'a/**/**/c';
      final distinct = _pairedProbeCycles(
        vector.length + 1,
        () => KeyExpr.isCanon(vector),
      );
      // MEASURED both ways (50 cycles), release removed =
      // `malloc.free(exprPtr)` in KeyExpr.isCanon's finally:
      //   removed -> 52 distinct   present -> 2 distinct
      expect(distinct, lessThan(15));
    });

    test('autocanonize construct-then-dispose cycles return their slots', () {
      final addresses = <int>{};
      for (var i = 0; i < _leakCycles; i++) {
        final ke = KeyExpr.autocanonize('a/**/**/c');
        addresses.add(ke.nativePtr.address);
        ke.dispose();
      }
      // Observes the SLOT ITSELF rather than a proxy, like the declared-key-
      // expression leg above. This proves dispose() frees the Dart-`calloc`'d
      // slot rather than only flipping a flag; it does NOT prove the native
      // zd_keyexpr_drop ran, which is outside this instrument's reach.
      //
      // MEASURED both ways (50 cycles), release removed =
      // `calloc.free(_kePtr)` in KeyExpr.dispose:
      //   removed -> 50 distinct   present -> 1 distinct
      expect(addresses.length, lessThan(15));
    });

    test('the canonize THROW path strands nothing', () {
      const vector = 'a?b';
      var throws = 0;
      final distinct = _pairedProbeCycles(vector.length + 1, () {
        expect(() => KeyExpr.canonize(vector), throwsA(isA<ZenohException>()));
        throws++;
      });
      // The throw count alone cannot see the leak -- it is 50 on both legs.
      // That is precisely why the address count is the evidence.
      expect(throws, _leakCycles);
      // MEASURED both ways (50 cycles). The defect injected here is not a
      // removal but a MISPLACEMENT, because that is what the outer-finally
      // rule actually prevents: `malloc.free(buf)` moved out of the finally to
      // just before the return, so it runs on success and is skipped on the
      // throw. The success leg stays green under that defect -- only this one
      // moves, which is the whole reason it exists:
      //   misplaced -> 53 distinct   in the finally -> 2 distinct
      expect(distinct, lessThan(15));
    });

    test('the autocanonize factory THROW path strands nothing', () {
      const vector = 'a?b';
      var throws = 0;

      // Three blocks are live when canon rejects -- the input copy, the length
      // cell and the slot -- and they do not all fit one probe class, so this
      // leg counts two.
      final small = _pairedProbeCycles(vector.length + 1, () {
        expect(
          () => KeyExpr.autocanonize(vector),
          throwsA(isA<ZenohException>()),
        );
        throws++;
      });

      final slotSize = bindings.zd_keyexpr_sizeof();
      final slots = <int>{};
      for (var i = 0; i < _leakCycles; i++) {
        final probe = calloc.allocate<Void>(slotSize);
        slots.add(probe.address);
        calloc.free(probe);

        expect(
          () => KeyExpr.autocanonize(vector),
          throwsA(isA<ZenohException>()),
        );
        throws++;
      }

      expect(throws, _leakCycles * 2);
      // MEASURED both ways (50 cycles each):
      //   `malloc.free(exprPtr)` in the factory's finally
      //                             removed -> 53 small   present -> 2 small
      //   `calloc.free(slot)` on the factory's rc-failure path
      //                             removed -> 50 slot    present -> 1 slot
      // Note the cross-check: the small probe read 2 with the SLOT release
      // removed, and the slot probe read 2 with the INPUT-COPY release
      // removed. Neither probe substitutes for the other.
      expect(small, lessThan(15));
      expect(slots.length, lessThan(15));
    });
  });
}

/// Cycles for every leak leg in this file's canonization group.
const _leakCycles = 50;

/// Runs [body] [_leakCycles] times, counting distinct addresses of a **paired**
/// same-size probe.
///
/// Paired rather than single, and the difference decides whether the leg works
/// at all. A single probe is blind to a leak that runs alongside a same-class
/// free in the same cycle: the block freed this cycle is handed straight back
/// to next cycle's probe, so the probe address never moves while the arena
/// grows behind it. Taking two blocks before releasing either forces the
/// second to come from fresh memory the moment anything is retained.
///
/// Measured, not assumed: with a single probe, canonize leaking its length
/// cell every cycle read 2 distinct addresses. With the pair, 51.
int _pairedProbeCycles(int probeSize, void Function() body) {
  final seen = <int>{};
  for (var i = 0; i < _leakCycles; i++) {
    final first = malloc<Uint8>(probeSize);
    final second = malloc<Uint8>(probeSize);
    seen
      ..add(first.address)
      ..add(second.address);
    malloc
      ..free(second)
      ..free(first);
    body();
  }
  return seen.length;
}

/// Spins the isolate without yielding to the event loop.
///
/// Deliberately a busy-wait, not a `Future.delayed`: the point is that Dart
/// CANNOT run the port listener while native threads keep posting, which is
/// the only way to observe a message sitting unparsed in the port queue.
void _blockIsolate(Duration duration) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {
    // spin
  }
}

/// Seed #5: the channel surface's new heap blocks.
///
/// ⚠️ WHY THESE COUNT INSTEAD OF ASSERTING. A resource defect is invisible to a
/// behavioural assertion. A leaked readiness-tee context neither throws nor
/// corrupts: every lifecycle cell in `pull_recv_test.dart` and
/// `pull_channel_test.dart` passes IDENTICALLY on leaking and on fixed code.
/// No assertion, at any position, can see it. So the discriminator is
/// observability class -- measure the resource, not the behaviour -- and the
/// measurement is DISTINCT BLOCK ADDRESSES over N cycles. Released => the
/// allocator hands the same address back. Leaked => every cycle needs a fresh
/// one.
///
/// ⚠️ THE INSTRUMENT'S REACH, stated rather than overclaimed. It sees the
/// Dart-`calloc`'d handler slot and the shim-`malloc`'d tee block -- the two
/// blocks this seed introduces. It does NOT see canon's opaque interiors: the
/// channel's own buffer, the subscriber's Rust-side state. Those were never in
/// reach of any leg in this file, and their evidence stays code-level. Each
/// Then below claims only what counting can actually show.
void _pullChannelOwnershipGroup() {
  group('Pull channel handle ownership (seed #5)', () {
    late Session session;

    setUp(() async {
      session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
    });

    tearDown(() => session.close());

    test('the tee context is released once per subscriber', () {
      const cycles = 50;
      final addresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final pull = session.declarePullSubscriber(
          'zenoh/dart/own/pull/tee',
          capacity: 4,
        );
        addresses.add(pull.teeAddressForTesting);
        pull.close();
      }
      // MEASURED BOTH WAYS, full-file run, release removed = the
      // `zd_pull_tee_drop` call in PullSubscriber.close:
      //   removed -> 50 distinct   present -> 16 distinct
      // A block that is never freed can never be reissued, so the leaking
      // count is exactly the cycle count by construction.
      expect(addresses.length, lessThan(35));
    });

    test('the tee context is released even when the session died first', () async {
      // THE OTHER ORDERING, and the one the design is shaped around. The
      // closure's drop callback deliberately does NOT free the tee block,
      // because it fires when the SESSION dies while a live Dart handle may
      // still arm. The free therefore has to come from close(), and this cell
      // is what shows the two paths compose rather than one of them dropping
      // the block on the floor.
      const cycles = 20;
      // ⚠️ THE SESSIONS ARE OPENED UP FRONT, and that is an instrument fix
      // rather than tidiness. With `Session.open` inside the loop, opening the
      // NEXT session churns the arena between one cycle's tee free and the
      // next cycle's tee malloc, so the block rarely comes back to the same
      // address. Measured that way: 16 distinct fixed vs 20 leaking -- a
      // margin of 4, which is not an instrument, it is a coin toss. Hoisting
      // the opens leaves only declare churn between free and reuse, exactly
      // as in the leg above.
      final owners = [
        for (var i = 0; i < cycles; i++)
          // Awaited IN the collection-for, so all `cycles` sessions are still
          // open before the measuring loop starts -- which is the instrument
          // the comment above describes, not a detail of the literal.
          await Session.open(
            config: Config()
              ..insertJson5('scouting/multicast/enabled', 'false')
              ..insertJson5('scouting/gossip/enabled', 'false'),
          ),
      ];
      final addresses = <int>{};
      var declared = 0;
      for (final owner in owners) {
        final pull = owner.declarePullSubscriber(
          'zenoh/dart/own/pull/tee-orphan',
          capacity: 4,
        );
        declared++;
        addresses.add(pull.teeAddressForTesting);
        // Producer dies FIRST: the drop callback runs here, and must not free.
        owner.close();
        // ...and the designated release runs here.
        pull.close();
      }
      // ⛔ THE ADDRESS INSTRUMENT IS DEAD ON THIS LEG SINCE THE OPEN WAS
      // OFFLOADED, and it is retired here rather than re-baselined.
      //
      // Its logic was: a block never freed can never be reissued, so a leak
      // reads EXACTLY `cycles`, and "was any address reused at all" is
      // therefore a sound discriminator. That held while the only churn
      // between a tee free and the next tee malloc was the declare. The
      // offloaded open added a 2024-byte worker block and an 8-byte session
      // block per open, and `close()` -- which runs INSIDE this loop -- now
      // frees the session block too. MEASURED over five full-file serial runs
      // after the offload: this leg read exactly 20 of 20 distinct in three of
      // them and passed in the others. A non-leaking run had become
      // indistinguishable from a leaking one, which is the definition of a
      // dead instrument, not a flaky one.
      //
      // ⚠️ AND IT IS NOT A LEAK. Measured directly with the counter, which is
      // immune to arena churn, over the same cycle shape:
      //   20 cycles -> allocs=20 frees=20 outstanding=0
      //   50 cycles -> allocs=50 frees=50 outstanding=0
      // The addresses are still collected and asserted non-empty, because a
      // run that declared nothing would otherwise pass this cell vacuously;
      // the leak question moved to `_offloadedOpenOwnershipGroup`, which
      // counts the real blocks and is calibrated both ways.
      // ⚠️ THE VACUITY GUARD IS THE ITERATION COUNT, NOT THE SET SIZE. These
      // are collected into a Set, so reuse COLLAPSES entries -- asserting the
      // set holds `cycles` addresses would demand that nothing was ever
      // reused, which is the exact opposite of what this leg used to want.
      expect(
        declared,
        equals(cycles),
        reason:
            'every cycle must have declared a pull subscriber; the '
            'RELEASE is measured by the counter, not by address reuse',
      );
      expect(addresses, isNotEmpty);
    });

    test('the fifo handler slot is released', () {
      const cycles = 50;
      final addresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final pull = session.declarePullSubscriber(
          'zenoh/dart/own/pull/fifo-slot',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addresses.add(pull.handlerAddressForTesting);
        pull.close();
      }
      // The fifo slot is a DIFFERENT size from the ring slot and is released
      // through a kind-dispatched entry, so it needs its own leg: a drop that
      // silently fell through to the ring branch would still release *a*
      // block, and only a fifo-specific count would notice.
      //
      // MEASURED BOTH WAYS with its OWN injection -- `calloc.free` of the
      // handler slot removed from close(), not the tee release, because the
      // tee is a different block and removing it moves this count by 2:
      //   removed -> 50 distinct   present -> 5 distinct
      expect(addresses.length, lessThan(15));
    });

    test('a failed declaration leaks nothing', () {
      // ALLOCATE-LAST means an invalid key expression is refused BEFORE any
      // slot, tee or port is claimed. A failed declare returns no handle whose
      // address could be read, so the observable is a probe.
      //
      // ⚠️ THE PAIRED probe, not a single one, and this file already measured
      // why: a single probe is blind to a leak running alongside a same-class
      // free in the same cycle, because the block freed this cycle is handed
      // straight back to next cycle's probe while the arena grows behind it.
      final distinct = _pairedProbeCycles(bindings.zd_subscriber_sizeof(), () {
        expect(
          () => session.declarePullSubscriber('bad//keyexpr', capacity: 4),
          throwsA(isA<ZenohException>()),
        );
      });
      // MEASURED BOTH WAYS with its own injection -- a slot claimed BEFORE
      // the key expression is validated, which is exactly the defect
      // allocate-last exists to prevent and the shape this path had before:
      //   allocate-first -> 51 distinct   allocate-last -> 24 distinct
      expect(distinct, lessThan(40));
    });
  });
}

/// The ReceivePort every PullSubscriber now owns.
///
/// A port that outlives its subscriber keeps the isolate alive, and the failure
/// mode is a HUNG process rather than a red assertion -- so the observable has
/// to be a child process that either returns from main or does not.
void _pullPortLifecycleGroup() {
  group('PullSubscriber ReceivePort lifecycle (seed #5)', () {
    test('a process that closes its pull subscribers exits', () async {
      // The probe is a COMMITTED helper under test/helpers/, not a script
      // written to a temp directory: a file outside the package cannot
      // resolve `package:zenoh_dart/...` at all, so a temp-file version fails
      // to compile rather than measuring anything. Same shape as
      // alloc_guard_harness.dart.
      //
      // If close() failed to close the ReceivePort, main would return and the
      // isolate would stay alive on the open port -- the process would HANG
      // here rather than fail an assertion. The timeout IS the assertion.
      final result =
          await Process.run(
            Platform.resolvedExecutable,
            ['run', 'test/helpers/pull_port_probe.dart'],
          ).timeout(
            const Duration(seconds: 90),
            onTimeout: () => fail(
              'the child process did not exit: a PullSubscriber ReceivePort '
              'outlived its subscriber and kept the isolate alive',
            ),
          );

      // Positive control: it got all the way through, so the exit is a real
      // exit and not an early crash that would also have "not hung".
      expect('${result.stdout}${result.stderr}', contains('PORT_PROBE_DONE'));
      expect(result.exitCode, 0);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

/// Seed #6: the heap blocks the query/reply channel surface introduces.
///
/// ⚠️ WHY THESE COUNT INSTEAD OF ASSERTING — the same reason seed #5's group
/// above does. A resource defect is invisible to a behavioural assertion: a
/// leaked handler slot, tee context or per-query wrapper neither throws nor
/// corrupts, and every lifecycle cell in `pull_replies_test.dart` and
/// `pull_queryable_test.dart` passes IDENTICALLY on leaking and on fixed code.
/// The discriminator is observability class — measure the resource, not the
/// behaviour — and the measurement is DISTINCT BLOCK ADDRESSES over N cycles.
/// Released => the allocator hands the same address back. Leaked => every cycle
/// needs a fresh one, so a leaking run reads EXACTLY the cycle count.
///
/// ⚠️ THE INSTRUMENT'S REACH, stated rather than overclaimed. It sees the
/// Dart-`calloc`'d handler and queryable slots, the shim-`malloc`'d tee blocks,
/// and the per-query wrappers. It does NOT see canon's opaque interiors — the
/// channel's own buffer, the queryable's Rust-side state. Those were never in
/// reach of any leg in this file, and each Then below claims only what counting
/// can actually show.
void _channelBlockOwnershipGroup() {
  group('Channel block ownership (seed #6)', () {
    late Session session;

    setUp(() async {
      session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
    });

    tearDown(() => session.close());

    test('a reply channel returns its handler slot and tee block', () {
      const cycles = 50;
      final handlers = <int>{};
      final tees = <int>{};
      for (var i = 0; i < cycles; i++) {
        final replies = session.pullGet(
          'zenoh/dart/own/s6/reply',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        handlers.add(replies.handlerAddressForTesting);
        tees.add(replies.teeAddressForTesting);
        replies.dispose();
      }
      // A block that is never freed can never be reissued, so a leaking run
      // reads exactly `cycles` on each set. Reuse at all is the discriminator.
      expect(handlers.length, lessThan(cycles));
      expect(tees.length, lessThan(cycles));
    });

    test('a ring reply channel returns its blocks too', () {
      // The two handler types are distinct and are released through
      // kind-matched entries, so a mismatch would show up on exactly one kind.
      const cycles = 50;
      final handlers = <int>{};
      final tees = <int>{};
      for (var i = 0; i < cycles; i++) {
        final replies = session.pullGet(
          'zenoh/dart/own/s6/reply-ring',
          kind: ChannelKind.ring,
          capacity: 4,
        );
        handlers.add(replies.handlerAddressForTesting);
        tees.add(replies.teeAddressForTesting);
        replies.dispose();
      }
      expect(handlers.length, lessThan(cycles));
      expect(tees.length, lessThan(cycles));
    });

    test('a query channel returns its handler slot and tee block', () {
      const cycles = 50;
      final handlers = <int>{};
      final tees = <int>{};
      for (var i = 0; i < cycles; i++) {
        final pull = session.declarePullQueryable(
          'zenoh/dart/own/s6/query',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        handlers.add(pull.handlerAddressForTesting);
        tees.add(pull.teeAddressForTesting);
        pull.close();
      }
      expect(handlers.length, lessThan(cycles));
      expect(tees.length, lessThan(cycles));
    });

    test('a pull liveliness subscriber returns its blocks, both kinds', () {
      const cycles = 30;
      for (final kind in ChannelKind.values) {
        final handlers = <int>{};
        final tees = <int>{};
        for (var i = 0; i < cycles; i++) {
          final pull = session.declarePullLivelinessSubscriber(
            'zenoh/dart/own/s6/live',
            kind: kind,
            capacity: 4,
          );
          handlers.add(pull.handlerAddressForTesting);
          tees.add(pull.teeAddressForTesting);
          pull.close();
        }
        expect(handlers.length, lessThan(cycles), reason: 'kind=$kind');
        expect(tees.length, lessThan(cycles), reason: 'kind=$kind');
      }
    });

    test('a failed channel declaration leaks nothing', () {
      // ALLOCATE-LAST on the failure path: a rejected key expression must not
      // strand the slots, and the shim must not strand the tee it never handed
      // over. Same shape as the seed #5 leg above.
      final distinct = _pairedProbeCycles(bindings.zd_queryable_sizeof(), () {
        expect(
          () => session.declarePullQueryable(
            'bad//keyexpr',
            kind: ChannelKind.fifo,
            capacity: 4,
          ),
          throwsA(isA<ZenohException>()),
        );
      });
      expect(distinct, lessThan(40));
    });
  });
}

/// Seed #6: the per-query wrapper on the PULL path.
///
/// The one block class on the query channel that is claimed per DELIVERED
/// value rather than per declaration — and the one the ownership rule's
/// allocator-side clause governs: the shim mallocs it inside `try_recv`, its
/// address rides back to Dart as a bare integer, and `Query.dispose()` hands it
/// to the shipped `zd_query_drop`. Nothing else can free it.
void _pullQueryWrapperOwnershipGroup() {
  group('Pull-path query wrapper ownership (seed #6, TCP 19396)', () {
    late Session hostSession;
    late Session getterSession;

    setUpAll(() async {
      hostSession = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19396"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      getterSession = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19396"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getterSession.close();
      hostSession.close();
    });

    test(
      'one wrapper block is claimed and released per delivered query',
      () async {
        const key = 'zenoh/dart/own/s6/wrapper';
        const cycles = 25;
        final pull = hostSession.declarePullQueryable(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final wrappers = <int>{};
        for (var i = 0; i < cycles; i++) {
          unawaited(
            getterSession
                .get(key, timeout: const Duration(seconds: 10))
                .toList(),
          );
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          var got = false;
          while (!got && DateTime.now().isBefore(deadline)) {
            final r = pull.tryRecv();
            if (r is RecvData<Query>) {
              got = true;
              // `handle` IS the wrapper's address.
              wrappers.add(r.value.handle);
              r.value
                ..reply(key, 'ack')
                ..dispose();
            } else {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          }
          expect(got, isTrue, reason: 'cycle $i saw no query');
        }

        // Released => reissued. A wrapper never freed can never come back, so a
        // leaking run reads exactly `cycles`.
        expect(wrappers.length, lessThan(cycles));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('queries left buffered at close do not diverge from a drained run', () async {
      // R-10's claim, measured: a query that was never recv'd is still in the
      // NATIVE channel, so the handler's own drop releases it and there is no
      // Dart-side undelivered set to maintain. The DRAINED run is the control —
      // without it, "the counts look fine" would be unanchored.
      const cycles = 15;

      Future<int> runCycles({required bool drain}) async {
        final handlers = <int>{};
        for (var i = 0; i < cycles; i++) {
          final key = 'zenoh/dart/own/s6/buffered/$drain';
          final pull = hostSession.declarePullQueryable(
            key,
            kind: ChannelKind.fifo,
            capacity: 4,
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
          unawaited(
            getterSession
                .get(key, timeout: const Duration(seconds: 2))
                .toList(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (drain) {
            final r = pull.tryRecv();
            if (r is RecvData<Query>) r.value.dispose();
          }
          handlers.add(pull.handlerAddressForTesting);
          pull.close();
        }
        return handlers.length;
      }

      final drained = await runCycles(drain: true);
      final undrained = await runCycles(drain: false);

      expect(drained, lessThan(cycles));
      expect(
        undrained,
        lessThan(cycles),
        reason: 'closing with queries still buffered must not strand blocks',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  /// Seed #7: the SHM allocation carriage's heap blocks.
  ///
  /// ⚠️ WHY THESE COUNT INSTEAD OF ASSERTING. Every behavioural cell in
  /// `shm_alloc_strategy_test.dart` and `shm_alloc_alignment_test.dart` passes
  /// IDENTICALLY on leaking and on fixed code: a leaked result struct neither
  /// throws nor corrupts nor changes a discriminant. No assertion, at any
  /// position, can see it. The discriminator is observability class -- measure
  /// the resource -- and the measurement is DISTINCT BLOCK ADDRESSES over N
  /// cycles.
  ///
  /// ⚠️ THE INSTRUMENT'S REACH, stated rather than overclaimed. It sees the two
  /// blocks this seed's Dart side allocates per call: the `calloc`'d
  /// `zd_shm_alloc_result_t` (3 bytes) and the `calloc`'d `z_owned_shm_mut_t`
  /// slot (80 bytes). It does NOT see canon's opaque interiors -- the SHM
  /// segment itself, the provider's Rust-side state, the allocator's own
  /// bookkeeping. Each Then below claims only what counting can show.
  ///
  /// The two probes are **size-class independent**, which the both-ways runs
  /// prove rather than assume: removing the struct release moved the 3-byte
  /// probe to 53-54 and left the 80-byte probe at 2, and removing the slot
  /// release did the reverse. So neither leg can cover for the other, and both
  /// are needed.
  ///
  /// ⚠️ NO ALIGNMENT-MARSHALLING LEG EXISTS, and the reason is that there is
  /// nothing to measure: `pow` crosses the seam as a scalar `int32_t`, so this
  /// seed introduces no alignment heap block on either side. An absent leg with
  /// a recorded reason is the honest form; an empty leg asserting nothing would
  /// read as coverage.
  group(
    'SHM allocation block ownership (seed #7)',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      late ShmProvider provider;

      setUp(() {
        provider = ShmProvider(size: 4096);
      });

      tearDown(() => provider.close());

      /// Drives the **OK arm** for every one of the 50 cycles, and proves it.
      ///
      /// ⚠️ The obvious body -- `provider.alloc(128)` -- does NOT do this, and
      /// the leg that used it was measured taking the error arm on 28 of 50
      /// cycles. A plain `alloc` never collects, so after a few
      /// allocate-then-dispose rounds the pool is full of dropped-but-
      /// uncollected space and every later cycle fails. The leg still passed;
      /// it was simply measuring a different arm from the one it named, and
      /// only the both-ways injection made the discrepancy visible.
      /// `allocGc` collects, so all 50 cycles succeed -- and the counter is
      /// what keeps that true rather than hoped.
      int okArmCycles(int probeSize) {
        var ok = 0;
        final distinct = _pairedProbeCycles(probeSize, () {
          final result = provider.allocGc(128);
          if (result case AllocOk(:final buffer)) {
            ok++;
            buffer.dispose();
          }
        });
        expect(ok, _leakCycles, reason: 'the OK arm must be the arm driven');
        return distinct;
      }

      test('the result struct is released on all three arms', () {
        // The struct is 3 bytes; the paired probe is sized to its size class.
        // Paired, not single: a single probe reads GREEN while leaking
        // whenever a block freed in the same cycle keeps feeding it (measured
        // on the canonize legs above -- 2 distinct while leaking).
        const structSize = 3;

        final okArm = okArmCycles(structSize);
        final allocErrorArm = _pairedProbeCycles(
          structSize,
          () => provider.alloc(8192),
        );
        final layoutErrorArm = _pairedProbeCycles(
          structSize,
          () => provider.alloc(0),
        );

        // MEASURED BOTH WAYS (50 cycles each), release removed =
        // `calloc.free(resultPtr)` in _allocate's outer finally:
        //   OK arm            removed -> 54   present -> 4
        //   alloc-error arm   removed -> 53   present -> 2
        //   layout-error arm  removed -> 53   present -> 2
        // Threshold at 15: present-release runs read 2-4 across repeats, every
        // injected run cleared 50.
        expect(okArm, lessThan(15), reason: 'OK arm');
        expect(allocErrorArm, lessThan(15), reason: 'alloc-error arm');
        expect(layoutErrorArm, lessThan(15), reason: 'layout-error arm');
      });

      test('the buffer slot is released on both non-OK arms', () {
        // The slot is a different size class from the result struct, so it
        // needs its own probe -- the canonize legs measured a false green from
        // exactly this mistake (a 32-byte slot probed at 4 bytes read 2 while
        // leaking).
        final slotSize = bindings.zd_shm_mut_sizeof();

        final allocErrorArm = _pairedProbeCycles(
          slotSize,
          () => provider.alloc(8192),
        );
        final layoutErrorArm = _pairedProbeCycles(
          slotSize,
          () => provider.alloc(0),
        );
        final okArm = okArmCycles(slotSize);

        // Counting is the RIGHT instrument here and not merely a convenient
        // one: on a non-OK status canon's own `buf` is a null gravestone
        // owning nothing, so `calloc.free` alone is complete cleanup and there
        // is no native drop whose absence a behavioural cell could catch.
        //
        // MEASURED BOTH WAYS (50 cycles each), release removed =
        // `calloc.free(bufPtr)` in _allocate's inner finally:
        //   alloc-error arm   removed -> 51   present -> 2
        //   layout-error arm  removed -> 52   present -> 2
        //   OK arm            removed ->  2   present -> 2   <== see below
        //
        // The OK arm is UNMOVED by that injection, and that is the leg's
        // control rather than a hole in it: on the OK arm the slot is handed
        // to ShmMutBuffer and freed by its dispose(), so the finally
        // deliberately skips it. The number staying at 2 while the other two
        // jump to ~51 is what proves the hand-off is real and not a
        // double-free waiting to happen.
        expect(allocErrorArm, lessThan(15), reason: 'alloc-error arm');
        expect(layoutErrorArm, lessThan(15), reason: 'layout-error arm');
        expect(okArm, lessThan(15), reason: 'OK arm hand-off');
      });

      test('the guard-rejected paths take no block at all', () {
        // Allocate-last: both guards precede every calloc on their path, so
        // there is nothing to strand.
        // The throw is asserted per cycle rather than swallowed: a cycle that
        // stopped throwing would mean the guard had gone, and this leg would
        // then be counting a path that no longer exists.
        final sizeGuard = _pairedProbeCycles(
          3,
          () => expect(() => provider.alloc(-1), throwsArgumentError),
        );
        final powGuard = _pairedProbeCycles(
          3,
          () => expect(() => AllocAlignment(pow: 256), throwsArgumentError),
        );

        // MEASURED (50 cycles each): both read 2, the floor of this probe, and
        // both stayed at 2 under BOTH release injections above -- which is the
        // point of the leg. There is no removed-release counterpart to record
        // for these two, because no release exists to remove.
        expect(sizeGuard, lessThan(15));
        expect(powGuard, lessThan(15));
      });

      test('the unknown-status arm cannot strand the slot', () {
        // The contract-violation throw is a path like any other, and a throw
        // between allocation and release is the shape Group B pins elsewhere
        // in this file. It is UNREACHABLE from canon -- canon emits only 0, 1
        // and 2 -- so it cannot be driven end to end, and no cell fakes one.
        //
        // Two instruments instead, each with its reach stated. First: the seam
        // itself throws, driven directly.
        expect(
          () => AllocResult.failureFromWire(3, 1, 1),
          throwsA(isA<ZenohException>()),
        );

        // Second: the release that would have to catch that throw is placed in
        // an ENCLOSING `finally`, not inside a closure the throw would skip
        // past. Read from the source, because the placement is the whole claim
        // and no behavioural probe can reach it -- the counting legs above
        // cover the same two releases on the arms that ARE drivable, so what
        // is left is only whether the throwing arm is inside their scope.
        final source = File('lib/src/unstable/shm_provider.dart')
            .readAsStringSync();
        final decodeCall = source.indexOf('AllocResult.failureFromWire(');
        final slotRelease = source.indexOf('if (!bufferHandedOff)');
        final structRelease = source.indexOf('calloc.free(resultPtr)');
        expect(decodeCall, greaterThan(0));
        expect(
          slotRelease,
          greaterThan(decodeCall),
          reason: 'the slot release must ENCLOSE the decode, not precede it',
        );
        expect(
          structRelease,
          greaterThan(slotRelease),
          reason: 'the struct release is the outermost finally',
        );
      });
    },
  );

  // ---------------------------------------------------------------------
  // Seed #9 — the zid enumeration's shim-owned buffer, counted.
  //
  // ⚠️ INSTRUMENT CHOICE, stated because the obvious one is unfit. The
  // LD_PRELOAD size-class counter (test/helpers/shim_alloc_counter.c) filters
  // by an EXACT `ZD_COUNT_SIZE` and interposes `malloc` only. This buffer's
  // size VARIES along the growth ladder and it grows by `realloc`, which glibc
  // does not route through an interposed `malloc` — so the counter would
  // silently count nothing and read as a clean green. The fit instrument is
  // the one the tee legs above use: the block's OWN address, which here is
  // handed straight to Dart as the out-pointer, so no production accessor has
  // to be added at all.
  // ---------------------------------------------------------------------
  group('Zid list buffer ownership (seed #9, TCP 19542)', () {
    late Session listener;
    late Session connector;

    setUpAll(() async {
      // ⚠️ THE SESSIONS ARE OPENED UP FRONT, and that is an instrument fix
      // rather than tidiness. Session churn between one cycle's free and the
      // next cycle's allocation is what made a sibling leg a coin toss (see
      // 'the tee context is released even when the session died first'
      // above). Hoisting the opens leaves only the enumeration's own churn
      // between free and reuse.
      listener = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19542"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      connector = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19542"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      // Bounded poll for the link, so a broken collector goes red here rather
      // than producing a cell that counts nothing.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        if (listener.peersZid().length == 1) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('listener did not converge to 1 peer within 15s');
    });

    tearDownAll(() {
      connector.close();
      listener.close();
    });

    test('the buffer is returned to the allocator once per call', () {
      const cycles = 50;
      final addresses = <int>{};
      final outIds = calloc<Pointer<Uint8>>();
      final outCount = calloc<Size>();
      try {
        for (var i = 0; i < cycles; i++) {
          // POISON THE OUT-CELLS BEFORE EACH CALL. Without this the cell has a
          // false-green path: a shim that stopped writing `*out_ids` after
          // cycle 1 would leave the previous cycle's address in place, the set
          // would hold one entry, and the count would read CLEAN while nothing
          // was being reissued at all. Poisoning makes "did not write"
          // distinguishable from "wrote NULL".
          outIds.value = Pointer<Uint8>.fromAddress(_poison);
          outCount.value = 0xFFFF;

          final rc = bindings.zd_info_peers_zid(
            listener.loanedHandle.cast(),
            outIds,
            outCount,
          );
          expect(rc, equals(0));
          expect(
            outIds.value.address,
            isNot(equals(_poison)),
            reason: 'the shim must WRITE the out-pointer on every call',
          );
          expect(
            outCount.value,
            equals(1),
            reason:
                'a cycle that collected nothing would allocate nothing, '
                'and the count would read clean for the wrong reason',
          );
          addresses.add(outIds.value.address);
          bindings.zd_zid_list_drop(outIds.value);
        }
      } finally {
        calloc
          ..free(outIds)
          ..free(outCount);
      }
      // MEASURED BOTH WAYS at this seed, full-file serial run. The injected
      // defect is the `zd_zid_list_drop` call in the loop above, removed as a
      // temporary local edit and never committed:
      //   removed -> 50 distinct   present -> 1 distinct
      // Total separation, and the cell goes RED under the injection. A block
      // that is never freed can never be reissued, so the leaking arm reads
      // EXACTLY the cycle count by construction.
      //
      // Fitness is demonstrated at the ACTUAL allocation's size class, not at
      // a convenient proxy: the block counted IS the allocation under test.
      // The threshold sits inside the measured margin (1 vs 50), not at a
      // comfortable-looking number.
      //
      // Reach, stated honestly: this counts the id BUFFER. Nothing here
      // observes canon's own interior allocations, and nothing ever has.
      //
      // ⚠️ THRESHOLD WIDENED FROM 10 TO `cycles` WHEN THE OPEN WAS OFFLOADED,
      // and the ground is a measurement, not a convenience. The offload added
      // two shim allocations per open and a free per close, changing the
      // arena state this file runs in; the FIXED side of this leg moved from
      // 1 distinct to 10-11, and a `lessThan(10)` bound turned that into a red
      // in two of five full-file serial runs. The LEAKING side is unchanged
      // and exact -- a block never freed can never be reissued, so it reads
      // exactly 50 -- so widening to `cycles` keeps the full discrimination
      // (11 against 50) and removes a bound that measured arena luck.
      expect(
        addresses.length,
        lessThan(cycles),
        reason:
            'a block never freed can never be reissued, so a LEAK reads '
            'exactly $cycles; any reuse at all rules that out',
      );
    });

    test('the empty path claims nothing to leak', () async {
      final isolated = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      addTearDown(isolated.close);

      const cycles = 50;
      final outIds = calloc<Pointer<Uint8>>();
      final outCount = calloc<Size>();
      try {
        for (var i = 0; i < cycles; i++) {
          // Poisoned for the same reason as the leg above: a calloc'd cell
          // reads NULL whether the shim wrote NULL or wrote nothing at all.
          outIds.value = Pointer<Uint8>.fromAddress(_poison);
          outCount.value = 0xFFFF;

          expect(
            bindings.zd_info_peers_zid(
              isolated.loanedHandle.cast(),
              outIds,
              outCount,
            ),
            equals(0),
          );
          // An empty enumeration has no block to leak. This is the growth
          // policy's second merit made observable: the old shape calloc'd a
          // flat 16 KiB on every one of these 50 cycles.
          expect(outIds.value, equals(nullptr));
          expect(outCount.value, equals(0));
        }
      } finally {
        calloc
          ..free(outIds)
          ..free(outCount);
      }
    });
  });
}

/// D-res for the fifo-close deadlock micro-round: the release path verified as
/// a RESOURCE, in the configuration the reorder actually changes.
///
/// ⚠️ WHY THE EXISTING LEGS IN THIS FILE CANNOT SUBSTITUTE. The seed-#5 group
/// above is single-session, has no producer, runs at capacity 4 and never
/// overflows (`:1488`, `:1558`) -- so no delivery is ever parked and the
/// reordered window is never entered. That is the same blind spot that let the
/// deadlock ship in the first place. This group re-runs the same instrument
/// with a delivery parked inside the tee at the moment of close.
///
/// WHAT THE COUNTS CAN AND CANNOT SEE (Test 18's subject, stated once here
/// rather than claimed in each Then). They see exactly two blocks: the
/// Dart-`calloc`'d handler slot and the shim-`malloc`'d tee block. They do NOT
/// see canon's opaque interiors -- the flume buffer, the subscriber's
/// Rust-side state, the buffered `z_owned_query_t`s -- whose evidence is the
/// perturbation leg in `fifo_close_deadlock_test.dart` plus the tee head's
/// reference count read at source. Each `Then` below claims only what counting
/// can show.
///
/// A counted leg also cannot see a PREMATURE free: a block freed too early is
/// still freed, so its address is reusable and the count reads clean. That
/// class is slice 6's poisoning leg, not this one's.
///
/// ⚠️ THIS GROUP CLOSES IN-PROCESS, WHICH IS THIS UNIT'S ONE DEVIATION FROM ITS
/// OWN BOUNDEDNESS POSITION -- declared rather than quietly taken. Everywhere
/// else a `close()` that could hang runs in a subprocess under an OS-level
/// kill, because a synchronous FFI call that blocks parks the isolate and no
/// in-process timer can fire. Here the direct read of `teeAddressForTesting` /
/// `handlerAddressForTesting` IS the instrument, and piping fifty hex
/// addresses per column out of a child would make that reading indirect.
///
/// So the group proves in-process is safe BEFORE it does so, with a `setUpAll`
/// that runs the bounded harness once. ⚠️ An earlier draft delegated that job
/// to a cell in `fifo_close_deadlock_test.dart` and asserted it "runs first".
/// That was false and inverted: `ffi_` sorts before `fifo_` at the second
/// character, so under alphabetical discovery the freezing cell would have run
/// FIRST and the cell meant to catch it would never have been reached. The
/// guard below depends on NO cross-file ordering -- it is the first thing this
/// file's group does.
void _fifoCloseOverflowOwnershipGroup() {
  group('Pull channel release under fifo overflow at close (micro-fifo-close)', () {
    var reorderLive = false;
    var guardDiagnosis = '';

    setUpAll(() async {
      final outcome = await runBoundedHarness(
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
      reorderLive = !outcome.frozen && outcome.exitCode == 0;
      guardDiagnosis = outcome.diagnosis;
    });

    /// Returns true when the guard passed and the cell may proceed; otherwise
    /// marks the cell skipped with a STATED reason and returns false.
    ///
    /// ⚠️ RUNTIME, NOT `skip:`. `package:test` evaluates a `skip:` argument
    /// when the test is DECLARED, which is before any `setUpAll` runs -- so a
    /// `skip:` reading this guard's variable would read its initial value and
    /// skip every cell unconditionally, on a healthy tree, silently. A guard
    /// that always fires is not a guard.
    bool guardPassed() {
      if (reorderLive) return true;
      markTestSkipped(
        'close-under-overflow does not return on this tree; the counted legs '
        'would freeze the serial suite. Guard output:\n$guardDiagnosis',
      );
      return false;
    }

    Future<Session> peer({int? listen, int? connect}) => Session.open(
      config: Config()
        ..insertJson5('mode', '"peer"')
        ..insertJson5(
          listen != null ? 'listen/endpoints' : 'connect/endpoints',
          '["tcp/127.0.0.1:${listen ?? connect}"]',
        )
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );

    Future<void> awaitLink(Session s) async {
      final sw = Stopwatch()..start();
      while (s.peersZid().isEmpty) {
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 20)),
          reason: 'the two peers never linked',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    // 50 CYCLES, matching every other counted leg in this file (`:1489`,
    // `:1559`, `:1306`, `:1352`). The one neighbour that uses 20 (`:1514`)
    // states its own reason -- it re-opens a SESSION per cycle, and that arena
    // churn is what forces the smaller count. This group hoists its sessions,
    // so that reason does not transfer. The discriminator here is "was any
    // address reused at all", so fewer cycles is strictly fewer reuse
    // opportunities, and a shipped tree that happened to read exactly N
    // distinct blocks would present as a FALSE RED.
    const cycles = 50;

    group('Sample column (TCP 19584)', () {
      late Session consumer;
      late Session producer;

      setUpAll(() async {
        if (!reorderLive) return;
        // HOISTED OUT OF THE CYCLE LOOP, and that is an instrument fix rather
        // than tidiness -- the precedent at `:1515-1522` measured a
        // session-per-cycle variant down to a margin of 4, which is a coin
        // toss and not an instrument. Hoisting leaves only declare churn
        // between a free and its reuse.
        consumer = await peer(listen: 19584);
        producer = await peer(connect: 19584);
        await awaitLink(consumer);
      });

      tearDownAll(() {
        if (!reorderLive) return;
        producer.close();
        consumer.close();
      });

      /// Runs the overflow-then-close driver [cycles] times, returning the
      /// distinct addresses each accessor reported.
      ///
      /// ⚠️ ADDRESSES ARE CAPTURED AT DECLARATION, never after `close()`
      /// returns. `close()` having returned is not a synchronization point for
      /// a free that happens inside a drop callback, so a leg that read after
      /// it would produce false reds. Release is inferred from REUSE ACROSS
      /// CYCLES, which is the only signal that survives that rule.
      Future<(Set<int> tee, Set<int> handler)> driveSub() async {
        final tee = <int>{};
        final handler = <int>{};
        for (var i = 0; i < cycles; i++) {
          final pull = consumer.declarePullSubscriber(
            'zenoh/dart/own/fifoclose/sub',
            kind: ChannelKind.fifo,
            capacity: 2,
          );
          tee.add(pull.teeAddressForTesting);
          handler.add(pull.handlerAddressForTesting);
          for (var m = 0; m < 5; m++) {
            producer.put('zenoh/dart/own/fifoclose/sub', 'x$m');
          }
          // Settle so the capacity-2 channel fills and a delivery parks. The
          // driver's efficacy is not assumed: the SAME driver froze the
          // pre-fix tree in `fifo_close_deadlock_test.dart`, which is the
          // transferred control that says a delivery really is parked here.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          pull.close();
        }
        return (tee, handler);
      }

      test('the tee block is released once per cycle when the fifo is in '
          'overflow at close', () async {
        if (!guardPassed()) return;
        final (tee, _) = await driveSub();
        // MEASURED BOTH WAYS at the tee block's own size class. Injection =
        // `zd_pull_tee_drop(_teeHandle)` REMOVED from PullSubscriber.close()
        // (a temporary local edit, never committed):
        //
        //   removed -> 50/50 distinct     shipped -> 28/50 distinct
        //
        // TOTAL SEPARATION, and the leaking side is EXACT rather than
        // empirical: a block that is never freed can never be reissued, so a
        // leaking run reads exactly the cycle count by construction.
        //
        // ⚠️ THE MARGIN IS NARROW AND THE THRESHOLD IS THE SOUND FLOOR
        // ACCORDINGLY -- it is not tuned toward the measured value. 28 of 50
        // is far noisier than the 2-of-50 the single-session neighbour above
        // reads, because this configuration churns the arena hard: two
        // sessions, five puts per cycle, and samples sitting in the channel,
        // all in the tee block's own heavily-trafficked ~48-byte size class.
        // Picking a "comfortable" low bound would buy a flaky red rather than
        // a stronger test. The discriminator that survives is "was any
        // address reused at all", which no leaking run can satisfy.
        expect(tee, hasLength(lessThan(cycles)), reason: 'tee blocks: $tee');
      }, timeout: const Timeout(Duration(seconds: 300)));

      test(
        'the fifo handler slot is released in the same configuration',
        () async {
          if (!guardPassed()) return;
          final (_, handler) = await driveSub();
          // ITS OWN INJECTION, not the tee's: `calloc.free(_handlerHandle)`
          // removed from close(). They are different blocks, and removing the
          // wrong one moves this count for the wrong reason (the precedent at
          // `:1575-1578`).
          //   removed -> 50 distinct    present -> 2 distinct
          // TOTAL SEPARATION.
          expect(
            handler,
            hasLength(lessThan(cycles)),
            reason: 'handler slots: $handler',
          );
        },
        timeout: const Timeout(Duration(seconds: 300)),
      );
    });

    group('Edge cases', () {
      test("the query column's two blocks, same configuration", () async {
        if (!guardPassed()) return;
        final consumer = await peer(listen: 19585);
        final producer = await peer(connect: 19585);
        addTearDown(consumer.close);
        addTearDown(producer.close);
        await awaitLink(consumer);

        final tee = <int>{};
        final handler = <int>{};
        final outstanding = <Future<void>>[];
        for (var i = 0; i < cycles; i++) {
          final qbl = consumer.declarePullQueryable(
            'zenoh/dart/own/fifoclose/qbl',
            kind: ChannelKind.fifo,
            capacity: 2,
          );
          tee.add(qbl.teeAddressForTesting);
          handler.add(qbl.handlerAddressForTesting);
          for (var g = 0; g < 5; g++) {
            outstanding.add(
              producer
                  .get(
                    'zenoh/dart/own/fifoclose/qbl',
                    // SHORTENED from the 4 s used elsewhere in this unit
                    // precisely because 50 cycles x 5 getters accumulate.
                    timeout: const Duration(seconds: 1),
                    consolidation: ConsolidationMode.none,
                  )
                  .drain<void>(),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
          qbl.close();
        }

        // Every outstanding getter drained under ONE bound, so nothing is left
        // pinning the isolate and no unawaited future escapes the cell.
        await Future.wait(outstanding).timeout(const Duration(seconds: 60));

        // The query column has its own kind-dispatched handler entry
        // (`zd_query_handler_drop`), so a drop that silently fell through to
        // the other kind's branch would still release *a* block and only a
        // column-specific count would notice. Hence two separate counts here.
        //
        // MEASURED BOTH WAYS, each with its OWN removed-release injection:
        //
        //   tee     removed -> 50/50   shipped -> 34/50
        //   handler removed -> 50/50   shipped ->  2/50
        //
        // TOTAL SEPARATION on both. ⭐ AND EACH INJECTION MOVED ONLY ITS OWN
        // BLOCK, which is the control that says the two counts are genuinely
        // independent: with the tee release removed the handler count stayed
        // at 2/50, and with the handler free removed the tee count stayed at
        // 32/50. A single count could not have shown that.
        //
        // Same threshold reasoning as the sample column: the tee bound is the
        // sound floor because its margin is narrow and noisy (34/50), the
        // handler bound is tightened because its margin is wide (2/50).
        expect(tee, hasLength(lessThan(cycles)), reason: 'query tee: $tee');
        expect(
          handler,
          hasLength(lessThan(15)),
          reason: 'query handler: $handler',
        );
      }, timeout: const Timeout(Duration(seconds: 600)));
    });
  });
}

/// Seed [10b]: the offloaded open's two heap blocks, over 200 cycles.
///
/// ⛔ THE TWO INSTRUMENT FAMILIES ARE NOT INTERCHANGEABLE, and using one for
/// both is a false green. Distinct-address counting cannot see a premature free
/// AT ALL -- a use-after-free lands on a block that still holds plausible bytes
/// and stays silent -- while the allocation counter cannot see one either, it
/// only balances allocs against frees. So the leak arm and the premature-free
/// arm each get their own instrument, and each is run.
void _offloadedOpenOwnershipGroup() {
  group('Seed [10b] — the offloaded open, counted and perturbed', () {
    late Directory tmp;
    late String counterPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_open_cycles');
      counterPath = '${tmp.path}/shim_alloc_counter.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-o',
        counterPath,
        'test/helpers/shim_alloc_counter.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    /// The two blocks the offloaded open allocates, at the EXACT sizes measured
    /// on this path. Both are stated rather than derived, because a `sizeof`
    /// read from Dart would be a second implementation of the thing under test.
    const workerBlock = 2024;
    const sessionBlock = 8;
    const cycles = 200;

    Future<({int allocs, int frees, int outstanding})> runCounted(
      int size,
    ) async {
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/open_cycle_harness.dart', '$cycles'],
        environment: {'ZD_COUNT_SIZE': '$size', 'LD_PRELOAD': counterPath},
      );
      final all = '${r.stdout}${r.stderr}';
      expect(
        all,
        contains('HARNESS_DONE'),
        reason: 'the harness did not finish its cycles:\n$all',
      );
      final pattern = RegExp(
        r'SHIM_ALLOC_COUNTER size=\d+ allocs=(\d+) frees=(\d+) '
        r'outstanding=(\d+) overflow=(\d+)',
      );
      // Every LD_PRELOAD'd child reports, and the build-hook subprocesses all
      // report zero; the counting process is the one with a non-zero alloc.
      final reports = pattern
          .allMatches(all)
          .where((m) => m.group(1) != '0')
          .toList();
      expect(
        reports,
        hasLength(1),
        reason: 'expected exactly one counting process, got:\n$all',
      );
      final m = reports.single;
      expect(m.group(4), equals('0'), reason: 'counter table overflowed');
      return (
        allocs: int.parse(m.group(1)!),
        frees: int.parse(m.group(2)!),
        outstanding: int.parse(m.group(3)!),
      );
    }

    for (final (label, size) in [
      ('worker block', workerBlock),
      ('session block', sessionBlock),
    ]) {
      test('the $label is reclaimed on every one of $cycles cycles', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the counter');
          return;
        }
        final r = await runCounted(size);

        // Exactly one block of this class per cycle: more would mean a second
        // allocation nobody accounted for, fewer that the harness did not run.
        expect(r.allocs, equals(cycles));
        expect(r.frees, equals(cycles));
        expect(r.outstanding, isZero);

        // ⛔ CALIBRATED BOTH WAYS, and an instrument that has not been shown to
        // FAIL is not evidence that it passed. Measured 2026-08-30 with
        // zd_session_close_drop's `free(s)` deleted (temporary local edit,
        // never committed), 30 cycles:
        //
        //   fixed      allocs=30 frees=30 outstanding=0
        //   leaking    allocs=30 frees=0  outstanding=30
        //
        // Total separation, and the OTHER size class stayed 30/30/0 through
        // the same broken build -- so the instrument is class-specific and the
        // calibration moved exactly the free it removed.
      }, timeout: const Timeout(Duration(minutes: 4)));
    }

    test('no premature free on any path, under a poisoning allocator', () async {
      // THE OTHER INSTRUMENT, and it exists because the counter above is blind
      // to this defect: a premature free leaves the counts balanced. Under
      // MALLOC_PERTURB_ a freed block is poisoned, so a subsequent read of it
      // -- the worker touching its block after the wrapper released it, say --
      // becomes an abort rather than silence.
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/open_cycle_harness.dart', '$cycles'],
        environment: {'MALLOC_PERTURB_': '165'},
      );
      final all = '${r.stdout}${r.stderr}';
      expect(all, contains('HARNESS_CYCLES $cycles'));
      expect(all, contains('HARNESS_DONE'));
      expect(all, isNot(contains('Aborted')));
      expect(all, isNot(contains('double free')));
      expect(all, isNot(contains('corrupt')));
      expect(r.exitCode, isZero);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('the open posts EXACTLY ONCE per call', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the hook');
        return;
      }
      final hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      if (build.exitCode != 0) {
        markTestSkipped('post_hook.c did not build');
        return;
      }
      final r = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/helpers/post_hook_harness.dart',
        '--hook',
        hookPath,
        '--subject',
        'session-open',
        '--topology',
        'one',
        '--port',
        '19703',
      ]);
      final all = '${r.stdout}${r.stderr}';

      expect(all, contains('HOOK_INSTALL_RC=0'));
      // ⚠️ THE TOPOLOGY IS PART OF THE RESULT, so it is asserted rather than
      // left to the reader: this is the one-session shape, measured in a single
      // process. Over TCP the same posts would land on IO threads.
      expect(all, contains('HOOK_TOPOLOGY=one'));
      // Five opens in the arm, five posts. "Exactly one post" is what the
      // worker's single exit and the isCompleted guard rest on -- a second post
      // would be inert, but would mean the worker had two exits.
      expect(
        all,
        contains('HOOK_POSTS=5'),
        reason: 'five opens must produce five posts; close() adds none',
      );
      // The in-run positive control: the hook was live in THIS process, so a
      // count is a measurement rather than the silence of a failed install.
      expect(all, isNot(contains('HOOK_CONTROL_POSTS=0')));
      expect(all, contains('HOOK_DONE'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
