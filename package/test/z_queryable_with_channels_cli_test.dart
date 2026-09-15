// CLI tests for z_queryable_with_channels.dart — canon's channel-queryable
// example.
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_queryable_with_channels CLI', () {
    test('answers a query from its recv loop, in canon shape', () async {
      const key = 'demo/example/qwc/cli';
      const port = 19398;

      final queryable = await Process.start(_dartExe, [
        'run',
        'example/z_queryable_with_channels.dart',
        '-k',
        key,
        '-p',
        'qwc-reply',
        '-l',
        'tcp/127.0.0.1:$port',
        '--no-multicast-scouting',
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(queryable));

      final qOut = StringBuffer();
      queryable.stdout
          .transform(const SystemEncoding().decoder)
          .listen(qOut.write);
      await waitForOutput(qOut, 'Press CTRL-C');

      final get = await runToCompletion(_dartExe, [
        'run',
        'example/z_get.dart',
        '-s',
        key,
        '-o',
        '5000',
        '-e',
        'tcp/127.0.0.1:$port',
        '--no-multicast-scouting',
      ], workingDirectory: packageRoot);

      expect(get.exitCode, isZero, reason: 'stderr: ${get.stderr}');
      expect(
        get.stdout as String,
        contains(">> Received ('$key': 'qwc-reply')"),
      );

      // ...and the example's own side observed the query, in canon's shape --
      // so the reply was answering a real received query rather than being
      // emitted unconditionally.
      await waitForOutput(qOut, 'Received Query');
      expect(qOut.toString(), contains(">> [Queryable ] Received Query '$key"));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the recv switch is exhaustive with no default arm', () {
      // [inspection]. Same reasoning as on the polling getter.
      final source = File('example/z_queryable_with_channels.dart')
          .readAsStringSync();
      expect(source, contains('case RecvData('));
      expect(source, contains('case RecvEmpty()'));
      expect(source, contains('case RecvDisconnected()'));
      expect(source, isNot(contains('default:')));
    });

    test('flags mirror canon exactly', () {
      // canon's z_queryable_with_channels.c takes -k/--key, -p/--payload and
      // --complete, plus the common block.
      final source = File('example/z_queryable_with_channels.dart')
          .readAsStringSync();
      expect(source, contains("addOption('key', abbr: 'k'"));
      expect(source, contains("addOption('payload', abbr: 'p'"));
      expect(source, contains("addFlag('complete'"));
      expect(source, contains('addCommonArgs(parser)'));
      expect(source, contains("import 'common_args.dart'"));
    });

    test('--help prints usage and exits 1', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_queryable_with_channels.dart',
        '--help',
      ], workingDirectory: packageRoot);
      expect(result.exitCode, equals(1));
      expect(
        result.stdout as String,
        contains('Usage: z_queryable_with_channels'),
      );
      expect(result.stdout as String, contains('--no-multicast-scouting'));
    });

    test('an unknown option is reported and exits non-zero', () async {
      final result = await runToCompletion(_dartExe, [
        'run',
        'example/z_queryable_with_channels.dart',
        '--bogus',
      ], workingDirectory: packageRoot);
      expect(result.exitCode, isNot(0));
      expect(result.stdout as String, contains('Unknown option --bogus'));
    });
  });
}
