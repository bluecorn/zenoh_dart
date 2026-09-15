// Seed [10a] slice 8 — the query column, lazily and without a declaration flag.
//
// WHY THIS COLUMN IS ASYMMETRIC, and why that asymmetry is the API's own
// explanation of the flag elsewhere. A sample's native payload dies when the
// delivery callback returns, so retaining it there must happen inside the
// callback or not at all -- hence `retainPayload:` at declaration. A query's
// does not: `_zd_query_callback` already heap-clones the whole owned query and
// Dart owns it until `Query.dispose()`. So the payload is reachable WHENEVER
// Dart asks, and the accessor can be lazy, memoized, and free when unused.
//
// The accessor is memoized rather than a clone factory: a consumer reading it
// twice must not leak one handle per read.
//
// No control byte is spelled as a literal: the interior NUL is an explicit
// 0x00 list element, so this file stays text to every review instrument.
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Drives one get carrying [payload] at the queryable's key and returns the
/// delivered [Query]. Bounded, and it fails with a diagnosis rather than
/// hanging the serial suite.
Future<Query> receiveQuery(
  Session getter,
  Stream<Query> queries,
  String key, {
  ZBytes? payload,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final seen = <Query>[];
  final sub = queries.listen(seen.add);
  try {
    final deadline = DateTime.now().add(timeout);
    while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
      // The reply stream is drained so the get completes rather than piling up.
      unawaited(
        getter
            .get(key, payload: payload?.clone())
            .drain<void>()
            .catchError((_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (seen.isEmpty) {
      throw StateError('no query arrived at $key within $timeout');
    }
    return seen.first;
  } finally {
    await sub.cancel();
  }
}

void main() {
  group('Received query payload — no opt-in required (TCP 19730)', () {
    late Session qSession;
    late Session gSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19730"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      qSession = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19730"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      gSession = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      gSession.close();
      qSession.close();
    });

    test(
      "a received query's payload is reachable as a ZBytes with no opt-in",
      () async {
        // Given: a queryable declared with NO retention argument at all
        const key = 'test/qretain/basic';
        final sent = Uint8List.fromList([0x71, 0x00, 0xFF, 0x42]);
        final queryable = qSession.declareQueryable(key);
        addTearDown(queryable.close);

        // When: a get carrying a payload reaches it
        final query = await receiveQuery(
          gSession,
          queryable.stream,
          key,
          payload: ZBytes.fromUint8List(sent),
        );

        // Then: payloadZBytes is non-null and byte-exact
        final retained = query.payloadZBytes;
        expect(retained, isNotNull);
        expect(retained!.toBytes(), equals(sent));
        expect(query.payloadBytes, equals(sent));
        retained.dispose();
        query.dispose();
      },
    );

    test('the accessor is memoized, not a clone factory', () async {
      // Given: a delivered Query carrying a payload
      const key = 'test/qretain/memo';
      final queryable = qSession.declareQueryable(key);
      addTearDown(queryable.close);
      final query = await receiveQuery(
        gSession,
        queryable.stream,
        key,
        payload: ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3])),
      );

      // When: payloadZBytes is read twice
      final first = query.payloadZBytes;
      final second = query.payloadZBytes;

      // Then: the IDENTICAL object, so a consumer cannot leak one handle per
      // read. `same`, not `equals` -- two distinct handles over the same bytes
      // would satisfy equality and still leak.
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      first!.dispose();
      query.dispose();
    });

    test("the retained payload survives the query's disposal", () async {
      // Given: a Query whose payloadZBytes has been materialised
      const key = 'test/qretain/outlives';
      final sent = Uint8List.fromList([0xAB, 0x00, 0xCD]);
      final queryable = qSession.declareQueryable(key);
      addTearDown(queryable.close);
      final query = await receiveQuery(
        gSession,
        queryable.stream,
        key,
        payload: ZBytes.fromUint8List(sent),
      );
      final retained = query.payloadZBytes;
      expect(retained, isNotNull);

      // When: the query itself is disposed
      query.dispose();

      // Then: the handle still reads -- the clone is independent of the query
      // it came from, which is exactly what a borrowed view could not be.
      expect(retained!.toBytes(), equals(sent));
      retained.dispose();
    });

    test(
      'an absent query payload reads as null, distinct from present-empty',
      () async {
        // Given: one get with NO payload and another with a zero-length one
        const absentKey = 'test/qretain/absent';
        const emptyKey = 'test/qretain/empty';
        final absentQueryable = qSession.declareQueryable(absentKey);
        addTearDown(absentQueryable.close);
        final emptyQueryable = qSession.declareQueryable(emptyKey);
        addTearDown(emptyQueryable.close);

        final absentQuery = await receiveQuery(
          gSession,
          absentQueryable.stream,
          absentKey,
        );
        final emptyQuery = await receiveQuery(
          gSession,
          emptyQueryable.stream,
          emptyKey,
          payload: ZBytes.fromUint8List(Uint8List(0)),
        );

        // When/Then: absent is null; present-but-empty is a live zero-length
        // handle. Conflating the two is the NULL-vs-empty transform this
        // project's fidelity doctrine names outright.
        expect(absentQuery.payloadZBytes, isNull);
        final emptyRetained = emptyQuery.payloadZBytes;
        expect(emptyRetained, isNotNull);
        expect(emptyRetained!.toBytes().length, equals(0));

        emptyRetained.dispose();
        absentQuery.dispose();
        emptyQuery.dispose();
      },
    );

    test('the pull queryable gets it for free', () async {
      // Given: a PullQueryable -- a different carrier, the SAME accessor
      const key = 'test/qretain/pull';
      final sent = Uint8List.fromList([0x50, 0x00, 0x51]);
      final pull = qSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);

      // When: the query is taken through tryRecv
      Query? query;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (query == null && DateTime.now().isBefore(deadline)) {
        unawaited(
          gSession
              .get(key, payload: ZBytes.fromUint8List(sent))
              .drain<void>()
              .catchError((_) {}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final r = pull.tryRecv();
        if (r is RecvData<Query>) query = r.value;
      }
      expect(
        query,
        isNotNull,
        reason: 'no query arrived on the pull queryable',
      );

      // Then: non-null and byte-exact -- one accessor covers push and pull
      final retained = query!.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes(), equals(sent));
      retained.dispose();
      query.dispose();
    });

    test('reading the handle from a disposed query is refused', () async {
      // Given: a Query already disposed, whose payload was NEVER materialised
      const key = 'test/qretain/disposed';
      final queryable = qSession.declareQueryable(key);
      addTearDown(queryable.close);
      final query = await receiveQuery(
        gSession,
        queryable.stream,
        key,
        payload: ZBytes.fromUint8List(Uint8List.fromList([9, 9])),
      );
      query.dispose();

      // When/Then: a StateError, rather than the disposed handle being loaned
      // to a clone that would read freed memory.
      expect(() => query.payloadZBytes, throwsStateError);
    });

    test('the background queryable behaves identically', () async {
      // Given: declareBackgroundQueryable, the fire-and-forget carrier
      const key = 'test/qretain/background';
      final sent = Uint8List.fromList([0xB6, 0x00, 0xB7]);
      final stream = qSession.declareBackgroundQueryable(key);

      // When: a get carrying a payload reaches it
      final query = await receiveQuery(
        gSession,
        stream,
        key,
        payload: ZBytes.fromUint8List(sent),
      );

      // Then: non-null and byte-exact
      final retained = query.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes(), equals(sent));
      retained.dispose();
      query.dispose();
    });
  });
}
