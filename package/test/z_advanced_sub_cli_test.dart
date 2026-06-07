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

  group('z_advanced_sub CLI', () {
    test('starts and prints declaration message with default key', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_sub.dart',
        '-l',
        'tcp/127.0.0.1:18722',
      ], workingDirectory: packageRoot);

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 5));
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring AdvancedSubscriber on'));
      expect(output, contains('demo/example/**'));
      expect(output, contains('Press CTRL-C'));
    });

    test('pub-to-sub e2e with history', () async {
      // Start advanced publisher first (caching samples)
      final pubProcess = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_pub.dart',
        '-k',
        'demo/test/adv',
        '-i',
        '5',
        '-l',
        'tcp/127.0.0.1:18723',
      ], workingDirectory: packageRoot);

      // Let publisher run and cache a few samples
      await Future<void>.delayed(const Duration(seconds: 5));

      // Start subscriber connecting to publisher
      final subProcess = await Process.start(_dartExe, [
        'run',
        'example/z_advanced_sub.dart',
        '-k',
        'demo/test/**',
        '-e',
        'tcp/127.0.0.1:18723',
      ], workingDirectory: packageRoot);

      final subStdout = StringBuffer();
      final subSubscription = subProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen(subStdout.write);

      // Let subscriber receive samples
      await Future<void>.delayed(const Duration(seconds: 8));

      await forceKill(subProcess);
      await forceKill(pubProcess);
      await subSubscription.cancel();

      final output = subStdout.toString();
      expect(output, contains('Received PUT'));
    });
  });
}
