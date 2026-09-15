// CLI tests for z_non_blocking_get.dart — canon's polling-get example.
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The Dart executable running this suite. Spawning `fvm` would hardcode a tool
/// that need not be on PATH and would resolve a *different* Dart.
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_non_blocking_get CLI', () {
    Future<ProcessResult> run([List<String> args = const []]) {
      return runToCompletion(_dartExe, [
        'run',
        'example/z_non_blocking_get.dart',
        ...args,
      ], workingDirectory: packageRoot);
    }

    test('terminates on the disconnect arm, not on a timer', () async {
      // With nothing answering, canon's own loop shape exits as soon as the
      // channel reports DISCONNECTED — which for a get with no matching
      // queryable is immediate. A loop that waited out its timeout instead
      // would take the full 20 s here.
      final started = DateTime.now();
      final result = await run([
        '-s',
        'demo/nobody/answers/**',
        '-o',
        '20000',
      ]);
      final elapsed = DateTime.now().difference(started);

      expect(result.exitCode, isZero, reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Sending Query'));
      expect(
        elapsed.inSeconds,
        lessThan(15),
        reason: 'the exit condition must be the disconnect arm, not the clock',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('prints a received reply in canon shape', () async {
      const key = 'demo/example/nbg/cli';
      const port = 19397;

      final queryable = await Process.start(_dartExe, [
        'run',
        'example/z_queryable.dart',
        '-k',
        key,
        '-p',
        'nbg-reply',
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

      final result = await run([
        '-s',
        key,
        '-o',
        '5000',
        '-e',
        'tcp/127.0.0.1:$port',
        '--no-multicast-scouting',
      ]);

      expect(result.exitCode, isZero, reason: 'stderr: ${result.stderr}');
      // canon's exact shape: >> Received ('key': 'value')
      expect(
        result.stdout as String,
        contains(">> Received ('$key': 'nbg-reply')"),
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the polling switch is exhaustive with no default arm', () {
      // [inspection]. The three-way discriminant's whole purpose is that the
      // loop's exit condition is expressible; a `default` arm would both
      // discard that and silently swallow any future variant.
      final source = File('example/z_non_blocking_get.dart').readAsStringSync();
      expect(source, contains('case RecvData('));
      expect(source, contains('case RecvEmpty()'));
      expect(source, contains('case RecvDisconnected()'));
      expect(source, isNot(contains('default:')));
    });

    test('flags mirror canon exactly', () {
      // canon's z_non_blocking_get.c takes -s/--selector, -p/--payload,
      // -t/--target and -o/--timeout, plus the common block.
      final source = File('example/z_non_blocking_get.dart').readAsStringSync();
      expect(source, contains("addOption('selector', abbr: 's'"));
      expect(source, contains("addOption('payload', abbr: 'p'"));
      expect(source, contains("addOption('target', abbr: 't'"));
      expect(source, contains("addOption('timeout', abbr: 'o'"));
      // The common flag block comes from the shared translation of canon's
      // parse_args.h, not hand-rolled here.
      expect(source, contains('addCommonArgs(parser)'));
      expect(source, contains("import 'common_args.dart'"));
    });

    test('--help prints usage and exits 1', () async {
      final result = await run(['--help']);
      expect(result.exitCode, equals(1));
      expect(result.stdout as String, contains('Usage: z_non_blocking_get'));
      expect(result.stdout as String, contains('--no-multicast-scouting'));
    });

    test('an unknown option is reported and exits non-zero', () async {
      final result = await run(['--bogus']);
      expect(result.exitCode, isNot(0));
      expect(result.stdout as String, contains('Unknown option --bogus'));
    });
  });
}
