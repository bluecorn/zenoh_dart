import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

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
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_pub_thr.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
      // canon prints this on stdout via printf, not stderr.
      expect(
        result.stdout as String,
        contains('<PAYLOAD_SIZE> argument is required'),
      );
    });

    test(
      'runs with --priority without error',
      () async {
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
        addTearDown(() => forceKill(process));

        final stdoutBuf = StringBuffer();
        final stderrBuf = StringBuffer();
        process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdoutBuf.write);
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderrBuf.write);

        // Let it run for 2 seconds then kill
        await waitForReady(stdoutBuf);
        await forceKill(process);

        // Verify it started successfully by checking stdout
        expect(stdoutBuf.toString(), contains('Press CTRL-C to quit'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'runs with --express without error',
      () async {
        const endpoint = 'tcp/127.0.0.1:18602';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_thr.dart',
          '--express',
          '64',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdoutBuf = StringBuffer();
        final stderrBuf = StringBuffer();
        process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdoutBuf.write);
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderrBuf.write);

        // Let it run for 2 seconds then kill
        await waitForReady(stdoutBuf);
        await forceKill(process);

        // Verify it started successfully by checking stdout
        expect(stdoutBuf.toString(), contains('Press CTRL-C to quit'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
