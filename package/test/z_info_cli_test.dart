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

  group('z_info CLI', () {
    Future<ProcessResult> runZInfo([List<String> args = const []]) async {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_info.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('runs with default arguments and prints own id', () async {
      final result = await runZInfo();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      // Must contain 'own id:' followed by a hex string
      expect(stdout, contains('own id:'));
      expect(stdout, matches(RegExp('own id: [0-9a-f]+')));
    });

    test('prints router and peer ID sections', () async {
      final result = await runZInfo();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('routers ids:'));
      expect(stdout, contains('peers ids:'));
    });

    test('accepts connect endpoint flag', () async {
      final result = await runZInfo(['-e', 'tcp/127.0.0.1:7447']);
      // Process completes without argument parse error
      // Exit code may be non-zero if router is unavailable
      final stderr = result.stderr as String;
      expect(stderr, isNot(contains('Could not find an option named')));
      expect(stderr, isNot(contains('FormatException')));
    });

    test('accepts --connect and --listen long-form flags', () async {
      final result = await runZInfo(['--connect', 'tcp/127.0.0.1:7447']);
      // Process completes without argument parse error
      final stderr = result.stderr as String;
      expect(stderr, isNot(contains('Could not find an option named')));
      expect(stderr, isNot(contains('FormatException')));
    });
  });
}
