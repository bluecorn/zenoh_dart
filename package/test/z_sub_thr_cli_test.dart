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

/// Starts z_pub_thr listening on [endpoint] and waits for it to bind.
/// Returns the running pub_thr process.
Future<Process> startPubThr(
  String endpoint,
  String packageRoot,
  int payloadSize,
) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_pub_thr.dart',
    '$payloadSize',
    '-e',
    endpoint,
  ], workingDirectory: packageRoot);

  // Wait for z_pub_thr to connect and start publishing
  await Future<void>.delayed(const Duration(seconds: 8));
  return process;
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_sub_thr CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_sub_thr.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_sub_thr.dart must exist',
      );
    });

    test('reports throughput with z_pub_thr', () async {
      const endpoint = 'tcp/127.0.0.1:18610';

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
      final pubThrProcess = await startPubThr(endpoint, packageRoot, 8);

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
        // Ensure sub is killed too in case it didn't exit
        try {
          subThrProcess.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 60)));

    test('prints summary on exit', () async {
      const endpoint = 'tcp/127.0.0.1:18610';

      // Start z_sub_thr first (it listens)
      final subThrProcess = await Process.start(_dartExe, [
        'run',
        'example/z_sub_thr.dart',
        '-s',
        '2',
        '-n',
        '1000',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      // Wait for listener to bind
      await Future<void>.delayed(const Duration(seconds: 8));

      // Start z_pub_thr connecting to the listener
      final pubThrProcess = await startPubThr(endpoint, packageRoot, 8);

      try {
        // Wait for z_sub_thr to complete
        final exitCode = await subThrProcess.exitCode.timeout(
          const Duration(seconds: 45),
        );

        final stdout = await subThrProcess.stdout
            .transform(const SystemEncoding().decoder)
            .join();

        expect(stdout, contains('messages over'));
        expect(exitCode, equals(0));
      } finally {
        await forceKill(pubThrProcess);
        try {
          subThrProcess.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 60)));

    test('exits after configured rounds', () async {
      const endpoint = 'tcp/127.0.0.1:18611';

      // Start z_sub_thr first (it listens)
      final subThrProcess = await Process.start(_dartExe, [
        'run',
        'example/z_sub_thr.dart',
        '-s',
        '1',
        '-n',
        '100',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      // Wait for listener to bind
      await Future<void>.delayed(const Duration(seconds: 8));

      // Start z_pub_thr connecting to the listener
      final pubThrProcess = await startPubThr(endpoint, packageRoot, 8);

      try {
        // z_sub_thr should exit on its own after completing rounds
        final exitCode = await subThrProcess.exitCode.timeout(
          const Duration(seconds: 45),
        );

        expect(exitCode, equals(0));
      } finally {
        await forceKill(pubThrProcess);
        try {
          subThrProcess.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}
