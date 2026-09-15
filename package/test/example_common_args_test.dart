// Tests for the shared example argument surface (`example/common_args.dart`).
//
// canon puts this block in one header (`extern/zenoh-c/examples/parse_args.h`)
// and every example calls it; we put it in one Dart file and every example
// imports it. So it is tested here once, plus one sweep that proves every
// example really does adopt it -- rather than twenty-five near-identical
// per-example flag tests that would each drift on their own.
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';

/// The Dart executable running this suite.
final String _dartExe = Platform.resolvedExecutable;

/// A line that appears only in the shared block, not in any example's own
/// options -- so finding it proves the example adopted the block rather than
/// merely having some help text.
const _commonBlockMarker = '--no-multicast-scouting (optional)';

void main() {
  final packageRoot = Directory.current.path;

  Future<ProcessResult> runExample(
    String script,
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
  }) => runToCompletion(
    _dartExe,
    [
      'run',
      'example/$script',
      ...args,
    ],
    workingDirectory: packageRoot,
    timeout: timeout,
  );

  group('example common args', () {
    test('every session-opening example prints the shared help block', () async {
      // The coverage assertion for "one implementation, not twenty-five": if an
      // example is added, or one silently keeps a hand-rolled parser, this is
      // what notices.
      final scripts =
          Directory('$packageRoot/example')
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n.startsWith('z_') && n.endsWith('.dart'))
              .toList()
            ..sort();

      // canon's z_bytes.c has no argument parsing at all and opens no session.
      final expected = scripts.where((n) => n != 'z_bytes.dart').toList();
      expect(
        expected,
        hasLength(27),
        reason: 'expected 27 session-opening examples, found: $scripts',
      );

      final missing = <String>[];
      for (final script in expected) {
        final result = await runExample(script, ['-h']);
        final out = result.stdout as String;
        if (result.exitCode != 1 || !out.contains(_commonBlockMarker)) {
          missing.add('$script (exit ${result.exitCode})');
        }
      }
      expect(
        missing,
        isEmpty,
        reason: 'examples without the shared help block: $missing',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
      "help prints the example's own options above the shared block",
      () async {
        final result = await runExample('z_put.dart', ['--help']);
        final out = result.stdout as String;
        // canon's `_Z_CHECK_HELP` exits 1, not 0.
        expect(result.exitCode, equals(1));
        expect(out, contains('Usage: z_put [OPTIONS]'));
        expect(out, contains('-k, --key <KEYEXPR>'));
        expect(out, contains(_commonBlockMarker));
        expect(
          out.indexOf('-k, --key <KEYEXPR>'),
          lessThan(out.indexOf(_commonBlockMarker)),
          reason: 'canon prints its own options, then printf(COMMON_HELP)',
        );
      },
    );

    test('z_bytes deliberately has no flag surface', () async {
      // canon's z_bytes.c has no parse_args.h include. Giving it one would be a
      // divergence, so the absence is asserted rather than left to chance.
      final result = await runExample('z_bytes.dart', ['-h']);
      expect(result.exitCode, equals(0));
      expect(result.stdout as String, isNot(contains(_commonBlockMarker)));
    });

    test(
      'an unknown long option is rejected the way canon rejects it',
      () async {
        final result = await runExample('z_put.dart', ['--bogus']);
        expect(result.stdout as String, contains('Unknown option --bogus'));
        // canon's exit(-1), as a shell observes it.
        expect(result.exitCode, equals(255));
      },
    );

    test('an unknown short option is rejected', () async {
      final result = await runExample('z_put.dart', ['-Z']);
      expect(result.stdout as String, contains('Unknown option -Z'));
      expect(result.exitCode, equals(255));
    });

    test('an option missing its value is rejected', () async {
      final result = await runExample('z_put.dart', ['-k']);
      expect(
        result.stdout as String,
        contains('Option -k given without a value'),
      );
      expect(result.exitCode, equals(255));
    });

    test('an unexpected positional argument is rejected', () async {
      final result = await runExample('z_put.dart', ['surplus']);
      expect(
        result.stdout as String,
        contains('Unexpected positional arguments'),
      );
      expect(result.exitCode, equals(255));
    });

    test('a missing required positional is reported by name', () async {
      final result = await runExample('z_ping.dart', []);
      expect(
        result.stdout as String,
        contains('<PAYLOAD_SIZE> argument is required'),
      );
      expect(result.exitCode, equals(255));
    });

    test(
      '-m, --cfg and --no-multicast-scouting reach the session config',
      () async {
        final result = await runExample('z_put.dart', [
          '-m',
          'peer',
          '--cfg',
          'scouting/delay:100',
          '--no-multicast-scouting',
          '-k',
          'test/commonargs/ok',
        ]);
        expect(
          result.exitCode,
          equals(0),
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
        expect(result.stdout as String, contains('Putting Data'));
      },
    );

    test("an invalid --mode is fatal, with canon's message", () async {
      final result = await runExample('z_put.dart', ['-m', 'bogus']);
      expect(
        result.stdout as String,
        contains("Value must be one of: 'client', 'peer' or 'router'"),
      );
      expect(result.exitCode, equals(255));
    });

    test('a --cfg argument without a colon is fatal', () async {
      final result = await runExample('z_put.dart', ['--cfg', 'nocolon']);
      expect(
        result.stdout as String,
        contains('expected KEY:VALUE pair, got nocolon'),
      );
      expect(result.exitCode, equals(255));
    });

    test('-c loads a configuration file, and a missing one is fatal', () async {
      final dir = Directory.systemTemp.createTempSync('zenoh_dart_cfg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final configFile = File('${dir.path}/config.json5')
        ..writeAsStringSync(
          '{ mode: "peer", scouting: { multicast: '
          '{ enabled: false } } }',
        );

      final ok = await runExample('z_put.dart', [
        '-c',
        configFile.path,
        '-k',
        'test/commonargs/fromfile',
      ]);
      expect(
        ok.exitCode,
        equals(0),
        reason: 'stdout: ${ok.stdout}\nstderr: ${ok.stderr}',
      );

      final missing = await runExample('z_put.dart', [
        '-c',
        '${dir.path}/does-not-exist.json5',
      ]);
      expect(missing.exitCode, isNot(0));
      expect(
        missing.stdout as String,
        contains("Couldn't read configuration file"),
      );
    });

    test('a --cfg value containing commas reaches the config intact', () async {
      // canon takes multiple values by *repeating* the flag, so a comma inside
      // a value is a literal character. `package:args` splits on commas by
      // default, which fragmented this JSON5 list into `listen/endpoints:
      // ["tcp/127.0.0.1:18661"` and `"tcp/127.0.0.1:18662"]` -- the first no
      // longer valid JSON5, so the insert failed and the example exited 255.
      final result = await runExample('z_put.dart', [
        '--no-multicast-scouting',
        '--cfg',
        'listen/endpoints:["tcp/127.0.0.1:18661","tcp/127.0.0.1:18662"]',
        '-k',
        'test/commonargs/splitcommas',
      ]);
      expect(
        result.exitCode,
        equals(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout as String, contains('Putting Data'));
    });

    test('a repeatable option does not split its value at commas', () async {
      // The pair below is the whole discriminator, and it is exact rather than
      // behavioural: `_insertEndpoints` echoes the JSON list it built, so the
      // number of elements in that echo says how many values the parser
      // produced. One comma-containing value must echo as ONE element -- it
      // echoed `['aaa','bbb']` before the fix. Deliberately invalid locators:
      // this asserts what the parser produced, and needs no network to do it.
      final result = await runExample('z_put.dart', ['-l', 'aaa,bbb']);
      expect(result.stdout as String, contains("['aaa,bbb']"));
      expect(result.exitCode, equals(255));
    });

    test('a repeated option still accumulates its values', () async {
      // The other half of the pair: same two tokens, delivered canon's way.
      // Guards against "fixing" the split by dropping accumulation entirely.
      final result = await runExample('z_put.dart', ['-l', 'aaa', '-l', 'bbb']);
      expect(result.stdout as String, contains("['aaa','bbb']"));
      expect(result.exitCode, equals(255));
    });

    test('a --no-<flag> alias is rejected the way canon rejects it', () async {
      // `package:args` auto-generates a `--no-X` spelling for every flag unless
      // `negatable: false` says otherwise. Canon has no negation concept, so
      // each of these was a surface canon does not have -- silently accepted,
      // and silently inverting the flag. The second is the vivid one: the flag
      // is itself named `no-express`, so the generated alias was
      // `--no-no-express`.
      final complete = await runExample('z_queryable.dart', [
        '--no-complete',
        '-m',
        'bogus',
      ]);
      expect(
        complete.stdout as String,
        contains('Unknown option --no-complete'),
      );
      expect(complete.exitCode, equals(255));

      final express = await runExample('z_ping.dart', ['8', '--no-no-express']);
      expect(
        express.stdout as String,
        contains('Unknown option --no-no-express'),
      );
      expect(express.exitCode, equals(255));
    });

    test('a flag canon spells with a no- prefix still works', () async {
      // The control for the test above: `--no-multicast-scouting` is a real
      // canon flag whose name begins with `no-`, so a sweep that rejected every
      // `--no-*` spelling would break it. It must still reach the config.
      final result = await runExample('z_put.dart', [
        '--no-multicast-scouting',
        '-k',
        'test/commonargs/negatable',
      ]);
      expect(
        result.exitCode,
        equals(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout as String, contains('Putting Data'));
    });

    test('z_delete accepts -e and -l like every other example', () async {
      // z_delete was the one example with no endpoint flags at all: it called
      // a bare Session.open() and could not be pointed at a router or peer,
      // while the guide documented -e/-l as present. Adopting the shared block
      // closed that.
      final result = await runExample('z_delete.dart', [
        '-k',
        'test/commonargs/deleted',
        '-l',
        'tcp/127.0.0.1:18631',
        '--no-multicast-scouting',
      ]);
      expect(
        result.exitCode,
        equals(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout as String, contains('Deleting resources matching'));
    });
  });

  group('example session open', () {
    // A config that fails to open deterministically and *without touching the
    // network*: client mode has no peer to connect to, and disabling multicast
    // scouting removes the only other way to find one, so zenoh refuses on the
    // config alone -- "No peer specified and multicast scouting deactivated!",
    // in under a second. Chosen by measurement: a config that failed by timing
    // out would make these tests slow and flaky rather than fast and certain.
    const failingOpen = ['-m', 'client', '--no-multicast-scouting'];

    // The four examples canon gives a required <PAYLOAD_SIZE> positional.
    const needsPositional = {
      'z_ping.dart',
      'z_ping_shm.dart',
      'z_pub_thr.dart',
      'z_pub_shm_thr.dart',
    };

    test("a failed open reports canon's message, not a stack trace", () async {
      final result = await runExample('z_put.dart', failingOpen);
      final out = result.stdout as String;
      final all = '$out${result.stderr}';

      expect(out, contains('Unable to open session!'));
      // These two are the load-bearing assertions, because the exit status
      // cannot discriminate here: Dart exits 255 on an uncaught exception,
      // which is the same status a shell observes for canon's `exit(-1)`. So
      // an exit-code-only test would have passed against the unguarded code.
      // What actually changed is that the failure is now reported rather than
      // thrown out of `main`.
      expect(all, isNot(contains('Unhandled exception')));
      expect(all, isNot(contains('ZenohException')));
      expect(result.exitCode, equals(255));
    });

    test('every session-opening example guards its open', () async {
      // The coverage assertion, mirroring the shared-help-block sweep above: an
      // example added later that hand-rolls `Session.open` instead of taking
      // `openSession` would otherwise regress silently, since nothing notices
      // an unguarded open until a user hits one.
      final scripts =
          Directory('$packageRoot/example')
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n.startsWith('z_') && n.endsWith('.dart'))
              // canon's z_bytes.c opens no session and parses no arguments;
              // canon's z_scout.c scouts without opening one. Both are canon's
              // shapes, not omissions on our side.
              .where((n) => n != 'z_bytes.dart' && n != 'z_scout.dart')
              .toList()
            ..sort();
      expect(
        scripts,
        hasLength(26),
        reason: 'expected 26 session-opening examples, found: $scripts',
      );

      final unguarded = <String>[];
      for (final script in scripts) {
        final result = await runExample(script, [
          ...failingOpen,
          if (needsPositional.contains(script)) '8',
        ]);
        final all = '${result.stdout}${result.stderr}';
        if (!all.contains('Unable to open session!') ||
            all.contains('Unhandled exception')) {
          unguarded.add('$script (exit ${result.exitCode})');
        }
      }
      expect(
        unguarded,
        isEmpty,
        reason: 'examples whose session open is unguarded: $unguarded',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
