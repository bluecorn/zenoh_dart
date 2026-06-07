import 'dart:io';

import 'package:test/test.dart';

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

// CLI tests for z_querier.dart example
void main() {
  final packageRoot = Directory.current.path;

  group('z_querier CLI', () {
    Future<String> runZQuerierAndCapture(
      List<String> args, {
      int waitSeconds = 3,
    }) async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_querier.dart',
        ...args,
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(Duration(seconds: waitSeconds));
      await forceKill(process);
      await subscription.cancel();

      return stdout.toString();
    }

    test('runs with default arguments and prints declaring message', () async {
      final output = await runZQuerierAndCapture(['--timeout', '2000']);
      expect(output, contains('Declaring Querier'));
      expect(output, contains('demo/example/**'));
    });

    test('accepts --selector flag', () async {
      final output = await runZQuerierAndCapture([
        '--selector',
        'demo/custom/**',
        '--timeout',
        '2000',
      ]);
      expect(output, contains('demo/custom/**'));
    });

    test('accepts short flags', () async {
      final output = await runZQuerierAndCapture([
        '-s',
        'demo/short/**',
        '-o',
        '2000',
      ]);
      expect(output, contains('demo/short/**'));
    });

    test('accepts --target flag', () async {
      final output = await runZQuerierAndCapture(['-t', 'ALL', '-o', '2000']);
      expect(output, contains('Querying'));
    });
  });
}
