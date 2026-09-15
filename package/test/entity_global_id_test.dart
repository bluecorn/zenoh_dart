import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/id.dart';

Uint8List _zidBytes(int fill) {
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = fill;
  }
  return b;
}

void main() {
  group('EntityGlobalId', () {
    test(
      'same zid + same eid are equal, share hashCode, collapse in a Set',
      () {
        final a = EntityGlobalId(ZenohId(_zidBytes(1)), 7);
        final b = EntityGlobalId(ZenohId(_zidBytes(1)), 7);

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));

        final set = {a, b};
        expect(set.length, equals(1));
      },
    );

    test('same zid, different eid are unequal (eid load-bearing)', () {
      final a = EntityGlobalId(ZenohId(_zidBytes(1)), 1);
      final b = EntityGlobalId(ZenohId(_zidBytes(1)), 2);

      expect(a, isNot(equals(b)));
    });

    test('different zid, same eid are unequal', () {
      final a = EntityGlobalId(ZenohId(_zidBytes(1)), 7);
      final b = EntityGlobalId(ZenohId(_zidBytes(2)), 7);

      expect(a, isNot(equals(b)));
    });

    test('eid accessor exposes full uint32 without narrowing', () {
      final zid = ZenohId(_zidBytes(3));
      final id = EntityGlobalId(zid, 0xFFFFFFFF);

      expect(id.eid, equals(4294967295));
      expect(id.zid, equals(zid));
    });
  });
}
