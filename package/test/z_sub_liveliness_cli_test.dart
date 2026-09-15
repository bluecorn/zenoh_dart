import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// FVM-resolved Dart executable path for CLI process tests.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_sub_liveliness CLI', () {
    test('runs and prints subscriber declaration message', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub_liveliness.dart',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForReady(stdout);
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('Declaring Liveliness Subscriber'));
      expect(stdout.toString(), contains('group1/**'));
    });

    test('accepts custom key and history flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub_liveliness.dart',
        '-k',
        'demo/custom/**',
        '--history',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForReady(stdout);
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/**'));
    });

    test('with empty key expression exits with error', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_sub_liveliness.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });
  });
}
