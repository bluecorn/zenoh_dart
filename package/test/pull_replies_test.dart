// Seed #6: the reply channel — canon's bounded fifo/ring delivery on
// `Session.get`, consumed through a paced pull handle instead of a stream.
//
// ⚠️ EVERY overflow / backpressure / drain cell in this file uses TWO SESSIONS,
// and that is a hard bound rather than a preference. Measured canon-direct
// (seed #6 survey, probe 2 / GT 8): on a same-session route the local delivery
// runs SYNCHRONOUSLY inside the caller's `z_get`, so a fifo reply channel that
// fills up freezes the getter inside the FFI call — timeout-killed at >25 s,
// with the get's own `timeout_ms` unable to rescue a thread stuck in the
// synchronous local push. A same-session fifo-full cell would not fail; it
// would freeze the suite.
//
// The reply column's lifecycle differs from the sample column's in a way these
// cells keep visible: a reply channel SELF-TERMINATES. Canon drops the closure
// "once all replies are processed", so `RecvDisconnected` here means "this
// query is done", not "somebody undeclared something".
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/features.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

void main() {
  /// Opens a listener/connector pair and returns (replier, getter) sessions.
  /// Discovery is off on both sides: a test that inherits the LAN is testing
  /// the LAN.
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final replierSession = await Session.open(config: listener);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final getterSession = await Session.open(config: connector);
    await Future<void>.delayed(const Duration(seconds: 1));
    return (replierSession, getterSession);
  }

  group('Slice 4: fifo reply channel, end to end (TCP 19350)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19350);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Declares a Stream-path queryable on [key] that replies once with
    /// [payload] and finalises the query.
    void replyOnceWith(String key, Uint8List payload) {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..replyBytes(key, ZBytes.fromUint8List(payload))
          ..dispose();
      });
    }

    test('a reply arrives through a fifo reply channel', () async {
      const key = 'zenoh/dart/test/s4/fifo/basic';
      // Deliberately carries a NUL and an invalid-UTF-8 byte, so a lossy
      // extraction path could not pass this cell.
      final payload = Uint8List.fromList([0x7a, 0x64, 0x00, 0xff, 0x2a]);
      replyOnceWith(key, payload);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(replies.dispose);

      final result = await pollUntilNotEmpty(replies.tryRecv);
      expect(result, isA<RecvData<Reply>>());
      final reply = (result as RecvData<Reply>).value;
      expect(reply.isOk, isTrue);
      expect(reply.ok.payloadBytes, equals(payload));
    });

    test('an empty channel reports alive-and-empty, not terminal', () async {
      // The back-off arm of a polling loop, and the reason the discriminant is
      // three-valued rather than nullable: "nothing yet" and "stop polling"
      // are different instructions to the caller.
      const key = 'zenoh/dart/test/s4/fifo/empty';
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      final held = <Query>[];
      queryable.stream.listen(held.add);
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        timeout: const Duration(seconds: 30),
      );
      addTearDown(replies.dispose);

      expect(replies.tryRecv(), isA<RecvEmpty<Reply>>());
    });

    test(
      'the channel disconnects when the query completes, and it sticks',
      () async {
        const key = 'zenoh/dart/test/s4/fifo/done';
        replyOnceWith(key, Uint8List.fromList([1, 2, 3]));
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(replies.dispose);

        final drained = await drainToTerminal(replies.tryRecv);
        expect(drained, hasLength(1));
        // Terminal AND sticky: canon's DISCONNECTED is not a one-shot edge, and
        // a polling loop that stopped on the first one must be able to observe
        // it again.
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
      },
    );

    test('an error reply flows through the same channel', () async {
      const key = 'zenoh/dart/test/s4/fifo/err';
      final errorBytes = Uint8List.fromList([0xde, 0xad, 0x00, 0xbe, 0xef]);
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..replyErrBytes(ZBytes.fromUint8List(errorBytes))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(replies.dispose);

      final result = await pollUntilNotEmpty(replies.tryRecv);
      expect(result, isA<RecvData<Reply>>());
      final reply = (result as RecvData<Reply>).value;
      // The ok/err discriminant survives the channel rather than being
      // flattened into "a reply arrived".
      expect(reply.isOk, isFalse);
      expect(reply.error.payloadBytes, equals(errorBytes));
    });

    test('the handle reports the kind it was declared with', () async {
      final fifo = getterSession.pullGet(
        'zenoh/dart/test/s4/kind/fifo',
        kind: ChannelKind.fifo,
        capacity: 1,
      );
      addTearDown(fifo.dispose);
      final ring = getterSession.pullGet(
        'zenoh/dart/test/s4/kind/ring',
        kind: ChannelKind.ring,
        capacity: 1,
      );
      addTearDown(ring.dispose);

      expect(fifo.kind, equals(ChannelKind.fifo));
      expect(ring.kind, equals(ChannelKind.ring));
    });

    test('releasing the handle is local-only and idempotent', () async {
      const key = 'zenoh/dart/test/s4/fifo/dispose';
      replyOnceWith(key, Uint8List.fromList([9]));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      await drainToTerminal(replies.tryRecv);

      expect(replies.dispose, returnsNormally);
      // Idempotent: a second release must not drop a native handle twice.
      expect(replies.dispose, returnsNormally);
      // And the handle's OWN closed state is a StateError, deliberately
      // distinct from the channel's RecvDisconnected: one says "you released
      // this", the other says "the producer is gone".
      expect(replies.tryRecv, throwsA(isA<StateError>()));
    });
  });

  // -------------------------------------------------------------------------
  // Slice 5: the ring kind, and the per-kind drain contract at completion.
  //
  // These are HONESTY CELLS. Measured canon-direct (seed #6 survey, GT 6): a
  // ring channel DISCARDS ITS WHOLE BUFFER at disconnect, and because a get's
  // completion normally follows its replies immediately, a ring reply channel
  // recovers nothing unless it is polled while the query is still in flight.
  // The cells below assert the measured loss rather than a wish — a ring reply
  // channel that "worked like fifo" would be this binding smoothing over
  // canon's own behaviour.
  //
  // ⚠️ EVERY CELL HERE PASSES `ConsolidationMode.none`, and that is an
  // INSTRUMENT decision with a measurement behind it, not a stylistic one.
  // canon's default is `auto`, which resolves to a consolidating mode, and a
  // consolidating get both DEDUPES replies by key expression and WITHHOLDS them
  // until the query completes. Measured through this stack
  // (test/helpers/probes/probe_consolidation_vs_channel.dart):
  //
  //   auto:  fifo_after_completion=1  ring_after=0  ring_inflight=0
  //   none:  fifo_after_completion=3  ring_after=0  ring_inflight=1
  //
  // So under `auto` three replies on one key reach the channel as ONE, and
  // nothing is visible in flight. A drain cell run that way would be measuring
  // consolidation and reporting it as a channel property.
  group('Slice 5: ring versus fifo at query completion (TCP 19351)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19351);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Declares a queryable that replies [count] times and then finalises.
    void replyNTimes(String key, int count) {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        for (var i = 0; i < count; i++) {
          query.reply(key, 'reply-$i');
        }
        query.dispose();
      });
    }

    /// Declares a queryable that replies once and then HOLDS the query open,
    /// so the channel stays connected while the test polls it.
    void replyOnceAndHold(String key) {
      final held = <Query>[];
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query.reply(key, 'in-flight');
        held.add(query);
      });
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });
    }

    test(
      'a ring reply channel delivers while the query is in flight',
      () async {
        const key = 'zenoh/dart/test/s5/ring/inflight';
        replyOnceAndHold(key);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          key,
          kind: ChannelKind.ring,
          capacity: 4,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 30),
        );
        addTearDown(replies.dispose);

        final result = await pollUntilNotEmpty(replies.tryRecv);
        // The in-flight positive arm. It is also the CONTROL for the two cells
        // below: without it, a ring recovering zero after completion could just
        // as well mean the ring never delivers anything at all.
        expect(result, isA<RecvData<Reply>>());
        expect(
          (result as RecvData<Reply>).value.ok.payload,
          equals('in-flight'),
        );
      },
    );

    test('a ring reply channel discards its buffer at query completion', () async {
      const key = 'zenoh/dart/test/s5/ring/discard';
      replyNTimes(key, 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.ring,
        capacity: 4,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(replies.dispose);

      // Settle time, not a race: the replier answers and finalises at once, so
      // this is "let the query finish before looking", which has no condition
      // to poll for -- polling IS the thing being withheld.
      await Future<void>.delayed(const Duration(seconds: 1));

      final drained = await drainToTerminal(replies.tryRecv);
      expect(drained, isEmpty);
      expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
    });

    test(
      'a fifo reply channel drains its buffer before reporting disconnected',
      () async {
        const key = 'zenoh/dart/test/s5/fifo/drain';
        replyNTimes(key, 2);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
          consolidation: ConsolidationMode.none,
        );
        addTearDown(replies.dispose);

        await Future<void>.delayed(const Duration(seconds: 1));

        final drained = await drainToTerminal(replies.tryRecv);
        expect(drained, hasLength(2));
        expect(
          drained.map((r) => r.ok.payload).toList(),
          equals(['reply-0', 'reply-1']),
        );
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
      },
    );

    test(
      'the two kinds are contrasted at the same volume and capacity',
      () async {
        // The DISCRIMINATOR is the contrast, not either absolute: the same
        // replier, the same volume, the same capacity, drained the same way.
        const key = 'zenoh/dart/test/s5/contrast';
        replyNTimes(key, 3);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final fifo = getterSession.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
          consolidation: ConsolidationMode.none,
        );
        addTearDown(fifo.dispose);
        await Future<void>.delayed(const Duration(seconds: 1));
        final fifoDrained = await drainToTerminal(fifo.tryRecv);

        final ring = getterSession.pullGet(
          key,
          kind: ChannelKind.ring,
          capacity: 4,
          consolidation: ConsolidationMode.none,
        );
        addTearDown(ring.dispose);
        await Future<void>.delayed(const Duration(seconds: 1));
        final ringDrained = await drainToTerminal(ring.tryRecv);

        expect(fifoDrained, hasLength(3));
        expect(ringDrained, isEmpty);
      },
    );

    test('both kinds reach the terminal state with nothing buffered', () async {
      // The queryable FINALISES WITHOUT REPLYING -- it disposes the query, so
      // ResponseFinal produces a clean zero-reply completion. Letting the query
      // time out instead would deliver canon's 'Timeout' error reply first and
      // this cell would be measuring the timeout family rather than the
      // terminal state. Zero replies is a legitimate get outcome.
      const key = 'zenoh/dart/test/s5/finalise';
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) => query.dispose());
      await Future<void>.delayed(const Duration(milliseconds: 300));

      for (final kind in ChannelKind.values) {
        final replies = getterSession.pullGet(
          key,
          kind: kind,
          capacity: 4,
          consolidation: ConsolidationMode.none,
        );
        addTearDown(replies.dispose);
        final result = await pollUntilNotEmpty(replies.tryRecv);
        expect(
          result,
          isA<RecvDisconnected<Reply>>(),
          reason: 'kind $kind should reach the terminal state with no error',
        );
      }
    });
  });
  // -------------------------------------------------------------------------
  // Slice 6: value fidelity through the reply channel, and the off-key
  // acceptance arm.
  //
  // Fidelity cells drive the CONTRACT's domain, not today's consumer's, and the
  // unit is the round-trip PAIR: each cell drives a value in through a real
  // replier and asserts byte-exact equality coming out. Structural parity — the
  // channel path delivering "a Reply" — is necessary and not sufficient: the
  // v0.18.1 defect passed every structural check while corrupting every
  // non-UTF-8 payload.
  //
  // The oracle is the Stream path: every field `Session.get` delivers must be
  // delivered here, none dropped and none invented.
  group('Slice 6: reply value fidelity through the channel (TCP 19352)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19352);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Runs [answer] as the queryable's reply body and returns the single
    /// reply the channel hands over.
    Future<Reply> oneReplyVia(
      String key,
      void Function(Query query) answer, {
      ReplyKeyExpr? acceptReplies,
    }) async {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        answer(query);
        query.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        acceptReplies: acceptReplies,
      );
      addTearDown(replies.dispose);

      final result = await pollUntilNotEmpty(replies.tryRecv);
      expect(result, isA<RecvData<Reply>>(), reason: 'no reply arrived');
      return (result as RecvData<Reply>).value;
    }

    test('the ok reply key expression arrives byte-exact', () async {
      const key = 'zenoh/dart/test/s6/keyexpr';
      final reply = await oneReplyVia(key, (q) => q.reply(key, 'x'));
      // Length-carried rather than strlen-measured; equality is on the whole
      // string, not a prefix.
      expect(reply.ok.keyExpr, equals(key));
    });

    test('a binary, invalid-UTF-8 reply payload arrives byte-exact', () async {
      const key = 'zenoh/dart/test/s6/payload/binary';
      // 0xff and 0xfe are not valid UTF-8 anywhere, and the NUL would truncate
      // any C-string carriage: a lossy path cannot pass this.
      final sent = Uint8List.fromList([0x00, 0xff, 0x10, 0xfe, 0x7f, 0x00]);
      final reply = await oneReplyVia(
        key,
        (q) => q.replyBytes(key, ZBytes.fromUint8List(sent)),
      );
      expect(reply.ok.payloadBytes, equals(sent));
      // ...and the display view is the LENIENT decode of those same bytes, not
      // a second source of truth.
      expect(reply.ok.payload, contains('�'));
    });

    test('valid-UTF-8 and empty reply payloads round-trip', () async {
      const utf8Key = 'zenoh/dart/test/s6/payload/utf8';
      final utf8Reply = await oneReplyVia(
        utf8Key,
        (q) => q.reply(utf8Key, 'héllo-🛰-键'),
      );
      expect(utf8Reply.ok.payload, equals('héllo-🛰-键'));

      const emptyKey = 'zenoh/dart/test/s6/payload/empty';
      final emptyReply = await oneReplyVia(
        emptyKey,
        (q) => q.replyBytes(emptyKey, ZBytes.fromUint8List(Uint8List(0))),
      );
      // Non-null and empty: a zero-length payload is a value, not an absence.
      expect(emptyReply.ok.payloadBytes, isNotNull);
      expect(emptyReply.ok.payloadBytes, isEmpty);
    });

    test('a present-but-empty reply attachment is not an absent one', () async {
      const emptyKey = 'zenoh/dart/test/s6/attach/empty';
      final withEmpty = await oneReplyVia(
        emptyKey,
        (q) => q.reply(
          emptyKey,
          'x',
          attachment: ZBytes.fromUint8List(Uint8List(0)),
        ),
      );
      expect(withEmpty.ok.attachmentBytes, isNotNull);
      expect(withEmpty.ok.attachmentBytes, isEmpty);

      const absentKey = 'zenoh/dart/test/s6/attach/absent';
      final withNone = await oneReplyVia(
        absentKey,
        (q) => q.reply(absentKey, 'x'),
      );
      expect(withNone.ok.attachmentBytes, isNull);
    });

    test('a binary reply attachment arrives byte-exact', () async {
      const key = 'zenoh/dart/test/s6/attach/binary';
      final sent = Uint8List.fromList([0xde, 0x00, 0xad, 0xff]);
      final reply = await oneReplyVia(
        key,
        (q) => q.reply(key, 'x', attachment: ZBytes.fromUint8List(sent)),
      );
      expect(reply.ok.attachmentBytes, equals(sent));
    });

    test('the reply encoding arrives', () async {
      const key = 'zenoh/dart/test/s6/encoding';
      final reply = await oneReplyVia(
        key,
        (q) => q.reply(key, '{}', encoding: Encoding.applicationJson),
      );
      expect(reply.ok.encoding, equals(Encoding.applicationJson.mimeType));
    });

    test(
      'the reply timestamp arrives when present and is null when absent',
      () async {
        const withKey = 'zenoh/dart/test/s6/ts/present';
        final stamp = replierSession.newTimestamp();
        final withTs = await oneReplyVia(
          withKey,
          (q) => q.reply(withKey, 'x', timestamp: stamp),
        );
        expect(withTs.ok.timestamp, isNotNull);
        expect(withTs.ok.timestamp!.rawBytes, equals(stamp.rawBytes));

        const withoutKey = 'zenoh/dart/test/s6/ts/absent';
        final withoutTs = await oneReplyVia(
          withoutKey,
          (q) => q.reply(withoutKey, 'x'),
        );
        expect(withoutTs.ok.timestamp, isNull);
      },
    );

    test('the QoS trio arrives on the reply sample', () async {
      const key = 'zenoh/dart/test/s6/qos';
      final reply = await oneReplyVia(
        key,
        (q) => q.reply(key, 'x', isExpress: true),
      );
      // canon's OWN values, whatever they are — no assertion is built on
      // reply-side congestion or priority being settable, because canon
      // deprecated both and forces a response's QoS to match the query's.
      expect(reply.ok.priority, isA<Priority>());
      expect(reply.ok.congestionControl, isA<CongestionControl>());
      expect(reply.ok.express, isA<bool>());
    });

    test('the replier id arrives where the unstable API is compiled in', () async {
      const okKey = 'zenoh/dart/test/s6/replier/ok';
      final okReply = await oneReplyVia(okKey, (q) => q.reply(okKey, 'x'));
      const errKey = 'zenoh/dart/test/s6/replier/err';
      final errReply = await oneReplyVia(errKey, (q) => q.replyErr('bad'));

      if (ZenohFeatures.hasUnstableApi) {
        expect(okReply.replierId, isNotNull);
        expect(okReply.replierId!.zid, equals(replierSession.zid));
        expect(errReply.replierId, isNotNull);
        expect(errReply.replierId!.zid, equals(replierSession.zid));
      } else {
        // The array shape is CONSTANT across variants -- the #ifdef gates only
        // the value extraction -- so the stable build reads null rather than
        // parsing a differently-shaped message.
        expect(okReply.replierId, isNull);
        expect(errReply.replierId, isNull);
      }
    });

    test('an error reply payload and encoding arrive byte-exact', () async {
      const key = 'zenoh/dart/test/s6/err/binary';
      final sent = Uint8List.fromList([0x00, 0xc0, 0xff, 0xee]);
      final reply = await oneReplyVia(
        key,
        (q) => q.replyErrBytes(
          ZBytes.fromUint8List(sent),
          encoding: Encoding.applicationJson,
        ),
      );
      expect(reply.isOk, isFalse);
      expect(reply.error.payloadBytes, equals(sent));
      expect(reply.error.encoding, equals(Encoding.applicationJson.mimeType));
    });

    test(
      'under acceptReplies: any an off-key reply is accepted and delivered',
      () async {
        const asked = 'zenoh/dart/test/s6/offkey/asked';
        const unrelated = 'zenoh/dart/test/s6/offkey/unrelated';

        Object? replyError;
        final queryable = replierSession.declareQueryable(asked);
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          try {
            query.reply(unrelated, 'off-key');
          } on Object catch (e) {
            replyError = e;
          }
          query.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          asked,
          kind: ChannelKind.fifo,
          capacity: 4,
          consolidation: ConsolidationMode.none,
          acceptReplies: ReplyKeyExpr.any,
        );
        addTearDown(replies.dispose);

        final drained = await drainToTerminal(replies.tryRecv);
        // BOTH endpoints asserted: the replier's call did not throw, AND the
        // disjoint reply was delivered carrying its own key expression. Either
        // half alone would be satisfied by the wrong thing.
        expect(replyError, isNull, reason: 'off-key reply was refused');
        expect(drained, hasLength(1));
        expect(drained.single.ok.keyExpr, equals(unrelated));
      },
    );

    test(
      'under the default policy the same off-key reply is refused',
      () async {
        // The control that makes the acceptance cell above a real observation:
        // same topology, same disjoint reply, only the policy differs.
        const asked = 'zenoh/dart/test/s6/offkey/default/asked';
        const unrelated = 'zenoh/dart/test/s6/offkey/default/unrelated';

        Object? replyError;
        final queryable = replierSession.declareQueryable(asked);
        addTearDown(queryable.close);
        queryable.stream.listen((query) {
          try {
            query.reply(unrelated, 'off-key');
          } on Object catch (e) {
            replyError = e;
          }
          query
            ..reply(asked, 'on-key')
            ..dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          asked,
          kind: ChannelKind.fifo,
          capacity: 4,
          consolidation: ConsolidationMode.none,
        );
        addTearDown(replies.dispose);

        final drained = await drainToTerminal(replies.tryRecv);
        expect(replyError, isA<ZenohException>());
        expect((replyError! as ZenohException).returnCode, equals(-128));
        expect(drained, hasLength(1));
        expect(drained.single.ok.keyExpr, equals(asked));
        expect(drained.single.ok.payload, equals('on-key'));
      },
    );
  });
  // -------------------------------------------------------------------------
  // Slice 7: the capacity contract on the channel-mode entries.
  //
  // Shipped at seed #5 for the sample column and extended here unchanged:
  // negatives are refused Dart-side BEFORE any native call (a negative would
  // otherwise be reinterpreted as an enormous unsigned `size_t` — a silent
  // transform, not a refusal); zero passes through and is pinned per kind; no
  // upper bound is invented, because rejecting a large-but-representable
  // capacity would narrow canon's surface on no canon-intrinsic ground.
  group('Slice 7: the capacity contract on pullGet (TCP 19353)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19353);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    test('a negative capacity is refused before any native call', () async {
      const key = 'zenoh/dart/test/s7/negative';
      // The queryable is the OUTSIDE VIEW: a refused pullGet must not have sent
      // a query. If it had, this queryable would see one.
      var queriesSeen = 0;
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        queriesSeen++;
        query
          ..reply(key, 'ack')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      for (final kind in ChannelKind.values) {
        expect(
          () => getterSession.pullGet(key, kind: kind, capacity: -1),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('capacity'),
            ),
          ),
          reason: 'kind=$kind',
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(queriesSeen, isZero, reason: 'a refused pullGet sent a query');

      // CONTROL, and load-bearing: `isZero` above would hold just as well if
      // this queryable never saw anything at all. A valid pullGet on the same
      // key must reach it.
      final valid = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(valid.dispose);
      await drainToTerminal(valid.tryRecv);
      expect(queriesSeen, equals(1));
    });

    test('capacity 0 on a fifo is a rendezvous that delivers under polling', () async {
      // MEASURED AT 1.8.0, NOT PROMISED BY CANON, which documents nothing about
      // capacity. Zero is inside canon's `size_t` domain, so refusing it would
      // narrow canon's surface on no canon-intrinsic ground. A capacity-0 fifo
      // is a RENDEZVOUS -- full when empty -- and a synchronous poll is itself
      // the concurrent consumer the rendezvous needs.
      const key = 'zenoh/dart/test/s7/zero/fifo';
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(key, 'rendezvous')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 0,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(replies.dispose);

      final drained = await drainToTerminal(replies.tryRecv);
      expect(drained, hasLength(1));
      expect(drained.single.ok.payload, equals('rendezvous'));
      expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
    });

    test('capacity 0 on a ring recovers nothing after completion', () async {
      const key = 'zenoh/dart/test/s7/zero/ring';
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..reply(key, 'lost')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.ring,
        capacity: 0,
        consolidation: ConsolidationMode.none,
      );
      addTearDown(replies.dispose);
      // Settle: let the query finish before looking.
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(await drainToTerminal(replies.tryRecv), isEmpty);
    });

    test('a large but representable capacity is not refused', () async {
      // No upper bound is invented. This is well inside `size_t` on every
      // target this package ships to.
      final replies = getterSession.pullGet(
        'zenoh/dart/test/s7/large',
        kind: ChannelKind.fifo,
        capacity: 1 << 20,
      );
      addTearDown(replies.dispose);
      expect(replies.kind, equals(ChannelKind.fifo));
    });

    test('the shim refuses out-of-range capacity with its own positive code', () async {
      // THE STRUCTURAL BACKSTOP, reached through the bindings directly: the
      // Dart guard makes this unreachable from the public API, which is exactly
      // why it needs its own cell -- otherwise the property rests entirely on
      // the caller.
      //
      // The declare channel's return space is SPLIT: canon owns 0-and-negative,
      // the shim's own refusals are POSITIVE and start at 10, because a
      // shim-owned -1 would squat on a live canon code and let a canon EINVAL
      // masquerade as our failure.
      final handler = calloc<Uint8>(bindings.zd_reply_handler_sizeof(1));
      addTearDown(() => calloc.free(handler));
      final ke = KeyExpr('zenoh/dart/test/s7/backstop');
      addTearDown(ke.dispose);

      final teeOut = calloc<Pointer<Uint8>>();
      addTearDown(() => calloc.free(teeOut));
      final rc = bindings.zd_get_channel(
        handler,
        teeOut,
        0,
        bindings.zd_session_loan(getterSession.loanedHandle.cast()).cast(),
        ke.loanedKeyExpr.cast(),
        1,
        -1,
        0,
        0,
        nullptr,
        // encoding + its length, then the schema channel + its length: the
        // seed-#10 carriage change. Both absent here — this cell is about the
        // capacity refusal, which happens before any encoding is built.
        nullptr,
        0,
        nullptr,
        0,
        0,
        nullptr,
        0,
        nullptr,
        -1,
        -1,
        -1,
        -1,
        -1,
      );
      expect(rc, equals(10));
      // Nothing was claimed on the refusal path, so there is no shim block for
      // the caller to release.
      expect(teeOut.value, equals(nullptr));
    });
  });
  // -------------------------------------------------------------------------
  // Slice 8: the backpressure prong — the seed's one MANDATORY criterion.
  //
  // What has to be shown is that the fifo channel is a REAL bound: lossless
  // through overflow, with the boundedness coming from the channel's own
  // capacity rather than from a Dart-side buffer that grows with traffic. A
  // rendering that eagerly drained into an unbounded `StreamController` would
  // pass a naive in-order test while failing this criterion by construction —
  // which is exactly the "fake bound" the register bars.
  //
  // The OBSERVABLE is losslessness-through-overflow CONTRASTED AGAINST A RING
  // CONTROL at the same capacity and volume. Producer blocking is not directly
  // observable in the only permitted topology: with two sessions the replier is
  // never the blocked party (that is the point of using two), so "the producer
  // blocked" cannot be asserted — but a fake bound cannot produce the ring's
  // loss at the same capacity, so the contrast is the discriminator.
  //
  // ⚠️ TWO SESSIONS, unconditionally. Same-session delivery runs inside the
  // getter's own `z_get` call, so a full fifo there freezes the caller inside
  // the FFI boundary with no timeout escape (>25 s, measured). That deadlock is
  // a dartdoc-and-topology bound, NOT a test cell.
  group('Slice 8: fifo backpressure versus ring loss (TCP 19360)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19360);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Declares a queryable that answers with [count] numbered replies as fast
    /// as it can, then finalises.
    void replyBurst(String key, int count) {
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        for (var i = 0; i < count; i++) {
          query.reply(key, '$i');
        }
        query.dispose();
      });
    }

    /// Drains [replies] to its terminal state at [pace] per take, recording
    /// whether `RecvDisconnected` was ever seen before the drain finished.
    Future<({List<String> payloads, bool earlyDisconnect})> drainSlowly(
      PullReplies replies, {
      Duration pace = const Duration(milliseconds: 20),
      Duration timeout = const Duration(seconds: 30),
    }) async {
      final payloads = <String>[];
      var earlyDisconnect = false;
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final result = replies.tryRecv();
        if (result is RecvData<Reply>) {
          payloads.add(result.value.ok.payload);
          // The CONSUMER'S PACE. This is not an assertion standing in for the
          // observable -- it is what makes the consumer slower than the burst,
          // which is the precondition the criterion names.
          await Future<void>.delayed(pace);
          continue;
        }
        if (result is RecvDisconnected<Reply>) {
          earlyDisconnect = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return (payloads: payloads, earlyDisconnect: earlyDisconnect);
    }

    test('a fifo reply channel is lossless and in order through overflow', () async {
      const key = 'zenoh/dart/test/s8/fifo/lossless';
      const volume = 20;
      // Capacity is a small fraction of the volume, so the channel MUST
      // overflow. The volume is kept modest deliberately: it has to fit under
      // the loopback link's own queue slack, or the cell would be measuring the
      // transport rather than the channel.
      replyBurst(key, volume);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 2,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 60),
      );
      addTearDown(replies.dispose);

      final drain = await drainSlowly(replies);

      expect(drain.payloads, hasLength(volume));
      expect(
        drain.payloads,
        equals([for (var i = 0; i < volume; i++) '$i']),
        reason: 'fifo must be lossless AND in order',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the terminal state arrives only after the last reply is handed over', () async {
      const key = 'zenoh/dart/test/s8/fifo/terminal';
      const volume = 12;
      replyBurst(key, volume);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 2,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 60),
      );
      addTearDown(replies.dispose);

      final drain = await drainSlowly(replies);

      // Completion is DELAYED BY THE UNCONSUMED BUFFER: every reply was handed
      // over before the channel reported disconnected, even though the query
      // itself finished long before the drain did.
      expect(drain.payloads, hasLength(volume));
      expect(drain.earlyDisconnect, isTrue);
      expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a ring channel at the same capacity and volume recovers nothing', () async {
      // THE CONTRAST CONTROL, and the whole reason the cell above is evidence:
      // identical replier, identical volume, identical capacity, identical
      // drain pace. A rendering whose "bound" was really an unbounded Dart-side
      // buffer would be lossless HERE too, and this cell would fail.
      //
      // MEASURED, and asserted as measured rather than as `lessThan(volume)`:
      // the ring recovers **zero**, not "some but fewer"
      // (test/helpers/probes/probe_backpressure_counts.dart —
      // `ring vol=20 cap=2 recovered=0` against `fifo ... recovered=20`). At
      // this volume the whole burst AND the query's completion land before the
      // first poll, so what is observed here is the ring's
      // discard-at-disconnect rather than drop-oldest. A `lessThan` matcher
      // would have been satisfied
      // by that zero without saying so — the cell below drives drop-oldest
      // itself, so neither behaviour is left standing in for the other.
      const key = 'zenoh/dart/test/s8/ring/lossy';
      const volume = 20;
      replyBurst(key, volume);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.ring,
        capacity: 2,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 60),
      );
      addTearDown(replies.dispose);

      final drain = await drainSlowly(replies);

      expect(drain.payloads, isEmpty);
      expect(drain.earlyDisconnect, isTrue);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a ring channel drops the oldest while the query is in flight', () async {
      // The drop-oldest observable, driven where it is actually reachable: the
      // replier PACES its replies so the consumer can poll in flight, and the
      // ring at capacity 2 overwrites what it cannot hold. Without this cell
      // the ring's "loss" would rest entirely on the discard-at-disconnect
      // above, and drop-oldest — the property that makes ring a *lossy
      // bounded* channel rather than one that just throws its buffer away —
      // would be unpinned on this carrier.
      const key = 'zenoh/dart/test/s8/ring/dropoldest';
      const volume = 12;
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) async {
        for (var i = 0; i < volume; i++) {
          query.reply(key, '$i');
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        query.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.ring,
        capacity: 2,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 60),
      );
      addTearDown(replies.dispose);

      // Polled MUCH slower than the replier produces, so the ring must
      // overwrite between takes.
      final drain = await drainSlowly(
        replies,
        pace: const Duration(milliseconds: 200),
      );

      expect(
        drain.payloads,
        isNotEmpty,
        reason: 'the ring must deliver in flight, or this measures nothing',
      );
      expect(
        drain.payloads.length,
        lessThan(volume),
        reason:
            'a ring at capacity 2 cannot deliver all $volume replies to a '
            'consumer this slow',
      );
      // DROPPED, not merely truncated: the values are not the first N. A
      // channel that simply stopped accepting at capacity would hand over
      // 0,1 and nothing else; drop-oldest hands over later values instead.
      final asInts = drain.payloads.map(int.parse).toList();
      expect(
        asInts.last,
        greaterThan(asInts.length - 1),
        reason:
            'drop-oldest must surface values from beyond the first '
            '${asInts.length}; got $asInts',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'the fifo bound is the channel capacity, not the process memory',
      () async {
        // Many multiples of a small capacity, drained slowly to exhaustion. A
        // Dart-side unbounded buffer would satisfy the losslessness here
        // VACUOUSLY -- which is why the ring cell above is what makes this one
        // mean something -- but the run completing rather than growing without
        // limit is the other half of the property.
        const key = 'zenoh/dart/test/s8/fifo/bound';
        const volume = 50;
        replyBurst(key, volume);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 1,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 60),
        );
        addTearDown(replies.dispose);

        final drain = await drainSlowly(
          replies,
          pace: const Duration(milliseconds: 5),
        );

        expect(drain.payloads, hasLength(volume));
        expect(drain.payloads, equals([for (var i = 0; i < volume; i++) '$i']));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
  // -------------------------------------------------------------------------
  // Slice 11: the timeout family, through the channel.
  //
  // The oracle is the Stream path, whose behaviour is already pinned: timeout
  // expiry is NOT silent completion — canon delivers an error reply whose
  // payload is 'Timeout' and only then disconnects. The channel mode must show
  // the same thing, because a channel that swallowed the error reply would be
  // reporting a clean end to a query that failed.
  //
  // ⚠️ EVERY EXPIRY CELL USES A HELD-OPEN QUERYABLE. A get with no matching
  // queryable completes INSTANTLY — that is a different outcome (zero replies,
  // no error) and it is pinned separately below. Measuring expiry against it
  // would produce a green that proves the wrong thing, which is exactly how the
  // survey's own first timeout cell went wrong.
  group('Slice 11: the timeout family through the channel (TCP 19370)', () {
    late Session replierSession;
    late Session getterSession;

    setUpAll(() async {
      (replierSession, getterSession) = await sessionPair(19370);
    });

    tearDownAll(() {
      getterSession.close();
      replierSession.close();
    });

    /// Declares a queryable that receives the query and never replies, holding
    /// it open so the getter's clock is what ends the query.
    void holdOpen(String key) {
      final held = <Query>[];
      final queryable = replierSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen(held.add);
      addTearDown(() {
        for (final q in held) {
          q.dispose();
        }
      });
    }

    test('an in-flight channel reports empty, not terminal', () async {
      const key = 'zenoh/dart/test/s11/inflight';
      holdOpen(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final replies = getterSession.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 30),
      );
      addTearDown(replies.dispose);

      // Alive with an empty buffer -- the back-off arm, not the exit arm.
      expect(replies.tryRecv(), isA<RecvEmpty<Reply>>());
    });

    test(
      'timeout expiry delivers a Timeout error reply, then disconnects',
      () async {
        const key = 'zenoh/dart/test/s11/expiry';
        holdOpen(key);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final replies = getterSession.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 1),
        );
        addTearDown(replies.dispose);

        final drained = await drainToTerminal(
          replies.tryRecv,
          timeout: const Duration(seconds: 15),
        );
        expect(drained, hasLength(1));
        expect(drained.single.isOk, isFalse);
        expect(drained.single.error.payload, equals('Timeout'));
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('a get with no matching queryable terminates without error', () async {
      // The zero-replies-no-error outcome, surfacing at a channel: canon
      // completes the query at once rather than running out the clock, so this
      // is NOT the expiry cell above wearing a different topology.
      final replies = getterSession.pullGet(
        'zenoh/dart/test/s11/nobody',
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 30),
      );
      addTearDown(replies.dispose);

      final drained = await drainToTerminal(
        replies.tryRecv,
        timeout: const Duration(seconds: 10),
      );
      expect(drained, isEmpty);
      expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a sentinel timeout cannot reach the channel entry either', () {
      // Option parity is not only about which options exist: the CONTRACT on
      // each one has to hold identically on both modes of the same carrier.
      for (final bad in [Duration.zero, const Duration(microseconds: 500)]) {
        expect(
          () => getterSession.pullGet(
            'zenoh/dart/test/s11/zero',
            kind: ChannelKind.fifo,
            capacity: 4,
            timeout: bad,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              equals('timeout'),
            ),
          ),
          reason: '$bad',
        );
      }
    });
  });
}
