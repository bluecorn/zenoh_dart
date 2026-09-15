import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

import 'helpers/cli_process.dart';

void main() {
  group('Config lifecycle', () {
    test('default config creation succeeds', () {
      // Given: the native library is initialized (via bindings singleton)
      // When: Config() is constructed
      // Then: no exception is thrown; the Config object is created successfully
      final config = Config();
      expect(config, isA<Config>());
      config.dispose();
    });

    test('insertJson5 with valid key-value succeeds', () {
      // Given: a default Config
      final config = Config();

      // When: insertJson5 is called with a valid key and JSON5 value
      // Then: no exception is thrown
      expect(() => config.insertJson5('mode', '"peer"'), returnsNormally);

      config.dispose();
    });

    test('dispose releases resources', () {
      // Given: a Config object
      final config = Config();

      // When: config.dispose() is called
      // Then: no exception is thrown
      expect(config.dispose, returnsNormally);
    });

    test('dispose is idempotent (double-drop safe)', () {
      // Given: a Config that has already been disposed
      final config = Config()..dispose();

      // When: config.dispose() is called a second time
      // Then: no exception is thrown
      expect(config.dispose, returnsNormally);
    });

    test('insertJson5 with invalid key throws ZenohException', () {
      // Given: a default Config
      final config = Config();

      // When: insertJson5 is called with an invalid key
      // Then: a ZenohException is thrown with a negative return code
      expect(
        () => config.insertJson5('nonexistent/garbage/key', '"value"'),
        throwsA(
          isA<ZenohException>().having(
            (e) => e.returnCode,
            'returnCode',
            isNegative,
          ),
        ),
      );

      config.dispose();
    });

    test('insertJson5 after dispose throws StateError', () {
      final config = Config()..dispose();
      expect(() => config.insertJson5('mode', '"peer"'), throwsStateError);
    });

    test('insertJson5 with invalid JSON5 value throws ZenohException', () {
      final config = Config();
      // 'peer' without quotes is invalid JSON5 for a string field
      expect(
        () => config.insertJson5('mode', 'not_valid_json5'),
        throwsA(isA<ZenohException>()),
      );
      config.dispose();
    });

    test('insertJson5 after consumed throws StateError', () async {
      final config = Config();
      final session = await Session.open(config: config);
      expect(() => config.insertJson5('mode', '"peer"'), throwsStateError);
      session.close();
    });
  });

  group(
    'ZenohException last-error enrichment (F12, UNSTABLE)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      // Base text produced by Config.insertJson5's enriched throw for this key.
      const badKeyBase = 'Failed to insert config value for key "!!bad key!!"';

      /// Drives the capture-wired failure and returns the caught exception.
      ZenohException forcedInsertFailure() {
        final config = Config();
        try {
          config.insertJson5('!!bad key!!', '"x"');
          fail('expected insertJson5 to throw');
        } on ZenohException catch (e) {
          return e;
        } finally {
          config.dispose();
        }
      }

      test('forced failure carries upstream detail beyond base text + rc', () {
        // Given: a default Config; unstable API compiled in (Linux)
        // When: insertJson5('!!bad key!!', '"x"') fails and throws
        // Then: the message includes upstream last-error detail beyond the base
        final e = forcedInsertFailure();
        expect(e.message, startsWith(badKeyBase));
        // Enrichment appends ': <detail>' past the base text.
        expect(
          e.message.length,
          greaterThan(badKeyBase.length),
          reason:
              'enriched message should carry upstream detail past base text',
        );
        expect(e.message, contains('$badKeyBase: '));
      });

      test(
        'enrichment message survives to the Dart catch site (durable copy)',
        () {
          // Given: the same forced failure
          // When: the exception is caught and its message inspected (twice)
          // Then: the detail is a stable, non-empty, durable copy across the
          // FFI boundary (not a borrowed/emptied/garbage view)
          final e = forcedInsertFailure();
          final firstRead = e.message;
          final secondRead = e.message;
          expect(firstRead, isNotEmpty);
          expect(firstRead, equals(secondRead));
          // The detail portion past the base separator is non-empty.
          final detail = firstRead.substring('$badKeyBase: '.length);
          expect(detail, isNotEmpty);
        },
      );

      test(
        'stale-error-leak guard: wired -> un-wired op does not inherit detail',
        () {
          // ⚠️ RE-POINTED, not left vacuous. Under the caller-supplied-storage
          // mechanism this cell CANNOT FAIL: the un-wired path has no channel
          // through which a detail could reach it -- it calls the plain
          // constructor, which takes no detail, and there is no buffer to
          // read. What it asserts now is exactly that: the property is
          // STRUCTURAL, and this cell is the tripwire that fires if a later
          // change gives an un-wired site a detail channel.
          final keyexpr = File('lib/src/keyexpr.dart').readAsStringSync();
          expect(
            keyexpr,
            isNot(contains('.enriched(')),
            reason: 'the un-wired path must have no detail channel at all',
          );

          // op1: a detail-carrying failure produces detail D1.
          final op1 = forcedInsertFailure();
          final d1Detail = op1.message.substring('$badKeyBase: '.length);
          expect(
            d1Detail,
            isNotEmpty,
            reason: 'op1 must set a non-empty detail for a non-vacuous guard',
          );

          // op2: an UN-wired failure thrown via the plain constructor that
          // never reads the durable buffer (KeyExpr uses plain
          // ZenohException).
          late final ZenohException op2;
          try {
            KeyExpr('bad ke ***');
            fail('expected KeyExpr to throw');
          } on ZenohException catch (e) {
            op2 = e;
          }

          // op2's message is base text + rc and does NOT contain op1's detail.
          expect(op2.message, startsWith('Invalid key expression:'));
          expect(
            op2.message,
            isNot(contains(d1Detail)),
            reason:
                "un-wired path must not inherit a prior op's upstream detail",
          );
        },
      );

      test(
        'graceful degradation: enriched factory with no detail to carry',
        () {
          // ⚠️ REWRITTEN FROM THE NEW PREMISE. The old cell drove a SUCCESSFUL
          // insert first, on the premise that "clear-on-entry + a successful
          // insert leaves the shim buffer empty". There is no shim buffer any
          // more, so that setup asserted nothing; worse, its two-argument call
          // is now a compile error.
          //
          // The assertions are preserved unchanged. What changed is what
          // drives the fallback: the CALLER having no detail, which is the
          // honest rendering of the `stable` variant and of any un-wired site.
          final e = ZenohException.enriched('base text', -1, null);
          expect(e.message, equals('base text'));
          expect(e.returnCode, equals(-1));

          // The empty string degrades the same way -- a zero-length detail is
          // "no detail", not a detail that happens to be empty.
          expect(
            ZenohException.enriched('base text', -1, '').message,
            equals('base text'),
          );
        },
      );
    },
  );

  group('Config.fromStr (F4)', () {
    // Base text produced by Config.fromStr's enriched throw on malformed input.
    const fromStrBase = 'Failed to create config from string';

    test('valid JSON constructs an openable config', () async {
      // Given: a valid JSON5 config string setting mode to "peer"
      // When: Config.fromStr(json) is passed to Session.open(config:)
      // Then: the session opens successfully and is usable
      final config = Config.fromStr('{ mode: "peer" }');
      final session = await Session.open(config: config);
      expect(session, isA<Session>());
      expect(session.isClosed, isFalse);
      session.close();
    });

    test('constructed config is consumed exactly like a default Config', () async {
      // Given: a Config.fromStr(validJson)
      // When: passed to Session.open
      // Then: it is consumed -- reuse/dispose after throws StateError, matching
      // default-Config lifecycle semantics.
      final config = Config.fromStr('{ mode: "peer" }');
      final session = await Session.open(config: config);

      expect(
        () => config.insertJson5('mode', '"peer"'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
      expect(config.dispose, throwsA(isA<StateError>()));

      session.close();
    });

    test('malformed JSON throws ZenohException (enriched)', () {
      // Given: a malformed config string
      // When: Config.fromStr(malformed) is called
      // Then: throws ZenohException with a negative rc; the failure-path frees
      // the native config (no leak).
      expect(
        () => Config.fromStr('{ bad json'),
        throwsA(
          isA<ZenohException>().having(
            (e) => e.returnCode,
            'returnCode',
            isNegative,
          ),
        ),
      );
    });

    test(
      'wired -> wired: op2 carries its own detail D2, not op1 detail D1',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
      () {
        // ⚠️ RE-POINTED IN ITS REASON, not in its assertions. When it was
        // written it DISCRIMINATED: a stale durable buffer could genuinely
        // have handed op2 op1's text. Under caller-supplied storage it cannot
        // fail -- op2's detail came back from op2's own call -- so it is now a
        // guard against reintroduction rather than a discriminator, and it is
        // kept because the behaviour it pins is still the contract.
        // op1: capture-wired insert failure sets last-error detail D1.
        const badKeyBase =
            'Failed to insert config value for key "!!bad key!!"';
        late final ZenohException op1;
        final config = Config();
        try {
          config.insertJson5('!!bad key!!', '"x"');
          fail('expected insertJson5 to throw');
        } on ZenohException catch (e) {
          op1 = e;
        } finally {
          config.dispose();
        }
        final d1Detail = op1.message.substring('$badKeyBase: '.length);
        expect(
          d1Detail,
          isNotEmpty,
          reason: 'op1 must set a non-empty detail for a non-vacuous test',
        );

        // op2: a second capture-wired failure (Config.fromStr parse error)
        // which report_error!s its own fresh detail D2 before the shim
        // captures.
        late final ZenohException op2;
        try {
          Config.fromStr('{ bad json');
          fail('expected Config.fromStr to throw');
        } on ZenohException catch (e) {
          op2 = e;
        }

        // op2 carries its OWN fresh detail (enriched past its base text)...
        expect(op2.message, startsWith(fromStrBase));
        expect(
          op2.message.length,
          greaterThan('$fromStrBase: '.length),
          reason: 'op2 must carry its own fresh upstream detail D2',
        );
        // ...and does NOT inherit op1's stale detail D1.
        expect(
          op2.message,
          isNot(contains(d1Detail)),
          reason:
              'a wired op must carry its own fresh ERROR_DESCRIPTION, '
              'not the prior wired op detail',
        );
      },
    );
  });

  group('Config.fromFile + Config.fromEnv (F4)', () {
    // Package root (tests run from package/); used to spawn the fromEnv probe
    // subprocess with a resolvable package:zenoh.
    final packageRoot = Directory.current.path;

    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory('$packageRoot/.tmp_from_env_test')
        ..createSync(recursive: true);
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('fromFile constructs an openable config', () async {
      // Given: a temp file containing a valid JSON5 config (mode: "peer")
      // When: Config.fromFile(tempPath) is passed to Session.open(config:)
      // Then: the session opens successfully
      final cfgFile = File('${tmpDir.path}/valid.json5')
        ..writeAsStringSync('{ mode: "peer" }');

      final config = Config.fromFile(cfgFile.path);
      final session = await Session.open(config: config);
      expect(session, isA<Session>());
      expect(session.isClosed, isFalse);
      session.close();
    });

    test('fromFile on a missing path throws ZenohException (no leak)', () {
      // Given: a path that does not exist
      // When: Config.fromFile(missingPath) is called
      // Then: throws ZenohException; the failure-path frees the native config.
      expect(
        () => Config.fromFile('/nonexistent/path/xyz.json5'),
        throwsA(isA<ZenohException>()),
      );
    });

    test(
      'fromEnv failure: ZENOH_CONFIG unset/malformed throws ZenohException',
      () {
        // The test process has ZENOH_CONFIG unset (verified in the run env), so
        // Config.fromEnv() fails and throws; the failure-path frees the native
        // config (no leak).
        expect(
          Platform.environment.containsKey('ZENOH_CONFIG'),
          isFalse,
          reason: 'this in-process failure test assumes ZENOH_CONFIG is unset',
        );
        expect(Config.fromEnv, throwsA(isA<ZenohException>()));
      },
    );

    test(
      'fromEnv success: ZENOH_CONFIG at a valid config opens a session',
      () async {
        // Dart cannot setenv for its own process, so drive fromEnv's success
        // path via a spawned subprocess with ZENOH_CONFIG set to a valid
        // config file.
        final cfgFile = File('${tmpDir.path}/env.json5')
          ..writeAsStringSync('{ mode: "peer" }');
        final probe = File('${tmpDir.path}/from_env_probe.dart')
          ..writeAsStringSync('''
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/session.dart';

Future<void> main() async {
  final config = Config.fromEnv();
  final session = await Session.open(config: config);
  print('FROM_ENV_OK');
  session.close();
}
''');

        final result = await runToCompletion(
          Platform.resolvedExecutable,
          ['run', probe.path],
          workingDirectory: packageRoot,
          environment: {'ZENOH_CONFIG': cfgFile.path},
          timeout: const Duration(seconds: 60),
        );

        expect(
          result.exitCode,
          equals(0),
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
        expect(result.stdout as String, contains('FROM_ENV_OK'));
      },
    );
  });

  group('Config.get + Config.toString (F4)', () {
    test('get reads back an inserted value', () {
      // Given: a Config with mode set to "peer" via insertJson5
      // When: config.get('mode') is called
      // Then: returns the JSON value present at that key (value-level)
      final config = Config()..insertJson5('mode', '"peer"');
      final value = config.get('mode');
      expect(value, contains('peer'));
      config.dispose();
    });

    test('toString contains a known inserted key/value', () {
      // Given: a Config with a known key/value set
      // When: config.toString() is called
      // Then: returns JSON text containing that key and value
      final config = Config()..insertJson5('mode', '"peer"');
      final text = config.toString();
      expect(text, contains('mode'));
      expect(text, contains('peer'));
      config.dispose();
    });

    test('fromStr -> get/toString value round-trip (value-level)', () {
      // Given: Config.fromStr(json) for a json setting a known key
      // When: reading that key via get and inspecting toString()
      // Then: the value is readable via get and present in toString()
      //   (value-level, not textually byte-identical to input)
      final config = Config.fromStr('{ mode: "peer" }');
      expect(config.get('mode'), contains('peer'));
      final text = config.toString();
      expect(text, contains('mode'));
      expect(text, contains('peer'));
      config.dispose();
    });

    test('get on an absent/invalid key behaves deliberately (rc checked)', () {
      // Given: a valid Config
      // When: config.get(nonexistentKey) is called
      // Then: canon rc is checked, never silently discarded, no crash.
      //   Empirically this build throws ZenohException (zc_config_get_from_str
      //   returns rc != 0 for an absent key).
      final config = Config();
      expect(
        () => config.get('nonexistent_key_xyz'),
        throwsA(isA<ZenohException>()),
      );
      config.dispose();
    });
  });

  group('Config consumed-wrapper lifecycle', () {
    // markConsumed frees the Dart-owned calloc block wrapping the (already
    // gravestoned) z_owned_config_t -- 2008 bytes, previously leaked once per
    // Session.open. A double free would abort the VM, so these pin that the
    // block is released exactly once on every path.

    test('dispose after consume throws rather than no-opping', () async {
      // Config deliberately diverges from ZBytes here: a consumed config is a
      // caller bug worth reporting, not a silent no-op. Pinned so the leak fix
      // cannot quietly change the contract.
      final config = Config();
      (await Session.open(config: config)).close();

      expect(
        config.dispose,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test(
      'repeated dispose after consume keeps throwing (no double free)',
      () async {
        final config = Config();
        (await Session.open(config: config)).close();

        expect(config.dispose, throwsStateError);
        expect(config.dispose, throwsStateError);
      },
    );

    test('markConsumed is idempotent', () async {
      final config = Config();
      (await Session.open(config: config)).close();

      // Already consumed by Session.open; a second mark must not re-free.
      expect(config.markConsumed, returnsNormally);
      expect(config.markConsumed, returnsNormally);
    });

    test('markConsumed after dispose does not free a second time', () {
      final config = Config()..dispose();

      expect(config.markConsumed, returnsNormally);
      expect(
        () => config.insertJson5('mode', '"peer"'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    // The two tests below assert the leak fix *quantitatively*, by observing
    // that libc hands the freed wrapper block back. A leak is invisible to a
    // behavioural assertion -- it neither throws nor corrupts -- so without
    // these, every test in this group would pass just as happily while the
    // block leaked. The margins are wide (observed: 2 distinct blocks, not 10)
    // and a failure is loud, never silent.

    test('a consumed config returns its wrapper block to the allocator', () async {
      final addresses = <int>{};
      for (var i = 0; i < 50; i++) {
        final config = Config();
        addresses.add(config.nativePtr.address); // captured before consumption
        (await Session.open(config: config)).close();
      }

      // Leaking => 50 cycles allocate 50 distinct blocks. Released => the same
      // block is reissued each time, so the set stays tiny.
      expect(addresses.length, lessThan(10));
    });

    test('Session.open() releases its internally-created config block', () async {
      // Session.open({config: null}) builds a Config internally that nothing
      // else owns, so an unmarked one is unreachable forever. The internal
      // config's own address is unobservable, so probe it indirectly: each
      // cycle frees a block, lets the internal config take it, and records
      // whether the next cycle gets it back.
      //
      // Counted, not single-shot. A one-off "same address before and after"
      // check passes for the wrong reason whenever unrelated allocator churn
      // happens to recycle that one address -- it did exactly that against the
      // full pre-fix tree while the block genuinely leaked. Over N cycles a
      // leak needs a fresh block every time, so the count separates cleanly:
      // measured 4 distinct when fixed, 50 when leaking (both when the whole
      // fix is reverted and when only the internal-config mark is removed).
      const cycles = 50;
      final probeAddresses = <int>{};
      for (var i = 0; i < cycles; i++) {
        final probe = Config();
        probeAddresses.add(probe.nativePtr.address);
        probe.dispose(); // block returned to the allocator
        // internal config takes it -- and must too
        (await Session.open()).close();
      }

      expect(probeAddresses.length, lessThan(10));
    });
  });
}
