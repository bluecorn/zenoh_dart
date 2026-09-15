import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The Dart executable running this suite.
///
/// Spawning `fvm` hardcodes a tool that need not be on PATH, and resolves a
/// *different* Dart than the one running the test.
/// `Platform.resolvedExecutable` is the SDK we are already inside.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_get CLI', () {
    Future<ProcessResult> runZGet([List<String> args = const []]) async {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_get.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('runs with default arguments and prints query', () async {
      final result = await runZGet(['--timeout', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Sending Query'));
      expect(result.stdout as String, contains('demo/example/**'));
    });

    test('accepts --selector flag', () async {
      final result = await runZGet([
        '--selector',
        'demo/custom/**',
        '--timeout',
        '2000',
      ]);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('demo/custom/**'));
    });

    test('accepts short flags', () async {
      final result = await runZGet(['-s', 'demo/short/**', '-o', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('demo/short/**'));
    });

    test('splits a selector at ? into key expression and parameters', () async {
      // The discriminating case for canon's selector handling (z_get.c:38-44).
      // Passing the whole selector through as a key expression throws --
      // '?' is not legal inside one -- so before the split this exited 255
      // with an uncaught ZenohException.
      final result = await runZGet([
        '-s',
        'demo/example/**?arg=value&other=1',
        '-o',
        '2000',
      ]);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(
        result.stdout as String,
        contains("Sending Query 'demo/example/**?arg=value&other=1'"),
      );
    });

    test('rejects an unsupported query target', () async {
      // canon's parse_query_target aborts; a silent fallback to the default
      // target would query differently than the user asked, without saying so.
      final result = await runZGet(['-t', 'BOGUS']);
      expect(result.exitCode, isNot(0));
      expect(
        result.stdout as String,
        contains('Unsupported query target value [BOGUS]'),
      );
    });

    test('-o 0 is canon-valid and runs rather than crashing', () async {
      // canon's z_get accepts `-o 0` and reads it as "use the configured
      // default query timeout". Seed #6 refuses a zero Duration at the API, so
      // an example that forwarded the flag verbatim would turn a canon-valid
      // invocation into an uncaught ArgumentError -- a reachable crash from a
      // documented flag value. The example translates the sentinel instead.
      final result = await runZGet(['-s', 'demo/nobody/answers/**', '-o', '0']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Sending Query'));
      expect(result.stderr as String, isNot(contains('ArgumentError')));
    });
  });
}
