import 'package:test/test.dart';
// encodingWireChannels is hidden from the public zenoh.dart export, so
// the send-site view of it is only reachable through the src library --
// which is how send sites under lib/src/ reach it too.
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Encoding', () {
    test('predefined constants have correct MIME types', () {
      expect(Encoding.zenohBytes.mimeType, equals('zenoh/bytes'));
      expect(Encoding.zenohString.mimeType, equals('zenoh/string'));
      expect(Encoding.textPlain.mimeType, equals('text/plain'));
      expect(Encoding.applicationJson.mimeType, equals('application/json'));
      expect(
        Encoding.applicationOctetStream.mimeType,
        equals('application/octet-stream'),
      );
      expect(
        Encoding.applicationProtobuf.mimeType,
        equals('application/protobuf'),
      );
      expect(Encoding.textHtml.mimeType, equals('text/html'));
      expect(Encoding.textCsv.mimeType, equals('text/csv'));
      expect(Encoding.imagePng.mimeType, equals('image/png'));
      expect(Encoding.imageJpeg.mimeType, equals('image/jpeg'));
    });

    test('custom constructor accepts arbitrary MIME type', () {
      const encoding = Encoding('application/x-custom');
      expect(encoding.mimeType, equals('application/x-custom'));
    });

    test('toString returns the MIME type string', () {
      expect(Encoding.textPlain.toString(), equals('text/plain'));
      expect(
        const Encoding('application/x-custom').toString(),
        equals('application/x-custom'),
      );
    });

    test('equality works for same MIME type', () {
      // The MIME string is assembled at runtime so neither Encoding can be
      // canonicalized into the other: two const invocations would collapse to
      // a single instance and the comparison would succeed on identity alone,
      // never exercising operator==.
      final mime = ['text', 'plain'].join('/');
      final a = Encoding(mime);
      final b = Encoding(mime);
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
    });

    test('withSchema round-trips a plain ASCII schema', () {
      final e = Encoding.textPlain.withSchema('utf-8');
      expect(e.schema, equals('utf-8'));
      // withSchema is value-style: it returns a NEW Encoding and leaves the
      // mime channel untouched. The two channels are independent.
      expect(e.mimeType, equals('text/plain'));
      expect(Encoding.textPlain.schema, isNull);
    });

    test('withSchema round-trips a multi-byte UTF-8 schema', () {
      // Multi-byte code points must survive the pure-Dart value round-trip
      // unaltered. Compared code unit for code unit, not by rendering, so a
      // replacement-character substitution could not hide behind equality of
      // printed forms.
      const multiByte = 'schéma-Ω-\u{1F600}';
      final e = Encoding.applicationJson.withSchema(multiByte);
      expect(e.schema, equals(multiByte));
      expect(e.schema?.codeUnits, equals(multiByte.codeUnits));
    });

    test('withSchema round-trips a schema containing an interior NUL', () {
      // U+0000 is VALID UTF-8, so this is the valid-UTF-8 boundary cell and
      // stays distinct from any invalid-UTF-8 vector. The control byte is
      // BUILT at runtime, never spelled in source: a raw NUL in a tracked
      // file turns the whole file binary to grep.
      final withNul = 'a${String.fromCharCode(0)}b';
      final e = Encoding.applicationOctetStream.withSchema(withNul);
      expect(e.schema, equals(withNul));
      expect(e.schema?.length, equals(3));
      expect(e.schema?.codeUnitAt(1), equals(0));
    });

    test('the three schema states are distinct at the Dart surface', () {
      // Canon has three states: absent (no schema field set -- canon decides),
      // present-but-empty, and present. Null stands for exactly one of them.
      const absent = Encoding.textPlain;
      final empty = Encoding.textPlain.withSchema('');
      final present = Encoding.textPlain.withSchema('utf-8');
      expect(absent.schema, isNull);
      expect(empty.schema, equals(''));
      expect(present.schema, equals('utf-8'));
      expect(absent, isNot(equals(empty)));
      expect(empty, isNot(equals(present)));
      expect(absent, isNot(equals(present)));
    });

    test('the getter derives a schema from a composed MIME string', () {
      const e = Encoding('application/json;my-schema');
      expect(e.schema, equals('my-schema'));
      // The constructor does not split: mimeType is what was handed in.
      expect(e.mimeType, equals('application/json;my-schema'));
    });

    test('the derived split is on the first separator', () {
      // This is a Dart-side DISPLAY convention, NOT a mirror of canon's parse.
      // Measured: canon's from_substr('foo/bar;old') stores id 65535 with
      // schema 'foo/bar;old' -- the whole string, unsplit -- for a custom id.
      // The behaviour asserted here is right; the reason "canon splits at the
      // first separator" would be false.
      const e = Encoding('foo/bar;a;b');
      expect(e.schema, equals('a;b'));
    });

    test('a composed string ending in a separator reads as empty', () {
      const e = Encoding('foo/bar;');
      expect(e.schema, isNotNull);
      expect(e.schema, equals(''));
    });

    test('an explicit schema wins over a derived one', () {
      const composed = Encoding('foo/bar;old');
      expect(composed.withSchema('new').schema, equals('new'));
    });

    test('const-constructibility survives the schema field', () {
      // Two const invocations with identical arguments canonicalize to one
      // instance; that identity IS the proof the constructor is still const.
      // A mime string that is NOT one of the predefined constants, so the
      // identity comes from canonicalizing these two invocations rather than
      // from both resolving to the same static const.
      const a = Encoding('application/x-const-probe');
      const b = Encoding('application/x-const-probe');
      expect(identical(a, b), isTrue);
      const predefined = <Encoding>[
        Encoding.zenohBytes,
        Encoding.zenohString,
        Encoding.textPlain,
        Encoding.applicationJson,
        Encoding.applicationOctetStream,
        Encoding.applicationProtobuf,
        Encoding.textHtml,
        Encoding.textCsv,
        Encoding.imagePng,
        Encoding.imageJpeg,
      ];
      expect(predefined.length, equals(10));
      expect(
        () => predefined.map((e) => e.toString()).toList(),
        returnsNormally,
      );
    });

    test('toString composes the way canon composes', () {
      expect(
        Encoding.textPlain.withSchema('utf-8').toString(),
        equals('text/plain;utf-8'),
      );
      // A bare trailing separator is what makes present-but-empty
      // distinguishable from absent in the rendered form.
      expect(
        Encoding.textPlain.withSchema('').toString(),
        equals('text/plain;'),
      );
      expect(Encoding.textPlain.toString(), equals('text/plain'));
    });

    test('toString does not contradict the wire on a composed mimeType', () {
      // Canon's set_schema_from_substr REPLACES rather than appends, so a
      // naive mimeType + separator + schema would render 'text/plain;old;new'
      // and contradict the 'text/plain;new' the wire actually carries.
      final e = const Encoding('text/plain;old').withSchema('new');
      expect(e.toString(), equals('text/plain;new'));
      expect(e.toString(), isNot(equals('text/plain;old;new')));
    });

    test('structural equality diverges from wire equality', () {
      // These two render identically on the wire ('text/plain;utf-8') and are
      // nonetheless unequal here. Wire equality depends on whether the id is
      // well-known, which needs canon's 53-entry id table and
      // z_encoding_equals -- exactly the native dependency this pure value
      // type deliberately excludes. Approximating it in Dart would be a
      // silent substitution on the surface this work exists to make faithful.
      const composed = Encoding('text/plain;utf-8');
      final built = Encoding.textPlain.withSchema('utf-8');
      expect(composed.toString(), equals(built.toString()));
      expect(composed, isNot(equals(built)));
    });

    test('encodingWireChannels yields the RAW pair, not the derived view', () {
      // What crosses the seam at a send site. mimeType goes out verbatim and
      // the schema channel carries the RAW schema only. Reading the derived
      // getter here would send 'foo/bar' plus an empty schema and the value
      // would arrive as 'foo/bar', where the wire must carry 'foo/bar;'.
      expect(
        encodingWireChannels(Encoding.textPlain),
        equals(('text/plain', null)),
      );
      expect(
        encodingWireChannels(const Encoding('foo/bar;')),
        equals(('foo/bar;', null)),
      );
      expect(
        encodingWireChannels(Encoding.textPlain.withSchema('')),
        equals(('text/plain', '')),
      );
      expect(
        encodingWireChannels(
          const Encoding('text/plain;old').withSchema('new'),
        ),
        equals(('text/plain;old', 'new')),
      );
    });
  });

  group('CongestionControl', () {
    test('has block and drop values with correct indices', () {
      expect(CongestionControl.block.index, equals(0));
      expect(CongestionControl.drop.index, equals(1));
      expect(CongestionControl.block, isNot(equals(CongestionControl.drop)));
    });
  });

  group('Priority', () {
    test('has all seven levels with correct indices', () {
      expect(Priority.realTime.index, equals(0));
      expect(Priority.interactiveHigh.index, equals(1));
      expect(Priority.interactiveLow.index, equals(2));
      expect(Priority.dataHigh.index, equals(3));
      expect(Priority.data.index, equals(4));
      expect(Priority.dataLow.index, equals(5));
      expect(Priority.background.index, equals(6));
      expect(Priority.values.length, equals(7));
    });
  });
}
