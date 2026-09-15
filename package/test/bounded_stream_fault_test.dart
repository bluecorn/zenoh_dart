import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Seed `[DM-bounded-stream]`: the drive loop's FAULT contract.
///
/// `PullSubscriber.stream`'s loop consumes the handle's own `recv()`, which can
/// **throw** rather than return a result — and the two throw classes have
/// opposite contracts:
///
/// - **`ZenohException`** is what canon calls a *call* failure. The channel is
///   alive, so the loop forwards the error and **keeps pulling**.
/// - **`StateError`** means the handle is closed or contended. Nothing is left
///   to pull, so the stream **terminates**.
///
/// ⚠️ And `recv()` throws **synchronously**, which is the subtlety this file
/// exists to pin: the call has to sit *inside* the loop's `try`, not merely be
/// awaited. An `async` drive whose returned future is ignored would leak that
/// throw to the zone instead of to the stream — silently, and only on a path
/// nobody exercises. Cell 36 runs inside `runZonedGuarded` for exactly that
/// reason: it fails if anything escapes.
void main() {
  group("The drive loop's fault contract (TCP 19596)", () {
    test('a StateError from the pull terminates the stream with an error, it '
        'does not vanish', () async {
      final session = await Session.open(
        config: Config()
          ..insertJson5('mode', '"peer"')
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19596"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      addTearDown(session.close);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final pull = session.declarePullSubscriber(
        'zenoh/dart/test/bsfault/contended',
        capacity: 8,
      );
      addTearDown(pull.close);

      // A recv() is now pending ON THE HANDLE. The drive loop's own first
      // recv(), issued synchronously inside `onListen`, therefore throws
      // `StateError: a recv() is already pending` -- synchronously.
      final userRecv = pull.recv();

      final events = <String>[];
      final done = Completer<void>();
      runZonedGuarded(
        () {
          pull.stream.listen(
            (_) => events.add('data'),
            onError: (Object e) => events.add('error:${e.runtimeType}'),
            onDone: () {
              events.add('done');
              if (!done.isCompleted) done.complete();
            },
          );
        },
        // ⚠️ THE ASSERTION THAT MATTERS. If the loop merely awaited a call
        // that throws synchronously, the throw would arrive here instead of on
        // the stream, and the cell below would still see an empty `events`
        // list rather than a diagnosis.
        (e, st) => events.add('UNHANDLED:${e.runtimeType}'),
      );

      await done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('the stream never completed; events=$events'),
      );

      expect(
        events,
        equals(['error:StateError', 'done']),
        reason:
            'the StateError must arrive as a stream ERROR EVENT and the '
            'stream must then complete -- nothing may escape to the zone',
      );

      // Release the handle's own waiter so the teardown is clean.
      pull.close();
      await userRecv;
    }, timeout: const Timeout(Duration(seconds: 90)));

    group('Live-fire: the injected allocation failure', () {
      late Directory tmp;
      late String injectorPath;
      var haveClang = false;

      setUpAll(() async {
        tmp = await Directory.systemTemp.createTemp('zd_bstream_fault');
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

      /// Runs the fault harness, optionally under the injector.
      ///
      /// The threshold sits **above** every declaration-time shim allocation
      /// and **below** the harness's oversized payload, so the only NULL in
      /// the process is the pull's payload copy.
      Future<ProcessResult> runHarness({required bool injected}) {
        return Process.run(
          Platform.resolvedExecutable,
          ['run', 'test/helpers/bounded_stream_fault_harness.dart'],
          environment: injected
              ? {'ZD_FAIL_MALLOC_OVER': '400000', 'LD_PRELOAD': injectorPath}
              : null,
        );
      }

      test('the injector control -- no injection, no error', () async {
        if (!haveClang) {
          // ⚠️ RUNTIME, never a `skip:` argument: `package:test` evaluates
          // `skip:` when the test is DECLARED, which is before `setUpAll` has
          // run, so it would read the initial `false` and skip every cell
          // unconditionally on a healthy tree.
          markTestSkipped('clang unavailable -- cannot build the injector');
          return;
        }
        final control = await runHarness(injected: false);
        final out = '${control.stdout}${control.stderr}';

        // THE CONTROL IS LOAD-BEARING: it establishes that the two markers the
        // next cell reads are ABSENT when nothing is injected, so their
        // presence there is attributable to the injected failure rather than
        // to anything the harness does on its own.
        expect(out, contains('HARNESS_READY'), reason: out);
        expect(out, contains('SAMPLE_OK'), reason: out);
        expect(out, isNot(contains('STREAM_ERROR=')), reason: out);
        expect(out, isNot(contains('INJECTOR_FIRED')), reason: out);
        expect(out, contains('HARNESS_OK'), reason: out);
        expect(out, contains('HARNESS_DONE'), reason: out);
        expect(control.exitCode, isZero, reason: out);
      }, timeout: const Timeout(Duration(seconds: 180)));

      test('a ZenohException from the pull surfaces as a stream error and the '
          'stream SURVIVES', () async {
        if (!haveClang) {
          markTestSkipped('clang unavailable -- cannot build the injector');
          return;
        }
        final injected = await runHarness(injected: true);
        final out = '${injected.stdout}${injected.stderr}';

        // ⭐ BOTH ARMS, VERBATIM, from one build minutes apart. This is what
        // makes the leg evidence rather than decoration -- a run that reads
        // identically either way is worth nothing while looking like proof.
        //
        //   CONTROL (no LD_PRELOAD):
        //     HARNESS_READY
        //     SAMPLE_OK len=524288
        //     SAMPLE_OK len=5
        //     HARNESS_OK
        //     HARNESS_DONE
        //
        //   INJECTED (ZD_FAIL_MALLOC_OVER=400000):
        //     HARNESS_READY
        //     INJECTOR_FIRED size=524288
        //     STREAM_ERROR=ZenohException
        //     SAMPLE_OK len=5
        //     HARNESS_OK
        //     HARNESS_DONE
        //
        // `size=524288` is the payload copy exactly, so the NULL landed on the
        // allocation under test and not on something incidental. The large
        // sample is gone and the SMALL ONE STILL ARRIVES -- which only a loop
        // that kept pulling could deliver.

        // Without this the cell proves nothing: it would be satisfied by a run
        // in which the branch under test was never entered at all.
        expect(
          out,
          contains('INJECTOR_FIRED'),
          reason: 'the injected branch was never entered:\n$out',
        );
        expect(
          out,
          contains('STREAM_ERROR=ZenohException'),
          reason:
              'the call failure must reach the listener as a stream error '
              'event:\n$out',
        );
        // ⭐ THE CONTRACT. Canon calls an allocation failure a CALL failure,
        // not a channel state, so the loop forwards it and KEEPS PULLING --
        // and the small sample published afterwards is the proof, because only
        // a live loop could have delivered it.
        expect(
          out,
          contains('SAMPLE_OK'),
          reason: 'the stream must stay alive after a ZenohException:\n$out',
        );
        expect(
          out,
          isNot(contains('STREAM_DONE')),
          reason:
              'a ZenohException must NOT terminate the stream -- that is '
              "the StateError arm's contract, not this one:\n\$out",
        );
        expect(out, contains('HARNESS_DONE'), reason: out);
        expect(injected.exitCode, isZero, reason: out);
      }, timeout: const Timeout(Duration(seconds: 180)));
    });
  });
}
