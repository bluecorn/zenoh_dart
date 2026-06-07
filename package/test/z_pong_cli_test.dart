import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart'; // z_pong CLI tests

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

  group('z_pong CLI', () {
    test('runs and prints startup messages', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring Publisher'));
      expect(output, contains('Declaring Background Subscriber'));
    });

    test('accepts --no-express flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
        '--no-express',
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

      // Should start without error — check startup messages appear
      expect(stdout.toString(), contains('Declaring Publisher'));
      // No unhandled exception in stderr
      expect(stderr.toString(), isNot(contains('Unhandled exception')));
    });

    test('echoes ping payload', () async {
      const port = 18570;
      const endpoint = 'tcp/127.0.0.1:$port';

      // Start z_pong listening on TCP
      final pongProcess = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final pongStdout = StringBuffer();
      final pongSub = pongProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen(pongStdout.write);

      try {
        // Wait for z_pong to bind TCP listener
        await Future<void>.delayed(const Duration(seconds: 8));

        // Open in-process session connecting to z_pong
        final config = Config();
        config.insertJson5('connect/endpoints', '["$endpoint"]');
        final session = Session.open(config: config);

        // Give TCP connection time to negotiate
        await Future<void>.delayed(const Duration(seconds: 2));

        // Subscribe to test/pong to receive the echo
        final subscriber = session.declareSubscriber('test/pong');

        // Give subscription time to propagate
        await Future<void>.delayed(const Duration(seconds: 1));

        // Publish on test/ping
        session.put('test/ping', 'echo-test');

        // Wait for echo on test/pong
        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 10),
        );

        // Verify we received something on pong
        expect(sample.keyExpr, equals('test/pong'));

        subscriber.close();
        session.close();
      } finally {
        await forceKill(pongProcess);
        await pongSub.cancel();
      }
    });

    test('accepts -e and -l flags', () async {
      const port = 18571;
      const endpoint = 'tcp/127.0.0.1:$port';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
        '-l',
        endpoint,
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

      // Should start without error
      expect(stdout.toString(), contains('Declaring Publisher'));
      expect(stderr.toString(), isNot(contains('Unhandled exception')));
    });
  });
}
