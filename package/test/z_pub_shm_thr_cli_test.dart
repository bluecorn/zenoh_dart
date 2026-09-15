import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

/// Starts z_sub_thr listening on [endpoint] and waits for it to bind.
///
/// Returns the process together with its captured stdout: waiting on the
/// output means listening to it here, and a process's stdout is a
/// single-subscription stream, so the caller cannot read it again afterwards.
Future<({Process process, StringBuffer stdout})> startSubThr(
  String endpoint,
  String packageRoot,
) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_sub_thr.dart',
    '-s',
    '1',
    '-n',
    '1000',
    '-l',
    endpoint,
  ], workingDirectory: packageRoot);
  addTearDown(() => forceKill(process));

  // Wait for the listener to actually bind rather than assuming 8s is enough.
  final out = StringBuffer();
  process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
  await waitForReady(out);
  return (process: process, stdout: out);
}

/// Pool size (MB) these tests ask the example for.
///
/// The example defaults to canon's `DEFAULT_SHARED_MEMORY_SIZE 32`
/// (`extern/zenoh-c/examples/z_pub_shm_thr.c:20`) and keeps it — that default is
/// parity, not a bug. But POSIX SHM pool creation is host-constrained: measured
/// here, pools up to 6 MB succeed while 7 MB and above fail with ENOMEM. A test
/// that inherits the default therefore asserts the host's limits rather than
/// the CLI's behaviour. None of these tests is about pool size, so they pin a
/// small one and stay reproducible anywhere.
const _testPoolMb = '1';

void main() {
  final packageRoot = Directory.current.path;

  group(
    'z_pub_shm_thr CLI',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      setUpAll(() {
        final scriptFile = File('$packageRoot/example/z_pub_shm_thr.dart');
        expect(
          scriptFile.existsSync(),
          isTrue,
          reason: 'example/z_pub_shm_thr.dart must exist',
        );
      });

      test('requires payload size argument', () async {
        final result = await runToCompletion(_dartExe, [
          'run',
          'example/z_pub_shm_thr.dart',
        ], workingDirectory: packageRoot);

        expect(result.exitCode, isNot(0));
      });

      test(
        'starts and publishes with SHM',
        () async {
          const endpoint = 'tcp/127.0.0.1:18620';

          // Start z_sub_thr first (it listens)
          final subThr = await startSubThr(endpoint, packageRoot);
          final subThrProcess = subThr.process;

          // Start z_pub_shm_thr connecting to the listener
          final pubShmProcess = await Process.start(_dartExe, [
            'run',
            'example/z_pub_shm_thr.dart',
            '-s',
            _testPoolMb,
            '64',
            '-e',
            endpoint,
          ], workingDirectory: packageRoot);
          addTearDown(() => forceKill(pubShmProcess));

          try {
            // Wait for z_sub_thr to complete its measurement round
            final exitCode = await subThrProcess.exitCode.timeout(
              const Duration(seconds: 45),
            );

            expect(subThr.stdout.toString(), contains('msg/s'));
            expect(exitCode, equals(0));
          } finally {
            await forceKill(pubShmProcess);
            try {
              subThrProcess.kill(ProcessSignal.sigkill);
            } on Object catch (_) {}
          }
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );

      test(
        'prints SHM startup messages',
        () async {
          const endpoint = 'tcp/127.0.0.1:18621';

          final process = await Process.start(_dartExe, [
            'run',
            'example/z_pub_shm_thr.dart',
            '-s',
            _testPoolMb,
            '64',
            '-l',
            endpoint,
          ], workingDirectory: packageRoot);
          addTearDown(() => forceKill(process));

          final stdoutBuf = StringBuffer();
          process.stdout
              .transform(const SystemEncoding().decoder)
              .listen(stdoutBuf.write);
          process.stderr
              .transform(const SystemEncoding().decoder)
              .listen((_) {}); // drain stderr

          await waitForOutput(stdoutBuf, 'Allocating single SHM buffer');
          await forceKill(process);

          final output = stdoutBuf.toString();
          expect(output, contains('SHM Provider'));
          expect(output, contains('Allocating single SHM buffer'));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'accepts --shared-memory flag',
        () async {
          const endpoint = 'tcp/127.0.0.1:18622';

          final process = await Process.start(_dartExe, [
            'run',
            'example/z_pub_shm_thr.dart',
            '-s',
            _testPoolMb,
            '64',
            '-l',
            endpoint,
          ], workingDirectory: packageRoot);
          addTearDown(() => forceKill(process));

          final stdoutBuf = StringBuffer();
          process.stdout
              .transform(const SystemEncoding().decoder)
              .listen(stdoutBuf.write);
          process.stderr
              .transform(const SystemEncoding().decoder)
              .listen((_) {}); // drain stderr

          await waitForOutput(stdoutBuf, 'Allocating single SHM buffer');
          await forceKill(process);

          final output = stdoutBuf.toString();
          // The flag reached the pool...
          // The banner reports the pool size the provider was actually
          // built with, not the MB the flag asked for -- so a run whose small
          // -s got clamped up to the example's floor says so instead of
          // reporting a size it never used. That floor was 65536 on a claim
          // that is measured false and is now canon's own 4096 (see the
          // constant's comment in z_pub_shm_thr.dart); this leg's 1 MB is far
          // above either, so the clamp does not engage and the assertion is
          // unchanged by the correction.
          const expectedBytes = 1 * 1024 * 1024;
          expect(output, contains('SHM Provider ($expectedBytes bytes)'));
          // ...and the pool was actually built. Both banners are printed
          // BEFORE the work they announce, so 'Creating…' alone passes even
          // when the provider then dies of ENOMEM. 'Allocating single SHM
          // buffer' is the first line that can only appear once ShmProvider()
          // has returned.
          expect(output, contains('Allocating single SHM buffer'));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      // Test 4, and the honest reading of it. A request the pool can NEVER
      // satisfy parks under BOTH allocators -- measured at this slice: pool
      // 4096, async request 8192, no answer in 3 s -- so the input that
      // "reports the failure and exits" has to be one canon REFUSES, not one
      // it parks. `0` is that input: a layout error, immediately, on either
      // entry.
      //
      // ⚠️ Stated rather than implied: this cell was green before the move as
      // well, so it is NOT the discriminator. What it guards is the failure
      // ARM of the switch -- the arm a migration is most likely to drop, and
      // the one nothing else in this file executes.
      test(
        'reports a refused allocation and exits, rather than parking',
        () async {
          final result = await runToCompletion(
            _dartExe,
            [
              'run',
              'example/z_pub_shm_thr.dart',
              '-s',
              _testPoolMb,
              '0',
            ],
            workingDirectory: packageRoot,
            timeout: const Duration(seconds: 45),
          );

          expect(
            result.exitCode,
            isNot(0),
            reason:
                'a refused allocation must not look like a healthy run: '
                '${result.stdout}',
          );
          expect(
            result.stdout as String,
            contains('Unexpected failure during SHM buffer allocation'),
          );
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('the example awaits the async allocator', () {
        // Per-file anchor. The population-wide claim -- that NOTHING in
        // `lib/` or `example/` calls the blocking entry any more, and that
        // the one declaration survives -- is a census in
        // `z_pub_shm_cli_test.dart`, which is also where the code-only
        // scanner that makes it discriminate lives.
        final source = File(
          '$packageRoot/example/z_pub_shm_thr.dart',
        ).readAsStringSync();
        expect(source, contains('await provider.allocGcDefragAsync('));
        expect(source, contains('allocates once at startup'));
      });
    },
  );
}
