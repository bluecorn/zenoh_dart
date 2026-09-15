import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_queryable CLI', () {
    test('runs and prints declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_queryable.dart',
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
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForReady(stdout);
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
      addTearDown(() => forceKill(qProcess));

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
        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]');
        final session = await Session.open(config: config);

        // Give the TCP connection time to negotiate
        await Future<void>.delayed(const Duration(seconds: 2));

        // Send a get query carrying a payload: canon's handler branches on
        // `z_query_payload` and prints `... with value '<payload>'`
        // (z_queryable.c:41-53). Without a payload that branch never runs, so
        // the query-payload display would go untested.
        final replies = await session
            .get(
              'demo/cli/q',
              payload: ZBytes.fromString('query-side-value'),
              timeout: const Duration(seconds: 5),
            )
            .toList();

        expect(replies, isNotEmpty);
        // Both lines can only have been printed by the handler that produced
        // the reply just received.
        expect(
          qStdout.toString(),
          contains(
            "Received Query 'demo/cli/q?' with value 'query-side-value'",
          ),
        );
        expect(
          qStdout.toString(),
          contains(">> [Queryable ] Responding ('demo/cli/q':"),
        );
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
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
