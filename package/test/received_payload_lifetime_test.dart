// Seed [10a] slice 5 — the ten enumerated release paths for a retained payload.
//
// ⛔ THIS IS THE R1 OWNERSHIP CLASS, WHERE A BEHAVIOURAL GREEN AND A LEAKING
// IMPLEMENTATION ARE INDISTINGUISHABLE. Nine behavioural tests once passed
// identically on a leaking tree and a fixed one. So no cell here asserts "the
// call returned"; every one measures a resource.
//
// ═══ WHY THE INSTRUMENT IS THE FINALIZER COUNTER AND NOT RESIDENT MEMORY ═══
//
// RSS was tried first and is STRUCTURALLY UNFIT here — recorded rather than
// tuned away, because the reason generalises. `z_bytes_clone` is a SHALLOW,
// refcounted clone: a retained handle owns no buffer of its own, it holds a
// reference to the one zenoh already has. Releasing it decrements a count and
// frees nothing until the last reference goes, and those bytes are also
// referenced by the sample's own `payloadBytes` copy and by zenoh internals.
// Measured: 16 MiB of payloads held, and closing released 2.8 MiB of resident
// memory — a real signal swamped by refcount sharing, at a magnitude no honest
// bound separates.
//
// ⛔ The temptation there is to widen the bound until it passes. That destroys
// the instrument permanently: a real leak of one handle would be absorbed by
// the same slack, forever, silently.
//
// What DOES discriminate, exactly and deterministically:
//
//   zd_fin_invocations(ZdFinKind.bytes)
//
// A `ZBytes` released through ANY enumerated path — `dispose()`, or a send
// that consumes it — DETACHES from the finalizer, so the net can never fire
// for it. A handle merely dropped stays attached, and the net fires under GC
// pressure. So the counter separates "an enumerated path released it" from
// "the safety net had to", which is precisely the distinction this slice is
// about and the one a leak reading cannot make — the net is otherwise a
// confounder that makes a leaking tree read clean.
//
//   delta == 0  ⟹ the enumerated path released it
//   delta  > 0  ⟹ nothing did, and the net cleaned up after us
//
// ⛔ shim_alloc_counter is UNFIT here too and is not reached for: the retained
// slot is Dart-side, dladdr resolves no shared object for Dart allocation
// sites, and Dart's FFI allocator pools blocks at that class below libc.
//
// ⛔ EVERY "delta == 0" CELL CARRIES A POSITIVE CONTROL. A counter that stays
// at zero because no handle was ever created is a false green. Each such cell
// proves handles actually existed — by counting deliveries, or by a sibling
// listener on the same key that saw the same traffic in the same run. And the
// path-3 cell is the arm that proves the counter MOVES at all; without it,
// every `equals(0)` here could be a counter that is simply dead.
//
// ⛔ PATH 9 — a handle stranded by a FAILED POST — HAS NO CELL, DELIBERATELY.
// It is not deterministically drivable: reaching it needs the VM to reject a
// post, which happens only when the receiving port is already closed, and that
// race cannot be forced from Dart. It lands as a reviewed code path with its
// reason stated rather than as a cell that cannot fail. The code is
// `_zd_sample_callback`'s `if (!Dart_PostCObject_DL(...))` branch, which drops
// the clone because the discarded message held its only reference.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
// The unstable door: the six-carrier declaration-failure cell reaches the
// advanced surfaces. It re-exports `zenoh.dart` in full, so nothing already
// in this file changes meaning.
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/bounded_subprocess.dart';

/// The premature-free harness, run as a bounded subprocess.
const _perturbHarness = 'test/helpers/retained_payload_perturb_harness.dart';

/// Payload size — large enough to matter, small enough not to dominate.
const int payloadBytes = 256 * 1024;

/// How many payloads each batch publishes.
const int perBatch = 8;

/// The process-wide count of `ZBytes` finalizer firings.
int finCount() => bindings.zd_fin_invocations(ZdFinKind.bytes);

Uint8List makePayload(int seed) {
  final data = Uint8List(payloadBytes);
  data[0] = seed & 0xFF;
  data[payloadBytes - 1] = (seed + 1) & 0xFF;
  return data;
}

/// Allocates and drops, which is what makes the finalizer net actually run.
Future<void> gcPressure({int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    Uint8List(512 * 1024)[0] = i;
  }
  await Future<void>.delayed(const Duration(milliseconds: 120));
}

/// Flushes finalizers left pending by EARLIER SUITES before any measurement.
///
/// ⛔ `zd_fin_invocations` is a PROCESS-WIDE counter and `package:test` runs
/// suites as isolates inside one process, so a `ZBytes` another file dropped
/// can be reclaimed inside one of this file's measurement windows and read as
/// a failure here. Measured: path 2 passed run alone and failed in a combined
/// run for exactly that reason.
///
/// ⭐ The fix is at the INSTRUMENT, not at the bound. Widening `equals(0)` to
/// absorb the noise would have destroyed what these cells exist to detect: a
/// genuine single-handle leak would sit inside the same slack forever. Draining
/// the backlog first makes the counter quiet, so the assertions stay exact.
Future<void> drainPendingFinalizers() async {
  for (var i = 0; i < 2; i++) {
    await gcPressure(rounds: 40);
  }
}

/// Polls until [condition] holds, failing RED at the deadline with [what].
///
/// Never an unbounded wait: a defect must go red, not freeze the serial suite.
Future<void> pollUntil(
  bool Function() condition,
  String what, {
  // 60s, not 30s. MEASURED: one run in four timed out here on "the first
  // batch" while every assertion in the file passed — a convergence wait, not
  // a defect. These cells push eight 256 KiB payloads over TCP while
  // deliberately churning the heap to drive the finalizer, so 30s was tight.
  //
  // ⚠️ This loosens a DEADLINE, never an assertion: a real defect still goes
  // red here, just later, and the diagnosis it fails with is unchanged. The
  // deadline exists so a defect reports instead of hanging the serial suite —
  // it is not itself a measurement.
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  // ⚠️ package:test's default per-cell guard is 30s. These cells drive real
  // two-session traffic AND deliberate GC pressure, so that guard fires on a
  // healthy tree. Raising it is not widening an assertion -- every cell here
  // still carries its OWN bounded deadline that fails with a diagnosis; this
  // only stops the harness cutting in before those can report.
  ensureInitialized();

  // ⛔ PATH 10 RUNS FIRST, IN ITS OWN GROUP, ON ITS OWN SESSION — and the
  // reason is a defect this cell actually had.
  //
  // Its assertion is that the ZBytes finalizer count does not move. That
  // counter is PROCESS-WIDE. Declared inside the main group it sat after five
  // cells that create retained handles, so any handle *they* leaked was
  // reclaimed inside *this* cell's measurement window and reddened it.
  // Measured: with the port-queue drain branch deliberately disabled, this
  // cell went red alongside paths 6 and 7 — reporting a defect that was
  // nowhere near a failed declaration.
  //
  // That is an absence assertion scoped to the PROCESS while written as though
  // scoped to the file. Running first, before any retention traffic exists,
  // makes the scope match the claim. It is repaired rather than tolerated: a
  // cell that reddens for a defect elsewhere sends the next reader to the
  // wrong place.
  group('Retained payload — declaration failure (no traffic yet)', () {
    late Session session;

    setUpAll(() async {
      final config = Config()
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session = await Session.open(config: config);
      await drainPendingFinalizers();
    });

    // ⛔ PER-CELL, not just per-group. The counter is process-wide, so each
    // cell would otherwise inherit the pending garbage of the cell before it
    // and read another cell's reclaim as its own. Draining here is what makes
    // every measurement window start quiet, which is what lets the assertions
    // stay `equals(0)` instead of being widened into uselessness.
    setUp(drainPendingFinalizers);

    tearDownAll(() {
      session.close();
    });

    test('path 10 — a declaration that fails leaves nothing retained', () async {
      // Given: a retention-enabled declaration whose key expression is
      // invalid, so the native declare never succeeds.
      final before = finCount();

      // When: the declaration fails
      expect(
        () => session.declareSubscriber('bad//key', retainPayload: true),
        throwsA(anything),
      );
      await gcPressure();

      // Then: the cell asserts the ABSENCE of anything to release, rather than
      // a release. Nothing arrived, so nothing was retained, so the net has
      // nothing to reclaim. `abandon()` is the path under test and its whole
      // content is that there is nothing to drain.
      expect(
        finCount() - before,
        equals(0),
        reason: 'a failed declaration retained something',
      );
    });

    // ⛔ SLICE 7 EXTENDS PATH 10 TO ALL SIX CARRIERS, AND IT LIVES HERE
    // RATHER THAN IN `received_payload_test.dart` FOR ONE REASON: the only
    // instrument that can say "nothing was left retained" is the
    // PROCESS-WIDE finalizer counter, and it reads exactly zero only inside a
    // quiet window. That file opens with three groups of retention traffic,
    // so an absence assertion placed after them would be scoped to the
    // process while written as though scoped to the file — the documented
    // defect this group was split out to avoid.
    test(
      'path 10 on every carrier — a failing declaration on each of the six '
      'retention-enabled surfaces leaves nothing retained',
      () async {
        // Given: retention ON at every one of the six sample-carrying
        // registrations, each with an invalid key expression.
        //
        // MEASURED, and it is the content of the cell rather than an aside:
        // all six reject at `KeyExpr`'s own validation
        // (`ZenohException: Invalid key expression: "bad//key" (code: -1)`),
        // which runs in `withLoanedKeyExpr` BEFORE the closure that creates
        // the retention channel. That is ALLOCATE-LAST doing its job — an
        // invalid key expression cannot strand an open `ReceivePort`, and it
        // cannot strand a retained handle either, because at the moment of
        // the throw neither exists yet.
        //
        // The session's own config plays no part for the same reason: nothing
        // native is reached. The advanced carriers' `timestamping` need is a
        // requirement of a SUCCESSFUL declaration, covered in their own
        // suites.
        const bad = 'bad//key';

        final attempts = <String, void Function()>{
          'declareSubscriber': () =>
              session.declareSubscriber(bad, retainPayload: true),
          'declareBackgroundSubscriber': () =>
              session.declareBackgroundSubscriber(bad, retainPayload: true),
          'declareLivelinessSubscriber': () =>
              session.declareLivelinessSubscriber(bad, retainPayload: true),
          'declareBackgroundLivelinessSubscriber': () => session
              .declareBackgroundLivelinessSubscriber(bad, retainPayload: true),
          'declareAdvancedSubscriber': () => session.declareAdvancedSubscriber(
            bad,
            options: const AdvancedSubscriberOptions(retainPayload: true),
          ),
          'AdvancedSubscriber.detectedPublishers': () =>
              session.declareAdvancedSubscriber(
                bad,
                options: const AdvancedSubscriberOptions(
                  detectPublishers: DetectPublishersOptions(
                    retainPayload: true,
                  ),
                ),
              ),
        };
        // Six, and tied to the count the shim itself reports, so this cell
        // and `received_payload_test.dart`'s six-carrier cell cannot drift
        // apart from the source silently.
        final shim = File('../src/zenoh_dart.c').readAsStringSync();
        final sampleSites = RegExp(
          r'z_closure_sample\(&callback, _zd_sample_callback',
        ).allMatches(shim).length;
        expect(attempts, hasLength(sampleSites));
        expect(attempts, hasLength(6));

        final before = finCount();

        // When: each declaration fails
        attempts.forEach((name, declare) {
          expect(
            declare,
            throwsA(isA<ZenohException>()),
            reason: '$name accepted an invalid key expression',
          );
        });
        await gcPressure();

        // Then: the ABSENCE of anything to release — asserted, not a release.
        // ⚠️ This cell has no positive control of its own and cannot have
        // one: creating a handle here would be the traffic the group exists
        // to exclude. The arm that proves this counter MOVES at all is
        // path 3, in the group below.
        expect(
          finCount() - before,
          equals(0),
          reason: 'a failed declaration retained something on one of the six',
        );
      },
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
    );
  });

  group('Retained payload release paths (TCP 19726)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19726"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19726"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));
      await drainPendingFinalizers();
    });

    // ⛔ PER-CELL, not just per-group. The counter is process-wide, so each
    // cell would otherwise inherit the pending garbage of the cell before it
    // and read another cell's reclaim as its own. Draining here is what makes
    // every measurement window start quiet, which is what lets the assertions
    // stay `equals(0)` instead of being widened into uselessness.
    setUp(drainPendingFinalizers);

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    void publishBatch(String key) {
      for (var i = 0; i < perBatch; i++) {
        pubSession.putBytes(key, ZBytes.fromUint8List(makePayload(i)));
      }
    }

    test('path 1 — a delivered handle the consumer disposes releases it, and '
        'the net never fires', () async {
      // Given: a retention-enabled subscriber whose consumer disposes each
      // handle as it arrives.
      const key = 'life/p1';
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);

      var delivered = 0;
      final sub = subscriber.stream.listen((s) {
        s.payloadZBytes?.dispose();
        delivered++;
      });
      addTearDown(sub.cancel);

      // Land one batch so the declaration is known to have propagated.
      publishBatch(key);
      await pollUntil(() => delivered >= perBatch, 'the first batch');

      final before = finCount();
      publishBatch(key);
      await pollUntil(() => delivered >= perBatch * 2, 'the measured batch');
      await gcPressure();

      // POSITIVE CONTROL: handles really did arrive and really were retained,
      // so the zero below is a released count and not an absent one.
      expect(delivered, greaterThanOrEqualTo(perBatch * 2));

      // Then: dispose() detached every one, so the net had nothing to do.
      expect(
        finCount() - before,
        equals(0),
        reason:
            'the finalizer fired for handles the consumer disposed — '
            'dispose() is not detaching from the net',
      );
    });

    test('path 2 — a delivered handle consumed by a publish is released, not '
        'leaked', () async {
      // Given: each retained payload handed straight to putBytes, which
      // CONSUMES it. This is the path the zero-copy echo actually uses, and
      // the one the seed's nine-path floor omitted.
      const key = 'life/p2';
      const echoKey = 'life/p2/echo';
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);

      var delivered = 0;
      final sub = subscriber.stream.listen((s) {
        final z = s.payloadZBytes;
        if (z != null) {
          pubSession.putBytes(echoKey, z);
        }
        delivered++;
      });
      addTearDown(sub.cancel);

      publishBatch(key);
      await pollUntil(() => delivered >= perBatch, 'the first batch');

      final before = finCount();
      publishBatch(key);
      await pollUntil(() => delivered >= perBatch * 2, 'the measured batch');
      await gcPressure();

      expect(delivered, greaterThanOrEqualTo(perBatch * 2));
      expect(
        finCount() - before,
        equals(0),
        reason:
            'markConsumed should have released these; the net fired '
            'instead, which means the consume path did not detach',
      );
    });

    test('path 4 — retained payloads undelivered when the channel closes are '
        'released by the drain', () async {
      // Given: a PAUSED subscription. Samples are parsed and tracked but no
      // listener ever receives them, so they sit in the controller buffer with
      // NO OTHER OWNER. This is the only path where the carrier itself is
      // responsible for the release.
      const key = 'life/p4';

      // POSITIVE CONTROL, on the same key in the same run: a sibling that IS
      // listening proves the traffic actually reached this process. Without it
      // a zero delta below could mean "nothing ever arrived".
      final witness = subSession.declareSubscriber(key, retainPayload: true);
      var witnessed = 0;
      final witnessSub = witness.stream.listen((s) {
        s.payloadZBytes?.dispose();
        witnessed++;
      });

      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      final paused = subscriber.stream.listen((_) {})..pause();

      final before = finCount();
      publishBatch(key);
      await pollUntil(
        () => witnessed >= perBatch,
        'the witness to see the batch (saw $witnessed)',
      );

      // When: the subscriber closes with its handles still undelivered
      await paused.cancel();
      subscriber.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await gcPressure();

      // Then: closeAndDrain disposed them, so the net never had to.
      expect(witnessed, greaterThanOrEqualTo(perBatch));
      expect(
        finCount() - before,
        equals(0),
        reason:
            'undelivered handles reached the finalizer, so closeAndDrain '
            'did not release them — they were orphaned, not drained',
      );

      await witnessSub.cancel();
      witness.close();
    });

    test('path 6 — a cancelled subscription releases what it never handed '
        'over', () async {
      // Given: a consumer that cancels while messages are still in flight
      const key = 'life/p6';
      final witness = subSession.declareSubscriber(key, retainPayload: true);
      var witnessed = 0;
      final witnessSub = witness.stream.listen((s) {
        s.payloadZBytes?.dispose();
        witnessed++;
      });

      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      final sub = subscriber.stream.listen((s) => s.payloadZBytes?.dispose());

      final before = finCount();
      publishBatch(key);
      // Cancel immediately — most of the batch is still in flight.
      await sub.cancel();
      subscriber.close();
      await pollUntil(
        () => witnessed >= perBatch,
        'the witness to see the batch (saw $witnessed)',
      );
      await gcPressure();

      expect(witnessed, greaterThanOrEqualTo(perBatch));
      expect(
        finCount() - before,
        equals(0),
        reason: 'cancelling mid-stream orphaned handles to the net',
      );

      await witnessSub.cancel();
      witness.close();
    });

    test(
      'path 7 — an abandoned iterator releases what it never took',
      () async {
        // Given: an `await for` abandoned after the first sample.
        //
        // ⚠️ The cell states what it rests on: a `sync*` generator's `finally`
        // does NOT run for an abandoned iterator, which is exactly why this
        // release cannot live in one. It lives in the channel's close path.
        const key = 'life/p7';
        final witness = subSession.declareSubscriber(key, retainPayload: true);
        var witnessed = 0;
        final witnessSub = witness.stream.listen((s) {
          s.payloadZBytes?.dispose();
          witnessed++;
        });

        final subscriber = subSession.declareSubscriber(
          key,
          retainPayload: true,
        );
        final before = finCount();
        publishBatch(key);

        await () async {
          await for (final s in subscriber.stream) {
            s.payloadZBytes?.dispose();
            break; // abandon the iterator
          }
        }();
        subscriber.close();
        await pollUntil(
          () => witnessed >= perBatch,
          'the witness to see the batch (saw $witnessed)',
        );
        await gcPressure();

        expect(witnessed, greaterThanOrEqualTo(perBatch));
        expect(
          finCount() - before,
          equals(0),
          reason: 'abandoning the iterator orphaned handles to the net',
        );

        await witnessSub.cancel();
        witness.close();
      },
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('Retained payload — the net is the discriminator (TCP 19727)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19727"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19727"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));
      await drainPendingFinalizers();
    });

    // ⛔ PER-CELL, not just per-group. The counter is process-wide, so each
    // cell would otherwise inherit the pending garbage of the cell before it
    // and read another cell's reclaim as its own. Draining here is what makes
    // every measurement window start quiet, which is what lets the assertions
    // stay `equals(0)` instead of being widened into uselessness.
    setUp(drainPendingFinalizers);

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test('path 3 — a delivered handle nobody releases is reclaimed by the '
        'net, and the counter says which released it', () async {
      // Given: cycles that drop the sample without disposing. This path is
      // survivable ONLY because of the net, which is exactly why the counter
      // is the instrument and a leak reading is not: a released handle and a
      // netted one both leave memory flat.
      const key = 'life/p3';
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);

      var delivered = 0;
      // Deliberately NOT disposed and not retained anywhere.
      final sub = subscriber.stream.listen((_) => delivered++);
      addTearDown(sub.cancel);

      final before = finCount();

      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < perBatch; i++) {
          pubSession.putBytes(key, ZBytes.fromUint8List(makePayload(i)));
        }
        await pollUntil(
          () => delivered >= (round + 1) * perBatch,
          'round $round deliveries (saw $delivered)',
        );
        await gcPressure();
      }

      // Then: the NET did the reclaiming. ⭐ This is also the arm that proves
      // the counter is live at all — without it, every `equals(0)` above could
      // be a counter that simply never moves.
      //
      // ⚠️ The wait DRIVES the condition rather than sleeping on it. A passive
      // poll made this cell flaky (1 timeout in 3 runs): whether the VM has
      // run the major GC that processes a NativeFinalizer is not something
      // elapsed time decides, so waiting longer is not the fix — applying
      // pressure is. Each iteration allocates and drops before re-reading.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (finCount() <= before) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'the ZBytes finalizer never fired for undisposed retained '
            'payloads, so this arm cannot vouch that the counter moves at '
            'all — every equals(0) elsewhere in this file is unvouched',
          );
        }
        await gcPressure(rounds: 80);
      }
      expect(finCount(), greaterThan(before));
    });

    test('path 8 — a consumer that throws before disposing does not leak '
        'beyond the net', () async {
      // Given: a listener that throws between receiving the sample and
      // disposing the handle. The throw is caught by a guarded zone: an
      // uncaught async error would be reported as a failure of this cell
      // rather than as the condition under test.
      const key = 'life/p8';
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);

      var reached = 0;
      var caught = 0;
      final done = Completer<void>();

      await runZonedGuarded(
        () async {
          final sub = subscriber.stream.listen((s) {
            reached++;
            if (reached >= perBatch && !done.isCompleted) done.complete();
            throw StateError('consumer failed before disposing');
          });
          addTearDown(sub.cancel);

          for (var i = 0; i < perBatch; i++) {
            pubSession.putBytes(key, ZBytes.fromUint8List(makePayload(i)));
          }
          await done.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () =>
                throw StateError('only $reached throwing deliveries arrived'),
          );
        },
        (error, stack) {
          caught++;
        },
      );

      await gcPressure();

      // Then: the throws really happened (control), and the handles they
      // skipped are covered by the net rather than lost.
      expect(reached, greaterThanOrEqualTo(perBatch));
      expect(
        caught,
        greaterThan(0),
        reason:
            'the zone never saw the consumer throw, so this cell did not '
            'exercise the thrown-before-release path at all',
      );
      // ⚠️ NOT written as a leak assertion: nobody released these, so
      // non-reclamation by an enumerated path is the CORRECT outcome. What is
      // asserted is that the net is what covers them.
      await pollUntil(
        () => finCount() > 0,
        'the net to have fired at least once in this process',
      );
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ═══════════════════════════════════════════════════════════════════════
  // Seed [10a] slice 6 — CONV-6 stated PER CLASS, never as a family.
  //
  //   ZBytes  — clause 1 ✅ what the user holds in order to USE the payload IS
  //             the ZBytes, and the Sample/Query reference keeps it alive
  //             while reachable; after the consumer drops both, release-while-
  //             in-use is the intended semantic. clause 2 ✅ zd_bytes_drop
  //             reaches no Dart C API. clause 3 ✅ a clone is independent BY
  //             CONSTRUCTION, measured below rather than cited from a doc line.
  //             The net already on it is admissible; nothing is attached and
  //             nothing is detached by this unit.
  //   Sample  — holds no handle of its own. No marker: the refusal is
  //             transitive through the payload it carries, measured in
  //             isolate_sendability_test.dart.
  //   Reply   — same, and for the same reason.
  //   Query   — already marked, already out of the net, unchanged here.
  //
  // ⛔ The at-risk clause is 1, not 3, and CONV-6's measured failure is on
  // precisely this delivery model: a finalizer on a push wrapper took a
  // listened stream from 3 delivered to 0, because what the user holds is the
  // STREAM and the stream does not reference the wrapper. The cell below
  // measures that exact topology.
  // ═══════════════════════════════════════════════════════════════════════
  group('CONV-6 per class, for the retained payload (TCP 19728)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19728"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19728"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));
      await drainPendingFinalizers();
    });

    // ⛔ PER-CELL, not just per-group. The counter is process-wide, so each
    // cell would otherwise inherit the pending garbage of the cell before it
    // and read another cell's reclaim as its own. Draining here is what makes
    // every measurement window start quiet, which is what lets the assertions
    // stay `equals(0)` instead of being widened into uselessness.
    setUp(drainPendingFinalizers);

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Receives one sample on [key] with retention on, bounded.
    Future<Sample> receiveOne(String key) async {
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);
      final seen = <Sample>[];
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (seen.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('no sample on $key');
        }
        pubSession.putBytes(
          key,
          ZBytes.fromUint8List(Uint8List.fromList([7, 0, 8, 0xFF])),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return seen.first;
    }

    test('clause 3 — disposing the retained payload changes no other live '
        "object's contract", () async {
      // Given: a delivered Sample whose retained payload is then disposed
      final sample = await receiveOne('conv6/clause3');
      final before = (
        keyExpr: sample.keyExpr,
        payload: sample.payload,
        payloadBytes: Uint8List.fromList(sample.payloadBytes),
        kind: sample.kind,
        encoding: sample.encoding,
        timestamp: sample.timestamp,
        priority: sample.priority,
        congestion: sample.congestionControl,
        express: sample.express,
      );

      // When: the handle is released
      sample.payloadZBytes!.dispose();

      // Then: every other member reads exactly what it read before. The
      // release is local to the handle and reaches nothing else.
      expect(sample.keyExpr, equals(before.keyExpr));
      expect(sample.payload, equals(before.payload));
      expect(sample.payloadBytes, equals(before.payloadBytes));
      expect(sample.kind, equals(before.kind));
      expect(sample.encoding, equals(before.encoding));
      expect(sample.timestamp, equals(before.timestamp));
      expect(sample.priority, equals(before.priority));
      expect(sample.congestionControl, equals(before.congestion));
      expect(sample.express, equals(before.express));
    });

    test(
      'clause 3 — releasing the SOURCE does not invalidate the clone',
      () async {
        // Given: a retained payload from a sample on its own session
        const key = 'conv6/source';
        final listenConfig = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19731"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false');
        final ownSub = await Session.open(config: listenConfig);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final connectConfig = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19731"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false');
        final ownPub = await Session.open(config: connectConfig);
        await Future<void>.delayed(const Duration(seconds: 1));

        final subscriber = ownSub.declareSubscriber(key, retainPayload: true);
        final seen = <Sample>[];
        final sub = subscriber.stream.listen(seen.add);
        final sent = Uint8List.fromList([0xAA, 0x00, 0xBB, 0x00, 0xCC]);
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (seen.isEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('no sample on $key');
          }
          ownPub.putBytes(key, ZBytes.fromUint8List(sent));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final retained = seen.first.payloadZBytes!;

        // When: the subscriber and BOTH sessions are closed
        await sub.cancel();
        subscriber.close();
        ownSub.close();
        ownPub.close();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Then: the clone still reads. ⭐ MEASURED for this construction rather
        // than cited from z_bytes_drop's doc comment — this project was burned
        // once by a canon clone that cloned a BORROW and threw the moment its
        // source was disposed. A signature is not a mechanism.
        expect(retained.toBytes(), equals(sent));
        retained.dispose();
      },
    );

    test('clause 1 — the net does not fire while the handle is IN USE', () async {
      // Given: a retained payload held ONLY through a listened stream, which
      // is precisely the topology CONV-6 records as its measured failure: what
      // the user holds is the stream, and the stream does not reference the
      // wrapper.
      const key = 'conv6/clause1';
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);

      final held = <ZBytes>[];
      final sub = subscriber.stream.listen((s) {
        final z = s.payloadZBytes;
        if (z != null) held.add(z);
      });
      addTearDown(sub.cancel);

      final sent = Uint8List.fromList([0x11, 0x00, 0x22]);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (held.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('no retained handle arrived');
        }
        pubSession.putBytes(key, ZBytes.fromUint8List(sent));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final before = finCount();

      // When: several rounds of GC pressure run while the handles are still
      // referenced and still to be read
      for (var round = 0; round < 4; round++) {
        await gcPressure();
      }

      // Then: the counter has not moved and every handle still reads. A
      // reachable-in-use handle must not be collected — that is clause 1, and
      // it is the clause that actually failed for the push family.
      expect(
        finCount() - before,
        equals(0),
        reason:
            'the net fired for a handle still held and still readable — '
            'clause 1 is violated for the stream-delivery topology',
      );
      for (final z in held) {
        expect(z.toBytes(), equals(sent));
      }
      for (final z in held) {
        z.dispose();
      }
    });

    test('clause (ii) — a RETAINED handle releases by the same path as a '
        'constructed one', () async {
      // ⛔ CLAUSE (ii) IS "the native release does not transitively call any
      // Dart C API", and for `ZBytes` it is ALREADY MEASURED ON BOTH
      // TOPOLOGIES by shipped surface: `finalizer_ownership_test.dart`'s
      // "bytes: its release reaches no Dart post" rows run the post-site hook
      // over `zd_bytes_drop` in the `one` and `tcp` topologies, each with an
      // in-run control that must itself see posts before a zero counts.
      //
      // Re-derived at HEAD for this unit, because this unit added a post to
      // the receive path and that is exactly when an instrument calibrated on
      // its absence has to be re-run: BOTH rows green, 2/2, after the change.
      //
      // ⚠️ Measuring both topologies is not ceremony. `Query` once posted 1
      // one-session and 0 over TCP, so a single-topology measurement repeats a
      // recorded near-miss exactly.
      //
      // Duplicating those two rows here would reproduce the repeated-shape
      // defect this project has already paid for. What this cell adds instead
      // is the ONE thing this unit changes: whether a handle materialised from
      // a POSTED IMAGE releases by that same measured path, or by some new one
      // the hook rows never saw.
      const key = 'conv6/clause2';
      final sample = await receiveOne(key);
      final retained = sample.payloadZBytes!;
      final constructed = ZBytes.fromUint8List(
        Uint8List.fromList([7, 0, 8, 0xFF]),
      );

      final before = finCount();

      // When: both are released the ordinary way
      retained.dispose();
      constructed.dispose();
      await gcPressure();

      // Then: they behave identically under release. Both refuse a subsequent
      // read with the same guard, and neither reaches the finalizer — which is
      // what shows the retained construction added no second release shape and
      // therefore inherits the both-topology measurement above rather than
      // needing its own.
      expect(retained.toBytes, throwsStateError);
      expect(constructed.toBytes, throwsStateError);
      expect(
        finCount() - before,
        equals(0),
        reason:
            'a disposed handle still reached the net, so dispose() did '
            'not detach — and the retained path would then NOT be covered by '
            'the measured zd_bytes_drop rows',
      );
    });

    test('a premature free of the retained clone would be caught', () async {
      // Given: a bounded subprocess that receives a retained payload and reads
      // it AFTER the point a premature free would occur, verifying the bytes
      // rather than merely that the call returned.
      //
      // MEASURED, shipped tree, MALLOC_PERTURB_=165:
      //   RETAIN_ROUND=0 .. RETAIN_ROUND=11, RETAIN_PERTURB_DONE, exit 0.
      final outcome = await runBoundedHarness(
        _perturbHarness,
        const [],
        deadline: const Duration(seconds: 200),
        environment: {'MALLOC_PERTURB_': '165'},
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, isZero, reason: outcome.diagnosis);
      for (var round = 0; round < 12; round++) {
        expect(
          outcome.hasMarker('RETAIN_ROUND=$round'),
          isTrue,
          reason: 'round $round never completed:\n${outcome.diagnosis}',
        );
      }
      // The end marker is asserted SEPARATELY from the exit code: a process
      // that died early would otherwise satisfy an exit-code check for the
      // wrong reason.
      expect(
        outcome.hasMarker('RETAIN_PERTURB_DONE'),
        isTrue,
        reason: 'the harness must reach its end:\n${outcome.diagnosis}',
      );

      // ── THE THREE-ARM CALIBRATION, AND ITS VERDICT IS STATED HONESTLY ────
      //
      // Injection (temporary local edit, never committed): in
      // `_zd_sample_callback`'s DELIVERED branch, replace
      //   z_internal_bytes_null(&retained_payload);
      // with
      //   z_bytes_drop(z_bytes_move(&retained_payload));
      // which frees the clone Dart now owns and leaves Dart holding the image
      // of a released handle.
      //
      //   shipped,  MALLOC_PERTURB_=165 -> 12 rounds, end marker, exit 0
      //   injected, MALLOC_PERTURB_=165 -> abort at round 0, exit 134
      //   injected, NO MALLOC_PERTURB_  -> abort at round 0, exit 134
      //
      // ⚠️ SEPARATION IS TOTAL, BUT THE POISONING IS NOT WHAT PRODUCED IT, AND
      // THAT IS SAID OUT LOUD RATHER THAN LEFT IMPLIED. The injected build
      // fails IDENTICALLY with and without MALLOC_PERTURB_ — the third row is
      // the control on the control, and it is what forbids claiming the
      // poisoning discriminated. What actually separated is the harness's own
      // byte-for-byte content check and its completion markers.
      //
      // ⭐ AND THE FINDING THE THIRD ROW BUYS: a premature free on THIS path is
      // LOUD, not silent. Both injected arms abort inside zenoh's own object
      // pool (`zenoh-sync/src/object_pool.rs:96`, `Option::unwrap()` on None)
      // rather than returning plausible bytes. The seed expected this unit to
      // be able to build a SILENT use-after-free, since its shim is in scope
      // where earlier units' were not; measured, this particular free is not
      // silent. That is a partial answer, not a failure to produce one.
      //
      // The revert is proved by a BYTE-IDENTICAL REBUILD, never by a
      // marker-word grep over a tree that documents the marker:
      //   src/zenoh_dart.c        sha256 6902f463…
      //   libzenoh_dart.so (unstable) sha256 935e7ab8… — identical before and
      //   after the injection cycle.
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ═══════════════════════════════════════════════════════════════════════
  // Seed [10a] slice 12 — the zero-copy echo.
  //
  // ⛔ THE MEASUREMENT IS NOT IN THIS FILE, DELIBERATELY. A suite cell can
  // measure "after" and can never measure "before", so the numbers live in the
  // PR body and the plan archive. What is asserted here is behaviour that
  // would break if the mechanism changed — identity, consume-once, and
  // backing-transparency.
  //
  // ⭐ MEASURED, transient harness, interleaved, on an idle host:
  //
  //   payload   clone us/op            copy us/op              ratio
  //   1 MiB     3.05 / 2.90 / 2.92     90.99 / 87.36 / 96.33   ~30x
  //   64 KiB    2.17                    4.97                    2.3x
  //   4 KiB     2.22                    1.86                    0.8x
  //
  // ⭐ THE SHAPE PROVES MORE THAN THE RATIO. The clone is FLAT in payload size
  // (~2-3 us at every class) while the copy SCALES with it. Flatness is the
  // signature of a refcount increment; scaling is the signature of a memcpy.
  // A ratio alone could be explained by a faster copy; flatness cannot.
  //
  // ⚠️ AND THE HONEST HALF: below roughly 8 KiB the clone is NOT faster — at
  // 4 KiB it is slightly slower, because its ~2.2 us fixed cost exceeds a
  // small memcpy. "Zero-copy" is a statement about ALLOCATION, not a promise
  // of lower latency at every size. This mirrors slice 1's finding on the same
  // stack, from the other direction.
  //
  // ⛔ The copy baseline was taken AFTER the marshalling fix landed
  // (commit e1a425c), as criterion D requires — calibrating a zero-copy claim
  // against a defective copy path measures the wrong thing. And the win is not
  // double-counted: the record measures S7's 16 ms publish-side difference as
  // almost exactly that same marshalling cost.
  // ═══════════════════════════════════════════════════════════════════════
  group('The zero-copy echo (TCP 19729)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19729"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19729"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));
      await drainPendingFinalizers();
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    setUp(drainPendingFinalizers);

    test('echoing a retained payload delivers the identical bytes', () async {
      // Given: a retention-enabled subscriber that republishes each retained
      // payload through a second key, and a far-end subscriber on that key.
      const inKey = 'echo/in';
      const outKey = 'echo/out';
      // Invalid UTF-8 and two interior NULs: a copy that round-tripped through
      // a string would corrupt this, and an echo that re-encoded would too.
      final body = Uint8List.fromList([0xFF, 0x00, 0x41, 0x00, 0x80, 0xC0]);

      final echoer = subSession.declareSubscriber(inKey, retainPayload: true);
      addTearDown(echoer.close);
      final echoSub = echoer.stream.listen((s) {
        final z = s.payloadZBytes;
        if (z != null) pubSession.putBytes(outKey, z);
      });
      addTearDown(echoSub.cancel);

      final farEnd = subSession.declareSubscriber(outKey);
      addTearDown(farEnd.close);
      final seen = <Sample>[];
      final farSub = farEnd.stream.listen(seen.add);
      addTearDown(farSub.cancel);

      // When: the far end receives the echo
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (seen.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('the echo never reached the far end');
        }
        pubSession.putBytes(inKey, ZBytes.fromUint8List(body));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // Then: byte-for-byte what was published, through two hops.
      expect(seen.first.payloadBytes, equals(body));
    });

    test('the echo consumes the handle exactly once, and the NET is not what '
        'freed it', () async {
      // Given: a retained payload handed to putBytes, which consumes it
      const key = 'echo/consume';
      final body = Uint8List.fromList([0x45, 0x00, 0x43]);
      final subscriber = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(subscriber.close);
      final seen = <Sample>[];
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (seen.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('no sample arrived');
        }
        pubSession.putBytes(key, ZBytes.fromUint8List(body));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final retained = seen.first.payloadZBytes!;
      final before = finCount();

      // When: it is consumed by a publish
      pubSession.putBytes('echo/consume/out', retained);

      // Then: a second read is refused — consumed exactly once.
      expect(retained.toBytes, throwsStateError);

      // ⭐ AND THE COUNTER SAYS WHICH PATH FREED IT. Without this the cell
      // cannot tell `markConsumed` releasing the block from the finalizer
      // reclaiming it later — both leave a StateError behind.
      await gcPressure();
      expect(
        finCount() - before,
        equals(0),
        reason:
            'the finalizer fired for a handle a publish consumed, so '
            'markConsumed did not detach it from the net',
      );
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
