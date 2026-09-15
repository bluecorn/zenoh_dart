import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Seed D slice 14 (F13) — a payload large enough that canon's own configuration
// makes fragmentation unavoidable survives a real TCP hop byte-exact.
//
// ⚠️ WHAT THIS TEST DOES *NOT* CLAIM. It does not claim to observe fragmenting.
// No fragmentation observable reaches Dart at all: the shim flattens every
// received payload (`z_bytes_to_slice`, documented as defragmenting), no stats
// surface is bound, and the slice-iterator route is unstable-gated. A test
// asserting "we watched it fragment" could not be written, and one claiming to
// would be a false green.
//
// What it does claim, in three legs:
//
//   1. THE PRECONDITION IS READ, NOT ASSUMED. The batch size actually in force
//      is read back out of the session config with `Config.get` and asserted.
//      This is the only detector that exists and it is a real one — see the
//      `batchSizeInForce` helper for the two failure modes it catches.
//   2. THE PAYLOAD IS DERIVED FROM IT, not written as a literal. Sizes are
//      computed as multiples of the value read back, strictly greater than it,
//      so fragmentation is ENTAILED by canon's own configuration rather than
//      asserted by us.
//   3. THE BYTES SURVIVE, over a PINNED TCP hop. The transport is pinned
//      explicitly with scouting off, because nothing in legs 1 and 2 forces a
//      transport and a co-located or shared-memory path would satisfy both
//      while never fragmenting anything. The hop is what makes the other two
//      mean something.
//
// The threshold is NOT read out of the Rust config crate. The in-band route
// above needs no such read and is strictly better: it reports the value in
// force for the session under test, so it cannot go stale the way a copied
// constant can.

/// A payload that is adversarial for a byte channel, not just large.
///
/// Cycles all 256 byte values, so it contains embedded NULs and byte sequences
/// that are invalid UTF-8. A fragmenting test built on printable text would
/// miss a lossy re-encode at a fragment boundary, which is exactly the class
/// this project has shipped a defect in before.
Uint8List _adversarial(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) % 256));

/// Builds a config with the batch size pinned and scouting off.
Config _config({required int batchSize, String? listen, String? connect}) {
  final c = Config()
    ..insertJson5('transport/link/tx/batch_size', '$batchSize')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (listen != null) c.insertJson5('listen/endpoints', '["$listen"]');
  if (connect != null) c.insertJson5('connect/endpoints', '["$connect"]');
  return c;
}

/// Reads the batch size actually in force for a config pinned to [requested].
///
/// This is the detector, and it discriminates two distinct failure modes that
/// nothing else in the suite would catch:
///
///  * an UNKNOWN key throws loudly out of `Config.get` (rc-checked), so a
///    renamed or misspelled config path cannot pass silently;
///  * an OUT-OF-RANGE value is silently clamped — canon's batch size is a u16,
///    so requesting 65536 reads back 65535 with no error at all. A pin that did
///    not take effect is visible here and nowhere else.
int _batchSizeInForce(int requested) {
  final c = _config(batchSize: requested);
  try {
    return int.parse(c.get('transport/link/tx/batch_size'));
  } finally {
    c.dispose();
  }
}

void main() {
  group('the batch-size precondition is readable and real', () {
    test('an unknown config key throws rather than reading as absent', () {
      // CONTROL for the whole slice: if `Config.get` returned something
      // harmless for a bad key, every threshold read below would be
      // unfalsifiable.
      final c = Config();
      addTearDown(c.dispose);
      expect(
        () => c.get('transport/link/tx/batch_size_TYPO'),
        throwsA(isA<ZenohException>()),
      );
    });

    test('a pinned batch size reads back as pinned', () {
      expect(_batchSizeInForce(4096), 4096);
      expect(_batchSizeInForce(8192), 8192);
    });

    test('an out-of-range batch size is silently clamped to the u16 max', () {
      // The second failure mode, and the reason leg 1 exists: this does NOT
      // throw. 65536 is accepted and reads back 65535, so a test that trusted
      // its own requested number would believe in a threshold that never
      // took effect.
      expect(_batchSizeInForce(65536), 65535);
    });

    test('canon default batch size is the u16 max', () {
      final c = Config()..insertJson5('scouting/multicast/enabled', 'false');
      addTearDown(c.dispose);
      // 65535 — read out of the running config rather than copied from a
      // constant, so it tracks the pinned zenoh-c version by construction.
      expect(int.parse(c.get('transport/link/tx/batch_size')), 65535);
    });
  });

  group('fragmenting payloads survive a pinned TCP hop (18915)', () {
    // Pinned WELL BELOW canon's 65535 default so the payloads stay small
    // enough to keep the suite fast while still being multiples of the batch.
    const batchSize = 4096;
    late Session sender;
    late Session receiver;

    setUpAll(() async {
      expect(
        _batchSizeInForce(batchSize),
        batchSize,
        reason:
            'LEG 1: the threshold this group believes in must be the '
            'threshold in force, or every size below is arbitrary',
      );

      sender = await Session.open(
        config: _config(
          batchSize: batchSize,
          listen: 'tcp/127.0.0.1:18915',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      receiver = await Session.open(
        config: _config(
          batchSize: batchSize,
          connect: 'tcp/127.0.0.1:18915',
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      sender.close();
      receiver.close();
    });

    test('a payload larger than the batch arrives byte-exact', () async {
      // LEG 2: strictly greater than the batch, and comfortably so — a payload
      // of exactly `batchSize` may or may not fit one batch once framing
      // overhead is counted, so no assertion is made at the boundary.
      const ke = 'zenoh/dart/test/d/frag/put';
      final payload = _adversarial(batchSize * 3);
      expect(payload.length, greaterThan(batchSize));

      final sub = receiver.declareSubscriber(ke);
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final first = sub.stream.first.timeout(const Duration(seconds: 10));
      sender.putBytes(ke, ZBytes.fromUint8List(payload));

      final s = await first;
      expect(s.payloadBytes, equals(payload));
    });

    test('the threshold tracks the config, not a hardcoded constant', () async {
      // Parameterised on the batch size read back in leg 1: the same test at
      // two multiples. If the size were a magic number, changing `batchSize`
      // would silently stop exercising fragmentation.
      const ke = 'zenoh/dart/test/d/frag/multiples';
      final sub = receiver.declareSubscriber(ke);
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      final got = <Uint8List>[];
      final done = sub.stream.take(2).forEach((s) => got.add(s.payloadBytes));

      for (final multiple in [2, 5]) {
        final payload = _adversarial(batchSize * multiple);
        sender.putBytes(ke, ZBytes.fromUint8List(payload));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await done.timeout(const Duration(seconds: 10));

      expect(got, hasLength(2));
      expect(got[0], equals(_adversarial(batchSize * 2)));
      expect(got[1], equals(_adversarial(batchSize * 5)));
    });

    test(
      'a fragmenting attachment survives beside a fragmenting payload',
      () async {
        // The fidelity doctrine's unit is the round-trip PAIR, and two large
        // opaque values on one message is the adversarial case for it.
        const ke = 'zenoh/dart/test/d/frag/attachment';
        final payload = _adversarial(batchSize * 2);
        final attachment = _adversarial(batchSize * 2 + 17);

        final sub = receiver.declareSubscriber(ke);
        addTearDown(sub.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        final first = sub.stream.first.timeout(const Duration(seconds: 10));
        sender.putBytes(
          ke,
          ZBytes.fromUint8List(payload),
          attachment: ZBytes.fromUint8List(attachment),
        );

        final s = await first;
        expect(s.payloadBytes, equals(payload));
        expect(s.attachmentBytes, equals(attachment));
      },
    );

    test('fragmenting query and reply payloads both survive', () async {
      // Both directions of the REQUEST path, not just the push path.
      const ke = 'zenoh/dart/test/d/frag/query';
      final queryPayload = _adversarial(batchSize * 2);
      final replyPayload = _adversarial(batchSize * 3 + 5);

      Uint8List? seenAtQueryable;
      final q = receiver.declareQueryable(ke);
      addTearDown(q.close);
      q.stream.listen((query) {
        seenAtQueryable = query.payloadBytes;
        query
          ..replyBytes(ke, ZBytes.fromUint8List(replyPayload))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(seconds: 1));

      final replies = await sender
          .get(
            ke,
            payload: ZBytes.fromUint8List(queryPayload),
            timeout: const Duration(seconds: 10),
          )
          .toList();

      final ok = replies.where((r) => r.isOk).toList();
      expect(ok, isNotEmpty, reason: 'no reply arrived (upstream core #2516)');
      expect(
        seenAtQueryable,
        equals(queryPayload),
        reason: 'the query payload must survive the hop byte-exact',
      );
      expect(
        ok.first.ok.payloadBytes,
        equals(replyPayload),
        reason: 'and so must the reply payload, on the way back',
      );
    });
  });
}
