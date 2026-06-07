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

  group('z_liveliness CLI', () {
    test('runs and prints token declaration message', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_liveliness.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Let it run for 3 seconds, then kill it
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Liveliness token declared'));
      expect(output, contains('group1/zenoh-dart'));
      expect(output, contains('Press CTRL-C'));
    });

    test('accepts custom key, connect, and listen flags', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_liveliness.dart',
        '--key',
        'custom/token/key',
        '--connect',
        'tcp/127.0.0.1:7447',
        '--listen',
        'tcp/127.0.0.1:18560',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await stdoutSub.cancel();
      await stderrSub.cancel();

      // The custom key should appear in output
      expect(stdout.toString(), contains('custom/token/key'));
    });

    test('invalid key expression exits with error', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_liveliness.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 30));

      expect(result.exitCode, isNot(0));
    });
  });
}
