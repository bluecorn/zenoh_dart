import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_sub CLI', () {
    test('runs and prints subscriber declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_sub.dart',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Let it run for 3 seconds, then kill it
      await waitForReady(stdout);
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
      addTearDown(() => forceKill(subProcess));

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
        // Wait for the subscriber to bind rather than assuming 8s covers
        // startup + build-hook overhead.
        await waitForReady(subStdout);

        // Use in-process session to put (avoids subprocess startup race)
        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]');
        final session = await Session.open(config: config);

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

    test('with empty key expression fails', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_sub.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });

    test(
      'prints the attachment alongside the received sample',
      () async {
        // canon appends ` (<attachment>)` when the sample carries one. Without
        // it the canonical `z_pub -a` -> `z_sub` demo pair loses its point: the
        // attachment is sent and never shown.
        const endpoint = 'tcp/127.0.0.1:18563';
        const keyExpr = 'test/sub/attach';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_sub.dart',
          '-k',
          keyExpr,
          '-l',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final out = StringBuffer();
        final sub = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(out.write);
        addTearDown(sub.cancel);

        await waitForReady(out);
        await Future<void>.delayed(const Duration(seconds: 2));

        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        session.put(
          keyExpr,
          'body-text',
          attachment: ZBytes.fromString('attached-metadata'),
        );

        await waitForOutput(out, 'Received PUT');
        expect(out.toString(), contains("'body-text') (attached-metadata)"));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
