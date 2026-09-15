import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Seed D slices 9-13 — `allowedOrigin` on the five declaration paths:
// declareSubscriber, declareBackgroundSubscriber, declarePullSubscriber,
// declareQueryable and declareBackgroundQueryable.
//
// This is the RECEIVE-side twin of `allowedDestination`. Same canon enum, same
// -1 sentinel, opposite direction: `allowedDestination` on a send limits who
// receives it; `allowedOrigin` on a declaration limits whose traffic it
// accepts.
//
// THE HARNESS. Two sessions over a pinned TCP hop with scouting off. The entity
// under test always lives on session B, and traffic is driven from BOTH
// sessions at once — from A (which is remote to B) and from B itself (which is
// same-session). That is what makes the three modes separable: with traffic
// from one side only, `sessionLocal` and `any` are indistinguishable and the
// test would pass for the wrong reason.
//
// `sessionLocal` means "within the declaring SESSION" — not the process and not
// the host. Sessions A and B live in this one Dart process and are still remote
// to each other, which is exactly why the harness works at all.
//
// Every three-mode test runs its `any` leg FIRST as a control: it proves both
// traffic sources are live and the route works, so a zero on a restricted leg
// is the locality filter rather than a dead harness.

/// Settle time for a declaration or publication to traverse the loopback hop.
Future<void> _settle() => Future<void>.delayed(const Duration(seconds: 1));

/// Opens a listen/connect session pair on [port] with scouting fully off.
Future<(Session, Session)> _pair(int port) async {
  final c1 = Config()
    ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final a = await Session.open(config: c1);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final c2 = Config()
    ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final b = await Session.open(config: c2);
  await Future<void>.delayed(const Duration(seconds: 1));
  return (a, b);
}

void main() {
  group('declareSubscriber allowedOrigin (TCP 18910)', () {
    late Session a;
    late Session b;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      (a, b) = await _pair(18910);
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      a.close();
      b.close();
    });

    /// Declares a subscriber on B with [origin], drives one put from A
    /// (remote) and one from B (same-session), and reports which arrived.
    Future<({bool fromRemote, bool fromLocal})> pattern(
      String ke,
      Locality? origin, {
      bool omit = false,
    }) async {
      final sub = omit
          ? b.declareSubscriber(ke)
          : b.declareSubscriber(ke, allowedOrigin: origin);
      addTearDown(sub.close);

      final got = <Sample>[];
      subs.add(sub.stream.listen(got.add));
      await _settle();

      a.put(ke, 'from-remote');
      b.put(ke, 'from-local');
      await _settle();

      final payloads = got.map((s) => s.payload).toSet();
      return (
        fromRemote: payloads.contains('from-remote'),
        fromLocal: payloads.contains('from-local'),
      );
    }

    test('allowedOrigin discriminates in all three modes', () async {
      expect(
        await pattern('zenoh/dart/test/d/sub/any', Locality.any),
        (fromRemote: true, fromLocal: true),
        reason:
            'CONTROL: both sources must reach an unrestricted subscriber, '
            'or the restricted legs below prove nothing',
      );
      expect(
        await pattern('zenoh/dart/test/d/sub/remote', Locality.remote),
        (fromRemote: true, fromLocal: false),
      );
      expect(
        await pattern('zenoh/dart/test/d/sub/local', Locality.sessionLocal),
        (fromRemote: false, fromLocal: true),
      );
    });

    test('an omitted allowedOrigin resolves to canon ANY', () async {
      expect(
        await pattern('zenoh/dart/test/d/sub/omitted', null, omit: true),
        (fromRemote: true, fromLocal: true),
      );
    });

    test('the failure path still throws and drops the closure once', () {
      // Introducing the options struct must not disturb the failure-path
      // ownership: on a non-zero rc the shim drops the un-consumed closure and
      // Dart throws. An invalid key expression is the reachable trigger.
      expect(
        () => b.declareSubscriber('bad//ke', allowedOrigin: Locality.remote),
        throwsA(anything),
      );
    });
  });

  group('declareBackgroundSubscriber allowedOrigin (TCP 18911)', () {
    late Session a;
    late Session b;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      (a, b) = await _pair(18911);
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      a.close();
      b.close();
    });

    Future<({bool fromRemote, bool fromLocal})> pattern(
      String ke,
      Locality? origin, {
      bool omit = false,
    }) async {
      final stream = omit
          ? b.declareBackgroundSubscriber(ke)
          : b.declareBackgroundSubscriber(ke, allowedOrigin: origin);

      final got = <Sample>[];
      subs.add(stream.listen(got.add));
      await _settle();

      a.put(ke, 'from-remote');
      b.put(ke, 'from-local');
      await _settle();

      final payloads = got.map((s) => s.payload).toSet();
      return (
        fromRemote: payloads.contains('from-remote'),
        fromLocal: payloads.contains('from-local'),
      );
    }

    test('allowedOrigin discriminates in all three modes', () async {
      expect(
        await pattern('zenoh/dart/test/d/bgsub/any', Locality.any),
        (fromRemote: true, fromLocal: true),
        reason: 'CONTROL: both sources must reach an unrestricted subscriber',
      );
      expect(
        await pattern('zenoh/dart/test/d/bgsub/remote', Locality.remote),
        (fromRemote: true, fromLocal: false),
      );
      expect(
        await pattern('zenoh/dart/test/d/bgsub/local', Locality.sessionLocal),
        (fromRemote: false, fromLocal: true),
      );
    });

    test('an omitted allowedOrigin resolves to canon ANY', () async {
      expect(
        await pattern('zenoh/dart/test/d/bgsub/omitted', null, omit: true),
        (fromRemote: true, fromLocal: true),
      );
    });
  });

  group('declarePullSubscriber allowedOrigin (TCP 18912)', () {
    late Session a;
    late Session b;

    setUpAll(() async {
      (a, b) = await _pair(18912);
    });

    tearDownAll(() {
      a.close();
      b.close();
    });

    Future<({bool fromRemote, bool fromLocal})> pattern(
      String ke,
      Locality? origin, {
      bool omit = false,
    }) async {
      final pull = omit
          ? b.declarePullSubscriber(ke)
          : b.declarePullSubscriber(ke, allowedOrigin: origin);
      addTearDown(pull.close);
      await _settle();

      a.put(ke, 'from-remote');
      b.put(ke, 'from-local');
      await _settle();

      // Poll to exhaustion rather than assuming an arrival order.
      final payloads = <String>{};
      while (true) {
        if (pull.tryRecv() case RecvData(:final value)) {
          payloads.add(value.payload);
        } else {
          break;
        }
      }
      return (
        fromRemote: payloads.contains('from-remote'),
        fromLocal: payloads.contains('from-local'),
      );
    }

    test('allowedOrigin discriminates in all three modes', () async {
      expect(
        await pattern('zenoh/dart/test/d/pull/any', Locality.any),
        (fromRemote: true, fromLocal: true),
        reason: 'CONTROL: both sources must be buffered when unrestricted',
      );
      expect(
        await pattern('zenoh/dart/test/d/pull/remote', Locality.remote),
        (fromRemote: true, fromLocal: false),
      );
      expect(
        await pattern('zenoh/dart/test/d/pull/local', Locality.sessionLocal),
        (fromRemote: false, fromLocal: true),
      );
    });

    test('an omitted allowedOrigin resolves to canon ANY', () async {
      expect(
        await pattern('zenoh/dart/test/d/pull/omitted', null, omit: true),
        (fromRemote: true, fromLocal: true),
      );
    });
  });

  group('declareQueryable allowedOrigin (TCP 18913)', () {
    late Session a;
    late Session b;

    setUpAll(() async {
      (a, b) = await _pair(18913);
    });

    tearDownAll(() {
      a.close();
      b.close();
    });

    /// Declares a queryable on B with [origin], then queries it from A
    /// (remote) and from B (same-session), reporting which get was answered.
    Future<({bool fromRemote, bool fromLocal})> pattern(
      String ke,
      Locality? origin, {
      bool omit = false,
    }) async {
      final q = omit
          ? b.declareQueryable(ke)
          : b.declareQueryable(ke, allowedOrigin: origin);
      addTearDown(q.close);
      q.stream.listen((query) {
        query
          ..reply(ke, 'r')
          ..dispose();
      });
      await _settle();

      Future<bool> answered(Session from) async {
        final replies = await from
            .get(ke, timeout: const Duration(seconds: 3))
            .toList();
        return replies.any((r) => r.isOk);
      }

      return (fromRemote: await answered(a), fromLocal: await answered(b));
    }

    test('allowedOrigin discriminates in all three modes', () async {
      // `sessionLocal` on the get/queryable path was untested in ANY topology
      // by the probes behind this seed — the middle leg here is its first
      // measurement.
      expect(
        await pattern('zenoh/dart/test/d/qbl/any', Locality.any),
        (fromRemote: true, fromLocal: true),
        reason:
            'CONTROL: both getters must be answered when unrestricted, so '
            'an unanswered get below is the locality filter and not a dead '
            'route (upstream core #2516)',
      );
      expect(
        await pattern('zenoh/dart/test/d/qbl/remote', Locality.remote),
        (fromRemote: true, fromLocal: false),
      );
      expect(
        await pattern('zenoh/dart/test/d/qbl/local', Locality.sessionLocal),
        (fromRemote: false, fromLocal: true),
      );
    });

    test('an omitted allowedOrigin resolves to canon ANY', () async {
      expect(
        await pattern('zenoh/dart/test/d/qbl/omitted', null, omit: true),
        (fromRemote: true, fromLocal: true),
      );
    });
  });

  group('declareBackgroundQueryable allowedOrigin (TCP 18914)', () {
    late Session a;
    late Session b;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      (a, b) = await _pair(18914);
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      a.close();
      b.close();
    });

    Future<({bool fromRemote, bool fromLocal})> pattern(
      String ke,
      Locality? origin, {
      bool omit = false,
    }) async {
      final stream = omit
          ? b.declareBackgroundQueryable(ke)
          : b.declareBackgroundQueryable(ke, allowedOrigin: origin);
      subs.add(
        stream.listen((query) {
          query
            ..reply(ke, 'r')
            ..dispose();
        }),
      );
      await _settle();

      Future<bool> answered(Session from) async {
        final replies = await from
            .get(ke, timeout: const Duration(seconds: 3))
            .toList();
        return replies.any((r) => r.isOk);
      }

      return (fromRemote: await answered(a), fromLocal: await answered(b));
    }

    test('allowedOrigin discriminates in all three modes', () async {
      expect(
        await pattern('zenoh/dart/test/d/bgqbl/any', Locality.any),
        (fromRemote: true, fromLocal: true),
        reason: 'CONTROL: both getters must be answered when unrestricted',
      );
      expect(
        await pattern('zenoh/dart/test/d/bgqbl/remote', Locality.remote),
        (fromRemote: true, fromLocal: false),
      );
      expect(
        await pattern('zenoh/dart/test/d/bgqbl/local', Locality.sessionLocal),
        (fromRemote: false, fromLocal: true),
      );
    });

    test('an omitted allowedOrigin resolves to canon ANY', () async {
      expect(
        await pattern('zenoh/dart/test/d/bgqbl/omitted', null, omit: true),
        (fromRemote: true, fromLocal: true),
      );
    });

    test('a delivered query is still fully replyable and disposable', () async {
      // The restriction filters WHICH queries arrive, not what can be done
      // with the ones that do.
      const ke = 'zenoh/dart/test/d/bgqbl/replyable';
      final stream = b.declareBackgroundQueryable(
        ke,
        allowedOrigin: Locality.remote,
      );
      var disposedCleanly = false;
      subs.add(
        stream.listen((query) {
          query
            ..reply(ke, 'payload-through')
            ..dispose();
          disposedCleanly = true;
        }),
      );
      await _settle();

      final replies = await a
          .get(ke, timeout: const Duration(seconds: 3))
          .toList();
      final ok = replies.where((r) => r.isOk).toList();
      expect(ok, isNotEmpty);
      expect(ok.first.ok.payload, 'payload-through');
      expect(disposedCleanly, isTrue);
    });
  });

  group('the liveliness subscriber path is deliberately out of scope', () {
    test('declareLivelinessSubscriber gains no allowedOrigin', () {
      // canon's `z_liveliness_subscriber_options_t` carries only `history` —
      // there is no locality field there — so the parameter is correctly
      // absent even though this path also returns a Subscriber. Neither the
      // seed nor its review checked this; it was found at planning.
      //
      // CONTROL: the ordinary declareSubscriber on the same class DOES take
      // allowedOrigin, so the absence below is a real negative.
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final session = code('lib/src/session.dart');
      final start = session.indexOf('Subscriber declareLivelinessSubscriber(');
      expect(start, greaterThan(-1), reason: 'the method must exist');
      final sig = session.substring(start, start + 220);

      // CONTROL, now STRUCTURAL rather than an exact one-line signature.
      //
      // It used to assert the literal
      // `declareSubscriber(Object keyExpr, {Locality? allowedOrigin})`, which
      // broke the moment seed [10a] added a `retainPayload` parameter and the
      // signature wrapped onto several lines. The cell went red on correct
      // code: BOTH its claims were still true, and only the control's spelling
      // had moved.
      //
      // Taking a window from the method's own start -- the same shape as the
      // claim it controls -- keeps its full strength (the ordinary subscriber
      // path must carry allowedOrigin, which is what makes the absence below a
      // real negative) while surviving reformatting.
      final controlStart = session.indexOf('Subscriber declareSubscriber(');
      expect(
        controlStart,
        greaterThan(-1),
        reason: 'the control method must exist',
      );
      expect(
        session.substring(controlStart, controlStart + 220),
        contains('allowedOrigin'),
        reason: 'CONTROL: the ordinary subscriber path does take it',
      );
      expect(sig, isNot(contains('allowedOrigin')));
    });
  });
}
