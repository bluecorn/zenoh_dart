import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

/// Starts z_pong listening on [endpoint] and waits for it to bind.
/// Returns the running pong process.
Future<Process> startPong(String endpoint, String packageRoot) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_pong.dart',
    '-l',
    endpoint,
  ], workingDirectory: packageRoot);
  addTearDown(() => forceKill(process));

  // Wait for the listener to actually bind rather than assuming 8s is
  // enough: z_pong prints its readiness banner only after Session.open has
  // bound the endpoint.
  final out = StringBuffer();
  process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
  await waitForReady(out);
  return process;
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_ping CLI', () {
    test('requires payload size argument', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_ping.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });

    test(
      'prints latency results with z_pong running',
      () async {
        const port = 18572;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pongProcess = await startPong(endpoint, packageRoot);

        try {
          final result = await runToCompletion(_dartExe, [
            'run',
            'example/z_ping.dart',
            '8',
            '--samples',
            '3',
            '--warmup',
            '0',
            '-e',
            endpoint,
          ], workingDirectory: packageRoot);

          expect(result.exitCode, equals(0));
          // canon prints `%d bytes: seq=%d rtt=%luµs, lat=%luµs`
          // (z_ping.c:106). A `contains('rtt=')` check stops one character
          // short of the two things this round changed: the `us` -> `µs`
          // spelling and the presence of the `lat=` half.
          expect(
            result.stdout as String,
            matches(RegExp(r'8 bytes: seq=0 rtt=\d+µs, lat=\d+µs')),
          );
        } finally {
          await forceKill(pongProcess);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('accepts -n/--samples flag', () async {
      const port = 18573;
      const endpoint = 'tcp/127.0.0.1:$port';

      final pongProcess = await startPong(endpoint, packageRoot);

      try {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_ping.dart',
          '8',
          '-n',
          '2',
          '--warmup',
          '0',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);

        expect(result.exitCode, equals(0));
        final lines = (result.stdout as String)
            .split('\n')
            .where((l) => l.contains('rtt='))
            .toList();
        expect(lines.length, equals(2));
      } finally {
        await forceKill(pongProcess);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('accepts --no-express flag', () async {
      const port = 18574;
      const endpoint = 'tcp/127.0.0.1:$port';

      final pongProcess = await startPong(endpoint, packageRoot);

      try {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_ping.dart',
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
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('accepts -w/--warmup flag', () async {
      const port = 18575;
      const endpoint = 'tcp/127.0.0.1:$port';

      final pongProcess = await startPong(endpoint, packageRoot);

      try {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_ping.dart',
          '8',
          '-n',
          '1',
          '-w',
          '500',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);

        expect(result.exitCode, equals(0));
        final output = result.stdout as String;
        expect(output, contains('Warming up'));
        expect(output, contains('rtt='));
      } finally {
        await forceKill(pongProcess);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
