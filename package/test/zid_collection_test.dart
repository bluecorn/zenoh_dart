// Seed #9, slices 1 and 2: the unbounded zid enumeration.
//
// Slice 1 drives the shim-owned buffer's ownership contract at the seam
// (bindings level) and through the shipped public path. Slice 2 pins the
// exactness of the enumeration and runs the growth ladder.
//
// Ports: 19540 (slice 1's pair + slice 2's four-session group), 19541 (slice
// 2's router/peer partition). Both above the token probe's runtime range
// (19500-19539), which a high-water grep does not see.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh.dart';

/// A session with discovery fully off, so every relationship these tests
/// assert is one the configured endpoints created and not one the developer's
/// LAN supplied.
Config _linked(String? endpointKey, int port, {String mode = 'peer'}) {
  final config = Config()
    ..insertJson5('mode', '"$mode"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (endpointKey != null) {
    config.insertJson5(endpointKey, '["tcp/127.0.0.1:$port"]');
  }
  return config;
}

/// Polls until [session] observes exactly [expected] peers, or fails.
///
/// Deadline-bounded on purpose: a convergence wait that cannot fail turns a
/// broken rework into a frozen serial suite, which is the most expensive
/// possible failure here — it burns the one sampling opportunity the close run
/// represents and reports nothing. This fails with the last count it saw.
Future<void> _awaitPeers(
  Session session,
  int expected, {
  String? label,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  var last = -1;
  while (DateTime.now().isBefore(deadline)) {
    last = session.peersZid().length;
    if (last == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    '${label ?? 'session'} did not converge to $expected peers within '
    '${timeout.inSeconds}s (last observed: $last)',
  );
}

/// Polls until [session] observes exactly [expected] routers, or fails.
Future<void> _awaitRouters(
  Session session,
  int expected, {
  String? label,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  var last = -1;
  while (DateTime.now().isBefore(deadline)) {
    last = session.routersZid().length;
    if (last == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    '${label ?? 'session'} did not converge to $expected routers within '
    '${timeout.inSeconds}s (last observed: $last)',
  );
}

void main() {
  // ---------------------------------------------------------------------
  // Slice 1 — the shim-owned buffer's ownership contract.
  // ---------------------------------------------------------------------
  group('Zid collection: the shim-owned buffer contract (TCP 19540)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      session1 = await Session.open(config: _linked('listen/endpoints', 19540));
      // Bound the listener's bind, then converge on the link itself rather
      // than sleeping through it.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      session2 = await Session.open(
        config: _linked('connect/endpoints', 19540),
      );
      await _awaitPeers(session1, 1, label: 'session1');
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    // Test 1: the seam itself. Canon's own memcmp discipline (z_api_info.c:213-
    // 260) applied before any Dart-side materialization, so a transform
    // introduced by ZenohId's constructor could not mask a wrong byte here.
    test(
      'the collectors hand back a shim-owned buffer with an exact count',
      () {
        final outIds = calloc<Pointer<Uint8>>();
        final outCount = calloc<Size>();
        try {
          final rc = bindings.zd_info_peers_zid(
            session1.loanedHandle.cast(),
            outIds,
            outCount,
          );

          expect(rc, equals(0), reason: 'canon returns Z_OK unconditionally');
          expect(outCount.value, equals(1), reason: 'exactly one linked peer');
          expect(outIds.value, isNot(equals(nullptr)));

          final atSeam = Uint8List.fromList(outIds.value.asTypedList(16));
          expect(atSeam, equals(session2.zid.bytes));
        } finally {
          // NULL is a documented no-op, so this is safe on the throwing path
          // too — and it is called exactly once, which is the whole contract.
          bindings.zd_zid_list_drop(outIds.value);
          calloc
            ..free(outIds)
            ..free(outCount);
        }
      },
    );

    // Test 2: the growth policy's second merit, made observable. The old path
    // calloc'd 16 KiB per call whatever the answer was; this one does not
    // allocate at all when the enumeration is empty.
    test('an empty enumeration allocates nothing at all', () async {
      final isolated = await Session.open(config: _linked(null, 0));
      addTearDown(isolated.close);

      final outIds = calloc<Pointer<Uint8>>();
      final outCount = calloc<Size>();
      try {
        final rc = bindings.zd_info_peers_zid(
          isolated.loanedHandle.cast(),
          outIds,
          outCount,
        );

        expect(rc, equals(0));
        expect(outCount.value, equals(0));
        expect(
          outIds.value,
          equals(nullptr),
          reason: 'an empty enumeration must claim no block at all',
        );
      } finally {
        bindings.zd_zid_list_drop(outIds.value);
        calloc
          ..free(outIds)
          ..free(outCount);
      }
    });

    // Test 3: the rework changes the mechanism, not the answer.
    test('the shipped public path is behaviour-preserving', () {
      final peers = session1.peersZid();
      expect(peers, hasLength(1));
      expect(peers.single, equals(session2.zid));
      expect(session1.routersZid(), isEmpty);
    });

    // --- Edge cases ---

    // Test 4: allocate-last means the refusal happens before any out-cell is
    // claimed, so there is nothing to strand.
    test('a closed session is refused before anything is allocated', () async {
      final closed = await Session.open(config: _linked(null, 0))
        ..close();
      expect(
        closed.peersZid,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    // Test 5: the NULL property, and only the NULL property.
    //
    // This cell asserts what zd_zid_list_drop actually guarantees: NULL is a
    // safe no-op. It deliberately does NOT assert that a second call on the
    // same non-NULL pointer is safe, because it is not — the entry is a raw
    // free() with no owned handle and therefore no gravestone to check. The
    // house puts idempotence in Dart (Query._disposed guarding zd_query_drop),
    // not in the C entry.
    test('dropping a NULL list is a safe no-op', () async {
      final isolated = await Session.open(config: _linked(null, 0));
      addTearDown(isolated.close);

      final outIds = calloc<Pointer<Uint8>>();
      final outCount = calloc<Size>();
      try {
        expect(
          bindings.zd_info_peers_zid(
            isolated.loanedHandle.cast(),
            outIds,
            outCount,
          ),
          equals(0),
        );
        expect(outIds.value, equals(nullptr));

        // The drop under test.
        bindings.zd_zid_list_drop(outIds.value);

        // The process survived, and the path is still usable: a subsequent
        // enumeration through the same entry still succeeds. Without this the
        // cell would pass against a drop that corrupted the heap silently.
        expect(
          bindings.zd_info_peers_zid(
            isolated.loanedHandle.cast(),
            outIds,
            outCount,
          ),
          equals(0),
        );
        expect(outCount.value, equals(0));
      } finally {
        bindings.zd_zid_list_drop(outIds.value);
        calloc
          ..free(outIds)
          ..free(outCount);
      }
    });
  });

  // ---------------------------------------------------------------------
  // Slice 2 — exact enumeration and the growth ladder.
  //
  // Classified GREEN-ON-WRITE (characterization) and said so here rather than
  // left to be discovered: three peers fit the old 1024 cap, so these cells
  // pass on the pre-rework code too. They exist to guard the rework, not to
  // discover it. The *unbounded* property has no in-suite driver — staging
  // >1024 live peers is not stageable, which the A9 record already states.
  //
  // Criterion A's pair, stated: initial capacity 0, N = 3 observed ids from 4
  // linked sessions. With capacity 0 and doubling, any non-empty enumeration
  // executes the growth path; three ids run the ladder 0 -> 1 -> 2 -> 4. Four
  // in-process linked sessions sits at the top of the measured LINKED
  // precedent (3-4 — session_test.dart's A9 and router groups).
  // ---------------------------------------------------------------------
  group('Zid collection: exact enumeration and growth (TCP 19540)', () {
    late Session listener;
    late Session c1;
    late Session c2;
    late Session c3;

    setUpAll(() async {
      listener = await Session.open(config: _linked('listen/endpoints', 19540));
      // Settle time, not a correctness wait: it lets the listener finish
      // binding before three sessions dial it, saving a round of connect
      // retries. The correctness wait is the bounded poll below, so nothing
      // here can green for the wrong reason if this sleep is too short.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      c1 = await Session.open(config: _linked('connect/endpoints', 19540));
      c2 = await Session.open(config: _linked('connect/endpoints', 19540));
      c3 = await Session.open(config: _linked('connect/endpoints', 19540));

      // Every link awaited by a bounded poll for the expected count — never a
      // fixed sleep standing in for a correctness wait.
      await _awaitPeers(listener, 3, label: 'listener');
      await _awaitPeers(c1, 1, label: 'c1');
      await _awaitPeers(c2, 1, label: 'c2');
      await _awaitPeers(c3, 1, label: 'c3');
    });

    tearDownAll(() {
      c3.close();
      c2.close();
      c1.close();
      listener.close();
    });

    // Test 1: set equality in both directions, no `contains`.
    test('the listener returns exactly the three peers that dialled it', () {
      final peers = listener.peersZid();

      expect(peers.toSet(), equals({c1.zid, c2.zid, c3.zid}));
      expect(peers, hasLength(3), reason: 'no duplicates');
      for (final id in peers) {
        expect(id.bytes, hasLength(16));
      }
    });

    // Test 2: the control that makes Test 1 mean "the collector returned what
    // exists" rather than "the network was busy". Gossip is off, so c1 has no
    // route to learn about its siblings.
    test('each connector sees exactly the listener, and not its siblings', () {
      expect(c1.peersZid().toSet(), equals({listener.zid}));
    });

    // Test 5 (grouped here with its topology): repeated enumeration is stable
    // and each call materializes its own values from its own buffer.
    test('a repeated enumeration is stable and independent', () {
      final first = listener.peersZid();
      final second = listener.peersZid();

      expect(first.toSet(), equals(second.toSet()));

      final firstSnapshot = second.toSet();
      first.clear();
      expect(listener.peersZid().toSet(), equals(firstSnapshot));
      expect(second.toSet(), equals(firstSnapshot));
    });
  });

  // Test 3: canon's own partition assertion (z_api_info.c:213-260), asserted on
  // BOTH halves rather than only the populated one.
  group('Zid collection: the router/peer partition (TCP 19541)', () {
    late Session router;
    late Session client;
    late Session peer;

    setUpAll(() async {
      router = await Session.open(
        config: _linked('listen/endpoints', 19541, mode: 'router'),
      );
      // Settle time, as above — the correctness waits are the bounded router
      // polls below.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      client = await Session.open(
        config: _linked('connect/endpoints', 19541, mode: 'client'),
      );
      peer = await Session.open(config: _linked('connect/endpoints', 19541));

      await _awaitRouters(client, 1, label: 'client');
      await _awaitRouters(peer, 1, label: 'peer');
    });

    tearDownAll(() {
      peer.close();
      client.close();
      router.close();
    });

    test('the router/peer partition holds on both halves', () {
      expect(client.routersZid().toSet(), equals({router.zid}));
      expect(
        client.peersZid(),
        isEmpty,
        reason:
            'the populated half alone would not catch a collector that '
            'returned every known session',
      );
    });
  });

  // Test 4: empty stays empty after the failure/empty split — the half of
  // criterion C that IS drivable.
  group('Zid collection: the empty enumeration', () {
    test('zero connected peers is an empty list, not a failure', () async {
      final isolated = await Session.open(config: _linked(null, 0));
      addTearDown(isolated.close);

      expect(isolated.peersZid(), isEmpty);
      expect(isolated.routersZid(), isEmpty);
    });
  });
}
