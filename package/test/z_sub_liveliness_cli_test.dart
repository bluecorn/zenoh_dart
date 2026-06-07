import 'dart:io';

import 'package:test/test.dart';

/// FVM-resolved Dart executable path for CLI process tests.
final _dartExe = Platform.resolvedExecutable;

/// Forcefully kills a process, using SIGKILL if SIGTERM doesn't work.
Future<void> forceKill(Process process) async {
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
  } catch (_) {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode
        .timeout(const Duration(seconds: 2))
        .catchError((_) => -1);
  }
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_sub_liveliness CLI', () {
    test('runs and prints subscriber declaration message', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub_liveliness.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
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

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/**'));
    });

    test('with empty key expression exits with error', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_sub_liveliness.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 30));

      expect(result.exitCode, isNot(0));
    });
  });
}
