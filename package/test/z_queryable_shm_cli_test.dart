import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// The FVM-resolved Dart executable path.
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

  group('z_queryable_shm CLI', () {
    test('runs and declares queryable', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable_shm.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('Declaring Queryable'));
      expect(stdout.toString(), contains('demo/example/zenoh-dart-queryable'));
    });

    test('accepts --key flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable_shm.dart',
        '--key',
        'demo/custom/shm',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/shm'));
    });

    test('prints SHM provider creation', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable_shm.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('SHM'));
    });
  });
}
