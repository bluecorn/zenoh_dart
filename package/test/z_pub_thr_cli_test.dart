import 'dart:async';
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

void main() {
  final packageRoot = Directory.current.path;

  group('z_pub_thr CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_pub_thr.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_pub_thr.dart must exist',
      );
    });

    test('requires payload size argument', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_pub_thr.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
      expect(
        result.stderr as String,
        contains('<PAYLOAD_SIZE> argument is required'),
      );
    });

    test('accepts --priority flag', () async {
      const endpoint = 'tcp/127.0.0.1:18601';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_thr.dart',
        '--priority',
        '1',
        '64',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      // Let it run for 2 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 2));
      await forceKill(process);

      // Verify it started successfully by checking stdout
      expect(stdoutBuf.toString(), contains('Press CTRL-C to quit'));
    }, timeout: Timeout(Duration(seconds: 60)));

    test('accepts --express flag', () async {
      const endpoint = 'tcp/127.0.0.1:18602';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_thr.dart',
        '--express',
        '64',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      // Let it run for 2 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 2));
      await forceKill(process);

      // Verify it started successfully by checking stdout
      expect(stdoutBuf.toString(), contains('Press CTRL-C to quit'));
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}
