// The SEND half of seed #10's criterion A: an encoding leaves byte-exact.
//
// The receive half is already length-carried (its own file), so these cells are
// genuinely about the send seam: what reaches the subscriber is what the sender
// set, or it is not. Two Dart sessions are enough here for exactly that reason
// — the receiving side is no longer a suspect.
//
// EVERY interior-NUL leg carries its NUL-free control, in the same run on the
// same path. Without it a green proves the path works, not that it is
// length-faithful.
//
// ⚠️ THIS FILE ASSERTS CANON'S CONTRACT, NOT RAW BYTE-IDENTITY, on the two legs
// where canon itself normalizes. Measured, round-tripping through canon:
// `''` becomes `'zenoh/bytes'`, `'text/plain;'` becomes `'text/plain'` (a
// well-known id, normalized through an id lookup) while `'foo/bar;'` is
// PRESERVED (a custom id, round-tripped as text). Two otherwise-reasonable
// cells would go red for canon's reasons rather than ours. The matcher is
// narrowed INTO that contract rather than widened to swallow it; the
// interior-NUL cells keep full byte-identity strength, being unaffected by it.
//
// No control byte is spelled as a literal: the interior NUL is BUILT with
// `String.fromCharCode(0)`. A raw NUL in a tracked file turns it binary to
// `grep`.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/native_lib.dart';
// The unstable door is a strict superset of the stable one, so this single
// import covers both. The advanced-publisher group gates on ZenohFeatures.
import 'package:zenoh_dart/zenoh_unstable.dart';

/// The interior NUL, built rather than spelled.
final nul = String.fromCharCode(0);

/// GT-1's subject: 20 bytes with the NUL at index 10.
final subjectMime = 'text/plain${nul}AFTER-NUL';

/// GT-1's control: 24 bytes carrying canon's own `;` separator.
const controlMime = 'text/plain;charset=utf-8';

/// A 3-byte schema whose middle byte is the interior NUL.
final nulSchema = 'a${nul}b';

/// A schema whose code points are multi-byte in UTF-8.
const multiByteSchema = 'schéma-Ω';

void main() {
  group('Encoding send fidelity — Session.put/putBytes (TCP 19554)', () {
    late Session sender;
    late Session receiver;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19554"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sender = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19554"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      receiver = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      receiver.close();
      sender.close();
    });

    /// Publishes once on [key] with [encoding] and returns the received sample.
    ///
    /// [useBytes] selects `putBytes` over `put`, so the two marshalling sites
    /// are each driven through their own pair rather than one standing in for
    /// the other.
    Future<Sample> send(
      String key,
      Encoding encoding, {
      bool useBytes = false,
    }) async {
      final subscriber = receiver.declareSubscriber(key);
      addTearDown(subscriber.close);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final first = subscriber.stream.first;
      if (useBytes) {
        sender.putBytes(key, ZBytes.fromString('payload'), encoding: encoding);
      } else {
        sender.put(key, 'payload', encoding: encoding);
      }
      return first.timeout(const Duration(seconds: 10));
    }

    test('an interior-NUL MIME string survives Session.put', () async {
      final sample = await send(
        'zenoh/dart/s10/send/nul',
        Encoding(subjectMime),
      );

      expect(subjectMime.length, equals(20));
      expect(sample.encoding, equals(subjectMime));
      expect(sample.encodingBytes, equals(utf8.encode(subjectMime)));
      expect(sample.encoding!.codeUnitAt(10), equals(0));
    });

    test('the same through Session.putBytes', () async {
      final sample = await send(
        'zenoh/dart/s10/send/nul-bytes',
        Encoding(subjectMime),
        useBytes: true,
      );

      expect(sample.encoding, equals(subjectMime));
    });

    test('an interior-NUL schema survives both entry points', () async {
      final encoding = Encoding.textPlain.withSchema(nulSchema);

      final viaPut = await send('zenoh/dart/s10/send/nul-schema', encoding);
      final viaBytes = await send(
        'zenoh/dart/s10/send/nul-schema-bytes',
        encoding,
        useBytes: true,
      );

      // "text/plain" (10) + ";" (1) + the 3-byte schema = 14.
      const expected = 'text/plain';
      expect(viaPut.encoding, equals('$expected;$nulSchema'));
      expect(viaPut.encoding!.length, equals(14));
      expect(viaPut.encoding!.codeUnitAt(12), equals(0));
      expect(viaBytes.encoding, equals('$expected;$nulSchema'));
    });

    test('the NUL-free control on each entry point in the same run', () async {
      final viaPut = await send(
        'zenoh/dart/s10/send/control',
        const Encoding(controlMime),
      );
      final viaBytes = await send(
        'zenoh/dart/s10/send/control-bytes',
        const Encoding(controlMime),
        useBytes: true,
      );

      expect(viaPut.encoding, equals(controlMime));
      expect(viaBytes.encoding, equals(controlMime));
    });

    // Edge cases.

    test('an empty schema arrives as empty, not as absent', () async {
      final empty = await send(
        'zenoh/dart/s10/send/schema-empty',
        Encoding.textPlain.withSchema(''),
      );
      final absent = await send(
        'zenoh/dart/s10/send/schema-absent-ctl',
        Encoding.textPlain,
      );

      // The bare trailing separator IS the empty state on a well-known id.
      expect(empty.encoding, equals('text/plain;'));
      expect(empty.encoding, isNot(equals(absent.encoding)));
    });

    test('an absent schema arrives with no separator', () async {
      final sample = await send(
        'zenoh/dart/s10/send/schema-absent',
        Encoding.textPlain,
      );

      expect(sample.encoding, equals('text/plain'));
      expect(sample.encoding, isNot(contains(';')));
    });

    // ⚠️ CANON'S CONTRACT, NOT OUR OUTPUT. The matcher is narrowed into the
    // asymmetry rather than widened to swallow it: a well-known id round-trips
    // through an id lookup that normalizes away a trailing separator, while a
    // custom id round-trips as text and preserves it.
    test("canon's own normalizations are pinned as canon's contract", () async {
      final emptyMime = await send(
        'zenoh/dart/s10/send/norm-empty',
        const Encoding(''),
      );
      final wellKnown = await send(
        'zenoh/dart/s10/send/norm-known',
        const Encoding('text/plain;'),
      );
      final custom = await send(
        'zenoh/dart/s10/send/norm-custom',
        const Encoding('foo/bar;'),
      );

      expect(emptyMime.encoding, equals('zenoh/bytes'));
      expect(wellKnown.encoding, equals('text/plain'));
      expect(custom.encoding, equals('foo/bar;'));
    });

    // Without this cell the marshalling rule is only INFERABLE from the
    // normalization outcomes above, three slices away from any implementer who
    // wires a send path through the public accessor.
    test('the marshalling rule is pinned directly, not inferred', () async {
      // A composed mimeType with NO schema field set. Under the raw rule the
      // whole string goes to the mime channel verbatim; under the derived
      // reading it would be split and arrive differently.
      final composed = await send(
        'zenoh/dart/s10/send/raw-composed',
        const Encoding('text/plain;composed'),
      );
      final structured = await send(
        'zenoh/dart/s10/send/raw-structured',
        Encoding.textPlain.withSchema('composed'),
      );

      expect(composed.encoding, equals('text/plain;composed'));
      expect(structured.encoding, equals('text/plain;composed'));
    });

    // The empty-schema state COLLAPSES for a custom id, and that limit is
    // canon's own asymmetry, not this binding's. Pinned rather than left to be
    // discovered: measured with `z_encoding_equals` as the discriminator, a
    // custom id has TWO states where a well-known id has three.
    test('the empty-schema state collapses for a custom id', () async {
      final empty = await send(
        'zenoh/dart/s10/send/custom-empty',
        const Encoding('foo/bar').withSchema(''),
      );
      final absent = await send(
        'zenoh/dart/s10/send/custom-absent',
        const Encoding('foo/bar'),
      );

      // Indistinguishable — while the same pair on `text/plain` above is not.
      expect(empty.encoding, equals('foo/bar'));
      expect(absent.encoding, equals('foo/bar'));
      expect(empty.encoding, equals(absent.encoding));
    });

    // ⚠️ THE INVALID-UTF-8 ARM, DRIVEN AT THE BINDINGS LEVEL — and it has to
    // be, because it is NOT PRODUCIBLE FROM THE `Encoding` SURFACE. A `String`
    // cannot carry an invalid UTF-8 sequence to the seam: `utf8.encode`
    // substitutes U+FFFD, so the bytes that would arrive are valid. The seed
    // authorises exactly two forms for a mandated cell with no public driver —
    // drive it at the bindings level, or record the non-producibility beside
    // it. This takes the first and states the second.
    //
    // MEASURED at canon before this cell was written, so it asserts a contract
    // rather than an observation:
    //   set_schema_from_substr(<C0 AF>, 2)  rc=-1  == Z_EINVAL
    //   set_schema_from_substr("ok", 2)     rc=0   <- the control
    // The bytes are BUILT, never spelled: 0xC0 0xAF is the overlong encoding
    // of '/', structurally invalid however it is decoded.
    test('an invalid-UTF-8 schema is refused, driven at the bindings level', () {
      const key = 'zenoh/dart/s10/send/invalid-schema';
      final mimeBytes = utf8.encode('text/plain');
      final mimeBuf = calloc<Uint8>(mimeBytes.length)
        ..asTypedList(mimeBytes.length).setAll(0, mimeBytes);
      // Built at runtime from its two code points, never a source literal.
      final badSchema = <int>[0xC0, 0xAF];
      final schemaBuf = calloc<Uint8>(badSchema.length)
        ..asTypedList(badSchema.length).setAll(0, badSchema);
      final okSchema = utf8.encode('ok');
      final okBuf = calloc<Uint8>(okSchema.length)
        ..asTypedList(okSchema.length).setAll(0, okSchema);

      int callWith(Pointer<Uint8> schema, int schemaLen) {
        final payload = ZBytes.fromString('payload');
        return withLoanedKeyExpr(key, 'keyExpr', (loanedKe) {
          final rc = bindings.zd_put(
            sender.loanedHandle.cast(),
            loanedKe.cast(),
            payload.nativePtr.cast(),
            mimeBuf.cast(),
            mimeBytes.length,
            schema.cast(),
            schemaLen,
            nullptr,
            nullptr,
            -1,
            -1,
            -1,
            -1,
          );
          // zd_put moves the payload on every path, including its own
          // encoding-error early return, which drops what it moved.
          payload.markConsumed();
          return rc;
        });
      }

      try {
        // The subject: canon's own Z_EINVAL, passed through unchanged. A
        // NEGATIVE here is correct and is canon's — binding-minted codes live
        // in positive space, and this one is not binding-minted.
        expect(callWith(schemaBuf, badSchema.length), equals(-1));
        // The control, in the same run through the same entry: without it a
        // red would prove only that the call fails, not that it discriminates.
        expect(callWith(okBuf, okSchema.length), isZero);
      } finally {
        calloc
          ..free(mimeBuf)
          ..free(schemaBuf)
          ..free(okBuf);
      }
    });

    test('a multi-byte UTF-8 schema survives the wire', () async {
      final sample = await send(
        'zenoh/dart/s10/send/multibyte-schema',
        Encoding.textPlain.withSchema(multiByteSchema),
      );

      expect(sample.encoding, equals('text/plain;$multiByteSchema'));
      expect(
        sample.encodingBytes,
        equals(utf8.encode('text/plain;$multiByteSchema')),
      );
    });
  });

  // The publisher family: THREE marshalling sites across TWO exports, so each
  // is driven through its own pair rather than one standing in for the others.
  // The declaration-time default and the per-message override are independent
  // channels, and a truncating carrier would make them indistinguishable.
  group('Encoding send fidelity — publisher family (TCP 19555)', () {
    late Session sender;
    late Session receiver;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19555"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sender = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19555"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      receiver = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      receiver.close();
      sender.close();
    });

    /// Declares a publisher on [key] (optionally with a declaration-time
    /// [declared] encoding), publishes once, and returns the received sample.
    ///
    /// [site] selects which of the three marshalling sites is exercised.
    Future<Sample> viaPublisher(
      String key, {
      Encoding? declared,
      Encoding? perMessage,
      String site = 'put',
    }) async {
      final subscriber = receiver.declareSubscriber(key);
      addTearDown(subscriber.close);

      final publisher = sender.declarePublisher(key, encoding: declared);
      addTearDown(publisher.close);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final first = subscriber.stream.first;
      if (site == 'putBytes') {
        publisher.putBytes(ZBytes.fromString('payload'), encoding: perMessage);
      } else {
        publisher.put('payload', encoding: perMessage);
      }
      return first.timeout(const Duration(seconds: 10));
    }

    test('a declaration-time interior-NUL encoding survives', () async {
      final sample = await viaPublisher(
        'zenoh/dart/s10/pub/declared-nul',
        declared: Encoding(subjectMime),
      );

      expect(sample.encoding, equals(subjectMime));
      expect(sample.encoding!.codeUnitAt(10), equals(0));
    });

    test(
      'a per-message interior-NUL encoding survives Publisher.put',
      () async {
        final sample = await viaPublisher(
          'zenoh/dart/s10/pub/put-nul',
          perMessage: Encoding(subjectMime),
        );

        expect(sample.encoding, equals(subjectMime));
      },
    );

    test('the same through Publisher.putBytes', () async {
      final sample = await viaPublisher(
        'zenoh/dart/s10/pub/putbytes-nul',
        perMessage: Encoding(subjectMime),
        site: 'putBytes',
      );

      expect(sample.encoding, equals(subjectMime));
    });

    test('an interior-NUL schema survives all three sites', () async {
      final encoding = Encoding.textPlain.withSchema(nulSchema);
      const expected = 'text/plain';

      final declared = await viaPublisher(
        'zenoh/dart/s10/pub/schema-declared',
        declared: encoding,
      );
      final put = await viaPublisher(
        'zenoh/dart/s10/pub/schema-put',
        perMessage: encoding,
      );
      final putBytes = await viaPublisher(
        'zenoh/dart/s10/pub/schema-bytes',
        perMessage: encoding,
        site: 'putBytes',
      );

      for (final sample in [declared, put, putBytes]) {
        expect(sample.encoding, equals('$expected;$nulSchema'));
        expect(sample.encoding!.codeUnitAt(12), equals(0));
      }
    });

    test('the NUL-free control at each of the three sites', () async {
      final declared = await viaPublisher(
        'zenoh/dart/s10/pub/ctl-declared',
        declared: const Encoding(controlMime),
      );
      final put = await viaPublisher(
        'zenoh/dart/s10/pub/ctl-put',
        perMessage: const Encoding(controlMime),
      );
      final putBytes = await viaPublisher(
        'zenoh/dart/s10/pub/ctl-bytes',
        perMessage: const Encoding(controlMime),
        site: 'putBytes',
      );

      expect(declared.encoding, equals(controlMime));
      expect(put.encoding, equals(controlMime));
      expect(putBytes.encoding, equals(controlMime));
    });

    // Edge cases.

    // The discriminating pair: if the two channels were not independent, a
    // truncating carrier could let one silently win. Both encodings carry an
    // interior NUL, so a truncation would collapse them onto the same prefix
    // and the assertion could not tell which arrived.
    test('a per-message encoding overrides the declaration-time one', () async {
      final other = 'text/other${nul}TAIL-XYZ';
      final sample = await viaPublisher(
        'zenoh/dart/s10/pub/override',
        declared: Encoding(subjectMime),
        perMessage: Encoding(other),
      );

      expect(sample.encoding, equals(other));
      expect(sample.encoding, isNot(equals(subjectMime)));
    });

    test(
      'empty and absent schemas stay distinct at declaration time',
      () async {
        final empty = await viaPublisher(
          'zenoh/dart/s10/pub/decl-empty',
          declared: Encoding.textPlain.withSchema(''),
        );
        final absent = await viaPublisher(
          'zenoh/dart/s10/pub/decl-absent',
          declared: Encoding.textPlain,
        );

        expect(empty.encoding, equals('text/plain;'));
        expect(absent.encoding, equals('text/plain'));
        expect(empty.encoding, isNot(equals(absent.encoding)));
      },
    );
  });

  // The get family: two exports over ONE shared C body
  // (`_zd_fill_get_options`), so the contract lands once and both inherit it —
  // but each Dart marshalling site is still driven through its own pair,
  // because they are separate code.
  group('Encoding send fidelity — get family (TCP 19556)', () {
    late Session getter;
    late Session host;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19556"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      host = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19556"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      host.close();
    });

    /// Declares our queryable on [key], issues one query carrying [encoding],
    /// and returns the query as the queryable saw it.
    ///
    /// [pull] selects `Session.pullGet` over `Session.get` — the second
    /// marshalling site, which an earlier draft's count of ten omitted.
    Future<Query> query(
      String key, {
      Encoding? encoding,
      bool withPayload = true,
      bool pull = false,
    }) async {
      final queryable = host.declareQueryable(key);
      addTearDown(queryable.close);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final first = queryable.stream.first;
      final payload = withPayload ? ZBytes.fromString('q') : null;
      if (pull) {
        final replies = getter.pullGet(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
          payload: payload,
          encoding: encoding,
          timeout: const Duration(seconds: 3),
        );
        addTearDown(replies.dispose);
      } else {
        unawaited(
          getter
              .get(
                key,
                payload: payload,
                encoding: encoding,
                timeout: const Duration(seconds: 3),
              )
              .drain<void>(),
        );
      }
      final received = await first.timeout(const Duration(seconds: 10));
      addTearDown(received.dispose);
      return received;
    }

    test('an interior-NUL query encoding survives Session.get', () async {
      final q = await query(
        'zenoh/dart/s10/get/nul',
        encoding: Encoding(subjectMime),
      );

      expect(q.encoding, equals(subjectMime));
      expect(q.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test('the same through Session.pullGet', () async {
      final q = await query(
        'zenoh/dart/s10/get/nul-pull',
        encoding: Encoding(subjectMime),
        pull: true,
      );

      expect(q.encoding, equals(subjectMime));
    });

    test('an interior-NUL schema survives both entry points', () async {
      final encoding = Encoding.textPlain.withSchema(nulSchema);

      final viaGet = await query(
        'zenoh/dart/s10/get/schema',
        encoding: encoding,
      );
      final viaPull = await query(
        'zenoh/dart/s10/get/schema-pull',
        encoding: encoding,
        pull: true,
      );

      expect(viaGet.encoding, equals('text/plain;$nulSchema'));
      expect(viaPull.encoding, equals('text/plain;$nulSchema'));
    });

    test('the NUL-free control on each entry point in the same run', () async {
      final viaGet = await query(
        'zenoh/dart/s10/get/ctl',
        encoding: const Encoding(controlMime),
      );
      final viaPull = await query(
        'zenoh/dart/s10/get/ctl-pull',
        encoding: const Encoding(controlMime),
        pull: true,
      );

      expect(viaGet.encoding, equals(controlMime));
      expect(viaPull.encoding, equals(controlMime));
    });

    // Edge cases.

    // ⚠️ SAME MEASURED CORRECTION as the receive-side cell: the plan asks for
    // `null` from "a get issued with a PAYLOAD and no encoding", and that is
    // not what canon does — with a payload present it substitutes its own
    // default and the query arrives as 'zenoh/bytes'. What produces the absent
    // state is a get with NO PAYLOAD, which is what the shipped corpus already
    // drives. Both arms are asserted, so GT-16's asymmetry is pinned at its
    // real boundary rather than an assumed one.
    test(
      'a query with no payload arrives null; one with a payload does not',
      () async {
        final absent = await query(
          'zenoh/dart/s10/get/absent',
          withPayload: false,
        );
        final defaulted = await query('zenoh/dart/s10/get/defaulted');

        expect(absent.encoding, isNull);
        expect(absent.encodingBytes, isNull);
        expect(defaulted.encoding, equals('zenoh/bytes'));
      },
    );

    test('empty and absent query schemas stay distinct', () async {
      final empty = await query(
        'zenoh/dart/s10/get/schema-empty',
        encoding: Encoding.textPlain.withSchema(''),
      );
      final absent = await query(
        'zenoh/dart/s10/get/schema-none',
        encoding: Encoding.textPlain,
      );

      expect(empty.encoding, equals('text/plain;'));
      expect(absent.encoding, equals('text/plain'));
      expect(empty.encoding, isNot(equals(absent.encoding)));
    });
  });

  // The querier family: two exports over one shared C body
  // (`_zd_fill_querier_get_options`), and two separate Dart marshalling sites.
  group('Encoding send fidelity — querier family (TCP 19557)', () {
    late Session getter;
    late Session host;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19557"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      host = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19557"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      host.close();
    });

    /// Declares our queryable on [key], issues one querier query carrying
    /// [encoding], and returns the query as the queryable saw it.
    Future<Query> viaQuerier(
      String key, {
      required Encoding encoding,
      bool pull = false,
      Querier? reuse,
    }) async {
      final queryable = host.declareQueryable(key);
      addTearDown(queryable.close);

      final querier = reuse ?? getter.declareQuerier(key);
      if (reuse == null) addTearDown(querier.close);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final first = queryable.stream.first;
      if (pull) {
        final replies = querier.pullGet(
          kind: ChannelKind.fifo,
          capacity: 4,
          payload: ZBytes.fromString('q'),
          encoding: encoding,
        );
        addTearDown(replies.dispose);
      } else {
        unawaited(
          querier
              .get(payload: ZBytes.fromString('q'), encoding: encoding)
              .drain<void>(),
        );
      }
      final received = await first.timeout(const Duration(seconds: 10));
      addTearDown(received.dispose);
      return received;
    }

    test('an interior-NUL encoding survives Querier.get', () async {
      final q = await viaQuerier(
        'zenoh/dart/s10/querier/nul',
        encoding: Encoding(subjectMime),
      );

      expect(q.encoding, equals(subjectMime));
      expect(q.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test('the same through Querier.pullGet', () async {
      final q = await viaQuerier(
        'zenoh/dart/s10/querier/nul-pull',
        encoding: Encoding(subjectMime),
        pull: true,
      );

      expect(q.encoding, equals(subjectMime));
    });

    test('an interior-NUL schema survives both entry points', () async {
      final encoding = Encoding.textPlain.withSchema(nulSchema);

      final viaGet = await viaQuerier(
        'zenoh/dart/s10/querier/schema',
        encoding: encoding,
      );
      final viaPull = await viaQuerier(
        'zenoh/dart/s10/querier/schema-pull',
        encoding: encoding,
        pull: true,
      );

      expect(viaGet.encoding, equals('text/plain;$nulSchema'));
      expect(viaPull.encoding, equals('text/plain;$nulSchema'));
    });

    test('the NUL-free control on each entry point in the same run', () async {
      final viaGet = await viaQuerier(
        'zenoh/dart/s10/querier/ctl',
        encoding: const Encoding(controlMime),
      );
      final viaPull = await viaQuerier(
        'zenoh/dart/s10/querier/ctl-pull',
        encoding: const Encoding(controlMime),
        pull: true,
      );

      expect(viaGet.encoding, equals(controlMime));
      expect(viaPull.encoding, equals(controlMime));
    });

    // Edge case.

    // A querier fixes target/consolidation/timeout at DECLARATION and has no
    // encoding channel of its own — the encoding is per-query. Two gets on ONE
    // querier must therefore carry their own encodings, whole: if declaration
    // state leaked into the per-query channel, or if a truncating carrier
    // collapsed them, the two would be indistinguishable. Both carry an
    // interior NUL so a truncation could not hide.
    test(
      "a querier's per-query encoding is independent of its declaration",
      () async {
        final querier = getter.declareQuerier(
          'zenoh/dart/s10/querier/indep',
          target: QueryTarget.all,
          consolidation: ConsolidationMode.none,
          timeout: const Duration(seconds: 3),
        );
        addTearDown(querier.close);

        final other = 'text/other${nul}TAIL-XYZ';
        final first = await viaQuerier(
          'zenoh/dart/s10/querier/indep',
          encoding: Encoding(subjectMime),
          reuse: querier,
        );
        final second = await viaQuerier(
          'zenoh/dart/s10/querier/indep',
          encoding: Encoding(other),
          reuse: querier,
        );

        expect(first.encoding, equals(subjectMime));
        expect(second.encoding, equals(other));
        expect(first.encoding, isNot(equals(second.encoding)));
      },
    );
  });

  // The reply family. Distinct from every other send site in one respect: the
  // payload is ALREADY MOVED when the encoding is built, so the encoding-error
  // path is a POST-move path that must drop what it moved. `markConsumed` is
  // therefore unconditional on the Dart side, and must stay that way.
  group('Encoding send fidelity — reply family (TCP 19558)', () {
    late Session replier;
    late Session getter;

    setUpAll(() async {
      final listenConfig = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19558"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      replier = await Session.open(config: listenConfig);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final connectConfig = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19558"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      getter = await Session.open(config: connectConfig);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      getter.close();
      replier.close();
    });

    /// Declares a queryable that answers on [arm] with [encoding], issues one
    /// get against it, and returns the single reply.
    Future<Reply> reply(
      String key,
      String arm, {
      Encoding? encoding,
      bool del = false,
    }) async {
      final queryable = replier.declareQueryable(key);
      addTearDown(queryable.close);

      final sub = queryable.stream.listen((q) {
        if (del) {
          q
            ..replyDel(key)
            ..dispose();
        } else if (arm == 'err') {
          q
            ..replyErrBytes(ZBytes.fromString('err'), encoding: encoding)
            ..dispose();
        } else {
          q
            ..replyBytes(key, ZBytes.fromString('ok'), encoding: encoding)
            ..dispose();
        }
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final replies = await getter
          .get(key, timeout: const Duration(seconds: 3))
          .toList()
          .timeout(const Duration(seconds: 10));
      expect(replies, hasLength(1), reason: 'expected exactly one reply');
      return replies.single;
    }

    test('an interior-NUL encoding survives an ok reply', () async {
      final r = await reply(
        'zenoh/dart/s10/reply/ok-nul',
        'ok',
        encoding: Encoding(subjectMime),
      );

      expect(r.isOk, isTrue);
      expect(r.ok.encoding, equals(subjectMime));
      expect(r.ok.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test('an interior-NUL encoding survives an error reply', () async {
      final r = await reply(
        'zenoh/dart/s10/reply/err-nul',
        'err',
        encoding: Encoding(subjectMime),
      );

      expect(r.isOk, isFalse);
      expect(r.error.encoding, equals(subjectMime));
      expect(r.error.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test('an interior-NUL schema survives both arms', () async {
      final encoding = Encoding.textPlain.withSchema(nulSchema);

      final ok = await reply(
        'zenoh/dart/s10/reply/ok-schema',
        'ok',
        encoding: encoding,
      );
      final err = await reply(
        'zenoh/dart/s10/reply/err-schema',
        'err',
        encoding: encoding,
      );

      expect(ok.ok.encoding, equals('text/plain;$nulSchema'));
      expect(err.error.encoding, equals('text/plain;$nulSchema'));
    });

    test('the NUL-free control on each arm in the same run', () async {
      final ok = await reply(
        'zenoh/dart/s10/reply/ok-ctl',
        'ok',
        encoding: const Encoding(controlMime),
      );
      final err = await reply(
        'zenoh/dart/s10/reply/err-ctl',
        'err',
        encoding: const Encoding(controlMime),
      );

      expect(ok.ok.encoding, equals(controlMime));
      expect(err.error.encoding, equals(controlMime));
    });

    // Edge cases.

    test('replyDel still carries no encoding channel', () async {
      final r = await reply('zenoh/dart/s10/reply/del', 'ok', del: true);

      // canon gives the delete arm no encoding option at all; the carriage
      // change must not leak one onto it. The kind is what identifies it.
      expect(r.isOk, isTrue);
      expect(r.ok.kind, equals(SampleKind.delete));
      expect(r.ok.payloadBytes, isEmpty);
    });
  });

  // The advanced publisher: the one send export inside the unstable guard, so
  // the change must be verified ABSENT from the stable door as well as correct
  // on the unstable one — a two-variant property.
  //
  // ⚠️ GATE ORDER IS LOAD-BEARING and follows the established in-tree shape:
  // the group gate ENCLOSES everything, so on the stable matrix leg the whole
  // group is a designed skip with its reason stated, and INSIDE the unstable
  // leg nothing skips at all.
  group(
    'Encoding send fidelity — advanced publisher (TCP 19559)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session sender;
      late Session receiver;

      setUpAll(() async {
        final listenConfig = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19559"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        sender = await Session.open(config: listenConfig);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final connectConfig = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19559"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        receiver = await Session.open(config: connectConfig);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        receiver.close();
        sender.close();
      });

      /// Publishes once through an AdvancedPublisher and returns the sample an
      /// AdvancedSubscriber received.
      Future<Sample> viaAdvanced(
        String key,
        Encoding encoding, {
        bool useBytes = false,
      }) async {
        final sub = receiver.declareAdvancedSubscriber(key);
        addTearDown(sub.close);

        final pub = sender.declareAdvancedPublisher(key);
        addTearDown(pub.close);

        await Future<void>.delayed(const Duration(milliseconds: 800));

        final first = sub.stream.first;
        if (useBytes) {
          pub.putBytes(ZBytes.fromString('payload'), encoding: encoding);
        } else {
          pub.put('payload', encoding: encoding);
        }
        return first.timeout(const Duration(seconds: 10));
      }

      test('an interior-NUL encoding survives AdvancedPublisher.put', () async {
        final sample = await viaAdvanced(
          'zenoh/dart/s10/adv/nul',
          Encoding(subjectMime),
        );

        expect(sample.encoding, equals(subjectMime));
        expect(sample.encodingBytes, equals(utf8.encode(subjectMime)));
      });

      test('the same through AdvancedPublisher.putBytes', () async {
        // Both public entry points funnel through the single marshalling site,
        // and both are exercised rather than one standing in for the other.
        final sample = await viaAdvanced(
          'zenoh/dart/s10/adv/nul-bytes',
          Encoding(subjectMime),
          useBytes: true,
        );

        expect(sample.encoding, equals(subjectMime));
      });

      test('an interior-NUL schema survives', () async {
        final sample = await viaAdvanced(
          'zenoh/dart/s10/adv/schema',
          Encoding.textPlain.withSchema(nulSchema),
        );

        expect(sample.encoding, equals('text/plain;$nulSchema'));
        expect(sample.encoding!.codeUnitAt(12), equals(0));
      });

      test('the NUL-free control in the same run', () async {
        final sample = await viaAdvanced(
          'zenoh/dart/s10/adv/ctl',
          const Encoding(controlMime),
        );

        expect(sample.encoding, equals(controlMime));
      });
    },
  );
}
