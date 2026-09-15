// Seed [D1] slice 10 — `initLog` is documented as the diagnosis route, with
// its exclusivity and its leak.
//
// ⛔ THIS SLICE SHIPS NO NEW BEHAVIOUR, AND THAT IS NOT A REASON TO WEAKEN IT.
// The security ruling this unit implements closes with a documentation item:
// *"keep the plain constructor, document `initLog` as the diagnosis route, and
// bind `zc_init_log_with_callback`."* Two of those three are code and were
// measurable. The third can ship unverified while the plan reads complete —
// which is exactly what criterion H exists to prevent, so it gets a covering
// cell rather than a tick in a list.
//
// ⛔ AND THE ADVICE IS QUALIFIED, BECAUSE EVERY QUALIFICATION WAS MEASURED IN
// THIS UNIT. A bare "call initLog to see the cause" would be:
//   * FALSE about exclusivity — it forecloses the sink, silently, for the life
//     of the process (slice 7);
//   * FALSE about leakage — the channel echoes rejected config values verbatim
//     on both variants (slice 8);
//   * INCOMPLETE about the default build — on `stable` it is not the better
//     route, it is the ONLY one (slices 1, 3, 4).
// Recommending it without those three is how a reader ends up debugging a
// delivery problem that is an ordering problem, or shipping a secret into a
// log file.
import 'dart:io';

import 'package:test/test.dart';

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

/// The dartdoc block immediately above `declaration` in the file at `path`,
/// flattened the same way.
///
/// Used where a claim must live at a SPECIFIC entry point rather than
/// somewhere in the file — "the advice carries its warning" is a statement
/// about adjacency, and a file-wide scan cannot see adjacency at all.
String dartdocAbove(String path, String declaration) {
  final source = File(path).readAsStringSync();
  final at = source.indexOf(declaration);
  expect(
    at,
    greaterThanOrEqualTo(0),
    reason: '$declaration not found in $path',
  );
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
  return doc
      .join(' ')
      .replaceAll('*', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
}

void main() {
  group('[D1] S10 — the diagnosis route is documented', () {
    test('the open-failure path points a reader at the diagnosis route', () {
      // The reader arrives here holding `-4` and nothing else. Canon collapses
      // every open failure but a missing config into that one code, so the
      // symbol alone is not a diagnosis and the dartdoc must send them
      // somewhere that is.
      final rendering = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      expect(
        rendering,
        contains('zenoh.initlog'),
        reason:
            'the failure-rendering dartdoc does not name the env-logger '
            'route',
      );
      expect(
        rendering,
        contains('zenoh.initlogwithsink'),
        reason:
            'and it must name the SINK route too: a host application '
            'that cannot read stdout has only that one',
      );
      expect(
        rendering,
        contains('catch-all'),
        reason:
            'Z_ENETWORK must be named as the catch-all it is, rather '
            'than left to read as a diagnosis of a network fault',
      );

      // And the entry point a reader actually calls carries the pointer too,
      // because that is where they are when the future rejects.
      final open = dartdocAbove(
        'lib/src/session.dart',
        'static Future<Session> open(',
      );
      expect(
        open,
        contains('initlog'),
        reason:
            'Session.open itself must point at the route; a reader who '
            'never opens the private renderer would otherwise never see it',
      );
    });

    test('the advice carries its exclusivity warning', () {
      final rendering = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      expect(
        rendering,
        contains('forecloses'),
        reason:
            'recommending initLog without saying it claims the logging '
            'slot permanently sets the reader up to install a sink later and '
            'get nothing',
      );
      expect(
        rendering,
        contains('stateerror'),
        reason:
            'and WHERE the foreclosure surfaces matters: at the sink '
            'install, not at the initLog call — a reader told only that it '
            'is exclusive will look for the error in the wrong place',
      );
    });

    test('the advice carries its leak condition', () {
      final rendering = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      // ⚠️ The measurement that made logging the recommended route was about
      // open-failure CAUSES, which carry no config. The CHANNEL is not clean:
      // config-rejection records echo the offending value verbatim. Carrying
      // the recommendation without the condition is how "the zero-leak route"
      // gets believed.
      expect(rendering, contains('echo'));
      expect(
        rendering,
        contains('both build variants'),
        reason:
            'the leak is not variant-gated the way the exception channel '
            'is, so the recommendation must be qualified rather than '
            'presented as the zero-leak route',
      );
    });

    // --- Edge cases ---

    test('the stable-variant asymmetry is stated where it bites', () {
      final rendering = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      // On the default build the exception channel carries no upstream detail
      // at all. So logging is not merely the better route there — it is the
      // only one, and a reader who does not know that will keep reading a
      // message that structurally cannot say more.
      expect(rendering, contains('stable'));
      expect(
        rendering,
        contains('the only route'),
        reason:
            'on the default variant logging is the ONLY route to the '
            'cause, not the preferable one, and the difference decides '
            'whether a reader keeps looking at the exception message',
      );
    });

    test('every claim traces to a measurement in this unit', () {
      // ⛔ NOT A STYLE CHECK. This slice is the one that recommends something,
      // and a recommendation is where an unmeasured claim does the most
      // damage. Each phrase below is carried by a cell elsewhere in the unit;
      // this asserts the surface does not carry a number without its
      // condition.
      final zenoh = flattenedProse('lib/src/zenoh.dart');
      expect(zenoh, contains('zero leakage'));
      expect(
        zenoh,
        contains('config-rejection records'),
        reason:
            'the "zero leakage" measurement must never appear without the '
            'condition that bounds it',
      );
      final session = flattenedProse('lib/src/session.dart');
      expect(session, contains('nine'));
      expect(
        session,
        contains('not a proof over'),
        reason:
            'the nine-driver secrets result must never appear without its '
            'stated limit',
      );
    });
  });
}
