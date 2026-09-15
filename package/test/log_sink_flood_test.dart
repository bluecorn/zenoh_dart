// Seed [D1] slice 9 — a log flood does not back-pressure zenoh, and a starved
// loop does not grow without bound.
//
// ⛔ EVERY LEG HERE CARRIES BOTH-WAYS CALIBRATION, because a resource leg with
// only one arm is worth nothing while looking like proof. Two wall times that
// match are equally consistent with "the post never blocks" and with "this
// instrument cannot see blocking at all". So the defect is INJECTED — a
// sibling hook that sleeps inside the post — and the armed run must separate
// widely from the unarmed one before the unarmed reading means anything.
//
// ⛔ AND RSS ALONE DECIDES NOTHING. It is a HIGH-WATER mark: a runtime that
// allocated, freed, and did not return the pages to the OS reads exactly like
// one that leaked. The discriminator is a SECOND flood in the SAME process
// after the first has drained to quiescence — if the second round's growth is
// a fraction of the first's, the first round's memory was reclaimed and
// reused.
//
// ⚠️ MARGINS ARE DELIBERATELY WIDE. These are resource cells on a shared
// machine, and the suite may be running four files at once. Every bound below
// sits far from its measured value, and the calibration arms sit far on the
// other side; the cells discriminate by ORDER OF MAGNITUDE, never by a few
// percent.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

typedef FloodRun = ({
  int exitCode,
  Map<String, int> values,
  List<String> markers,
  String raw,
  String stderr,
});

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

/// Whether clang is available to build the injector.
final bool haveClang = Process.runSync('clang', ['--version']).exitCode == 0;

Future<FloodRun> runFlood(
  String mode,
  int rounds, {
  String hookPath = '',
  int delayUs = 0,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'test/helpers/log_sink_flood_harness.dart',
      mode,
      '$rounds',
      hookPath,
      '$delayUs',
    ],
    environment: {'ZENOH_DART_VARIANT': 'unstable'},
  );
  final out = StringBuffer();
  final err = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(out.write);
  process.stderr.transform(utf8.decoder).listen(err.write);

  var timedOut = false;
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));

  final raw = out.toString();
  final values = <String, int>{};
  final markers = <String>[];
  for (final line in const LineSplitter().convert(raw)) {
    final eq = line.indexOf('=');
    // ⚠️ DIGITS ARE IN THE CLASS. Without them `RSS_AFTER_ROUND1_MIB` never
    // reaches the map, and the cell that reads it dies on a null check rather
    // than reporting a measurement — which is how it first failed.
    if (eq > 0 && line.startsWith(RegExp('[A-Z0-9_]+='))) {
      values[line.substring(0, eq)] =
          int.tryParse(line.substring(eq + 1)) ?? -1;
    } else if (line.startsWith('FLOOD_') || line.startsWith('DRIVEN ')) {
      markers.add(line);
    }
  }
  expect(
    timedOut,
    isFalse,
    reason: 'the flood child never exited. Markers: $markers\n$err',
  );
  expect(
    markers,
    contains('FLOOD_DONE'),
    reason:
        'the child did not reach the end, so its numbers are partial and '
        'a small one would read as a good result:\n$raw$err',
  );
  return (
    exitCode: code,
    values: values,
    markers: markers,
    raw: raw,
    stderr: err.toString(),
  );
}

/// Builds `post_delay_hook.c` into [dir], or returns null when clang is absent
/// or the build fails.
Future<String?> buildDelayHook(Directory dir) async {
  if (!haveClang) return null;
  final path = '${dir.path}/post_delay_hook.so';
  final build = await Process.run('clang', [
    '-shared',
    '-fPIC',
    '-O0',
    '-g',
    '-o',
    path,
    'test/helpers/post_delay_hook.c',
    '-ldl',
  ]);
  return build.exitCode == 0 ? path : null;
}

void main() {
  group('[D1] S9 — the flood arm', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('zd_d1_s9_');
    });
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a slow sink does not slow the producing side', () async {
      const rounds = 4000;
      final control = await runFlood('control', rounds);
      final flood = await runFlood('flood', rounds);

      expect(
        flood.values['RECORDS'],
        rounds,
        reason:
            'the sink run delivered ${flood.values['RECORDS']} of $rounds '
            'records, so a fast wall time below would mean it did less work '
            'rather than the same work without blocking',
      );
      expect(control.values['RECORDS'], 0);

      final controlMs = control.values['DRIVE_MS']!;
      final floodMs = flood.values['DRIVE_MS']!;
      // A ratio alone blows up on small numbers, so the bound has a floor.
      final bound = math.max(controlMs * 4, controlMs + 300);
      expect(
        floodMs,
        lessThan(bound),
        reason:
            'the driving loop took ${floodMs}ms with a sink against '
            '${controlMs}ms without one. The post is supposed to enqueue and '
            "return; if it blocks, it holds one of zenoh's own runtime "
            'threads for as long as the host takes',
      );
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('the instrument can see back-pressure when it exists', () async {
      // ⛔ THE CALIBRATION THE CELL ABOVE DEPENDS ON. Without it, "the two
      // wall times matched" is indistinguishable from "this instrument cannot
      // see blocking".
      final hookPath = await buildDelayHook(tmp);
      if (hookPath == null) {
        markTestSkipped('clang unavailable — cannot build the injector');
        return;
      }
      const rounds = 4000;
      final disarmed = await runFlood('flood', rounds, hookPath: hookPath);
      final armed = await runFlood(
        'flood',
        rounds,
        hookPath: hookPath,
        delayUs: 200,
      );

      expect(disarmed.values['HOOK_RC'], 0, reason: 'the hook did not install');
      expect(armed.values['HOOK_RC'], 0);
      expect(
        disarmed.values['HOOK_POSTS'],
        greaterThanOrEqualTo(rounds),
        reason: 'the hook saw no posts, so it is not on the path at all',
      );
      expect(
        disarmed.values['HOOK_DELAYED'],
        0,
        reason: 'the disarmed run delayed posts, so it is not a control',
      );
      expect(
        armed.values['HOOK_DELAYED'],
        greaterThanOrEqualTo(rounds),
        reason:
            "the hook's own marker: a wide separation with this at 0 "
            'would mean something else slowed the run',
      );

      final disarmedMs = disarmed.values['DRIVE_MS']!;
      final armedMs = armed.values['DRIVE_MS']!;
      expect(
        armedMs,
        greaterThan(disarmedMs * 5),
        reason:
            'injecting a 200us block into every post moved the driving '
            'loop from ${disarmedMs}ms to only ${armedMs}ms. The instrument '
            'cannot see back-pressure, so the previous cell proves nothing',
      );
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('a starved event loop under flood does not grow without bound', () async {
      // ⛔ THE MODE WHERE MEMORY ACTUALLY GROWS. Both cells in an earlier
      // revision drove a loop that was free to drain between turns, so the
      // port queue never accumulated and both measured the same non-event.
      // Here the isolate does heavy SYNCHRONOUS work with no await at all.
      const rounds = 200000;
      final run = await runFlood('starved-twice', rounds);

      expect(run.values['RECORDS'], rounds * 2);
      final start = run.values['RSS_START_MIB']!;
      final afterOne = run.values['RSS_AFTER_ROUND1_MIB']!;
      final afterTwo = run.values['RSS_AFTER_ROUND2_MIB']!;
      final firstGrowth = afterOne - start;
      final secondGrowth = afterTwo - afterOne;

      // The first round MUST grow, or the discriminator below is comparing
      // two non-events.
      expect(
        firstGrowth,
        greaterThan(20),
        reason:
            'a $rounds-record backlog grew resident memory by only '
            '${firstGrowth}MiB — the queue is not accumulating, so the second '
            'round proves nothing',
      );
      // ⭐ AND THE SECOND ROUND MUST NOT. That is the leak-vs-backlog line: a
      // second identical flood reusing the first round's memory means it was
      // reclaimed, so growth is bounded by the deepest BACKLOG a host allows
      // rather than by the total volume ever logged.
      expect(
        secondGrowth,
        lessThan(math.max(firstGrowth ~/ 4, 8)),
        reason:
            'round 1 grew ${firstGrowth}MiB and round 2 grew '
            '${secondGrowth}MiB in the same process. Round 1 was not '
            'reclaimed, which is a leak rather than a backlog, and a '
            'shim-side bound would be forced',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('the policy sentence names the right stage', () {
      final zenoh = flattenedProse('lib/src/zenoh.dart');
      // ⚠️ The buffer is NOT the broadcast controller, and saying so would
      // send a reader looking for a knob that does not exist. It is the VM's
      // port queue, it is unbounded, and it sits UPSTREAM of the discard --
      // which is why a no-listener flood costs the same as a listened one.
      expect(zenoh, contains('port queue'));
      expect(zenoh, contains('unbounded'));
      expect(zenoh, contains('upstream'));
      expect(
        zenoh,
        contains('protects listeners'),
        reason:
            'broadcast delivery protects listeners from each other, not '
            'memory — a reader who thinks otherwise will believe having no '
            'listener is free',
      );
      // ⛔ THE FIGURES THEMSELVES, not just the word "measured". A policy
      // sentence with no number behind it is the shape this unit exists to
      // remove: a confident claim a reader cannot check.
      for (final needle in const [
        '200,000',
        'reclaimed',
        'no shim-side bound',
      ]) {
        expect(
          zenoh,
          contains(needle),
          reason:
              'the measurement behind the policy is missing "$needle" — '
              'the growth figure, the reclamation result and the decision it '
              'licenses all belong where a consumer reads them',
        );
      }
    });

    // --- Edge cases ---

    test('a flood with no listener costs nothing that grows', () async {
      // ⚠️ A DRAINING loop, deliberately — the contrast with the starved cell
      // is the point. This measures the STEADY-STATE cost of a flood nobody
      // listens to; that one measures the cost of a BACKLOG. Reporting either
      // as the other would be wrong in both directions.
      const rounds = 200000;
      final run = await runFlood('nolisten-draining', rounds);
      expect(
        run.values['RECORDS'],
        0,
        reason: 'records reached a listener in the no-listener arm',
      );
      final start = run.values['RSS_START_MIB']!;
      final end = run.values['RSS_END_MIB']!;
      expect(
        end - start,
        lessThan(60),
        reason:
            'a flood nobody listens to grew resident memory by '
            '${end - start}MiB and kept it, so the broadcast discard is not '
            'releasing what it drops',
      );
      expect(run.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('a process under sustained logging exits cleanly', () async {
      // ⛔ THE ADJACENT EDGE the raw-port decision names, and the seed's own
      // words aim here: "a logging sink that deadlocks or reenters is worse
      // than none." This child returns from main WITH RECORDS STILL IN
      // FLIGHT, so the shim's closure is posting against a VM already in
      // teardown.
      final run = await runFlood(
        'exit-hot',
        50000,
        timeout: const Duration(minutes: 3),
      );
      expect(run.markers, contains('DRIVEN exit-hot'));
      expect(
        run.exitCode,
        0,
        reason:
            'the child did not exit cleanly while still emitting — either '
            'it hung (the isolate-pinning defect) or it crashed posting into '
            'a VM in teardown',
      );
      expect(
        run.stderr,
        isNot(contains('Dart_')),
        reason:
            'a VM-level complaint on the way out is a crash with a zero '
            'exit code hiding it',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
