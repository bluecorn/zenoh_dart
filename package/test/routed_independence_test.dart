// The default suite must not acquire a router dependency — guarded here
// rather than asserted in a report.
//
// The unit's first acceptance criterion is that `./scripts/test.sh` still
// runs, green for green, for someone who has never fetched anything. That is
// demonstrated by a run. **This file is what stops the demonstration
// decaying**, because this project's record is that a run recorded in a
// report is not a control: it is true on the day it is written and nothing
// re-checks it.
//
// Every cell below reads SOURCE, not behaviour. They cost nothing, they run
// in the default suite, and they fail the moment a routed counterpart starts
// reaching for something the default suite does not have.
//
// ⚠️ THIS FILE EXCLUDES ITSELF FROM ITS OWN SCANS, and the exclusion is not a
// convenience. A scanner has to name the strings it forbids, and this file's
// name matches the very glob it scans. Excluding it keeps the needles from
// matching themselves. What that costs is stated where it is taken: this file
// is the one routed file its own guards do not cover, so it must not acquire
// a router dependency of its own — and it has none, since it opens no session
// and starts no process.

import 'dart:io';

import 'package:test/test.dart';

/// This file's own name, excluded from every scan below. See the header.
const _selfName = 'routed_independence_test.dart';

/// The helper every routed counterpart is built on.
const _helperPath = 'test/helpers/routed_topology.dart';

/// The band this unit allocated, above a corpus ceiling measured at 19765.
const _portFloor = 19800;
const _portCeiling = 19899;

/// Every source file this unit adds, except this one.
///
/// Derived from the tree rather than listed, so a counterpart file added by a
/// later slice is covered the moment it lands — a hand-maintained list is
/// exactly the shape that goes stale silently.
List<File> routedSources() {
  final files = <File>[
    for (final entity in Directory('test').listSync())
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('routed_') &&
          entity.uri.pathSegments.last.endsWith('_test.dart') &&
          entity.uri.pathSegments.last != _selfName)
        entity,
  ];
  final helper = File(_helperPath);
  if (helper.existsSync()) files.add(helper);
  return files;
}

/// A file's lines, paired with their 1-based numbers, comments dropped.
///
/// Comment lines are dropped because the criteria below are about what the
/// code DOES. A comment naming a forbidden string is how a defect gets
/// explained; forbidding it there would make the guard unwritable.
Iterable<({String path, int line, String text})> codeLines(File f) sync* {
  final lines = f.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i];
    if (text.trimLeft().startsWith('//')) continue;
    yield (path: f.path, line: i + 1, text: text);
  }
}

void main() {
  group('The routed counterparts hold no router-harness dependency', () {
    test('the scan covers the files this unit actually added', () {
      // A guard over an empty set passes vacuously. This is the control for
      // every cell below it: if the derivation breaks, the guards go quiet
      // rather than red, and this is what notices.
      final sources = routedSources();

      expect(
        sources,
        isNotEmpty,
        reason:
            'routedSources() found nothing to scan -- the derivation is '
            'broken, and every guard in this file is passing vacuously.',
      );
      expect(
        sources.map((f) => f.path),
        contains(_helperPath),
        reason:
            'the helper is the one file every counterpart is built on; '
            'a scan that misses it misses the whole mechanism.',
      );
    });

    test(
      'no routed file names a router binary, the harness, or its env vars',
      () {
        // The four things a routed counterpart must never reach for. Naming any
        // of them is what would make the default suite depend on a fetch step.
        const forbidden = [
          'zenohd',
          'scripts/topology',
          'ZENOH_TOPOLOGY_',
          'fetch_router',
        ];

        final hits = <String>[];
        for (final file in routedSources()) {
          for (final line in codeLines(file)) {
            for (final needle in forbidden) {
              if (line.text.contains(needle)) {
                hits.add('${line.path}:${line.line} names "$needle"');
              }
            }
          }
        }

        expect(
          hits,
          isEmpty,
          reason:
              'A routed counterpart reached for the router harness. The '
              'validity half is built on a router this process hosts, which '
              'needs no fetched artifact; a reference to one here would give '
              'the default suite a dependency it does not have.\n'
              '${hits.join('\n')}',
        );
      },
    );

    test('no routed file binds a port outside this unit band, or 7447', () {
      // Two instruments, and the runtime guard in the helper is a third:
      // `HostedRouter.open` refuses out-of-band ports when it runs. This one
      // READS where that one RUNS, so a port that never reaches the helper —
      // a raw endpoint literal, say — is still caught.
      //
      // WHAT THIS SCAN CANNOT SEE, stated rather than left to be discovered:
      // it matches LITERAL ports only. A computed one — `open(portFloor - 1)`,
      // as the boundary-refusal cell uses — passes through unread. That is
      // why the two instruments are kept together rather than one being
      // called sufficient: the runtime refusal covers exactly the computed
      // case this one is blind to, and that case is the only place a routed
      // file names an out-of-band port on purpose.
      final endpointPort = RegExp(r'tcp/127\.0\.0\.1:(\d+)');
      final namedPort = RegExp(r'[Pp]ort[A-Za-z]*\s*[=:]\s*(\d{4,5})\b');
      final openCall = RegExp(r'HostedRouter\.open\(\s*(\d{4,5})\s*\)');

      final offenders = <String>[];
      for (final file in routedSources()) {
        for (final line in codeLines(file)) {
          for (final pattern in [endpointPort, namedPort, openCall]) {
            for (final m in pattern.allMatches(line.text)) {
              final port = int.parse(m.group(1)!);
              if (port < _portFloor || port > _portCeiling) {
                offenders.add(
                  '${line.path}:${line.line} binds $port '
                  '(band is $_portFloor-$_portCeiling)',
                );
              }
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'A routed cell bound a port outside the band this unit '
            'allocated. Below 19765 it collides with the ~189 endpoint '
            'literals the corpus already holds, and the collision presents '
            'as a delivery red rather than as an address clash.\n'
            '${offenders.join('\n')}',
      );
    });

    test('the default runner still cannot see the interop tier', () {
      // The interop files are named `*_interop.dart` precisely so the default
      // glob misses them, which is what keeps the measured baseline stable.
      // This unit adds a routed MODE to that tier; if the glob widened, every
      // interop file would join the default suite with no error and no
      // warning, and the baseline would move for a reason nobody could see.
      //
      // Read the SETTING, not the file. The file's own comments explain the
      // mechanism and therefore name `*_interop.dart` several times, so a
      // whole-file scan for that string answers about the prose rather than
      // about the glob.
      final settingLine = File('dart_test.yaml')
          .readAsLinesSync()
          .where((l) => l.trimLeft().startsWith('filename:'))
          .toList();

      expect(
        settingLine,
        hasLength(1),
        reason: 'dart_test.yaml must state exactly one filename glob.',
      );
      expect(settingLine.single.trim(), equals('filename: "*_test.dart"'));
    });
  });

  group('The routed counterparts avoid two known process-level hazards', () {
    test('no routed file carries a non-ASCII byte outside a comment', () {
      // A session operation on a key expression whose first chunk begins
      // multi-byte ABORTS THE PROCESS inside zenoh's routing layer, unfixed
      // upstream. With a router this process hosts, that abort takes the
      // whole run down rather than one child — so the blast radius here is
      // strictly larger than it is for the cells that found it.
      //
      // The scan is wider than key expressions on purpose: identifying a key
      // expression mechanically means guessing at call shapes, while "no
      // non-ASCII in code" is exact, needs no guess, and is satisfiable.
      // Prose keeps its em dashes; they live in comments.
      final offenders = <String>[];
      for (final file in routedSources()) {
        for (final line in codeLines(file)) {
          for (final unit in line.text.codeUnits) {
            if (unit > 0x7F) {
              offenders.add(
                '${line.path}:${line.line} carries U+'
                '${unit.toRadixString(16).toUpperCase()}',
              );
              break;
            }
          }
        }
      }

      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('no routed file asserts that a stderr buffer is silent', () {
      // `ERROR zenoh::api::admin: Unable to publish transport event: session
      // closed` appeared on EVERY routed path measured at plan time — from
      // canon's own binaries as well as ours. A silence assertion over
      // stderr is therefore a cell that fails for a reason unrelated to its
      // subject.
      //
      // ⛔ NARROWED 2026-09-08, because the first form was over-broad and
      // would have refused a pattern the corpus uses NINE times. It flagged
      // any `stderr` line matching `isNot(contains(...))`, which catches
      // `expect(stderr, isNot(contains('Unhandled exception')))` — a SPECIFIC
      // application-level absence, not a silence claim, and measured across
      // the corpus as 'FormatException' (3), 'Could not find an option
      // named' (3), 'Unhandled exception' (2), 'ArgumentError' (1).
      //
      // The hazard is asserting the absence of the ROUTED NOISE. So a
      // negation flags only when what it negates could match that noise; a
      // specific application error is none of those words. `isEmpty` on a
      // stderr buffer is always the hazard and is always flagged.
      const noiseWords = [
        'ERROR',
        'error',
        'session closed',
        'transport event',
        'admin',
      ];
      final negation = RegExp(r'isNot\(\s*contains\(');

      final offenders = <String>[];
      for (final file in routedSources()) {
        for (final line in codeLines(file)) {
          if (!line.text.contains('stderr')) continue;
          final silences = line.text.contains('isEmpty');
          final negatesNoise =
              negation.hasMatch(line.text) &&
              noiseWords.any(line.text.contains);
          if (silences || negatesNoise) {
            offenders.add('${line.path}:${line.line}: ${line.text.trim()}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'A routed cell asserted stderr silence. Canon prints a '
            'transport-event error on every routed teardown, so the '
            'assertion is about the environment, not the subject.\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
