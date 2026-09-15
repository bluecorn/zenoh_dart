// Seed [10a] slice 2 — the retention seam, on one push sample surface.
//
// This file establishes the mechanism every later column inherits: the shim
// clones the loaned payload into a STACK `z_owned_bytes_t`, posts its `sizeof`
// byte image as typed data (Dart_PostCObject_DL copies before it returns),
// nulls the local so the trailing cleanup cannot drop it, and the Dart parse
// bitwise-moves that image into its own `calloc` slot. Zero new shim
// allocations on the receive path.
//
// The seam's own failure mode -- a posted image that is not `zd_bytes_sizeof()`
// bytes long -- is driven directly against the internal factory rather than
// through the network, because no publisher can produce a truncated handle
// image. Driving it through a subscriber would be a cell that cannot fail.
//
// No control byte is spelled as a literal anywhere in this file: the interior
// NUL is built with `String.fromCharCode(0)` / an explicit 0x00 element, so the
// file stays text to every review instrument on this line.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
// The unstable door, not the stable one: three of the six carriers
// exercised below are the advanced surfaces. It re-exports `zenoh.dart`
// in full, so nothing already in this file changes meaning.
import 'package:zenoh_dart/zenoh_unstable.dart';

/// Waits for [n] samples on [stream], failing RED at the deadline rather than
/// hanging the serial suite. Every convergence wait here is bounded.
Future<List<Sample>> takeSamples(
  Stream<Sample> stream,
  int n, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final got = <Sample>[];
  final done = Completer<void>();
  final sub = stream.listen((s) {
    got.add(s);
    if (got.length >= n && !done.isCompleted) done.complete();
  });
  try {
    await done.future.timeout(
      timeout,
      onTimeout: () => throw StateError(
        'expected $n samples, saw ${got.length} within $timeout',
      ),
    );
  } finally {
    await sub.cancel();
  }
  return got;
}

/// Publishes [payload] to [key] until [probe] reports the sample landed.
///
/// The subscriber declaration has to reach the peer before the put, and how
/// long that takes is the network's business. Bounded, and it fails with a
/// diagnosis rather than hanging.
Future<void> publishUntilSeen(
  Session publisher,
  String key,
  Uint8List payload,
  Future<bool> Function() probe, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    // putBytes CONSUMES its ZBytes, so each attempt builds its own.
    publisher.putBytes(key, ZBytes.fromUint8List(payload));
    if (await probe()) return;
  }
  throw StateError('publication to $key never arrived within $timeout');
}

/// Polls until [samples] is non-empty, failing RED at the deadline.
///
/// Used where the arrival cannot be RE-DRIVEN the way a publication can: a
/// liveliness token is declared once and declaring it again announces a
/// SECOND token rather than retrying the first, and a publisher-detection
/// event fires once per publisher. So this waits, bounded, and fails with a
/// diagnosis rather than hanging the serial suite.
Future<void> awaitSample(
  List<Sample> samples,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (samples.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (samples.isEmpty) fail('no $what within $timeout');
}

/// Registers a tear-down releasing EVERY retained handle [samples] collects.
///
/// Not only the one a cell asserts on: a carrier may deliver more than one
/// sample and each carries its own owned clone. Registered BEFORE the
/// subscription's own cancel tear-down, so the unwind order is
/// cancel -> dispose: cancelling first stops new handles arriving while the
/// disposal runs.
void releaseAll(List<Sample> samples) {
  addTearDown(() {
    for (final s in samples) {
      s.payloadZBytes?.dispose();
    }
  });
}

void main() {
  group('Received payload retention — sample push surface (TCP 19720)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19720"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19720"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test(
      'a subscriber declared with retention hands back a usable ZBytes',
      () async {
        // Given: a retention-enabled subscriber and a publisher on its key
        const key = 'test/retain/basic';
        final payload = Uint8List.fromList([0x68, 0x69, 0x00, 0xFF]);
        final subscriber = subSession.declareSubscriber(
          key,
          retainPayload: true,
        );
        addTearDown(subscriber.close);

        final samples = <Sample>[];
        final sub = subscriber.stream.listen(samples.add);
        addTearDown(sub.cancel);

        // When: a sample arrives and payloadZBytes is read
        await publishUntilSeen(
          pubSession,
          key,
          payload,
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return samples.isNotEmpty;
          },
        );

        // Then: it is non-null and its bytes equal what was published, exactly
        final retained = samples.first.payloadZBytes;
        expect(retained, isNotNull);
        expect(retained!.toBytes(), equals(payload));
        retained.dispose();
      },
    );

    test('the retained handle outlives the callback, the subscriber and the '
        'session', () async {
      // Given: a retained ZBytes taken from a delivered sample, on its OWN
      // session so closing it cannot disturb the other cells.
      const key = 'test/retain/outlives';
      final payload = Uint8List.fromList([0xDE, 0xAD, 0x00, 0xBE, 0xEF]);

      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19721"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      final ownSub = await Session.open(config: listenConfig);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19721"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      final ownPub = await Session.open(config: connectConfig);
      await Future<void>.delayed(const Duration(seconds: 1));

      final subscriber = ownSub.declareSubscriber(key, retainPayload: true);
      final samples = <Sample>[];
      final sub = subscriber.stream.listen(samples.add);

      await publishUntilSeen(
        ownPub,
        key,
        payload,
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return samples.isNotEmpty;
        },
      );

      final retained = samples.first.payloadZBytes;
      expect(retained, isNotNull);

      // When: the subscriber AND the subscribing session are closed before the
      // handle is read. GT-A is canon-direct and proves nothing about our
      // seam; this is its shipped-stack counterpart.
      await sub.cancel();
      subscriber.close();
      ownSub.close();
      ownPub.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Then: it still returns the published bytes
      expect(retained!.toBytes(), equals(payload));
      retained.dispose();
    });

    test('three distinct payloads yield three independent handles', () async {
      // Given: three DISTINCT payloads. Distinctness makes the check
      // non-vacuous twice over -- it proves the handles are not aliased onto
      // one buffer, and it makes a stale read detectable.
      const key = 'test/retain/distinct';
      final payloads = [
        Uint8List.fromList([0x01, 0x00, 0x11]),
        Uint8List.fromList([0x02, 0x00, 0x22]),
        Uint8List.fromList([0x03, 0x00, 0x33]),
      ];
      final subscriber = subSession.declareSubscriber(
        key,
        retainPayload: true,
      );
      addTearDown(subscriber.close);

      final seen = <Sample>[];
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);

      // Land the first one, so the declaration is known to have propagated,
      // then send the remaining two.
      await publishUntilSeen(
        pubSession,
        key,
        payloads[0],
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return seen.isNotEmpty;
        },
      );
      seen.clear();
      for (final p in payloads) {
        pubSession.putBytes(key, ZBytes.fromUint8List(p));
      }

      // When: all three retained handles are read after the last one arrives
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (seen.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        seen.length,
        greaterThanOrEqualTo(3),
        reason: 'saw ${seen.length} of 3 samples',
      );

      // Then: each returns its OWN bytes
      final handles = seen.take(3).map((s) => s.payloadZBytes).toList();
      expect(handles.every((h) => h != null), isTrue);
      final read = handles.map((h) => h!.toBytes()).toList();
      for (var i = 0; i < 3; i++) {
        expect(
          read[i],
          equals(payloads[i]),
          reason: 'handle $i read the wrong payload -- aliased or stale',
        );
      }
      for (final h in handles) {
        h!.dispose();
      }
    });

    test('the posted image is length-checked at the seam', () {
      // Given: a payload-handle image that is NOT zd_bytes_sizeof() bytes.
      // Driven against the factory directly: no publisher can produce a
      // truncated image, so routing this through the network would be a cell
      // that cannot fail.
      final short = Uint8List(7);

      // When/Then: it throws loudly naming the mismatch, rather than
      // constructing a ZBytes over a truncated handle.
      expect(
        () => ZBytes.fromPostedImage(short),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('7'), contains('retained payload')),
          ),
        ),
      );

      // And: a null image is the absent case, not an error.
      expect(ZBytes.fromPostedImage(null), isNull);
    });

    test(
      'a delete sample carries an empty retained payload, not a null one',
      () async {
        // Given: a retention-enabled subscriber and a delete on its key
        const key = 'test/retain/delete';
        final subscriber = subSession.declareSubscriber(
          key,
          retainPayload: true,
        );
        addTearDown(subscriber.close);

        final seen = <Sample>[];
        final sub = subscriber.stream.listen(seen.add);
        addTearDown(sub.cancel);

        // Land a PUT first so the declaration is known propagated, then delete.
        await publishUntilSeen(
          pubSession,
          key,
          Uint8List.fromList([0x41]),
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return seen.isNotEmpty;
          },
        );
        seen.clear();

        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
          pubSession.deleteResource(key);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(seen, isNotEmpty, reason: 'no DELETE sample arrived');

        // When: the DELETE sample arrives
        final deleteSample = seen.firstWhere(
          (s) => s.kind == SampleKind.delete,
          orElse: () => throw StateError('no DELETE among ${seen.length}'),
        );

        // Then: present-but-empty, matching the discipline payloadBytes keeps
        expect(deleteSample.payloadZBytes, isNotNull);
        expect(deleteSample.payloadZBytes!.toBytes().length, equals(0));
        deleteSample.payloadZBytes!.dispose();
      },
    );

    test('a zero-length PUT payload retains', () async {
      // Given: a retention-enabled subscriber and a PUT of zero bytes
      const key = 'test/retain/empty';
      final subscriber = subSession.declareSubscriber(
        key,
        retainPayload: true,
      );
      addTearDown(subscriber.close);

      final seen = <Sample>[];
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);

      // When: the sample arrives
      await publishUntilSeen(
        pubSession,
        key,
        Uint8List(0),
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return seen.isNotEmpty;
        },
      );

      // Then: non-null with a zero-length read -- distinct from the absent
      // case, which is what a retention-OFF carrier delivers.
      final retained = seen.first.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes().length, equals(0));
      expect(seen.first.kind, equals(SampleKind.put));
      retained.dispose();
    });
  });

  group('Received payload retention — the copy is unchanged (TCP 19722)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19722"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19722"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test(
      'retention is OFF by default and payloadBytes is what it always was',
      () async {
        // Given: a subscriber declared with NO retainPayload argument at all.
        // The default is the whole claim, so the flag is not written here --
        // passing `retainPayload: false` explicitly would test the parameter,
        // not the default.
        const key = 'test/retain/default-off';
        // Invalid UTF-8 (0xC3 0x28, a truncated two-byte sequence) plus an
        // interior NUL: data no lenient string view could reconstruct, so
        // payloadBytes is being checked on ground truth rather than on bytes
        // that happen to survive a string round trip.
        final payload = Uint8List.fromList([0x7A, 0x00, 0xC3, 0x28, 0x41]);
        final subscriber = subSession.declareSubscriber(key);
        addTearDown(subscriber.close);

        final seen = <Sample>[];
        final sub = subscriber.stream.listen(seen.add);
        addTearDown(sub.cancel);

        // When: a sample arrives
        await publishUntilSeen(
          pubSession,
          key,
          payload,
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return seen.isNotEmpty;
          },
        );

        // Then: no handle was minted, and the copy is byte-exact
        expect(seen.first.payloadZBytes, isNull);
        expect(seen.first.payloadBytes, equals(payload));
        // ...on EVERY delivery of the run, not just the first: the default
        // cannot be "off for the first sample and on afterwards".
        for (final s in seen) {
          expect(s.payloadZBytes, isNull);
          expect(s.payloadBytes, equals(payload));
        }
      },
    );

    test('both arms deliver identical payloadBytes in ONE run', () async {
      // Given: TWO subscribers on the same key, in one process and one run --
      // one retaining, one not. Two separate runs would not discharge this:
      // the claim is that a retaining declaration leaves a non-retaining
      // one's copy untouched while both are live, and a per-arm run cannot
      // observe the two together.
      const key = 'test/retain/both-arms';
      final payload = Uint8List.fromList([0x00, 0xFF, 0x41, 0x00, 0x80]);

      final plain = subSession.declareSubscriber(key);
      addTearDown(plain.close);
      final retaining = subSession.declareSubscriber(key, retainPayload: true);
      addTearDown(retaining.close);

      final plainSeen = <Sample>[];
      final retainSeen = <Sample>[];
      final subPlain = plain.stream.listen(plainSeen.add);
      addTearDown(subPlain.cancel);
      final subRetain = retaining.stream.listen(retainSeen.add);
      addTearDown(subRetain.cancel);
      // The publish loop may land more than one sample on the retaining arm;
      // every handle it delivered is released, not just the one asserted on.
      addTearDown(() {
        for (final s in retainSeen) {
          s.payloadZBytes?.dispose();
        }
      });

      // When: the same publication reaches both
      await publishUntilSeen(
        pubSession,
        key,
        payload,
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return plainSeen.isNotEmpty && retainSeen.isNotEmpty;
        },
      );

      // Then: the copies are byte-identical to each other and to the wire
      expect(plainSeen.first.payloadBytes, equals(payload));
      expect(retainSeen.first.payloadBytes, equals(payload));
      expect(
        retainSeen.first.payloadBytes,
        equals(plainSeen.first.payloadBytes),
      );
      // And the arms differ in exactly one thing: the handle
      expect(plainSeen.first.payloadZBytes, isNull);
      expect(retainSeen.first.payloadZBytes, isNotNull);
    });

    test('the retained handle and the copy agree byte-for-byte', () async {
      // Given: a payload carrying BOTH invalid UTF-8 (0xFF, 0xFE, 0x80 are
      // never valid) and an interior NUL -- the two shapes a string-shaped
      // seam mangles, one by U+FFFD replacement and one by strlen truncation.
      // If either the handle or the copy went through a string, they diverge
      // here; on clean bytes they would agree vacuously.
      const key = 'test/retain/agree';
      final payload = Uint8List.fromList(
        [0xFF, 0xFE, 0x00, 0x41, 0x80, 0x00, 0x42],
      );
      final subscriber = subSession.declareSubscriber(
        key,
        retainPayload: true,
      );
      addTearDown(subscriber.close);

      final seen = <Sample>[];
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);
      addTearDown(() {
        for (final s in seen) {
          s.payloadZBytes?.dispose();
        }
      });

      // When: the sample arrives
      await publishUntilSeen(
        pubSession,
        key,
        payload,
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return seen.isNotEmpty;
        },
      );

      // Then: handle and copy agree with each other AND with the wire. All
      // three legs are stated: two that agree with each other but not with
      // what was published would be a shared defect, not a pass.
      final sample = seen.first;
      final retained = sample.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes(), equals(sample.payloadBytes));
      expect(retained.toBytes(), equals(payload));
      expect(sample.payloadBytes, equals(payload));
      // Length stated separately: a truncation at the first NUL would give 2
      // bytes, and `equals` on the list already covers it -- this names the
      // number so a failure reads as a truncation rather than as a mismatch.
      expect(retained.toBytes().length, equals(7));
      retained.dispose();
    });

    test(
      'asking for the handle without opting in reports the requirement',
      () async {
        // Given: a sample from a retention-OFF subscriber
        const key = 'test/retain/requirement';
        final payload = Uint8List.fromList([0x51, 0x00, 0x52]);
        final subscriber = subSession.declareSubscriber(key);
        addTearDown(subscriber.close);

        final seen = <Sample>[];
        final sub = subscriber.stream.listen(seen.add);
        addTearDown(sub.cancel);

        // When: a consumer reads payloadZBytes
        await publishUntilSeen(
          pubSession,
          key,
          payload,
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return seen.isNotEmpty;
          },
        );

        // Then: it is null -- absent, not present-and-empty
        expect(seen.first.payloadZBytes, isNull);

        // And: the surface itself says what to change. A null with no
        // documented route is a dead end, so the member's OWN dartdoc has to
        // name the opt-in. Read from source and walked backwards from the
        // declaration, so a mention anywhere else in the file cannot satisfy
        // it.
        final source = File('lib/src/sample.dart').readAsStringSync();
        final doc = docCommentFor(source, 'final ZBytes? payloadZBytes;');
        expect(doc, contains('retainPayload'));
      },
    );

    test(
      'widening the message to ten elements shifts no existing field',
      () async {
        // Given: a retention-OFF subscriber, and a publication that drives
        // EVERY pre-existing field OFF ITS DEFAULT at once. The risk is an
        // off-by-one: element 9 was appended to the posted array, and a parse
        // that mis-indexed or tripped a defensive length guard would corrupt or
        // drop one of the nine below it. Driving each field off-default is what
        // makes a shifted read detectable -- a field that defaulted and a field
        // that was dropped are indistinguishable otherwise.
        const key = 'test/retain/shape';
        final payload = Uint8List.fromList(utf8.encode('{"a":1}'));
        final attachment = Uint8List.fromList(utf8.encode('att-42'));
        final expectedEncoding = Uint8List.fromList(
          utf8.encode('application/json'),
        );
        // Borrowed by putBytes, not consumed, so the SAME timestamp is attached
        // on every attempt and the assertion below can be bit-exact.
        final stamp = pubSession.newTimestamp();

        final subscriber = subSession.declareSubscriber(key);
        addTearDown(subscriber.close);

        final seen = <Sample>[];
        final sub = subscriber.stream.listen(seen.add);
        addTearDown(sub.cancel);

        // When: it is published. publishUntilSeen carries no option surface, so
        // the loop is written out here -- same bounded shape, same diagnosis on
        // the deadline.
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
          // putBytes CONSUMES both the payload and the attachment, so each
          // attempt builds its own pair.
          pubSession.putBytes(
            key,
            ZBytes.fromUint8List(payload),
            encoding: Encoding.applicationJson,
            attachment: ZBytes.fromUint8List(attachment),
            timestamp: stamp,
            congestionControl: CongestionControl.block,
            priority: Priority.realTime,
            isExpress: true,
          );
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(seen, isNotEmpty, reason: 'no sample arrived within 20s');

        // Then: every one of the twelve pre-existing members still lands, and
        // each of them lands on the non-default value that was sent.
        final sample = seen.first;
        expect(sample.keyExpr, equals(key));
        expect(sample.payload, equals('{"a":1}'));
        expect(sample.payloadBytes, equals(payload));
        expect(sample.kind, equals(SampleKind.put));
        expect(sample.attachment, equals('att-42'));
        expect(sample.attachmentBytes, equals(attachment));
        expect(sample.encoding, equals('application/json'));
        expect(sample.encodingBytes, equals(expectedEncoding));
        expect(sample.timestamp, isNotNull);
        expect(sample.timestamp, equals(stamp));
        expect(sample.priority, equals(Priority.realTime));
        expect(sample.congestionControl, equals(CongestionControl.block));
        expect(sample.express, isTrue);
        // And the newly appended element 9 parses to the absent case, because
        // this declaration did not opt in: the tenth slot is on the wire either
        // way, and off means null rather than a missing element.
        expect(sample.payloadZBytes, isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 4 — the fidelity round trip, over the CONTRACT's data domain.
  //
  // The domain asserted below is
  //     {valid UTF-8 x invalid UTF-8 / raw binary x interior NUL x empty},
  // plus a payload larger than one transport frame. It is the CONTRACT's
  // domain, not the domain today's consumer happens to send: the defect class
  // this guards against put a UTF-8-VALIDATING extractor on an opaque-bytes
  // path, passed every structural check, and silently corrupted every
  // non-UTF-8 payload while internal consistency stayed green throughout.
  //
  // The unit is the round-trip PAIR -- "out" cannot be validated without
  // driving "in" -- so every cell here publishes its own vector and reads the
  // handle back, rather than inspecting a value the suite manufactured.
  // -------------------------------------------------------------------------
  group('Received payload retention — byte fidelity (TCP 19723)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19723"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19723"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Declares a retaining subscriber on [key] and returns the (initially
    /// empty) list its samples land in.
    ///
    /// Every handle delivered is released, not only the one a cell asserts
    /// on -- a publish loop may land more than one sample and each carries
    /// its own owned clone.
    ///
    /// Tear-downs are registered so they unwind cancel -> dispose -> close:
    /// cancelling first stops new handles arriving while the disposal runs.
    List<Sample> retainingCollector(String key) {
      final subscriber = subSession.declareSubscriber(
        key,
        retainPayload: true,
      );
      addTearDown(subscriber.close);

      final seen = <Sample>[];
      addTearDown(() {
        for (final s in seen) {
          s.payloadZBytes?.dispose();
        }
      });
      final sub = subscriber.stream.listen(seen.add);
      addTearDown(sub.cancel);
      return seen;
    }

    /// Collects on [key], publishes [payload] until a sample lands, and
    /// returns everything seen.
    Future<List<Sample>> retainRoundTrip(String key, Uint8List payload) async {
      final seen = retainingCollector(key);
      await publishUntilSeen(
        pubSession,
        key,
        payload,
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return seen.isNotEmpty;
        },
      );
      return seen;
    }

    test(
      'valid UTF-8 round-trips byte-exact through the retained handle',
      () async {
        // Given: a MULTI-BYTE valid-UTF-8 payload. Pure ASCII would survive a
        // string-shaped seam unharmed and so would not discriminate; the
        // byte-length-exceeds-code-unit-length check below is what pins that.
        const key = 'test/retain/fidelity/utf8';
        const text = 'héllo — 世界 — κόσμος';
        final payload = Uint8List.fromList(utf8.encode(text));
        expect(
          payload.length,
          greaterThan(text.length),
          reason: 'the vector must actually be multi-byte to discriminate',
        );

        // When: the sample arrives and the handle is read
        final seen = await retainRoundTrip(key, payload);

        // Then: the handle's read equals what was published, byte for byte
        final retained = seen.first.payloadZBytes;
        expect(retained, isNotNull);
        final read = retained!.toBytes();
        expect(read.length, equals(payload.length));
        expect(read, equals(payload));
      },
    );

    test('raw binary and invalid UTF-8 round-trip byte-exact', () async {
      // Given: bytes that are NEVER valid UTF-8. 0xFF and 0xFE can begin no
      // sequence at all, 0x80 is a bare continuation byte, and 0xC0 is an
      // overlong lead. A validating extractor renders each as U+FFFD; a
      // lenient one does the same, quietly.
      const key = 'test/retain/fidelity/binary';
      final payload = Uint8List.fromList([0xFF, 0xFE, 0x80, 0xC0, 0x01]);

      // When: the sample arrives and the handle is read
      final seen = await retainRoundTrip(key, payload);

      // Then: all five bytes come back unchanged...
      final retained = seen.first.payloadZBytes;
      expect(retained, isNotNull);
      final read = retained!.toBytes();
      expect(read.length, equals(5));
      expect(read, equals(payload));

      // ...and no U+FFFD appears anywhere in the handle's read. Asserted on
      // the BYTES, because that is the form a replacement would take here:
      // the three-byte sequence 0xEF 0xBF 0xBD. Asking a decoded String
      // whether it holds U+FFFD would put the question to the decoder rather
      // than to the path under test.
      expect(
        containsSequence(read, const [0xEF, 0xBF, 0xBD]),
        isFalse,
        reason: 'a U+FFFD replacement reached the retained handle',
      );
    });

    test('an interior NUL survives the whole path', () async {
      // Given: a payload with TWO NUL runs, one single and one double, and a
      // non-NUL byte after each. No NUL is spelled as a literal anywhere --
      // 0x00 is written as a list element, so the file stays text to every
      // review instrument.
      const key = 'test/retain/fidelity/nul';
      final payload = Uint8List.fromList([0x61, 0x00, 0x62, 0x00, 0x00, 0x63]);

      // When: the sample arrives and the handle is read
      final seen = await retainRoundTrip(key, payload);

      // Then: the LENGTH first and named. A NUL-terminated copy truncates to
      // one byte and still reads correctly at index 0, so a comparison that
      // stopped at the shared prefix would pass on a truncation.
      final retained = seen.first.payloadZBytes;
      expect(retained, isNotNull);
      final read = retained!.toBytes();
      expect(read.length, equals(6), reason: 'truncated at a NUL');
      expect(read, equals(payload));
      // Both runs, stated as bytes: a seam that collapsed a NUL run would
      // still satisfy a length check if it padded elsewhere.
      expect(read[1], equals(0));
      expect(read[3], equals(0));
      expect(read[4], equals(0));
      expect(read[5], equals(0x63), reason: 'the byte AFTER the double NUL');
    });

    test('an empty payload is present-but-empty, never absent', () async {
      // Given: a PUT of zero bytes with retention ON. Conflating ABSENT with
      // EMPTY is the NULL-vs-empty transform this project's fidelity doctrine
      // names outright, and the empty corner of the domain is where the two
      // are easiest to confuse: `null` and `[]` both read as "nothing here".
      const key = 'test/retain/fidelity/empty';

      // When: the sample arrives
      final seen = await retainRoundTrip(key, Uint8List(0));

      // Then: non-null (PRESENT) with a zero-length read (EMPTY). Both legs
      // are stated, because either alone is satisfied by the other's defect.
      final retained = seen.first.payloadZBytes;
      expect(retained, isNotNull, reason: 'empty was rendered as absent');
      expect(retained!.toBytes().length, equals(0));
      expect(retained.toBytes(), equals(Uint8List(0)));
      expect(seen.first.kind, equals(SampleKind.put));
    });

    test(
      'a payload larger than one transport frame round-trips byte-exact',
      () async {
        // Given: 4 MiB against canon's 65535-byte default batch -- 64 batches,
        // so the transport MUST fragment it and the receive path must
        // defragment it. Deterministic fill (all 256 byte values cycled, so
        // interior NULs and invalid UTF-8 recur at every fragment boundary),
        // and a rolling checksum recorded over the SENT bytes.
        const key = 'test/retain/fidelity/large';
        const size = 4 * 1024 * 1024;
        final payload = deterministicFill(size);
        final sentSum = fnv1a32(payload);

        // The frame premise is READ, not assumed. The batch size actually in
        // force is asked of a config built like this group's, so "larger than
        // one transport frame" tracks the pinned zenoh-c version by
        // construction rather than resting on a default written here.
        final probe = Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false');
        addTearDown(probe.dispose);
        final batch = int.parse(probe.get('transport/link/tx/batch_size'));
        expect(
          size,
          greaterThan(batch),
          reason: 'the payload must exceed the batch size in force ($batch)',
        );

        final seen = retainingCollector(key);

        // Land a ONE-BYTE sample first, so the declaration is known to have
        // propagated before 4 MiB is pushed at it. Re-publishing 4 MiB inside a
        // discovery loop would flood the link rather than measure it.
        await publishUntilSeen(
          pubSession,
          key,
          Uint8List.fromList([0x01]),
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return seen.isNotEmpty;
          },
        );
        seen.clear();

        // When: the large payload is published once and awaited. A longer
        // deadline than the small cells carry -- but still BOUNDED, and it
        // fails naming what it did see rather than hanging the serial suite.
        pubSession.putBytes(
          key,
          ZBytes.fromUint8List(payload),
          congestionControl: CongestionControl.block,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        Sample? big;
        while (big == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          for (final s in seen) {
            if (s.payloadBytes.length == size) {
              big = s;
              break;
            }
          }
        }
        expect(
          big,
          isNotNull,
          reason:
              'no $size-byte sample within 90s; saw ${seen.length} '
              'sample(s), lengths ${seen.map((s) => s.payloadBytes.length)}',
        );

        // Then: the handle's read is the same length, the same checksum and the
        // same bytes. The checksum is not redundant with the buffer walk: it is
        // computed over the sent buffer BEFORE the hop and over the received
        // buffer after it, so it also pins that the vector itself was not
        // rebuilt differently on the two sides.
        final retained = big!.payloadZBytes;
        expect(retained, isNotNull);
        final read = retained!.toBytes();
        expect(read.length, equals(size));
        expect(
          fnv1a32(read),
          equals(sentSum),
          reason: 'checksum diverged across the fragmenting hop',
        );
        // Byte-for-byte, reported as the FIRST divergent index rather than as a
        // four-million-element matcher diff.
        var firstDiff = -1;
        for (var i = 0; i < size; i++) {
          if (read[i] != payload[i]) {
            firstDiff = i;
            break;
          }
        }
        expect(
          firstDiff,
          equals(-1),
          reason: 'first byte divergence at index $firstDiff',
        );
      },
    );

    test('the retention path carries no forbidden transform', () {
      // A STATIC SCAN expressed as a cell. It is scoped to the RETENTION code
      // specifically and never to a whole file: each of these three files
      // legitimately carries other paths (subscriber.dart decodes the display
      // strings leniently, bytes.dart offers toStr), so a whole-file
      // assertion would be scoped to the tree rather than to the thing under
      // test -- a recorded defect class here.
      //
      // WHAT WAS SCANNED — six regions, each anchored on its own declaration,
      // each anchor asserted to occur EXACTLY ONCE, each region ending at the
      // first line at or shallower than the anchor's own indentation:
      //   src/zenoh_dart.c         the sample callback's clone-and-post block
      //   src/zenoh_dart.c         zd_bytes_to_buf, the handle's read
      //   lib/src/subscriber.dart  the element-9 image extraction
      //   lib/src/subscriber.dart  the payloadZBytes construction
      //   lib/src/bytes.dart       ZBytes.fromPostedImage
      //   lib/src/bytes.dart       ZBytes.toBytes
      //
      // WHAT WAS FOUND — the clone is z_bytes_clone taken on the LOANED
      // payload and posted as Dart_CObject_kTypedData; the read is
      // z_bytes_reader_read into a caller-sized buffer; the Dart side moves
      // the posted image bitwise into its own slot and reads back through
      // zd_bytes_to_buf. No string type appears on any of the six regions in
      // either direction, and the one error path throws rather than
      // substituting.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      final subscriberSrc = File('lib/src/subscriber.dart').readAsStringSync();
      final bytesSrc = File('lib/src/bytes.dart').readAsStringSync();

      final regions = <String, String>{
        // ⛔ FOUR CLONE SITES, NOT ONE — and this list grew because the
        // instrument BROKE when it was one. The original anchor was
        // `z_owned_bytes_t retained_payload;`, which was unique when only the
        // sample callback retained. The reply column added a second
        // declaration and `regionOf`'s uniqueness guard fired, correctly: the
        // cell went red on correct code because the instrument no longer knew
        // which region it meant.
        //
        // ⭐ Repaired by WIDENING COVERAGE, not by narrowing the anchor.
        // Picking one site would have left the other three retention paths
        // unscanned, which is how an instrument keeps reading green while the
        // thing it guards moves out from under it. Each anchor below is
        // asserted unique, and together they cover every path on which this
        // unit clones a received payload.
        'zenoh_dart.c :: sample push clone-and-post': regionOf(
          shim,
          '// Seed [10a] element 9: the RETAINED payload handle.',
          '// Cleanup',
        ),
        'zenoh_dart.c :: reply push clone-and-post': regionOf(
          shim,
          '// Seed [10a] element 12: the RETAINED payload handle, '
              'same mechanism as',
          '// Cleanup',
        ),
        'zenoh_dart.c :: pull sample clone': regionOf(
          shim,
          '// Seed [10a]: the retained payload handle, on the PULL path.',
          '// Drop the owned sample',
        ),
        'zenoh_dart.c :: pull reply clone': regionOf(
          shim,
          '// Seed [10a]: the retained payload handle, '
              'on the PULL REPLY path.',
          '} else {',
        ),
        'zenoh_dart.c :: zd_bytes_to_buf': regionOf(
          shim,
          'FFI_PLUGIN_EXPORT int8_t zd_bytes_to_buf(',
          '}',
        ),
        'subscriber.dart :: element-9 extraction': regionOf(
          subscriberSrc,
          'final retainedImage = message.length > 9',
          'final sample = Sample(',
        ),
        'subscriber.dart :: payloadZBytes construction': lineOf(
          subscriberSrc,
          'payloadZBytes: ZBytes.fromPostedImage(',
        ),
        'bytes.dart :: fromPostedImage': regionOf(
          bytesSrc,
          'static ZBytes? fromPostedImage(',
          '}',
        ),
        'bytes.dart :: toBytes': regionOf(
          bytesSrc,
          'Uint8List toBytes() {',
          '}',
        ),
      };

      // ANTI-VACUITY. An anchor that drifted would yield an empty or wrong
      // region and every absence assertion below would pass on nothing. Each
      // marker is the one call the region exists to make.
      const markers = <String, String>{
        'zenoh_dart.c :: sample push clone-and-post': 'z_bytes_clone',
        'zenoh_dart.c :: reply push clone-and-post': 'z_bytes_clone',
        'zenoh_dart.c :: pull sample clone': 'z_bytes_clone',
        'zenoh_dart.c :: pull reply clone': 'z_bytes_clone',
        'zenoh_dart.c :: zd_bytes_to_buf': 'z_bytes_reader_read',
        'subscriber.dart :: element-9 extraction': 'message[9]',
        'subscriber.dart :: payloadZBytes construction': 'fromPostedImage',
        'bytes.dart :: fromPostedImage': 'zd_bytes_sizeof',
        'bytes.dart :: toBytes': 'zd_bytes_to_buf',
      };
      markers.forEach((name, marker) {
        expect(
          regions[name],
          contains(marker),
          reason: 'the "$name" anchor drifted — the region is not that code',
        );
      });

      // THE FORBIDDEN TRANSFORMS, each named with the way it corrupts.
      const forbidden = <String, String>{
        'z_bytes_to_string':
            'a UTF-8-VALIDATING extractor on an '
            'opaque-bytes path — the shipped defect verbatim',
        'Dart_CObject_kString':
            'a C-string post: the Dart seam measures it '
            'with strlen, so an interior NUL truncates the value',
        'utf8.decode':
            'the retained bytes becoming a String — lossy '
            'strictly (throws) and lossy leniently (U+FFFD)',
        '??': 'a silent default substituted for the real value',
        'catch': 'a swallowed failure, which substitutes a default silently',
      };
      regions.forEach((name, source) {
        forbidden.forEach((token, why) {
          expect(
            source,
            isNot(contains(token)),
            reason: '$name contains `$token`: $why',
          );
        });
      });

      // And the one POSITIVE leg. A silent default on the image-length
      // mismatch would be the same defect class wearing a different hat: it
      // would substitute a zero-filled handle for a bad image rather than
      // saying so.
      expect(
        regions['bytes.dart :: fromPostedImage'],
        contains('throw StateError'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Slice 7 — the flag on every OTHER sample-carrying carrier.
  //
  // Slice 2 wired retention onto `declareSubscriber` alone. FIVE more shim
  // registrations post the same ten-element sample message, and each takes its
  // OWN flag: a caller who opted one carrier in has not thereby opted in the
  // others. The two groups below drive each of the five, and the last cell
  // drives all six together against a count read out of the shim source.
  // -------------------------------------------------------------------------
  group('Received payload retention — the other push carriers (TCP 19724)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19724"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      subSession = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19724"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      pubSession = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    test(
      'a background subscriber retains when its declaration opts in',
      () async {
        // Given: a BACKGROUND subscriber — fire-and-forget, no handle to close,
        // it lives until the session does — declared with retention on. Its own
        // shim registration, not the one slice 2 wired.
        const key = 'test/retain/background';
        // Interior NUL plus 0xFF, which is never valid UTF-8: a string-shaped
        // seam on THIS carrier would truncate at the NUL or substitute U+FFFD,
        // and either shows up as a mismatch below.
        final payload = Uint8List.fromList([0x62, 0x00, 0xFF, 0x67]);

        final seen = <Sample>[];
        releaseAll(seen);
        final stream = subSession.declareBackgroundSubscriber(
          key,
          retainPayload: true,
        );
        final sub = stream.listen(seen.add);
        addTearDown(sub.cancel);

        // When: a sample arrives
        await publishUntilSeen(
          pubSession,
          key,
          payload,
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return seen.isNotEmpty;
          },
        );

        // Then: the handle is present and reads the published bytes exactly
        final retained = seen.first.payloadZBytes;
        expect(retained, isNotNull);
        expect(retained!.toBytes(), equals(payload));
        expect(retained.toBytes().length, equals(4), reason: 'truncated');
      },
    );

    test(
      'a liveliness subscriber retains when its declaration opts in',
      () async {
        // Given: a retention-enabled liveliness subscriber, and a token
        // declared on a matching key by the other session.
        const key = 'test/retain/liveliness';

        final seen = <Sample>[];
        releaseAll(seen);
        final subscriber = subSession.declareLivelinessSubscriber(
          '$key/*',
          retainPayload: true,
        );
        addTearDown(subscriber.close);
        final sub = subscriber.stream.listen(seen.add);
        addTearDown(sub.cancel);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // When: the token appears
        final token = pubSession.declareLivelinessToken('$key/1');
        addTearDown(token.close);
        await awaitSample(seen, 'liveliness PUT');

        // Then: the handle is PRESENT
        expect(seen.first.kind, equals(SampleKind.put));
        final retained = seen.first.payloadZBytes;
        expect(retained, isNotNull);

        // ⚠️ AND IT IS EMPTY — MEASURED ON THIS TREE, not inherited from any
        // other surface's expectation. A liveliness announcement is canon's own
        // sample and canon sends it with no user payload at all, so the clone
        // this carrier retains is zero-length.
        //
        // Measured 2026-08-31 against the shipped native, on a two-session TCP
        // pair like this one: `payloadBytes.length == 0` and
        // `payloadZBytes!.toBytes().length == 0` — for the PUT on declaration
        // AND for the DELETE on close, on the plain and the background
        // liveliness carriers alike.
        //
        // Recorded as PRESENT-BUT-EMPTY, which is the whole distinction
        // retention draws: a carrier that did NOT opt in delivers `null` here,
        // and this one delivers a zero-length handle. Both legs are stated
        // because either alone is satisfied by the other's defect.
        expect(retained!.toBytes().length, equals(0));
        expect(seen.first.payloadBytes.length, equals(0));
      },
    );

    test('a background liveliness subscriber retains when its declaration '
        'opts in', () async {
      // Given: the BACKGROUND liveliness carrier — a fourth registration,
      // distinct from the plain liveliness one above.
      const key = 'test/retain/bg-liveliness';

      final seen = <Sample>[];
      releaseAll(seen);
      final stream = subSession.declareBackgroundLivelinessSubscriber(
        '$key/*',
        retainPayload: true,
      );
      final sub = stream.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // When: the token appears
      final token = pubSession.declareLivelinessToken('$key/1');
      addTearDown(token.close);
      await awaitSample(seen, 'background liveliness PUT');

      // Then: present, and — same measurement as the plain liveliness
      // carrier, stated on ITS OWN carrier rather than inferred from that
      // one, because these are two separate shim registrations — zero-length.
      expect(seen.first.kind, equals(SampleKind.put));
      final retained = seen.first.payloadZBytes;
      expect(retained, isNotNull);
      expect(retained!.toBytes().length, equals(0));
      expect(seen.first.payloadBytes.length, equals(0));
    });
  });

  group(
    'Received payload retention — the advanced carriers (TCP 19725)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session subSession;
      late Session pubSession;

      setUpAll(() async {
        // `timestamping/enabled` is not decoration here: the advanced
        // publisher and the advanced subscriber both require it.
        final listenConfig = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19725"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        subSession = await Session.open(config: listenConfig);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final connectConfig = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19725"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        pubSession = await Session.open(config: connectConfig);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        pubSession.close();
        subSession.close();
      });

      test(
        'an advanced subscriber retains through its OPTIONS object',
        () async {
          // Given: retention asked for on `AdvancedSubscriberOptions` and NOT
          // as a loose parameter. The advanced surfaces carry their knobs on
          // the options object, and retention is no exception — a loose
          // parameter here would be the odd one out.
          const key = 'test/retain/advanced';
          final payload = Uint8List.fromList([0xA1, 0x00, 0xFF, 0x5A, 0x00]);

          final seen = <Sample>[];
          releaseAll(seen);
          final subscriber = subSession.declareAdvancedSubscriber(
            key,
            options: const AdvancedSubscriberOptions(retainPayload: true),
          );
          addTearDown(subscriber.close);
          final sub = subscriber.stream.listen(seen.add);
          addTearDown(sub.cancel);

          // When: a sample arrives on the advanced subscriber's own stream
          await publishUntilSeen(
            pubSession,
            key,
            payload,
            () async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              return seen.isNotEmpty;
            },
          );

          // Then: present, and byte-exact through the interior NULs
          final retained = seen.first.payloadZBytes;
          expect(retained, isNotNull);
          expect(retained!.toBytes(), equals(payload));
          expect(retained.toBytes().length, equals(5), reason: 'truncated');
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'the publisher-detection stream retains through ITS own options',
        () async {
          // Given: an advanced subscriber whose DETECTION stream opts in, on a
          // flag of its own.
          //
          // ⚠️ This is the SIXTH registration and the one a count of "five
          // sample surfaces" omits: a separate closure on a separate port with
          // its own context. `AdvancedSubscriberOptions.retainPayload` governs
          // the data stream ONLY — this flag lives on
          // `DetectPublishersOptions`, and the cell deliberately leaves the
          // subscriber's own retention OFF so nothing here can pass by
          // inheriting it.
          const key = 'test/retain/detect';

          final detected = <Sample>[];
          releaseAll(detected);
          final subscriber = subSession.declareAdvancedSubscriber(
            key,
            options: const AdvancedSubscriberOptions(
              detectPublishers: DetectPublishersOptions(retainPayload: true),
            ),
          );
          addTearDown(subscriber.close);
          final sub = subscriber.detectedPublishers!.listen(detected.add);
          addTearDown(sub.cancel);
          await Future<void>.delayed(const Duration(milliseconds: 500));

          // When: a matching advanced publisher appears
          final publisher = pubSession.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);
          await awaitSample(detected, 'publisher-detection event');

          // Then: the detection sample carries a handle...
          final sample = detected.first;
          expect(sample.kind, equals(SampleKind.put));
          final retained = sample.payloadZBytes;
          expect(retained, isNotNull);

          // ...and it is PRESENT-BUT-EMPTY, measured here on this carrier
          // rather than inherited. Detection is backed by a liveliness token,
          // so what arrives carries no user payload: measured 2026-08-31,
          // `payloadBytes.length == 0` and the retained read is zero-length.
          // The claim is that the sixth registration reaches the SAME PARSE,
          // not that it carries data.
          expect(retained!.toBytes().length, equals(0));
          expect(sample.payloadBytes.length, equals(0));

          // And it came off the detection stream, not off some other one: the
          // announcement token sits under the declared key. Stated so a failure
          // reads as "the wrong stream" rather than as "no event".
          expect(sample.keyExpr, startsWith('$key/@adv/pub/'));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'all six sample-carrying registrations reach the same parse',
        () async {
          // ═══ THE INSTRUMENT THAT PRODUCES THE NUMBER SIX ═══
          //
          // Asserted here, not merely quoted, so a seventh payload-carrying
          // registration added later REDDENS this cell instead of slipping past
          // a stale number in a comment:
          //
          //   awk '/z_closure_sample\(&callback, _zd_sample_callback/ {n++} \
          //        END {print n}' src/zenoh_dart.c              ->  6
          //
          // Those six are zd_declare_subscriber,
          // zd_declare_background_subscriber, zd_liveliness_declare_subscriber,
          // zd_liveliness_declare_background_subscriber,
          // zd_declare_advanced_subscriber and
          // zd_advanced_subscriber_detect_publishers_background. MINUS NONE —
          // every one of the six carries a payload.
          //
          // A SEVENTH `zd_subscriber_context_t` site exists, and it is
          // deliberately NOT one of them:
          //
          //   awk '/malloc\(sizeof\(zd_subscriber_context_t\)\)/ {n++} \
          //        END {print n}' src/zenoh_dart.c              ->  7
          //
          // The extra one registers `ze_closure_miss` / `_zd_miss_callback`,
          // which carries a source id and a count and no payload at all, so it
          // has nothing to retain and its `ctx->retain_payload` is 0
          // permanently. Both numbers are read out of the source below, so the
          // six-versus-seven distinction is MEASURED rather than remembered.
          final shim = File('../src/zenoh_dart.c').readAsStringSync();
          final sampleSites = RegExp(
            r'z_closure_sample\(&callback, _zd_sample_callback',
          ).allMatches(shim).length;
          expect(
            sampleSites,
            equals(6),
            reason:
                'the shim registers $sampleSites payload-carrying sample '
                'callbacks; this cell exercises six',
          );
          final contextSites = RegExp(
            r'malloc\(sizeof\(zd_subscriber_context_t\)\)',
          ).allMatches(shim).length;
          expect(
            contextSites,
            equals(7),
            reason:
                'the miss listener is the seventh context site and the one '
                'that carries no payload; found $contextSites',
          );

          // Given: one carrier of each of the six kinds, every one opted in.
          const dataKey = 'test/retain/six/data';
          const liveKey = 'test/retain/six/live';
          final payload = Uint8List.fromList([0x36, 0x00, 0xFE, 0x78]);

          final plain = <Sample>[];
          releaseAll(plain);
          final plainSub = subSession.declareSubscriber(
            dataKey,
            retainPayload: true,
          );
          addTearDown(plainSub.close);
          final s1 = plainSub.stream.listen(plain.add);
          addTearDown(s1.cancel);

          final background = <Sample>[];
          releaseAll(background);
          final s2 = subSession
              .declareBackgroundSubscriber(dataKey, retainPayload: true)
              .listen(background.add);
          addTearDown(s2.cancel);

          final liveliness = <Sample>[];
          releaseAll(liveliness);
          final liveSub = subSession.declareLivelinessSubscriber(
            '$liveKey/*',
            retainPayload: true,
          );
          addTearDown(liveSub.close);
          final s3 = liveSub.stream.listen(liveliness.add);
          addTearDown(s3.cancel);

          final bgLiveliness = <Sample>[];
          releaseAll(bgLiveliness);
          final s4 = subSession
              .declareBackgroundLivelinessSubscriber(
                '$liveKey/*',
                retainPayload: true,
              )
              .listen(bgLiveliness.add);
          addTearDown(s4.cancel);

          final advanced = <Sample>[];
          final detected = <Sample>[];
          releaseAll(advanced);
          releaseAll(detected);
          final advSub = subSession.declareAdvancedSubscriber(
            dataKey,
            options: const AdvancedSubscriberOptions(
              retainPayload: true,
              detectPublishers: DetectPublishersOptions(retainPayload: true),
            ),
          );
          addTearDown(advSub.close);
          final s5 = advSub.stream.listen(advanced.add);
          addTearDown(s5.cancel);
          final s6 = advSub.detectedPublishers!.listen(detected.add);
          addTearDown(s6.cancel);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          // When: ONE token, ONE advanced publisher and ONE publication loop
          // drive all six.
          final token = pubSession.declareLivelinessToken('$liveKey/1');
          addTearDown(token.close);
          final publisher = pubSession.declareAdvancedPublisher(
            dataKey,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          final carriers = <String, List<Sample>>{
            'declareSubscriber': plain,
            'declareBackgroundSubscriber': background,
            'declareLivelinessSubscriber': liveliness,
            'declareBackgroundLivelinessSubscriber': bgLiveliness,
            'AdvancedSubscriber.stream': advanced,
            'AdvancedSubscriber.detectedPublishers': detected,
          };
          // The set exercised is tied to the number read from the shim, so the
          // two cannot drift apart silently.
          expect(carriers, hasLength(sampleSites));

          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (carriers.values.any((v) => v.isEmpty) &&
              DateTime.now().isBefore(deadline)) {
            // putBytes CONSUMES its payload, so each attempt builds its own.
            publisher.putBytes(ZBytes.fromUint8List(payload));
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          final silent = carriers.entries
              .where((e) => e.value.isEmpty)
              .map((e) => e.key)
              .toList();
          expect(silent, isEmpty, reason: 'no sample reached: $silent');

          // Then: every one of the six hands back a retained handle — counted,
          // and the count IS the number read out of the shim above.
          final retaining = carriers.entries
              .where((e) => e.value.first.payloadZBytes != null)
              .map((e) => e.key)
              .toSet();
          expect(
            retaining,
            hasLength(sampleSites),
            reason:
                'took the flag and retained nothing: '
                '${carriers.keys.toSet().difference(retaining)}',
          );
          expect(retaining, hasLength(6));

          // And the THREE carriers that carry user data read it back exactly.
          // The other three are liveliness- and detection-backed, whose samples
          // canon sends with no payload at all — present and zero-length, each
          // measured on its own cell above.
          expect(plain.first.payloadZBytes!.toBytes(), equals(payload));
          expect(background.first.payloadZBytes!.toBytes(), equals(payload));
          expect(advanced.first.payloadZBytes!.toBytes(), equals(payload));
          expect(liveliness.first.payloadZBytes!.toBytes().length, equals(0));
          expect(bgLiveliness.first.payloadZBytes!.toBytes().length, equals(0));
          expect(detected.first.payloadZBytes!.toBytes().length, equals(0));
        },
        timeout: const Timeout(Duration(seconds: 180)),
      );
    },
  );
}

/// Returns the dartdoc block immediately above [signature] in [source].
///
/// Walks backwards over the consecutive `///` lines, so an assertion made on
/// the result is about THAT member's documented contract -- a word appearing
/// anywhere else in the file cannot satisfy it.
///
/// [signature] is matched as a line PREFIX and the match is asserted UNIQUE,
/// which is what keeps a prefix honest. Same instrument `bytes_test.dart`
/// uses for the same job.
String docCommentFor(String source, String signature) {
  final lines = const LineSplitter().convert(source);
  final matches = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].trim().startsWith(signature)) i,
  ];
  expect(matches, hasLength(1), reason: 'one declaration of: $signature');
  final index = matches.single;
  final doc = <String>[];
  for (var i = index - 1; i >= 0 && lines[i].trim().startsWith('///'); i--) {
    doc.insert(0, lines[i].trim());
  }
  expect(doc, isNotEmpty, reason: 'no dartdoc above $signature');
  return doc.join('\n');
}

/// A deterministic, adversarial fill of [length] bytes.
///
/// Cycles all 256 byte values, so it carries interior NULs and invalid UTF-8
/// at every scale and at every fragment boundary. A large-payload test built
/// on printable text would miss a lossy re-encode at a boundary, which is
/// exactly the class this package has shipped a defect in before.
Uint8List deterministicFill(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) % 256));

/// FNV-1a, 32 bit, over [bytes].
///
/// A rolling checksum computed over what was SENT and again over what was
/// RECEIVED. It is order-sensitive and avalanching, so a reordered or
/// partially-substituted fragment moves it even where the two buffers happen
/// to share a length.
int fnv1a32(Uint8List bytes) {
  var hash = 0x811C9DC5;
  for (final b in bytes) {
    hash = (hash ^ b) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Whether [needle] occurs anywhere inside [haystack].
///
/// Used to assert the ABSENCE of the U+FFFD replacement sequence in a raw
/// byte read, which is the observable a validating extractor leaves behind.
bool containsSequence(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Returns the source region of [source] running from the unique line whose
/// trimmed text starts with [from], down to (but excluding) the first later
/// line whose trimmed text equals [to] AND whose indentation is no deeper
/// than the anchor's.
///
/// The indentation rule is what makes a block-closing end anchor usable: a
/// method whose body contains a nested `}` ends at the `}` that closes the
/// method, not at the one that closes the `if` inside it.
///
/// The start anchor is asserted UNIQUE, which is what keeps a prefix honest —
/// same discipline [docCommentFor] uses.
String regionOf(String source, String from, String to) {
  final lines = const LineSplitter().convert(source);
  final starts = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].trim().startsWith(from)) i,
  ];
  expect(starts, hasLength(1), reason: 'one region start for: $from');
  final start = starts.single;
  final anchorIndent = lines[start].length - lines[start].trimLeft().length;
  var end = -1;
  for (var i = start + 1; i < lines.length; i++) {
    final indent = lines[i].length - lines[i].trimLeft().length;
    if (indent <= anchorIndent && lines[i].trim() == to) {
      end = i;
      break;
    }
  }
  expect(end, greaterThan(start), reason: 'no region end "$to" after: $from');
  return lines.sublist(start, end).join('\n');
}

/// Returns the single line of [source] whose trimmed text starts with
/// [prefix], asserting that exactly one such line exists.
String lineOf(String source, String prefix) {
  final matches = <String>[
    for (final line in const LineSplitter().convert(source))
      if (line.trim().startsWith(prefix)) line,
  ];
  expect(matches, hasLength(1), reason: 'one line starting with: $prefix');
  return matches.single;
}
