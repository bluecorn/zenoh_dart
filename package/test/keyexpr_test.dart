import 'dart:convert';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';

/// The interior NUL used across the fidelity legs.
///
/// Built with [String.fromCharCode] rather than written as a source escape so
/// that no raw NUL byte can ever reach this file: a raw NUL makes `grep`
/// classify the whole file as binary and silently suppress every match in it
/// (measured by the seed review, finding F5-3).
final String nul = String.fromCharCode(0);

void main() {
  group('KeyExpr round-trip', () {
    test('simple expression', () {
      final ke = KeyExpr('demo/test');
      expect(ke.value, equals('demo/test'));
      ke.dispose();
    });

    test('hierarchical expression', () {
      final ke = KeyExpr('demo/example/zenoh-dart/test');
      expect(ke.value, equals('demo/example/zenoh-dart/test'));
      ke.dispose();
    });

    test('single wildcard', () {
      final ke = KeyExpr('demo/*');
      expect(ke.value, equals('demo/*'));
      ke.dispose();
    });

    test('double wildcard', () {
      final ke = KeyExpr('demo/**');
      expect(ke.value, equals('demo/**'));
      ke.dispose();
    });

    test('single segment (no slash)', () {
      final ke = KeyExpr('test');
      expect(ke.value, equals('test'));
      ke.dispose();
    });

    test('empty string throws ZenohException', () {
      expect(() => KeyExpr(''), throwsA(isA<ZenohException>()));
    });

    test('dispose releases resources', () {
      final ke = KeyExpr('demo/test');
      expect(ke.dispose, returnsNormally);
    });

    test('dispose is idempotent', () {
      final ke = KeyExpr('demo/test')..dispose();
      expect(ke.dispose, returnsNormally);
    });

    test('value after dispose throws StateError', () {
      final ke = KeyExpr('demo/test')..dispose();
      expect(() => ke.value, throwsStateError);
    });
  });

  group('KeyExpr.intersects', () {
    test('exact match intersects', () {
      final a = KeyExpr('demo/example/test');
      final b = KeyExpr('demo/example/test');
      expect(a.intersects(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('double-wildcard intersects specific', () {
      final a = KeyExpr('demo/**');
      final b = KeyExpr('demo/example/test');
      expect(a.intersects(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('single-level wildcard intersects', () {
      final a = KeyExpr('demo/*/test');
      final b = KeyExpr('demo/example/test');
      expect(a.intersects(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('non-matching does not intersect', () {
      final a = KeyExpr('demo/a');
      final b = KeyExpr('demo/b');
      expect(a.intersects(b), isFalse);
      a.dispose();
      b.dispose();
    });

    test('disjoint paths do not intersect', () {
      final a = KeyExpr('demo/example');
      final b = KeyExpr('other/path');
      expect(a.intersects(b), isFalse);
      a.dispose();
      b.dispose();
    });
  });

  group('KeyExpr.includes', () {
    test('wildcard includes specific', () {
      final a = KeyExpr('demo/**');
      final b = KeyExpr('demo/example/test');
      expect(a.includes(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('specific does not include wildcard', () {
      final a = KeyExpr('demo/example/test');
      final b = KeyExpr('demo/**');
      expect(a.includes(b), isFalse);
      a.dispose();
      b.dispose();
    });

    test('exact includes itself', () {
      final a = KeyExpr('demo/example');
      final b = KeyExpr('demo/example');
      expect(a.includes(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('disjoint does not include', () {
      final a = KeyExpr('demo/a');
      final b = KeyExpr('demo/b');
      expect(a.includes(b), isFalse);
      a.dispose();
      b.dispose();
    });
  });

  group('KeyExpr.equals', () {
    test('identical expressions are equal', () {
      final a = KeyExpr('demo/example');
      final b = KeyExpr('demo/example');
      expect(a.equals(b), isTrue);
      a.dispose();
      b.dispose();
    });

    test('different expressions are not equal', () {
      final a = KeyExpr('demo/a');
      final b = KeyExpr('demo/b');
      expect(a.equals(b), isFalse);
      a.dispose();
      b.dispose();
    });

    test('wildcard not equal to specific', () {
      final a = KeyExpr('demo/**');
      final b = KeyExpr('demo/example');
      expect(a.equals(b), isFalse);
      a.dispose();
      b.dispose();
    });
  });

  // Slice 1 -- the construction path is length-carried, so the key expression
  // domain canon actually accepts (interior NUL included, measured at Probe 1)
  // survives construction byte-exact. Comparison is at Uint8List level: a
  // `String ==` cannot tell a truncated value from a carried one when the
  // truncation happens to land on a valid prefix.
  group('KeyExpr fidelity -- construction round-trip', () {
    test('interior NUL survives construction byte-exact', () {
      final ke = KeyExpr('a${nul}b');
      expect(utf8.encode(ke.value), equals([97, 0, 98]));
      ke.dispose();
    });

    test('interior NUL survives in a multi-segment expression', () {
      final ke = KeyExpr('de${nul}mo/x');
      expect(utf8.encode(ke.value), equals([100, 101, 0, 109, 111, 47, 120]));
      ke.dispose();
    });

    test('a leading NUL is carried', () {
      final ke = KeyExpr('${nul}a');
      expect(utf8.encode(ke.value), equals([0, 97]));
      ke.dispose();
    });

    test('a trailing NUL is carried', () {
      final ke = KeyExpr('a$nul');
      expect(utf8.encode(ke.value), equals([97, 0]));
      ke.dispose();
    });

    test('the non-ASCII contract domain round-trips byte-exact', () {
      // The control for the length-carried entry: every one of these is in
      // canon's domain (Probe 5 / Probe 6) and its UTF-8 byte length differs
      // from its `String.length` for each non-ASCII member.
      const domain = <String>[
        'demo/example/test',
        'demo/*/test',
        'demo/**',
        r'demo/exam$*',
        'デモ/例/テスト',
        'demo/mesure/température',
        'demo/emoji/🚀',
        'demo/ü/ß',
        'a',
        'demo/ /x',
      ];
      for (final expr in domain) {
        final ke = KeyExpr(expr);
        expect(
          utf8.encode(ke.value),
          equals(utf8.encode(expr)),
          reason: 'round-trip failed for "$expr"',
        );
        ke.dispose();
      }
    });
  });

  group('KeyExpr fidelity -- edge cases', () {
    test('an invalid expression still throws with canon own code', () {
      const invalid = <String>[
        '',
        'demo//x',
        '/demo/x',
        'demo/x/',
        'demo/x?y',
        'demo/x#y',
        r'demo/$*/test',
      ];
      for (final expr in invalid) {
        expect(
          () => KeyExpr(expr),
          throwsA(
            isA<ZenohException>().having(
              (e) => e.returnCode,
              'returnCode',
              -1,
            ),
          ),
          reason: 'expected Z_EINVAL for "$expr"',
        );
      }
    });

    test('a disposed operand is rejected on either side', () {
      final live = KeyExpr('demo/example/test');
      final dead = KeyExpr('demo/**')..dispose();

      expect(() => dead.intersects(live), throwsStateError);
      expect(() => live.intersects(dead), throwsStateError);

      live.dispose();
    });

    test('a NUL-only expression is accepted, matching canon', () {
      // Probe 1, U-1e: canon admits it. The binding does not invent a stricter
      // domain than the contract has.
      final ke = KeyExpr(nul);
      expect(utf8.encode(ke.value), equals([0]));
      ke.dispose();
    });
  });
}
