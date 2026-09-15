import 'dart:io';
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

/// Number of sections that failed.
///
/// canon compiles with `#undef NDEBUG` and asserts, so any mismatch aborts the
/// process. Printing `FAIL` and still exiting 0 would be the false-green shape
/// -- a CI job watching the exit code would never see it.
int failures = 0;

void check({required bool pass, required String name}) {
  if (!pass) failures++;
  print('  ${pass ? "PASS" : "FAIL"}: $name');
}

void main() {
  // Section 1: Raw bytes and string round-trips
  {
    // Raw bytes
    final inputBytes = Uint8List.fromList([1, 2, 3, 4]);
    final payload = ZBytes.fromUint8List(inputBytes);
    final outputBytes = payload.toBytes();
    check(
      pass: _listEquals(inputBytes, outputBytes),
      name: 'raw bytes round-trip',
    );
    payload.dispose();
  }
  {
    // String
    const inputStr = 'test';
    final payload = ZBytes.fromString(inputStr);
    final outputStr = payload.toStr();
    check(pass: inputStr == outputStr, name: 'string round-trip');
    payload.dispose();
  }

  // Section 2: Single-value serialization round-trips
  {
    // Int
    const inputInt = 1234;
    final payload = ZBytes.fromInt(inputInt);
    final outputInt = payload.toInt();
    check(pass: inputInt == outputInt, name: 'int round-trip');
    payload.dispose();
  }
  {
    // Double
    const inputDouble = 3.14;
    final payload = ZBytes.fromDouble(inputDouble);
    final outputDouble = payload.toDouble();
    check(pass: inputDouble == outputDouble, name: 'double round-trip');
    payload.dispose();
  }
  {
    // Bool
    const inputBool = true;
    final payload = ZBytes.fromBool(inputBool);
    final outputBool = payload.toBool();
    check(pass: inputBool == outputBool, name: 'bool round-trip');
    payload.dispose();
  }

  // Section 3: Serializer/Deserializer with arithmetic types, strings, bytes
  {
    final ser = ZSerializer()
      ..serializeUint32(42)
      ..serializeDouble(2.718)
      ..serializeString('hello')
      ..serializeBytes(Uint8List.fromList([10, 20, 30]));
    final payload = ser.finish();
    ser.dispose();

    final deser = ZDeserializer(payload);
    final u32 = deser.deserializeUint32();
    final d = deser.deserializeDouble();
    final s = deser.deserializeString();
    final b = deser.deserializeBytes();
    deser.dispose();
    payload.dispose();

    check(
      pass:
          u32 == 42 &&
          d == 2.718 &&
          s == 'hello' &&
          _listEquals(b, Uint8List.fromList([10, 20, 30])),
      name: 'serializer/deserializer multi-value',
    );
  }

  // Section 4a: Composite -- sequence of primitive types (canon z_bytes.c:93)
  {
    final inputVec = [1, 2, 3, 4];

    final ser = ZSerializer()..serializeSequenceLength(inputVec.length);
    inputVec.forEach(ser.serializeInt32);
    final payload = ser.finish();
    ser.dispose();

    final deser = ZDeserializer(payload);
    final numElements = deser.deserializeSequenceLength();
    final outputVec = [
      for (var i = 0; i < numElements; i++) deser.deserializeInt32(),
    ];
    deser.dispose();
    payload.dispose();

    var pass = numElements == inputVec.length;
    for (var i = 0; i < inputVec.length && pass; i++) {
      pass = inputVec[i] == outputVec[i];
    }
    check(pass: pass, name: 'composite int32 sequence');
  }

  // Section 4b: Composite -- sequence of key-value pairs
  {
    final kvs = [(0, 'abc'), (1, 'def')];

    final ser = ZSerializer()..serializeSequenceLength(kvs.length);
    for (final (key, value) in kvs) {
      ser
        ..serializeInt32(key)
        ..serializeString(value);
    }
    final payload = ser.finish();
    ser.dispose();

    final deser = ZDeserializer(payload);
    final numElements = deser.deserializeSequenceLength();
    final outputKvs = <(int, String)>[];
    for (var i = 0; i < numElements; i++) {
      final key = deser.deserializeInt32();
      final value = deser.deserializeString();
      outputKvs.add((key, value));
    }
    deser.dispose();
    payload.dispose();

    var pass = numElements == kvs.length;
    for (var i = 0; i < kvs.length && pass; i++) {
      pass = kvs[i].$1 == outputKvs[i].$1 && kvs[i].$2 == outputKvs[i].$2;
    }
    check(pass: pass, name: 'composite key-value sequence');
  }

  // Section 4c: Custom struct -- float, nested 2x3 uint64 sequences, string
  // (canon z_bytes.c:156-197). Serde is positional and tagless, so nesting is
  // expressed purely by the order of sequence lengths.
  {
    const inputFloat = 1.0;
    const inputMatrix = [
      [1, 2, 3],
      [4, 5, 6],
    ];
    const inputStr = 'test';

    final ser = ZSerializer()
      ..serializeFloat(inputFloat)
      ..serializeSequenceLength(inputMatrix.length);
    for (final row in inputMatrix) {
      ser.serializeSequenceLength(row.length);
      row.forEach(ser.serializeUint64);
    }
    ser.serializeString(inputStr);
    final payload = ser.finish();
    ser.dispose();

    final deser = ZDeserializer(payload);
    final outputFloat = deser.deserializeFloat();
    final rows = deser.deserializeSequenceLength();
    final outputMatrix = <List<int>>[];
    for (var i = 0; i < rows; i++) {
      final cols = deser.deserializeSequenceLength();
      outputMatrix.add([
        for (var j = 0; j < cols; j++) deser.deserializeUint64(),
      ]);
    }
    final outputStr = deser.deserializeString();
    final done = deser.isDone;
    deser.dispose();
    payload.dispose();

    var pass =
        outputFloat == inputFloat &&
        outputStr == inputStr &&
        done &&
        outputMatrix.length == inputMatrix.length;
    for (var i = 0; i < inputMatrix.length && pass; i++) {
      pass = _listEquals(
        Uint8List.fromList(inputMatrix[i]),
        Uint8List.fromList(outputMatrix[i]),
      );
    }
    check(pass: pass, name: 'custom struct (float, nested sequences, string)');
  }

  // Section 5: ZBytesWriter -- writeAll and append
  {
    final writer = ZBytesWriter()
      ..writeAll(Uint8List.fromList([0, 1, 2]))
      ..writeAll(Uint8List.fromList([3, 4]));
    final payload = writer.finish();
    writer.dispose();

    final output = payload.toBytes();
    payload.dispose();

    final expected = Uint8List.fromList([0, 1, 2, 3, 4]);
    check(pass: _listEquals(output, expected), name: 'writer writeAll');
  }
  {
    final b1 = ZBytes.fromUint8List(
      Uint8List.fromList([0x61, 0x62, 0x63]),
    ); // "abc"
    final b2 = ZBytes.fromUint8List(
      Uint8List.fromList([0x64, 0x65, 0x66]),
    ); // "def"
    final b3 = ZBytes.fromUint8List(
      Uint8List.fromList([0x68, 0x69, 0x6a]),
    ); // "hij"

    final writer = ZBytesWriter()
      ..append(b1)
      ..append(b2)
      ..append(b3);
    final payload = writer.finish();
    writer.dispose();

    final output = payload.toBytes();
    payload.dispose();

    final expected = Uint8List.fromList([
      0x61,
      0x62,
      0x63,
      0x64,
      0x65,
      0x66,
      0x68,
      0x69,
      0x6a,
    ]);
    check(pass: _listEquals(output, expected), name: 'writer append');
  }

  // Section 6: Slice iterator
  {
    final b1 = ZBytes.fromString('abc');
    final b2 = ZBytes.fromString('def');
    final b3 = ZBytes.fromString('hij');

    final writer = ZBytesWriter()
      ..append(b1)
      ..append(b2)
      ..append(b3);
    final payload = writer.finish();
    writer.dispose();

    final slices = payload.slices.toList();
    payload.dispose();

    // canon prints each slice's length and bytes -- the point of the section is
    // that three appended payloads stay three slices. Asserting only
    // "at least one slice, right total content" would pass on a coalescing
    // regression, which is precisely what this demonstrates the absence of.
    for (final slice in slices) {
      final hex = slice.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}');
      print("  slice len: ${slice.length}, slice data: '${hex.join(' ')} '");
    }

    final totalContent = slices.fold<List<int>>([], (acc, s) => acc..addAll(s));
    final expected = [0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x68, 0x69, 0x6a];
    check(
      pass:
          slices.length == 3 &&
          _listEquals(
            Uint8List.fromList(totalContent),
            Uint8List.fromList(expected),
          ),
      name: 'slice iterator (3 distinct slices)',
    );
  }

  // Section 7: the single-shot conversions for every scalar width.
  //
  // canon's own z_bytes.c uses the ONE-SHOT family for exactly this
  // (`ze_serialize_uint32` at :69). Before seed #10 only int64, binary64 and
  // bool had a single-shot form here, so the other eight widths were reachable
  // only through the streaming serializer.
  {
    var ok = true;
    // Each width at both ends of its domain, so a truncation or a sign error
    // shows rather than passing on a mid-range value.
    ok = ok && ZBytes.fromUint8(255).let((p) => p.toUint8() == 255);
    ok = ok && ZBytes.fromUint16(65535).let((p) => p.toUint16() == 65535);
    ok =
        ok &&
        ZBytes.fromUint32(4294967295).let(
          (p) => p.toUint32() == 4294967295,
        );
    ok = ok && ZBytes.fromInt8(-128).let((p) => p.toInt8() == -128);
    ok = ok && ZBytes.fromInt16(-32768).let((p) => p.toInt16() == -32768);
    ok =
        ok &&
        ZBytes.fromInt32(-2147483648).let(
          (p) => p.toInt32() == -2147483648,
        );
    check(pass: ok, name: 'single-shot integer widths round-trip');
  }
  {
    // f32 narrows under IEEE-754 rather than rejecting, so the round-trip is
    // to the NEAREST binary32 — not to the original f64. Asserting equality
    // with 0.1 would be wrong, and asserting nothing would be vacuous.
    final narrowed = Float32List.fromList([0.1])[0];
    final payload = ZBytes.fromFloat(0.1);
    final back = payload.toFloat();
    payload.dispose();
    check(
      pass: back == narrowed,
      name: 'single-shot float narrows to binary32',
    );
  }
  {
    // uint64 above 2^63 is carried as bit-exact two's complement — the only
    // Dart-representable form, and not a transform.
    final payload = ZBytes.fromUint64(-1);
    final back = payload.toUint64();
    payload.dispose();
    check(pass: back == -1, name: 'single-shot uint64 is bit-exact');
  }

  // Section 8: the encoding's two channels, and its three schema states.
  //
  // canon's z_bytes.c only MENTIONS the corresponding encoding constants in
  // comments (:49-50, :60-61, :73-74); it never demonstrates the schema. The
  // three states are what this seed made expressible.
  {
    const absent = Encoding.applicationJson;
    final empty = absent.withSchema('');
    final present = absent.withSchema('my-schema');

    // Absent, present-but-empty, present — three distinct values, and the
    // rendered forms differ by exactly the trailing separator.
    final distinct =
        absent.schema == null &&
        empty.schema == '' &&
        present.schema == 'my-schema';
    final rendered =
        absent.toString() == 'application/json' &&
        empty.toString() == 'application/json;' &&
        present.toString() == 'application/json;my-schema';
    check(
      pass: distinct && rendered,
      name: 'encoding schema: absent, empty and present are distinct',
    );

    // The derived getter reads a schema out of a composed MIME string, and an
    // explicit one wins over it.
    const composed = Encoding('application/json;from-mime');
    final overridden = composed.withSchema('explicit');
    check(
      pass:
          composed.schema == 'from-mime' &&
          overridden.schema == 'explicit' &&
          overridden.toString() == 'application/json;explicit',
      name: 'encoding schema: derived getter, and explicit wins',
    );

    // The predefined table is canon's own 53, not a subset.
    check(
      pass:
          Encoding.applicationCbor.mimeType == 'application/cbor' &&
          Encoding.textJson5.mimeType == 'text/json5',
      name: "encoding constants: canon's table, beyond the original ten",
    );
  }

  if (failures > 0) {
    print('$failures section(s) FAILED');
    exit(1);
  }
}

/// Runs `body` over a payload and disposes it, whatever the outcome.
///
/// The single-shot section builds and drops a payload per width; without this
/// the section would be twenty lines of identical try/finally.
extension _Scoped on ZBytes {
  bool let(bool Function(ZBytes) body) {
    try {
      return body(this);
    } finally {
      dispose();
    }
  }
}

/// Compares two [Uint8List] for element-wise equality.
bool _listEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
