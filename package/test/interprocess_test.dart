import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The Dart executable running this suite.
///
/// Spawning `fvm` hardcodes a tool that need not be on PATH, and resolves a
/// *different* Dart than the one running the test.
/// `Platform.resolvedExecutable` is the SDK we are already inside.
final String _dartExe = Platform.resolvedExecutable;

/// Starts the interprocess_connect helper in the given mode.
///
/// Returns the [Process] after the ready signal has been received.
Future<Process> _startHelper({
  required String mode,
  required String port,
  int duration = 5,
  Map<String, String>? environment,
}) async {
  final helper = await Process.start(
    _dartExe,
    [
      'run',
      'test/helpers/interprocess_connect.dart',
      mode,
      '--port',
      port,
      '--duration',
      '$duration',
    ],
    workingDirectory: '.',
    environment: environment,
  );
  addTearDown(() => forceKill(helper));

  final readySignal = mode == '--listen' ? 'LISTENING' : 'CONNECTED';
  final stdoutLines = helper.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());
  await stdoutLines
      .firstWhere((line) => line.contains(readySignal))
      .timeout(const Duration(seconds: 15));

  return helper;
}

void main() {
  group('Inter-process connection', () {
    test('two Dart processes connect via TCP without crashing', () async {
      const port = '19001';

      final listener = await _startHelper(
        mode: '--listen',
        port: port,
        duration: 8,
      );
      final connector = await _startHelper(
        mode: '--connect',
        port: port,
        duration: 3,
      );

      final connectorExit = await connector.exitCode.timeout(
        const Duration(seconds: 15),
      );
      expect(
        connectorExit,
        equals(0),
        reason: 'Connector process should exit cleanly',
      );

      final listenerExit = await listener.exitCode.timeout(
        const Duration(seconds: 20),
      );
      expect(
        listenerExit,
        equals(0),
        reason: 'Listener process should exit cleanly',
      );
    });

    test('connection works without LD_LIBRARY_PATH or LD_PRELOAD', () async {
      const port = '19003';

      final env = Map<String, String>.from(Platform.environment)
        ..remove('LD_LIBRARY_PATH')
        ..remove('LD_PRELOAD');

      final listener = await _startHelper(
        mode: '--listen',
        port: port,
        duration: 8,
        environment: env,
      );
      final connector = await _startHelper(
        mode: '--connect',
        port: port,
        duration: 3,
        environment: env,
      );

      final connectorExit = await connector.exitCode.timeout(
        const Duration(seconds: 15),
      );
      final listenerExit = await listener.exitCode.timeout(
        const Duration(seconds: 20),
      );

      expect(connectorExit, equals(0));
      expect(listenerExit, equals(0));
    });

    test(
      'standalone helper process exits cleanly without connection',
      () async {
        const port = '19004';

        final listener = await _startHelper(
          mode: '--listen',
          port: port,
          duration: 2,
        );

        // No connector — just verify the listener exits on its own
        final listenerExit = await listener.exitCode.timeout(
          const Duration(seconds: 15),
        );
        expect(
          listenerExit,
          equals(0),
          reason: 'Standalone listener should exit cleanly',
        );
      },
    );
  });

  group('Inter-process pub/sub', () {
    /// Starts the pubsub helper and returns process + collected stdout lines.
    ///
    /// Waits for the ready signal before returning.
    Future<({Process process, List<String> output})> startPubsubHelper({
      required String mode,
      required String port,
      required String key,
      String payload = 'hello',
      int count = 1,
    }) async {
      final process = await Process.start(_dartExe, [
        'run',
        'test/helpers/interprocess_pubsub.dart',
        '--mode',
        mode,
        '--port',
        port,
        '--key',
        key,
        '--payload',
        payload,
        '--count',
        '$count',
      ], workingDirectory: '.');
      addTearDown(() => forceKill(process));

      final output = <String>[];
      final readyCompleter = Completer<void>();
      final readySignal = mode == 'sub' ? 'SUB_READY' : 'PUB_READY';

      process.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
            output.add(line);
            if (line.contains(readySignal) && !readyCompleter.isCompleted) {
              readyCompleter.complete();
            }
          });

      // Also forward stderr for debugging
      process.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
            // ignore stderr but don't let it block
          });

      await readyCompleter.future.timeout(const Duration(seconds: 15));
      return (process: process, output: output);
    }

    test(
      'publisher in one process delivers data to subscriber in another',
      () async {
        const port = '19010';
        const key = 'interprocess/test/pubsub';
        const payload = 'hello-interprocess';

        // Start subscriber (listener)
        final sub = await startPubsubHelper(
          mode: 'sub',
          port: port,
          key: key,
        );

        // Start publisher (connector)
        final pub = await startPubsubHelper(
          mode: 'pub',
          port: port,
          key: key,
          payload: payload,
        );

        final pubExit = await pub.process.exitCode.timeout(
          const Duration(seconds: 20),
        );
        expect(pubExit, equals(0), reason: 'Publisher should exit cleanly');

        final subExit = await sub.process.exitCode.timeout(
          const Duration(seconds: 20),
        );
        expect(subExit, equals(0), reason: 'Subscriber should exit cleanly');

        // Verify subscriber received the payload
        expect(
          sub.output.any((line) => line == 'RECEIVED:$payload'),
          isTrue,
          reason:
              'Subscriber should have received "$payload", got: ${sub.output}',
        );
      },
    );

    test('payload bytes are preserved across processes', () async {
      const port = '19011';
      const key = 'interprocess/test/bytes';
      const payload = 'deadbeef';

      final sub = await startPubsubHelper(
        mode: 'sub',
        port: port,
        key: key,
      );

      final pub = await startPubsubHelper(
        mode: 'pub',
        port: port,
        key: key,
        payload: payload,
      );

      final pubExit = await pub.process.exitCode.timeout(
        const Duration(seconds: 20),
      );
      expect(pubExit, equals(0));

      final subExit = await sub.process.exitCode.timeout(
        const Duration(seconds: 20),
      );
      expect(subExit, equals(0));

      // Verify subscriber received the exact payload string
      expect(
        sub.output.any((line) => line == 'RECEIVED:$payload'),
        isTrue,
        reason:
            'Subscriber should have received "$payload", got: ${sub.output}',
      );

      // Verify the BYTES line carries the exact bytes, not merely that a BYTES
      // line exists. The helper hex-dumps `sample.payloadBytes`, so comparing
      // the value is what makes this test about byte fidelity across the
      // process boundary; asserting only the prefix leaves the purpose-built
      // instrument unread and passes on any corruption.
      final expectedHex = utf8
          .encode(payload)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        sub.output,
        contains('BYTES:$expectedHex'),
        reason:
            'Subscriber should have printed the exact payload bytes, '
            'got: ${sub.output}',
      );
    });

    test(
      'subscriber receives multiple messages from remote publisher',
      () async {
        const port = '19012';
        const key = 'interprocess/test/multi';
        const payload = 'msg';
        const count = 3;

        final sub = await startPubsubHelper(
          mode: 'sub',
          port: port,
          key: key,
          count: count,
        );

        final pub = await startPubsubHelper(
          mode: 'pub',
          port: port,
          key: key,
          payload: payload,
          count: count,
        );

        final pubExit = await pub.process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        expect(pubExit, equals(0), reason: 'Publisher should exit cleanly');

        final subExit = await sub.process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        expect(subExit, equals(0), reason: 'Subscriber should exit cleanly');

        // Verify all 3 messages received
        for (var i = 0; i < count; i++) {
          expect(
            sub.output.any((line) => line == 'RECEIVED:$payload-$i'),
            isTrue,
            reason:
                'Subscriber should have received "$payload-$i", '
                'got: ${sub.output}',
          );
        }
      },
    );
  });
}
