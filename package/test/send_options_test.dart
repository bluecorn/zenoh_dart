import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Seed D slices 2-6 — the send-side options surface on put, publisher, delete,
// get and querier.
//
// Two acceptance criteria run through every group here, and they are different
// claims:
//
//   A — every option the caller SETS reaches canon. Asserted by round-trip:
//       the receive legs are census-verified identity, so a mismatch indicts
//       the send side.
//
//   B — every option the caller OMITS resolves to CANON's default for that
//       specific operation, not to a default this binding invented. This is
//       the criterion the seed exists to get right, and it needs a per-path
//       control: canon's congestion default is DROP on the push paths
//       (put/delete/publisher, `CongestionControl::DEFAULT_PUSH`) and BLOCK on
//       the request paths (get/querier, `DEFAULT_REQUEST`). A single Dart
//       literal could not be correct on both, which is why the omitted case
//       must reach `*_options_default` rather than a value we chose.
//
// Locality needs a THREE-WAY harness. With only two sessions, `sessionLocal`
// and `any` are indistinguishable — both deliver to the local subscriber — so
// a two-way test would pass for the wrong reason. Every locality group here
// therefore runs a subscriber on the SENDING session and one on the remote
// session simultaneously, and asserts the delivery pattern across both.
//
// All TCP groups pin explicit endpoints with scouting off. With multicast on a
// LAN, a stray peer flips the `remote` leg's counts and the negatives stop
// being real negatives.

/// Collects samples from [stream] into a list for later assertion.
///
/// Returned list is live: it accumulates until the subscription is cancelled
/// by the test's tearDown.
List<Sample> _collect(Stream<Sample> stream, List<StreamSubscription<void>> s) {
  final got = <Sample>[];
  s.add(stream.listen(got.add));
  return got;
}

/// Settle time for a publication to traverse the loopback TCP hop.
///
/// This is settle time, not a race: the assertions that follow are about what
/// did NOT arrive as much as what did, so there is no marker to poll for on
/// the negative legs.
Future<void> _settle() => Future<void>.delayed(const Duration(seconds: 1));

void main() {
  group('Session.put send options (TCP 18900)', () {
    late Session local;
    late Session remote;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18900"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      local = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18900"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      remote = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      local.close();
      remote.close();
    });

    Future<Sample> putAndReceive(
      String ke, {
      CongestionControl? congestionControl,
      Priority? priority,
      bool? isExpress,
      bool passNulls = false,
    }) async {
      final subscriber = remote.declareSubscriber(ke);
      addTearDown(subscriber.close);
      await _settle();

      final first = subscriber.stream.first.timeout(const Duration(seconds: 5));
      if (passNulls) {
        // Passing the default EXPLICITLY is the thing under test: CONV-2
        // requires an explicit `null` to take the same path as an absent
        // argument. Each suppression is per-argument rather than file-wide so
        // genuine redundancy elsewhere in this file still reports.
        local.put(
          ke,
          'v',
          // The literal null IS the test; removing it removes the test.
          // ignore: avoid_redundant_argument_values
          congestionControl: null,
          // The literal null IS the test; removing it removes the test.
          // ignore: avoid_redundant_argument_values
          priority: null,
          // The literal null IS the test; removing it removes the test.
          // ignore: avoid_redundant_argument_values
          isExpress: null,
          // The literal null IS the test; removing it removes the test.
          // ignore: avoid_redundant_argument_values
          allowedDestination: null,
        );
      } else {
        local.put(
          ke,
          'v',
          congestionControl: congestionControl,
          priority: priority,
          isExpress: isExpress,
        );
      }
      return first;
    }

    test('an explicitly set QoS triple arrives at the subscriber', () async {
      final s = await putAndReceive(
        'zenoh/dart/test/d/put/qos-set',
        congestionControl: CongestionControl.block,
        priority: Priority.realTime,
        isExpress: true,
      );
      expect(s.congestionControl, CongestionControl.block);
      expect(s.priority, Priority.realTime);
      expect(s.express, isTrue);
    });

    test('an omitted congestionControl resolves to canon DROP', () async {
      // Criterion B, the load-bearing case. canon's `z_put_options_default`
      // assigns CongestionControl::DEFAULT_PUSH = DROP. The same omission on
      // `get` yields BLOCK (asserted in the get group below), which is what
      // makes this a real discriminator rather than a restatement: no single
      // Dart literal could be correct on both paths.
      final s = await putAndReceive('zenoh/dart/test/d/put/cc-omitted');
      expect(s.congestionControl, CongestionControl.drop);
    });

    test('omitted priority and isExpress resolve to canon defaults', () async {
      final s = await putAndReceive('zenoh/dart/test/d/put/prio-omitted');
      expect(s.priority, Priority.data);
      expect(s.express, isFalse);
    });

    test('explicit null is indistinguishable from omission', () async {
      // CONV-2: `null` means "unspecified, canon decides". If an explicit null
      // took a different path from an absent argument, the sentinel would be
      // leaking a binding decision.
      final s = await putAndReceive(
        'zenoh/dart/test/d/put/explicit-null',
        passNulls: true,
      );
      expect(s.congestionControl, CongestionControl.drop);
      expect(s.priority, Priority.data);
      expect(s.express, isFalse);
    });

    test('putBytes carries the same options as put', () async {
      // The two Dart methods share one FFI signature, so they must agree.
      const ke = 'zenoh/dart/test/d/put/bytes-qos';
      final subscriber = remote.declareSubscriber(ke);
      addTearDown(subscriber.close);
      await _settle();

      final payload = Uint8List.fromList([0, 1, 2, 250, 251, 255]);
      final first = subscriber.stream.first.timeout(const Duration(seconds: 5));
      local.putBytes(
        ke,
        ZBytes.fromUint8List(payload),
        congestionControl: CongestionControl.block,
        priority: Priority.background,
        isExpress: true,
      );

      final s = await first;
      expect(s.congestionControl, CongestionControl.block);
      expect(s.priority, Priority.background);
      expect(s.express, isTrue);
      expect(s.payloadBytes, equals(payload));
    });

    test('payload and attachment ownership is unaffected', () async {
      // The added arguments must not disturb the unconditional markConsumed
      // discipline: z_bytes_move gravestones both regardless of return code.
      //
      // The probe is REUSE through the public API, not `markConsumed()` --
      // that method is deliberately idempotent (it returns early when already
      // consumed), so calling it twice proves nothing. Feeding a consumed
      // ZBytes back into a send site is what a caller would actually do wrong,
      // and it trips `_ensureNotConsumed` on the way to the pointer.
      const ke = 'zenoh/dart/test/d/put/ownership';
      final payload = ZBytes.fromString('p');
      final attachment = ZBytes.fromString('a');
      local.putBytes(
        ke,
        payload,
        attachment: attachment,
        congestionControl: CongestionControl.block,
        priority: Priority.dataHigh,
        isExpress: true,
        allowedDestination: Locality.any,
      );
      expect(
        () => local.putBytes(ke, payload),
        throwsA(isA<StateError>()),
        reason: 'the payload was moved into zenoh-c and must not be reusable',
      );
      expect(
        () => local.put(ke, 'x', attachment: attachment),
        throwsA(isA<StateError>()),
        reason: 'the attachment was moved too, on the same call',
      );
    });
  });

  group('Session.put locality (TCP 18901)', () {
    late Session local;
    late Session remote;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18901"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      local = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18901"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      remote = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      local.close();
      remote.close();
    });

    /// Publishes once with [allowedDestination] and reports (localHits,
    /// remoteHits) observed by a same-session and a remote subscriber.
    Future<(int, int)> deliveryPattern(
      String ke,
      Locality? allowedDestination, {
      bool omit = false,
    }) async {
      final localSub = local.declareSubscriber(ke);
      final remoteSub = remote.declareSubscriber(ke);
      addTearDown(localSub.close);
      addTearDown(remoteSub.close);

      final localGot = _collect(localSub.stream, subs);
      final remoteGot = _collect(remoteSub.stream, subs);
      await _settle();

      if (omit) {
        local.put(ke, 'v');
      } else {
        local.put(ke, 'v', allowedDestination: allowedDestination);
      }
      await _settle();
      return (localGot.length, remoteGot.length);
    }

    test('allowedDestination discriminates in all three modes', () async {
      // The three-way claim: `any` reaches both, `sessionLocal` reaches only
      // the same-session subscriber, `remote` reaches only the remote one.
      // Run `any` FIRST — it doubles as the control proving both subscribers
      // are live and the route works, so a zero on a later leg is the locality
      // filter rather than a dead harness.
      expect(
        await deliveryPattern('zenoh/dart/test/d/put/loc-any', Locality.any),
        (1, 1),
        reason:
            'CONTROL: any must reach both, or the negatives below are '
            'unfalsifiable',
      );
      expect(
        await deliveryPattern(
          'zenoh/dart/test/d/put/loc-local',
          Locality.sessionLocal,
        ),
        (1, 0),
      );
      expect(
        await deliveryPattern(
          'zenoh/dart/test/d/put/loc-remote',
          Locality.remote,
        ),
        (0, 1),
      );
    });

    test('an omitted allowedDestination resolves to canon ANY', () async {
      // Criterion B for locality: `z_locality_default()` is ANY, so omission
      // must be indistinguishable from the explicit `any` leg above.
      expect(
        await deliveryPattern(
          'zenoh/dart/test/d/put/loc-omitted',
          null,
          omit: true,
        ),
        (1, 1),
      );
    });
  });

  group('declarePublisher send options (TCP 18902)', () {
    late Session local;
    late Session remote;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18902"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      local = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18902"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      remote = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      local.close();
      remote.close();
    });

    Future<Sample> declareAndReceive(
      String ke, {
      CongestionControl? congestionControl,
      Priority? priority,
      bool? isExpress,
    }) async {
      final subscriber = remote.declareSubscriber(ke);
      addTearDown(subscriber.close);
      await _settle();

      final publisher = local.declarePublisher(
        ke,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
      );
      addTearDown(publisher.close);
      await _settle();

      final first = subscriber.stream.first.timeout(const Duration(seconds: 5));
      publisher.put('v');
      return first;
    }

    test('omitting the QoS triple still yields canon push defaults', () async {
      // Scope item 6 — the relocation. Before this slice the three values came
      // from Dart literals at publisher.dart:28-30 (duplicated one layer up at
      // session.dart:373-375); after it they come from
      // `z_publisher_options_default`. Both produce DROP/data/false, so this
      // test is NOT a discriminator for the relocation — it is the criterion-F
      // non-regression lock proving the relocation changed no behaviour.
      // The structural evidence is the separate test below.
      final s = await declareAndReceive('zenoh/dart/test/d/pub/qos-omitted');
      expect(s.congestionControl, CongestionControl.drop);
      expect(s.priority, Priority.data);
      expect(s.express, isFalse);
    });

    test('an explicitly set QoS triple still arrives', () async {
      final s = await declareAndReceive(
        'zenoh/dart/test/d/pub/qos-set',
        congestionControl: CongestionControl.block,
        priority: Priority.realTime,
        isExpress: true,
      );
      expect(s.congestionControl, CongestionControl.block);
      expect(s.priority, Priority.realTime);
      expect(s.express, isTrue);
    });

    test('explicit null is identical to omission', () async {
      final s = await declareAndReceive(
        'zenoh/dart/test/d/pub/qos-null',
        // The literal null IS the test; removing it removes the test.
        // ignore: avoid_redundant_argument_values
        congestionControl: null,
        // The literal null IS the test; removing it removes the test.
        // ignore: avoid_redundant_argument_values
        priority: null,
        // The literal null IS the test; removing it removes the test.
        // ignore: avoid_redundant_argument_values
        isExpress: null,
      );
      expect(s.congestionControl, CongestionControl.drop);
      expect(s.priority, Priority.data);
      expect(s.express, isFalse);
    });

    test('no Dart-literal QoS default survives the relocation', () async {
      // The relocation has no behavioural discriminator (see the first test),
      // so its evidence is structural. Ground truth 5: the shim's `>= 0`
      // guards at zenoh_dart.c:704-712 were DEAD CODE, because Dart declared
      // the three parameters non-nullable with literal defaults and could
      // never emit a negative. This asserts the literals are gone, which is
      // what makes the sentinel reachable and canon the source of the value.
      //
      // The CONTROL is load-bearing: without it a renamed file or a changed
      // parameter name would leave the absence assertions passing vacuously.
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final publisher = code('lib/src/publisher.dart');
      final session = code('lib/src/session.dart');

      for (final MapEntry(key: name, value: src) in {
        'publisher.dart': publisher,
        'session.dart': session,
      }.entries) {
        expect(
          src,
          contains('congestionControl'),
          reason:
              'CONTROL: $name must mention the parameter at all, or the '
              'absence assertions below prove nothing',
        );
        expect(
          src,
          isNot(contains('CongestionControl congestionControl =')),
          reason:
              '$name still declares a non-nullable congestionControl with '
              'a Dart-chosen default',
        );
        expect(
          src,
          isNot(contains('Priority priority =')),
          reason: '$name still declares a non-nullable priority default',
        );
        expect(
          src,
          isNot(contains('bool isExpress =')),
          reason: '$name still declares a non-nullable isExpress default',
        );
      }

      // And the send encoding is CONV-1's `.value`, not the positional forms.
      expect(publisher, isNot(contains('congestionControl.index')));
      expect(publisher, isNot(contains('priority.index + 1')));
      expect(publisher, contains('congestionControl?.value'));
    });

    test('allowedDestination discriminates in all three modes', () async {
      Future<(int, int)> pattern(String ke, Locality? dest) async {
        final localSub = local.declareSubscriber(ke);
        final remoteSub = remote.declareSubscriber(ke);
        addTearDown(localSub.close);
        addTearDown(remoteSub.close);

        final localGot = _collect(localSub.stream, subs);
        final remoteGot = _collect(remoteSub.stream, subs);
        await _settle();

        final publisher = local.declarePublisher(ke, allowedDestination: dest);
        addTearDown(publisher.close);
        await _settle();

        publisher.put('v');
        await _settle();
        return (localGot.length, remoteGot.length);
      }

      // `any` first as the control — see the put group.
      expect(
        await pattern('zenoh/dart/test/d/pub/loc-any', Locality.any),
        (1, 1),
        reason: 'CONTROL: any must reach both',
      );
      expect(
        await pattern(
          'zenoh/dart/test/d/pub/loc-local',
          Locality.sessionLocal,
        ),
        (1, 0),
      );
      expect(
        await pattern('zenoh/dart/test/d/pub/loc-remote', Locality.remote),
        (0, 1),
      );
      // Criterion B for locality on this path (closing coverage gap C-2):
      // omission must be indistinguishable from the explicit `any` leg. It
      // sits beside the criterion-A legs above deliberately — an omission
      // test alone also passes when the plumbing is absent entirely.
      expect(
        await pattern('zenoh/dart/test/d/pub/loc-omitted', null),
        (1, 1),
      );
    });
  });

  group('Session.deleteResource send options (TCP 18903)', () {
    late Session local;
    late Session remote;
    final subs = <StreamSubscription<void>>[];

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18903"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      local = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18903"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      remote = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      for (final s in subs) {
        await s.cancel();
      }
      local.close();
      remote.close();
    });

    Future<Sample> deleteAndReceive(
      String ke, {
      CongestionControl? congestionControl,
      Priority? priority,
      bool? isExpress,
    }) async {
      final subscriber = remote.declareSubscriber(ke);
      addTearDown(subscriber.close);
      await _settle();

      final first = subscriber.stream.first.timeout(const Duration(seconds: 5));
      local.deleteResource(
        ke,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
      );
      return first;
    }

    test('an explicitly set QoS triple arrives on the DELETE sample', () async {
      // The one discriminator in the evidence table that was unverified when
      // the plan was written: the census measured QoS identity on delivery
      // surfaces but never separated PUT from DELETE samples. This is its
      // first measurement.
      final s = await deleteAndReceive(
        'zenoh/dart/test/d/del/qos-set',
        congestionControl: CongestionControl.block,
        priority: Priority.realTime,
        isExpress: true,
      );
      expect(s.kind, SampleKind.delete);
      expect(s.congestionControl, CongestionControl.block);
      expect(s.priority, Priority.realTime);
      expect(s.express, isTrue);
    });

    test('an omitted congestionControl resolves to canon DROP', () async {
      // delete is a PUSH path: canon's `z_delete_options_default` assigns
      // CongestionControl::DEFAULT_PUSH = DROP.
      final s = await deleteAndReceive('zenoh/dart/test/d/del/cc-omitted');
      expect(s.kind, SampleKind.delete);
      expect(s.congestionControl, CongestionControl.drop);
    });

    test('omitted priority and isExpress resolve to canon defaults', () async {
      final s = await deleteAndReceive('zenoh/dart/test/d/del/prio-omitted');
      expect(s.priority, Priority.data);
      expect(s.express, isFalse);
    });

    test('allowedDestination discriminates in all three modes', () async {
      Future<(int, int)> pattern(String ke, Locality? dest) async {
        final localSub = local.declareSubscriber(ke);
        final remoteSub = remote.declareSubscriber(ke);
        addTearDown(localSub.close);
        addTearDown(remoteSub.close);

        final localGot = _collect(localSub.stream, subs);
        final remoteGot = _collect(remoteSub.stream, subs);
        await _settle();

        local.deleteResource(ke, allowedDestination: dest);
        await _settle();
        return (localGot.length, remoteGot.length);
      }

      expect(
        await pattern('zenoh/dart/test/d/del/loc-any', Locality.any),
        (1, 1),
        reason: 'CONTROL: any must reach both',
      );
      expect(
        await pattern(
          'zenoh/dart/test/d/del/loc-local',
          Locality.sessionLocal,
        ),
        (1, 0),
      );
      expect(
        await pattern('zenoh/dart/test/d/del/loc-remote', Locality.remote),
        (0, 1),
      );
      // Criterion B for locality on the delete path (coverage gap C-2),
      // paired with the criterion-A legs above so the pair discriminates
      // "canon's default" from "nothing was wired".
      expect(
        await pattern('zenoh/dart/test/d/del/loc-omitted', null),
        (1, 1),
      );
    });

    test('the delete path exposes no attachment parameter', () {
      // canon's `z_delete_options_t` has no attachment field. Binding one
      // would be the over-translation error the seed struck four sites for,
      // so this pins the absence. The CONTROL proves the instrument can see
      // an attachment parameter where one legitimately exists (put).
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final session = code('lib/src/session.dart');
      final deleteSig = session.substring(
        session.indexOf('void deleteResource('),
        session.indexOf('void deleteResource(') + 260,
      );

      expect(
        session,
        contains('ZBytes? attachment'),
        reason:
            'CONTROL: put/putBytes do take an attachment, so the '
            'instrument can see one when it is there',
      );
      expect(
        deleteSig,
        isNot(contains('attachment')),
        reason: 'canon z_delete_options_t has no attachment field',
      );
    });
  });

  group('Session.get send options (TCP 18904)', () {
    late Session getter;
    late Session replier;

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18904"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18904"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      replier = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      replier.close();
    });

    /// Declares a queryable on [session] that replies once to every query.
    Queryable replyOnce(Session session, String ke, {List<Query>? seen}) {
      final q = session.declareQueryable(ke);
      q.stream.listen((query) {
        seen?.add(query);
        query
          ..reply(ke, 'r')
          ..dispose();
      });
      return q;
    }

    Future<Reply> getOneReply(
      String ke, {
      CongestionControl? congestionControl,
      Priority? priority,
      bool? isExpress,
      ReplyKeyExpr? acceptReplies,
    }) async {
      final q = replyOnce(replier, ke);
      addTearDown(q.close);
      await _settle();

      final replies = await getter
          .get(
            ke,
            congestionControl: congestionControl,
            priority: priority,
            isExpress: isExpress,
            acceptReplies: acceptReplies,
            timeout: const Duration(seconds: 5),
          )
          .toList();

      final ok = replies.where((r) => r.isOk).toList();
      // Upstream zenoh core #2516: a get can return immediately with ZERO
      // replies and no error under some topologies. Without this guard, every
      // assertion below would pass vacuously on an empty stream — the exact
      // false-green shape the discipline names.
      expect(
        ok,
        isNotEmpty,
        reason:
            'no reply arrived: the assertions that follow would be '
            'vacuous (upstream core #2516)',
      );
      return ok.first;
    }

    test('an explicitly set congestionControl and priority arrive', () async {
      // A reply's sample carries the QUERY's congestion and priority — measured
      // over real TCP with a discriminating control, and re-measured by CP
      // through a declared Querier. So this reads the send side directly.
      final r = await getOneReply(
        'zenoh/dart/test/d/get/qos-set',
        congestionControl: CongestionControl.drop,
        priority: Priority.realTime,
      );
      expect(r.ok.congestionControl, CongestionControl.drop);
      expect(r.ok.priority, Priority.realTime);
    });

    test('an omitted congestionControl resolves to canon BLOCK', () async {
      // THE criterion the seed exists to get right. get is a REQUEST path:
      // canon's `z_get_options_default` assigns
      // CongestionControl::DEFAULT_REQUEST = BLOCK, where the same omission on
      // `put` yields DROP. The put group above asserts DROP on the identical
      // expression, so the pair is a genuine per-path control — no single Dart
      // literal could satisfy both.
      final r = await getOneReply('zenoh/dart/test/d/get/cc-omitted');
      expect(r.ok.congestionControl, CongestionControl.block);
    });

    test('an omitted priority resolves to canon data', () async {
      final r = await getOneReply('zenoh/dart/test/d/get/prio-omitted');
      expect(r.ok.priority, Priority.data);
    });

    test('an explicitly set isExpress is observable over TCP', () async {
      // Topology-dependent, and deliberately asserted only on the TCP leg:
      // over TCP a reply's express flag tracks the QUERY, so it reads the get's
      // own isExpress. Same-session it inverts and tracks the REPLY — which is
      // why the reply-path slices confine their round-trip to same-session and
      // forbid it here. The observable is reproduced; its mechanism (whether
      // the transport recomputes reply QoS from the request, or the
      // same-session path short-circuits) is NOT understood.
      final on = await getOneReply(
        'zenoh/dart/test/d/get/express-on',
        isExpress: true,
      );
      expect(on.ok.express, isTrue);

      final off = await getOneReply('zenoh/dart/test/d/get/express-off');
      expect(off.ok.express, isFalse);
    });

    test('acceptReplies is observable directly at the queryable', () async {
      // The direct value round-trip, preferred over an indirect
      // acceptance-count assertion.
      const ke = 'zenoh/dart/test/d/get/accept-any';
      final seen = <Query>[];
      final q = replyOnce(replier, ke, seen: seen);
      addTearDown(q.close);
      await _settle();

      await getter
          .get(
            ke,
            acceptReplies: ReplyKeyExpr.any,
            timeout: const Duration(seconds: 5),
          )
          .toList();

      expect(seen, isNotEmpty, reason: 'the queryable saw no query at all');
      expect(seen.first.acceptsReplies, ReplyKeyExpr.any);
    });

    test('allowedDestination discriminates in all three modes', () async {
      // ⚠️ target: all + consolidation: none are BOTH required. Under the
      // default `auto` consolidation canon resolves to LATEST — "unicity of
      // replies for the same key expression" — so two queryables on one key
      // would yield ONE reply and the `any` leg would read 1 where it means 2.
      // Note that simply lowering the expectation to 1 would make all three
      // legs read 1 and discriminate nothing: the test would go green while
      // testing nothing. Pattern taken from replier_id_test.dart:216.
      Future<int> replyCount(String ke, Locality? dest) async {
        final localQ = replyOnce(getter, ke);
        final remoteQ = replyOnce(replier, ke);
        addTearDown(localQ.close);
        addTearDown(remoteQ.close);
        await _settle();

        final replies = await getter
            .get(
              ke,
              allowedDestination: dest,
              target: QueryTarget.all,
              consolidation: ConsolidationMode.none,
              timeout: const Duration(seconds: 5),
            )
            .toList();
        return replies.where((r) => r.isOk).length;
      }

      // `any` first as the control: it proves both queryables answer and the
      // route works, so a lower count on a later leg is the locality filter.
      expect(
        await replyCount('zenoh/dart/test/d/get/loc-any', Locality.any),
        2,
        reason:
            'CONTROL: both the same-session and the remote queryable must '
            'reply, or the restricted legs below prove nothing',
      );
      expect(
        await replyCount(
          'zenoh/dart/test/d/get/loc-local',
          Locality.sessionLocal,
        ),
        1,
      );
      expect(
        await replyCount('zenoh/dart/test/d/get/loc-remote', Locality.remote),
        1,
      );
      // Criterion B for locality on the get path (coverage gap C-2), paired
      // with the criterion-A legs above.
      expect(
        await replyCount('zenoh/dart/test/d/get/loc-omitted', null),
        2,
      );
    });

    test('payload and attachment ownership is unaffected', () async {
      const ke = 'zenoh/dart/test/d/get/ownership';
      final payload = ZBytes.fromString('p');
      final attachment = ZBytes.fromString('a');
      await getter
          .get(
            ke,
            payload: payload,
            attachment: attachment,
            congestionControl: CongestionControl.block,
            priority: Priority.dataHigh,
            isExpress: true,
            allowedDestination: Locality.any,
            acceptReplies: ReplyKeyExpr.any,
            timeout: const Duration(milliseconds: 300),
          )
          .toList();

      expect(
        () => getter.get(ke, payload: payload),
        throwsA(isA<StateError>()),
      );
      expect(
        () => getter.get(ke, attachment: attachment),
        throwsA(isA<StateError>()),
      );
    });

    test('a pre-move selector failure leaves the payload unconsumed', () async {
      // The markConsumed discipline distinguishes a genuine pre-move
      // early-return from a post-move failure. An invalid selector throws
      // BEFORE any z_bytes_move, so the caller retains ownership — and the
      // added option arguments must not have moved that boundary.
      final payload = ZBytes.fromString('p');
      expect(
        () => getter.get(
          'bad//selector',
          payload: payload,
          congestionControl: CongestionControl.block,
        ),
        throwsA(anything),
      );
      // Still usable: the failure happened before the move.
      expect(payload.toBytes(), isNotEmpty);
    });
  });

  group('declareQuerier send options (TCP 18906)', () {
    late Session getter;
    late Session replier;

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18906"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18906"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      replier = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      replier.close();
    });

    Queryable replyOnce(Session session, String ke, {List<Query>? seen}) {
      final q = session.declareQueryable(ke);
      q.stream.listen((query) {
        seen?.add(query);
        query
          ..reply(ke, 'r')
          ..dispose();
      });
      return q;
    }

    Future<Reply> queryOnce(
      String ke, {
      CongestionControl? congestionControl,
      Priority? priority,
      bool? isExpress,
      ReplyKeyExpr? acceptReplies,
    }) async {
      final q = replyOnce(replier, ke);
      addTearDown(q.close);
      await _settle();

      final querier = getter.declareQuerier(
        ke,
        congestionControl: congestionControl,
        priority: priority,
        isExpress: isExpress,
        acceptReplies: acceptReplies,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);
      await _settle();

      final ok = (await querier.get().toList()).where((r) => r.isOk).toList();
      expect(
        ok,
        isNotEmpty,
        reason:
            'no reply arrived: the assertions that follow would be '
            'vacuous (upstream core #2516)',
      );
      return ok.first;
    }

    test('an explicitly set congestionControl and priority arrive', () async {
      // All five options are DECLARATION-time. Canon's
      // `z_querier_get_options_t` carries no QoS field at all, so there is no
      // per-call form to add — binding one would be over-translation.
      final r = await queryOnce(
        'zenoh/dart/test/d/qr/qos-set',
        congestionControl: CongestionControl.drop,
        priority: Priority.realTime,
      );
      expect(r.ok.congestionControl, CongestionControl.drop);
      expect(r.ok.priority, Priority.realTime);
    });

    test('an omitted congestionControl resolves to canon BLOCK', () async {
      // querier is a REQUEST path, like get: `DEFAULT_REQUEST` = BLOCK.
      final r = await queryOnce('zenoh/dart/test/d/qr/cc-omitted');
      expect(r.ok.congestionControl, CongestionControl.block);
    });

    test('an omitted priority resolves to canon data', () async {
      final r = await queryOnce('zenoh/dart/test/d/qr/prio-omitted');
      expect(r.ok.priority, Priority.data);
    });

    test('isExpress set at declaration is observable, and omitting it '
        'yields canon false', () async {
      // Closes coverage gap C-1: nothing else in the seed sets isExpress on a
      // declared querier, though the observation IS available — over TCP a
      // reply's express flag tracks the query, and the querier fixes the
      // query's express at declaration time.
      final on = await queryOnce(
        'zenoh/dart/test/d/qr/express-on',
        isExpress: true,
      );
      expect(on.ok.express, isTrue);

      final off = await queryOnce('zenoh/dart/test/d/qr/express-off');
      expect(off.ok.express, isFalse);
    });

    test('acceptReplies set at declaration reaches EVERY query', () async {
      // The value is fixed at declaration, so it must apply to the second
      // get() as well as the first — that is what distinguishes a
      // declaration-time option from a per-call one.
      const ke = 'zenoh/dart/test/d/qr/accept-any';
      final seen = <Query>[];
      final q = replyOnce(replier, ke, seen: seen);
      addTearDown(q.close);
      await _settle();

      final querier = getter.declareQuerier(
        ke,
        acceptReplies: ReplyKeyExpr.any,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);
      await _settle();

      await querier.get().toList();
      await querier.get().toList();

      expect(seen.length, greaterThanOrEqualTo(2), reason: 'two queries sent');
      expect(seen[0].acceptsReplies, ReplyKeyExpr.any);
      expect(seen[1].acceptsReplies, ReplyKeyExpr.any);
    });

    test('an omitted acceptReplies resolves to canon MATCHING_QUERY', () async {
      // Criterion B for acceptReplies on the querier path (coverage gap C-2).
      // It sits beside the criterion-A test above, on the same option and the
      // same path, so the pair discriminates "canon's default" from "nothing
      // was wired" — an omission test alone passes either way.
      const ke = 'zenoh/dart/test/d/qr/accept-omitted';
      final seen = <Query>[];
      final q = replyOnce(replier, ke, seen: seen);
      addTearDown(q.close);
      await _settle();

      final querier = getter.declareQuerier(
        ke,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(querier.close);
      await _settle();

      await querier.get().toList();
      expect(seen, isNotEmpty, reason: 'the queryable saw no query at all');
      expect(seen.first.acceptsReplies, ReplyKeyExpr.matchingQuery);
    });

    test('allowedDestination discriminates in all three modes', () async {
      // target: all + consolidation: none, both required — see the get group.
      Future<int> replyCount(String ke, Locality? dest) async {
        final localQ = replyOnce(getter, ke);
        final remoteQ = replyOnce(replier, ke);
        addTearDown(localQ.close);
        addTearDown(remoteQ.close);
        await _settle();

        final querier = getter.declareQuerier(
          ke,
          allowedDestination: dest,
          target: QueryTarget.all,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 5),
        );
        addTearDown(querier.close);
        await _settle();

        return (await querier.get().toList()).where((r) => r.isOk).length;
      }

      expect(
        await replyCount('zenoh/dart/test/d/qr/loc-any', Locality.any),
        2,
        reason:
            'CONTROL: both queryables must reply, or the restricted legs '
            'below prove nothing',
      );
      expect(
        await replyCount(
          'zenoh/dart/test/d/qr/loc-local',
          Locality.sessionLocal,
        ),
        1,
      );
      expect(
        await replyCount('zenoh/dart/test/d/qr/loc-remote', Locality.remote),
        1,
      );
      // Criterion B for locality on the querier path (coverage gap C-2).
      expect(await replyCount('zenoh/dart/test/d/qr/loc-omitted', null), 2);
    });

    test('no QoS parameter is added to Querier.get()', () async {
      // canon's `z_querier_get_options_t` carries payload/encoding/
      // source_info/attachment/cancellation_token and ZERO QoS fields, while
      // the declaration-time `z_querier_options_t` carries all three. Binding
      // a field canon does not have is the stronger form of over-translation.
      // CONTROL: the declare path DOES take them, so the instrument can see a
      // QoS parameter where one legitimately exists.
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final querier = code('lib/src/querier.dart');
      final getSig = querier.substring(
        querier.indexOf('Stream<Reply> get('),
        querier.indexOf('Stream<Reply> get(') + 200,
      );

      expect(
        querier,
        contains('CongestionControl? congestionControl'),
        reason: 'CONTROL: the DECLARATION path takes the QoS triple',
      );
      expect(getSig, isNot(contains('congestionControl')));
      expect(getSig, isNot(contains('priority')));
      expect(getSig, isNot(contains('isExpress')));
    });
  });
}
