import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group(
    'z_advanced_sub CLI',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('starts and prints declaration message with default key', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_advanced_sub.dart',
          '-l',
          'tcp/127.0.0.1:18722',
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
        addTearDown(() => forceKill(pubProcess));

        final pubStdout = StringBuffer();
        final pubSubscription = pubProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(pubStdout.write);

        // Wait until the publisher has demonstrably cached samples, rather than
        // sleeping 5 s and hoping. This is the one race in the suite whose
        // failure was silent instead of red: too short a sleep meant nothing
        // was cached, the subscriber greened on a live sample, and the test
        // still claimed to prove history.
        //
        // Gating on `[   2]` means samples [0]..[2] are published and inside
        // the 5-sample cache (`-i 5`) -- enough margin that [0] has not been
        // evicted by the time the subscriber connects. The index is padded to
        // width 4, as canon's `sprintf("[%4d] %s", ...)` does.
        await waitForOutput(pubStdout, "'[   2] ");

        // Start subscriber connecting to publisher
        final subProcess = await Process.start(_dartExe, [
          'run',
          'example/z_advanced_sub.dart',
          '-k',
          'demo/test/**',
          '-e',
          'tcp/127.0.0.1:18723',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(subProcess));

        final subStdout = StringBuffer();
        final subSubscription = subProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(subStdout.write);

        // `[0]` is the discriminator, and it is what the test's name is about.
        // The publisher published it before this subscriber existed, so it can
        // only have arrived through the history cache -- whereas the publisher
        // puts every second, so a subscriber with a completely broken history
        // path still shows a `Received PUT` within ~1 s. Asserting delivery
        // proved delivery; asserting `[0]` proves history.
        await waitForOutput(subStdout, "'[   0] ");

        await forceKill(subProcess);
        await forceKill(pubProcess);
        await subSubscription.cancel();
        await pubSubscription.cancel();

        final output = subStdout.toString();
        expect(output, contains('Received PUT'));
        expect(output, contains('[   0] '));
      });
    },
  );
}
