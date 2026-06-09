import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

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
      expect(() => zbytes.dispose(), returnsNormally);
    });

    test('dispose is idempotent (double-drop safe)', () {
      // Given: a ZBytes that has been disposed
      final zbytes = ZBytes.fromString('test');
      zbytes.dispose();

      // When: zbytes.dispose() is called again
      // Then: no exception is thrown
      expect(() => zbytes.dispose(), returnsNormally);
    });

    test('from string with unicode content', () {
      // Given: a string "hello world"
      // When: ZBytes.fromString("hello world") is created and .toStr() is called
      final zbytes = ZBytes.fromString('hello world');
      final result = zbytes.toStr();

      // Then: the returned string equals "hello world"
      expect(result, equals('hello world'));
      zbytes.dispose();
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
      // When: ZBytes.fromUint8List(Uint8List(0)) is created and .toStr() is called
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
      final bytes = ZBytes.fromString('hello');
      bytes.dispose();
      expect(() => bytes.toStr(), throwsStateError);
    });

    test('toStr can be called multiple times', () {
      final bytes = ZBytes.fromString('reuse me');
      expect(bytes.toStr(), equals('reuse me'));
      expect(bytes.toStr(), equals('reuse me'));
      expect(bytes.toStr(), equals('reuse me'));
      bytes.dispose();
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
      final zbytes = ZBytes.fromString('test');
      zbytes.dispose();

      // When/Then: toBytes() throws StateError
      expect(() => zbytes.toBytes(), throwsStateError);
    });

    test('on consumed ZBytes throws StateError', () {
      // Given: a consumed ZBytes
      final zbytes = ZBytes.fromString('test');
      zbytes.markConsumed();

      // When/Then: toBytes() throws StateError
      expect(() => zbytes.toBytes(), throwsStateError);
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
      // Given: a ZBytes built from invalid-UTF-8 binary [0x00,0xFF,0xFE,0x80,0x41]
      final data = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41]);
      final zbytes = ZBytes.fromUint8List(data);

      // When: toBytes() is called
      final result = zbytes.toBytes();

      // Then: result == exactly the stored bytes (rc-checked reader; no
      // trailing uninitialized bytes from a short read).
      expect(result, equals(Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x41])));
      expect(result.length, equals(5));
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
      final b = a.clone();
      b.dispose();
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
      final zbytes = ZBytes.fromString('disposed');
      zbytes.dispose();

      // When/Then: clone() throws StateError
      expect(() => zbytes.clone(), throwsStateError);
    });

    test('clone on consumed throws StateError', () {
      // Given: a consumed ZBytes
      final zbytes = ZBytes.fromString('consumed');
      zbytes.markConsumed();

      // When/Then: clone() throws StateError
      expect(() => zbytes.clone(), throwsStateError);
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
      // Given: ZSerializer serializes uint32(42) then string("extra"), finishes to ZBytes
      final ser = ZSerializer();
      ser.serializeUint32(42);
      ser.serializeString('extra');
      final zbytes = ser.finish();
      ser.dispose();

      // When: toInt() is called on the resulting ZBytes
      // Then: throws ZenohException (extra data remains)
      expect(() => zbytes.toInt(), throwsA(isA<ZenohException>()));

      zbytes.dispose();
    });

    test('fromInt with negative value round-trips (min int64)', () {
      // Given: no preconditions
      // When: ZBytes.fromInt(-9223372036854775808) is created, then toInt() is called
      final zbytes = ZBytes.fromInt(-9223372036854775808);
      final result = zbytes.toInt();

      // Then: returns -9223372036854775808
      expect(result, equals(-9223372036854775808));
      zbytes.dispose();
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
      final writer = ZBytesWriter();
      writer.append(ZBytes.fromString('abc'));
      writer.append(ZBytes.fromString('def'));
      writer.append(ZBytes.fromString('hij'));
      final zbytes = writer.finish();
      writer.dispose();

      // When: slices is iterated on the finished result
      final result = zbytes.slices.toList();

      // Then: yields >=1 elements whose concatenation equals UTF-8 of "abcdefhij"
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

  group('Barrel export', () {
    test('provides all public types', () {
      // Given: the zenoh package is imported via package:zenoh/zenoh.dart
      // When: the types Config, Session, KeyExpr, ZBytes, ZenohException
      //       are referenced
      // Then: all types are accessible (test compiles and runs)
      expect(Config, isNotNull);
      expect(Session, isNotNull);
      expect(KeyExpr, isNotNull);
      expect(ZBytes, isNotNull);
      expect(ZenohException, isNotNull);
    });
  });
}
