// z_pull CLI tests
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

/// z_pull prompts for input instead of printing the usual CTRL-C banner, so
/// its tests gate on canon's prompt (`Press <enter> to pull data...`).
const _pullReady = 'Press <enter>';

void main() {
  final packageRoot = Directory.current.path;

  group('z_pull CLI', () {
    test('runs and prints subscriber declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pull.dart',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForOutput(stdout, _pullReady);
      await forceKill(process);
      await subscription.cancel();

      expect(stdout.toString(), contains('Declaring Subscriber'));
      expect(stdout.toString(), contains('demo/example/**'));
    });

    test('accepts --key and --size flags', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pull.dart',
        '--key',
        'demo/custom/**',
        '--size',
        '5',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForOutput(stdout, _pullReady);
      await forceKill(process);
      await subscription.cancel();

      // canon's declaration banner carries the key expression only, so `--size`
      // is proven behaviourally instead -- see the ring-capacity test below.
      expect(stdout.toString(), contains('demo/custom/**'));
    });

    test('with empty key expression fails', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_pull.dart',
        '--key',
        '',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, isNot(0));
    });

    test(
      'receives sample from in-process put',
      () async {
        const port = 18571;
        const endpoint = 'tcp/127.0.0.1:$port';

        // Start z_pull listening on a specific key with TCP listener
        final pullProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pull.dart',
          '-k',
          'demo/cli/pull',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(pullProcess));

        final pullStdout = StringBuffer();
        final declaringCompleter = Completer<void>();
        final receivedCompleter = Completer<void>();
        final pullSubscription = pullProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen((data) {
              pullStdout.write(data);
              if (!declaringCompleter.isCompleted &&
                  pullStdout.toString().contains(_pullReady)) {
                declaringCompleter.complete();
              }
              if (!receivedCompleter.isCompleted &&
                  pullStdout.toString().contains('Received PUT')) {
                receivedCompleter.complete();
              }
            });

        try {
          // Wait for subscriber to be ready
          await declaringCompleter.future.timeout(const Duration(seconds: 15));
          // Extra time for TCP listener to bind
          await Future<void>.delayed(const Duration(seconds: 3));

          // Open in-process session connecting to the pull subscriber
          final config = Config()
            ..insertJson5('connect/endpoints', '["$endpoint"]');
          final session = await Session.open(config: config);

          // Give TCP connection time to negotiate
          await Future<void>.delayed(const Duration(seconds: 2));

          // Publish a sample
          session.put('demo/cli/pull', 'test payload');

          // Wait a bit for the sample to arrive in the ring buffer
          await Future<void>.delayed(const Duration(seconds: 1));

          // Send newline to stdin to trigger pull
          pullProcess.stdin.writeln();
          await pullProcess.stdin.flush();

          // Wait for sample to be received
          await receivedCompleter.future.timeout(const Duration(seconds: 10));

          final output = pullStdout.toString();
          expect(output, contains('Received PUT'));
          expect(output, contains('test payload'));

          session.close();
        } finally {
          // Send 'q' to quit gracefully, then force kill
          pullProcess.stdin.writeln('q');
          await pullProcess.stdin.flush();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await forceKill(pullProcess);
          await pullSubscription.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'pulls exactly one buffered sample per keypress',
      () async {
        // The discriminating test for canon's pull granularity: canon runs one
        // `z_try_recv` per input character (z_pull.c:74-86). An implementation
        // that drains the ring on each keypress prints BOTH payloads after the
        // first newline, and fails on the `isNot(contains('second'))` below --
        // which is exactly what the pre-fix example did.
        const port = 18573;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pullProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pull.dart',
          '-k',
          'demo/cli/pullgran',
          '-s',
          '4',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(pullProcess));

        final out = StringBuffer();
        final ready = Completer<void>();
        final sub = pullProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen((data) {
              out.write(data);
              if (!ready.isCompleted && out.toString().contains(_pullReady)) {
                ready.complete();
              }
            });

        try {
          await ready.future.timeout(const Duration(seconds: 15));
          await Future<void>.delayed(const Duration(seconds: 3));

          final config = Config()
            ..insertJson5('connect/endpoints', '["$endpoint"]');
          final session = await Session.open(config: config);
          await Future<void>.delayed(const Duration(seconds: 2));

          session
            ..put('demo/cli/pullgran', 'first-sample')
            ..put('demo/cli/pullgran', 'second-sample');
          await Future<void>.delayed(const Duration(seconds: 1));

          // One keypress -> exactly one sample.
          pullProcess.stdin.writeln();
          await pullProcess.stdin.flush();
          await waitForOutput(out, 'first-sample');
          // Give a would-be drain-all loop room to print the second one too.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(
            out.toString(),
            isNot(contains('second-sample')),
            reason: 'one keypress must pull one sample, not drain the ring',
          );

          // The second keypress releases the second sample.
          pullProcess.stdin.writeln();
          await pullProcess.stdin.flush();
          await waitForOutput(out, 'second-sample');

          session.close();
        } finally {
          pullProcess.stdin.writeln('q');
          await pullProcess.stdin.flush();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await forceKill(pullProcess);
          await sub.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '--size bounds what the lossy ring retains',
      () async {
        // Proves `-s` actually reaches the declaration now that the banner no
        // longer echoes it: with capacity 1 the older sample is dropped, so the
        // first pull yields the NEWER payload and the older one never appears.
        // At the default capacity of 3 both would be retained and the first
        // pull would yield 'older-sample' instead.
        const port = 18575;
        const endpoint = 'tcp/127.0.0.1:$port';

        final pullProcess = await Process.start(_dartExe, [
          'run',
          'example/z_pull.dart',
          '-k',
          'demo/cli/pullcap',
          '-s',
          '1',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(pullProcess));

        final out = StringBuffer();
        final ready = Completer<void>();
        final sub = pullProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen((data) {
              out.write(data);
              if (!ready.isCompleted && out.toString().contains(_pullReady)) {
                ready.complete();
              }
            });

        try {
          await ready.future.timeout(const Duration(seconds: 15));
          await Future<void>.delayed(const Duration(seconds: 3));

          final config = Config()
            ..insertJson5('connect/endpoints', '["$endpoint"]');
          final session = await Session.open(config: config);
          await Future<void>.delayed(const Duration(seconds: 2));

          session.put('demo/cli/pullcap', 'older-sample');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          session.put('demo/cli/pullcap', 'newer-sample');
          await Future<void>.delayed(const Duration(seconds: 1));

          pullProcess.stdin.writeln();
          await pullProcess.stdin.flush();
          await waitForOutput(out, 'newer-sample');
          expect(
            out.toString(),
            isNot(contains('older-sample')),
            reason: 'a capacity-1 ring must have dropped the older sample',
          );

          session.close();
        } finally {
          pullProcess.stdin.writeln('q');
          await pullProcess.stdin.flush();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await forceKill(pullProcess);
          await sub.cancel();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
