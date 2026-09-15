import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_pub CLI', () {
    test('runs and prints publisher declaration', () async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_pub.dart',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Wait for the first publish, not a fixed interval: 'Putting Data' is
      // printed after the readiness banner, so it is the later of the two
      // things asserted below.
      await waitForOutput(stdout, 'Putting Data');
      await forceKill(process);
      await subscription.cancel();

      final output = stdout.toString();
      expect(output, contains('Declaring Publisher'));
      expect(output, contains('Putting Data'));
    });

    test(
      "stamps every put with canon's text/plain encoding",
      () async {
        // canon clones `z_encoding_text_plain()` into the options of every put.
        // The encoding rides the wire, so the only place it can be observed is
        // a real receiver -- a banner assertion cannot see it.
        const endpoint = 'tcp/127.0.0.1:18545';
        const keyExpr = 'test/pub/encoding';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub.dart',
          '-k',
          keyExpr,
          '-l',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final out = StringBuffer();
        final outSub = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(out.write);
        addTearDown(outSub.cancel);

        await waitForReady(out);
        await Future<void>.delayed(const Duration(seconds: 2));

        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);

        final subscriber = session.declareSubscriber(keyExpr);
        addTearDown(subscriber.close);

        final received = await subscriber.stream.first.timeout(
          const Duration(seconds: 20),
        );
        expect(received.encoding, equals(Encoding.textPlain.mimeType));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
