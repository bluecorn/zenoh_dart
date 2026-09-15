import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

void main() {
  group('Zenoh', () {
    test('initLog does not throw', () {
      // initLog is idempotent -- safe to call in tests.
      expect(() => Zenoh.initLog('error'), returnsNormally);
    });

    test('initLog accepts various filter levels', () {
      // Subsequent calls are no-ops in zenoh-c, but should not throw.
      expect(() => Zenoh.initLog('warn'), returnsNormally);
      expect(() => Zenoh.initLog('info'), returnsNormally);
    });
  });

  group('Zenoh scout', () {
    test('completes without error', () async {
      final hellos = await Zenoh.scout(timeoutMs: 500);
      expect(hellos, isA<List<Hello>>());
    });

    test('with custom config completes', () async {
      final config = Config();
      final hellos = await Zenoh.scout(config: config, timeoutMs: 500);
      expect(hellos, isA<List<Hello>>());
      // Config should be consumed -- attempting to use it throws StateError
      expect(() => config.nativePtr, throwsStateError);
    });

    test('discovers a peer session', () async {
      // Open a session with multicast on loopback interface
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17461"]')
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final session = await Session.open(config: listenConfig);
      addTearDown(session.close);

      // Wait for listener to bind and multicast to start
      await Future<void>.delayed(const Duration(seconds: 1));

      // Scout with loopback multicast to find the peer
      final scoutConfig = Config()
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);
      expect(hellos, isNotEmpty);

      final peerHello = hellos.firstWhere(
        (h) => h.whatami == WhatAmI.peer,
        orElse: () => throw TestFailure('No peer found in scout results'),
      );
      expect(peerHello.zid.bytes.length, 16);
      // ZID should be non-zero
      expect(peerHello.zid.bytes.any((b) => b != 0), isTrue);
      expect(peerHello.locators, isNotEmpty);
    });

    test('Hello fields are populated correctly', () async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17462"]')
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final session = await Session.open(config: listenConfig);
      addTearDown(session.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final scoutConfig = Config()
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);
      expect(hellos, isNotEmpty);

      final hello = hellos.first;
      expect(hello.zid, isA<ZenohId>());
      expect(hello.zid.bytes.length, 16);
      expect(hello.zid.bytes.any((b) => b != 0), isTrue);
      expect(
        hello.whatami,
        isIn([WhatAmI.router, WhatAmI.peer, WhatAmI.client]),
      );
      expect(hello.locators, isA<List<String>>());
      expect(hello.locators, isNotEmpty);
      // At least one locator should contain a protocol prefix
      expect(hello.locators.any((l) => l.contains('tcp/')), isTrue);
    });

    test('Hello.toString produces readable output', () async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17463"]')
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final session = await Session.open(config: listenConfig);
      addTearDown(session.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final scoutConfig = Config()
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);
      expect(hellos, isNotEmpty);

      final str = hellos.first.toString();
      expect(str, contains('Hello'));
      expect(str, contains(hellos.first.zid.toHexString()));
      expect(str, contains(hellos.first.whatami.name));
      // Should contain at least one locator
      expect(str, contains('tcp/'));
    });

    test('with consumed config throws StateError', () async {
      final config = Config();
      // Consume the config by opening a session
      final session = await Session.open(config: config);
      addTearDown(session.close);

      // Now config is consumed -- scout should throw
      expect(
        () => Zenoh.scout(config: config, timeoutMs: 500),
        throwsStateError,
      );
    });
  });

  // Acceptance A (seed #1, scout-offload-micro): a Future-returning API
  // contractually must not block the caller's event loop. Pre-fix, Zenoh.scout
  // ran the blocking FFI zd_scout synchronously on the caller isolate with no
  // preceding await, so the whole timeoutMs executed on the event-loop thread.
  //
  // The discriminator is ticks-DURING-the-scout-window, never wall-clock: a
  // frozen loop yields ~1 tick across a 1000ms scout, a live one ~19-20
  // (measured on the pre-fix .so). The >= 5 threshold clears both by ~5x.
  // Test 2 is the positive control -- without it, a failing Test 1 could be
  // indicting the timer instrument or a slow machine rather than the scout.
  group('Zenoh scout event-loop liveness', () {
    test('the event loop advances while a scout is in flight', () async {
      // Multicast off makes discovery deterministic and LAN-independent while
      // z_scout still blocks for its full timeout (measured). The assertion is
      // purely "did the loop advance" -- no peer count is asserted.
      final quietConfig = Config()
        ..insertJson5('scouting/multicast/enabled', 'false');

      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => ticks++,
      );
      final sw = Stopwatch()..start();
      // The window is stated explicitly even though it matches the default:
      // both the 800ms floor and the 5-tick threshold below are calibrated to
      // it, so a reader must be able to see it without resolving the default.
      // ignore: avoid_redundant_argument_values
      final hellos = await Zenoh.scout(config: quietConfig, timeoutMs: 1000);
      sw.stop();
      timer.cancel();

      // The scout window has to be real, or a low tick count would prove
      // nothing -- an instant return would also produce ~0 ticks.
      expect(
        sw.elapsedMilliseconds,
        greaterThanOrEqualTo(800),
        reason:
            'scout returned in ${sw.elapsedMilliseconds}ms -- too fast to '
            'have observed a real scout window',
      );
      expect(
        ticks,
        greaterThanOrEqualTo(5),
        reason:
            'the event loop was frozen during scout: only $ticks 50ms '
            'ticks fired across ${sw.elapsedMilliseconds}ms',
      );
      expect(hellos, isA<List<Hello>>());
    });

    test('the tick instrument is sound (positive control)', () async {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => ticks++,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      timer.cancel();

      expect(
        ticks,
        greaterThanOrEqualTo(15),
        reason:
            'the 50ms timer under-counted on an idle event loop: $ticks '
            'ticks in 1000ms -- a failing liveness test would then be '
            'indicting the instrument, not the scout',
      );
    });
  });

  // CA2 S7: concurrent scouting is a state that could not exist before the
  // off-load -- the first call blocked the isolate, so a second could never be
  // started. Each call owns its own ReceivePort, Completer and heap blocks.
  group('Zenoh scout concurrency', () {
    Config quiet() =>
        Config()..insertJson5('scouting/multicast/enabled', 'false');

    test(
      'two overlapping scouts both complete with their own results',
      () async {
        final first = Zenoh.scout(config: quiet(), timeoutMs: 600);
        final second = Zenoh.scout(config: quiet(), timeoutMs: 600);

        final results = await Future.wait([first, second]);

        expect(results, hasLength(2));
        expect(results[0], isA<List<Hello>>());
        expect(results[1], isA<List<Hello>>());
        // Separate result instances -- a shared list would mean the two calls
        // were writing through the same context.
        expect(identical(results[0], results[1]), isFalse);
      },
    );

    test('a shorter scout finishes first, so the calls overlap', () async {
      final order = <String>[];
      final sw = Stopwatch()..start();

      final long = Zenoh.scout(
        config: quiet(),
        timeoutMs: 1500,
      ).then((h) => order.add('long'));
      final short = Zenoh.scout(
        config: quiet(),
        timeoutMs: 300,
      ).then((h) => order.add('short'));

      await Future.wait([long, short]);
      sw.stop();

      // Independence: the short scout completes first despite being started
      // second, which serialized calls could not produce.
      expect(order, equals(['short', 'long']));
      // Overlap: serialized calls would take at least 1500 + 300 = 1800ms.
      expect(
        sw.elapsedMilliseconds,
        lessThan(1700),
        reason:
            'the two scouts serialized instead of overlapping: '
            '${sw.elapsedMilliseconds}ms',
      );
      // ...and the long one really did run its full window, so a pair of
      // instant returns cannot pass this.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1400));
    });
  });

  // A6 (bucket-A fidelity): scout locators are marshalled PER ELEMENT as a
  // nested array of strings, not a ';'-joined blob split on the Dart side.
  //
  // CLASSIFICATION: GREEN-only / structural (reclassified from reproduce-first
  // RED after an in-suite spike, per the plan's confirm-or-reclassify gate).
  // The two conceptually bug-reproducing vectors are NOT stageable in-suite:
  //   * A locator containing ';' would be mis-split by the old split(';').
  //     But endpoint metadata (#key1=val1;key2=val2) is STRIPPED from the
  //     locator advertised in a scouted Hello (empirically confirmed:
  //     tcp/127.0.0.1:P#a=1;b=2 scouts as bare tcp/127.0.0.1:P), so no ';'
  //     can be driven into an advertised locator over loopback.
  //   * A lone empty-string locator would collapse to [] under the old
  //     `locatorsStr.isEmpty ? [] : ...` guard. But the only stageable empty
  //     case is ZERO locators (peer with no listen endpoints), which the old
  //     guard already rendered as [] correctly.
  // So these tests are structural/regression guards: they pass on both the old
  // and new code by design. They prove the per-element channel delivers full,
  // un-split, element-exact locator strings and that an empty set stays [].
  group('Zenoh scout locators (A6 per-element marshalling)', () {
    test(
      'single locator is delivered element-exact (not fragmented)',
      () async {
        final listenConfig = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17495"]')
          ..insertJson5('scouting/multicast/interface', '"lo"');
        final session = await Session.open(config: listenConfig);
        addTearDown(session.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        final scoutConfig = Config()
          ..insertJson5('scouting/multicast/interface', '"lo"');
        final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);

        final mine = hellos.firstWhere(
          (h) => h.locators.contains('tcp/127.0.0.1:17495'),
          orElse: () => throw TestFailure('configured peer not scouted'),
        );
        // The full locator arrives as a single, exact List<String> element --
        // a ';' inside a locator would likewise be preserved by construction
        // (the Dart side no longer calls split(';')).
        expect(mine.locators, contains('tcp/127.0.0.1:17495'));
        for (final loc in mine.locators) {
          expect(loc, isNot(contains(';')));
        }
      },
    );

    test('multiple locators are element-exact', () async {
      final listenConfig = Config()
        ..insertJson5(
          'listen/endpoints',
          '["tcp/127.0.0.1:17496", "tcp/127.0.0.1:17497"]',
        )
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final session = await Session.open(config: listenConfig);
      addTearDown(session.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final scoutConfig = Config()
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);

      final mine = hellos.firstWhere(
        (h) => h.locators.contains('tcp/127.0.0.1:17496'),
        orElse: () => throw TestFailure('configured peer not scouted'),
      );
      // Both listen endpoints surface as two distinct, full-string elements.
      expect(mine.locators, contains('tcp/127.0.0.1:17496'));
      expect(mine.locators, contains('tcp/127.0.0.1:17497'));
      expect(mine.locators.length, 2);
    });

    test('empty locator set is [] (not [""])', () async {
      // No listen endpoints -> the peer advertises an empty locator array.
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '[]')
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final session = await Session.open(config: listenConfig);
      addTearDown(session.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final scoutConfig = Config()
        ..insertJson5('scouting/multicast/interface', '"lo"');
      final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);

      final emptyPeer = hellos.firstWhere(
        (h) => h.whatami == WhatAmI.peer && h.locators.isEmpty,
        orElse: () => throw TestFailure('no empty-locator peer scouted'),
      );
      // Per-element marshalling makes a 0-element set distinct from a lone
      // empty-string element: [] rather than [''].
      expect(emptyPeer.locators, isEmpty);
      expect(emptyPeer.locators, isNot(contains('')));
    });
  });

  group('Zenoh scout memory safety', () {
    test(
      'scouting with a config survives a poisoning allocator',
      () async {
        // Regression guard for the consume ordering in Zenoh.scout.
        //
        // scout passes the config's native block to zd_scout as a captured int
        // address, and zd_scout dereferences it (z_config_move) for the whole
        // call -- while markConsumed frees that block. Marking before the call
        // is therefore a use-after-free, and a `nativePtr` grep cannot see it
        // through the address laundering.
        //
        // In-process this is silent: the freed 2008-byte block still holds
        // plausible bytes, so the suite stays green. MALLOC_PERTURB_ makes
        // glibc scribble over freed memory, which turns the UAF into a hard
        // abort -- verified: re-inverting the order aborts here with
        // "malloc(): unsorted double linked list corrupted", while the correct
        // order passes under the same poisoning. A subprocess is required
        // because MALLOC_PERTURB_ is read once at libc startup.
        // Raised from 5 iterations and made to alternate the user-config and
        // default-config branches: the off-load put a detached worker between
        // the Dart-side free and the native read, so both branches' heap
        // blocks now have to survive a boundary that did not exist before.
        const helperScript = '''
import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  Zenoh.initLog('error');
  for (var i = 0; i < 12; i++) {
    if (i.isEven) {
      final config = Config();
      config.insertJson5('scouting/multicast/enabled', 'false');
      await Zenoh.scout(config: config, timeoutMs: 100);
    } else {
      // The NULL-config branch builds its own config inside the worker block.
      await Zenoh.scout(timeoutMs: 100);
    }
  }
  print('SCOUT_OK');
}
''';

        final packageRoot = Directory.current.path;
        final tempDir = await Directory.systemTemp.createTemp('scout_uaf_');
        addTearDown(() => tempDir.delete(recursive: true));
        final tempScript = File('${tempDir.path}/scout_uaf.dart');
        await tempScript.writeAsString(helperScript);

        final result = await runToCompletion(
          Platform.resolvedExecutable,
          [
            'run',
            '--packages=$packageRoot/.dart_tool/package_config.json',
            tempScript.path,
          ],
          workingDirectory: packageRoot,
          environment: {'MALLOC_PERTURB_': '165'},
          timeout: const Duration(seconds: 90),
        );

        // The exit code is the assertion: a heap abort yields SIGABRT (-6), not
        // a test failure message. SCOUT_OK confirms the loop actually ran, so a
        // process that died early cannot pass for the wrong reason.
        expect(
          result.exitCode,
          equals(0),
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
        expect(result.stdout, contains('SCOUT_OK'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'overlapping scouts survive a poisoning allocator',
      () async {
        // The concurrent case, plus the narrow window the detached worker
        // creates at shutdown: the helper exits promptly after the last future
        // completes, while workers may still be dropping their config and
        // freeing their block. A double free of the hello context, a read of
        // the freed worker block, or a use-after-free of the config would
        // abort here rather than fail an assertion -- behavioural assertions
        // cannot see this defect class, so the exit code is the assertion.
        const helperScript = '''
import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  Zenoh.initLog('error');
  for (var round = 0; round < 3; round++) {
    final batch = <Future<List<Hello>>>[];
    for (var i = 0; i < 6; i++) {
      final config = Config();
      config.insertJson5('scouting/multicast/enabled', 'false');
      batch.add(Zenoh.scout(config: config, timeoutMs: 150));
    }
    await Future.wait(batch);
  }
  print('SCOUT_CONCURRENT_OK');
}
''';

        final packageRoot = Directory.current.path;
        final tempDir = await Directory.systemTemp.createTemp('scout_conc_');
        addTearDown(() => tempDir.delete(recursive: true));
        final tempScript = File('${tempDir.path}/scout_conc.dart');
        await tempScript.writeAsString(helperScript);

        final result = await runToCompletion(
          Platform.resolvedExecutable,
          [
            'run',
            '--packages=$packageRoot/.dart_tool/package_config.json',
            tempScript.path,
          ],
          workingDirectory: packageRoot,
          environment: {'MALLOC_PERTURB_': '165'},
          timeout: const Duration(seconds: 90),
        );

        expect(
          result.exitCode,
          equals(0),
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
        expect(result.stdout, contains('SCOUT_CONCURRENT_OK'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // Canon enumerates z_what_t as exactly {1,2,3,4,5,6,7} --
  // build/linux-x64/extern/zenoh-c/release/include/zenoh_commons.h:246-254.
  // Before the guard, `what` crossed into zd_scout unchecked, so 0, 8 and
  // every negative reached the native call as a raw bit pattern.
  group('Zenoh scout what-mask domain guard', () {
    Config quiet() =>
        Config()..insertJson5('scouting/multicast/enabled', 'false');

    test(
      'a mask outside canon 1..7 is refused before any native call',
      () async {
        for (final bad in [0, 8]) {
          // A live Config is the instrument for "nothing reached native":
          // scout consumes its config unconditionally once zd_scout is entered,
          // so a config still usable after the throw proves the guard fired
          // first and left the caller's config untouched.
          final config = quiet();
          addTearDown(config.dispose);

          await expectLater(
            Zenoh.scout(config: config, timeoutMs: 150, what: bad),
            throwsA(
              isA<ArgumentError>()
                  .having((e) => e.invalidValue, 'invalidValue', bad)
                  .having((e) => e.name, 'name', 'what')
                  .having((e) => e.toString(), 'toString', contains('$bad')),
            ),
            reason: 'what: $bad is outside canon z_what_t and must be refused',
          );

          expect(
            () => config.nativePtr,
            returnsNormally,
            reason:
                'the config was consumed for what: $bad, so the guard ran '
                'after the native call instead of before it',
          );
        }
      },
    );

    test('a negative mask is refused as a domain error', () async {
      // The shim signature is `int what`, cast to z_what_t before the call --
      // a Dart -1 would arrive as a bit pattern in an unsigned field rather
      // than as any value canon names. Guard it Dart-side.
      final config = quiet();
      addTearDown(config.dispose);

      await expectLater(
        Zenoh.scout(config: config, timeoutMs: 150, what: -1),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.invalidValue, 'invalidValue', -1)
              .having((e) => e.name, 'name', 'what')
              .having((e) => e.toString(), 'toString', contains('-1')),
        ),
      );

      expect(
        () => config.nativePtr,
        returnsNormally,
        reason: 'the config was consumed, so the negative mask reached native',
      );
    });

    test('every value canon enumerates is accepted', () async {
      // Multicast off and a short window keep this fast and LAN-independent;
      // a fresh Config per iteration because each scout consumes one.
      for (var what = 1; what <= 7; what++) {
        final hellos = await Zenoh.scout(
          config: quiet(),
          timeoutMs: 150,
          what: what,
        );
        expect(
          hellos,
          isA<List<Hello>>(),
          reason: 'what: $what is enumerated by canon and must be accepted',
        );
      }

      // The default is not observable from a call that passes `what`, so it
      // is read off the declaration; the uniqueness check keeps the anchor
      // honest against a second `int what = N,` appearing in the file.
      final source = File('lib/src/zenoh.dart').readAsStringSync();
      final matches = RegExp(
        r'^\s*int what = (\d+),$',
        multiLine: true,
      ).allMatches(source).toList();
      expect(
        matches,
        hasLength(1),
        reason:
            'the `what` parameter declaration was not found exactly once '
            'in lib/src/zenoh.dart',
      );
      expect(matches.single.group(1), equals('3'));
    });
  });
}
