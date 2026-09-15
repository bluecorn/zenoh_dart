import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The direct Dart executable path (not via fvm, to avoid zombie processes).
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

  group(
    'z_ping_shm CLI',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('requires payload size argument', () async {
        final result = await runToCompletion(_dartExe, [
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
            final result = await runToCompletion(_dartExe, [
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
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('accepts --no-express flag', () async {
        const port = 18581;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pongProcess = await startPong(endpoint, packageRoot);

        try {
          final result = await runToCompletion(_dartExe, [
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
      }, timeout: const Timeout(Duration(seconds: 60)));

      test(
        'prints SHM-related startup messages',
        () async {
          const port = 18582;
          const endpoint = 'tcp/127.0.0.1:$port';

          final pongProcess = await startPong(endpoint, packageRoot);

          try {
            final result = await runToCompletion(_dartExe, [
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
        timeout: const Timeout(Duration(seconds: 60)),
      );

      // The refusal arm, which nothing else in this file executes. A payload
      // size of 0 is the one input canon answers immediately on either
      // allocator (a layout error), so it reaches the failure branch without
      // ever parking. ⚠️ Green before the move as well -- see the same cell
      // in `z_pub_shm_thr_cli_test.dart` for why that is the honest shape.
      test('reports a refused allocation and exits', () async {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_ping_shm.dart',
          '0',
          '-n',
          '1',
          '--warmup',
          '0',
        ], workingDirectory: packageRoot);

        expect(
          result.exitCode,
          isNot(0),
          reason:
              'a refused allocation must not look like a healthy run: '
              '${result.stdout}',
        );
        expect(
          result.stdout as String,
          contains('Unexpected failure during SHM buffer allocation'),
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('the example awaits the async allocator', () {
        // Per-file anchor; the population-wide census lives in
        // `z_pub_shm_cli_test.dart`.
        final source = File(
          '$packageRoot/example/z_ping_shm.dart',
        ).readAsStringSync();
        expect(source, contains('await provider.allocGcDefragAsync('));
        expect(source, contains('allocates once at startup'));
      });
    },
  );
}
