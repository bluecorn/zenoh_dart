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

  group('z_put CLI', () {
    Future<ProcessResult> runZPut([List<String> args = const []]) async {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_put.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('runs with default arguments', () async {
      final result = await runZPut();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Putting Data'));
    });

    test('accepts custom key and payload', () async {
      final result = await runZPut([
        '--key',
        'demo/test',
        '--payload',
        'Custom value',
      ]);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('demo/test'));
      expect(stdout, contains('Custom value'));
    });

    test('with invalid key expression exits with error', () async {
      final result = await runZPut(['--key', '']);
      expect(result.exitCode, isNot(0));
    });
  });
}
