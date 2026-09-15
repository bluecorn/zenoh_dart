import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group(
    'z_advanced_pub CLI',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('starts and prints declaration message', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_advanced_pub.dart',
          '-l',
          'tcp/127.0.0.1:18720',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
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
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
        await forceKill(process);
        await subscription.cancel();

        final output = stdout.toString();
        expect(output, contains('demo/test/adv-pub'));
      });

      test('uses canon-shaped defaults when -k and -p are omitted', () async {
        // Every other test in this file passes -k, so the defaults never
        // execute. Round 2 moved them back to the plain language-tag form
        // (canon uses `demo/example/zenoh-c-pub` / `Pub from C!`, not a
        // separate `-advanced-pub` key), and adopted canon's `Put Data`
        // banner and `sprintf("[%4d] %s", ...)` padding. One line pins all
        // four.
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_advanced_pub.dart',
          '-l',
          'tcp/127.0.0.1:18725',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);
        addTearDown(subscription.cancel);

        // The first put, which only happens once the declaration returned.
        await waitForOutput(stdout, '[   0]');
        await forceKill(process);

        expect(
          stdout.toString(),
          contains(
            "Put Data ('demo/example/zenoh-dart-pub': '[   0] Pub from Dart!')",
          ),
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('runs with -i cache size without error', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_advanced_pub.dart',
          '-i',
          '10',
          '-l',
          'tcp/127.0.0.1:18724',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
        await forceKill(process);
        await subscription.cancel();

        final output = stdout.toString();
        expect(output, contains('Declaring AdvancedPublisher on'));
      });
    },
  );
}
