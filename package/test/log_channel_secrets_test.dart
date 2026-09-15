// Seed [D1] slice 8 — the log channel carries config secrets, and the sink is
// the control.
//
// ⛔ THE ASYMMETRY THIS FILE EXISTS TO PIN, and it is the reason the logging
// bind is a SECURITY CONTROL rather than a diagnosability nicety:
//
//   channel            unstable        stable (what consumers get)
//   ---------------------------------------------------------------
//   exception          echoes          EMPTY — capture compiled out
//   log                echoes          ECHOES
//
// On the variant consumers actually ship, **the log is the only leak** — and
// until this unit it went to stdout unconditionally, with the host holding no
// control over it whatsoever. A redaction position that covered the exception
// channel and not this one would have MOVED the leak rather than closed it.
//
// ⛔ Every cell spawns its own process: canon's logging slot is process-global
// and first-wins, and the suite is one OS process.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/log_severity.dart';

typedef SinkRun = ({
  int exitCode,
  List<String> markers,
  List<({int severity, String message})> records,
  List<String> kept,
  String stderr,
});

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too. Three false reds paid
/// for this shape, all the same defect -- the cell watching TYPOGRAPHY instead
/// of the CLAIM: a line break inside the claim, a comment marker inside it,
/// and a sentence-initial capital that a mid-sentence needle cannot match. A
/// reflow, a re-wrap or a sentence move is now free to happen, and only the
/// disappearance of the claim itself turns a cell red.
String flattenedProse(String path) => File(path)
    .readAsStringSync()
    .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
    // Emphasis markers go too: `**both** build variants` must match a needle
    // that reads `both build variants`. Backticks are KEPT -- a code span is
    // part of the claim, not decoration.
    .replaceAll('*', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase();

Future<SinkRun> runChild(
  String mode, {
  required LogSeverity severity,
  required String marker,
  String variant = 'unstable',
  Duration timeout = const Duration(seconds: 60),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/log_sink_harness.dart', mode, severity.name, marker],
    environment: {'ZENOH_DART_VARIANT': variant},
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
  final kept = <String>[];
  for (final line in const LineSplitter().convert(out.toString())) {
    if (line.startsWith('REC ')) {
      final sp = line.indexOf(' ', 4);
      records.add((
        severity: int.parse(line.substring(4, sp)),
        message: jsonDecode(line.substring(sp + 1)) as String,
      ));
    } else if (line.startsWith('KEPT ')) {
      kept.add(line);
    } else if (line.startsWith('SINK_') || line.startsWith('DRIVEN ')) {
      markers.add(line);
    }
  }
  expect(
    timedOut,
    isFalse,
    reason: 'the child never exited. Markers: $markers\nstderr: $err',
  );
  return (
    exitCode: code,
    markers: markers,
    records: records,
    kept: kept,
    stderr: err.toString(),
  );
}

void main() {
  group('[D1] S8 — the log channel and its control', () {
    test('a rejected secret-bearing config value reaches the host sink '
        'verbatim', () async {
      const marker = 'ZDS8-SECRET-c0ffee';
      final run = await runChild(
        'deliver',
        severity: LogSeverity.error,
        marker: marker,
      );
      expect(run.markers, contains('DRIVEN post-install'));
      final joined = run.records.map((r) => r.message).join('\n');
      expect(
        joined,
        contains(marker),
        reason:
            'this channel is supposed to carry it — the cell proves the '
            "hazard the exception channel's dartdoc warns about is real HERE "
            'too, on a channel that previously went to stdout with no host '
            'control at all',
      );
      expect(
        joined,
        contains('^---'),
        reason:
            "canon's caret comes with it, so the record carries the "
            'SURROUNDING source line and not only the offending value',
      );
    });

    test(
      'the host can suppress it, which is what makes the sink a control',
      () async {
        const marker = 'ZDS8-FILTERED-c0ffee';
        final run = await runChild(
          'filtered',
          severity: LogSeverity.error,
          marker: marker,
        );
        expect(run.markers, contains('DRIVEN filtered'));
        // ⛔ THE ASSERTION IS ON WHAT LEFT THE FILTER, never on the raw stream.
        // Asserting the raw stream would measure the leak a second time and
        // call it suppression.
        expect(
          run.kept,
          isEmpty,
          reason:
              'a secret-bearing record survived the host filter: '
              '${run.kept}',
        );
        // And the calibration: the unfiltered run above DID carry it, so the
        // emptiness here is suppression rather than nothing having happened.
        expect(run.exitCode, 0);
      },
    );

    test('the leak is present on the stable variant too', () async {
      // ⛔ THE CELL THAT DECIDES THE REDACTION POSITION. On `stable` — the
      // default, and what consumers get — the exception channel carries no
      // upstream detail at all. This one does. So a position covering only
      // the exception channel would have moved the leak, not closed it.
      const marker = 'ZDS8-STABLE-c0ffee';
      final run = await runChild(
        'deliver',
        severity: LogSeverity.error,
        marker: marker,
        variant: 'stable',
      );
      expect(run.markers, contains('DRIVEN post-install'));
      expect(
        run.records.map((r) => r.message).join('\n'),
        contains(marker),
        reason:
            'the log channel did not carry the marker on stable, which '
            'would make this whole slice a statement about a variant nobody '
            'ships',
      );
    });

    test('the initLog measurement is carried with its condition', () {
      final zenoh = flattenedProse('lib/src/zenoh.dart');
      // ⚠️ The measurement that routed diagnosis here in the first place was
      // "initLog('error') prints the precise cause with ZERO leakage". True —
      // of open-failure CAUSES. It is false of the CHANNEL: config-rejection
      // records echo the offending value verbatim on both variants. Carrying
      // the number without that condition is how a reader concludes the log
      // channel is the zero-leak route.
      expect(zenoh, contains('zero leakage'));
      expect(
        zenoh,
        contains('config-rejection records'),
        reason:
            'the condition must travel with the measurement, or the '
            'measurement reads as a property of the channel',
      );
      expect(
        zenoh,
        contains('both build variants'),
        reason:
            'the echo is not variant-gated the way the exception channel '
            'is, and that is exactly what makes this the surviving leak',
      );
    });

    // --- Edge cases ---

    test('no ceiling short of suppressing errors removes it — one subprocess '
        'per severity', () async {
      // ⛔ ONE SUBPROCESS PER SEVERITY. An earlier revision installed "sinks
      // at each severity" in one process, which is several claims against one
      // process-global slot — impossible even in isolation.
      const marker = 'ZDS8-CEILING-c0ffee';
      final sawMarker = <LogSeverity, bool>{};
      for (final severity in LogSeverity.values) {
        final run = await runChild(
          'deliver',
          severity: severity,
          marker: marker,
        );
        expect(
          run.markers,
          contains('DRIVEN post-install'),
          reason: 'the ${severity.name} child never reached its driver',
        );
        sawMarker[severity] = run.records.any(
          (r) => r.message.contains(marker),
        );
      }
      expect(
        sawMarker.values.every((seen) => seen),
        isTrue,
        reason:
            'the record is emitted at `error`, so every ceiling up to and '
            'including error delivers it: $sawMarker. The level is NOT the '
            'control — host-side filtering is',
      );

      final zenoh = flattenedProse('lib/src/zenoh.dart');
      expect(
        zenoh,
        contains('host side is the control'),
        reason: 'the dartdoc must name the control, and it is not the ceiling',
      );
    });
  });
}
