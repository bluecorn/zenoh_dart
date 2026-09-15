import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Slice 7: ZBytesWriter tests

void main() {
  group('ZBytesWriter', () {
    test('writeAll assembles bytes', () {
      final writer = ZBytesWriter()
        ..writeAll(Uint8List.fromList([0, 1, 2]))
        ..writeAll(Uint8List.fromList([3, 4]));
      final result = writer.finish();
      addTearDown(result.dispose);
      expect(result.toBytes(), equals(Uint8List.fromList([0, 1, 2, 3, 4])));
    });

    test('append assembles ZBytes', () {
      final a = ZBytes.fromString('abc');
      final b = ZBytes.fromString('def');
      final c = ZBytes.fromString('hij');
      final writer = ZBytesWriter()
        ..append(a)
        ..append(b)
        ..append(c);
      final result = writer.finish();
      addTearDown(result.dispose);

      // Concatenation of UTF-8 bytes of "abc", "def", "hij"
      final expected = Uint8List.fromList([
        ...Uint8List.fromList('abc'.codeUnits),
        ...Uint8List.fromList('def'.codeUnits),
        ...Uint8List.fromList('hij'.codeUnits),
      ]);
      expect(result.toBytes(), equals(expected));
    });

    test('mixed write and append', () {
      final writer = ZBytesWriter()..writeAll(Uint8List.fromList([0, 1]));
      final mid = ZBytes.fromString('mid');
      writer
        ..append(mid)
        ..writeAll(Uint8List.fromList([9]));
      final result = writer.finish();
      addTearDown(result.dispose);
      expect(
        result.toBytes(),
        equals(Uint8List.fromList([0, 1, 109, 105, 100, 9])),
      );
    });

    test('append consumes the ZBytes', () {
      final bytes = ZBytes.fromString('test');
      final writer = ZBytesWriter()..append(bytes);
      // The appended ZBytes should be consumed
      expect(bytes.toStr, throwsStateError);
      writer.finish().dispose();
    });

    test('finish then finish throws StateError', () {
      final writer = ZBytesWriter();
      final result = writer.finish();
      addTearDown(result.dispose);
      expect(writer.finish, throwsStateError);
    });

    test('dispose without finish is safe', () {
      final writer = ZBytesWriter();
      expect(writer.dispose, returnsNormally);
    });
  });
}
