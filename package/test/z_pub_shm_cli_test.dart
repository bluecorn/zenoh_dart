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

  group('z_pub_shm CLI', () {
    test(
      'runs and prints SHM provider creation and publisher declaration',
      () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
        ], workingDirectory: packageRoot);

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        // Let it run for 3 seconds, then kill it
        await Future<void>.delayed(const Duration(seconds: 3));
        await forceKill(process);
        await subscription.cancel();

        final output = stdout.toString();
        expect(output, contains('Opening session...'));
        expect(output, contains('Creating POSIX SHM Provider...'));
        expect(output, contains('Declaring Publisher'));
        expect(output, contains('Putting Data'));
      },
    );

    test('accepts -k and -p flags', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm.dart',
        '-k',
        'demo/shm/test',
        '-p',
        'SHM data',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('demo/shm/test'));
      expect(output, contains('SHM data'));
    });

    test('accepts --add-matching-listener flag without crashing', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm.dart',
        '--add-matching-listener',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await stdoutSub.cancel();
      await stderrSub.cancel();

      final output = stdout.toString();
      expect(output, contains('Opening session...'));
      expect(output, contains('Putting Data'));
    });

    test('accepts -e endpoint flag', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub_shm.dart',
        '-e',
        'tcp/127.0.0.1:7447',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Give it time to start (may fail to connect but should parse the flag)
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      // At minimum, it parsed the flag and attempted to open a session
      expect(output, contains('Opening session...'));
    });
  });
}
