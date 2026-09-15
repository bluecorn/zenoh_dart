import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Seed D slices 7-8 — `isExpress` on the reply path, and ONLY `isExpress`.
//
// canon marks `z_query_reply_options_t.congestion_control` and `.priority`
// deprecated and ignored ("Reply congestion control is not supported anymore"),
// and the C++ peer's reply()/reply_del() deliberately do not copy them into the
// C options. Binding them would be over-translation of a dead field, so they
// stay unexposed and a source-level test pins that.
//
// ⚠️ THE OBSERVABLE IS TOPOLOGY-INVERTED, and that shapes every test here.
// Measured: over TCP a reply's express flag tracks the QUERY; same-session it
// tracks the REPLY. So the round-trip assertion is confined to the same-session
// leg and is explicitly FORBIDDEN on the TCP leg — asserting it there would
// pass for the wrong reason, reading back the getter's own express rather than
// the reply's. The TCP leg instead asserts NON-PERTURBATION: setting isExpress
// must not disturb the reply's payload, encoding, attachment or timestamp.
//
// The observable is reproduced and reliable. Its MECHANISM is not understood —
// whether the transport recomputes a reply's QoS from the request, or the
// same-session path short-circuits. Recorded as open rather than guessed.

void main() {
  group('Query.reply isExpress (same-session)', () {
    late Session session;

    setUpAll(() async {
      // Single session hosting both the queryable and the getter: no network
      // hop, which is the topology in which a reply's express tracks the REPLY.
      final c = Config()
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session = await Session.open(config: c);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDownAll(() => session.close());

    Future<Reply> replyWith(
      String ke, {
      bool? isExpress,
      bool useBytes = false,
    }) async {
      final q = session.declareQueryable(ke);
      addTearDown(q.close);
      q.stream.listen((query) {
        if (useBytes) {
          query.replyBytes(ke, ZBytes.fromString('v'), isExpress: isExpress);
        } else {
          query.reply(ke, 'v', isExpress: isExpress);
        }
        query.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = await session
          .get(ke, timeout: const Duration(seconds: 5))
          .toList();
      final ok = replies.where((r) => r.isOk).toList();
      expect(ok, isNotEmpty, reason: 'no reply arrived (upstream core #2516)');
      return ok.first;
    }

    test('an explicitly set isExpress is observable same-session', () async {
      final on = await replyWith('zenoh/dart/test/d/rep/on', isExpress: true);
      expect(on.ok.express, isTrue);

      final off = await replyWith('zenoh/dart/test/d/rep/off');
      expect(
        off.ok.express,
        isFalse,
        reason:
            'CONTROL: without the flag the same topology must read false, '
            'or the true above is not evidence of anything',
      );
    });

    test('reply and replyBytes agree', () async {
      // The two Dart methods share one FFI signature and must agree.
      final viaString = await replyWith(
        'zenoh/dart/test/d/rep/str',
        isExpress: true,
      );
      final viaBytes = await replyWith(
        'zenoh/dart/test/d/rep/bytes',
        isExpress: true,
        useBytes: true,
      );
      expect(viaString.ok.express, isTrue);
      expect(viaBytes.ok.express, isTrue);
      expect(viaBytes.ok.payloadBytes, equals(viaString.ok.payloadBytes));
    });

    test(
      'an explicitly set isExpress is observable on a DELETE reply',
      () async {
        // Slice 8: replyDel, same topology.
        Future<Reply> replyDelWith(String ke, {bool? isExpress}) async {
          final q = session.declareQueryable(ke);
          addTearDown(q.close);
          q.stream.listen((query) {
            query
              ..replyDel(ke, isExpress: isExpress)
              ..dispose();
          });
          await Future<void>.delayed(const Duration(milliseconds: 300));

          final ok =
              (await session
                      .get(ke, timeout: const Duration(seconds: 5))
                      .toList())
                  .where((r) => r.isOk)
                  .toList();
          expect(ok, isNotEmpty, reason: 'no reply arrived');
          return ok.first;
        }

        final on = await replyDelWith(
          'zenoh/dart/test/d/repdel/on',
          isExpress: true,
        );
        expect(on.ok.kind, SampleKind.delete);
        expect(on.ok.express, isTrue);

        final off = await replyDelWith('zenoh/dart/test/d/repdel/off');
        expect(off.ok.kind, SampleKind.delete);
        expect(
          off.ok.express,
          isFalse,
          reason:
              'canon z_query_reply_del_options_default leaves express false',
        );
      },
    );

    test(
      'a DELETE reply carries no payload, and canon default encoding',
      () async {
        const ke = 'zenoh/dart/test/d/repdel/shape';
        final q = session.declareQueryable(ke);
        addTearDown(q.close);
        q.stream.listen((query) {
          query
            ..replyDel(ke, isExpress: true)
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final ok =
            (await session
                    .get(ke, timeout: const Duration(seconds: 5))
                    .toList())
                .where((r) => r.isOk)
                .toList();
        expect(ok, isNotEmpty);
        expect(ok.first.ok.payloadBytes, isEmpty);
        // MEASURED, and not what the plan predicted: a DELETE reply arrives
        // carrying canon's DEFAULT encoding `zenoh/bytes`, not an absent one.
        // The plan's text said "no encoding is set"; the wire says otherwise.
        // Pinned to the measured value rather than relaxed to
        // `anyOf(isNull, isEmpty, ...)` — widening a matcher to accommodate a
        // surprise discards the assertion instead of modelling the contract.
        expect(ok.first.ok.encoding, 'zenoh/bytes');
      },
    );
  });

  group('reply isExpress does not perturb the reply over TCP (18908)', () {
    late Session getter;
    late Session replier;

    setUpAll(() async {
      final c1 = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:18908"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: c1);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final c2 = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:18908"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      replier = await Session.open(config: c2);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      replier.close();
    });

    test('payload, encoding, attachment and timestamp all survive', () async {
      // NO assertion is made on `reply.ok.express` here — over TCP it tracks
      // the query, not the reply, so it would be a false green.
      final payload = Uint8List.fromList([0, 200, 255, 1, 0, 128]);

      Future<Reply> send(String ke, {bool? isExpress}) async {
        final q = replier.declareQueryable(ke);
        addTearDown(q.close);
        q.stream.listen((query) {
          query
            ..replyBytes(
              ke,
              ZBytes.fromUint8List(payload),
              encoding: Encoding.applicationJson,
              attachment: ZBytes.fromString('att'),
              timestamp: replier.newTimestamp(),
              isExpress: isExpress,
            )
            ..dispose();
        });
        await Future<void>.delayed(const Duration(seconds: 1));

        final ok =
            (await getter.get(ke, timeout: const Duration(seconds: 5)).toList())
                .where((r) => r.isOk)
                .toList();
        expect(ok, isNotEmpty, reason: 'no reply arrived');
        return ok.first;
      }

      final withExpress = await send(
        'zenoh/dart/test/d/rep/tcp-on',
        isExpress: true,
      );
      final without = await send('zenoh/dart/test/d/rep/tcp-off');

      for (final r in [withExpress, without]) {
        expect(r.ok.payloadBytes, equals(payload));
        expect(r.ok.encoding, Encoding.applicationJson.mimeType);
        expect(r.ok.attachmentBytes, isNotNull);
        expect(r.ok.timestamp, isNotNull);
      }
    });

    test(
      'a DELETE reply over TCP keeps its attachment and timestamp',
      () async {
        Future<Reply> send(String ke, {bool? isExpress}) async {
          final q = replier.declareQueryable(ke);
          addTearDown(q.close);
          q.stream.listen((query) {
            query
              ..replyDel(
                ke,
                attachment: ZBytes.fromString('att'),
                timestamp: replier.newTimestamp(),
                isExpress: isExpress,
              )
              ..dispose();
          });
          await Future<void>.delayed(const Duration(seconds: 1));

          final ok =
              (await getter
                      .get(ke, timeout: const Duration(seconds: 5))
                      .toList())
                  .where((r) => r.isOk)
                  .toList();
          expect(ok, isNotEmpty, reason: 'no reply arrived');
          return ok.first;
        }

        for (final r in [
          await send('zenoh/dart/test/d/repdel/tcp-on', isExpress: true),
          await send('zenoh/dart/test/d/repdel/tcp-off'),
        ]) {
          expect(r.ok.kind, SampleKind.delete);
          expect(r.ok.attachmentBytes, isNotNull);
          expect(r.ok.timestamp, isNotNull);
        }
      },
    );
  });

  group('the reply path exposes no deprecated QoS', () {
    test('reply, replyBytes and replyDel take isExpress and nothing else', () {
      // canon deprecates and IGNORES reply congestion_control and priority
      // (zenoh_commons.h:1250-1259 and :1286-1295), and the C++ peer does not
      // copy them. The CONTROL proves the instrument can see these parameter
      // names where they legitimately exist — session.dart binds all three.
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final query = code('lib/src/query.dart');
      final session = code('lib/src/session.dart');

      expect(
        session,
        contains('CongestionControl? congestionControl'),
        reason:
            'CONTROL: the send paths DO bind congestionControl, so its '
            'absence in query.dart is a real negative',
      );
      expect(
        query,
        contains('bool? isExpress'),
        reason: 'the one live QoS field on the reply path',
      );
      expect(query, isNot(contains('congestionControl')));
      expect(query, isNot(contains('Priority? priority')));
    });
  });
}
