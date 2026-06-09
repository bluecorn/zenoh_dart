import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/src/sample.dart';

void main() {
  group('Sample.attachmentBytes', () {
    // Invalid UTF-8 fixture: lone surrogate-ish / continuation bytes.
    final invalidUtf8 = Uint8List.fromList([0xFF, 0xFE, 0x80]);

    test('exposes exact attachment bytes (no U+FFFD)', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
        attachment: utf8.decode(invalidUtf8, allowMalformed: true),
        attachmentBytes: invalidUtf8,
      );

      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('preserves lenient String view alongside exact bytes', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
        attachment: utf8.decode(invalidUtf8, allowMalformed: true),
        attachmentBytes: invalidUtf8,
      );

      // Lenient decode substitutes U+FFFD; bytes stay exact.
      expect(sample.attachment, isNotNull);
      expect(sample.attachment, contains('�'));
      expect(sample.attachmentBytes, equals([0xFF, 0xFE, 0x80]));
    });

    test('absent attachment is null on both views', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
      );

      expect(sample.attachmentBytes, isNull);
      expect(sample.attachment, isNull);
    });

    test('present-but-empty distinguishable from absent', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        payloadBytes: Uint8List.fromList([104, 101, 108, 108, 111]),
        kind: SampleKind.put,
        attachment: '',
        attachmentBytes: Uint8List(0),
      );

      expect(sample.attachmentBytes, isNotNull);
      expect(sample.attachmentBytes, isEmpty);
    });
  });
}
