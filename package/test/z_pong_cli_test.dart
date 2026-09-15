import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart'; // z_pong CLI tests

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_pong CLI', () {
    test('runs and prints startup messages', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForReady(stdout);
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring Publisher'));
      expect(output, contains('Declaring Background Subscriber'));
    });

    test('runs with --no-express without error', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
        '--no-express',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write);

      await waitForReady(stdout);
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
      addTearDown(() => forceKill(pongProcess));

      final pongStdout = StringBuffer();
      final pongSub = pongProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen(pongStdout.write);

      try {
        // Wait for z_pong to bind: Session.open binds the listen endpoint, so
        // the readiness banner implies the listener is up.
        await waitForReady(pongStdout);

        // Open in-process session connecting to z_pong
        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]');
        final session = await Session.open(config: config);

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
        // ...and that it is the *same* something. z_pong exists to echo the
        // ping payload back; asserting only the key means a pong that
        // corrupted or substituted the content stayed green. Echo content
        // fidelity is untested at every other level too -- z_ping asserts only
        // round-trip times.
        expect(sample.payload, equals('echo-test'));

        subscriber.close();
        session.close();
      } finally {
        await forceKill(pongProcess);
        await pongSub.cancel();
      }
    });

    // The echo is the retained handle itself, which is what canon's
    // `z_pong.c` does: `z_bytes_clone` on the received payload, then
    // `z_publisher_put` of that clone. Source-anchored deliberately -- a heap
    // copy and a refcount clone put identical bytes on the wire, so the echo
    // cell above stays green either way. What separates them is what an
    // SHM-backed payload survives, and that is not observable from a CLI's
    // stdout (it is measured in `shm_received_backing_test.dart`).
    test('echoes the retained payload handle, not a reconstructed copy', () {
      final source = File('example/z_pong.dart').readAsStringSync();

      // Retention is opted into at the declaration...
      expect(source, contains('retainPayload: true'));
      // ...and the handle that arrived on the sample is what gets published.
      expect(source, contains('sample.payloadZBytes'));
      // ...with no reconstruction left anywhere on this path.
      expect(source, isNot(contains('ZBytes.fromUint8List')));

      // The gap marker is GONE rather than reworded. It recorded that no
      // `Sample` -> `ZBytes` handle existed; that gap is closed, and a marker
      // rewritten to describe a closed gap is worse than no marker at all.
      expect(source, isNot(contains('API-surface')));
      expect(source, isNot(contains('zero-copy handle exists')));
    });

    test('runs with -e and -l without error', () async {
      const port = 18571;
      const endpoint = 'tcp/127.0.0.1:$port';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pong.dart',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write);

      await waitForReady(stdout);
      await forceKill(process);
      await stdoutSub.cancel();
      await stderrSub.cancel();

      // Should start without error
      expect(stdout.toString(), contains('Declaring Publisher'));
      expect(stderr.toString(), isNot(contains('Unhandled exception')));
    });
  });
}
