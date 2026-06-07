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

  group('throughput integration', () {
    setUpAll(() {
      final subThrScript = File('$packageRoot/example/z_sub_thr.dart');
      final pubThrScript = File('$packageRoot/example/z_pub_thr.dart');
      expect(
        subThrScript.existsSync(),
        isTrue,
        reason: 'example/z_sub_thr.dart must exist',
      );
      expect(
        pubThrScript.existsSync(),
        isTrue,
        reason: 'example/z_pub_thr.dart must exist',
      );
    });

    test(
      'z_pub_thr starts and publishes (verified via z_sub_thr)',
      () async {
        const endpoint = 'tcp/127.0.0.1:18630';

        // Start z_sub_thr first (it listens)
        final subThrProcess = await Process.start(_dartExe, [
          'run',
          'example/z_sub_thr.dart',
          '-s',
          '1',
          '-n',
          '1000',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        // Wait for listener to bind
        await Future<void>.delayed(const Duration(seconds: 8));

        // Start z_pub_thr connecting to the listener
        final pubThrProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pub_thr.dart',
          '64',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);

        try {
          // Wait for z_sub_thr to complete
          final exitCode = await subThrProcess.exitCode.timeout(
            const Duration(seconds: 45),
          );

          final stdout = await subThrProcess.stdout
              .transform(const SystemEncoding().decoder)
              .join();

          expect(stdout, contains('msg/s'));
          expect(exitCode, equals(0));
        } finally {
          await forceKill(pubThrProcess);
          try {
            subThrProcess.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      },
      timeout: Timeout(Duration(seconds: 60)),
    );

    test(
      'Dart pub/sub throughput pair produces measurable results',
      () async {
        const endpoint = 'tcp/127.0.0.1:18631';

        // Start z_sub_thr first (it listens)
        final subThrProcess = await Process.start(_dartExe, [
          'run',
          'example/z_sub_thr.dart',
          '-s',
          '1',
          '-n',
          '500',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        // Wait for listener to bind
        await Future<void>.delayed(const Duration(seconds: 8));

        // Start z_pub_thr connecting to the listener
        final pubThrProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pub_thr.dart',
          '8',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);

        try {
          // Wait for z_sub_thr to complete
          final exitCode = await subThrProcess.exitCode.timeout(
            const Duration(seconds: 45),
          );

          final stdout = await subThrProcess.stdout
              .transform(const SystemEncoding().decoder)
              .join();

          // Parse throughput value and verify it's > 0
          final throughputMatch = RegExp(
            r'([\d,]+(?:\.\d+)?)\s+msg/s',
          ).firstMatch(stdout);
          expect(
            throughputMatch,
            isNotNull,
            reason: 'Expected throughput output containing msg/s',
          );

          final throughputStr = throughputMatch!.group(1)!.replaceAll(',', '');
          final throughput = double.parse(throughputStr);
          expect(
            throughput,
            greaterThan(0),
            reason: 'Throughput must be > 0 msg/s',
          );

          expect(exitCode, equals(0));
        } finally {
          await forceKill(pubThrProcess);
          try {
            subThrProcess.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      },
      timeout: Timeout(Duration(seconds: 60)),
    );
  });
}
