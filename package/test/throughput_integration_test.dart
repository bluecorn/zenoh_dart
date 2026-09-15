import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

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
        addTearDown(() => forceKill(subThrProcess));

        // Capture rather than re-read later: waiting on the output means
        // listening, and stdout is a single-subscription stream.
        final subThrStdout = StringBuffer();
        subThrProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(subThrStdout.write);
        await waitForReady(subThrStdout);

        // Start z_pub_thr connecting to the listener
        final pubThrProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pub_thr.dart',
          '8',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(pubThrProcess));

        try {
          // Wait for z_sub_thr to complete
          final exitCode = await subThrProcess.exitCode.timeout(
            const Duration(seconds: 45),
          );

          final stdout = subThrStdout.toString();

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
          } on Object catch (_) {}
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
