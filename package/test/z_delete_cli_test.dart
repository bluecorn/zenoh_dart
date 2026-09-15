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
  // Get the package root (where pubspec.yaml lives)
  // Tests run from package/
  final packageRoot = Directory.current.path;

  group('z_delete CLI', () {
    Future<ProcessResult> runZDelete([List<String> args = const []]) async {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_delete.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('runs with default arguments', () async {
      final result = await runZDelete();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Deleting'));
    });

    test('accepts custom key', () async {
      final result = await runZDelete(['--key', 'demo/test']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('demo/test'));
    });

    test('with invalid key expression exits with error', () async {
      final result = await runZDelete(['--key', '']);
      expect(result.exitCode, isNot(0));
    });
  });
}
