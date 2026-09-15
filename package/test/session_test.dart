import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/query.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/zenoh.dart';

import 'helpers/canon_zid.dart';

void main() {
  group('Session lifecycle', () {
    test('open session with default config', () async {
      final session = await Session.open();
      expect(session, isA<Session>());
      session.close();
    });

    test('open session with explicit config', () async {
      final config = Config()..insertJson5('mode', '"peer"');

      final session = await Session.open(config: config);
      expect(session, isA<Session>());

      // Verify config is consumed by checking that further use throws
      expect(
        () => config.insertJson5('mode', '"peer"'),
        throwsA(isA<StateError>()),
      );

      session.close();
    });

    test('close session gracefully', () async {
      final session = await Session.open();
      expect(session.close, returnsNormally);
    });

    test('close session is idempotent (double-close safe)', () async {
      final session = await Session.open()
        ..close();
      expect(session.close, returnsNormally);
    });

    test('reusing consumed Config throws StateError', () async {
      final config = Config();
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

      session.close();
    });
  });

  group('Session.isClosed (F10)', () {
    test('open session reports not closed', () async {
      final session = await Session.open();
      expect(session.isClosed, isFalse);
      session.close();
    });

    test('closed session reports closed', () async {
      final session = await Session.open()
        ..close();
      expect(session.isClosed, isTrue);
    });

    test(
      'isClosed is safe to call after close (no freed-pointer deref)',
      () async {
        final session = await Session.open()
          ..close();
        // Repeated reads must short-circuit on the Dart-side _closed flag and
        // never deref the freed native handle.
        expect(session.isClosed, isTrue);
        expect(session.isClosed, isTrue);
        expect(session.isClosed, isTrue);
      },
    );
  });

  group('Put and delete operations', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('put succeeds with valid key expression', () {
      expect(() => session.put('demo/example/test', 'hello'), returnsNormally);
    });

    test('putBytes succeeds and consumes the payload', () {
      final payload = ZBytes.fromString('hello bytes');
      session.putBytes('demo/example/test', payload);
      // Payload should be consumed -- toStr() should throw
      expect(
        payload.toStr,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test('put with invalid key expression throws ZenohException', () {
      expect(() => session.put('', 'hello'), throwsA(isA<ZenohException>()));
    });

    test('putBytes with already-disposed ZBytes throws StateError', () {
      final payload = ZBytes.fromString('disposable')..dispose();
      expect(
        () => session.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    test('putBytes with already-consumed ZBytes throws StateError', () {
      final payload = ZBytes.fromString('consume me');
      session.putBytes('demo/example/test', payload);
      expect(
        () => session.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test('put on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.put('demo/example/test', 'hello'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('putBytes on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      final payload = ZBytes.fromString('hello');
      expect(
        () => closedSession.putBytes('demo/example/test', payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      payload.dispose();
    });

    test('deleteResource succeeds with valid key expression', () {
      expect(
        () => session.deleteResource('demo/example/test'),
        returnsNormally,
      );
    });

    test('deleteResource on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.deleteResource('demo/example/test'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('deleteResource on non-existent key succeeds', () {
      // fire-and-forget semantics -- no error even if no data published
      expect(
        () => session.deleteResource('demo/example/nonexistent'),
        returnsNormally,
      );
    });

    test(
      'deleteResource with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.deleteResource(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  });

  group('Session info', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('zid returns non-zero ZenohId with 16 bytes', () {
      final zid = session.zid;
      expect(zid, isA<ZenohId>());
      expect(zid.bytes.length, equals(16));
      // At least one byte should be non-zero
      expect(zid.bytes.any((b) => b != 0), isTrue);
    });

    test('zid is consistent across multiple accesses', () {
      final zid1 = session.zid;
      final zid2 = session.zid;
      expect(zid1, equals(zid2));
    });

    test('zid.toHexString returns non-empty hex string', () {
      final zid = session.zid;
      final hex = zid.toHexString();
      expect(hex, isNotEmpty);
      // RE-PINNED at seed #9, to canon's CONTRACT rather than to a width.
      //
      // This line read `expect(hex.length, equals(32))`. Under the canon-form
      // rendering a live zid is 32 digits 15 times in 16 and 31 digits 1 time
      // in 16, so re-pinning the width to 31 or 32 would buy a 94% green --
      // the same 1-in-16 hazard this corpus has already been bitten by twice
      // on this exact surface.
      //
      // canonZidPattern is zenoh's own definition (1-32 lowercase hex digits,
      // never a leading '0' -- "Leading 0s are not valid"), so it holds for
      // every draw.
      expect(hex, matches(canonZidPattern));
    });

    test('zid on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.zid,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('routersZid on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        closedSession.routersZid,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('peersZid on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        closedSession.peersZid,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });
  });

  // F12 rc-hygiene (Slice 2): the five bare z_*/zc_* calls that returned a
  // discarded z_result_t are now each rc-checked and either propagated or
  // deliberately handled with a rationale comment. The five sites are:
  //   1. zd_init_log        -> zc_init_log_from_env_or (void fn, best-effort)
  //   2. zd_close_session   -> z_close (void fn, best-effort teardown)
  //   3. zd_info_routers_zid-> z_info_routers_zid (returns -1 on failure)
  //   4. zd_info_peers_zid  -> z_info_peers_zid   (returns -1 on failure)
  //   5. zd_scout fallback  -> z_config_default before z_scout
  // Acceptance is primarily static; these tests are happy-path regression
  // guards proving the added rc-checks changed no observable behavior. Since
  // the zid collectors now return -1 on failure, session.dart::_collectZids
  // treats a negative count as an empty list (guards asTypedList(negative)).
  group('F12 rc-hygiene regression (Slice 2)', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('routersZid happy path returns a valid list (sites 3+4)', () {
      final routers = session.routersZid();
      final peers = session.peersZid();
      expect(routers, isA<List<ZenohId>>());
      expect(peers, isA<List<ZenohId>>());
      // A well-formed (non-negative-count) result: every id is 16 bytes.
      for (final id in routers) {
        expect(id.bytes.length, equals(16));
      }
      for (final id in peers) {
        expect(id.bytes.length, equals(16));
      }
    });

    test('initLog is unchanged after rc-check (site 1)', () {
      expect(() => Zenoh.initLog('error'), returnsNormally);
    });

    test('close is idempotent after rc-check (site 2)', () async {
      final s = await Session.open();
      expect(s.close, returnsNormally);
      expect(s.close, returnsNormally);
    });
  });

  group('Session peer discovery', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Scouting off in both sessions. With multicast on, two same-host peers
      // discover each other regardless of the endpoints under test, so the
      // assertions below would green even if the configured TCP path were
      // broken -- they would prove the peers found *some* route. Disabling
      // discovery makes them assert what their names claim. (The A9 group in
      // this file already carries the pattern.)
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17460"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session1 = await Session.open(config: config1);

      // Wait for listener to bind
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17460"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session2 = await Session.open(config: config2);

      // Wait for link establishment
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('two connected sessions see each other as peers', () {
      final peers1 = session1.peersZid();
      final peers2 = session2.peersZid();

      expect(
        peers1.contains(session2.zid),
        isTrue,
        reason: 'session1 should see session2 as a peer',
      );
      expect(
        peers2.contains(session1.zid),
        isTrue,
        reason: 'session2 should see session1 as a peer',
      );
    });

    test('two connected sessions have different ZIDs', () {
      expect(session1.zid, isNot(equals(session2.zid)));
    });
  });

  group('Session put attachment + encoding (send)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17470"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17470"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('putBytes delivers binary attachment byte-exact', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/bin-att');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final payload = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      session1.putBytes(
        'zenoh/dart/put/bin-att',
        ZBytes.fromUint8List(payload),
        attachment: ZBytes.fromUint8List(
          Uint8List.fromList([0xFF, 0xFE, 0x80]),
        ),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(payload));
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('put sets encoding received faithfully', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/enc');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(
        'zenoh/dart/put/enc',
        'hello',
        encoding: Encoding.applicationJson,
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.encoding, equals('application/json'));
    });

    test('valid custom encoding round-trips faithfully', () async {
      final subscriber = session2.declareSubscriber(
        'zenoh/dart/put/enc-custom',
      );
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put(
        'zenoh/dart/put/enc-custom',
        'hello',
        encoding: const Encoding('application/vnd.dart.test'),
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      // No silent substitution: the custom MIME survives the rc-checked path.
      expect(sample.encoding, contains('application/vnd.dart.test'));
    });

    test('putBytes marks attachment consumed on success', () {
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      session1.putBytes(
        'zenoh/dart/put/consume',
        ZBytes.fromString('payload'),
        attachment: attachment,
      );
      // Attachment ownership moved to zenoh-c -- use-after-move must throw.
      expect(
        attachment.toBytes,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('consumed'),
          ),
        ),
      );
    });

    test('putBytes on invalid keyexpr is a pre-move early-return '
        '(attachment NOT consumed, caller retains ownership)', () {
      final attachment = ZBytes.fromUint8List(
        Uint8List.fromList([0xFF, 0xFE, 0x80]),
      );
      // An invalid key expression fails in the KeyExpr constructor BEFORE
      // zd_put runs, so z_bytes_move never gravestones the attachment.
      // Per the markConsumed discipline, a genuine pre-move early-return
      // must NOT mark consumed -- the caller still owns the ZBytes.
      expect(
        () => session1.putBytes(
          '',
          ZBytes.fromString('payload'),
          attachment: attachment,
        ),
        throwsA(isA<ZenohException>()),
      );
      // Still owned: reading and disposing it must succeed (no use-after-move).
      expect(attachment.toBytes(), equals([0xFF, 0xFE, 0x80]));
      attachment.dispose();
    });

    test('absent attachment/encoding behaves as before', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/absent');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/put/absent', 'plain');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.payloadBytes, equals(utf8.encode('plain')));
      expect(sample.attachmentBytes, isNull);
      // Default encoding still present (existing behavior unchanged).
      expect(sample.encoding, isNotNull);
    });
  });

  group('Session put/delete timestamp (send)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17535"]');
      session1 = await Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17535"]');
      session2 = await Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('put timestamp round-trips bit-exact', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/ts');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      session1.put('zenoh/dart/put/ts', 'hello', timestamp: ts);

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp, equals(ts));
      // NTP64 time AND id bit-exact (the whole 24 bytes).
      expect(sample.timestamp!.time, equals(ts.time));
      expect(sample.timestamp!.id, equals(ts.id));
    });

    test('deleteResource carries a timestamp', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/del/ts');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      session1.deleteResource('zenoh/dart/del/ts', timestamp: ts);

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.kind, equals(SampleKind.delete));
      expect(sample.timestamp, equals(ts));
    });

    test('put without a timestamp yields null on receive', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/put/no-ts');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/put/no-ts', 'hello');

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNull);
    });

    test('putBytes accepts the same timestamp param (bit-exact)', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/putbytes/ts');
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      final ts = session1.newTimestamp();
      session1.putBytes(
        'zenoh/dart/putbytes/ts',
        ZBytes.fromString('hello'),
        timestamp: ts,
      );

      final sample = await subscriber.stream.first.timeout(
        const Duration(seconds: 5),
      );

      expect(sample.timestamp, isNotNull);
      expect(sample.timestamp, equals(ts));
      expect(sample.timestamp!.time, equals(ts.time));
      expect(sample.timestamp!.id, equals(ts.id));
    });
  });

  // Slice 6 (A8): get() must honor the config default query timeout when no
  // explicit timeout is given. zenoh-c `timeout_ms = 0` means "use the
  // configuration's default query timeout" (zenoh_commons.h:1039); the C++ peer
  // defaults GetOptions.timeout_ms = 0 (session.hxx:299). Our get() instead
  // hardcoded `const Duration(seconds: 10)`, silently overriding the config.
  //
  // Spike-CONFIRMED (reproduce-first RED): the config key is the top-level
  // `queries_default_timeout` (milliseconds). It is NOT
  // `queries_default_timeout` inside any vendored extern header (that string
  // lives in the unvendored zenoh Rust config), but
  // Config.insertJson5('queries_default_timeout', '<ms>') is accepted and
  // honored. The timeout only *governs* when a matching but non-replying
  // queryable exists (with no matching queryable, zenoh finalizes the query
  // immediately). So each test connects a second peer whose queryable matches
  // the selector and HOLDS queries without replying, forcing get() to wait
  // the full timeout before its reply stream closes. All waits are bounded at
  // <= ~2.5 s (never the full 10 s).
  group('Session.get config default timeout (A8)', () {
    // Test 1: no explicit timeout honors the small config default.
    // RED (current 10 s hardcode): the reply stream is still open at ~2 s, so
    // .toList().timeout(2 s) throws TimeoutException -> test fails.
    // GREEN (wire 0 -> config default): closes at ~300 ms -> elapsed < 1500 ms.
    test(
      'no explicit timeout honors the config default query timeout',
      () async {
        final sessionA = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17495"]')
            ..insertJson5('queries_default_timeout', '300'),
        );
        addTearDown(sessionA.close);
        final sessionB = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17495"]'),
        );
        addTearDown(sessionB.close);

        final held = <Query>[];
        final queryable = sessionB.declareQueryable('zenoh/dart/a8/**');
        addTearDown(queryable.close);
        // Match the selector but never reply: get() must wait for the timeout.
        queryable.stream.listen(held.add);
        addTearDown(() {
          for (final q in held) {
            q.dispose();
          }
        });

        await Future<void>.delayed(const Duration(milliseconds: 700));

        final sw = Stopwatch()..start();
        await sessionA
            .get('zenoh/dart/a8/timeout/thing')
            .toList()
            .timeout(const Duration(seconds: 2));
        sw.stop();

        // Two-sided, and both sides do work. The upper bound rules out the
        // old 10 s override. The lower bound rules out the opposite failure:
        // an elapsed of ~0 means the query finalized without the timeout ever
        // governing -- which is what happens if the 700 ms propagation wait
        // above loses its race and no matching queryable was discovered. With
        // an upper bound alone, that vacuous run reads as a pass.
        //
        // Calibrated to this test's own config default (300 ms), not to
        // Test 3's (800 ms): a 400 ms floor copied from the sibling would fail
        // on correct behavior here.
        expect(sw.elapsedMilliseconds, greaterThan(150));
        expect(sw.elapsedMilliseconds, lessThan(1500));
      },
    );

    // Test 2: explicit timeout is passed through unchanged (regression guard;
    // passes with or without the fix, since the explicit path always honored
    // it).
    test('explicit timeout is respected', () async {
      final sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17496"]'),
      );
      addTearDown(sessionA.close);
      final sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17496"]'),
      );
      addTearDown(sessionB.close);

      final held = <Query>[];
      final queryable = sessionB.declareQueryable('zenoh/dart/a8b/**');
      addTearDown(queryable.close);
      queryable.stream.listen(held.add);
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 700));

      final sw = Stopwatch()..start();
      await sessionA
          .get(
            'zenoh/dart/a8b/timeout/thing',
            timeout: const Duration(milliseconds: 200),
          )
          .toList()
          .timeout(const Duration(seconds: 2));
      sw.stop();

      // Same two-sided reasoning as Test 1, calibrated to this test's own
      // explicit 200 ms timeout: without a floor, a get that finalized
      // immediately (no queryable discovered) passes while proving nothing
      // about pass-through.
      expect(sw.elapsedMilliseconds, greaterThan(100));
      expect(sw.elapsedMilliseconds, lessThan(1200));
    });

    // Test 3: null timeout maps to wire 0 -> the *config* value governs.
    // Uses a DISTINCT config default (800 ms) to prove the wired value tracks
    // the configuration (not a coincidental hardcode, not the 200 ms explicit
    // value, not the old 10 s). RED (current 10 s): still open at ~2 s ->
    // TimeoutException. GREEN: closes near 800 ms, inside the [400, 1900)
    // window.
    test(
      'null timeout delegates to the config value (distinct default)',
      () async {
        final sessionA = await Session.open(
          config: Config()
            ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17497"]')
            ..insertJson5('queries_default_timeout', '800'),
        );
        addTearDown(sessionA.close);
        final sessionB = await Session.open(
          config: Config()
            ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17497"]'),
        );
        addTearDown(sessionB.close);

        final held = <Query>[];
        final queryable = sessionB.declareQueryable('zenoh/dart/a8c/**');
        addTearDown(queryable.close);
        queryable.stream.listen(held.add);
        addTearDown(() {
          for (final q in held) {
            q.dispose();
          }
        });

        await Future<void>.delayed(const Duration(milliseconds: 700));

        final sw = Stopwatch()..start();
        await sessionA
            .get('zenoh/dart/a8c/timeout/thing')
            .toList()
            .timeout(const Duration(milliseconds: 2500));
        sw.stop();

        // Governed by the 800 ms config default: not the ~10 s hardcode, and
        // demonstrably longer than the 200 ms explicit value of Test 2.
        expect(sw.elapsedMilliseconds, greaterThan(400));
        expect(sw.elapsedMilliseconds, lessThan(1900));
      },
    );
  });

  // A9, DISCHARGED (seed #9). The cap this group was named for no longer
  // exists: `_collectZids` used to fill a fixed buffer -- 64 slots, then 1024
  // -- and silently drop everything past it. The collection is now unbounded,
  // into a shim-owned buffer that grows by realloc inside canon's closure, so
  // there is no constant left to guard and no truncation left to bound. The
  // register debt the old comment recorded ("true-unbounded parity with the
  // cpp `std::vector<Id>` collector") is paid.
  //
  // The group is KEPT, not retired: it is the oldest linked-topology guard on
  // this path and it exercises the reworked collector through the shipped
  // public surface. Its exactness and growth-ladder successors live in
  // test/zid_collection_test.dart; what stays here is the regression guard.
  //
  // The name keeps its A9 tag so the register row remains locatable.
  group('Session zid collection cap (A9)', () {
    late Session session1;
    late Session session2;
    late Session session3;

    // Multicast scouting is disabled on every session in this group: the
    // topology here is explicit TCP links, so discovery adds nothing, while
    // multicast lets real peers on the developer's LAN join these sessions and
    // appear in the collected zid lists. Left on, these tests assert the
    // network is quiet rather than asserting anything about the collector.
    setUpAll(() async {
      final config1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17540"]')
        ..insertJson5('scouting/multicast/enabled', 'false');
      session1 = await Session.open(config: config1);

      // Wait for listener to bind.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17540"]')
        ..insertJson5('scouting/multicast/enabled', 'false');
      session2 = await Session.open(config: config2);

      final config3 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17540"]')
        ..insertJson5('scouting/multicast/enabled', 'false');
      session3 = await Session.open(config: config3);

      // Wait for link establishment / mutual discovery.
      await Future<void>.delayed(const Duration(seconds: 2));
    });

    tearDownAll(() {
      session3.close();
      session2.close();
      session1.close();
    });

    // Test 1 (functional regression guard): three connected peers on loopback;
    // the collection (now larger-capped) still returns the reachable peers.
    test('small-N peers are all returned', () {
      final peers1 = session1.peersZid();

      expect(
        peers1.contains(session2.zid),
        isTrue,
        reason: 'session1 should see session2 as a peer',
      );
      expect(
        peers1.contains(session3.zid),
        isTrue,
        reason: 'session1 should see session3 as a peer',
      );
      // Correct values: every returned id is one of the other two peers.
      final others = {session2.zid, session3.zid};
      for (final p in peers1) {
        expect(others.contains(p), isTrue, reason: 'unexpected peer id $p');
      }
    });

    // Test 2 (edge): an isolated session has no connected peers; the negative-
    // count/empty rc-hygiene (F12) yields an empty list without throwing.
    test('zero connected peers returns an empty list', () async {
      // The isolation must be configured, not assumed: a default-config session
      // scouts multicast and adopts whatever peers the LAN offers, which made
      // this assert "the network is quiet" instead of "the session is alone".
      final isolatedConfig = Config()
        ..insertJson5('scouting/multicast/enabled', 'false');
      final isolated = await Session.open(config: isolatedConfig);
      addTearDown(isolated.close);

      expect(isolated.peersZid(), isEmpty);
      expect(isolated.routersZid(), isEmpty);
    });
  });

  // R3: routersZid CONTENT, against a router this test brings itself.
  //
  // routersZid was covered only for shape -- 'routersZid happy path returns a
  // valid list' asserts isA<List<ZenohId>> and then loops over the result
  // checking each id is 16 bytes. On a default peer session with no router
  // reachable that list is empty, so the loop body never executes and the test
  // reduces to "the call returned a list". An implementation returning a fixed
  // empty list passes it.
  //
  // The reason nothing pinned content is that it needs a router, and the suite
  // has no zenohd. It does not need one: a zenoh session opened with
  // `mode: "router"` IS a router, so the test brings its own rather than
  // assuming the developer's machine has one running -- which would make the
  // result depend on the environment, and would go red on CI for the wrong
  // reason.
  //
  // Discovery is off on all three sessions, so every relationship asserted
  // below is one the configured endpoints created.
  group('Session routersZid content against an owned router (TCP 18810)', () {
    late Session router;
    late Session client;
    late Session peer;

    Config linked(String mode, String endpointKey) => Config()
      ..insertJson5('mode', '"$mode"')
      ..insertJson5(endpointKey, '["tcp/127.0.0.1:18810"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');

    setUpAll(() async {
      router = await Session.open(config: linked('router', 'listen/endpoints'));
      await Future<void>.delayed(const Duration(milliseconds: 800));

      client = await Session.open(
        config: linked('client', 'connect/endpoints'),
      );
      peer = await Session.open(config: linked('peer', 'connect/endpoints'));

      // Both attach to the router before anything is collected.
      await Future<void>.delayed(const Duration(seconds: 2));
    });

    tearDownAll(() {
      peer.close();
      client.close();
      router.close();
    });

    test('a client reports exactly the router it is attached to', () {
      final routers = client.routersZid();

      expect(routers, hasLength(1));
      expect(routers.single, equals(router.zid));
      // Not merely "some 16 bytes came back": it is the id of the session this
      // test started, which no fixed or fabricated value can match.
      expect(routers.single.toHexString(), equals(router.zid.toHexString()));
    });

    test('a peer attached to a router reports it too', () {
      final routers = peer.routersZid();

      expect(routers, hasLength(1));
      expect(routers.single, equals(router.zid));
    });

    // The negative half, with the positives above as its control: routersZid
    // reports routers and nothing else. A collector that returned every known
    // session would fail here while passing both tests above.
    test('routersZid excludes non-router sessions', () {
      // The router itself knows no other router.
      expect(router.routersZid(), isEmpty);

      // Neither the client nor the peer appears in anyone's router list.
      final known = {...client.routersZid(), ...peer.routersZid()};
      expect(known, isNot(contains(client.zid)));
      expect(known, isNot(contains(peer.zid)));
      expect(known, equals({router.zid}));
    });

    // peersZid is the sibling collector over the same transport state, and the
    // split between the two is the thing worth pinning: attached clients and
    // peers land in different lists, and neither lands in both.
    test('peersZid and routersZid partition the router topology', () {
      // From the router: the peer is a peer; the client is not listed as one.
      final routerPeers = router.peersZid();
      expect(routerPeers, contains(peer.zid));
      expect(routerPeers, isNot(contains(client.zid)));
      expect(routerPeers, isNot(contains(router.zid)));

      // From the leaves: the router is in routersZid, and peersZid is empty --
      // they know each other only through the router, not directly.
      expect(client.peersZid(), isEmpty);
      expect(peer.peersZid(), isEmpty);
    });
  });

  // Layer-1 open-error enrichment. The message a failed `Session.open` carries
  // is rendered by `openFailureMessage`, a test-visible top-level function in
  // session.dart -- provisional, and local to that file pending the
  // diagnosability unit's general rc-to-name accessor.
  group('Session.open failure diagnostics', () {
    // Fails deterministically and WITHOUT touching the network: client mode
    // has no peer to connect to, and multicast scouting is off, so zenoh
    // refuses on the config alone. Measured on this machine: rc -4 in 27 ms.
    // A config that failed by timing out would make these cells slow and
    // flaky instead of fast and certain.
    Config failingConfig() => Config()
      ..insertJson5('mode', '"client"')
      ..insertJson5('scouting/multicast/enabled', 'false');

    Future<ZenohException> captureOpenFailure() async {
      ZenohException? thrown;
      try {
        (await Session.open(config: failingConfig())).close();
      } on ZenohException catch (e) {
        thrown = e;
      }
      expect(
        thrown,
        isNotNull,
        reason:
            'the client-mode/no-multicast config must fail to open; if '
            'it opened, this whole group is measuring nothing',
      );
      return thrown!;
    }

    test('a failing open names the canon code, not a bare integer', () async {
      final thrown = await captureOpenFailure();

      // -4 is Z_ENETWORK -- extern/zenoh-c/include/zenoh_concrete.h:31.
      expect(thrown.returnCode, equals(-4));
      expect(thrown.message, contains('Z_ENETWORK'));
      // The number stays in the message too: the name is added ALONGSIDE it,
      // not substituted for it.
      expect(thrown.message, contains('-4'));
    });

    test(
      'the named code is qualified, so it cannot be read as a diagnosis',
      () async {
        // z_open has exactly TWO failure returns -- Z_EINVAL when no config was
        // provided, and Z_ENETWORK for every other failure, the Err(e) arm
        // being unconditional (extern/zenoh-c/src/session.rs:89-111, read at
        // the pinned 1.8.0). So -4 means "the open failed" and carries NO
        // information about why. A bad mode, an unparseable endpoint and an
        // unreachable peer all arrive as -4.
        //
        // Naming the symbol is accurate; letting it stand unqualified is not --
        // it reads as "network problem" and sends a reader after a fault that
        // may not exist. This cell pins the qualification so it cannot be
        // dropped silently in a later edit.
        final message = (await captureOpenFailure()).message;

        expect(
          message,
          contains('every open failure'),
          reason:
              'the message must disclose that -4 is a catch-all, or the '
              'symbol reads as a diagnosis canon never made',
        );
        expect(
          message,
          contains('not specifically a network fault'),
          reason: 'the network reading is the specific misreading to refuse',
        );
      },
    );

    test(
      'the message says which config was in play, at zero FFI cost',
      () async {
        // The caller-supplied half, driven by an actually failing open.
        final supplied = (await captureOpenFailure()).message;

        // The `config: null` half CANNOT be driven through a real open: a
        // null-config open takes canon's defaults, which SUCCEED (measured
        // 0 ms, rc 0 on this machine today). There is no failure to observe,
        // so this half goes through the seam directly.
        final defaulted = openFailureMessage(-4, callerSuppliedConfig: false);

        expect(supplied, isNot(equals(defaulted)));
        // And the real open's text OPENS with the seam's caller-supplied
        // rendering -- otherwise the two halves above would be comparing
        // different things. `startsWith`, not `equals`: the offloaded open
        // appends canon's own detail (". Zenoh says: ...") after the rendering,
        // and that suffix is the worker's, not the seam's.
        expect(
          supplied,
          startsWith(openFailureMessage(-4, callerSuppliedConfig: true)),
        );
      },
    );

    test('an unmapped code degrades honestly to the bare number', () {
      // No real z_open returns an unmapped code, so this is rendered through
      // the seam. -99 is outside canon's set entirely.
      final rendered = openFailureMessage(-99, callerSuppliedConfig: true);

      expect(rendered, contains('-99'));
      expect(rendered, isNot(matches(RegExp('Z_[A-Z]'))));
      // Control, so the negative above is discriminating rather than vacuous:
      // the same call on a MAPPED code does name its symbol.
      expect(
        openFailureMessage(-4, callerSuppliedConfig: true),
        matches(RegExp('Z_[A-Z]')),
      );
    });

    test('enrichment never converts a success into a failure', () async {
      // Measured: opens in ~1 ms, rc 0.
      final session = await Session.open(
        config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
      );

      // Usable, not merely non-null.
      expect(session, isA<Session>());
      expect(session.zid, isA<ZenohId>());
      expect(session.close, returnsNormally);

      // The structural half, and the real hazard this cell exists for:
      // reading `mode` or `connect/endpoints` to enrich the text would cost
      // an FFI call on EVERY successful open for a failure-only message, and
      // Config.get throws ZenohException on an absent key -- turning a
      // diagnosable failure into a different exception entirely.
      final source = File('lib/src/session.dart').readAsStringSync();

      // (a) The renderer takes no Config, so it cannot read one.
      final declaration = RegExp(
        r'String openFailureMessage\(\s*int rc,\s*'
        r'\{\s*required bool callerSuppliedConfig,?\s*\}\s*\)',
      );
      expect(
        declaration.allMatches(source),
        hasLength(1),
        reason:
            'openFailureMessage must take exactly (int, {bool}) -- a '
            'Config parameter would reopen the hazard',
      );

      // (b) Its single call site sits PAST the success path's early return,
      // so no successful open ever reaches the rendering. The rc is read in
      // the completion handler now that `open` is offloaded -- the shape
      // moved, the invariant did not.
      final handlerStart = source.indexOf('void completeOpenFromPost(');
      final handlerEnd = source.indexOf('String openFailureMessage(');
      expect(handlerStart, greaterThanOrEqualTo(0));
      expect(handlerEnd, greaterThan(handlerStart));
      final body = source.substring(handlerStart, handlerEnd);

      final successBranch = body.indexOf('if (rc == 0 && address != 0) {');
      final successComplete = body.indexOf('completer.complete(Session._(');
      final callSite = body.indexOf('openFailureMessage(');
      expect(successBranch, greaterThanOrEqualTo(0));
      expect(successComplete, greaterThan(successBranch));
      expect(
        RegExp(r'openFailureMessage\(').allMatches(body),
        hasLength(1),
        reason: 'exactly one call site, so locating it locates all of them',
      );
      // The success arm RETURNS between completing and the rendering, which
      // is what keeps a rc-0 post out of the failure text entirely.
      final earlyReturn = body.indexOf('return;', successComplete);
      expect(earlyReturn, greaterThan(successComplete));
      expect(callSite, greaterThan(earlyReturn));
    });
  });
}
