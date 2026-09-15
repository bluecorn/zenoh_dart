// Seed [D1] slice 15 — the loaded library path is reachable from the public
// door.
//
// The one value that answers *"which library did you actually load?"* has
// existed since the loader was written, and has been available only by
// reaching into `src/` — in violation of the package's own convention. That is
// a diagnosability defect on the question a consumer asks precisely when
// nothing else is working.
//
// ⛔ AND THE ACCESSOR DOES NOT FORCE INITIALISATION, which is the whole design
// decision. An accessor whose purpose is diagnosing a LOAD problem must not
// itself depend on the load succeeding: it would throw at exactly the moment a
// consumer most needs it, and merely asking would drag in a 13 MB library. It
// is total, it never throws, and it returns `null` with all three null cases
// enumerated. This diverges deliberately from the `bindings` getter, which
// DOES auto-initialise — and the dartdoc says why.
import 'dart:convert';
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

Future<String> runProbe(
  String mode, {
  Map<String, String> environment = const {},
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/resolved_path_probe.dart', mode],
    environment: environment,
  );
  return '${result.stdout}${result.stderr}';
}

void main() {
  group('[D1] S15 — resolvedLibraryPath from the public door', () {
    test(
      'a consumer importing only the public library can read the path',
      () async {
        final out = await runProbe('after-open');
        expect(out, contains('PROBE_DONE'), reason: out);
        final path = const LineSplitter()
            .convert(out)
            .firstWhere((l) => l.startsWith('PATH='), orElse: () => '')
            .replaceFirst('PATH=', '');
        expect(
          path,
          contains('libzenoh_dart.so'),
          reason:
              'the accessor did not report the loaded library after a '
              'session had been opened:\n$out',
        );
        // And the probe reaches it WITHOUT importing src/ — asserted on its
        // source, because that is the whole claim.
        final probe = File('test/helpers/resolved_path_probe.dart')
            .readAsStringSync();
        expect(
          probe,
          isNot(contains('zenoh_dart/src/')),
          reason:
              'the probe reaches into src/, so it demonstrates nothing '
              'about the public door',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'the accessor is total — before initialisation and after a failed one',
      () async {
        // ⛔ THE CELL THE DESIGN DECISION EXISTS FOR. Reading it must not load
        // anything, and must not throw when the load has already gone wrong —
        // which is exactly when a consumer reaches for it.
        final cold = await runProbe('cold');
        expect(cold, contains('PATH=<null>'), reason: cold);
        expect(cold, contains('PROBE_DONE'));
        expect(
          cold,
          isNot(contains('LOADED')),
          reason:
              'merely asking for the path initialised the library, which is '
              'both a 13 MB side effect and the thing that would make this '
              'accessor useless when the load is the problem',
        );

        final failed = await runProbe(
          'after-failure',
          environment: {'ZENOH_DART_VARIANT': 'nonexistent-variant'},
        );
        expect(failed, contains('INIT_THREW'), reason: failed);
        expect(
          failed,
          contains('PATH=<null>'),
          reason: 'the accessor threw or reported a path after a failed load',
        );
        expect(failed, contains('PROBE_DONE'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'the three null cases are enumerated where a consumer will read them',
      () {
        final doc = flattenedProse('lib/src/zenoh.dart');
        expect(doc, contains('nothing has been loaded yet'));
        expect(doc, contains('the load failed'));
        expect(
          doc,
          contains('soname'),
          reason:
              'the third case is the one nobody guesses: the OS linker '
              'resolved by soname, so there was never a path to record — '
              'the APK and Flutter desktop origin lib case',
        );
        expect(
          doc,
          contains('does not initialise'),
          reason:
              'the no-auto-initialise decision must be stated, because it '
              'diverges from the bindings getter right next to it',
        );
      },
    );

    // --- Edge cases ---

    test(
      'the accessor reports the variant actually loaded, not the requested',
      () async {
        final out = await runProbe(
          'after-open',
          environment: {'ZENOH_DART_VARIANT': 'stable'},
        );
        expect(out, contains('PROBE_DONE'), reason: out);
        expect(
          out,
          contains('/stable/'),
          reason:
              'a consumer diagnosing a variant question must get the truth '
              'rather than their own request echoed back:\n$out',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('native_lib.dart stays out of both public doors', () {
      for (final door in const [
        'lib/zenoh.dart',
        'lib/zenoh_unstable.dart',
      ]) {
        expect(
          File(door).readAsStringSync(),
          isNot(contains('native_lib.dart')),
          reason:
              '$door exports the loader, which would make `bindings` and '
              '`nativeLibrary` public surface — the accessor exists so that '
              'does not have to happen',
        );
      }
    });

    test('the new accessor trips no walked-tree pin', () {
      final zenoh = File('lib/src/zenoh.dart').readAsStringSync();
      expect(
        zenoh,
        isNot(contains('Safe to call multiple times')),
        reason: 'that phrase moves the 10+10+1 finalizer partition',
      );
      expect(
        zenoh,
        isNot(
          contains(
            'sendPort'
            '.send',
          ),
        ),
      );
      expect(zenoh, isNot(contains('Isolate.spawn')));
    });
  });
}
