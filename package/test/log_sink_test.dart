// Seed [D1] slice 5 — canon's log records reach the host application, and the
// process can still exit.
//
// ⛔ EVERY CELL IN THIS FILE SPAWNS ITS OWN PROCESS, and that is a hard rule
// rather than a style. Canon's logging init is first-wins, process-global and
// SILENT; the suite is one OS process. A second in-process install would
// receive nothing and report that as a result. The rule's tripwire is the
// last cell here, which scans the whole test corpus for an in-process install.
//
// ⛔ THE SECOND HALF OF THE TITLE IS NOT DECORATION. A receive port keeps its
// isolate alive by default, and this sink has no session, no handle and no
// removal — canon offers none. A `ReceivePort` here would hang every consumer
// process that installed a sink, which is a worse defect than the one the
// feature fixes. The measured precedent is on record: "declareBackground* has
// no handle; its port pins the isolate alive forever | Public API | Hang
// reproduced."
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/log_severity.dart';

/// A source file with its comment markers and line wrapping flattened away.
///
/// See `open_detail_secrets_test.dart` for why: a `contains` against raw
/// source reports a missing claim when what actually moved was a line break.
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

/// One child run: its markers, its records, and how it ended.
typedef ChildRun = ({
  int exitCode,
  List<String> markers,
  List<({int severity, String message})> records,
  String raw,
});

/// Runs the sink harness in [mode], bounded, and parses its protocol.
///
/// ⛔ Bounded by the PARENT, not by a timer inside the child. The failure this
/// guards is a child that never exits; a child cannot time out its own hang.
Future<ChildRun> runChild(
  String mode, {
  LogSeverity severity = LogSeverity.error,
  String marker = 'ZDLOGMARK',
  String variant = 'unstable',
  Duration timeout = const Duration(seconds: 60),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'test/helpers/log_sink_harness.dart',
      mode,
      severity.name,
      marker,
    ],
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
  // Let the pipes drain after exit.
  await Future<void>.delayed(const Duration(milliseconds: 100));

  final raw = out.toString();
  final markers = <String>[];
  final records = <({int severity, String message})>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('REC ')) {
      final sp = line.indexOf(' ', 4);
      records.add((
        severity: int.parse(line.substring(4, sp)),
        message: jsonDecode(line.substring(sp + 1)) as String,
      ));
    } else if (line.startsWith('SINK_') || line.startsWith('DRIVEN ')) {
      markers.add(line);
    }
  }
  expect(
    timedOut,
    isFalse,
    reason:
        'the child had to be killed — it never exited. Markers reached: '
        '$markers\nstderr: $err',
  );
  return (exitCode: code, markers: markers, records: records, raw: raw);
}

/// Fails with a diagnosis when a child produced no records, distinguishing
/// "produced none" from "never got there".
void expectReachedDriver(ChildRun run, String phase) {
  expect(
    run.markers,
    contains('DRIVEN $phase'),
    reason:
        'the child never reached the end of its "$phase" driver, so an '
        'empty record set says nothing about delivery — a blind child reads '
        'as a clean negative. Markers: ${run.markers}',
  );
}

void main() {
  group('[D1] S5 — the log sink', () {
    test('a record canon emits arrives at the host', () async {
      final run = await runChild('deliver', marker: 'ZDS5DELIVER');
      expect(run.markers, contains('SINK_INSTALLED error'));
      expectReachedDriver(run, 'post-install');
      expect(
        run.records,
        isNotEmpty,
        reason: 'the driver ran and no record arrived at all',
      );
      final errors = run.records.where(
        (r) => r.severity == LogSeverity.error.wireValue,
      );
      expect(errors, isNotEmpty, reason: 'no record carried error severity');
      expect(
        errors.map((r) => r.message).join('\n'),
        contains('ZDS5DELIVER'),
        reason:
            "the record must carry canon's own text for THIS call, not "
            'merely some record from somewhere',
      );
    });

    test('the ceiling filters, and the same cell proves the filtered records '
        'were deliverable', () async {
      // ⛔ Both halves in one cell, because either alone is worthless. "The
      // error sink received no info records" is satisfied by a sink that
      // receives nothing; the info run is what proves those records existed
      // and were deliverable.
      final atInfo = await runChild('workload', severity: LogSeverity.info);
      final atError = await runChild('workload');
      expectReachedDriver(atInfo, 'workload');
      expectReachedDriver(atError, 'workload');

      final infoRecords = atInfo.records.where(
        (r) => r.severity == LogSeverity.info.wireValue,
      );
      expect(
        infoRecords,
        isNotEmpty,
        reason:
            'the info-ceiling process received no INFO records, so the '
            'error-ceiling result below would be vacuous',
      );
      expect(
        atError.records.where(
          (r) => r.severity < LogSeverity.error.wireValue,
        ),
        isEmpty,
        reason: 'the error ceiling let a below-error record through',
      );
    });

    test('the message is byte-faithful across the seam', () async {
      final run = await runChild('multibyte', marker: 'ZDS5MB');
      expectReachedDriver(run, 'multibyte');
      final joined = run.records.map((r) => r.message).join('\n');
      expect(
        joined,
        contains('日本語-Ω-ZDS5MB'),
        reason:
            'multi-byte content did not survive the crossing intact. It '
            'travels length-carried and is copied by the post while the '
            'borrow is still valid: never as a NUL-delimited string and '
            'never through a UTF-8-validating extractor',
      );
    });

    test('a process that installs a sink exits on its own', () async {
      // ⛔ THE HAZARD, NAMED: a receive port keeps its isolate alive by
      // default, and this sink has no handle and no removal. A ReceivePort
      // here reproduces a measured hang.
      final run = await runChild(
        'exit',
        severity: LogSeverity.trace,
        timeout: const Duration(seconds: 30),
      );
      expect(run.markers, contains('SINK_DONE'));
      expect(
        run.exitCode,
        0,
        reason:
            'the child did not exit cleanly on its own; a non-zero code '
            'here, or a kill above, is the isolate-pinning defect',
      );
    });

    test("the severity enum's wire values are explicit and match canon", () {
      // CONV-1: explicit wire values, never ordinal-by-accident.
      expect(LogSeverity.trace.wireValue, 0);
      expect(LogSeverity.debug.wireValue, 1);
      expect(LogSeverity.info.wireValue, 2);
      expect(LogSeverity.warn.wireValue, 3);
      expect(LogSeverity.error.wireValue, 4);
      expect(LogSeverity.values, hasLength(5));

      // And the mapping is asserted against canon's own header rather than a
      // copy of it: an embedded copy checked against the code's copy is
      // self-agreement.
      final header = File(
        '../build/linux-x64/extern/zenoh-c/release/include/zenoh_commons.h',
      ).readAsStringSync();
      for (final severity in LogSeverity.values) {
        final macro = 'ZC_LOG_SEVERITY_${severity.name.toUpperCase()}';
        expect(
          header,
          contains('$macro = ${severity.wireValue},'),
          reason: '$macro does not equal ${severity.wireValue} in canon',
        );
      }
    });

    test('the export-count pin is updated with its delta stated', () {
      // finalizer_ownership_test.dart asserts the count; this cell asserts
      // WHAT the count is made of, so the number stays an instrument rather
      // than becoming a rubber stamp.
      final exports = File('lib/zenoh.dart')
          .readAsLinesSync()
          .where((l) => l.startsWith('export'))
          .toList();
      expect(exports, hasLength(36));
      expect(
        exports.where((l) => l.contains('log_severity.dart')),
        hasLength(1),
      );
      expect(
        exports.where((l) => l.contains('log_record.dart')),
        hasLength(1),
      );
    });

    // --- Edge cases ---

    test(
      'records emitted before install are lost, and that is stated',
      () async {
        final run = await runChild('late', marker: 'ZDS5LATE');
        expectReachedDriver(run, 'pre-install');
        expectReachedDriver(run, 'post-install');
        final joined = run.records.map((r) => r.message).join('\n');
        expect(
          joined,
          contains('ZDS5LATE'),
          reason:
              'the post-install driver produced nothing, so the absence '
              'below proves nothing',
        );
        expect(
          joined,
          isNot(contains('ZDS5LATEPRE')),
          reason:
              'a pre-install record arrived — canon has no retrospective '
              'delivery, so this would mean the sink is buffering somewhere',
        );
        expect(run.exitCode, 0);

        final zenoh = flattenedProse('lib/src/zenoh.dart');
        expect(
          zenoh,
          contains('no buffering'),
          reason:
              'the dartdoc must state that records emitted before the '
              'install are gone, or a consumer will read the silence as a bug',
        );
      },
    );

    test('the contract binds the right parties', () {
      // ⛔ Two audiences, two different contracts, and conflating them is the
      // defect this cell exists for. The prohibitions — do not block, do not
      // reenter, do not allocate unboundedly — bind the SHIM'S OWN C CLOSURE,
      // which really does run synchronously on the emitting tokio thread. The
      // Dart listener never runs there; it runs on its own event loop, a post
      // later. Telling a consumer "your handler must not block" would be
      // false, and would hide what is actually true for them.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      // Bounded by two landmarks rather than a character count: a window
      // measured in characters silently stops covering what it was written
      // to cover the moment the block above it grows.
      final from = shim.indexOf('// The logging slot');
      final to = shim.indexOf('static void _zd_log_drop(');
      expect(from, greaterThanOrEqualTo(0), reason: 'the section is missing');
      expect(to, greaterThan(from), reason: 'the closure is missing');
      final region = shim.substring(from, to).toLowerCase();
      expect(region, contains('emitting thread'));
      expect(region, contains('copy, post, return'));
      expect(region, contains('never block'));
      expect(region, contains('never reenter'));
      expect(region, contains('never allocate unboundedly'));

      final zenoh = flattenedProse('lib/src/zenoh.dart');
      expect(zenoh, contains('no listener'));
      expect(zenoh, contains('unbounded'));
      expect(zenoh, contains('no removal'));
      expect(
        zenoh,
        contains('costs you memory'),
        reason:
            'a slow listener costs the HOST memory; it does not '
            "back-pressure zenoh's own threads, and saying otherwise would "
            'send a consumer optimising the wrong thing',
      );
    });

    test('no in-process sink install exists anywhere in the suite', () {
      // ⛔ THE TRIPWIRE THAT KEEPS THE ARCHITECTURE RULE ALIVE. One cell
      // installing a sink in the suite process claims the slot for every
      // later cell in the run, silently.
      // ⛔ AN EXPLICIT ALLOWLIST, NOT A DIRECTORY EXEMPTION. Exempting all of
      // test/helpers/ would make adding an installing harness silent, which
      // is the opposite of what this cell is for. Adding a harness here is a
      // deliberate act with a name attached, and the cell that made it
      // necessary is the one that caught slice 6's harness on arrival.
      const sanctionedInstallers = <String>[
        'helpers/log_sink_harness.dart', // slice 5
        'helpers/log_sink_thread_harness.dart', // slice 6
        'helpers/log_init_order_harness.dart', // slice 7
        'helpers/log_sink_flood_harness.dart', // slice 9
      ];
      final offenders = <String>[];
      for (final entity in Directory('test').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (sanctionedInstallers.any(entity.path.endsWith)) continue;
        final text = entity.readAsStringSync();
        for (final line in const LineSplitter().convert(text)) {
          final code = line.trimLeft();
          if (code.startsWith('//')) continue;
          // ⚠️ NEEDLE SPLIT ACROSS TWO LITERALS. This cell scans every file
          // in test/, itself included, so spelling the call out would make
          // the tripwire fire on itself. It did, on the first green run --
          // the same shape a walked-tree pin caught in slice 1.
          const needle =
              'initLogWithSink'
              '(';
          if (code.contains(needle)) offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a sink install outside the spawned-subprocess harness claims '
            "canon's one process-global slot for the whole suite run",
      );
    });

    test('the new files trip no walked-tree pin', () {
      // The partition finalizer_ownership_test.dart pins is 10 detaching +
      // 10 excluded + 1 unrelated over `Safe to call multiple times`. Neither
      // new file holds a native handle, so neither may carry that phrase.
      for (final path in const [
        'lib/src/log_severity.dart',
        'lib/src/log_record.dart',
      ]) {
        final text = File(path).readAsStringSync();
        expect(
          text,
          isNot(contains('Safe to call multiple times')),
          reason: '$path would move the 10+10+1 finalizer partition',
        );
        expect(
          text,
          isNot(
            contains(
              'Dart_PostCObject'
              '_DL',
            ),
          ),
          reason: '$path would break the walked-tree absence pin',
        );
        expect(
          text,
          isNot(
            contains(
              'zd_query'
              '_parameters',
            ),
          ),
        );
        expect(
          text,
          isNot(
            contains(
              'sendPort'
              '.send',
            ),
          ),
        );
      }
    });
  });
}
