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

  group('z_sub CLI', () {
    test('runs and prints subscriber declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub.dart',
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

    test('receives a sample from in-process put', () async {
      // Use explicit TCP to ensure the subprocess and in-process session
      // can communicate reliably.
      const port = 18551;
      const endpoint = 'tcp/127.0.0.1:$port';

      // Start z_sub listening on a specific key with TCP listener
      final subProcess = await Process.start(_dartExe, [
        'run',
        'example/z_sub.dart',
        '-k',
        'demo/cli/test',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final subStdout = StringBuffer();
      final completer = Completer<void>();
      final subSubscription = subProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen((data) {
            subStdout.write(data);
            if (!completer.isCompleted &&
                subStdout.toString().contains('Received PUT')) {
              completer.complete();
            }
          });

      try {
        // Wait for subscriber session to bind TCP listener
        // (build hooks add ~2s startup overhead)
        await Future<void>.delayed(const Duration(seconds: 8));

        // Use in-process session to put (avoids subprocess startup race)
        final config = Config();
        config.insertJson5('connect/endpoints', '["$endpoint"]');
        final session = Session.open(config: config);

        // Give the TCP connection time to negotiate
        await Future<void>.delayed(const Duration(seconds: 2));

        session.put('demo/cli/test', 'from-put');

        // Wait for the sample to arrive (with timeout)
        await completer.future.timeout(const Duration(seconds: 10));

        final output = subStdout.toString();
        expect(output, contains('Received PUT'));
        expect(output, contains('from-put'));

        session.close();
      } finally {
        await forceKill(subProcess);
        await subSubscription.cancel();
      }
    });

    test('accepts --key flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub.dart',
        '--key',
        'demo/custom/**',
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

    test('with empty key expression fails', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_sub.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 30));

      expect(result.exitCode, isNot(0));
    });
  });
}
