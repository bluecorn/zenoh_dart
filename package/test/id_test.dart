import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('ZenohId', () {
    test('stores 16 bytes', () {
      final input = Uint8List.fromList([
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
      ]);
      final zid = ZenohId(input);

      expect(zid.bytes.length, equals(16));
      expect(zid.bytes, equals(input));
    });

    test('toHexString produces hex representation', () {
      final input = Uint8List.fromList([
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      final zid = ZenohId(input);

      final hex = zid.toHexString();
      expect(hex, isNotEmpty);
      expect(zid.toString(), equals(hex));
    });

    test('equality and hashCode', () {
      final bytes1 = Uint8List.fromList([
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
      ]);
      final bytes2 = Uint8List.fromList([
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
      ]);
      final bytes3 = Uint8List.fromList([
        16,
        15,
        14,
        13,
        12,
        11,
        10,
        9,
        8,
        7,
        6,
        5,
        4,
        3,
        2,
        1,
      ]);

      final zid1 = ZenohId(bytes1);
      final zid2 = ZenohId(bytes2);
      final zid3 = ZenohId(bytes3);

      expect(zid1, equals(zid2));
      expect(zid1.hashCode, equals(zid2.hashCode));
      expect(zid1, isNot(equals(zid3)));
    });

    test('all-zero bytes produces valid hex string', () {
      final input = Uint8List(16); // all zeros
      final zid = ZenohId(input);

      final hex = zid.toHexString();
      expect(hex, isNotEmpty);
      // Still satisfied under the canon-form contract, but for a different
      // reason than when this was written: the rendering is the single digit
      // '0', not thirty-two of them. Superseded in strength by 'the all-zero
      // id renders as a single zero' in the rendering group below; kept
      // because it costs nothing and guards the isNotEmpty half.
      expect(hex, matches(RegExp(r'^[0]+$')));
    });

    // The exact-hex pin -- RE-PINNED to the canon-form contract.
    //
    // RED-ON-FIX SITE, repaired rather than deleted. It used to assert the
    // storage-order rendering (`000f107f80ff0102030405060708090a`) plus a
    // length of 32. Both were assertions about the DEFECT: canon renders the
    // byte-pair reverse with leading zeros stripped per digit, so this
    // vector's true rendering is 31 digits, not 32.
    //
    // The vector is kept exactly as it was and still discriminates every
    // failure mode it was built for, now against the right expected value:
    //   0x0a leading (bytes[15]) -> emits 'a'; a missing strip would give '0a'
    //   0x0f, 0x09, 0x08 ...     -> a one-digit pad would drop their zeros
    //   0xff, 0x80               -> an upper-case radix conversion emits 'FF'
    //   the whole order          -> a storage-order rendering reverses visibly
    //
    // The length line is NOT re-pinned to 31. A width assertion is exactly
    // what made the interop corpus carry a 1-in-16 flake for weeks; the
    // contract is asserted instead, in the rendering group below.
    test('toHexString pins the exact hex for a known byte vector', () {
      final input = Uint8List.fromList([
        0x00, 0x0f, 0x10, 0x7f, //
        0x80, 0xff, 0x01, 0x02, //
        0x03, 0x04, 0x05, 0x06, //
        0x07, 0x08, 0x09, 0x0a, //
      ]);
      final zid = ZenohId(input);

      expect(zid.toHexString(), equals('a090807060504030201ff807f100f00'));
      expect(zid.toString(), equals(zid.toHexString()));
    });

    // The wrong-length pin -- REWRITTEN.
    //
    // The finding this cell pinned is now FIXED. It used to assert today's
    // broken behaviour: the constructor performed no length validation, so a
    // short array was copied verbatim, toHexString returned a short string,
    // and `operator ==` (a hard-coded 0..15 loop) read past the end and threw
    // RangeError instead of returning false.
    //
    // The contract now: a ZenohId is exactly 16 bytes, enforced at
    // construction. The overrun this cell described is therefore no longer
    // repairable-or-broken -- it is UNREPRESENTABLE, because the short
    // instance whose comparison overran cannot be built in the first place.
    test(
      'a non-16-byte ZenohId is refused, so the overrun is unrepresentable',
      () {
        final shortBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

        expect(() => ZenohId(shortBytes), throwsA(isA<ArgumentError>()));

        // ...and there is no instance to compare, which is the whole point:
        // the old `expect(() => a == b, throwsA(isA<RangeError>()))` cannot
        // even be written now, because `a` and `b` never come into existence.
      },
    );

    test('a short byte array is refused at construction', () {
      final eightBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      expect(
        () => ZenohId(eightBytes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('16 bytes'),
          ),
        ),
        reason: "canon's z_id_t is a fixed uint8_t[16]; 8 is not expressible",
      );

      // "No instance exists" is observed by the matcher itself rather than by
      // a second cell: `throwsA` invokes the closure and, when it returns
      // instead of throwing, reports the RETURNED VALUE as the failure --
      // which is literally what this cell printed before the guard landed
      // ("returned ZenohId:<0102030405060708>"). A try/catch rebinding the
      // result would only restate that, and very_good_analysis rejects
      // catching an Error subtype (avoid_catching_errors) besides.
    });

    test('a long byte array is refused at construction', () {
      final seventeenBytes = Uint8List(17);

      expect(
        () => ZenohId(seventeenBytes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('16 bytes'),
          ),
        ),
      );

      // This is what makes the measured long-id break UNREPRESENTABLE rather
      // than repaired: two 17-byte ids agreeing on their first sixteen bytes
      // used to compare EQUAL (the 0..15 loop never looked at byte 16) while
      // hashCode -- which walks the whole array -- disagreed. That pair
      // silently corrupts any Set or Map keyed on ZenohId. Refusing the
      // construction removes the pair from the domain instead of teaching
      // `operator ==` to cope with it.
      final a = Uint8List(17)..[16] = 1;
      final b = Uint8List(17)..[16] = 2;
      expect(() => ZenohId(a), throwsA(isA<ArgumentError>()));
      expect(() => ZenohId(b), throwsA(isA<ArgumentError>()));
    });

    test('the guard is a real throw, not an assert', () {
      // An `assert` vanishes in a release build, so a guard written that way
      // would protect only the test run -- and the whole point of this
      // invariant is that `operator ==`'s bounded 0..15 loop stays safe in
      // production too. Two instruments, matching the shipped precedent in
      // shm_alloc_alignment_test.dart, because neither alone is decisive: the
      // thrown type discriminates at run time (under `dart test` asserts are
      // ENABLED, so an `assert` would raise AssertionError, which
      // isA<ArgumentError>() rejects), and the source check catches a future
      // edit that swaps them back, which the type check would not see.
      //
      // NEITHER INSTRUMENT OBSERVES RELEASE MODE. This suite runs with asserts
      // on; nothing here executes an AOT release build. The type check is a
      // PROXY for release-mode survival, not a measurement of it -- "the guard
      // holds in release mode" is a statement of intent that these two cells
      // approximate.
      final eightBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(() => ZenohId(eightBytes), throwsArgumentError);
      expect(
        () => ZenohId(eightBytes),
        isNot(throwsA(isA<AssertionError>())),
      );

      final source = File('lib/src/id.dart').readAsStringSync();
      expect(source, isNot(contains('assert(')));
    });

    test('equality is total and consistent with hashCode', () {
      final base = Uint8List.fromList([
        1, 2, 3, 4, 5, 6, 7, 8, //
        9, 10, 11, 12, 13, 14, 15, 16, //
      ]);
      final sameAsBase = Uint8List.fromList(base);
      final lastByteDiffers = Uint8List.fromList(base)..[15] = 99;

      final a = ZenohId(base);
      final b = ZenohId(sameAsBase);
      final c = ZenohId(lastByteDiffers);

      // Equal ids: equal, same hashCode, collapse in a Set.
      expect(a, equals(b));
      expect(b, equals(a));
      expect(a.hashCode, equals(b.hashCode));
      expect({a, b}, hasLength(1));

      // Unequal ids: unequal in BOTH directions, and no RangeError on any
      // path -- totality is what the invariant buys. `expect(..., isNot(...))`
      // would report a thrown RangeError as a failure, but state it directly
      // too so the diagnosis is unambiguous if it ever regresses.
      expect(() => a == c, returnsNormally);
      expect(() => c == a, returnsNormally);
      expect(a, isNot(equals(c)));
      expect(c, isNot(equals(a)));
      expect({a, c}, hasLength(2));

      // Reflexive, and the identity short-circuit is not the only reason.
      expect(a, equals(a));
      expect(a, equals(ZenohId(base)));
    });

    test('the all-zero id stays constructible', () {
      // Canon's stable API documents the all-zero id as its INVALID-SESSION
      // sentinel (zenoh_commons.h:3746-3753 -- the accessor returns a zeroed
      // z_id_t when the session is not valid). Rejecting it at construction
      // would make canon's own documented return value untranslatable, so the
      // 16-byte invariant is a LENGTH invariant only; it says nothing about
      // content.
      final zid = ZenohId(Uint8List(16));

      expect(zid.bytes.length, equals(16));
      expect(zid.bytes.every((b) => b == 0), isTrue);
      expect(zid, equals(ZenohId(Uint8List(16))));
    });

    // Slice 6 -- the exposed bytes must be genuinely unmodifiable.
    //
    // MEASURED BEFORE THIS CELL LANDED: `zid.bytes[0] = 0xEE` SUCCEEDED. The
    // field carried a `// unmodifiable copy` comment that was false on the
    // half that matters -- the constructor's defensive copy isolated the
    // CALLER'S SOURCE array (pinned by the next cell), but the field itself
    // was a plain writable Uint8List, so the write changed an @immutable
    // value's rendering AND its hashCode in place:
    //   mut : field mutation changed id: true (hashCode changed: true)
    //   mut : after field mutation     : ee0102030405060708090a0b0c0d0e0f
    // An id whose hashCode moves after it has been used as a Map/Set key is
    // unfindable in that collection.
    //
    // Both halves of this cell matter. The throw alone would not show the
    // value SURVIVED the attempt intact -- a mechanism that threw after
    // half-applying the write would pass a throw-only assertion.
    test(
      'mutating the exposed bytes throws and leaves the id unchanged',
      () {
        final zid = ZenohId(
          Uint8List.fromList([
            1, 2, 3, 4, 5, 6, 7, 8, //
            9, 10, 11, 12, 13, 14, 15, 16, //
          ]),
        );
        final partner = ZenohId(
          Uint8List.fromList([
            1, 2, 3, 4, 5, 6, 7, 8, //
            9, 10, 11, 12, 13, 14, 15, 16, //
          ]),
        );

        // Captured BEFORE the attempt -- comparing against values read after
        // it would compare the mutated id with itself and always pass.
        final hexBefore = zid.toHexString();
        final hashBefore = zid.hashCode;
        expect(zid, equals(partner));

        // Statement body, not `expect(() => zid.bytes[0] = 0xEE, ...)`: the
        // expression form yields the assignment's value and trips a lint.
        expect(() {
          zid.bytes[0] = 0xEE;
        }, throwsUnsupportedError);

        expect(zid.toHexString(), equals(hexBefore));
        expect(zid.hashCode, equals(hashBefore));
        expect(zid, equals(partner));
      },
    );

    // The defensive copy's half that ALREADY worked -- pinned rather than
    // assumed, so a future edit that stores the caller's array directly
    // (instead of copying it) is caught here and not in the field.
    test(
      'mutating the source array after construction does not reach the id',
      () {
        final source = Uint8List.fromList([
          1, 2, 3, 4, 5, 6, 7, 8, //
          9, 10, 11, 12, 13, 14, 15, 16, //
        ]);
        final zid = ZenohId(source);

        final hexAtConstruction = zid.toHexString();
        final hashAtConstruction = zid.hashCode;

        source[0] = 0xEE;
        source[15] = 0xEE;

        expect(zid.toHexString(), equals(hexAtConstruction));
        expect(zid.hashCode, equals(hashAtConstruction));
        expect(zid.bytes[0], equals(1));
        expect(zid.bytes[15], equals(16));
      },
    );

    // Unmodifiability constrains WRITES only. The bytes path is the fidelity
    // ground truth for an identifier, so every read shape a caller might use
    // has to keep working -- a mechanism that satisfied the two cells above by
    // narrowing the type or copying on each access would break one of these.
    test('the unmodifiable bytes stay a usable Uint8List for readers', () {
      final input = Uint8List.fromList([
        0x00, 0x0f, 0x10, 0x7f, //
        0x80, 0xff, 0x01, 0x02, //
        0x03, 0x04, 0x05, 0x06, //
        0x07, 0x08, 0x09, 0x0a, //
      ]);
      final zid = ZenohId(input);

      // Still a Uint8List, still 16 wide.
      expect(zid.bytes, isA<Uint8List>());
      expect(zid.bytes.length, equals(16));

      // Indexed, including the boundaries.
      expect(zid.bytes[0], equals(0x00));
      expect(zid.bytes[5], equals(0xff));
      expect(zid.bytes[15], equals(0x0a));

      // Iterated, in storage order.
      var seen = 0;
      for (final byte in zid.bytes) {
        expect(byte, equals(input[seen]));
        seen++;
      }
      expect(seen, equals(16));

      // Copied out -- the escape hatch for a caller that genuinely needs a
      // writable array of its own.
      final copy = Uint8List.fromList(zid.bytes);
      expect(copy, equals(input));
      copy[0] = 0xEE;
      expect(zid.bytes[0], equals(0x00), reason: 'the copy is independent');
    });
  });

  // =========================================================================
  // The canon-form rendering.
  //
  // `toHexString()` renders exactly what canon's `z_id_to_string` renders for
  // the same sixteen bytes: digit order `bytes[15]` -> `bytes[0]` (the
  // byte-pair reverse of storage order), leading zeros stripped PER HEX DIGIT
  // across byte boundaries, and the all-zero id as a single `'0'`.
  //
  // These are LITERAL pins, not oracle comparisons. The oracle lives in
  // id_rendering_oracle_test.dart and carries the live-draw leg; this file
  // deliberately imports neither `dart:ffi` nor the bindings, which is the
  // structural demonstration that an id renders without the native library.
  //
  // Every literal below was measured through the shipped stack against canon's
  // own renderer, and re-derived arithmetically before being written here.
  // =========================================================================
  group('ZenohId rendering (canon form)', () {
    // The base fixture: every position distinct, so a reordering is visible.
    final f1 = Uint8List.fromList([
      0x11, 0x22, 0x33, 0x44, //
      0x55, 0x66, 0x77, 0x88, //
      0x99, 0xaa, 0xbb, 0xcc, //
      0xdd, 0xee, 0xff, 0x10, //
    ]);

    test('the exact canon rendering for the distinct-per-position fixture', () {
      expect(
        ZenohId(f1).toHexString(),
        equals('10ffeeddccbbaa998877665544332211'),
        reason:
            'digit order is bytes[15] -> bytes[0]; before this seed this '
            'returned the byte-pair reverse of it',
      );
    });

    // ⚠️ THE PADDING DISCRIMINATOR, and it is the only deterministic one in
    // this family besides the migrated pair below.
    //
    // The likeliest way to get the algorithm wrong is `byte.toRadixString(16)`
    // WITHOUT `padLeft(2, '0')` -- the same omission the old exact-hex pin was
    // built to catch. Measured: that implementation passes the F1, F3, F4 and
    // all-zero cells IDENTICALLY. Only this cell and the migrated pair catch
    // it, so do not "simplify" the family by dropping either: one whole
    // failure mode rests on them.
    //
    // The live-draw leg in the oracle file is not the safety net either -- it
    // catches this at 1 - (15/16)^15, about 62% per run, which is a coin flip
    // of exactly the kind this corpus has been bitten by twice on this surface.
    test(
      'a low-nibble byte in an INTERIOR position still emits two digits',
      () {
        final f2 = Uint8List.fromList(f1)..[0] = 0x0a;
        expect(
          ZenohId(f2).toHexString(),
          equals('10ffeeddccbbaa99887766554433220a'),
          reason:
              'the trailing `0a` is PADDED because it is not the leading '
              'byte -- stripping is a leading-DIGIT rule, not a per-byte '
              'formatting rule',
        );
        expect(ZenohId(f2).toHexString(), hasLength(32));
      },
    );

    test('a low-nibble most-significant byte strips one digit', () {
      final f3 = Uint8List.fromList(f1)..[15] = 0x0a;
      final hex = ZenohId(f3).toHexString();
      expect(hex, equals('affeeddccbbaa998877665544332211'));
      expect(hex, hasLength(31), reason: 'stripping is per hex digit');
    });

    test('a zero most-significant byte strips two digits', () {
      final f4 = Uint8List.fromList(f1)..[15] = 0x00;
      final hex = ZenohId(f4).toHexString();
      expect(hex, equals('ffeeddccbbaa998877665544332211'));
      expect(
        hex,
        hasLength(30),
        reason:
            'the stripping crosses the byte boundary, so it is not a '
            'per-byte rule',
      );
    });

    test('the all-zero id renders as a single zero', () {
      expect(
        ZenohId(Uint8List(16)).toHexString(),
        equals('0'),
        reason: "canon's rendering of its own invalid-session sentinel",
      );
    });

    // MIGRATED from the interop corpus, not retired.
    //
    // These two strings are a REAL cross-implementation observation of one
    // session (2026-07-31): canon printed the 31-digit form, our pre-seed
    // renderer printed the 32-digit storage-order form. They lived in
    // test/interop/session_info_interop.dart as a control on the normalizer
    // that this seed retires. Under the new contract the same measured pair
    // becomes a deterministic fixture for OUR renderer -- and moving it here
    // converts a site the default suite could never see into one it runs on
    // every invocation.
    //
    // It also carries the padding discriminator (an interior `03`), which is
    // why it must not be dropped either.
    test(
      'a real cross-implementation pair, migrated from the interop control',
      () {
        final measured = Uint8List.fromList([
          0x97, 0xde, 0x82, 0xdb, //
          0xf3, 0x51, 0x94, 0x66, //
          0x8e, 0x4e, 0x66, 0x03, //
          0x91, 0x90, 0x7e, 0x0e, //
        ]);
        expect(
          ZenohId(measured).toHexString(),
          equals('e7e909103664e8e669451f3db82de97'),
          reason: 'a real-world 31-digit case beside the synthetic ones',
        );
      },
    );

    // Canon's own valid-id contract, asserted as a CONTRACT rather than as a
    // width: `^[1-9a-f][0-9a-f]{0,31}$`. Zenoh refuses a config id with a
    // leading zero outright ("Leading 0s are not valid"), so a rendering that
    // emitted one would not round-trip through canon at all.
    test('toString delegates, and no rendering starts with a zero', () {
      final canonValidId = RegExp(r'^[1-9a-f][0-9a-f]{0,31}$');
      final fixtures = <String, Uint8List>{
        'F1': f1,
        'F2': Uint8List.fromList(f1)..[0] = 0x0a,
        'F3': Uint8List.fromList(f1)..[15] = 0x0a,
        'F4': Uint8List.fromList(f1)..[15] = 0x00,
        'migrated': Uint8List.fromList([
          0x97, 0xde, 0x82, 0xdb, //
          0xf3, 0x51, 0x94, 0x66, //
          0x8e, 0x4e, 0x66, 0x03, //
          0x91, 0x90, 0x7e, 0x0e, //
        ]),
      };
      for (final entry in fixtures.entries) {
        final zid = ZenohId(entry.value);
        final hex = zid.toHexString();
        expect(zid.toString(), equals(hex), reason: entry.key);
        expect(hex, matches(canonValidId), reason: entry.key);
      }

      // The all-zero id is the documented exception: canon renders its own
      // invalid-session sentinel as '0', which the valid-id pattern rejects
      // BY DESIGN.
      final zero = ZenohId(Uint8List(16));
      expect(zero.toString(), equals('0'));
      expect(zero.toHexString(), isNot(matches(canonValidId)));
    });

    // Edge: the rendering is a DERIVED VIEW and the bytes path never
    // transforms. This is the half a rendering fix could plausibly break, and
    // it is the fidelity ground truth for the whole surface.
    test('the rendering change does not touch the bytes path', () {
      final fixtures = <Uint8List>[
        f1,
        Uint8List.fromList(f1)..[0] = 0x0a,
        Uint8List.fromList(f1)..[15] = 0x00,
        Uint8List(16),
      ];
      for (final input in fixtures) {
        final zid = ZenohId(input);
        expect(
          zid.toHexString(),
          isNotEmpty,
          reason: 'the rendering must actually have run before bytes is read',
        );
        expect(
          zid.bytes,
          equals(input),
          reason:
              'bytes must stay raw storage order, byte-exact, after any '
              'number of renderings',
        );
      }
    });
  });
}
