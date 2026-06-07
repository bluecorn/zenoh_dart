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

/// Starts z_sub_thr listening on [endpoint] and waits for it to bind.
/// Returns the running sub_thr process.
Future<Process> startSubThr(String endpoint, String packageRoot) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_sub_thr.dart',
    '-s',
    '1',
    '-n',
    '1000',
    '-l',
    endpoint,
  ], workingDirectory: packageRoot);

  // Wait for listener to bind
  await Future<void>.delayed(const Duration(seconds: 8));
  return process;
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_pub_shm_thr CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_pub_shm_thr.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_pub_shm_thr.dart must exist',
      );
    });

    test('requires payload size argument', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_pub_shm_thr.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });

    test('starts and publishes with SHM', () async {
      const endpoint = 'tcp/127.0.0.1:18620';

      // Start z_sub_thr first (it listens)
      final subThrProcess = await startSubThr(endpoint, packageRoot);

      // Start z_pub_shm_thr connecting to the listener
      final pubShmProcess = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm_thr.dart',
        '64',
        '-e',
        endpoint,
      ], workingDirectory: packageRoot);

      try {
        // Wait for z_sub_thr to complete its measurement round
        final exitCode = await subThrProcess.exitCode.timeout(
          const Duration(seconds: 45),
        );

        final stdout = await subThrProcess.stdout
            .transform(const SystemEncoding().decoder)
            .join();

        expect(stdout, contains('msg/s'));
        expect(exitCode, equals(0));
      } finally {
        await forceKill(pubShmProcess);
        try {
          subThrProcess.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 90)));

    test('prints SHM startup messages', () async {
      const endpoint = 'tcp/127.0.0.1:18621';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm_thr.dart',
        '64',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((_) {}); // drain stderr

      // Let it run for 2 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 2));
      await forceKill(process);

      final output = stdoutBuf.toString();
      expect(output, contains('SHM Provider'));
      expect(output, contains('Allocating SHM buffer'));
    }, timeout: Timeout(Duration(seconds: 60)));

    test('accepts --shared-memory flag', () async {
      const endpoint = 'tcp/127.0.0.1:18622';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm_thr.dart',
        '-s',
        '16',
        '64',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((_) {}); // drain stderr

      // Let it run for 2 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 2));
      await forceKill(process);

      expect(stdoutBuf.toString(), contains('SHM Provider'));
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}
