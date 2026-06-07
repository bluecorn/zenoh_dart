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

  group('z_queryable CLI', () {
    test('runs and prints declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable.dart',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Let it run for 3 seconds, then kill it
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('Declaring Queryable'));
      expect(stdout.toString(), contains('demo/example/zenoh-dart-queryable'));
    });

    test('accepts --key flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable.dart',
        '--key',
        'demo/custom/q',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/q'));
    });

    test('responds to in-process get', () async {
      const port = 18553;
      const endpoint = 'tcp/127.0.0.1:$port';

      // Start z_queryable listening on a specific key with TCP listener
      final qProcess = await Process.start(_dartExe, [
        'run',
        'example/z_queryable.dart',
        '-k',
        'demo/cli/q',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final qStdout = StringBuffer();
      final completer = Completer<void>();
      final qSubscription = qProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen((data) {
            qStdout.write(data);
            if (!completer.isCompleted &&
                qStdout.toString().contains('Press CTRL-C')) {
              completer.complete();
            }
          });

      try {
        // Wait for queryable to start and bind TCP listener
        await completer.future.timeout(const Duration(seconds: 15));
        // Extra time for TCP listener to actually bind
        await Future<void>.delayed(const Duration(seconds: 3));

        // Open in-process session connecting to the queryable
        final config = Config();
        config.insertJson5('connect/endpoints', '["$endpoint"]');
        final session = Session.open(config: config);

        // Give the TCP connection time to negotiate
        await Future<void>.delayed(const Duration(seconds: 2));

        // Send a get query
        final replies = <Reply>[];
        await for (final reply in session.get(
          'demo/cli/q',
          timeout: const Duration(seconds: 5),
        )) {
          replies.add(reply);
        }

        expect(replies, isNotEmpty);
        expect(replies.first.isOk, isTrue);
        expect(replies.first.ok.payload, contains('Queryable from Dart'));

        // Verify queryable printed the received query
        final output = qStdout.toString();
        expect(output, contains('Received Query'));

        session.close();
      } finally {
        await forceKill(qProcess);
        await qSubscription.cancel();
      }
    }, timeout: Timeout(Duration(seconds: 40)));
  });
}
