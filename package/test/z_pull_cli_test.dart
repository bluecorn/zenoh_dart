// z_pull CLI tests
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

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

  group('z_pull CLI', () {
    test('runs and prints subscriber declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pull.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Let it run for 3 seconds, then kill it
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('Declaring Subscriber'));
      expect(stdout.toString(), contains('demo/example/**'));
    });

    test('accepts --key and --size flags', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pull.dart',
        '--key',
        'demo/custom/**',
        '--size',
        '5',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/**'));
      expect(stdout.toString(), contains('capacity 5'));
    });

    test('with empty key expression fails', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_pull.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 30));

      expect(result.exitCode, isNot(0));
    });

    test(
      'receives sample from in-process put',
      () async {
        const port = 18571;
        const endpoint = 'tcp/127.0.0.1:$port';

        // Start z_pull listening on a specific key with TCP listener
        final pullProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pull.dart',
          '-k',
          'demo/cli/pull',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        final pullStdout = StringBuffer();
        final declaringCompleter = Completer<void>();
        final receivedCompleter = Completer<void>();
        final pullSubscription = pullProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen((data) {
              pullStdout.write(data);
              if (!declaringCompleter.isCompleted &&
                  pullStdout.toString().contains('Press ENTER')) {
                declaringCompleter.complete();
              }
              if (!receivedCompleter.isCompleted &&
                  pullStdout.toString().contains('Received PUT')) {
                receivedCompleter.complete();
              }
            });

        try {
          // Wait for subscriber to be ready
          await declaringCompleter.future.timeout(const Duration(seconds: 15));
          // Extra time for TCP listener to bind
          await Future<void>.delayed(const Duration(seconds: 3));

          // Open in-process session connecting to the pull subscriber
          final config = Config();
          config.insertJson5('connect/endpoints', '["$endpoint"]');
          final session = Session.open(config: config);

          // Give TCP connection time to negotiate
          await Future<void>.delayed(const Duration(seconds: 2));

          // Publish a sample
          session.put('demo/cli/pull', 'test payload');

          // Wait a bit for the sample to arrive in the ring buffer
          await Future<void>.delayed(const Duration(seconds: 1));

          // Send newline to stdin to trigger pull
          pullProcess.stdin.writeln('');
          await pullProcess.stdin.flush();

          // Wait for sample to be received
          await receivedCompleter.future.timeout(const Duration(seconds: 10));

          final output = pullStdout.toString();
          expect(output, contains('Received PUT'));
          expect(output, contains('test payload'));

          session.close();
        } finally {
          // Send 'q' to quit gracefully, then force kill
          pullProcess.stdin.writeln('q');
          await pullProcess.stdin.flush();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await forceKill(pullProcess);
          await pullSubscription.cancel();
        }
      },
      timeout: Timeout(Duration(seconds: 40)),
    );
  });
}
