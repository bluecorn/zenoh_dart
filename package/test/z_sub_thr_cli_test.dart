import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

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
  addTearDown(() => forceKill(process));

  // Wait for z_pub_thr to be publishing rather than assuming 8s: its
  // readiness banner is printed once the publisher is declared.
  final out = StringBuffer();
  process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
  await waitForReady(out);
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

    test(
      'reports throughput with z_pub_thr',
      () async {
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
        addTearDown(() => forceKill(subThrProcess));

        // Capture rather than re-read later: waiting on the output means
        // listening, and stdout is a single-subscription stream.
        final subThrStdout = StringBuffer();
        subThrProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(subThrStdout.write);
        await waitForReady(subThrStdout);

        // Start z_pub_thr connecting to the listener
        final pubThrProcess = await startPubThr(endpoint, packageRoot, 8);

        try {
          // Wait for z_sub_thr to complete
          final exitCode = await subThrProcess.exitCode.timeout(
            const Duration(seconds: 45),
          );

          final stdout = subThrStdout.toString();

          expect(stdout, contains('msg/s'));
          expect(exitCode, equals(0));
        } finally {
          await forceKill(pubThrProcess);
          // Ensure sub is killed too in case it didn't exit
          try {
            subThrProcess.kill(ProcessSignal.sigkill);
          } on Object catch (_) {}
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test("documents canon's round-length default", () async {
      // canon's DEFAULT_MESSAGES is 1,000,000 (z_sub_thr.c:20); ours was
      // 100,000, which silently changed what a default run measures. Every
      // other test here passes -n, so the default never executes -- and
      // running a default round to observe it would be a benchmark, not a
      // test. The help text renders from the same constant that feeds
      // `defaultsTo`, so pinning the text pins the default.
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_sub_thr.dart',
        '-h',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, equals(1));
      final out = result.stdout as String;
      expect(out, contains("default='1000000'"));
      expect(out, contains("default='10'"));
    });

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
      addTearDown(() => forceKill(subThrProcess));

      // Capture rather than re-read later: waiting on the output means
      // listening, and stdout is a single-subscription stream.
      final subThrStdout = StringBuffer();
      subThrProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen(subThrStdout.write);
      await waitForReady(subThrStdout);

      // Start z_pub_thr connecting to the listener
      final pubThrProcess = await startPubThr(endpoint, packageRoot, 8);

      try {
        // Wait for z_sub_thr to complete
        final exitCode = await subThrProcess.exitCode.timeout(
          const Duration(seconds: 45),
        );

        final stdout = subThrStdout.toString();

        expect(stdout, contains('messages over'));
        expect(exitCode, equals(0));
      } finally {
        await forceKill(pubThrProcess);
        try {
          subThrProcess.kill(ProcessSignal.sigkill);
        } on Object catch (_) {}
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'exits after configured rounds',
      () async {
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
        addTearDown(() => forceKill(subThrProcess));

        // Capture rather than re-read later: waiting on the output means
        // listening, and stdout is a single-subscription stream.
        final subThrStdout = StringBuffer();
        subThrProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(subThrStdout.write);
        await waitForReady(subThrStdout);

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
          } on Object catch (_) {}
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
