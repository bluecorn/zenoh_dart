// Seed [D1] slice 6 — records arriving from a non-Dart thread reach the host.
//
// ⛔ WHY THIS IS NOT A RESTATEMENT OF SLICE 5. Every driver slice 5 used emits
// on the CALLING thread: canon rejects a config value and logs it inside the
// same synchronous call. A delivery mechanism that only worked when the
// emitter happened to be the Dart thread would pass every one of those cells.
// Canon's own header says the callback fires "synchronously on the thread that
// emitted the record" and is "not guaranteed not to be called concurrently" —
// so the arms that matter are the ones where the emitter is somebody else.
//
// ⛔ AND THE INSTRUMENT IS THE PROTOCOL. Every assertion here is made across a
// process boundary, where a child that died before its driver and a child that
// ran and received nothing produce the same output: none. The first is a
// broken instrument; the second is a result. Every cell asserts the child's
// phase markers BEFORE it asserts anything about records.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// One child run.
typedef ThreadRun = ({
  int exitCode,
  List<String> markers,
  List<({int severity, String message})> records,
  String stderr,
});

/// Ports this file's tokio-thread driver listens on, from the unit's reserved
/// 19743-19762 block. One per cell, because a TLS listener that fails on its
/// key material may still have touched the port.
const _tokioPort = 19751;
const _bothPort = 19752;
const _nolistenPort = 19753;

Future<ThreadRun> runChild(
  String mode, {
  String marker = 'ZDS6',
  int port = _tokioPort,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'test/helpers/log_sink_thread_harness.dart',
      mode,
      marker,
      '$port',
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

  final markers = <String>[];
  final records = <({int severity, String message})>[];
  for (final line in const LineSplitter().convert(out.toString())) {
    if (line.startsWith('REC ')) {
      final sp = line.indexOf(' ', 4);
      records.add((
        severity: int.parse(line.substring(4, sp)),
        message: jsonDecode(line.substring(sp + 1)) as String,
      ));
    } else if (line.startsWith('THREAD_') || line.startsWith('DRIVEN ')) {
      markers.add(line);
    }
  }
  expect(
    timedOut,
    isFalse,
    reason:
        'the child never exited and had to be killed. Markers reached: '
        '$markers\nstderr: $err',
  );
  return (
    exitCode: code,
    markers: markers,
    records: records,
    stderr: err.toString(),
  );
}

/// Asserts the child got where it was going, so an empty record set is a
/// RESULT rather than a broken instrument.
void expectHealthy(ThreadRun run, List<String> phases) {
  expect(
    run.markers,
    contains('THREAD_START'),
    reason: 'the child never started: ${run.stderr}',
  );
  expect(run.markers, contains('THREAD_INSTALLED'));
  for (final phase in phases) {
    expect(
      run.markers,
      contains('DRIVEN $phase'),
      reason:
          'the child never finished its "$phase" driver, so nothing below '
          'it can be read as a negative. Markers: ${run.markers}',
    );
  }
  expect(run.markers, contains('THREAD_DONE'));
  expect(
    run.exitCode,
    0,
    reason:
        'every child asserts its own clean exit, so an isolate-pinning '
        'regression surfaces here as well as in slice 5',
  );
}

void main() {
  group('[D1] S6 — records from a non-Dart thread', () {
    test('a record emitted on a tokio thread is delivered', () async {
      final run = await runChild('tokio');
      expectHealthy(run, ['tokio']);
      expect(
        run.records.map((r) => r.message).join('\n'),
        contains('127.0.0.1:$_tokioPort'),
        reason:
            'no record carried the failing listener this call created. '
            "The port is the attribution token because canon's open-failure "
            'records render a diagnosis and echo nothing of the config — '
            'measured over nine drivers in slice 3 — so there is no field to '
            'plant a marker in',
      );
    });

    test('both thread origins arrive in one child', () async {
      // ⛔ ONE CHILD, BOTH ORIGINS. Two separate children would let a
      // calling-thread-only regression pass the first and fail only the
      // second, which reads as a flake rather than as the defect it is.
      final run = await runChild('both', marker: 'ZDS6BOTH', port: _bothPort);
      expectHealthy(run, ['calling', 'tokio']);
      final joined = run.records.map((r) => r.message).join('\n');
      expect(
        joined,
        contains('ZDS6BOTHCALLING'),
        reason: 'the calling-thread record is missing',
      );
      expect(
        joined,
        contains('127.0.0.1:$_bothPort'),
        reason:
            'the tokio-thread record is missing, so this run proves only '
            'what slice 5 already proved',
      );
    });

    test('concurrent emission does not lose or corrupt records', () async {
      // Canon's header: "not guaranteed not to be called concurrently". Eight
      // isolates drive at once into the single process-global sink.
      final run = await runChild('concurrent', marker: 'ZDS6C');
      expectHealthy(run, ['concurrent 8']);

      for (var i = 0; i < 8; i++) {
        final marker = 'ZDS6C-$i';
        // ⛔ EXACTLY ONE, not "at least one". A count is what distinguishes
        // "every record arrived" from "one arrived and seven were lost", and
        // duplication under concurrency is as much a defect as loss.
        //
        // ⚠️ RECORDS carrying the marker, NOT occurrences of it. Counting
        // occurrences over the joined text reads 2 for every driver, because
        // canon echoes the offending value TWICE inside one message — once in
        // its summary and once in the caret rendering underneath. That is the
        // instrument miscounting, not the sink duplicating, and the first cut
        // of this cell reported it as a defect.
        final carrying = run.records
            .where(
              (r) => r.message.contains(marker),
            )
            .length;
        expect(
          carrying,
          1,
          reason:
              'driver $i produced $carrying records carrying its own '
              'marker; every driver must produce exactly one',
        );
      }
      // And no record carries another driver's text: each canon message
      // quotes exactly the value its own call passed.
      for (final record in run.records) {
        final carried = [
          for (var i = 0; i < 8; i++)
            if (record.message.contains('ZDS6C-$i')) i,
        ];
        expect(
          carried.length,
          lessThanOrEqualTo(1),
          reason:
              'one record carried the markers of drivers $carried — the '
              "records were interleaved into each other's text",
        );
      }
    });

    test('the harness can tell silence from death', () {
      // ⛔ THE CELL THAT MAKES THE OTHERS READABLE. Assert the protocol
      // itself: the child prints a start marker, a per-phase marker and a
      // terminal marker, and this file's helper checks all three before any
      // record assertion. Without that ordering, a child that crashed at
      // startup delivers a clean-looking negative.
      final harness = File('test/helpers/log_sink_thread_harness.dart')
          .readAsStringSync();
      for (final marker in const [
        'THREAD_START',
        'THREAD_INSTALLED',
        'THREAD_DONE',
        'DRIVEN ',
      ]) {
        expect(
          harness,
          contains("'$marker"),
          reason:
              'the harness no longer prints $marker, so a dead child and '
              'a silent one become indistinguishable',
        );
      }

      final self = File('test/log_sink_threading_test.dart').readAsStringSync();
      expect(
        self,
        contains('void expectHealthy('),
        reason:
            'the phase check must be a single named helper, so no cell '
            'can quietly skip it',
      );
    });

    // --- Edge cases ---

    test(
      'a record arriving while nothing is listening does not crash',
      () async {
        final run = await runChild(
          'nolisten',
          marker: 'ZDS6NL',
          port: _nolistenPort,
        );
        expectHealthy(run, ['unheard', 'heard']);
        final joined = run.records.map((r) => r.message).join('\n');
        expect(
          joined,
          contains('ZDS6NLHEARD'),
          reason:
              'the post-listener record never arrived, so the absence below '
              'proves nothing',
        );
        expect(
          joined,
          isNot(contains('ZDS6NLUNHEARD')),
          reason:
              'a record delivered before any listener attached was replayed '
              '— broadcast delivery discards them, and the dartdoc says so',
        );
      },
    );
  });
}
