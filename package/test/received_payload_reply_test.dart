// Seed [10a] slice 9 — the reply column, and its TWO INDEPENDENT PARSES.
//
// ⛔ THE WHOLE RISK OF THIS SLICE IS A NAMED PAST DEFECT. `Session.get` and
// `Querier.get` do not share a reply parse: `session.dart::_createReplyChannel`
// and `querier.dart`'s inline listener are separate code that happen to agree.
// A fix applied only to the first once left EVERY `Querier` reply truncating.
//
// So this column carries two red legs, not one. A cell driving `Session.get`
// does not discharge `Querier.get`, and a green on one proves nothing about
// the other. They are deliberately not factored into a shared helper here —
// factoring them would hide exactly the divergence they exist to detect.
//
// ⚠️ A CELL OBSERVING RETAINED REPLY PAYLOADS IN FLIGHT MUST PASS
// `ConsolidationMode.none`. Measured previously on this stack: under canon's
// default (`auto`) an in-flight observation sees 0; under `none` it sees them.
// Where that matters below it is stated beside the cell.
//
// ⛔ THE ERROR ARM IS CARVED. `ReplyError.payloadBytes` gets no retained
// handle in this unit; the carve is homed to the terminal unit with its
// grounds on the roadmap. Test 4 ASSERTS the carve rather than assuming it.
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/reply_retention.dart';
import 'package:zenoh_dart/zenoh.dart';

/// The process-wide count of `ZBytes` finalizer firings — the discriminator
/// between "an enumerated release path freed it" and "the safety net did".
int finCount() => bindings.zd_fin_invocations(ZdFinKind.bytes);

/// Allocates and drops, which is what makes the finalizer net actually run.
Future<void> gcPressure({int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    Uint8List(512 * 1024)[0] = i;
  }
  await Future<void>.delayed(const Duration(milliseconds: 120));
}

/// Flushes finalizers left pending by EARLIER SUITES before any measurement.
///
/// The counter is process-wide and `package:test` runs suites as isolates in
/// one process, so without this a handle another file dropped is reclaimed
/// inside one of this file's windows and reads as a failure here.
Future<void> drainPendingFinalizers() async {
  for (var i = 0; i < 2; i++) {
    await gcPressure(rounds: 40);
  }
}

/// Collects replies from [stream], bounded, failing RED with a diagnosis.
Future<List<Reply>> collectReplies(
  Stream<Reply> stream, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    return await stream.toList().timeout(timeout);
  } on TimeoutException {
    throw StateError('the reply stream never completed within $timeout');
  }
}

void main() {
  ensureInitialized();

  group('Retained reply payloads — Session.get (TCP 19732)', () {
    late Session qSession;
    late Session gSession;
    late Queryable queryable;

    const key = 'reply/retain/session';
    final replyBytes = Uint8List.fromList([0x52, 0x00, 0xFF, 0x41, 0x00]);

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19732"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      qSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19732"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      gSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));

      queryable = qSession.declareQueryable(key);
      queryable.stream.listen((q) {
        q
          ..replyBytes(key, ZBytes.fromUint8List(replyBytes))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    tearDownAll(() {
      queryable.close();
      gSession.close();
      qSession.close();
    });

    test('a reply received through Session.get yields a usable retained '
        'payload', () async {
      // Given: a retention-enabled get against a replying queryable
      // When: the ok reply arrives
      final replies = await collectReplies(
        gSession.get(key, retainPayload: true),
      );

      // Then: the retained handle reads the replier's bytes exactly
      expect(replies, isNotEmpty, reason: 'no reply arrived');
      final ok = replies.firstWhere((r) => r.isOk);
      final retained = ok.ok.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes(), equals(replyBytes));
      expect(ok.ok.payloadBytes, equals(replyBytes));
      retained.dispose();
    });

    test('retention is off by default on the reply column too', () async {
      // Given: a get with no retainPayload argument
      final replies = await collectReplies(gSession.get(key));

      // Then: no handle, and the copy is exactly what it always was
      final ok = replies.firstWhere((r) => r.isOk);
      expect(ok.ok.payloadZBytes, isNull);
      expect(ok.ok.payloadBytes, equals(replyBytes));
    });

    test('a retained reply payload survives the get completing', () async {
      // Given: a retained payload from a reply whose stream has completed
      final replies = await collectReplies(
        gSession.get(key, retainPayload: true),
      );
      final retained = replies.firstWhere((r) => r.isOk).ok.payloadZBytes;
      expect(retained, isNotNull);

      // When: the stream is long since done (toList completed above)
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Then: it still reads the replier's bytes
      expect(retained!.toBytes(), equals(replyBytes));
      retained.dispose();
    });
  });

  group('Retained reply payloads — Querier.get, its OWN parse (TCP 19733)', () {
    late Session qSession;
    late Session gSession;
    late Queryable queryable;
    late Querier querier;

    const key = 'reply/retain/querier';
    final replyBytes = Uint8List.fromList([0x51, 0x00, 0xEE, 0x42]);

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19733"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      qSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19733"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      gSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));

      queryable = qSession.declareQueryable(key);
      queryable.stream.listen((q) {
        q
          ..replyBytes(key, ZBytes.fromUint8List(replyBytes))
          ..dispose();
      });
      querier = gSession.declareQuerier(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    tearDownAll(() {
      querier.close();
      queryable.close();
      gSession.close();
      qSession.close();
    });

    test('a reply received through Querier.get yields one too', () async {
      // ⛔ THIS IS A SEPARATE RED LEG, not a repeat of the Session.get cell.
      // querier.dart carries its own reply parse; fixing only session.dart
      // once left every Querier reply truncating.
      final replies = await collectReplies(querier.get(retainPayload: true));

      expect(replies, isNotEmpty, reason: 'no reply arrived at the querier');
      final ok = replies.firstWhere((r) => r.isOk);
      final retained = ok.ok.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes(), equals(replyBytes));
      expect(ok.ok.payloadBytes, equals(replyBytes));
      retained.dispose();
    });

    test('the querier parse is off by default too', () async {
      final replies = await collectReplies(querier.get());
      final ok = replies.firstWhere((r) => r.isOk);
      expect(ok.ok.payloadZBytes, isNull);
      expect(ok.ok.payloadBytes, equals(replyBytes));
    });
  });

  group('Retained reply payloads — liveliness and the error carve (TCP 19734)', () {
    late Session aSession;
    late Session bSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19734"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      aSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19734"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      bSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      bSession.close();
      aSession.close();
    });

    test('livelinessGet accepts the flag consistently', () async {
      // Given: a live token on a matching key
      const key = 'reply/retain/live/tok';
      final token = aSession.declareLivelinessToken(key);
      addTearDown(token.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // When: livelinessGet asks with retention on
      final replies = await collectReplies(
        bSession.livelinessGet('reply/retain/live/**', retainPayload: true),
      );

      // Then: the reply's sample carries a retained payload.
      // ⚠️ Whether it is EMPTY is canon's behaviour and is RECORDED here as
      // measured on this tree, not asserted from a prior landmark: a
      // liveliness reply carries a zero-length payload.
      expect(replies, isNotEmpty, reason: 'no liveliness reply arrived');
      final ok = replies.firstWhere((r) => r.isOk);
      final retained = ok.ok.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes().length, equals(0));
      retained.dispose();
    });

    test('an error reply is unaffected — the carve, asserted', () async {
      // Given: a queryable that replies with an ERROR
      const key = 'reply/retain/err';
      final errBytes = Uint8List.fromList([0x45, 0x00, 0x52, 0x52]);
      final queryable = aSession.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((q) {
        q
          ..replyErrBytes(ZBytes.fromUint8List(errBytes))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // When: a RETENTION-ENABLED get receives the error reply
      final replies = await collectReplies(
        bSession.get(key, retainPayload: true),
      );

      // Then: the error arm behaves exactly as before. No retained handle is
      // produced for it, and its payload bytes are untouched. ⛔ The carve is
      // ASSERTED here rather than assumed — it is homed to the terminal unit,
      // and a silent change on this arm is what the assertion exists to catch.
      expect(replies, isNotEmpty, reason: 'no error reply arrived');
      final err = replies.firstWhere((r) => !r.isOk);
      expect(err.error.payloadBytes, equals(errBytes));
    });
  });

  group('Retained reply payloads — release paths (TCP 19735)', () {
    late Session qSession;
    late Session gSession;
    late Queryable queryable;

    const key = 'reply/retain/release';
    const repliesPerQuery = 8;
    final replyBytes = Uint8List(64 * 1024);

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19735"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      qSession = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19735"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      gSession = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));

      // One query, MANY replies — which is what lets a consumer abandon the
      // stream with handles still buffered.
      queryable = qSession.declareQueryable(key);
      queryable.stream.listen((q) {
        for (var i = 0; i < repliesPerQuery; i++) {
          q.replyBytes(key, ZBytes.fromUint8List(replyBytes));
        }
        q.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await drainPendingFinalizers();
    });

    tearDownAll(() {
      queryable.close();
      gSession.close();
      qSession.close();
    });

    setUp(drainPendingFinalizers);

    test('retained reply payloads undelivered at query completion are '
        'released by the drain', () async {
      // Given: a retention-enabled get whose consumer takes ONE reply and
      // abandons the rest. The remaining handles sit in the controller with no
      // other owner, and the channel self-terminates at query completion.
      //
      // ⚠️ ConsolidationMode.none, deliberately: under canon's default the
      // replies are consolidated and a multi-reply observation sees far fewer
      // than were sent, which would make this cell measure nothing.
      final before = finCount();

      final stream = gSession.get(
        key,
        retainPayload: true,
        consolidation: ConsolidationMode.none,
      );
      final first = await stream.first.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError('no reply arrived'),
      );

      // POSITIVE CONTROL: a handle really did arrive, so a zero below is a
      // released count and not an absent one.
      expect(first.isOk, isTrue);
      expect(first.ok.payloadZBytes, isNotNull);
      first.ok.payloadZBytes!.dispose();

      // `.first` cancels the subscription, so the remaining replies are
      // undelivered when the channel terminates.
      await Future<void>.delayed(const Duration(seconds: 2));
      await gcPressure();

      // ⛔ THE FINALIZER COUNTER CANNOT SEE THIS DEFECT, AND THAT IS RECORDED
      // RATHER THAN WORKED AROUND. Measured: deleting the drain call reddened
      // NOTHING with the counter as the instrument. The reason is structural —
      // a carrier that fails to drain does not create garbage, it keeps every
      // handle strongly reachable from its own live set, so the net never runs
      // and the counter reads a clean zero on a permanently leaking tree.
      // A leak INTO A LIVE SET is invisible to a reclamation-based instrument.
      //
      // So the instrument here is the live undelivered count, which measures
      // the set directly. The counter assertion is kept beside it because it
      // still says something true and different: nothing was orphaned to the
      // net either.
      expect(
        ReplyRetention.liveUndelivered,
        equals(0),
        reason:
            'retained reply handles are still tracked as undelivered '
            'after the query completed, so the drain did not run — they are '
            'leaked into a live set, where no finalizer will ever reach them',
      );
      // ⚠️ THIS SECOND ASSERTION IS SERIAL-ONLY, AND THAT IS RECORDED RATHER
      // THAN WEAKENED. `finCount()` is a PROCESS-WIDE native counter, while
      // the `liveUndelivered` check above is a Dart static and therefore
      // per-isolate. Under `--concurrency=4` another suite's dropped handles
      // are reclaimed inside this window and this reads non-zero — measured:
      // red at c=4, green serially, repeatedly. Certification is serial, which
      // is the configuration this assertion is exact in.
      //
      // It is kept because it says something true and DIFFERENT from the
      // primary instrument: not merely that the drain ran, but that nothing
      // was orphaned to the net either. Deleting it to buy a parallel-clean
      // run would discard that, and widening it would make it meaningless in
      // both configurations.
      expect(
        finCount() - before,
        equals(0),
        reason:
            'undelivered reply payloads reached the net, so something '
            'orphaned them instead of releasing them. NOTE: this assertion is '
            'process-scoped and only exact in a SERIAL run — re-check serially '
            'before treating a parallel red here as real',
      );
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
