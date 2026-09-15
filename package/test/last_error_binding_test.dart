// Seed [D1] slice 1 — the failure detail travels with the call, and no
// thread-local read-back survives.
//
// ⭐ WHAT THIS FILE PROVES, AND IN WHICH CELL. Criterion A's literal form —
// "drive a read straddling a turn enough times to distinguish 249/300 from a
// fixed mechanism" — is UNSATISFIABLE after this slice, because there is no
// read to straddle. The substitution the plan makes, and which this file
// implements, has three legs:
//
//   (1) the proof is STRUCTURAL — the mechanism that could produce a foreign
//       read is absent from both shipped natives and from `package/lib`
//       (`the mechanism … no longer exists`, below);
//   (2) behavioural cells show the replacement DELIVERS rather than merely
//       removing (`every enriched site still carries canon's own text`);
//   (3) the RED-time record of 249/300 is the both-ways calibration, and it
//       lives in the dartdoc this file asserts.
//
// ⛔ The 300-round interleave cell is a REGRESSION GUARD, not the proof. It
// cannot fail on a correct implementation. Said here as well as in the
// harness because a reader who meets only one of the two would reasonably
// read it as the evidence.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

import 'helpers/last_error_interleave_harness.dart';

/// The three identifiers the deleted mechanism was made of.
///
/// ⛔ Deliberately NOT widened to a pattern. `development/discipline/
/// verification.md` §3b: a pattern broad enough to survive the deletion is a
/// pattern that no longer names the thing it was watching.
const _deletedIdentifiers = <String>[
  'zd_last_error_buf',
  'zd_last_error_len',
  '_zd_clear_last_error',
  'zd_last_error_message',
];

const _variants = <String>['unstable', 'stable'];

String _nativePath(String variant) =>
    'native/linux/x86_64/$variant/libzenoh_dart.so';

/// Every `zd_`-prefixed dynamic symbol defined by [variant]'s native.
Set<String> _dynamicZdSymbols(String variant) {
  final result = Process.runSync('nm', [
    '-D',
    '--defined-only',
    _nativePath(variant),
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'nm failed on $variant: ${result.stderr}',
  );
  return (result.stdout as String)
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((parts) => parts.length >= 3 && parts[2].startsWith('zd_'))
      .map((parts) => parts[2])
      .toSet();
}

void main() {
  group('[D1] S1 — the detail travels with the call', () {
    test('the mechanism that could produce a foreign read no longer exists', () {
      // The structural proof, and it is leg (1) of criterion A's substitution.
      // Three surfaces, because the mechanism had three: an exported reader,
      // the shim's durable storage, and a Dart-side fetch.
      for (final variant in _variants) {
        final symbols = _dynamicZdSymbols(variant);
        expect(
          symbols,
          isNot(contains('zd_last_error_message')),
          reason:
              'the reader is exported by the $variant native; a caller '
              'could still read a buffer it did not fill',
        );
        // The control: this instrument can see a symbol when one is there.
        // Without it, an `nm` that silently produced nothing would report the
        // absence above as a pass.
        expect(
          symbols,
          contains('zd_config_from_file'),
          reason:
              'positive control — nm must be able to see $variant symbols '
              'at all, or the absence above proves nothing',
        );
      }

      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final header = File('../src/zenoh_dart.h').readAsStringSync();
      for (final identifier in _deletedIdentifiers) {
        expect(
          shim,
          isNot(contains(identifier)),
          reason: '$identifier survives in the shim',
        );
        expect(
          header,
          isNot(contains(identifier)),
          reason: '$identifier survives in the shim header',
        );
      }

      // And no Dart site reads a buffer it did not receive from the call it
      // is reporting: the only way one could is through the binding, and the
      // binding is gone.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        for (final identifier in _deletedIdentifiers) {
          if (text.contains(identifier)) offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty);
    });

    test(
      "every enriched site still carries canon's own text for its own failure",
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (the capture is compiled out on '
                'stable — criterion F2, honest absence)',
      () {
        // Leg (2): the replacement DELIVERS. Removing the read-back without
        // this cell would satisfy leg (1) and ship a binding that had quietly
        // stopped surfacing upstream detail at all.
        //
        // Each driver is checked against canon's text for ITS OWN failure —
        // measured 2026-09-01, both variants, in this unit's probe run.
        const fileBase =
            'Failed to create config from file "/nonexistent/zdd1-s1.json5"';
        expect(
          _messageOf(() => Config.fromFile('/nonexistent/zdd1-s1.json5')),
          allOf(
            startsWith('$fileBase: '),
            contains('Failed to read config from'),
            contains('/nonexistent/zdd1-s1.json5'),
          ),
        );

        expect(
          _messageOf(() => Config.fromStr('{ bad json')),
          allOf(
            startsWith('Failed to create config from string: '),
            contains('Invalid config string'),
          ),
        );

        final config = Config();
        expect(
          _messageOf(() => config.insertJson5('!!bad key!!', '"x"')),
          allOf(
            startsWith(
              'Failed to insert config value for key "!!bad key!!": ',
            ),
            contains('unknown key'),
          ),
        );
        expect(
          _messageOf(() => config.get('!!nope!!')),
          allOf(
            startsWith('Failed to get config key "!!nope!!": '),
            contains('No value was found in the config'),
          ),
        );
        config.dispose();

        expect(
          _messageOf(Config.fromEnv),
          allOf(
            startsWith('Failed to create config from environment: '),
            contains('environment variable not found'),
          ),
        );
      },
    );

    test(
      'two isolates failing in an interleaved order each get their own message',
      timeout: const Timeout(Duration(minutes: 3)),
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (no detail segment on stable)',
      () async {
        // ⚠️ A REGRESSION GUARD, NOT THE PROOF — it cannot fail on a correct
        // implementation, because the detail is fixed at throw time. Criterion
        // B's adversarial half, claimed by name; the proof is the structural
        // cell above.
        final violations = await runInterleavedRounds();
        expect(
          violations,
          isEmpty,
          reason:
              '${violations.length} of 600 rounds carried a message that '
              'was not their own or had no detail at all:\n'
              '${violations.take(10).join('\n')}',
        );
      },
    );

    test(
      'the precondition that used to be unstated is now unrepresentable',
      () {
        // The signature is the contract. `detail` is supplied BY THE CALLER WHO
        // MADE THE CALL — there is nowhere else it could come from, because the
        // factory has no access to any buffer.
        final exceptions = File('lib/src/exceptions.dart').readAsStringSync();
        expect(
          exceptions,
          contains(
            'factory ZenohException.enriched(\n'
            '    String baseMessage,\n'
            '    int returnCode,\n'
            '    String? detail,\n'
            '  )',
          ),
          reason:
              'the third parameter is the whole mechanism; a change to its '
              'shape is a change to what the factory can be handed',
        );
        expect(
          exceptions,
          isNot(contains('_fetchLastErrorDetail')),
          reason: 'the Dart-side fetch is what made a foreign read possible',
        );

        // And the RED-time record — leg (3) of criterion A's substitution — is
        // carried where a reader of the factory will meet it, with the number
        // and its condition together.
        expect(exceptions, contains('249'));
        expect(exceptions, contains('300'));
        expect(exceptions, contains('unrepresentable'));

        // The five widened shim entries each carry the caller's storage.
        final header = File('../src/zenoh_dart.h').readAsStringSync();
        for (final entry in const [
          'zd_config_insert_json5',
          'zd_config_from_str',
          'zd_config_from_file',
          'zd_config_from_env',
          'zd_config_get',
        ]) {
          final declStart = header.indexOf('FFI_PLUGIN_EXPORT int $entry(');
          expect(
            declStart,
            greaterThanOrEqualTo(0),
            reason: '$entry not found',
          );
          final decl = header.substring(declStart, declStart + 260);
          expect(
            decl,
            allOf(
              contains('uint8_t* err_buf'),
              contains('int err_cap'),
              contains('int* err_len'),
            ),
            reason: "$entry must write its detail into the CALLER's storage",
          );
        }
      },
    );

    test(
      'the factory cannot be called without having asked the call for its '
      'detail',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        // R16's shape ground, asserted rather than asserted-about: a
        // two-argument call does not compile.
        //
        // ⛔ BOTH ARMS RUN. The three-argument arm is the calibration — an
        // analyzer that failed for an unrelated reason (a package_config this
        // cell built wrongly, say) would otherwise report the two-argument
        // arm's failure as proof.
        final twoArg = await _analyzeProbe(
          "ZenohException.enriched('base', -1);",
        );
        expect(
          twoArg.exitCode,
          isNot(0),
          reason:
              'a two-argument .enriched call must not compile:\n'
              '${twoArg.output}',
        );
        expect(
          twoArg.output,
          anyOf(
            contains('missing_required_argument'),
            contains('not_enough_positional_arguments'),
          ),
          reason:
              'the failure must be the ARITY, not some other error:\n'
              '${twoArg.output}',
        );

        final threeArg = await _analyzeProbe(
          "ZenohException.enriched('base', -1, null);",
        );
        expect(
          threeArg.exitCode,
          0,
          reason:
              'positive control — the three-argument form must analyze '
              'clean, or the arm above proves nothing:\n${threeArg.output}',
        );
      },
    );

    test('zd_config_to_string no longer captures, and its Dart site is '
        'unchanged', () {
      // The wired-but-unread site is REMOVED rather than promoted to a fourth
      // enriched site: enriching it would widen the surface to a call whose
      // input is the whole rendered config, which R3 forbids.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final start = shim.indexOf('int zd_config_to_string(');
      expect(start, greaterThanOrEqualTo(0));
      final body = shim.substring(start, shim.indexOf('\n}', start));
      expect(body, isNot(contains('_zd_capture_last_error')));

      final config = File('lib/src/config.dart').readAsStringSync();
      final toStringStart = config.indexOf('String toString() {');
      expect(toStringStart, greaterThanOrEqualTo(0));
      final toStringBody = config.substring(toStringStart, toStringStart + 700);
      expect(
        toStringBody,
        isNot(contains('enriched')),
        reason:
            'toString must not throw, so it never enriched; the removal '
            'of the capture must not have changed that',
      );

      // And it still behaves: a disposed config renders its placeholder.
      final disposed = Config()..dispose();
      expect(disposed.toString(), equals('Config(unavailable)'));
    });

    test(
      "the open path's detail is unchanged",
      timeout: const Timeout(Duration(minutes: 2)),
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (the capture is compiled out on '
                'stable)',
      () async {
        // The worker moved from a thread-local to a stack buffer. What it
        // POSTS did not change, and the rendering did not change with it —
        // driven, not read off the source.
        Object? error;
        try {
          final config = Config()
            ..insertJson5('mode', '"client"')
            ..insertJson5('scouting/multicast/enabled', 'false');
          (await Session.open(config: config)).close();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<ZenohException>());
        final message = (error! as ZenohException).message;
        expect(message, contains('. Zenoh says: '));
        expect(message, contains('No peer specified'));

        // ⚠️ The two renderings — `'$base: $detail'` at the config sites and
        // `'$base. Zenoh says: $detail'` here — are deliberately NOT unified
        // in this unit. Not named IN scope; recorded at the enrichment fence.
        final session = File('lib/src/session.dart').readAsStringSync();
        expect(session, contains(r'$base. Zenoh says: $detail'));
      },
    );

    test(
      'the two re-pointed source-scan instruments assert the NEW mechanism',
      () {
        // Their own cells live in session_open_offload_test.dart; this asserts
        // the SHIM side of what they were re-pointed onto, so a revert shows up
        // here too rather than only there.
        final shim = File('../src/zenoh_dart.c').readAsStringSync();
        final workerStart = shim.indexOf('static void* _zd_open_worker(');
        expect(workerStart, greaterThanOrEqualTo(0));
        final worker = shim.substring(workerStart, workerStart + 2200);

        expect(
          worker,
          contains('local to this call'),
          reason:
              "the re-pointed :578 asserts the worker's detail lives in "
              'storage local to this call, replacing the deleted '
              "_Thread_local's 'zero-initialised' ground",
        );
        expect(
          worker,
          contains('_zd_capture_last_error(detail_buf'),
          reason:
              'the re-pointed :581 asserts the PARAMETERISED call; the '
              'empty-paren form it replaced named a signature that moved',
        );
        // Preserved deliberately: both were correct before and remain correct.
        expect(worker, contains('TRAVELS WITH THE POST'));
      },
    );

    test('the surviving negative pin holds a fortiori', () {
      // session_open_offload_test.dart:586 asserts session.dart never names
      // the reader. It now holds over the WHOLE tree, because the symbol does
      // not exist anywhere to be reintroduced accidentally.
      final offenders = <String>[];
      for (final dir in [Directory('lib'), Directory('../src')]) {
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.dart') &&
              !entity.path.endsWith('.c') &&
              !entity.path.endsWith('.h')) {
            continue;
          }
          if (entity.readAsStringSync().contains('zd_last_error_message')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test(
      'on the stable variant the detail is absent, and the fallback is the '
      'base text',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        // Criterion F2's second arm. ⛔ An HONEST ABSENCE, not a fix
        // demonstration: the capture is compiled out on the variant consumers
        // actually get, so there is nothing to surface and the base text is
        // the whole message.
        final probe = await _runProbe('stable');
        expect(probe['VARIANT'], 'stable');
        expect(
          probe['FILE'],
          'Failed to create config from file "/nonexistent/zdd1s1.json5"',
        );
        expect(probe['STR'], 'Failed to create config from string');
        expect(
          probe['INSERT'],
          'Failed to insert config value for key "!!bad key!!"',
        );
        expect(probe['GET'], 'Failed to get config key "!!zdd1s1!!"');
        expect(probe['ENV'], 'Failed to create config from environment');
      },
    );

    test('the pinned phrases and scan windows survive the comment rewrite', () {
      // The two shipped instruments scan a fixed number of characters from the
      // worker's opening. A longer comment block pushes a pinned phrase out of
      // range and turns a live instrument into a silent pass — which is a
      // worse outcome than a red.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final workerStart = shim.indexOf('static void* _zd_open_worker(');
      expect(workerStart, greaterThanOrEqualTo(0));

      final window2200 = shim.substring(workerStart, workerStart + 2200);
      expect(window2200, contains('TRAVELS WITH THE POST'));

      final window3000 = shim.substring(workerStart, workerStart + 3000);
      expect(window3000, contains('_zd_str_to_cobject(detail, detail_len'));
    });

    test('no new file introduced by this slice trips a walked-tree pin', () {
      // parameters_fidelity_test.dart:289-305 walks all of lib/ and test/ for
      // an identifier that must appear nowhere. This slice enlarges that tree.
      //
      // ⚠️ The needle is SPLIT ACROSS TWO ADJACENT LITERALS on purpose. That
      // walker excludes exactly one file by name — its own — so a cell that
      // spelled the identifier out would be the very violation it is
      // checking for. Caught by this cell failing on itself, first run.
      const needle =
          'zd_query'
          '_parameters';
      for (final path in const [
        'test/last_error_binding_test.dart',
        'test/helpers/last_error_interleave_harness.dart',
        'test/helpers/config_failure_probe.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains(needle)),
          reason: '$path would break the walked-tree absence pin',
        );
      }
    });
  });
}

/// Drives [body] to failure and returns the exception's message.
String _messageOf(void Function() body) {
  try {
    body();
    fail('expected a ZenohException');
  } on ZenohException catch (e) {
    return e.message;
  }
}

/// Runs `config_failure_probe.dart` under [variant] and parses its lines.
Future<Map<String, String>> _runProbe(String variant) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/config_failure_probe.dart', 'zdd1s1'],
    environment: {'ZENOH_DART_VARIANT': variant},
  );
  final out = result.stdout as String;
  expect(
    out,
    contains('PROBE_DONE'),
    reason:
        'the probe did not reach the end — a blind child reads as a '
        'clean negative:\n$out${result.stderr}',
  );
  final parsed = <String, String>{};
  for (final line in const LineSplitter().convert(out)) {
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final key = line.substring(0, eq);
    final value = line.substring(eq + 1);
    parsed[key] = key == 'VARIANT' ? value : jsonDecode(value) as String;
  }
  return parsed;
}

/// The outcome of analyzing a generated one-line probe.
typedef _AnalyzeResult = ({int exitCode, String output});

/// Analyzes a throwaway file containing [statement], OUTSIDE the package tree.
///
/// ⛔ Deliberately not written into `package/`. A probe that must not compile,
/// left behind by a crashed run, would break `dart analyze package` — the
/// project's strict gate — for every later session. It is built in a fresh
/// system temp directory with a rewritten `package_config.json` (only the
/// self-entry's `rootUri` is relative; everything else is already absolute),
/// and removed on every path.
Future<_AnalyzeResult> _analyzeProbe(String statement) async {
  final packageRoot = Directory.current.absolute.path;
  final dir = await Directory.systemTemp.createTemp('zd_enriched_arity_');
  try {
    final config = jsonDecode(
      File('.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final entry in config['packages'] as List<dynamic>) {
      final package = entry as Map<String, dynamic>;
      if (package['name'] == 'zenoh_dart') {
        package['rootUri'] = Uri.file('$packageRoot/').toString();
      }
    }
    await Directory('${dir.path}/.dart_tool').create();
    File('${dir.path}/.dart_tool/package_config.json')
        .writeAsStringSync(jsonEncode(config));
    File('${dir.path}/probe.dart').writeAsStringSync(
      "import 'package:zenoh_dart/src/exceptions.dart';\n"
      'void main() {\n'
      '  $statement\n'
      '}\n',
    );

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['analyze', dir.path],
    );
    return (
      exitCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  } finally {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
