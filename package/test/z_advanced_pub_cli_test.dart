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

  group('z_advanced_pub CLI', () {
    test('starts and prints declaration message', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_pub.dart',
        '-l',
        'tcp/127.0.0.1:18720',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 5));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring AdvancedPublisher on'));
      expect(output, contains('Press CTRL-C'));
    });

    test('accepts -k and -p flags', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_pub.dart',
        '-k',
        'demo/test/adv-pub',
        '-p',
        'Custom payload',
        '-l',
        'tcp/127.0.0.1:18721',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 5));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('demo/test/adv-pub'));
    });

    test('accepts -i flag for cache size', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_pub.dart',
        '-i',
        '10',
        '-l',
        'tcp/127.0.0.1:18724',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 5));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring AdvancedPublisher on'));
    });
  });
}
