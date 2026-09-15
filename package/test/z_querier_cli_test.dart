import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

// CLI tests for z_querier.dart example
void main() {
  final packageRoot = Directory.current.path;

  group('z_querier CLI', () {
    Future<String> runZQuerierAndCapture(
      List<String> args, {
      String until = 'Querying',
    }) async {
      final process = await Process.start(_dartExe, [
        'run',
        'example/z_querier.dart',
        ...args,
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await waitForOutput(stdout, until);
      await forceKill(process);
      await subscription.cancel();

      return stdout.toString();
    }

    test('runs with default arguments and prints declaring message', () async {
      final output = await runZQuerierAndCapture(['--timeout', '2000']);
      expect(output, contains('Declaring Querier'));
      expect(output, contains('demo/example/**'));
    });

    test('-o 0 is canon-valid and declares rather than crashing', () async {
      // canon's z_querier accepts `-o 0` and reads it as "use the configured
      // default query timeout". Seed #6 refuses a zero Duration at
      // `declareQuerier`, so forwarding the flag verbatim would turn a
      // canon-valid invocation into an uncaught ArgumentError. The example
      // translates the sentinel to `timeout: null` instead.
      final output = await runZQuerierAndCapture(['-o', '0']);
      expect(output, contains('Declaring Querier'));
    });

    test('accepts --selector flag', () async {
      final output = await runZQuerierAndCapture([
        '--selector',
        'demo/custom/**',
        '--timeout',
        '2000',
      ]);
      expect(output, contains('demo/custom/**'));
    });

    test('accepts short flags', () async {
      final output = await runZQuerierAndCapture([
        '-s',
        'demo/short/**',
        '-o',
        '2000',
      ]);
      expect(output, contains('demo/short/**'));
    });

    test('accepts --target flag', () async {
      final output = await runZQuerierAndCapture(['-t', 'ALL', '-o', '2000']);
      expect(output, contains('Querying'));
    });

    test('rejects an unsupported query target', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_querier.dart',
        '-t',
        'BOGUS',
      ], workingDirectory: packageRoot);
      expect(result.exitCode, isNot(0));
      expect(
        result.stdout as String,
        contains('Unsupported query target value [BOGUS]'),
      );
    });

    test(
      'issues queries serially, never overlapping a drain',
      () async {
        // The discriminating test for canon's main loop (z_querier.c:92-132):
        // sleep, query, drain to completion, THEN advance the index. The
        // fixed-rate `Timer.periodic` it replaced did not await its own
        // callback, so whenever a drain outlasted the one-second interval the
        // queries overlapped and the printed index REPEATED until the first
        // drain finished.
        //
        // A slow responder is what makes the two shapes distinguishable: with
        // no queryable at all the drain finalizes immediately and both loops
        // look identical. This queryable waits two seconds before replying, so
        // every drain outlasts the interval.
        const endpoint = 'tcp/127.0.0.1:18615';
        const keyExpr = 'test/querier/serial';

        final config = Config()
          ..insertJson5('listen/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);

        final queryable = session.declareQueryable(keyExpr);
        addTearDown(queryable.close);
        final queryableSub = queryable.stream.listen((query) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          query
            ..reply(keyExpr, 'slow reply')
            ..dispose();
        });
        addTearDown(queryableSub.cancel);

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_querier.dart',
          '-s',
          keyExpr,
          '-e',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final out = StringBuffer();
        final sub = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(out.write);

        await waitForOutput(out, 'Querying');
        await Future<void>.delayed(const Duration(seconds: 8));
        await forceKill(process);
        await sub.cancel();

        final indices = RegExp(r"payload '\[\s*(\d+)\]")
            .allMatches(out.toString())
            .map((m) => m.group(1)!)
            .toList();

        expect(
          indices.length,
          greaterThanOrEqualTo(2),
          reason:
              'need at least two iterations to say anything about order; '
              'captured: $out',
        );
        expect(
          indices.toSet().length,
          equals(indices.length),
          reason:
              'a repeated index means a query was issued before the '
              'previous drain finished; captured indices: $indices',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
