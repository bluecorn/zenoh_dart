import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

void main() {
  group(
    'AdvancedPublisher',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session;

      setUpAll(() async {
        final config = Config()..insertJson5('timestamping/enabled', 'true');
        session = await Session.open(config: config);
      });

      tearDownAll(() {
        session.close();
      });

      test('declareAdvancedPublisher returns an AdvancedPublisher', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub',
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test('AdvancedPublisher.keyExpr returns the declared key expression', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub',
        );
        expect(publisher.keyExpr, equals('demo/example/adv-pub'));
        publisher.close();
      });

      test('AdvancedPublisher.close completes without error', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub',
        );
        expect(publisher.close, returnsNormally);
      });

      test('AdvancedPublisher.close is idempotent', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub',
        )..close();
        expect(publisher.close, returnsNormally);
      });

      test(
        'declareAdvancedPublisher on closed session throws StateError',
        () async {
          final closedConfig = Config()
            ..insertJson5('timestamping/enabled', 'true');
          final closedSession = await Session.open(config: closedConfig)
            ..close();
          expect(
            () =>
                closedSession.declareAdvancedPublisher('demo/example/adv-pub'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('closed'),
              ),
            ),
          );
        },
      );

      test(
        'declareAdvancedPublisher with invalid key expression throws '
        'ZenohException',
        () {
          expect(
            () => session.declareAdvancedPublisher(''),
            throwsA(isA<ZenohException>()),
          );
        },
      );

      test('declareAdvancedPublisher with default options succeeds', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-default',
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test('AdvancedPublisher.put publishes a string without error', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-put',
        );
        addTearDown(publisher.close);
        expect(() => publisher.put('Hello advanced'), returnsNormally);
      });

      test(
        'AdvancedPublisher.putBytes publishes ZBytes and consumes the payload',
        () {
          final publisher = session.declareAdvancedPublisher(
            'demo/example/adv-pub-putbytes',
          );
          addTearDown(publisher.close);
          final payload = ZBytes.fromString('raw data');
          expect(() => publisher.putBytes(payload), returnsNormally);
          expect(() => payload.nativePtr, throwsA(isA<StateError>()));
        },
      );

      test('AdvancedPublisher.deleteResource completes without error', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-del',
        );
        addTearDown(publisher.close);
        expect(publisher.deleteResource, returnsNormally);
      });

      test('AdvancedPublisher.put after close throws StateError', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-closed',
        )..close();
        expect(
          () => publisher.put('test'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
        );
      });

      test('All AdvancedPublisher operations after close throw StateError', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-closed-all',
        )..close();
        expect(
          () => publisher.putBytes(ZBytes.fromString('x')),
          throwsA(isA<StateError>()),
        );
        expect(publisher.deleteResource, throwsA(isA<StateError>()));
        expect(() => publisher.keyExpr, throwsA(isA<StateError>()));
      });
      // --- Options tests ---
      test('declareAdvancedPublisher with cache enabled succeeds', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-cache',
          options: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 10),
          ),
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test(
        'declareAdvancedPublisher with publisher detection enabled succeeds',
        () {
          final publisher = session.declareAdvancedPublisher(
            'demo/example/adv-pub-detect',
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          expect(publisher, isA<AdvancedPublisher>());
          publisher.close();
        },
      );

      test(
        'declareAdvancedPublisher with sample miss detection and periodic '
        'heartbeat succeeds',
        () {
          final publisher = session.declareAdvancedPublisher(
            'demo/example/adv-pub-miss',
            options: const AdvancedPublisherOptions(
              sampleMissDetection: true,
              heartbeatMode: HeartbeatMode.periodic,
              heartbeatPeriodMs: 500,
            ),
          );
          expect(publisher, isA<AdvancedPublisher>());
          publisher.close();
        },
      );

      test('declareAdvancedPublisher with all options enabled succeeds', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-all',
          options: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 5),
            publisherDetection: true,
            sampleMissDetection: true,
            heartbeatMode: HeartbeatMode.periodic,
            heartbeatPeriodMs: 500,
          ),
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test('HeartbeatMode enum has correct values', () {
        expect(HeartbeatMode.none.value, equals(0));
        expect(HeartbeatMode.periodic.value, equals(1));
        expect(HeartbeatMode.sporadic.value, equals(2));
      });

      // Renamed, not deleted: the cell is sound, its NAME carried the false
      // "unlimited" claim (the fifth GT-18 site). Zero's measured behaviour is
      // pinned in advanced_cache_test.dart, not asserted here.
      test('declareAdvancedPublisher with a zero cache limit succeeds', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-zero-cache',
          options: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 0),
          ),
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      // --- Seed #8 Slice 2: the cache options rework and its domain guard ---
      // The defect cured here: ONE nullable field carried TWO axes (enable +
      // limit), so `null` could not mean both "no cache" and "canon decides the
      // limit" -- which is what made `0` misreadable. Presence of the object
      // carries the enable axis; `maxSamples` carries the limit axis.

      test(
        "a cache options object with no limit enables the cache at canon's "
        'own default',
        () {
          final publisher = session.declareAdvancedPublisher(
            'demo/example/adv-pub-cache-unspec',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(),
            ),
          );
          // CONV-2: null means canon decides. The shim leaves
          // ze_advanced_publisher_cache_options_default's max_samples
          // untouched; that is observable in advanced_cache_test.dart.
          expect(publisher, isA<AdvancedPublisher>());
          publisher.close();
        },
      );

      test('no cache options object means no cache', () {
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-no-cache',
          options: const AdvancedPublisherOptions(),
        );
        // The enable axis is carried by presence alone; the absence is
        // observable in advanced_cache_test.dart.
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test('a negative limit throws ArgumentError with no native call', () {
        // CONV-4(a). Before this slice the same input coerced to a huge
        // unsigned bound and the declare SUCCEEDED -- the legitimate-looking
        // wrong outcome.
        expect(
          () => session.declareAdvancedPublisher(
            'demo/example/adv-pub-neg-cache',
            options: const AdvancedPublisherOptions(
              cache: AdvancedPublisherCacheOptions(maxSamples: -1),
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('maxSamples'),
            ),
          ),
        );
      });

      test('zero is accepted and reaches canon', () {
        // CONV-4(b) and seed #5's strict-parity ground: rejecting it would
        // narrow canon's surface on no canon-intrinsic ground. Its BEHAVIOUR is
        // pinned in advanced_cache_test.dart; this cell pins expressibility.
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-zero',
          options: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 0),
          ),
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });

      test('a large in-domain limit is carried full-width', () {
        // CONV-4(c). 2^32 is the value a 32-bit truncation would turn into a
        // WORKING 0 -- a silent transform, not a visible failure. On an ILP32
        // target the shim's #if SIZE_MAX < INT64_MAX guard returns
        // ZD_DECLARE_ECAPACITY and this surfaces as ZenohException; that arm
        // has no driver on a 64-bit test host and is stated, not skipped.
        final publisher = session.declareAdvancedPublisher(
          'demo/example/adv-pub-wide-cache',
          options: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 4294967296),
          ),
        );
        expect(publisher, isA<AdvancedPublisher>());
        publisher.close();
      });
    },
  ); // AdvancedPublisher group

  // --- Seed #8 Slice 4: AdvancedPublisher.hasMatchingSubscribers() --------
  //
  // The advanced publisher was the odd one out on its own sibling surface:
  // plain `Publisher` and `Querier` can both ask whether anyone is listening,
  // and the advanced form could not. This is a third consumer of a bridge that
  // already had two; canon's closure type is identical, only the loaned handle
  // type differs.
  group(
    'AdvancedPublisher matching status (TCP 19403)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session1;
      late Session session2;

      setUpAll(() async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19403"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        session1 = await Session.open(config: config1);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19403"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        session2 = await Session.open(config: config2);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        session2.close();
        session1.close();
      });

      test('false with no matching subscriber', () {
        // The controlled negative. Multicast and gossip are off on both
        // sessions, so this asserts isolation rather than asserting that the
        // LAN happened to be quiet.
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/adv-match/lonely',
        );
        addTearDown(publisher.close);
        expect(publisher.hasMatchingSubscribers(), isFalse);
      });

      test('true with a live matching advanced subscriber', () async {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/adv-match/paired',
        );
        addTearDown(publisher.close);
        expect(
          publisher.hasMatchingSubscribers(),
          isFalse,
          reason: 'the transition has to start from false to mean anything',
        );

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/adv-match/paired',
        );
        addTearDown(subscriber.close);

        // Polled, never asserted after a bare sleep: matching propagates
        // across the wire and the wait is a race, not settle time.
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        var matching = false;
        while (!matching && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          matching = publisher.hasMatchingSubscribers();
        }
        expect(matching, isTrue);
      });

      test('the poll on a closed publisher throws StateError', () {
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/adv-match/closed',
        )..close();
        // The Dart-side _ensureOpen() guard fires before any native call --
        // the same shape every other member on this class uses, and the reason
        // the rc-failure arm has no driver (see the note below).
        expect(publisher.hasMatchingSubscribers, throwsA(isA<StateError>()));
      });

      // ⚠️ THE rc != 0 ARM HAS NO MEASURED DRIVER, and this note is the cell.
      //
      // Recorded here rather than in a PR body because this is where a reader
      // counting the cells would otherwise notice the gap and assume an
      // oversight. Both candidate drivers are shadowed by a guard that fires
      // first: a post-close call hits the Dart-side `_ensureOpen()` above, and
      // a stable native hits `requireUnstable()` inside
      // `declareAdvancedPublisher`, so the publisher this arm needs can never
      // be constructed on the leg where the native could fail.
      //
      // What IS gate-reviewable, and what the implementation therefore has to
      // carry, in `advanced_publisher.dart`:
      //   * the `calloc<Int>()` out-param is allocated LAST, after the
      //     `_ensureOpen()` guard and after the loan;
      //   * it is freed in a `finally` that ENCLOSES every statement that can
      //     throw, the rc check included;
      //   * rc != 0 maps to `ZenohException` carrying canon's own code;
      //   * the shim writes `*matching` only on rc 0, matching canon's own
      //     documented contract that the out-struct is not updated on error.
      //
      // If a real driver is ever found, pin it — that is a bonus, not an
      // obligation the absence of which weakens the cells above.
    },
  );

  // --- Seed #8 Slice 5: AdvancedPublisher.matchingStatus ------------------
  //
  // The opt-in background matching listener, surfaced as a nullable
  // Stream<bool> exactly as `Publisher` and `Querier` already do. The opt-in
  // rides the options object rather than a named parameter, because this class
  // is configured only through options and its sibling capability
  // (`enableMissListener` on the subscriber side) already lives there.
  group(
    'AdvancedPublisher matchingStatus (TCP 19404-19405)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('the stream is null when the listener is not enabled', () async {
        final config = Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session = await Session.open(config: config);
        addTearDown(session.close);

        final publisher = session.declareAdvancedPublisher(
          'zenoh/dart/adv-match-stream/off',
          options: const AdvancedPublisherOptions(),
        );
        addTearDown(publisher.close);
        expect(publisher.matchingStatus, isNull);
      });

      test('the stream exists when the listener is enabled', () async {
        final config = Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session = await Session.open(config: config);
        addTearDown(session.close);

        final publisher = session.declareAdvancedPublisher(
          'zenoh/dart/adv-match-stream/on',
          options: const AdvancedPublisherOptions(
            enableMatchingListener: true,
          ),
        );
        addTearDown(publisher.close);
        expect(publisher.matchingStatus, isA<Stream<bool>>());
      });

      test('true on the first matching subscriber, false when the last '
          'departs', () async {
        final config1 = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19404"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session1 = await Session.open(config: config1);
        addTearDown(session1.close);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final config2 = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19404"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session2 = await Session.open(config: config2);
        addTearDown(session2.close);

        await Future<void>.delayed(const Duration(seconds: 1));

        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/adv-match-stream/transition',
          options: const AdvancedPublisherOptions(
            enableMatchingListener: true,
          ),
        );
        addTearDown(publisher.close);

        final seen = <bool>[];
        final sub = publisher.matchingStatus!.listen(seen.add);
        addTearDown(sub.cancel);

        // The transition PAIR is the fidelity cell for this value path: the
        // shim posts int64 0/1 and Dart decodes `!= 0`, so observing both
        // directions of canon's one-field bool struct is what proves the
        // decode rather than assuming it.
        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/adv-match-stream/transition',
        );

        var deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!seen.contains(true) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          seen,
          contains(true),
          reason:
              'canon: "the first subscriber '
              'connects"',
        );

        subscriber.close();

        deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!seen.contains(false) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          seen,
          contains(false),
          reason:
              'canon: "if last subscriber '
              'disconnects"',
        );
        // Order matters: false must FOLLOW true, or the stream is reporting
        // something other than the transition it claims to.
        expect(seen.indexOf(true), lessThan(seen.lastIndexOf(false)));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('the stream completes when the publisher closes', () async {
        final config = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19405"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session = await Session.open(config: config);
        addTearDown(session.close);

        final publisher = session.declareAdvancedPublisher(
          'zenoh/dart/adv-match-stream/close',
          options: const AdvancedPublisherOptions(
            enableMatchingListener: true,
          ),
        );

        var done = false;
        final sub = publisher.matchingStatus!.listen(
          (_) {},
          onDone: () => done = true,
        );
        addTearDown(sub.cancel);

        // The pre-state, or the completion below proves nothing: a stream that
        // was ALREADY complete when the listener attached fires onDone at once
        // and passes this cell without close() having done anything.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(done, isFalse, reason: 'the stream must be live before close');

        publisher.close();

        // Entity-scoped terminal shape, the same one the shipped missEvents
        // has. The SESSION-close behaviour of this stream is deliberately not
        // asserted: it is seed #11's routed contract question.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!done && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(done, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      // Slice 9 Test 4: the matching stream's entity-close contract is
      // already pinned by 'the stream completes when the publisher closes'
      // above -- entity-scoped, no sentinel, the same terminal shape as the
      // shipped missEvents. Its SESSION-close behaviour is seed #11's routed
      // question and is deliberately not asserted anywhere in this file.

      // ⚠️ THE DECLARE-FAILURE PATH HAS NO MEASURED DRIVER either (the same
      // shadowing as Slice 4's rc arm), so it is verified structurally at the
      // gate. What the implementation must carry, in `advanced_publisher.dart`:
      // on a non-zero rc from the matching-listener declare, the matching port
      // and controller are closed, the native publisher is dropped and its
      // slot freed, and only then is the exception thrown — the shipped
      // second-listener teardown template (`advanced_subscriber.dart:127-135`,
      // `publisher.dart:89-95`). Nothing is left behind on the failing path.
      //
      // Flagged for seed #11's affected-type census: this seed adds ONE more
      // entity-scoped stream (this one) to the set whose session-close
      // contract #11 owns. The detect stream is NOT in that set — its
      // session-close completion is decided in-seed on the shipped sentinel.
    },
  );

  // --- Seed #8 Slice 2 Test 6: the removed field is gone from the surface ---
  //
  // The breaking change has to be COMPLETE: never both carriages for one
  // capability (CONV-2b), so no legacy `cacheMaxSamples` alias may survive.
  // "It does not compile" is only measurable by compiling, so this cell runs
  // the analyzer over two snippets and reads both answers.
  //
  // The second snippet is the CONTROL, and it is what makes the first mean
  // anything: if package resolution were broken, BOTH legs would error and the
  // red leg would pass for the wrong reason. The control's clean exit proves
  // the analyzer resolved `package:zenoh_dart` and understood the class.
  group(
    'AdvancedPublisherOptions surface (analyzer)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Directory tmp;

      // Under `.dart_tool/` deliberately: the analyzer skips dot-directories
      // when it walks a tree, so a crashed run cannot leave a deliberately
      // broken file where `dart analyze package` would later find it. Package
      // resolution still works -- it walks UP to package/.dart_tool/.
      setUpAll(() {
        tmp = Directory(
          '.dart_tool',
        ).createTempSync('seed8_surface_');
      });

      tearDownAll(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      Future<ProcessResult> analyze(String name, String body) async {
        final f = File('${tmp.path}/$name')..writeAsStringSync(body);
        // --no-fatal-warnings so only ERRORS decide the exit code; there is
        // no --no-fatal-infos (infos are non-fatal unless opted in).
        return Process.run(Platform.resolvedExecutable, [
          'analyze',
          '--no-fatal-warnings',
          f.path,
        ]);
      }

      test('naming cacheMaxSamples no longer compiles', () async {
        final r = await analyze('legacy.dart', '''
import 'package:zenoh_dart/zenoh_unstable.dart';
const options = AdvancedPublisherOptions(cacheMaxSamples: 5);
''');
        expect(r.exitCode, isNot(0), reason: 'stdout: ${r.stdout}');
        expect('${r.stdout}', contains('cacheMaxSamples'));
      });

      test('the control: naming cache compiles clean', () async {
        final r = await analyze('reworked.dart', '''
import 'package:zenoh_dart/zenoh_unstable.dart';
const options = AdvancedPublisherOptions(
  cache: AdvancedPublisherCacheOptions(maxSamples: 5),
);
''');
        // Clean exit proves package resolution worked, so the red leg above
        // errored on the removed field and not on an unresolved import.
        expect(r.exitCode, equals(0), reason: 'stdout: ${r.stdout}');
        expect('${r.stdout}', isNot(contains('cacheMaxSamples')));
      });
    },
  );
}
