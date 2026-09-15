import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Slice 4: ZDeserializer round-trip tests

void main() {
  group('ZSerializer lifecycle', () {
    test('creates serializer and finishes to ZBytes', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      expect(bytes, isNotNull);
      bytes.dispose();
    });

    test('dispose releases resources without finish', () {
      final serializer = ZSerializer();
      expect(serializer.dispose, returnsNormally);
    });

    test('dispose is idempotent', () {
      final serializer = ZSerializer()..dispose();
      expect(serializer.dispose, returnsNormally);
    });

    test('finish then finish again throws StateError', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(serializer.finish, throwsStateError);
    });

    test('finish then dispose is safe', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(serializer.dispose, returnsNormally);
    });

    test('operations after dispose throw StateError', () {
      final serializer = ZSerializer()..dispose();
      expect(serializer.finish, throwsStateError);
    });
  });

  // The 'ZSerializer arithmetic types' and 'ZSerializer compound types' groups
  // were eleven serialize-then-`expect(bytes, isNotNull)` tests. `finish()`
  // returns a non-nullable ZBytes, so every one of those assertions was a
  // tautology; the only information they carried was implicit no-throw, and
  // the ZDeserializer round-trip group below drives all the same values
  // through real round-trips. Removed as dead weight (round 1 took ten; round 3
  // took the last one, 'boundary values serialize without error', once the
  // numeric-domain legs at the foot of this file superseded its INT64_MAX pin
  // -- see 'INT64_MAX round-trips and encodes to 7f ff...' there, which pins
  // both the value AND its octets where the removed test pinned neither).

  group('ZDeserializer round-trip', () {
    test('uint8 round-trip', () {
      final ser = ZSerializer()..serializeUint8(42);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(42));
      expect(deser.isDone, isTrue);
    });

    test('uint16 round-trip', () {
      final ser = ZSerializer()..serializeUint16(1000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint16(), equals(1000));
      expect(deser.isDone, isTrue);
    });

    test('uint32 round-trip', () {
      final ser = ZSerializer()..serializeUint32(51000000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint32(), equals(51000000));
      expect(deser.isDone, isTrue);
    });

    test('uint64 round-trip', () {
      final ser = ZSerializer()..serializeUint64(1000000000005);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint64(), equals(1000000000005));
      expect(deser.isDone, isTrue);
    });

    test('int8 round-trip', () {
      final ser = ZSerializer()..serializeInt8(-5);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt8(), equals(-5));
      expect(deser.isDone, isTrue);
    });

    test('int16 round-trip', () {
      final ser = ZSerializer()..serializeInt16(-1000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt16(), equals(-1000));
      expect(deser.isDone, isTrue);
    });

    test('int32 round-trip', () {
      final ser = ZSerializer()..serializeInt32(51000000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt32(), equals(51000000));
      expect(deser.isDone, isTrue);
    });

    test('int64 round-trip', () {
      final ser = ZSerializer()..serializeInt64(-1000000000005);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt64(), equals(-1000000000005));
      expect(deser.isDone, isTrue);
    });

    test('float round-trip with tolerance', () {
      final ser = ZSerializer()..serializeFloat(10.1);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeFloat(), closeTo(10.1, 0.01));
      expect(deser.isDone, isTrue);
    });

    test('double round-trip exact', () {
      final ser = ZSerializer()..serializeDouble(-105.001);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeDouble(), equals(-105.001));
      expect(deser.isDone, isTrue);
    });

    test('bool round-trip', () {
      final ser = ZSerializer()
        ..serializeBool(true)
        ..serializeBool(false);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBool(), isTrue);
      expect(deser.deserializeBool(), isFalse);
      expect(deser.isDone, isTrue);
    });

    test('string round-trip', () {
      final ser = ZSerializer()..serializeString('hello zenoh');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeString(), equals('hello zenoh'));
      expect(deser.isDone, isTrue);
    });

    test('bytes/slice round-trip', () {
      final ser = ZSerializer()
        ..serializeBytes(Uint8List.fromList([1, 2, 3, 4]));
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBytes(), equals([1, 2, 3, 4]));
      expect(deser.isDone, isTrue);
    });

    test('empty string round-trip', () {
      final ser = ZSerializer()..serializeString('');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeString(), equals(''));
      expect(deser.isDone, isTrue);
    });

    test('empty bytes round-trip', () {
      final ser = ZSerializer()..serializeBytes(Uint8List(0));
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBytes(), equals(<int>[]));
      expect(deser.isDone, isTrue);
    });

    test('zero values round-trip', () {
      final ser = ZSerializer()
        ..serializeUint8(0)
        ..serializeInt64(0)
        ..serializeDouble(0);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(0));
      expect(deser.deserializeInt64(), equals(0));
      expect(deser.deserializeDouble(), equals(0.0));
      expect(deser.isDone, isTrue);
    });

    test('boundary values round-trip', () {
      final ser = ZSerializer()
        ..serializeUint8(255)
        ..serializeInt8(-128)
        ..serializeInt8(127)
        ..serializeInt64(0x7FFFFFFFFFFFFFFF);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(255));
      expect(deser.deserializeInt8(), equals(-128));
      expect(deser.deserializeInt8(), equals(127));
      expect(deser.deserializeInt64(), equals(0x7FFFFFFFFFFFFFFF));
      expect(deser.isDone, isTrue);
    });

    test('isDone false with remaining data', () {
      final ser = ZSerializer()
        ..serializeUint32(42)
        ..serializeString('extra');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint32(), equals(42));
      expect(deser.isDone, isFalse);
    });

    test('dispose frees deserializer', () {
      final ser = ZSerializer()..serializeUint8(1);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      expect(deser.dispose, returnsNormally);
    });
  });

  group('Composite serialization', () {
    test('sequence of int32 round-trip', () {
      final ser = ZSerializer()
        ..serializeSequenceLength(4)
        ..serializeInt32(1)
        ..serializeInt32(2)
        ..serializeInt32(3)
        ..serializeInt32(4);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      final length = deser.deserializeSequenceLength();
      expect(length, equals(4));
      final values = <int>[];
      for (var i = 0; i < length; i++) {
        values.add(deser.deserializeInt32());
      }
      expect(values, equals([1, 2, 3, 4]));
      expect(deser.isDone, isTrue);
    });

    test('sequence of key-value pairs round-trip', () {
      final ser = ZSerializer()
        ..serializeSequenceLength(2)
        ..serializeInt32(0)
        ..serializeString('abc')
        ..serializeInt32(1)
        ..serializeString('def');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      final length = deser.deserializeSequenceLength();
      expect(length, equals(2));
      final pairs = <(int, String)>[];
      for (var i = 0; i < length; i++) {
        final key = deser.deserializeInt32();
        final value = deser.deserializeString();
        pairs.add((key, value));
      }
      expect(pairs, equals([(0, 'abc'), (1, 'def')]));
      expect(deser.isDone, isTrue);
    });

    test('nested sequence (custom struct) round-trip', () {
      final ser = ZSerializer()
        ..serializeFloat(1)
        ..serializeSequenceLength(2)
        // Inner sequence 1: [1, 2, 3]
        ..serializeSequenceLength(3)
        ..serializeUint64(1)
        ..serializeUint64(2)
        ..serializeUint64(3)
        // Inner sequence 2: [4, 5, 6]
        ..serializeSequenceLength(3)
        ..serializeUint64(4)
        ..serializeUint64(5)
        ..serializeUint64(6)
        ..serializeString('test');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      final floatVal = deser.deserializeFloat();
      expect(floatVal, closeTo(1.0, 0.01));
      final outerLen = deser.deserializeSequenceLength();
      expect(outerLen, equals(2));
      final nested = <List<int>>[];
      for (var i = 0; i < outerLen; i++) {
        final innerLen = deser.deserializeSequenceLength();
        expect(innerLen, equals(3));
        final inner = <int>[];
        for (var j = 0; j < innerLen; j++) {
          inner.add(deser.deserializeUint64());
        }
        nested.add(inner);
      }
      expect(
        nested,
        equals([
          [1, 2, 3],
          [4, 5, 6],
        ]),
      );
      final strVal = deser.deserializeString();
      expect(strVal, equals('test'));
      expect(deser.isDone, isTrue);
    });

    test('empty sequence round-trip', () {
      final ser = ZSerializer()..serializeSequenceLength(0);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      final length = deser.deserializeSequenceLength();
      expect(length, equals(0));
      expect(deser.isDone, isTrue);
    });

    // Census gap G3: a multi-byte ULEB128 sequence length round-trips.
    //
    // Every sequence-length cell above uses a length in 0..4, which is a
    // single ULEB128 octet -- the continuation path is never entered, so the
    // varint encoder and decoder could disagree beyond 127 and nothing in the
    // corpus would see it. 128 is the first length needing two octets; 300
    // additionally puts a non-zero payload in the second. Both encodings are
    // MEASURED (probe, 2026-08-21), not inferred from the format.
    //
    // The octet assertion is what makes this a wire pin rather than another
    // round-trip: a serializer and deserializer that changed together would
    // still return the value, and only the octets would show it.
    test('a multi-byte ULEB128 sequence length round-trips', () {
      const vectors = <int, List<int>>{
        128: [0x80, 0x01],
        300: [0xAC, 0x02],
      };
      for (final entry in vectors.entries) {
        final ser = ZSerializer()..serializeSequenceLength(entry.key);
        final bytes = ser.finish();
        addTearDown(bytes.dispose);
        expect(
          bytes.toBytes(),
          equals(entry.value),
          reason: 'length ${entry.key} ULEB128 octets',
        );

        final deser = ZDeserializer(bytes);
        addTearDown(deser.dispose);
        expect(deser.deserializeSequenceLength(), equals(entry.key));
        expect(deser.isDone, isTrue, reason: 'length ${entry.key} consumed');
      }
    });
  });

  group('Deserializer error handling', () {
    test('deserialize wrong type produces error', () {
      final ser = ZSerializer()..serializeUint32(42);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeString, throwsA(isA<ZenohException>()));
    });

    test('deserialize past end produces error', () {
      final ser = ZSerializer()..serializeUint32(42);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      // First deserialize succeeds
      expect(deser.deserializeUint32(), equals(42));
      expect(deser.isDone, isTrue);
      // Second deserialize should fail -- no more data
      expect(deser.deserializeUint32, throwsA(isA<ZenohException>()));
    });

    test('deserializer on disposed ZBytes throws StateError', () {
      final ser = ZSerializer()..serializeUint32(42);
      // Dispose the ZBytes before creating the deserializer
      final bytes = ser.finish()..dispose();

      // Creating a deserializer from disposed ZBytes should throw
      expect(() => ZDeserializer(bytes), throwsStateError);
    });

    // Census gap G1: a bool wire byte outside {0,1} is rejected.
    //
    // Canon's bool deserializer admits exactly two octets; anything else is a
    // malformed bool and comes back as Z_EDESERIALIZE (-7), canon's own code,
    // adopted rather than minted. The two in-domain octets are driven in the
    // same cell as a control: without them a reader that threw on every octet
    // would satisfy the rejection half and the cell would say nothing.
    test('a bool wire byte outside {0,1} is rejected with -7', () {
      for (final octet in <int>[0x02, 0xFF]) {
        final payload = ZBytes.fromUint8List(Uint8List.fromList([octet]));
        addTearDown(payload.dispose);
        final deser = ZDeserializer(payload);
        addTearDown(deser.dispose);
        expect(
          deser.deserializeBool,
          throwsA(
            isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -7),
          ),
          reason: 'octet 0x${octet.toRadixString(16)}',
        );
      }

      // Control: the in-domain octets are accepted and carry their values.
      for (final entry in <int, bool>{0x00: false, 0x01: true}.entries) {
        final payload = ZBytes.fromUint8List(Uint8List.fromList([entry.key]));
        addTearDown(payload.dispose);
        final deser = ZDeserializer(payload);
        addTearDown(deser.dispose);
        expect(deser.deserializeBool(), equals(entry.value));
      }
    });

    // Census gaps G2 and G5: invalid UTF-8 fed to deserializeString is
    // rejected with canon's -7, driven over the three census exemplars
    // verbatim plus a lone never-valid octet.
    //
    // Distinct from 'deserialize wrong type produces error' above, which is a
    // TRUNCATION story: that payload's length prefix (42) names far more
    // octets than remain. Here every payload is well framed -- the prefix
    // names exactly the octets that follow -- and the sole defect is that
    // those octets are not valid UTF-8. Canon validates the string it builds
    // and answers Z_EDESERIALIZE (-7), which means the `allowMalformed: true`
    // decode on our side is unreachable for invalid content: strictness is
    // canon-preserved here, not relaxed. That is what this cell pins.
    //
    // The exemplars are the classic three: a bad continuation byte, an
    // overlong solidus, and a lead byte beyond U+10FFFF. Each is built from
    // integer octets -- no exemplar is ever spelled as a character in a
    // string literal.
    test('invalid UTF-8 is rejected with -7, not decoded leniently', () {
      const exemplars = <String, List<int>>{
        'C3 28 (bad continuation byte)': [0xC3, 0x28],
        'C0 AF (overlong solidus)': [0xC0, 0xAF],
        'F5 80 80 80 (lead beyond U+10FFFF)': [0xF5, 0x80, 0x80, 0x80],
        'FF (never valid in UTF-8)': [0xFF],
      };
      for (final entry in exemplars.entries) {
        final payload = ZBytes.fromUint8List(
          Uint8List.fromList([entry.value.length, ...entry.value]),
        );
        addTearDown(payload.dispose);
        final deser = ZDeserializer(payload);
        addTearDown(deser.dispose);
        expect(
          deser.deserializeString,
          throwsA(
            isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -7),
          ),
          reason: entry.key,
        );
      }

      // Control: the SAME hand-built framing over valid UTF-8 succeeds, so
      // the rejections above are about validity and not about framing --
      // a mis-framed payload would also answer -7 and would look identical.
      final framedValid = ZBytes.fromUint8List(
        Uint8List.fromList([0x02, 0x68, 0x69]), // length 2, then 'h', 'i'
      );
      addTearDown(framedValid.dispose);
      final deser = ZDeserializer(framedValid);
      addTearDown(deser.dispose);
      expect(deser.deserializeString(), equals('hi'));
      expect(deser.isDone, isTrue);
    });
  });

  group('A2b string fidelity (NUL-safe serialize + lenient deserialize)', () {
    // An embedded-NUL string 'a', U+0000, 'b' (3 code units), constructed via
    // char codes so NO raw NUL byte ever appears in this source file.
    final embeddedNul = String.fromCharCodes([0x61, 0x00, 0x62]);

    // Helper: serialize one string, then deserialize it back.
    String roundTrip(String value) {
      final ser = ZSerializer()..serializeString(value);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      return deser.deserializeString();
    }

    // Test 1: Embedded-NUL string round-trips fully.
    test('embedded-NUL string round-trips fully', () {
      // GREEN: the length-based ze_serializer_serialize_substr shim preserves
      // the embedded NUL, so the full 3-char string round-trips. (RED, against
      // the pre-fix null-terminated ze_serializer_serialize_str, truncated this
      // to 'a'.)
      expect(roundTrip(embeddedNul), equals(embeddedNul));
    });

    // Test 2: Multibyte round-trip.
    test('multibyte string round-trips byte-exact', () {
      expect(roundTrip('héllo→'), equals('héllo→'));
    });

    // Edge Cases

    // Test 3: Empty string.
    test('empty string round-trips without throwing', () {
      expect(roundTrip(''), equals(''));
    });

    // Test 4: Lenient receive twin -- deserializeString is non-throwing over
    // the valid-string domain and round-trips valid strings byte-exact
    // (defensive twin consistent with A1's lenient ZBytes.toStr()).
    test('deserializeString is lenient and byte-exact for valid strings', () {
      for (final s in <String>['plain', 'héllo→', embeddedNul, '']) {
        expect(roundTrip(s), equals(s));
      }
    });
  });

  // Serialize with [build], then hand back the raw octets the wire would carry.
  Uint8List encoded(void Function(ZSerializer) build) {
    final ser = ZSerializer();
    build(ser);
    final bytes = ser.finish();
    addTearDown(bytes.dispose);
    return bytes.toBytes();
  }

  // Golden wire-format vectors, transplanted verbatim from canon zenoh-cpp's
  // `binary_format_test()` (extern/zenoh-cpp/tests/universal/serialization.cxx
  // :104-121). Every expected list below is that function's literal, byte for
  // byte, with the C++ type-directed calls rewritten as our positional
  // serializer calls (canon's serde is positional and tagless, so a
  // `std::tuple<uint16_t, float, std::string>` is exactly uint16 -> float ->
  // string, and a `std::vector<T>` is exactly a sequence length followed by its
  // elements).
  //
  // These are the only tests in the corpus that pin the *encoding* rather than
  // a Dart round-trip. A round-trip stays green when serializer and
  // deserializer change together -- which is precisely the change that breaks
  // interop with every other zenoh binding while our suite reports success.
  // Nothing else we have can see that; these can.
  group('Golden wire format (canon zenoh-cpp binary_format_test)', () {
    test('int32 encodes little-endian', () {
      expect(
        encoded((s) => s.serializeInt32(1234566)),
        equals([134, 214, 18, 0]),
      );
    });

    test('negative int32 encodes two-complement little-endian', () {
      expect(
        encoded((s) => s.serializeInt32(-49245)),
        equals([163, 63, 255, 255]),
      );
    });

    test('string encodes as length prefix then UTF-8', () {
      expect(
        encoded((s) => s.serializeString('test')),
        equals([4, 116, 101, 115, 116]),
      );
    });

    test('tuple(uint16, float, string) encodes positionally', () {
      expect(
        encoded(
          (s) => s
            ..serializeUint16(500)
            ..serializeFloat(1234)
            ..serializeString('test'),
        ),
        equals([244, 1, 0, 64, 154, 68, 4, 116, 101, 115, 116]),
      );
    });

    test('sequence of int64 encodes as length then elements', () {
      expect(
        encoded(
          (s) => s
            ..serializeSequenceLength(4)
            ..serializeInt64(-100)
            ..serializeInt64(500)
            ..serializeInt64(100000)
            ..serializeInt64(-20000000),
        ),
        equals([
          4,
          156, 255, 255, 255, 255, 255, 255, 255, //
          244, 1, 0, 0, 0, 0, 0, 0, //
          160, 134, 1, 0, 0, 0, 0, 0, //
          0, 211, 206, 254, 255, 255, 255, 255, //
        ]),
      );
    });

    test('sequence of (string, int16) pairs encodes positionally', () {
      expect(
        encoded(
          (s) => s
            ..serializeSequenceLength(2)
            ..serializeString('s1')
            ..serializeInt16(10)
            ..serializeString('s2')
            ..serializeInt16(-10000),
        ),
        equals([2, 2, 115, 49, 10, 0, 2, 115, 50, 240, 216]),
      );
    });
  });

  // Numeric fidelity domains -- the serializer half of the "correct in =>
  // correct out" check, driven over the domains a caller can actually reach
  // rather than the ones a caller happens to send today. Each leg pins the
  // value through a real round-trip AND, where the value is a boundary, its
  // octets, so a round-trip that changed on both sides cannot hide in it.
  //
  // These supersede the removed 'boundary values serialize without error'
  // (see the note at the head of this file).
  group('Numeric fidelity domains', () {
    // Round-trip one double through the serializer and hand back what came out.
    double doubleRoundTrip(double value) {
      final ser = ZSerializer()..serializeDouble(value);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      return deser.deserializeDouble();
    }

    test('NaN round-trips as NaN', () {
      expect(doubleRoundTrip(double.nan).isNaN, isTrue);
    });

    test('positive infinity round-trips', () {
      expect(doubleRoundTrip(double.infinity), equals(double.infinity));
    });

    test('negative infinity round-trips', () {
      expect(
        doubleRoundTrip(double.negativeInfinity),
        equals(double.negativeInfinity),
      );
    });

    test('negative zero round-trips with its sign intact', () {
      // The lint would have this written `-0`, which is the int zero and has
      // no sign -- the exact distinction under test. Keep the double literal.
      // ignore: prefer_int_literals
      final result = doubleRoundTrip(-0.0);
      // `expect(result, equals(-0.0))` would be satisfied by +0.0 -- Dart's
      // `==` treats the two as equal. `compareTo` is the discriminator that
      // does not: (-0.0).compareTo(0.0) == -1.
      expect(result.compareTo(-0.0), equals(0), reason: 'sign of zero lost');
      expect(result.compareTo(0.0), equals(-1), reason: 'came back as +0.0');
    });

    test('float NaN and infinities round-trip', () {
      final ser = ZSerializer()
        ..serializeFloat(double.nan)
        ..serializeFloat(double.infinity)
        ..serializeFloat(double.negativeInfinity);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeFloat().isNaN, isTrue);
      expect(deser.deserializeFloat(), equals(double.infinity));
      expect(deser.deserializeFloat(), equals(double.negativeInfinity));
      expect(deser.isDone, isTrue);
    });

    test('INT64_MIN round-trips and encodes to 00..80', () {
      const intMin = -9223372036854775808; // -2^63
      final ser = ZSerializer()..serializeInt64(intMin);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(
        bytes.toBytes(),
        equals([0, 0, 0, 0, 0, 0, 0, 128]),
        reason: 'INT64_MIN little-endian',
      );
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt64(), equals(intMin));
    });

    test('INT64_MAX round-trips and encodes to ff..7f', () {
      const intMax = 9223372036854775807; // 2^63 - 1
      final ser = ZSerializer()..serializeInt64(intMax);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(
        bytes.toBytes(),
        equals([255, 255, 255, 255, 255, 255, 255, 127]),
        reason: 'INT64_MAX little-endian',
      );
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt64(), equals(intMax));
    });

    // The u64 top-bit convention, pinned here because it is the one numeric
    // domain where our Dart type cannot represent the C type's range and the
    // API therefore has a convention rather than a plain mapping.
    //
    // Dart's `int` is 64-bit *signed*, so UINT64_MAX (2^64-1) is not a
    // representable literal. serializeUint64/deserializeUint64 pass the raw 64
    // bits through: a caller writes the bit pattern by passing the Dart int
    // with the same bits (-1 for all-ones), and reads it back the same way.
    // The convention is therefore "reinterpret, do not saturate or throw", and
    // the octet assertion below is what makes that claim checkable -- it holds
    // regardless of how Dart chooses to print the value.
    test('uint64 with the top bit set is reinterpreted, not clamped', () {
      const allOnes = -1; // UINT64_MAX's bit pattern in a signed Dart int.
      const topBitOnly = -9223372036854775808; // 2^63's bit pattern, likewise.
      final ser = ZSerializer()
        ..serializeUint64(allOnes)
        ..serializeUint64(topBitOnly);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(
        bytes.toBytes(),
        equals([
          255, 255, 255, 255, 255, 255, 255, 255, // UINT64_MAX
          0, 0, 0, 0, 0, 0, 0, 128, // 2^63
        ]),
      );
      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint64(), equals(allOnes));
      expect(deser.deserializeUint64(), equals(topBitOnly));
      expect(deser.isDone, isTrue);
    });
  });

  // Declared-width domains -- each of these methods names the native width
  // it writes, and that width's domain is part of the contract: a value
  // outside it is refused Dart-side, before any native call, rather than
  // wrapping mod 2^N. The float leg is the deliberate exception and is
  // pinned here beside the integer legs so the surface reads as one policy
  // rather than two.
  group('Declared width domains', () {
    test('an out-of-range unsigned value is refused', () {
      final ser = ZSerializer();
      addTearDown(ser.dispose);
      expect(
        () => ser.serializeUint8(300),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('0..255'),
          ),
        ),
      );
      // No native call was made, so no native state was touched: the
      // serializer still accepts a valid value, and the payload it produces
      // carries that value and nothing else.
      ser.serializeUint8(7);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(bytes.toBytes(), equals([7]));
    });

    test('an out-of-range signed value is refused', () {
      final ser = ZSerializer();
      addTearDown(ser.dispose);
      expect(
        () => ser.serializeInt8(200),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('-128..127'),
          ),
        ),
      );
    });

    test('a negative into an unsigned width is refused', () {
      final ser = ZSerializer();
      addTearDown(ser.dispose);
      // Before the guard this reached the native uint16_t parameter and
      // wrapped to the two all-ones octets.
      expect(
        () => ser.serializeUint16(-1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('0..65535'),
          ),
        ),
      );
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(
        bytes.toBytes(),
        isEmpty,
        reason: 'the refused call reached native code and wrote octets',
      );
    });

    test('in-domain boundary values still pass, bytes unchanged', () {
      // The bytes asserted here are the ones the pre-guard surface produced
      // for the same calls, so the guard is shown to have left the wire
      // format alone.
      expect(
        encoded(
          (s) => s
            ..serializeUint8(0)
            ..serializeUint8(255),
        ),
        equals([0, 255]),
        reason: 'uint8 extremes',
      );
      expect(
        encoded(
          (s) => s
            ..serializeUint16(0)
            ..serializeUint16(65535),
        ),
        equals([0, 0, 255, 255]),
        reason: 'uint16 extremes, little-endian',
      );
      expect(
        encoded(
          (s) => s
            ..serializeUint32(0)
            ..serializeUint32(4294967295),
        ),
        equals([0, 0, 0, 0, 255, 255, 255, 255]),
        reason: 'uint32 extremes, little-endian',
      );
      expect(
        encoded(
          (s) => s
            ..serializeInt8(-128)
            ..serializeInt8(127)
            ..serializeInt8(-1)
            ..serializeInt8(0)
            ..serializeInt8(1),
        ),
        equals([128, 127, 255, 0, 1]),
        reason: 'int8 extremes plus the sign hinge',
      );
      expect(
        encoded(
          (s) => s
            ..serializeInt16(-32768)
            ..serializeInt16(32767)
            ..serializeInt16(-1)
            ..serializeInt16(0)
            ..serializeInt16(1),
        ),
        equals([
          0, 128, // -32768
          255, 127, // 32767
          255, 255, // -1
          0, 0, // 0
          1, 0, // 1
        ]),
        reason: 'int16 extremes plus the sign hinge, little-endian',
      );
      expect(
        encoded(
          (s) => s
            ..serializeInt32(-2147483648)
            ..serializeInt32(2147483647)
            ..serializeInt32(-1)
            ..serializeInt32(0)
            ..serializeInt32(1),
        ),
        equals([
          0, 0, 0, 128, // -2147483648
          255, 255, 255, 127, // 2147483647
          255, 255, 255, 255, // -1
          0, 0, 0, 0, // 0
          1, 0, 0, 0, // 1
        ]),
        reason: 'int32 extremes plus the sign hinge, little-endian',
      );
    });

    test('uint64 is unguarded, and the reason is that it cannot be', () {
      // Every Dart int is a valid 64-bit pattern, so uint64 has no
      // out-of-range value to reject. A value above 2^63 is carried as its
      // bit-exact two's complement -- the only Dart-representable form, and
      // not a transform. Guarding this width would reject values that are
      // in domain.
      const allOnes = -1; // UINT64_MAX's bit pattern in a signed Dart int.
      expect(
        encoded((s) => s.serializeUint64(allOnes)),
        equals([255, 255, 255, 255, 255, 255, 255, 255]),
      );
    });

    test('float narrows by rounding, not by rejecting', () {
      // An integer width has an exactly-representable domain, so a value
      // outside it is a caller error. A binary floating width has no such
      // domain: every finite f64 has a defined nearest binary32 under
      // IEEE-754, so this narrowing is a specified rounding and not an
      // out-of-domain wrap. Canon's own
      // `ze_serializer_serialize_float(float)` performs the identical
      // narrowing at the ABI. Hence float documents and pins where the
      // integer widths reject.
      const value = 0.1;
      expect(
        Float32List.fromList([value])[0],
        isNot(equals(value)),
        reason: 'the chosen value must not be exactly representable in f32',
      );
      final expected = ByteData(4)..setFloat32(0, value, Endian.little);
      expect(
        encoded((s) => s.serializeFloat(value)),
        equals(expected.buffer.asUint8List()),
      );
    });

    test('the pre-guard uint8 wrap is gone (behaviour-breaking)', () {
      // Behaviour-breaking on shipped surface, and deliberately so: before
      // this guard, serializeUint8(300) wrote 300 mod 256 to the wire, and
      // a caller could have been relying on that octet. Source-compatible
      // -- no signature changed -- but the value behaviour did.
      const wrappedOctet = 300 % 256;
      expect(
        wrappedOctet,
        equals(44),
        reason: 'the octet the pre-guard surface emitted for 300',
      );
      final ser = ZSerializer();
      addTearDown(ser.dispose);
      expect(() => ser.serializeUint8(300), throwsArgumentError);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);
      expect(
        bytes.toBytes(),
        isEmpty,
        reason: 'the wrapped octet was still written to the wire',
      );
    });
  });

  // --- Seed [D1] slice 17: deserializeString promises what canon does ---
  group('[D1] S17 — deserializeString tells the truth', () {
    /// See `open_detail_secrets_test.dart` for why prose is read flattened.
    String flattenedProse(String path) =>
        File(path)
            .readAsStringSync()
            .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
            .replaceAll('*', '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .toLowerCase();

    test(
      'invalid UTF-8 in the string slot throws rather than producing U+FFFD',
      () {
        // ⛔ THE DRIVER IS THE NON-VALIDATING WRITER, and that is the only way
        // to reach this at all. Canon's `ze_serializer_serialize_string`
        // VALIDATES on the way in and returns Z_EUTF8, while
        // `ze_serializer_serialize_slice` takes raw bytes -- and the two emit
        // the same length-prefixed byte run. So bytes written as a slice and
        // read as a string is the reachable shape.
        final serializer = ZSerializer()
          ..serializeBytes(Uint8List.fromList([0xFF, 0xFE, 0x41, 0x80]));
        final deserializer = ZDeserializer(serializer.finish());
        try {
          expect(
            deserializer.deserializeString,
            throwsA(
              isA<ZenohException>()
                  .having((e) => e.returnCode, 'returnCode', -7)
                  .having(
                    (e) => e.codeNames,
                    'codeNames',
                    ['Z_EDESERIALIZE'],
                  ),
            ),
            reason:
                'canon deserializes into a Rust String, which validates; '
                'the binding must surface that refusal rather than smuggling '
                'a replacement character past it',
          );
        } finally {
          deserializer.dispose();
        }
      },
    );

    test('the dartdoc states the true contract', () {
      final doc = flattenedProse('lib/src/deserializer.dart');
      expect(doc, contains('z_edeserialize'));
      expect(
        doc,
        contains('does not return u+fffd'),
        reason:
            'the promise it used to make is the thing being corrected, so '
            'the correction has to be explicit rather than a deletion',
      );
      expect(
        doc,
        contains('unreachable'),
        reason:
            'the lenient decode is retained BECAUSE it is unreachable, '
            'not despite it — a reader who does not know that will either '
            'delete it as dead code or re-document it as a promise',
      );
    });

    test('valid multi-byte content still round-trips exactly', () {
      // Correcting the promise must not weaken the working path.
      const value = '日本語-Ω-ünïcødé';
      final serializer = ZSerializer()..serializeString(value);
      final deserializer = ZDeserializer(serializer.finish());
      try {
        expect(deserializer.deserializeString(), value);
        expect(deserializer.isDone, isTrue);
      } finally {
        deserializer.dispose();
      }
    });

    // --- Edge cases ---

    test('an empty string round-trips as empty, not as a failure', () {
      // Exercises the `len == 0` early return the fix must not disturb.
      final serializer = ZSerializer()..serializeString('');
      final deserializer = ZDeserializer(serializer.finish());
      try {
        expect(deserializer.deserializeString(), '');
        expect(deserializer.isDone, isTrue);
      } finally {
        deserializer.dispose();
      }
    });

    test('the lenient decode is not removed, and the reason is recorded', () {
      final source = File('lib/src/deserializer.dart').readAsStringSync();
      expect(
        source,
        contains('allowMalformed: true'),
        reason:
            'the defence is retained deliberately, for the day canon '
            'relaxes its validation: deleting it would be a change nobody '
            'measured',
      );
      final doc = flattenedProse('lib/src/deserializer.dart');
      expect(
        doc,
        contains('nor re-documents it as a promise'),
        reason:
            'the comment must say BOTH things it is defending against: a '
            'later reader deleting it as dead code, and a later reader '
            'writing the old promise back',
      );
    });
  });
}
