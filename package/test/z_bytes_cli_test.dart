import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_bytes CLI', () {
    test(
      'runs and prints PASS with no FAIL',
      () async {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_bytes.dart',
        ], workingDirectory: packageRoot);

        expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
        expect(result.stdout.toString(), contains('PASS'));
        expect(result.stdout.toString(), isNot(contains('FAIL')));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      "runs canon's full section list and exits nonzero on failure",
      () async {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_bytes.dart',
        ], workingDirectory: packageRoot);
        final stdout = result.stdout as String;

        // The sections canon has that this example used to skip.
        expect(stdout, contains('composite int32 sequence'));
        expect(stdout, contains('custom struct'));
        // canon prints every slice; three appended payloads must stay three
        // slices, which "at least one slice, right total content" would not
        // have caught.
        expect(stdout, contains('slice iterator (3 distinct slices)'));
        expect(
          RegExp('slice len: 3').allMatches(stdout).length,
          equals(3),
          reason: 'canon prints one line per slice; stdout: $stdout',
        );
        // A FAIL line with a green exit is the false-green shape canon avoids
        // by asserting (`#undef NDEBUG`).
        expect(stdout, isNot(contains('FAIL')));
        expect(result.exitCode, equals(0));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // Seed #10's sections. Named individually rather than checked as a count,
    // so a section that silently stops running is a red rather than a smaller
    // number nobody reads.
    test(
      'exercises the single-shot conversions and the encoding schema surface',
      () async {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_bytes.dart',
        ], workingDirectory: packageRoot);
        final stdout = result.stdout as String;

        // canon's own z_bytes.c uses the ONE-SHOT family for exactly this
        // (`ze_serialize_uint32` at :69); before seed #10 only int64, binary64
        // and bool had a single-shot form on this surface.
        expect(stdout, contains('PASS: single-shot integer widths round-trip'));
        expect(
          stdout,
          contains('PASS: single-shot float narrows to binary32'),
        );
        expect(stdout, contains('PASS: single-shot uint64 is bit-exact'));

        // canon's z_bytes.c only MENTIONS the encoding constants in comments
        // (:49-50, :60-61, :73-74) and never demonstrates the schema. The
        // three states are what this seed made expressible.
        expect(
          stdout,
          contains(
            'PASS: encoding schema: absent, empty and present are distinct',
          ),
        );
        expect(
          stdout,
          contains('PASS: encoding schema: derived getter, and explicit wins'),
        );
        expect(
          stdout,
          contains("PASS: encoding constants: canon's table"),
        );

        expect(result.exitCode, equals(0));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // ⚠️ NO NEW CLI BINARY. canon's counterpart for this surface is
    // `z_bytes.c`, which this example already mirrors — adding a `z_encoding`
    // binary would create an example with no canon counterpart, which the
    // example README handles only through its "Absent Examples" mechanism.
    test('no z_encoding binary was introduced', () {
      expect(
        File('example/z_encoding.dart').existsSync(),
        isFalse,
        reason:
            'the seed extends z_bytes.dart rather than adding a binary '
            'with no canon counterpart',
      );
    });
  });
}
