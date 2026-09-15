import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

// CLI tests for z_get_liveliness.dart

/// The Dart executable running this suite.
///
/// Spawning `fvm` hardcodes a tool that need not be on PATH, and resolves a
/// *different* Dart than the one running the test.
/// `Platform.resolvedExecutable` is the SDK we are already inside.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_get_liveliness CLI', () {
    Future<ProcessResult> runZGetLiveliness([
      List<String> args = const [],
    ]) async {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_get_liveliness.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('runs with default arguments and prints liveliness query', () async {
      final result = await runZGetLiveliness(['--timeout', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Sending liveliness query'));
      expect(result.stdout as String, contains('group1/**'));
    });

    test('accepts custom key and timeout flags', () async {
      final result = await runZGetLiveliness([
        '-k',
        'custom/group/**',
        '-o',
        '2000',
      ]);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('custom/group/**'));
    });

    test('empty key expression exits with error', () async {
      final result = await runZGetLiveliness(['-k', '', '-o', '2000']);
      expect(result.exitCode, isNot(equals(0)));
    });
  });
}
