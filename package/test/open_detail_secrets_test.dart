// Seed [D1] slice 3 — the shipped open path is inside the variant rule and
// carries no secret.
//
// ⛔ THE MEASUREMENT THIS UNIT'S SEED DECLARED IT OWED AND HAD NOT TAKEN. The
// security ruling behind the enrichment fence says enriching `Session.open`
// "would import the value-echo onto a path whose input is the whole
// secret-bearing config". That ruling predates the offloaded open, which
// SHIPPED thread-correct enrichment on exactly that path two days before the
// seed was written. So the diagnosability half of the ruling is discharged
// and the SECRETS half was never measured. This file measures it.
//
// ⚠️ WHAT A NEGATIVE HERE IS AND IS NOT. Nine drivers reaching a canon open
// failure, all clean, with a positive control firing in the same process, is a
// STRONG NEGATIVE WITH A STATED MECHANISM — canon's open-failure errors render
// a DIAGNOSIS rather than an echo of the input. It is not a proof over canon's
// whole open-failure space, and the cells say so rather than rounding it up.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/open_secret_probe.dart' show drivers, secret;

/// A source file with its comment markers and line wrapping flattened away.
///
/// ⚠️ WHY. A prose assertion against raw source is hostage to LINE WRAPPING: a
/// claim that reads as one sentence is stored as `...so no\n/// other
/// operation's text...`, and `contains('no other operation')` fails on text
/// that plainly says it. That is a false red — the cell reports a missing
/// claim when what moved was a line break — and it cost one here on the first
/// green run. Flattening watches the CLAIM, which is what these cells are for,
/// and leaves a reflow free to happen.
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

/// Runs the probe under [variant] and returns its rows by case name.
Future<Map<String, Map<String, Object?>>> runProbe(String variant) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/open_secret_probe.dart'],
    environment: {'ZENOH_DART_VARIANT': variant},
  );
  final out = result.stdout as String;
  expect(
    out,
    contains('PROBE_DONE'),
    reason:
        'the probe did not reach the end — a blind child reads as a clean '
        'negative, which is the one outcome this file must never produce:\n'
        '$out${result.stderr}',
  );
  final rows = <String, Map<String, Object?>>{};
  for (final line in const LineSplitter().convert(out)) {
    if (!line.startsWith('{')) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    rows[row['case'] as String] = row;
  }
  return rows;
}

void main() {
  group('[D1] S3 — the open path carries no secret', () {
    late Map<String, Map<String, Object?>> unstable;

    setUpAll(() async {
      unstable = await runProbe('unstable');
    });

    test('the instrument is proven able to see a leak, in the same run', () {
      // ⛔ READ THIS CELL FIRST. Every negative below is conditional on it.
      // The same marker, the same process, the same variant, through the
      // enriched config channel where the echo is measured and expected.
      final control = unstable['CONTROL']!;
      expect(
        control['fired'],
        isTrue,
        reason:
            'the control driver did not even throw — the instrument never '
            'got a chance to see anything',
      );
      expect(
        control['marker'],
        isTrue,
        reason:
            'the marker did NOT come back through a channel measured to '
            'echo it. The instrument is blind, and every "no leak" in this '
            'file is worthless rather than reassuring',
      );
    });

    test('a recognisable secret in the failing config does not reach the '
        'exception message', () {
      var fired = 0;
      for (final name in drivers.keys) {
        final row = unstable[name]!;
        expect(
          row['fired'],
          isTrue,
          reason:
              'driver $name no longer reaches a canon open failure — it '
              'must be re-derived or removed, not left silently vacuous',
        );
        fired++;
        expect(
          row['rc'],
          -4,
          reason:
              "driver $name: canon's catch-all is the only failure code "
              'the open path produces besides a missing config',
        );
        expect(
          row['carried'],
          isTrue,
          reason:
              'driver $name carried no detail at all, so its clean '
              'result says nothing about leakage',
        );
        expect(
          row['marker'],
          isFalse,
          reason:
              'driver $name LEAKED the marker into the exception message:\n'
              '${row['message']}',
        );
      }
      expect(fired, 9, reason: 'nine drivers, all of which must fire');
    });

    test('misattribution is impossible on this path by construction, and that '
        'is stated', () {
      // The structural half of criterion B, discharged here rather than by a
      // behavioural cell: there is no read-back to interleave against.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final workerStart = shim.indexOf('static void* _zd_open_worker(');
      final worker = shim.substring(workerStart, workerStart + 2200);
      expect(worker, contains('TRAVELS WITH THE POST'));
      expect(worker, contains('local to this call'));

      final session = flattenedProse('lib/src/session.dart');
      expect(
        session,
        contains('captured on the worker'),
        reason:
            'the Dart side must state where the detail came from, or a '
            'reader has to infer it from the shim',
      );
      expect(
        session,
        contains('no other operation'),
        reason:
            'the property is that no OTHER operation’s text can '
            'reach this message — that is what makes misattribution '
            'structurally impossible rather than merely unobserved',
      );
    });

    test('the dartdoc states which channel leaks and which does not', () {
      final session = flattenedProse('lib/src/session.dart');
      // ⭐ The finding this slice exists to record: the echo is a property of
      // the ERROR TYPE, not of the path's input. Open failures render a
      // diagnosis; config PARSE errors echo their source with a caret. A
      // reader told only "the open path is clean" will draw the wrong general
      // conclusion and enrich a parse path next.
      expect(session, contains('property of the error type'));
      expect(session, contains('caret'));
      expect(
        session,
        contains('do echo'),
        reason:
            'the leaking channel must be named, not merely implied by the '
            "clean one's absence",
      );
    });

    // --- Edge cases ---

    test('on the stable variant the message carries no detail', () async {
      // Criterion F2's second arm, and the variant consumers actually get.
      // ⛔ An HONEST ABSENCE: the capture is compiled out, so there is no
      // detail to leak and no fix being demonstrated.
      final stable = await runProbe('stable');
      expect(stable['VARIANT']!['variant'], 'stable');
      for (final name in drivers.keys) {
        final row = stable[name]!;
        expect(row['fired'], isTrue, reason: 'driver $name must still fail');
        expect(
          row['carried'],
          isFalse,
          reason:
              'driver $name carried a detail segment on stable, where the '
              'capture is compiled out',
        );
        expect(row['marker'], isFalse);
        expect(
          row['message'],
          isNot(contains(secret)),
          reason: 'driver $name leaked on stable',
        );
      }
      // And the control still fires here, so the stable arm is not reading a
      // blindness twice: the config channel echoes on BOTH variants via
      // canon's own text... except that on stable the capture is compiled
      // out, so the echo is absent from the exception. That asymmetry is the
      // point of the next cell in slice 8, and is asserted there against the
      // LOG channel, which does leak on stable.
      expect(stable['CONTROL']!['fired'], isTrue);
      expect(
        stable['CONTROL']!['marker'],
        isFalse,
        reason:
            'on stable the enriched channel carries no upstream text at '
            'all, so even the control cannot echo — which is exactly why the '
            'log channel is the one that matters there',
      );
    });

    test('a failure class whose text is unknown is not claimed clean', () {
      final session = flattenedProse('lib/src/session.dart');
      expect(
        session,
        contains('nine'),
        reason: 'the number of drivers behind the claim must be stated',
      );
      expect(
        session,
        contains('not a proof over'),
        reason:
            'the limit must be written where the claim is, or the claim '
            'reads as universal',
      );
    });
  });
}
