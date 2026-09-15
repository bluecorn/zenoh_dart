// The determination for the session-open-offload unit: does the calling
// isolate stay live across `Session.open`?
//
// The first cell was written against the SYNCHRONOUS `Session.open` and read
// FROZEN on the shipped build — ticks_during=0 against a threshold of 5, at
// wall_ms 537/529/538 over three runs. That reading is the control the retype
// ruling was made on, and it is committed verbatim at
// `development/research/probes-10b-20260829/prefix-red-run.txt`. The cell now
// carries its `await` and reads live; both readings are on the record, which
// is the point of writing it before the fix rather than after.
//
// Evidence, with the conditions the numbers were taken under:
//   development/research/probes-10b-20260829/
//   development/reviews/probes-ca2-10b-20260829/   (the twenty-ninth pass)

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// This unit's allocated port block is 19700-19709; 19700 is the address the
/// control rests on and **nothing is ever started on it**.
const int deadPort = 19700;

/// The tick instrument's period. 25 ms over the ~500 ms open window gives a
/// theoretical ceiling of 20 ticks — enough headroom that a threshold well
/// below it is not a timing-resolution artefact.
const Duration tickPeriod = Duration(milliseconds: 25);

/// Long enough for the periodic timer to have established itself and fired at
/// least once before the measured window opens.
const Duration timerSettleDelay = Duration(milliseconds: 50);

/// The idle window the positive control runs across — the same length as the
/// open wait it is calibrating against (504-507 ms, medians of three).
const Duration openWaitWindow = Duration(milliseconds: 500);

/// The config the determination is taken under, stated inline rather than
/// borrowed from a helper, because **which** config is in play is the whole
/// question: the wait is a property of a *pair* of settings, and the wrong pair
/// silently discharges the control.
///
/// - `mode: peer` — canon's default mode, stated rather than assumed.
/// - `scouting/multicast/enabled: false` — so the number does not depend on
///   whatever the real LAN happens to contain.
/// - `connect/endpoints: [tcp/127.0.0.1:19700]` — a **dead** endpoint. Measured
///   504-505 ms with gossip either way, LAN-independently.
///
/// ⛔ Deliberately NOT the quiet endpoint-free config (measured **1 ms**), and
/// deliberately NOT this endpoint aimed at a live quiet in-process listener
/// (measured **2 ms**). Either would leave nothing to freeze and the cell would
/// pass for the wrong reason.
Config deadEndpointConfig() => Config()
  ..insertJson5('mode', '"peer"')
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$deadPort"]');

/// A config canon FAILS to open — client mode with no peer and multicast
/// scouting off, so zenoh refuses on the config alone. Measured rc -4 in ~1 ms.
Config canonFailingConfig() => Config()
  ..insertJson5('mode', '"client"')
  ..insertJson5('scouting/multicast/enabled', 'false');

/// A config that opens immediately — measured ~1 ms, rc 0.
Config quietConfig() =>
    Config()..insertJson5('scouting/multicast/enabled', 'false');

/// The port the config-fidelity cell listens on. Inside this unit's block
/// (19700-19709) and deliberately NOT [deadPort], which stays dead: the whole
/// determination above rests on nothing ever listening there.
const int listenPort = 19701;

/// The ceiling every wait in the concurrency cells runs under.
///
/// Deliberately far above the ~505 ms it bounds. It is a BACKSTOP that turns a
/// lost completion post into a red cell carrying a diagnosis, never a timing
/// assertion -- a tight value here would turn scheduler noise into a flake.
const Duration openDeadline = Duration(seconds: 15);

/// Awaits [future] under [openDeadline], failing with a diagnosis that names
/// what was being waited for instead of hanging.
///
/// ⛔ The only thing that can complete an offloaded open is the worker's
/// completion post. Nothing in the calling isolate can fail a future that
/// never receives one, so every await on an open goes through here.
Future<T> awaitOpenOr<T>(Future<T> future, String waitingFor) {
  return future.timeout(
    openDeadline,
    onTimeout: () => fail(
      'deadline: ${openDeadline.inSeconds}s elapsed while waiting for '
      '$waitingFor. Observed instead: the future was still pending, so no '
      'completion post ever arrived from the worker thread',
    ),
  );
}

void main() {
  group('Session.open — the calling isolate across the open', () {
    test('the calling isolate stays live across the open', () async {
      var ticks = 0;
      final timer = Timer.periodic(tickPeriod, (_) => ticks++);
      await Future<void>.delayed(timerSettleDelay);

      final before = ticks;
      final stopwatch = Stopwatch()..start();
      final session = await Session.open(config: deadEndpointConfig());
      stopwatch.stop();
      // Counts the timer callbacks that ran while the open was in flight. On
      // the synchronous signature this read 0, every time.
      final during = ticks - before;
      timer.cancel();
      session.close();

      final wallMs = stopwatch.elapsedMilliseconds;
      printOnFailure('SYNC OPEN: wall_ms=$wallMs ticks_during=$during');

      expect(
        wallMs,
        greaterThanOrEqualTo(400),
        reason:
            'the window has to be real before a tick count means anything — a '
            'low count across a 2 ms open proves nothing. Measured 504-505 ms '
            'against this dead endpoint; a shorter wall here means the config '
            'took a fast path and the control has silently discharged',
      );
      expect(
        during,
        greaterThanOrEqualTo(5),
        reason:
            'the calling isolate must stay live across the open. 5 is a '
            'quarter of the 25 ms timer ceiling over this window and well '
            'above the idle-window floor the positive control measures, so '
            'it discriminates without resting on scheduler precision',
      );
    });

    test('the tick instrument is sound across an idle window of the same '
        'length (positive control)', () async {
      var ticks = 0;
      final timer = Timer.periodic(tickPeriod, (_) => ticks++);
      await Future<void>.delayed(timerSettleDelay);

      final before = ticks;
      await Future<void>.delayed(openWaitWindow);
      final during = ticks - before;
      timer.cancel();

      printOnFailure('IDLE WINDOW: ticks_during=$during');

      expect(
        during,
        greaterThanOrEqualTo(10),
        reason:
            'with no zenoh call in flight the same timer over the same window '
            'must tick freely. A failure here indicts the instrument or the '
            'machine, not the open — which is what makes a red first cell '
            'attributable',
      );
    });

    test('the configured endpoint is genuinely dead, so the control cannot '
        'silently discharge', () async {
      Object? error;
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          deadPort,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
      } on Object catch (e) {
        error = e;
      }

      expect(
        error,
        isA<SocketException>(),
        reason:
            'the ~500 ms wait is a property of an UNREACHABLE configured '
            'endpoint. If something is listening on 127.0.0.1:$deadPort the '
            'open takes the 2 ms path and the first cell would pass on the '
            'shipped build for the wrong reason. This unit starts nothing on '
            'this port',
      );
    });
  });

  group('Session.open — the rc contract and the completion channel', () {
    test('a canon failure arrives as a REJECTED FUTURE, not a sync throw', () {
      // The whole point of the rc contract: the wrapper returns before z_open
      // finishes, so it cannot possibly know canon's outcome. Calling WITHOUT
      // await must therefore hand back a future rather than throw.
      late final Future<Session> pending;
      expect(
        () => pending = Session.open(config: canonFailingConfig()),
        returnsNormally,
        reason:
            'a canon failure that threw synchronously would prove the '
            'wrapper waited for z_open, which is the freeze this unit removes',
      );

      return expectLater(
        pending,
        throwsA(
          isA<ZenohException>().having(
            (e) => e.returnCode,
            'returnCode',
            lessThan(0),
          ),
        ),
        reason:
            "canon's failures are NEGATIVE and arrive on the future; the "
            'positive codes are start failures and arrive synchronously',
      );
    });

    test('a spent config still throws SYNCHRONOUSLY, before any future', () {
      final spent = quietConfig();
      // Consume it.
      return Session.open(config: spent).then((session) {
        session.close();
        // No await on the second call: `open` is deliberately not an `async`
        // body, so a pre-flight programming error surfaces at the CALL, not at
        // the await. This is what keeps a tear-off discriminating.
        expect(
          () => Session.open(config: spent),
          throwsStateError,
          reason:
              'an async body would have wrapped this into a rejected '
              'future and the call site would look fine',
        );
      });
    });

    test('the session is usable and closes cleanly through the shim', () async {
      final session = await Session.open(config: quietConfig());

      expect(session.zid.bytes, hasLength(16));
      expect(session.close, returnsNormally);
      expect(session.close, returnsNormally, skip: false);

      // Structural, and load-bearing: the block is SHIM-owned now, so a
      // caller-side free would be a cross-allocator free. Assert the routing
      // rather than trusting that nobody re-adds calloc.free during a later
      // edit -- a wrong free of this kind does not fail a behavioural cell.
      final source = File('lib/src/session.dart').readAsStringSync();
      final closeStart = source.indexOf('  void close() {');
      expect(closeStart, greaterThanOrEqualTo(0));
      final closeBody = source.substring(closeStart, closeStart + 900);
      expect(closeBody, contains('zd_session_close_drop'));
      expect(
        closeBody,
        isNot(contains('calloc.free(_ptr)')),
        reason: 'the shim malloc-ed this block, so the shim frees it',
      );
    });

    test('the config is marked consumed on BOTH paths', () async {
      final onSuccess = quietConfig();
      (await Session.open(config: onSuccess)).close();
      expect(
        () => onSuccess.nativePtr,
        throwsStateError,
        reason:
            'z_config_take runs before any fallible step, so the consume '
            'is unconditional',
      );

      final onFailure = canonFailingConfig();
      await expectLater(
        Session.open(config: onFailure),
        throwsA(isA<ZenohException>()),
      );
      expect(
        () => onFailure.nativePtr,
        throwsStateError,
        reason:
            'a failing open consumes its config exactly as a succeeding '
            'one does; deferring the mark to the post would let a dropped '
            "Config's finalizer fire while the worker is inside z_open",
      );
    });
  });

  // These two cases CANNOT be produced by the shim, which contracts exactly one
  // well-formed post per successful start. They are driven through the seam,
  // because the failure they guard against is a HANG -- and a startup call's
  // hang is total: no in-isolate timeout can rescue a future whose only
  // completion path threw.
  group('Session.open — the completion handler cannot strand the future', () {
    test('a malformed post fails the future instead of hanging', () async {
      final completer = Completer<Session>();

      // Not the contracted three-element array. The old shape of this defect
      // was a handler that threw out of its listener and left the future
      // pending for the life of the isolate.
      completeOpenFromPost(
        'not the contracted array',
        completer,
        callerSuppliedConfig: true,
      );

      expect(completer.isCompleted, isTrue);
      await expectLater(completer.future, throwsA(isA<Object>()));
    });

    test('a duplicate or late post is inert', () async {
      final completer = Completer<Session>();

      // First post: a canon failure, so no Session is constructed and the
      // cell needs no native cleanup.
      completeOpenFromPost(
        <dynamic>[-4, 0, null],
        completer,
        callerSuppliedConfig: true,
      );
      expect(completer.isCompleted, isTrue);

      // Second post on the same completer must be a no-op, not a
      // "Future already completed" thrown out of the listener.
      expect(
        () => completeOpenFromPost(
          <dynamic>[0, 12345, null],
          completer,
          callerSuppliedConfig: true,
        ),
        returnsNormally,
      );

      await expectLater(completer.future, throwsA(isA<ZenohException>()));
    });

    test('a canon failure lets nothing escape', () async {
      final completer = Completer<Session>();

      // What the worker actually posts on a canon failure: canon's negative
      // code, a session address of ZERO because the worker already freed the
      // block, and the detail it captured on its own thread.
      completeOpenFromPost(
        <dynamic>[-4, 0, Uint8List.fromList('boom'.codeUnits)],
        completer,
        callerSuppliedConfig: false,
      );

      final error = await completer.future.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(
        error,
        isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -4),
      );
      // The detail travelled WITH the post rather than being read back from a
      // thread-local belonging to a thread that did not make the call.
      expect((error! as ZenohException).message, contains('boom'));
    });

    test('a start failure renders distinctly from a canon failure', () {
      // Positive code, synchronous channel: nothing ran.
      expect(openStartFailureMessage(12), contains('ZD_OPEN_EALLOC'));
      expect(openStartFailureMessage(13), contains('ZD_OPEN_ETHREAD'));
      expect(openStartFailureMessage(12), contains('never opened'));
      // An unmapped start code degrades to the bare number.
      expect(openStartFailureMessage(99), contains('99'));
      expect(openStartFailureMessage(99), isNot(contains('ZD_OPEN')));
    });
  });

  // THE START-FAILURE ARM. `zd_open_session_async`'s return means "did it
  // START", not "did it succeed" -- so a non-zero return means nothing ran, no
  // post is coming, and Dart must throw rather than await a completion that can
  // never arrive.
  //
  // ⛔ EVERY CELL HERE IS A BOUNDED SUBPROCESS. A start failure that hung
  // instead of throwing would hang the parent too, and no in-isolate deadline
  // can fire against it -- the same property that made the pre-fix freeze
  // unguardable from inside.
  group('Session.open — a failure to START is synchronous and positive', () {
    late Directory tmp;
    late String injectorPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_open_startfail');
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

    /// The offloaded open's two heap blocks, at the EXACT sizes measured on
    /// this path. An exact size is a sizeof and a sizeof can drift; it fails
    /// SAFE when it does, because the `INJECTOR_FIRED` control below then
    /// disappears and the cell goes red rather than quietly passing.
    const workerBlockBytes = '2024';
    const sessionBlockBytes = '8';

    Future<ProcessResult> runHarness({String? failSize}) {
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/open_start_failure_harness.dart'],
        environment: failSize == null
            ? null
            : {'ZD_FAIL_MALLOC_SIZE': failSize, 'LD_PRELOAD': injectorPath},
      );
    }

    test('the control opens cleanly and fires no injector', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }
      final r = await runHarness();
      final out = '${r.stdout}${r.stderr}';
      // LOAD-BEARING: without it, a clean sweep in the cells below would be
      // indistinguishable from an inert injector.
      expect(out, contains('HARNESS_OPENED'));
      expect(out, isNot(contains('INJECTOR_FIRED')));
      expect(out, isNot(contains('HARNESS_SYNC_THREW')));
      expect(out, contains('HARNESS_DONE'));
      expect(r.exitCode, isZero);
    });

    for (final (label, size) in [
      ('worker block', workerBlockBytes),
      ('session block', sessionBlockBytes),
    ]) {
      test('a failed $label allocation throws SYNCHRONOUSLY as 12', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the injector');
          return;
        }
        final r = await runHarness(failSize: size);
        final out = '${r.stdout}${r.stderr}';

        // Positive control on the instrument: the branch was actually entered.
        expect(
          out,
          contains('INJECTOR_FIRED size=$size'),
          reason:
              'the injector must have failed the $label allocation; if it '
              'fired on nothing the sizeof has drifted',
        );
        // The marker itself carries the synchronicity: the harness catches
        // around a call it does NOT await, so an asynchronous failure could
        // not produce this line.
        expect(out, contains('HARNESS_SYNC_THREW code=12'));
        expect(
          out,
          isNot(contains('HARNESS_OPENED')),
          reason: 'nothing started, so nothing may have opened',
        );
        // Reached the end rather than hanging on a post that never comes.
        expect(out, contains('HARNESS_DONE'));
        expect(r.exitCode, isZero);
      });
    }

    test('a start failure and a canon failure are distinguishable', () {
      // THE WHOLE POINT OF THE SPLIT, asserted on the renderings because the
      // two travel on different channels: a start failure is a SYNCHRONOUS
      // throw with a POSITIVE code, a canon failure a REJECTED FUTURE with
      // canon's NEGATIVE code. The channel discriminates; the sign confirms.
      expect(openStartFailureMessage(12), contains('never opened'));
      expect(openStartFailureMessage(13), contains('never opened'));
      expect(
        openFailureMessage(-4, callerSuppliedConfig: true),
        isNot(contains('never opened')),
      );
    });

    // ⛔ THE 13 (ZD_OPEN_ETHREAD) ARM HAS NO COMMITTABLE DRIVER, and the
    // absence is stated rather than hidden.
    //
    // It WAS driven, by a temporary local patch forcing the pthread_create
    // failure branch -- the technique of record, never committed. Measured on
    // 2026-08-30: 20 of 20 iterations threw synchronously with code 13, and 20
    // of 20 again under MALLOC_PERTURB_=165 with no abort, which is what shows
    // the cleanup path (config drop, session-block free, worker free) is
    // correct rather than merely reached. The patch was reverted and both
    // preset pairs rebuilt to a sha identical to the pre-patch build.
    //
    // The predecessor's named candidate -- an RLIMIT_NPROC / `ulimit -u` clamp
    // -- is a MEASURED NULL RESULT and is not used: swept across its usable
    // range with a control, there is no value at which the VM boots and OUR
    // thread is the one refused. Ours is requested last, so the ceiling always
    // binds on the VM or on tokio first.
    //
    // Evidence: development/research/probes-10b-20260829/start-failure.md
  });

  // THE CANON-FAILURE ARM, and Layer 2 travelling with the post.
  group('Session.open — a canon failure rejects the future', () {
    test("the future rejects with canon's own negative code", () async {
      Object? error;
      try {
        (await Session.open(config: canonFailingConfig())).close();
      } on Object catch (e) {
        error = e;
      }

      expect(
        error,
        isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -4),
      );
      // Slice 2's Layer-1 rendering is present, and still qualified so the
      // symbol cannot be read as a diagnosis canon never made.
      final message = (error! as ZenohException).message;
      expect(message, contains('Z_ENETWORK'));
      expect(message, contains('every open failure'));
      expect(message, contains('not specifically a network fault'));
    });

    test("the detail is the FAILING CALL's own, and rides the post", () async {
      // ⚠️ THIS CELL NAMES THE VARIANT IT REQUIRES. The capture is compiled
      // out when Z_FEATURE_UNSTABLE_API is absent, and the stable build
      // defines neither feature, so the post carries no detail at all there.
      // The two "defaults" are DIFFERENT
      // objects: CMake's default variant is `stable`, while the variant the
      // pubspec declares -- and therefore the one ./scripts/test.sh runs -- is
      // `unstable`. Conflating them is a false green, so both branches are
      // asserted rather than one being assumed.
      Object? error;
      try {
        (await Session.open(config: canonFailingConfig())).close();
      } on Object catch (e) {
        error = e;
      }
      final message = (error! as ZenohException).message;

      if (ZenohFeatures.hasUnstableApi) {
        // Canon's own words for THIS failure, captured on the worker
        // immediately after the failing call and carried in the post.
        expect(
          message,
          contains('Zenoh says:'),
          reason:
              'the unstable native exposes zc_get_last_error, so the '
              'detail must travel',
        );
        expect(message, contains('No peer specified'));
      } else {
        // The honest fallback: no detail is reachable, so the message is the
        // base rendering and says nothing it cannot support.
        expect(
          message,
          isNot(contains('Zenoh says:')),
          reason:
              'the capture is compiled out with the unstable API off, so '
              'nothing travels with the post; the base text is the correct '
              'degrade',
        );
      }
    });

    test(
      'the Layer 2 ground is stated in the code, not just in a commit',
      () async {
        // ⚠️ RE-POINTED by seed [D1] slice 1. Two of these assertions were
        // pinned to a signature and a storage class that moved, and they went
        // RED on correct code. Neither was deleted and neither was loosened
        // into a pattern that would pass either way -- what each one WATCHES is
        // unchanged; what it names is now the surviving mechanism.
        //
        // The ground itself did not change: this path is safe because the
        // detail is captured ON THE WORKER and posted BY VALUE, so there is no
        // cross-call read-back. What changed is WHY no other operation's text
        // can reach it. It used to be "the worker is a fresh thread, so its
        // _Thread_local buffer is zero-initialised". The thread-local is gone
        // -- deleted across the whole shim, because it was measured returning
        // another operation's message 249 times in 300 on a deferred read -- so
        // the ground is now the stronger one the config entries also stand on:
        // the detail lands in storage LOCAL TO THIS CALL.
        final shim = File('../src/zenoh_dart.c').readAsStringSync();
        final workerStart = shim.indexOf('static void* _zd_open_worker(');
        expect(workerStart, greaterThanOrEqualTo(0));
        final worker = shim.substring(workerStart, workerStart + 2200);

        expect(worker, contains('TRAVELS WITH THE POST'));
        expect(
          worker,
          contains('local to this call'),
          reason:
              'was pinned to the deleted thread-local buffer and its '
              'zero-initialised ground; the replacement ground is the '
              'call-local buffer, and a revert to any durable storage fails '
              'here',
        );
        // And the mechanism matches the claim: the capture happens here, into
        // storage this frame owns. The empty-paren form this replaced named a
        // signature that no longer exists -- the helper now takes the buffer,
        // its capacity and an out-length, so a parameterless call would not
        // compile.
        expect(worker, contains('_zd_capture_last_error(detail_buf'));

        final dart = File('lib/src/session.dart').readAsStringSync();
        expect(
          dart,
          isNot(contains('zd_last_error_message')),
          reason:
              'unchanged, and it now holds A FORTIORI: the reader was '
              'deleted from the shim and is exported by neither native, so '
              'the read-back no longer exists anywhere to be reintroduced '
              'accidentally -- this cell has gone from watching one file to '
              'watching for a resurrection',
        );
      },
    );

    test('the detail is length-carried, never kString', () {
      // A kString truncates at an interior NUL -- the seam this repo already
      // closed on the parameters path. The post's third element must go
      // through the length-carried helper.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final workerStart = shim.indexOf('static void* _zd_open_worker(');
      final worker = shim.substring(workerStart, workerStart + 3000);
      expect(worker, contains('_zd_str_to_cobject(detail, detail_len'));
      // ⚠️ The negative targets the ASSIGNMENT, not the word. The block above
      // explains in prose why kString is wrong, so a bare `isNot(contains(
      // 'Dart_CObject_kString'))` matches its own documentation and fails on
      // correct code -- which is exactly what it did when first written.
      expect(
        worker,
        isNot(contains('c_detail.type = Dart_CObject_kString')),
        reason: 'kString truncates at an interior NUL',
      );
    });
  });

  // CONCURRENCY -- a state that COULD NOT EXIST before the offload. The
  // synchronous call held the calling isolate for the whole wait, so a second
  // open could not be started, let alone overlap; nothing in the corpus could
  // have been written to observe it.
  //
  // Every cell below states its own config in its own body. The wait is a
  // property of a PAIR of settings, and the wrong pair discharges the
  // measurement silently rather than failing it.
  group('Session.open — concurrent opens', () {
    test('two opens in flight complete independently', () async {
      // Config, both legs: deadEndpointConfig() -- peer, multicast off,
      // connect to the dead 127.0.0.1:19700. ~505 ms each, LAN-independent,
      // and long enough that the two windows genuinely overlap instead of one
      // finishing before the other is started. Two Config instances, because
      // an open consumes the one it is given.
      final firstOpen = Session.open(config: deadEndpointConfig());
      final secondOpen = Session.open(config: deadEndpointConfig());

      final first = await awaitOpenOr(firstOpen, 'the first concurrent open');
      final second = await awaitOpenOr(
        secondOpen,
        'the second concurrent '
        'open',
      );
      addTearDown(first.close);
      addTearDown(second.close);

      expect(
        identical(first, second),
        isFalse,
        reason: 'two opens must hand back two Session objects',
      );
      expect(
        first.zid,
        isNot(equals(second.zid)),
        reason:
            'each open must carry its OWN native session. Equal zids '
            'would mean one worker post was delivered to both futures, which '
            'is the cross-delivery this cell exists to rule out. Observed '
            '${first.zid.toHexString()} and ${second.zid.toHexString()}',
      );
      // Live and usable through the shim, not merely distinct: a session
      // whose block went to the other future fails HERE rather than comparing
      // unequal above.
      expect(first.peersZid, returnsNormally);
      expect(second.peersZid, returnsNormally);
    });

    test(
      'a shorter open completes first, so the calls genuinely overlap',
      () async {
        // Two configs, stated here because the cell IS the comparison between
        // them:
        //  * slow -- deadEndpointConfig(): peer, multicast off, dead
        //    127.0.0.1:19700. Measured 505 ms synchronous, 511 ms offloaded.
        //  * fast -- quietConfig(): multicast off and no endpoint at all.
        //    Measured 1 ms synchronous, 5 ms offloaded.
        final order = <String>[];
        final stopwatch = Stopwatch()..start();
        int? fastMs;
        int? slowMs;

        // The SLOW one starts first, and neither is awaited here. Under the
        // synchronous signature this single line held the isolate for the whole
        // ~505 ms, so the fast open could not even have been STARTED until it
        // returned.
        final slowDone = Session.open(config: deadEndpointConfig()).then((s) {
          order.add('slow');
          slowMs = stopwatch.elapsedMilliseconds;
          return s;
        });
        final fastDone = Session.open(config: quietConfig()).then((s) {
          order.add('fast');
          fastMs = stopwatch.elapsedMilliseconds;
          return s;
        });

        final slow = await awaitOpenOr(slowDone, 'the slow dead-endpoint open');
        final fast = await awaitOpenOr(fastDone, 'the fast quiet open');
        stopwatch.stop();
        addTearDown(slow.close);
        addTearDown(fast.close);

        final totalMs = stopwatch.elapsedMilliseconds;
        printOnFailure(
          'OVERLAP: order=$order fast_ms=$fastMs slow_ms=$slowMs '
          'total_ms=$totalMs',
        );

        expect(
          order,
          equals(<String>['fast', 'slow']),
          reason:
              'the fast open was started SECOND, so it can only finish '
              'first if the two waits actually overlapped',
        );
        // ⚠️ THE DISCRIMINATING NUMBER IS THIS ONE, not the total. Serial
        // execution of these two configs sums to ~506 ms and overlapped
        // execution takes ~505 ms -- one millisecond apart, so no total-wall
        // bound can tell them apart, and a bound that tight would be measuring
        // scheduler noise. What separates the two worlds by two orders of
        // magnitude is WHEN THE FAST OPEN COMPLETED: ~5 ms overlapped against
        // ~506 ms serial, because serially it could not have started earlier.
        // 200 ms sits 40x above the measured value and 2.5x below the serial
        // one -- headroom on both sides.
        expect(
          fastMs,
          lessThan(200),
          reason:
              'the fast open must complete while the slow one is still in '
              'flight. A value near 500 ms means it waited for the slow open, '
              'i.e. the two ran serially',
        );
        expect(
          slowMs,
          greaterThanOrEqualTo(400),
          reason:
              'the slow leg has to have been slow or there was no overlap '
              'to observe. Measured 505-512 ms against this dead endpoint',
        );
        // A gross-regression ceiling only, for the reason given above: it
        // cannot discriminate serial from overlapped and is not asked to.
        expect(totalMs, lessThan(1500));
      },
    );
  });

  // ⚠️ WHY THIS CELL EXISTS AT ALL: a truncated config still opens a session,
  // so no other assertion in this file can see a content loss. The offload
  // moves the config by canon's own z_config_take and copies no bytes, so an
  // n/a answer was pre-authorised -- it is proved behaviourally anyway,
  // because "no bytes are copied" is a claim about the code as it stands and
  // this cell holds whatever a later edit does to it.
  group('Session.open — the config survives the heap hop', () {
    test(
      'a listen endpoint carried through the offload is really listening',
      () async {
        // Configs, stated here rather than inherited:
        //  * listener -- listen/endpoints tcp/127.0.0.1:19701, with multicast
        //    off so the reading does not depend on what the LAN contains.
        //  * connector -- multicast AND gossip both off, connect/endpoints to
        //    the same address. With every discovery mechanism disabled the only
        //    route to the listener is the configured endpoint, so a peer
        //    appearing at all is proof that the listener's own endpoint
        //    survived the hop into the worker's heap block.
        final listener = await awaitOpenOr(
          Session.open(
            config: Config()
              ..insertJson5('mode', '"peer"')
              ..insertJson5('scouting/multicast/enabled', 'false')
              ..insertJson5(
                'listen/endpoints',
                '["tcp/127.0.0.1:$listenPort"]',
              ),
          ),
          'the listening session to open',
        );
        addTearDown(listener.close);

        final connector = await awaitOpenOr(
          Session.open(
            config: Config()
              ..insertJson5('mode', '"peer"')
              ..insertJson5('scouting/multicast/enabled', 'false')
              ..insertJson5('scouting/gossip/enabled', 'false')
              ..insertJson5(
                'connect/endpoints',
                '["tcp/127.0.0.1:$listenPort"]',
              ),
          ),
          'the connecting session to open',
        );
        addTearDown(connector.close);

        // Bounded convergence: poll until the peer appears or the deadline
        // expires. Never a bare wait -- if the link never forms there is
        // nothing to complete, so the loop has to end by itself and report.
        final deadline = DateTime.now().add(openDeadline);
        var peers = connector.peersZid();
        while (peers.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          peers = connector.peersZid();
        }
        printOnFailure('CONFIG FIDELITY: peers=${peers.length}');

        expect(
          peers,
          contains(listener.zid),
          reason:
              'waited up to ${openDeadline.inSeconds}s for the connector to '
              "see the listener's zid ${listener.zid.toHexString()} through "
              'peersZid(), and observed ${peers.length} peer(s): '
              '${peers.map((p) => p.toHexString()).toList()}. Multicast and '
              'gossip are both off on the connector, so the configured connect '
              'endpoint is its only route: an empty list means the listener '
              'never listened on tcp/127.0.0.1:$listenPort, i.e. the config '
              'lost its content on the way through the worker',
        );
      },
    );
  });

  // ⛔ THE RULE THE CELLS ABOVE ARE WRITTEN UNDER, made checkable. The fast
  // and default paths differ by THREE ORDERS OF MAGNITUDE (1 ms against
  // 508 ms, measured), and the trigger is a property of the pair of settings
  // rather than of any one of them. A config built once in a shared setup and
  // inherited would let a single later edit move every timing cell in the
  // file at once, with no cell mentioning it.
  group('Session.open — every timing cell states its own config', () {
    test('no cell in this file inherits a config from shared setup', () {
      final source = File('test/session_open_offload_test.dart')
          .readAsStringSync();

      // ⚠️ THE NEEDLES ARE ASSEMBLED AT RUNTIME. Written as plain literals
      // they would appear in this cell's own source -- which is the text the
      // cell reads -- so the instrument would match itself and go red on a
      // clean file.
      const paren = '(';
      const configNeedle = 'Config$paren';
      var scanned = 0;

      for (final marker in ['setUp$paren', 'setUpAll$paren']) {
        var at = source.indexOf(marker);
        while (at >= 0) {
          // The window runs to the next cell, which is where a shared-setup
          // body necessarily ends in this file's layout.
          final nextTest = source.indexOf('\n    test$paren', at);
          final end = nextTest < 0 ? source.length : nextTest;
          expect(
            source.substring(at, end),
            isNot(contains(configNeedle)),
            reason:
                'a shared $marker block builds a Config, so a cell below '
                'it inherits the config its timing depends on instead of '
                'stating it',
          );
          scanned++;
          at = source.indexOf(marker, at + 1);
        }
      }

      // Positive control: without it, an instrument that matched nothing
      // would pass exactly as loudly as a clean file does.
      expect(
        scanned,
        greaterThanOrEqualTo(1),
        reason:
            'the scan must have found at least the start-failure group '
            'shared setup. Zero windows means the markers matched nothing, '
            'and the cell passed vacuously',
      );
    });
  });
}
