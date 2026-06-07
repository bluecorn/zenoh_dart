import 'dart:io';

import 'package:test/test.dart';

/// The direct Dart executable path (not via fvm, to avoid zombie processes).
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

/// Starts z_pong listening on [endpoint] and waits for it to bind.
/// Returns the running pong process.
Future<Process> startPong(String endpoint, String packageRoot) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_pong.dart',
    '-l',
    endpoint,
  ], workingDirectory: packageRoot);

  // Wait for z_pong to bind TCP listener
  await Future<void>.delayed(const Duration(seconds: 8));
  return process;
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_ping_shm CLI', () {
    test('requires payload size argument', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_ping_shm.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });

    test(
      'prints latency results with z_pong running',
      () async {
        const port = 18580;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pongProcess = await startPong(endpoint, packageRoot);

        try {
          final result = await Process.run(_dartExe, [
            'run',
            'example/z_ping_shm.dart',
            '8',
            '--samples',
            '3',
            '--warmup',
            '0',
            '-e',
            endpoint,
          ], workingDirectory: packageRoot);

          expect(result.exitCode, equals(0));
          expect(result.stdout as String, contains('8 bytes: seq=0 rtt='));
        } finally {
          await forceKill(pongProcess);
        }
      },
      timeout: Timeout(Duration(seconds: 60)),
    );

    test('accepts --no-express flag', () async {
      const port = 18581;
      const endpoint = 'tcp/127.0.0.1:$port';

      final pongProcess = await startPong(endpoint, packageRoot);

      try {
        final result = await Process.run(_dartExe, [
          'run',
          'example/z_ping_shm.dart',
          '--no-express',
          '8',
          '-n',
          '1',
          '--warmup',
          '0',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);

        expect(result.exitCode, equals(0));
        expect(result.stdout as String, contains('rtt='));
      } finally {
        await forceKill(pongProcess);
      }
    }, timeout: Timeout(Duration(seconds: 60)));

    test(
      'prints SHM-related startup messages',
      () async {
        const port = 18582;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pongProcess = await startPong(endpoint, packageRoot);

        try {
          final result = await Process.run(_dartExe, [
            'run',
            'example/z_ping_shm.dart',
            '8',
            '-n',
            '1',
            '--warmup',
            '0',
            '-e',
            endpoint,
          ], workingDirectory: packageRoot);

          expect(result.exitCode, equals(0));
          final output = result.stdout as String;
          expect(output, contains('SHM Provider'));
          expect(output, contains('Allocating SHM buffer'));
        } finally {
          await forceKill(pongProcess);
        }
      },
      timeout: Timeout(Duration(seconds: 60)),
    );
  });
}
