// Seed [D1] slice 7 — the logging slot is claimed once, and the asymmetry is
// decided.
//
// ⛔ THE DEFECT THIS SLICE CLOSES WAS CREATED BY THIS UNIT'S OWN FEATURE.
// Canon's three logging inits are first-wins, process-global and SILENTLY
// idempotent. Before the sink existed there was nothing to be too late for.
// Now there is: a consumer who calls `Zenoh.initLog` and then installs a sink
// would, without this slice, get no sink and no error — and would go looking
// for a delivery bug that is really an ordering one.
//
// ⭐ THE ASYMMETRY, AND ITS GROUND. Only two of the four orderings throw:
//
//   initLog        -> initLogWithSink   THROWS
//   initLogWithSink-> initLogWithSink   THROWS
//   initLogWithSink-> initLog           silent
//   initLog        -> initLog           silent (unchanged from shipped)
//
// The ground is STRUCTURAL, not compatibility: the throw belongs where a
// RETURNED VALUE would otherwise be false. `initLogWithSink` hands back a
// `Stream`, and a stream that can never emit is a lie handed back as a live
// channel. `initLog` returns `void`, and `void` cannot be false — what a late
// `initLog` loses is a filter level, not a channel. The three shipped
// `initLog` cells therefore pass unchanged, and the shipped dartdoc sentence
// stays true and gains a warning rather than a reversal.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

typedef OrderRun = ({
  int exitCode,
  List<String> markers,
  List<({int severity, String message})> records,
  int canonRecords,
  String raw,
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

Future<OrderRun> runOrder(
  String mode, {
  String marker = 'ZDS7',
  Duration timeout = const Duration(seconds: 90),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/log_init_order_harness.dart', mode, marker],
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
  final markers = <String>[];
  final records = <({int severity, String message})>[];
  // Canon's own records go to STDOUT, not stderr — measured, and a
  // stderr-only capture returned nothing at all, which read as a clean
  // negative. `-a`-style byte handling is not needed here because the runtime
  // writes ANSI escapes, not NULs; the target name is the discriminator.
  var canonRecords = 0;
  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('REC ')) {
      final sp = line.indexOf(' ', 4);
      records.add((
        severity: int.parse(line.substring(4, sp)),
        message: jsonDecode(line.substring(sp + 1)) as String,
      ));
    } else if (line.startsWith('ORDER_') ||
        line.startsWith('FIRST_') ||
        line.startsWith('SECOND_') ||
        line.startsWith('DRIVEN ')) {
      markers.add(line.split(' ').take(2).join(' '));
    } else if (line.contains('zenohc::config') ||
        line.contains('zenohc::session')) {
      canonRecords++;
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
    canonRecords: canonRecords,
    raw: raw,
    stderr: err.toString(),
  );
}

void main() {
  group('[D1] S7 — the logging slot is claimed once', () {
    test('initLog then a sink install throws', () async {
      final run = await runOrder('initlog-then-sink');
      expect(run.markers, contains('FIRST_OK initlog'));
      expect(
        run.markers.where((m) => m.startsWith('SECOND_THREW')),
        isNotEmpty,
        reason:
            'the sink install did not refuse. Silently returning a stream '
            'that can never deliver is the defect this cell exists for. '
            'Markers: ${run.markers}',
      );
      expect(
        run.raw,
        contains('already claimed'),
        reason:
            'the refusal must name what claimed the slot, or the consumer '
            'is told only that something went wrong',
      );
      expect(run.markers, contains('ORDER_DONE'));
      expect(run.exitCode, 0);
    });

    test(
      'a second sink install throws, and the first keeps delivering',
      () async {
        final run = await runOrder('sink-then-sink', marker: 'ZDS7SS');
        expect(run.markers, contains('FIRST_OK sink'));
        expect(
          run.markers.where((m) => m.startsWith('SECOND_THREW')),
          isNotEmpty,
          reason: 'the second install did not refuse',
        );
        expect(run.markers, contains('DRIVEN first-still-live'));
        expect(
          run.records.map((r) => r.message).join('\n'),
          contains('ZDS7SS'),
          reason:
              'the FIRST stream stopped delivering after the second install '
              'was refused — a refusal must not disturb the sink that owns the '
              'slot',
        );
        expect(run.exitCode, 0);
      },
    );

    test(
      'a sink install then initLog is silent, and initLog twice is silent',
      () async {
        // ⛔ THE FOURTH ORDERING, undecided at an earlier revision of the plan.
        final sinkFirst = await runOrder('sink-then-initlog', marker: 'ZDS7SI');
        expect(sinkFirst.markers, contains('FIRST_OK sink'));
        expect(
          sinkFirst.markers,
          contains('SECOND_OK initlog'),
          reason:
              'a late initLog must NOT throw: void cannot be false, and '
              'what is lost is a filter level rather than a channel',
        );
        expect(
          sinkFirst.records.map((r) => r.message).join('\n'),
          contains('ZDS7SI'),
          reason: 'the sink stopped delivering after a late initLog',
        );
        expect(sinkFirst.exitCode, 0);

        final twice = await runOrder('initlog-then-initlog');
        expect(twice.markers, contains('FIRST_OK initlog'));
        expect(
          twice.markers,
          contains('SECOND_OK initlog'),
          reason: 'initLog stays silent-idempotent, unchanged from shipped',
        );
        expect(twice.exitCode, 0);
      },
    );

    test('the three shipped initLog cells are unaffected', () {
      // Their behaviour is covered by the suite itself; what this cell pins
      // is that they are STILL THERE, unedited, and that nothing in the suite
      // process installs a sink to claim the slot out from under them.
      final zenohTest = File('test/zenoh_test.dart').readAsStringSync();
      expect(zenohTest, contains("Zenoh.initLog('error')"));
      expect(
        zenohTest,
        contains('returnsNormally'),
        reason:
            'the shipped cells assert only that the call returns, which '
            'is what makes them safe in a shared process',
      );
      final sessionTest = File('test/session_test.dart').readAsStringSync();
      expect(sessionTest, contains('Zenoh.initLog('));

      // The tripwire that keeps them safe lives in log_sink_test.dart; this
      // asserts it still exists, so the two cannot drift apart.
      final sinkTest = File('test/log_sink_test.dart').readAsStringSync();
      expect(sinkTest, contains('sanctionedInstallers'));
    });

    test('first-wins is asserted on our own surface, both orders', () async {
      // ⛔ BOTH DIRECTIONS OR NEITHER. "off first yields nothing" is also what
      // a process with nothing emitting would report. The `error` first arm
      // is the calibration, and total separation is the result.
      final offFirst = await runOrder('off-then-error');
      final errorFirst = await runOrder('error-then-off');
      expect(offFirst.markers, contains('DRIVEN first-wins'));
      expect(errorFirst.markers, contains('DRIVEN first-wins'));

      expect(
        errorFirst.canonRecords,
        greaterThan(0),
        reason:
            'the error-first process emitted nothing, so the zero below '
            'is a blind instrument rather than a measurement',
      );
      expect(
        offFirst.canonRecords,
        0,
        reason:
            'the first init did not win: `off` was claimed first and '
            'records still appeared',
      );
    });

    // --- Edge cases ---

    test('the guard states its limits, and nothing unmeasured is asserted', () {
      final zenoh = flattenedProse('lib/src/zenoh.dart');
      expect(
        zenoh,
        contains('only inits made through this binding'),
        reason:
            'the flag cannot see an init made by other code in the same '
            'process, and promising otherwise would be false',
      );
      expect(
        zenoh,
        contains('claims it permanently'),
        reason: 'a host wanting a sink must be told to install it FIRST',
      );
      expect(
        zenoh,
        contains('returns `void`'),
        reason:
            'canon reports nothing itself, which is WHY the binding has '
            'to keep its own record',
      );
      // ⛔ And the arm nobody has measured is not asserted anywhere.
      expect(
        zenoh,
        isNot(contains('zc_try_init_log_from_env')),
        reason:
            'the try form unset-env behaviour is measured by nobody, so '
            'this surface must make no claim about it',
      );
    });

    test('the shipped dartdoc sentence stays true and gains its warning', () {
      final zenoh = flattenedProse('lib/src/zenoh.dart');
      expect(
        zenoh,
        contains('subsequent calls are ignored by the underlying runtime'),
        reason:
            'the shipped sentence is CORRECT and must survive verbatim — '
            'the contract is extended, not reversed',
      );
      final at = zenoh.indexOf('subsequent calls are ignored');
      final after = zenoh.substring(at, at + 900);
      expect(
        after,
        contains('forecloses'),
        reason:
            'the warning must FOLLOW the shipped sentence, so a reader '
            'meets the extension where they met the original claim',
      );
      expect(after, contains('stateerror'));
    });
  });
}
