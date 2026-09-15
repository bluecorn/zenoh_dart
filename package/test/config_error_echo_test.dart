// Seed [D1] slice 4 — the config sites' value echo is stated where a consumer
// will meet it.
//
// ⛔ THE ASYMMETRY THIS FILE EXISTS FOR. Slice 3 measured the open path clean
// over nine drivers and wrote down WHY: canon's open-failure errors render a
// diagnosis rather than an echo. That is a property of the ERROR TYPE, and the
// config paths are the other side of it — canon's json5 parser echoes the
// offending value, the surrounding source line, and prints a caret under the
// offending token. Same binding, same factory, opposite behaviour.
//
// So the echo is asserted here as a DOCUMENTED CONTRACT rather than left as
// something a consumer might discover in a bug report. A warning that is not
// tested is a warning that goes stale silently.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// See `open_detail_secrets_test.dart` for why prose is read flattened: a
/// `contains` against raw source is hostage to line wrapping, and reports a
/// missing claim when what moved was a line break.
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

/// The marker, planted in a value canon rejects.
const _marker = 'ZD-D1-S4-MARKER';

/// The five PUBLIC entry points a consumer can reach that carry upstream
/// detail, with the substring that anchors each one's dartdoc.
///
/// ⚠️ FIVE, NOT THE THREE THE FENCE COUNTS, and the difference is deliberate.
/// The fence counts *enriched call sites*, and three of the five share one —
/// the private `_build` skeleton behind `fromStr`, `fromFile` and `fromEnv`.
/// A consumer never reads `_build`'s dartdoc. The warning has to be where the
/// reader is, so it is on all five.
const _publicEntryPoints = <String, String>{
  'fromStr': 'factory Config.fromStr(',
  'fromFile': 'factory Config.fromFile(',
  'fromEnv': 'factory Config.fromEnv(',
  'insertJson5': 'void insertJson5(',
  'get': 'String get(',
};

/// The dartdoc block immediately above [declaration] in [source].
String dartdocAbove(String source, String declaration) {
  final at = source.indexOf(declaration);
  expect(at, greaterThanOrEqualTo(0), reason: '$declaration not found');
  final lines = source.substring(0, at).split('\n');
  final doc = <String>[];
  for (var i = lines.length - 2; i >= 0; i--) {
    final line = lines[i].trimLeft();
    if (line.startsWith('///')) {
      doc.insert(0, line.substring(3).trim());
    } else if (line.startsWith('@') || line.isEmpty) {
      continue;
    } else {
      break;
    }
  }
  return doc.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

Future<Map<String, String>> runProbe(String variant) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/config_failure_probe.dart', _marker],
    environment: {'ZENOH_DART_VARIANT': variant},
  );
  final out = result.stdout as String;
  expect(
    out,
    contains('PROBE_DONE'),
    reason: 'the probe did not finish:\n$out${result.stderr}',
  );
  final parsed = <String, String>{};
  for (final line in const LineSplitter().convert(out)) {
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final key = line.substring(0, eq);
    final value = line.substring(eq + 1);
    parsed[key] = key == 'VARIANT' ? value : jsonDecode(value) as String;
  }
  return parsed;
}

void main() {
  group('[D1] S4 — the config value echo is documented', () {
    test(
      'the echo is asserted as the documented contract, not left to chance',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (the capture is compiled out on '
                'stable — criterion F2, honest absence)',
      () {
        // Driven in-process: a value canon rejects, carrying the marker.
        final config = Config();
        String? message;
        try {
          config.insertJson5(
            'connect/endpoints',
            '["tcp/1.2.3.4:7447" $_marker]',
          );
          fail('expected canon to reject the value');
        } on ZenohException catch (e) {
          message = e.message;
        } finally {
          config.dispose();
        }

        expect(
          message,
          contains(_marker),
          reason:
              'the offending value must come back verbatim — this is the '
              'behaviour the dartdoc warns about, and a warning about '
              'something that does not happen is worse than no warning',
        );
        expect(
          message,
          contains('^---'),
          reason:
              "canon's caret rendering, which is what makes the echo "
              'carry the SURROUNDING source line and not just the value',
        );
        expect(
          message,
          contains('tcp/1.2.3.4:7447'),
          reason:
              'the adjacent, intact content of the same line comes back '
              'too — that is the part a consumer will not expect',
        );
      },
    );

    test('the dartdoc warns against forwarding the message', () {
      final source = File('lib/src/config.dart').readAsStringSync();
      for (final entry in _publicEntryPoints.entries) {
        final doc = dartdocAbove(source, entry.value);
        expect(
          doc,
          contains('echo'),
          reason:
              '${entry.key} does not say the message may echo the '
              'offending config text',
        );
        expect(
          doc,
          contains('unstable'),
          reason:
              '${entry.key} does not name the variant on which it does — '
              'criterion F2 applies to the warning as much as to the cell',
        );
        expect(
          doc,
          contains('not forward'),
          reason:
              '${entry.key} describes the hazard without telling the '
              'caller what to do about it',
        );
      }
    });

    test('the no-redaction decision is recorded with its ground', () {
      final exceptions = flattenedProse('lib/src/exceptions.dart');
      expect(exceptions, contains('no redaction is applied'));
      expect(
        exceptions,
        contains('one opaque string'),
        reason:
            'the GROUND must be there, not just the decision: a general '
            'redactor is not implementable at this seam because the shim '
            'receives one opaque string with no structure to redact against',
      );
      expect(
        exceptions,
        contains('manufacture'),
        reason:
            'and the second half of the ground — a PARTIAL redactor '
            'manufactures confidence, which is worse than none',
      );
    });

    // --- Edge cases ---

    test(
      'on the stable variant there is no echo because there is no detail',
      () async {
        // Criterion F2's second arm, on the variant consumers actually get.
        // ⛔ The absence is HONEST, not a fix: the capture is compiled out, so
        // no upstream text of any kind reaches the exception channel here.
        final stable = await runProbe('stable');
        expect(stable['VARIANT'], 'stable');
        expect(
          stable['CARET'],
          'Failed to insert config value for key "connect/endpoints"',
          reason: 'the base text, and nothing else',
        );
        expect(stable['CARET'], isNot(contains(_marker)));
        expect(stable['CARET'], isNot(contains('^---')));

        // The same driver on unstable DOES echo, in the same shape, so the two
        // arms are not reading one blindness twice.
        final unstable = await runProbe('unstable');
        expect(unstable['VARIANT'], 'unstable');
        expect(unstable['CARET'], contains(_marker));
        expect(unstable['CARET'], contains('^---'));
      },
    );
  });
}
