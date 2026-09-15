import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

void main() {
  group('ZBytes round-trip', () {
    test('from string round-trip', () {
      // Given: a string "hello"
      // When: ZBytes.fromString("hello") is created and .toStr() is called
      final zbytes = ZBytes.fromString('hello');
      final result = zbytes.toStr();

      // Then: the returned string equals "hello"
      expect(result, equals('hello'));
      zbytes.dispose();
    });

    test('from Uint8List round-trip', () {
      // Given: a Uint8List containing [104, 101, 108, 108, 111] (ASCII "hello")
      final data = Uint8List.fromList([104, 101, 108, 108, 111]);

      // When: ZBytes.fromUint8List(bytes) is created and .toStr() is called
      final zbytes = ZBytes.fromUint8List(data);
      final result = zbytes.toStr();

      // Then: the returned string equals "hello"
      expect(result, equals('hello'));
      zbytes.dispose();
    });

    test('dispose releases resources', () {
      // Given: a ZBytes object
      final zbytes = ZBytes.fromString('test');

      // When: zbytes.dispose() is called
      // Then: no exception is thrown
      expect(zbytes.dispose, returnsNormally);
    });

    test('dispose is idempotent (double-drop safe)', () {
      // Given: a ZBytes that has been disposed
      final zbytes = ZBytes.fromString('test')..dispose();

      // When: zbytes.dispose() is called again
      // Then: no exception is thrown
      expect(zbytes.dispose, returnsNormally);
    });

    test('from empty string', () {
      // Given: an empty string ""
      // When: ZBytes.fromString("") is created and .toStr() is called
      final zbytes = ZBytes.fromString('');
      final result = zbytes.toStr();

      // Then: the returned string equals ""
      expect(result, equals(''));
      zbytes.dispose();
    });

    test('from empty Uint8List', () {
      // Given: an empty Uint8List
      // When: ZBytes.fromUint8List(Uint8List(0)) is created and .toStr() is
      // called
      final zbytes = ZBytes.fromUint8List(Uint8List(0));
      final result = zbytes.toStr();

      // Then: the returned string equals ""
      expect(result, equals(''));
      zbytes.dispose();
    });

    test('from large payload', () {
      // Given: a string of 10,000 "a" characters
      final largeString = 'a' * 10000;

      // When: ZBytes.fromString(largeString) is created and .toStr() is called
      final zbytes = ZBytes.fromString(largeString);
      final result = zbytes.toStr();

      // Then: the returned string equals the original
      expect(result, equals(largeString));
      zbytes.dispose();
    });

    test('toStr after dispose throws StateError', () {
      final bytes = ZBytes.fromString('hello')..dispose();
      expect(bytes.toStr, throwsStateError);
    });

    test('toStr can be called multiple times', () {
      final bytes = ZBytes.fromString('reuse me');
      expect(bytes.toStr(), equals('reuse me'));
      expect(bytes.toStr(), equals('reuse me'));
      expect(bytes.toStr(), equals('reuse me'));
      bytes.dispose();
    });
  });

  group('ZBytes.toStr() lenient UTF-8 (A1)', () {
    // Reproduce-first RED — CURRENT failure mode (observed against pre-fix
    // code, 2026-07-10): on invalid UTF-8, toStr() routes through the
    // UTF-8-*validating* shim extractor `zd_bytes_to_string`
    // (z_bytes_to_string), which returns a non-zero rc, so toStr() THROWS
    // `ZenohException` (code -1) — it does NOT return empty and does NOT
    // lossily corrupt. The fix routes toStr() through the byte-faithful
    // reader (zd_bytes_to_buf, as toBytes() already does) +
    // utf8.decode(allowMalformed: true), so invalid sequences become U+FFFD
    // instead of throwing.

    test('invalid UTF-8 decodes leniently to U+FFFD (no throw)', () {
      // Given: a ZBytes built from an invalid UTF-8 sequence [0xFF, 0xFE]
      final data = Uint8List.fromList([0xFF, 0xFE]);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toStr() is called
      // Then: it does not throw and yields the U+FFFD replacement character
      final result = zbytes.toStr();
      expect(result, contains('�'));

      // And: toBytes() still returns the original bytes byte-exact
      expect(zbytes.toBytes(), equals(data));
      zbytes.dispose();
    });

    test('valid multibyte UTF-8 round-trips unchanged', () {
      // Given: a ZBytes built from a valid multibyte UTF-8 string
      const original = 'héllo→';
      final zbytes = ZBytes.fromUint8List(
        Uint8List.fromList(utf8.encode(original)),
      );

      // When: toStr() is called
      // Then: it returns the exact original string
      expect(zbytes.toStr(), equals(original));
      zbytes.dispose();
    });

    test('empty payload returns "" without throwing', () {
      // Given: an empty ZBytes
      final zbytes = ZBytes.fromUint8List(Uint8List(0));

      // When: toStr() is called
      // Then: it returns "" without throwing
      expect(zbytes.toStr(), equals(''));
      zbytes.dispose();
    });

    test('lone surrogate bytes decode leniently (not throw, not empty)', () {
      // Given: a ZBytes whose bytes are the UTF-8-invalid encoding of an
      // unpaired surrogate region [0xED, 0xA0, 0x80]
      final data = Uint8List.fromList([0xED, 0xA0, 0x80]);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toStr() is called
      // Then: it returns a lenient U+FFFD result (not a throw, not empty)
      final result = zbytes.toStr();
      expect(result, contains('�'));
      expect(result, isNotEmpty);

      // And: toBytes() remains byte-exact
      expect(zbytes.toBytes(), equals(data));
      zbytes.dispose();
    });
  });

  group('ZBytes.fromString() length-safe (A2a)', () {
    // Reproduce-first RED — CURRENT failure mode (observed against pre-fix
    // code, 2026-07-10): fromString copies via the NUL-terminated
    // `zd_bytes_copy_from_str` (value.toNativeUtf8()) path, so an embedded NUL
    // TRUNCATES the payload. `ZBytes.fromString("a\u0000b").toBytes()` today
    // returns exactly [0x61] (len 1) — the "b" past the NUL is dropped. The fix
    // encodes the string to UTF-8 bytes and copies via the length-based
    // `zd_bytes_copy_from_buf` (as fromUint8List already does), preserving the
    // full byte content.
    //
    // The embedded-NUL string is built via String.fromCharCodes to keep a raw
    // NUL byte out of this source file.
    final embeddedNul = String.fromCharCodes([0x61, 0x00, 0x62]);

    test('embedded NUL is preserved (not truncated at the NUL)', () {
      // Given: a Dart string containing an embedded NUL, "a\u0000b"
      final zbytes = ZBytes.fromString(embeddedNul);

      // When: toBytes() is read
      final result = zbytes.toBytes();

      // Then: it returns exactly the 3 bytes [0x61, 0x00, 0x62]
      // (not truncated to [0x61] as the NUL-terminated copy would).
      expect(result, equals(Uint8List.fromList([0x61, 0x00, 0x62])));
      zbytes.dispose();
    });

    test('multibyte string round-trips byte-exact', () {
      // Given: a multibyte UTF-8 string
      const original = 'héllo';
      final zbytes = ZBytes.fromString(original);

      // When: toBytes() is read
      final result = zbytes.toBytes();

      // Then: it equals utf8.encode of that string byte-exact
      expect(result, equals(Uint8List.fromList(utf8.encode(original))));
      zbytes.dispose();
    });

    test('empty string yields an empty Uint8List without throwing', () {
      // Given: an empty string ""
      final zbytes = ZBytes.fromString('');

      // When: toBytes() is read
      final result = zbytes.toBytes();

      // Then: it returns an empty Uint8List without throwing
      expect(result, equals(Uint8List(0)));
      expect(result.length, equals(0));
      zbytes.dispose();
    });
  });

  group('ZBytes.toBytes()', () {
    test('round-trip from string', () {
      // Given: ZBytes created from string 'hello'
      final zbytes = ZBytes.fromString('hello');

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: returns UTF-8 bytes [104, 101, 108, 108, 111]
      expect(result, equals(Uint8List.fromList([104, 101, 108, 108, 111])));
      zbytes.dispose();
    });

    test('round-trip from Uint8List', () {
      // Given: ZBytes created from Uint8List [1, 2, 3, 4, 5]
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: returns identical bytes
      expect(result, equals(data));
      zbytes.dispose();
    });

    test('empty bytes returns empty Uint8List', () {
      // Given: ZBytes created from empty string
      final zbytes = ZBytes.fromString('');

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: returns empty Uint8List
      expect(result, equals(Uint8List(0)));
      expect(result.length, equals(0));
      zbytes.dispose();
    });

    test('can be called multiple times (non-destructive read)', () {
      // Given: ZBytes created from 'reuse'
      final zbytes = ZBytes.fromString('reuse');

      // When: toBytes() is called three times
      final r1 = zbytes.toBytes();
      final r2 = zbytes.toBytes();
      final r3 = zbytes.toBytes();

      // Then: all results are identical
      expect(r1, equals(Uint8List.fromList([114, 101, 117, 115, 101])));
      expect(r2, equals(r1));
      expect(r3, equals(r1));
      zbytes.dispose();
    });

    test('on disposed ZBytes throws StateError', () {
      // Given: a disposed ZBytes
      final zbytes = ZBytes.fromString('test')..dispose();

      // When/Then: toBytes() throws StateError
      expect(zbytes.toBytes, throwsStateError);
    });

    test('on consumed ZBytes throws StateError', () {
      // Given: a consumed ZBytes
      final zbytes = ZBytes.fromString('test')..markConsumed();

      // When/Then: toBytes() throws StateError
      expect(zbytes.toBytes, throwsStateError);
    });

    test('large payload (10KB)', () {
      // Given: ZBytes created from 10KB of zeros
      final data = Uint8List(10240);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: returns identical 10KB buffer
      expect(result.length, equals(10240));
      expect(result, equals(data));
      zbytes.dispose();
    });

    test('returns exactly the stored bytes (no garbage tail)', () {
      // Given: a ZBytes built from invalid-UTF-8 binary
      // [0x00,0xFF,0xFE,0x80,0x41]
      final data = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: result == exactly the stored bytes (rc-checked reader; no
      // trailing uninitialized bytes from a short read).
      expect(
        result,
        equals(Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41])),
      );
      expect(result.length, equals(5));
      zbytes.dispose();
    });

    test('1 MiB payload round-trips byte-identically', () {
      // Census gap G4: the largest fixture driven anywhere in this corpus was
      // the 10 KB cell above, so the reader's size handling had never been
      // exercised past that. 1 MiB is still far below the int32 ceiling the
      // census flags on this path -- the claim here is identity at scale, not
      // the ceiling.
      //
      // Given: 1 MiB whose bytes VARY (i & 0xFF) rather than being zeros, so
      // a short read that zero-filled its tail would be visible; a zero-filled
      // fixture cannot tell identity from that failure mode.
      final data = Uint8List(1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i & 0xFF;
      }
      final zbytes = ZBytes.fromUint8List(data);

      // When: toBytes() reads it back
      final result = zbytes.toBytes();

      // Then: same length, same bytes, in order
      expect(result.length, equals(1024 * 1024));
      expect(result, equals(data));
      zbytes.dispose();
    });
  });

  // --- Slice 1 net: the marshalling form -------------------------------------
  //
  // `ZBytes.fromString` and `ZBytes.fromUint8List` copied their payload into
  // the native staging buffer BYTE AT A TIME, where the rest of this tree uses
  // `asTypedList(n).setAll(0, src)` (serializer.dart, native_string.dart,
  // keyexpr.dart). The change is a copy-form substitution with no behavioural
  // delta on any non-empty input, so this group is a REGRESSION NET rather than
  // a RED: it was written before the change and must read identically after.
  //
  // The one genuine hazard it exists to pin is the EMPTY buffer. The byte loop
  // is vacuously safe at length 0; `asTypedList(0)` on a zero-length allocation
  // is not obviously so, which is why `native_string.dart` guards its own use
  // of the idiom. Both empty constructors are asserted here, on both entries.
  group('ZBytes marshalling form (slice 1 regression net)', () {
    test('an empty payload still constructs and reads back empty', () {
      // Given: the two empty inputs, one per constructor
      // When: each is marshalled
      final fromList = ZBytes.fromUint8List(Uint8List(0));
      final fromStr = ZBytes.fromString('');

      // Then: both construct without throwing and read back zero-length
      expect(fromList.toBytes(), equals(Uint8List(0)));
      expect(fromList.toBytes().length, equals(0));
      expect(fromStr.toBytes(), equals(Uint8List(0)));
      expect(fromStr.toBytes().length, equals(0));

      fromList.dispose();
      fromStr.dispose();
    });

    test('an interior NUL survives the marshalling', () {
      // Given: bytes [0x61, 0x00, 0x62] and the equivalent string. Interior
      // NUL is a standing member of this project's fidelity domain -- a
      // NUL-terminated copy would truncate at index 1 and still look correct
      // for the first byte.
      final data = Uint8List.fromList([0x61, 0x00, 0x62]);
      const str = 'a\u0000b';

      // When: each is marshalled and read back
      final fromList = ZBytes.fromUint8List(data);
      final fromStr = ZBytes.fromString(str);

      // Then: all three bytes come back, the NUL included, on both entries
      expect(fromList.toBytes(), equals(data));
      expect(fromList.toBytes().length, equals(3));
      expect(fromStr.toBytes(), equals(data));
      expect(fromStr.toBytes().length, equals(3));

      fromList.dispose();
      fromStr.dispose();
    });

    test('invalid UTF-8 survives byte-exact', () {
      // Given: five bytes that are not valid UTF-8 and include a NUL
      final data = Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01, 0x80]);

      // When: they are marshalled and read back
      final zbytes = ZBytes.fromUint8List(data);
      final result = zbytes.toBytes();

      // Then: byte-exact, and no replacement character was substituted
      expect(result, equals(data));
      expect(result.length, equals(5));
      expect(result.contains(0xEF), isFalse, reason: 'no U+FFFD lead byte');

      zbytes.dispose();
    });

    test('a large buffer marshals byte-exact', () {
      // Given: 1 MiB from a deterministic LCG with a recorded checksum. The
      // fill is deliberately NOT `i & 0xFF` (the pattern the neighbouring
      // toBytes() cell uses) so this exercises the bulk copy against a
      // different fixture rather than repeating that one.
      const size = 1024 * 1024;
      final data = Uint8List(size);
      var state = 0x2545F491;
      var checksum = 0;
      for (var i = 0; i < size; i++) {
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
        data[i] = (state >> 16) & 0xFF;
        checksum = (checksum * 31 + data[i]) & 0xFFFFFFFF;
      }

      // When: it is marshalled and read back
      final zbytes = ZBytes.fromUint8List(data);
      final result = zbytes.toBytes();

      // Then: same length, same bytes, same checksum
      expect(result.length, equals(size));
      expect(result, equals(data));
      var roundTrip = 0;
      for (var i = 0; i < size; i++) {
        roundTrip = (roundTrip * 31 + result[i]) & 0xFFFFFFFF;
      }
      expect(roundTrip, equals(checksum));

      zbytes.dispose();
    });

    test('the string constructor UTF-8 encode is unchanged', () {
      // Given: a string carrying a lone (unpaired) surrogate. Dart's
      // `utf8.encode` substitutes U+FFFD for it; that substitution belongs to
      // the ENCODE, which this slice does not touch.
      const value = 'a\uD800b';
      final expected = Uint8List.fromList(utf8.encode(value));

      // When: fromString marshals it
      final zbytes = ZBytes.fromString(value);

      // Then: the marshalled bytes are exactly what `utf8.encode` produced --
      // the fix changes the copy, never the encode.
      expect(zbytes.toBytes(), equals(expected));

      zbytes.dispose();
    });
  });
  group('ZBytes.clone()', () {
    test('clone produces valid independent copy', () {
      // Given: a ZBytes created from a string
      final original = ZBytes.fromString('hello clone');

      // When: clone() is called
      final cloned = original.clone();

      // Then: both return the same string
      expect(cloned.toStr(), equals('hello clone'));
      expect(original.toStr(), equals('hello clone'));

      cloned.dispose();
      original.dispose();
    });

    test('clone and original can be disposed independently', () {
      // Given: a ZBytes and its clone
      final original = ZBytes.fromString('independent');
      final cloned = original.clone();

      // When: original is disposed first
      original.dispose();

      // Then: clone still works
      expect(cloned.toStr(), equals('independent'));
      cloned.dispose();

      // And vice versa: disposing clone after original is fine
      final a = ZBytes.fromString('reverse');
      a.clone().dispose();
      expect(a.toStr(), equals('reverse'));
      a.dispose();
    });

    test('clone of clone works', () {
      // Given: a ZBytes
      final original = ZBytes.fromString('deep');

      // When: clone of clone is created
      final clone1 = original.clone();
      final clone2 = clone1.clone();

      // Then: all three hold the same value
      expect(original.toStr(), equals('deep'));
      expect(clone1.toStr(), equals('deep'));
      expect(clone2.toStr(), equals('deep'));

      clone2.dispose();
      clone1.dispose();
      original.dispose();
    });

    test('clone on disposed throws StateError', () {
      // Given: a disposed ZBytes
      final zbytes = ZBytes.fromString('disposed')..dispose();

      // When/Then: clone() throws StateError
      expect(zbytes.clone, throwsStateError);
    });

    test('clone on consumed throws StateError', () {
      // Given: a consumed ZBytes
      final zbytes = ZBytes.fromString('consumed')..markConsumed();

      // When/Then: clone() throws StateError
      expect(zbytes.clone, throwsStateError);
    });

    test('clone of empty bytes works', () {
      // Given: ZBytes created from an empty string
      final original = ZBytes.fromString('');

      // When: clone() is called
      final cloned = original.clone();

      // Then: clone is valid and returns empty string
      expect(cloned.toStr(), equals(''));

      cloned.dispose();
      original.dispose();
    });
  });

  group('ZBytes convenience methods', () {
    test('fromInt / toInt round-trip', () {
      // Given: no preconditions
      // When: ZBytes.fromInt(42) is created, then toInt() is called
      final zbytes = ZBytes.fromInt(42);
      final result = zbytes.toInt();

      // Then: returns 42
      expect(result, equals(42));
      zbytes.dispose();
    });

    test('fromDouble / toDouble round-trip', () {
      // Given: no preconditions
      // When: ZBytes.fromDouble(-3.14) is created, then toDouble() is called
      final zbytes = ZBytes.fromDouble(-3.14);
      final result = zbytes.toDouble();

      // Then: returns -3.14
      expect(result, equals(-3.14));
      zbytes.dispose();
    });

    test('fromBool / toBool round-trip true', () {
      // Given: no preconditions
      // When: ZBytes.fromBool(true) is created, then toBool() is called
      final zbytes = ZBytes.fromBool(true);
      final result = zbytes.toBool();

      // Then: returns true
      expect(result, isTrue);
      zbytes.dispose();
    });

    test('fromBool / toBool round-trip false', () {
      // Given: no preconditions
      // When: ZBytes.fromBool(false) is created, then toBool() is called
      final zbytes = ZBytes.fromBool(false);
      final result = zbytes.toBool();

      // Then: returns false
      expect(result, isFalse);
      zbytes.dispose();
    });

    test('fromInt interop with ZDeserializer', () {
      // Given: ZBytes.fromInt(42) is created
      final zbytes = ZBytes.fromInt(42);

      // When: ZDeserializer(bytes) is created, deserializeInt64() is called
      final deser = ZDeserializer(zbytes);
      final result = deser.deserializeInt64();

      // Then: returns 42, isDone is true
      expect(result, equals(42));
      expect(deser.isDone, isTrue);

      deser.dispose();
      zbytes.dispose();
    });

    test('toInt on multi-value payload throws ZenohException', () {
      // Given: ZSerializer serializes uint32(42) then string("extra"),
      // finishes to ZBytes
      final ser = ZSerializer()
        ..serializeUint32(42)
        ..serializeString('extra');
      final zbytes = ser.finish();
      ser.dispose();

      // When: toInt() is called on the resulting ZBytes
      // Then: throws ZenohException (extra data remains)
      expect(zbytes.toInt, throwsA(isA<ZenohException>()));

      zbytes.dispose();
    });

    test('fromInt with negative value round-trips (min int64)', () {
      // Given: no preconditions
      // When: ZBytes.fromInt(-9223372036854775808) is created, then toInt()
      // is called
      final zbytes = ZBytes.fromInt(-9223372036854775808);
      final result = zbytes.toInt();

      // Then: returns -9223372036854775808
      expect(result, equals(-9223372036854775808));
      zbytes.dispose();
    });
  });

  group('ZBytes single-shot scalar widths', () {
    test('each new width round-trips at its extremes', () {
      // Given: the eight canon scalar widths that had no single-shot form
      // When: each value is written with the new constructor and read back
      // with the new reader, at the extremes of its documented Dart domain
      // Then: every value returns bit-identical
      for (final width in _intWidths) {
        _expectIntRoundTrip(width, width.extremes);
      }

      // f32's extremes are binary32's own: FLT_MAX, -FLT_MAX and the
      // smallest positive normal, each exactly representable in binary64
      // too, so the narrowing must be the identity on them.
      for (final value in [
        3.4028234663852886e+38,
        -3.4028234663852886e+38,
        1.1754943508222875e-38,
        0.0,
      ]) {
        final bytes = ZBytes.fromFloat(value);
        expect(bytes.toFloat(), equals(value), reason: 'float $value');
        bytes.dispose();
      }
    });

    test('signed widths round-trip at -1, 0 and 1', () {
      // Given: the three narrow signed widths
      final signed = _intWidths.where((w) => w.name.startsWith('int')).toList();
      expect(signed.length, equals(3), reason: 'int8, int16, int32');

      // When/Then: the sign boundary round-trips on each of them
      for (final width in signed) {
        _expectIntRoundTrip(width, [-1, 0, 1]);
      }
    });

    test('f32 round-trips where binary32 and binary64 differ', () {
      // The values below are chosen because their binary32 and binary64
      // representations differ -- and the cell PROVES that rather than
      // asserting it, so it cannot degrade into a tautology. Dart's own
      // Float32List narrowing is the independent oracle: each value must
      // MOVE under it before the round-trip result is compared to it.
      for (final value in [0.1, 1.0e-40, 16777217.0, -0.7]) {
        final nearest = (Float32List(1)..[0] = value)[0];
        expect(
          nearest,
          isNot(equals(value)),
          reason: '$value must not be representable in binary32',
        );

        final bytes = ZBytes.fromFloat(value);
        expect(bytes.toFloat(), equals(nearest), reason: 'float $value');
        bytes.dispose();
      }

      // NaN and the infinities survive as themselves.
      final nan = ZBytes.fromFloat(double.nan);
      expect(nan.toFloat().isNaN, isTrue);
      nan.dispose();

      for (final value in [double.infinity, double.negativeInfinity]) {
        final bytes = ZBytes.fromFloat(value);
        expect(bytes.toFloat(), equals(value), reason: 'float $value');
        bytes.dispose();
      }
    });

    test('the new one-shot bytes match the streaming bytes', () {
      // Given: the same value written both ways
      // When: the payloads are compared byte for byte
      // Then: they are identical -- our surface reproducing the
      // canon-to-canon measurement that justified declining the one-shot
      // canon family as genuinely redundant.
      for (final width in _intWidths) {
        for (final value in width.extremes) {
          final oneShot = width.from(value);
          final streamed = _streamed(width, value);
          expect(
            oneShot.toBytes(),
            equals(streamed.toBytes()),
            reason: '${width.name} value $value',
          );
          oneShot.dispose();
          streamed.dispose();
        }
      }

      final oneShotFloat = ZBytes.fromFloat(0.1);
      final streamedFloat = (ZSerializer()..serializeFloat(0.1)).finish();
      expect(oneShotFloat.toBytes(), equals(streamedFloat.toBytes()));
      oneShotFloat.dispose();
      streamedFloat.dispose();

      // Control: the comparator above is capable of reporting DIFFERENT.
      // [134, 214, 18, 0] is the measured int32 encoding of 1234566; its
      // neighbour 1234567 must not match it.
      final measured = ZBytes.fromInt32(1234566);
      final neighbour = ZBytes.fromInt32(1234567);
      expect(measured.toBytes(), equals([134, 214, 18, 0]));
      expect(measured.toBytes(), isNot(equals(neighbour.toBytes())));
      measured.dispose();
      neighbour.dispose();
    });

    test('cross-family readback works in both directions', () {
      for (final width in _intWidths) {
        final value = width.extremes.last;

        // One-shot written -> streaming read, reporting fully consumed.
        final oneShot = width.from(value);
        final deser = ZDeserializer(oneShot);
        expect(width.deserialize(deser), equals(value), reason: width.name);
        expect(deser.isDone, isTrue, reason: '${width.name} fully consumed');
        deser.dispose();
        oneShot.dispose();

        // Streaming written -> one-shot read. The single-shot reader only
        // RETURNS when the payload is fully consumed -- an unconsumed tail
        // is the code-12 failure pinned below -- so a plain return is the
        // fully-consumed report on this leg.
        final streamed = _streamed(width, value);
        expect(width.to(streamed), equals(value), reason: width.name);
        streamed.dispose();
      }

      final oneShotFloat = ZBytes.fromFloat(0.5);
      final deserFloat = ZDeserializer(oneShotFloat);
      expect(deserFloat.deserializeFloat(), equals(0.5));
      expect(deserFloat.isDone, isTrue);
      deserFloat.dispose();
      oneShotFloat.dispose();

      final streamedFloat = (ZSerializer()..serializeFloat(0.5)).finish();
      expect(streamedFloat.toFloat(), equals(0.5));
      streamedFloat.dispose();
    });

    test('trailing data fails with 12', () {
      // MEASURED, canon-to-canon (int32 payload 1234566, 3 trailing bytes):
      //   ONE-SHOT ze_deserialize_int32: TRAILING data rc=-2
      //   STREAMING ze_deserializer:     TRAILING data rc=0, is_done=0
      // Our readers compose over the STREAMING pair, so on this path canon
      // returns Z_OK -- it SUCCEEDS -- and the check is Dart-side. There is
      // therefore no canon rc to adopt, and any canon negative would
      // masquerade: a consumer catching it would read "canon's deserializer
      // rejected my bytes" when canon's deserializer accepted them. The
      // code is binding-owned and lives in canon-free POSITIVE space beside
      // the shipped 10 (capacity) and 11 (allocation).
      for (final width in _intWidths) {
        final ser = ZSerializer();
        width.serialize(ser, width.extremes.last);
        ser.serializeUint8(7);
        final payload = ser.finish();

        final err = _zenohErrorFrom(() => width.to(payload));
        expect(err, isNotNull, reason: '${width.name} must reject a tail');
        expect(err!.returnCode, equals(12), reason: width.name);
        expect(
          err.returnCode,
          greaterThan(0),
          reason: '${width.name} must not fabricate a canon negative',
        );
        payload.dispose();
      }

      final serFloat = ZSerializer()
        ..serializeFloat(0.5)
        ..serializeUint8(7);
      final payloadFloat = serFloat.finish();
      final errFloat = _zenohErrorFrom(payloadFloat.toFloat);
      expect(errFloat?.returnCode, equals(12));
      payloadFloat.dispose();
    });

    test('a too-short payload reports -7', () {
      // -7 is Z_EDESERIALIZE, canon's own, measured on the very family
      // these readers call: a payload shorter than the width returns rc=-7
      // from ze_deserializer_deserialize_*. It is adopted, not minted.
      for (final width in _intWidths) {
        final payload = ZBytes.fromUint8List(Uint8List(width.size - 1));
        final err = _zenohErrorFrom(() => width.to(payload));
        expect(err, isNotNull, reason: '${width.name} must reject a short');
        expect(err!.returnCode, equals(-7), reason: width.name);
        payload.dispose();
      }

      final shortFloat = ZBytes.fromUint8List(Uint8List(3));
      final errFloat = _zenohErrorFrom(shortFloat.toFloat);
      expect(errFloat?.returnCode, equals(-7));
      shortFloat.dispose();
    });

    test('the two failure conditions are distinguishable', () {
      // Z_EPARSE (-2) is unobservable through this binding because the plan
      // DECLINED canon's one-shot family on the byte-identity carve -- NOT
      // because canon lacks a code for trailing data. Canon has one, and it
      // is -2: the measured one-shot ze_deserialize_int32 answers -2 for
      // BOTH a short payload and a trailing one, which is exactly the
      // conflation this cell pins the absence of.
      final truncated = ZBytes.fromUint8List(Uint8List(3));
      final short = _zenohErrorFrom(truncated.toUint32);
      truncated.dispose();

      final ser = ZSerializer()
        ..serializeUint32(4242)
        ..serializeUint8(9);
      final withTail = ser.finish();
      final trailing = _zenohErrorFrom(withTail.toUint32);
      withTail.dispose();

      expect(short, isNotNull);
      expect(trailing, isNotNull);
      expect(short!.returnCode, equals(-7));
      expect(trailing!.returnCode, equals(12));
      expect(short.returnCode, isNot(equals(trailing.returnCode)));
      expect(short.returnCode, isNot(equals(-2)));
      expect(trailing.returnCode, isNot(equals(-2)));
    });

    test('uint64 above 2^63 states and pins what it does', () {
      // Dart has no unsigned 64-bit integer, so a uint64 whose top bit is
      // set is representable ONLY as the corresponding negative Dart int.
      // The reader returns that bit pattern unchanged: this is the sole
      // Dart-representable form, NOT a transform applied to the value.
      final allOnes = ZBytes.fromUint64(-1);
      expect(allOnes.toBytes(), equals(List<int>.filled(8, 255)));
      expect(allOnes.toUint64(), equals(-1));
      expect(
        BigInt.from(allOnes.toUint64()).toUnsigned(64),
        equals(BigInt.parse('18446744073709551615')),
        reason: 'the same 64 bits read as unsigned are 2^64 - 1',
      );
      allOnes.dispose();

      final topBit = ZBytes.fromUint64(-9223372036854775808);
      expect(topBit.toUint64(), equals(-9223372036854775808));
      expect(
        BigInt.from(topBit.toUint64()).toUnsigned(64),
        equals(BigInt.parse('9223372036854775808')),
        reason: 'the same 64 bits read as unsigned are 2^63',
      );
      topBit.dispose();
    });

    test('fromString/toStr are not the serialized string form', () {
      // fromString/toStr are RAW UNFRAMED UTF-8. The serializer's string
      // form is length-prefixed (a varint; one byte at this length), so the
      // two payloads differ by that prefix and reading either as the other
      // misreads it. The width names must not imply interchangeability.
      const text = 'hi';
      final raw = ZBytes.fromString(text);
      final framed = (ZSerializer()..serializeString(text)).finish();

      final rawBytes = raw.toBytes();
      final framedBytes = framed.toBytes();
      expect(rawBytes, equals(utf8.encode(text)));
      expect(framedBytes, isNot(equals(rawBytes)));
      expect(framedBytes.length, equals(rawBytes.length + 1));
      expect(framedBytes.first, equals(rawBytes.length));
      expect(framedBytes.sublist(1), equals(rawBytes));

      // And the leak is visible on the display view: the framed payload
      // read as raw text carries the prefix byte.
      expect(framed.toStr(), isNot(equals(text)));

      raw.dispose();
      framed.dispose();
    });

    test('the narrow widths inherit the serializer domain guard', () {
      // The guard lives ONE layer down, in ZSerializer._requireInRange, and
      // the new constructors compose over it. So this cell asserts the
      // INHERITANCE rather than a duplicate: the ArgumentError carries the
      // serializer's own wording, and bytes.dart carries no range text of
      // its own (the source check catches a future edit that copies one in
      // and lets the two policies drift).
      final rejects = <(String, void Function())>[
        ('uint8', () => ZBytes.fromUint8(-1)),
        ('uint8', () => ZBytes.fromUint8(256)),
        ('uint16', () => ZBytes.fromUint16(-1)),
        ('uint16', () => ZBytes.fromUint16(65536)),
        ('uint32', () => ZBytes.fromUint32(-1)),
        ('uint32', () => ZBytes.fromUint32(4294967296)),
        ('int8', () => ZBytes.fromInt8(-129)),
        ('int8', () => ZBytes.fromInt8(128)),
        ('int16', () => ZBytes.fromInt16(-32769)),
        ('int16', () => ZBytes.fromInt16(32768)),
        ('int32', () => ZBytes.fromInt32(-2147483649)),
        ('int32', () => ZBytes.fromInt32(2147483648)),
      ];
      for (final entry in rejects) {
        final (width, build) = entry;
        expect(
          build,
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              contains('out of range for $width'),
            ),
          ),
          reason: width,
        );
      }

      // uint64 and float are unguarded by design, for the same reasons the
      // serializer's are: every Dart int is a valid 64-bit pattern, and
      // every finite f64 has a defined nearest binary32.
      expect(() => ZBytes.fromUint64(-1).dispose(), returnsNormally);
      expect(() => ZBytes.fromFloat(1e300).dispose(), returnsNormally);

      final source = File('lib/src/bytes.dart').readAsStringSync();
      expect(source, isNot(contains('out of range for')));
      expect(source, isNot(contains('_requireInRange')));
    });
  });

  group('ZBytes shipped conversions: one trailing-data policy', () {
    // MEASURED, on the very family these three readers call (and re-measured
    // for this slice through the shipped surface itself):
    //   STREAMING ze_deserializer, TRAILING data:  rc=0, is_done=0
    //   STREAMING ze_deserializer, short payload:  rc=-7 (Z_EDESERIALIZE)
    // So on the trailing-data path canon ACCEPTS the bytes and the rejection
    // is entirely ours. The shipped three used to report -1 (Z_EINVAL) there
    // -- a canon code fabricated for a condition canon never reported -- so a
    // consumer catching it read "canon's deserializer rejected my bytes"
    // when canon's deserializer did no such thing. 12 is binding-owned and
    // positive on purpose, beside the shipped 10 (capacity out of range) and
    // 11 (allocation failure).

    test('trailing data after an int64 reports 12', () {
      final payload =
          (ZSerializer()
                ..serializeInt64(42)
                ..serializeUint8(7))
              .finish();

      final err = _zenohErrorFrom(payload.toInt);
      expect(err, isNotNull, reason: 'toInt must reject a tail');
      expect(err!.returnCode, equals(12));
      expect(
        err.returnCode,
        greaterThan(0),
        reason: 'a binding-minted code must not sit in canon negative space',
      );
      expect(err.returnCode, isNot(equals(-1)), reason: 'not Z_EINVAL');
      payload.dispose();
    });

    test('trailing data after a double reports 12', () {
      final payload =
          (ZSerializer()
                ..serializeDouble(-3.5)
                ..serializeUint8(7))
              .finish();

      final err = _zenohErrorFrom(payload.toDouble);
      expect(err, isNotNull, reason: 'toDouble must reject a tail');
      expect(err!.returnCode, equals(12));
      expect(err.returnCode, greaterThan(0));
      expect(err.returnCode, isNot(equals(-1)), reason: 'not Z_EINVAL');
      payload.dispose();
    });

    test('trailing data after a bool reports 12', () {
      final payload =
          (ZSerializer()
                ..serializeBool(true)
                ..serializeUint8(7))
              .finish();

      final err = _zenohErrorFrom(payload.toBool);
      expect(err, isNotNull, reason: 'toBool must reject a tail');
      expect(err!.returnCode, equals(12));
      expect(err.returnCode, greaterThan(0));
      expect(err.returnCode, isNot(equals(-1)), reason: 'not Z_EINVAL');
      payload.dispose();
    });

    test('the shipped three and the new eight agree on the code', () {
      // The SAME eight value bytes plus the SAME trailing byte, read once
      // through a shipped conversion (toInt, int64) and once through a new
      // one (toUint64) -- the identical condition on the identical payload.
      // This is the whole reason the shipped three were touched: one policy
      // governs all eleven, not eight-plus-a-legacy-three.
      final payload =
          (ZSerializer()
                ..serializeInt64(42)
                ..serializeUint8(7))
              .finish();

      final shipped = _zenohErrorFrom(payload.toInt);
      final added = _zenohErrorFrom(payload.toUint64);

      expect(shipped, isNotNull);
      expect(added, isNotNull);
      expect(shipped!.returnCode, equals(added!.returnCode));
      expect(shipped.returnCode, equals(12));
      payload.dispose();
    });

    test('a short payload still reports canon -7 on the shipped three', () {
      // -7 is canon's own, adopted BECAUSE canon reported it. The two
      // conditions stay distinguishable on the shipped surface exactly as on
      // the new one: -7 short, 12 trailing.
      final shortInt = ZBytes.fromUint8List(Uint8List(7));
      final intErr = _zenohErrorFrom(shortInt.toInt);
      expect(intErr, isNotNull, reason: 'toInt must reject a short payload');
      expect(intErr!.returnCode, equals(-7));
      shortInt.dispose();

      final shortDouble = ZBytes.fromUint8List(Uint8List(7));
      final doubleErr = _zenohErrorFrom(shortDouble.toDouble);
      expect(doubleErr, isNotNull, reason: 'toDouble must reject a short');
      expect(doubleErr!.returnCode, equals(-7));
      shortDouble.dispose();

      // A bool is one byte wide, so the only shorter payload is the empty
      // one -- which canon also answers with -7.
      final shortBool = ZBytes.fromUint8List(Uint8List(0));
      final boolErr = _zenohErrorFrom(shortBool.toBool);
      expect(boolErr, isNotNull, reason: 'toBool must reject a short');
      expect(boolErr!.returnCode, equals(-7));
      shortBool.dispose();

      expect(intErr.returnCode, isNot(equals(12)));
      expect(doubleErr.returnCode, isNot(equals(12)));
      expect(boolErr.returnCode, isNot(equals(12)));
    });

    test('a well-formed payload of each type is unaffected', () {
      final asInt = ZBytes.fromInt(-9223372036854775808);
      expect(asInt.toInt, returnsNormally);
      expect(asInt.toInt(), equals(-9223372036854775808));
      asInt.dispose();

      final asDouble = ZBytes.fromDouble(-3.5);
      expect(asDouble.toDouble, returnsNormally);
      expect(asDouble.toDouble(), equals(-3.5));
      asDouble.dispose();

      final asTrue = ZBytes.fromBool(true);
      expect(asTrue.toBool, returnsNormally);
      expect(asTrue.toBool(), isTrue);
      asTrue.dispose();

      final asFalse = ZBytes.fromBool(false);
      expect(asFalse.toBool, returnsNormally);
      expect(asFalse.toBool(), isFalse);
      asFalse.dispose();
    });

    test('each shipped conversion documents both codes', () {
      // Rendered as a DARTDOC contract check rather than a CHANGELOG one: a
      // later slice owns CHANGELOG.md, and the dartdoc is where a consumer
      // deciding what to catch actually looks. Anchored on each method's own
      // doc block, so the file mentioning a code elsewhere cannot pass it.
      final source = File('lib/src/bytes.dart').readAsStringSync();
      final shipped = <String, String>{
        'toInt': 'int toInt()',
        'toDouble': 'double toDouble()',
        'toBool': 'bool toBool()',
      };

      for (final entry in shipped.entries) {
        final name = entry.key;
        final doc = _docCommentFor(source, entry.value);
        expect(doc, contains('`-7`'), reason: '$name names canon -7');
        expect(doc, contains('Z_EDESERIALIZE'), reason: name);
        expect(doc, contains('shorter'), reason: '$name: the -7 condition');
        expect(doc, contains('`12`'), reason: '$name names 12');
        expect(doc, contains('beyond'), reason: '$name: the 12 condition');
        expect(doc, isNot(contains('`-1`')), reason: '$name drops -1');
      }

      // And no ZenohException in this file is still raised with a literal
      // negative code: the three fabricated -1 sites are gone, and a future
      // edit reintroducing one is caught here.
      final literalNegative = RegExp(r'ZenohException\([^)]*,\s*-\d+\)');
      expect(
        literalNegative.hasMatch(source),
        isFalse,
        reason: 'no fabricated canon negative may be raised from bytes.dart',
      );
    });
  });

  group('ZBytes.slices', () {
    test('single ZBytes has one slice', () {
      // Given: ZBytes from string "hello"
      final zbytes = ZBytes.fromString('hello');

      // When: slices is iterated
      final result = zbytes.slices.toList();

      // Then: yields exactly 1 element equal to UTF-8 bytes of "hello"
      expect(result.length, equals(1));
      expect(result[0], equals(Uint8List.fromList([104, 101, 108, 108, 111])));
      zbytes.dispose();
    });

    test('writer-assembled ZBytes has multiple slices', () {
      // Given: three ZBytes appended via ZBytesWriter
      final writer = ZBytesWriter()
        ..append(ZBytes.fromString('abc'))
        ..append(ZBytes.fromString('def'))
        ..append(ZBytes.fromString('hij'));
      final zbytes = writer.finish();
      writer.dispose();

      // When: slices is iterated on the finished result
      final result = zbytes.slices.toList();

      // Then: yields >=1 elements whose concatenation equals UTF-8 of
      // "abcdefhij"
      expect(result.length, greaterThanOrEqualTo(1));
      final concatenated = result.expand((s) => s).toList();
      expect(
        Uint8List.fromList(concatenated),
        equals(Uint8List.fromList([97, 98, 99, 100, 101, 102, 104, 105, 106])),
      );
      zbytes.dispose();
    });

    test('empty ZBytes has no slices', () {
      // Given: ZBytes from empty string
      final zbytes = ZBytes.fromString('');

      // When: slices is iterated
      final result = zbytes.slices.toList();

      // Then: yields 0 elements
      expect(result, isEmpty);
      zbytes.dispose();
    });

    test('slices can be iterated multiple times', () {
      // Given: ZBytes from string "reuse"
      final zbytes = ZBytes.fromString('reuse');

      // When: slices is iterated twice
      final first = zbytes.slices.toList();
      final second = zbytes.slices.toList();

      // Then: both iterations yield identical results
      expect(first.length, equals(second.length));
      for (var i = 0; i < first.length; i++) {
        expect(first[i], equals(second[i]));
      }
      zbytes.dispose();
    });
  });

  group(
    'ZBytes.isShmBacked (A5 Android guard)',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('non-SHM heap payload reports false on Linux', () {
        // Given: a heap-backed ZBytes on the Linux test host
        // When: isShmBacked is read
        // Then: it returns false and does not throw (regression guard locking
        //       the existing Linux contract across the Android short-circuit)
        final zbytes = ZBytes.fromString('not-shm');
        expect(zbytes.isShmBacked, isFalse);
        zbytes.dispose();
      });
    },
  );

  group('ZBytes consumed-wrapper lifecycle', () {
    // markConsumed frees the Dart-owned calloc block wrapping the (already
    // gravestoned) z_owned_bytes_t. These pin the paths on which that block
    // must be released exactly once -- a double free would abort the VM, so
    // "returnsNormally" here is a real assertion, not a formality.

    test('dispose after consume is a no-op (block already freed)', () {
      // Given: a ZBytes whose native handle has been moved into zenoh-c
      final zbytes = ZBytes.fromString('consumed')..markConsumed();

      // When/Then: dispose() must not drop or free a second time
      expect(zbytes.dispose, returnsNormally);
    });

    test('repeated dispose after consume stays a no-op', () {
      final zbytes = ZBytes.fromString('consumed')..markConsumed();

      expect(zbytes.dispose, returnsNormally);
      expect(zbytes.dispose, returnsNormally);
    });

    test('markConsumed is idempotent (aliased payload/attachment)', () {
      // Given: one ZBytes passed as BOTH payload and attachment to a send op,
      //   which marks each argument in turn -- so the same instance is marked
      //   twice and must be freed only once.
      final zbytes = ZBytes.fromString('aliased')..markConsumed();

      expect(zbytes.markConsumed, returnsNormally);
      expect(zbytes.markConsumed, returnsNormally);
    });

    test('markConsumed after dispose does not free a second time', () {
      // Given: a disposed ZBytes (block already freed by dispose)
      final zbytes = ZBytes.fromString('disposed')..dispose();

      // When/Then: a stray mark must not re-free, and must leave the state
      //   reporting "disposed" rather than "consumed".
      expect(zbytes.markConsumed, returnsNormally);
      expect(
        zbytes.toBytes,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    test('consumed ZBytes still reports consumed on every accessor', () {
      // The guards are what make freeing at consumption time safe: no accessor
      // may reach _ptr once it is freed.
      final zbytes = ZBytes.fromString('consumed')..markConsumed();

      expect(zbytes.toBytes, throwsStateError);
      expect(zbytes.toStr, throwsStateError);
      expect(zbytes.clone, throwsStateError);
      expect(zbytes.toInt, throwsStateError);
      expect(zbytes.toDouble, throwsStateError);
      expect(zbytes.toBool, throwsStateError);
      expect(() => zbytes.slices.toList(), throwsStateError);
    });
  });
}

/// One canon scalar integer width, and every route this slice must make
/// agree about it: the new single-shot pair, the shipped streaming pair the
/// single-shot pair composes over, the width's byte size, and the extremes
/// of its documented Dart domain.
typedef _IntWidth = ({
  String name,
  int size,
  ZBytes Function(int) from,
  int Function(ZBytes) to,
  void Function(ZSerializer, int) serialize,
  int Function(ZDeserializer) deserialize,
  List<int> extremes,
});

final _intWidths = <_IntWidth>[
  (
    name: 'uint8',
    size: 1,
    from: ZBytes.fromUint8,
    to: (b) => b.toUint8(),
    serialize: (s, v) => s.serializeUint8(v),
    deserialize: (d) => d.deserializeUint8(),
    extremes: [0, 255],
  ),
  (
    name: 'uint16',
    size: 2,
    from: ZBytes.fromUint16,
    to: (b) => b.toUint16(),
    serialize: (s, v) => s.serializeUint16(v),
    deserialize: (d) => d.deserializeUint16(),
    extremes: [0, 65535],
  ),
  (
    name: 'uint32',
    size: 4,
    from: ZBytes.fromUint32,
    to: (b) => b.toUint32(),
    serialize: (s, v) => s.serializeUint32(v),
    deserialize: (d) => d.deserializeUint32(),
    extremes: [0, 4294967295],
  ),
  (
    // uint64's Dart domain is every Dart int, so its extremes are int64's:
    // a value at or above 2^63 is representable only as its two's
    // complement pattern. The "uint64 above 2^63" cell pins what that
    // means; here it is simply carried unchanged.
    name: 'uint64',
    size: 8,
    from: ZBytes.fromUint64,
    to: (b) => b.toUint64(),
    serialize: (s, v) => s.serializeUint64(v),
    deserialize: (d) => d.deserializeUint64(),
    extremes: [-9223372036854775808, 0, 9223372036854775807],
  ),
  (
    name: 'int8',
    size: 1,
    from: ZBytes.fromInt8,
    to: (b) => b.toInt8(),
    serialize: (s, v) => s.serializeInt8(v),
    deserialize: (d) => d.deserializeInt8(),
    extremes: [-128, 127],
  ),
  (
    name: 'int16',
    size: 2,
    from: ZBytes.fromInt16,
    to: (b) => b.toInt16(),
    serialize: (s, v) => s.serializeInt16(v),
    deserialize: (d) => d.deserializeInt16(),
    extremes: [-32768, 32767],
  ),
  (
    name: 'int32',
    size: 4,
    from: ZBytes.fromInt32,
    to: (b) => b.toInt32(),
    serialize: (s, v) => s.serializeInt32(v),
    deserialize: (d) => d.deserializeInt32(),
    extremes: [-2147483648, 2147483647],
  ),
];

/// Writes each of [values] with [width]'s single-shot constructor, reads it
/// back with [width]'s single-shot reader, and asserts it is unchanged.
void _expectIntRoundTrip(_IntWidth width, List<int> values) {
  for (final value in values) {
    final bytes = width.from(value);
    expect(
      width.to(bytes),
      equals(value),
      reason: '${width.name} value $value',
    );
    bytes.dispose();
  }
}

/// The payload the shipped streaming pair produces for [value] at [width].
ZBytes _streamed(_IntWidth width, int value) {
  final ser = ZSerializer();
  width.serialize(ser, value);
  return ser.finish();
}

/// Runs [body] and returns the [ZenohException] it threw, or null if it did
/// not throw one. Keeps the failure-code cells free of try/catch noise.
ZenohException? _zenohErrorFrom(void Function() body) {
  try {
    body();
  } on ZenohException catch (e) {
    return e;
  }
  return null;
}

/// Returns the dartdoc block immediately above [signature] in [source].
///
/// Walks backwards over the consecutive `///` lines, so an assertion made on
/// the result is about THAT method's documented contract -- a code named
/// anywhere else in the file cannot satisfy it.
///
/// [signature] is matched as a line PREFIX (`int toInt()`), which locates
/// the declaration without pinning its body form: whether the method is a
/// block or an arrow is not what this instrument is about. The uniqueness
/// check is what keeps the prefix honest.
String _docCommentFor(String source, String signature) {
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
