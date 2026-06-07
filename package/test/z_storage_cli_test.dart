import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

/// The FVM-resolved Dart executable path (direct binary, not fvm wrapper).
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

  group('z_storage CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_storage.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_storage.dart must exist',
      );
    });

    test(
      'starts and prints subscriber/queryable messages',
      () async {
        const endpoint = 'tcp/127.0.0.1:18700';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
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

        // Let it run for 3 seconds then kill
        await Future<void>.delayed(const Duration(seconds: 3));
        await forceKill(process);

        final stdout = stdoutBuf.toString();
        expect(stdout, contains('Declaring Subscriber'));
        expect(stdout, contains('Declaring Queryable'));
        expect(stdout, contains('demo/example/**'));
      },
      timeout: Timeout(Duration(seconds: 60)),
    );

    test('accepts --key flag', () async {
      const endpoint = 'tcp/127.0.0.1:18701';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '-k',
        'test/storage/**',
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

      // Let it run for 3 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      expect(stdout, contains('test/storage/**'));
    }, timeout: Timeout(Duration(seconds: 60)));

    test('accepts --complete flag', () async {
      const endpoint = 'tcp/127.0.0.1:18702';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '--complete',
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

      // Let it run for 3 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      final stderr = stderrBuf.toString();

      // Process should have started without crashing
      // Accept either clean startup messages or a clean exit
      expect(
        stdout.contains('Declaring Subscriber') ||
            stdout.contains('Press CTRL-C'),
        isTrue,
        reason:
            'Process should start without error. stdout: $stdout, stderr: $stderr',
      );
    }, timeout: Timeout(Duration(seconds: 60)));

    test(
      'put then query returns stored value',
      () async {
        const endpoint = 'tcp/127.0.0.1:18710';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        addTearDown(() => forceKill(storageProc));

        // Wait for z_storage to be ready
        await Future<void>.delayed(const Duration(seconds: 8));
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put a value
        final putResult = await Process.run(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'value1',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(
          putResult.exitCode,
          equals(0),
          reason: 'z_put failed: ${putResult.stderr}',
        );

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Query the stored value
        final getResult = await Process.run(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'demo/example/**',
          '-e',
          endpoint,
          '-o',
          '5000',
        ], workingDirectory: packageRoot);

        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          contains('value1'),
          reason:
              'z_get should return stored value. stdout: $getStdout, stderr: ${getResult.stderr}',
        );
      },
      timeout: Timeout(Duration(seconds: 60)),
    );

    test(
      'delete removes from storage then query omits deleted key',
      () async {
        const endpoint = 'tcp/127.0.0.1:18711';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        addTearDown(() => forceKill(storageProc));

        // Wait for z_storage to be ready
        await Future<void>.delayed(const Duration(seconds: 8));
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put key1 and key2
        final put1Result = await Process.run(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'val1',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(put1Result.exitCode, equals(0));

        final put2Result = await Process.run(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key2',
          '-p',
          'val2',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(put2Result.exitCode, equals(0));

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Delete key1 using in-process Session API
        final config = Config();
        config.insertJson5('connect/endpoints', '["$endpoint"]');
        final session = Session.open(config: config);
        // Allow connection to establish
        await Future<void>.delayed(const Duration(seconds: 2));
        session.deleteResource('demo/example/key1');
        // Wait for delete propagation
        await Future<void>.delayed(const Duration(seconds: 2));
        session.close();

        // Verify storage received the DELETE
        expect(storageStdout.toString(), contains('DELETE'));

        // Query and check that val1 is gone but val2 remains
        final getResult = await Process.run(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'demo/example/**',
          '-e',
          endpoint,
          '-o',
          '5000',
        ], workingDirectory: packageRoot);

        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          contains('val2'),
          reason:
              'z_get should return val2. stdout: $getStdout, stderr: ${getResult.stderr}',
        );
        expect(
          getStdout,
          isNot(contains('val1')),
          reason: 'z_get should not return deleted val1. stdout: $getStdout',
        );
      },
      timeout: Timeout(Duration(seconds: 90)),
    );

    test(
      'query with non-matching key returns no results',
      () async {
        const endpoint = 'tcp/127.0.0.1:18712';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        addTearDown(() => forceKill(storageProc));

        // Wait for z_storage to be ready
        await Future<void>.delayed(const Duration(seconds: 8));
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put a value under demo/example/key1
        final putResult = await Process.run(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'testval',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(putResult.exitCode, equals(0));

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Query with a non-matching selector
        final getResult = await Process.run(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'other/**',
          '-e',
          endpoint,
          '-o',
          '3000',
        ], workingDirectory: packageRoot);

        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          isNot(contains('testval')),
          reason:
              'z_get with non-matching selector should not return testval. stdout: $getStdout',
        );
      },
      timeout: Timeout(Duration(seconds: 60)),
    );
  });
}
