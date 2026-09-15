import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart';

import 'helpers/poll.dart';

/// The interior NUL, built rather than escaped so no raw NUL byte reaches this
/// file (a raw NUL makes `grep` treat the whole file as binary).
final String nul = String.fromCharCode(0);

Future<Session> _quietSession() {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  return Session.open(config: config);
}

/// Matches a [ZenohException] carrying exactly [code].
///
/// The codes asserted here are the only two canon emits on these paths --
/// `-1` (Z_EINVAL) for a right operand that is not valid UTF-8, `-128`
/// (Z_EGENERIC) for every other failure, which canon collapses with the
/// reason left in its log. No finer taxonomy is invented.
Matcher throwsZenohCode(int code) => throwsA(
  isA<ZenohException>().having((e) => e.returnCode, 'returnCode', code),
);

void main() {
  group('KeyExpr.concat', () {
    test('the doc-pinned concat', () {
      final foo = KeyExpr('FOO');
      final result = foo.concat('BAR');

      expect(result.value, equals('FOOBAR'));
      // The receiver is unaffected.
      expect(foo.value, equals('FOO'));

      result.dispose();
      foo.dispose();
    });

    test('an interior NUL in the right operand is carried', () {
      final foo = KeyExpr('foo');
      final result = foo.concat('b${nul}c');

      expect(utf8.encode(result.value), equals([102, 111, 111, 98, 0, 99]));

      result.dispose();
      foo.dispose();
    });

    test('an empty right operand is legal and changes nothing', () {
      // The binding must pass a valid non-NULL pointer with length 0:
      // slice::from_raw_parts(NULL, 0) is undefined behaviour in canon.
      final foo = KeyExpr('FOO');
      final result = foo.concat('');

      expect(result.value, equals('FOO'));

      result.dispose();
      foo.dispose();
    });

    test('a segment-splitting concat rejoins across the boundary', () {
      final left = KeyExpr('demo/exam');
      final result = left.concat('ple/x');

      expect(result.value, equals('demo/example/x'));

      result.dispose();
      left.dispose();
    });
  });

  group('KeyExpr.join', () {
    test('the doc-pinned join', () {
      final foo = KeyExpr('FOO');
      final result = foo.join('BAR');

      // The separator is canon's, not the binding's.
      expect(result.value, equals('FOO/BAR'));

      result.dispose();
      foo.dispose();
    });

    test('join accepts both arms of the union', () {
      final foo = KeyExpr('FOO');
      final bar = KeyExpr('BAR');

      final fromString = foo.join('BAR');
      final fromKeyExpr = foo.join(bar);

      expect(fromString.value, equals('FOO/BAR'));
      expect(fromKeyExpr.value, equals('FOO/BAR'));
      // The callee never disposes a caller-owned KeyExpr.
      expect(bar.value, equals('BAR'));

      fromString.dispose();
      fromKeyExpr.dispose();
      bar.dispose();
      foo.dispose();
    });

    test('join keeps a wildcard left operand, unlike concat', () {
      final left = KeyExpr('foo/*');
      final result = left.join('bar');

      expect(result.value, equals('foo/*/bar'));

      result.dispose();
      left.dispose();
    });
  });

  group('composed results are ordinary key expressions', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('a composed result works as a key expression', () async {
      final received = <Sample>[];
      final subscriber = session.declareSubscriber('demo/example/x');
      final sub = subscriber.stream.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        subscriber.close();
      });

      final left = KeyExpr('demo/exam');
      final composed = left.concat('ple/x');
      expect(composed.value, equals('demo/example/x'));

      session.put(composed, 'from-composed');
      await waitUntil(
        () => received.isNotEmpty,
        description: 'the sample published on the composed key expression',
      );
      expect(received.single.keyExpr, equals('demo/example/x'));

      // And as a relation operand.
      final wildcard = KeyExpr('demo/**');
      expect(wildcard.includes(composed), isTrue);
      expect(composed.includes(wildcard), isFalse);

      wildcard.dispose();
      composed.dispose();
      left.dispose();
    });

    test(
      'undeclaring an owned-but-never-declared handle mirrors canon',
      () {
        // A concat result is owned at the canon seam but was never registered
        // on any session -- one of the two unusual input classes the unified
        // type makes type-legal. Unlike the view-backed class, this one does
        // reach canon, and canon takes the value before it checks anything.
        final left = KeyExpr('FOO');
        final composed = left.concat('BAR');

        expect(
          () => session.undeclareKeyExpr(composed),
          throwsZenohCode(-128),
        );
        expect(() => composed.value, throwsStateError);

        left.dispose();
      },
    );
  });

  // ⚠️ MEASURED, and it contradicts this seed's plan. The plan held that
  // `z_keyexpr_clone` takes a loaned source and therefore "clones any backing
  // into an owned result", so one uniform clone path made the aliasing
  // question disappear. It does not: canon clones what the source HOLDS, and
  // a view key expression holds a BORROW of the caller's buffer.
  //
  //   owned source (a concat result), disposed -> clone reads "demo/example/x"
  //   view  source,                 disposed -> clone THREW FormatException
  //   view  source,                 alive    -> clone reads correctly
  //
  // So the view path clones through canon's copying constructor
  // (z_keyexpr_from_substr, "constructs ... by copying a substring") and the
  // owned path through z_keyexpr_clone. The 'lifetimes are independent' leg
  // below is what caught this, exactly as the plan predicted it would -- it
  // just caught canon's semantics rather than an implementation slip.
  group('KeyExpr.clone', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('a clone of a view-backed handle round-trips', () {
      final source = KeyExpr('demo/example/test');
      final copy = source.clone();

      expect(copy.value, equals(source.value));

      copy.dispose();
      source.dispose();
    });

    test('a clone of an owned handle round-trips', () {
      final left = KeyExpr('FOO');
      final owned = left.concat('BAR');
      final copy = owned.clone();

      expect(copy.value, equals('FOOBAR'));

      copy.dispose();
      owned.dispose();
      left.dispose();
    });

    test('a clone of a declared handle round-trips', () {
      final declared = session.declareKeyExpr('zenoh/dart/f5/clone-decl');
      final copy = declared.clone();

      expect(copy.value, equals('zenoh/dart/f5/clone-decl'));

      copy.dispose();
      session.undeclareKeyExpr(declared);
    });

    test('an interior NUL survives cloning', () {
      final source = KeyExpr('a${nul}b');
      final copy = source.clone();

      expect(utf8.encode(copy.value), equals([97, 0, 98]));

      copy.dispose();
      source.dispose();
    });

    test('lifetimes are independent across all three backings', () async {
      final received = <Sample>[];
      final subscriber = session.declareSubscriber('zenoh/dart/f5/cl/**');
      final sub = subscriber.stream.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        subscriber.close();
      });

      final viewSource = KeyExpr('zenoh/dart/f5/cl/view');
      final ownedLeft = KeyExpr('zenoh/dart/f5/cl');
      final ownedSource = ownedLeft.concat('/owned');
      final declaredSource = session.declareKeyExpr('zenoh/dart/f5/cl/decl');

      final fromView = viewSource.clone();
      final fromOwned = ownedSource.clone();
      final fromDeclared = declaredSource.clone();

      // Kill every source. An aliasing clone would be reading freed storage
      // from here on -- which is exactly what this leg exists to catch.
      viewSource.dispose();
      ownedSource.dispose();
      ownedLeft.dispose();
      session.undeclareKeyExpr(declaredSource);

      expect(fromView.value, equals('zenoh/dart/f5/cl/view'));
      expect(fromOwned.value, equals('zenoh/dart/f5/cl/owned'));
      expect(fromDeclared.value, equals('zenoh/dart/f5/cl/decl'));

      final wildcard = KeyExpr('zenoh/dart/f5/cl/**');
      expect(wildcard.includes(fromView), isTrue);
      expect(wildcard.includes(fromOwned), isTrue);
      expect(wildcard.includes(fromDeclared), isTrue);

      session
        ..put(fromView, 'v')
        ..put(fromOwned, 'o')
        ..put(fromDeclared, 'd');

      await waitUntil(
        () => received.length >= 3,
        description: 'all three clones to deliver after their sources died',
      );
      expect(
        received.map((s) => s.payload).toSet(),
        equals(<String>{'v', 'o', 'd'}),
      );

      wildcard.dispose();
      fromView.dispose();
      fromOwned.dispose();
      fromDeclared.dispose();
    });

    test('a clone is independently disposable', () {
      final source = KeyExpr('demo/example');
      final copy = source.clone();

      expect(copy.dispose, returnsNormally);
      expect(copy.dispose, returnsNormally);
      expect(source.value, equals('demo/example'));

      source.dispose();
    });

    test('cloning a dead handle is rejected', () {
      final disposed = KeyExpr('demo/example')..dispose();
      expect(disposed.clone, throwsStateError);

      final declared = session.declareKeyExpr('zenoh/dart/f5/clone-dead');
      session.undeclareKeyExpr(declared);
      expect(declared.clone, throwsStateError);
    });

    test(
      'the clone of a declared handle is itself undeclarable, and undeclaring '
      'it leaves the source alone',
      () {
        final source = session.declareKeyExpr('zenoh/dart/f5/clone');
        final copy = source.clone();

        expect(() => session.undeclareKeyExpr(copy), returnsNormally);
        expect(() => copy.value, throwsStateError);

        // Two genuinely independent registrations, not two views of one.
        expect(source.value, equals('zenoh/dart/f5/clone'));
        expect(() => session.undeclareKeyExpr(source), returnsNormally);
      },
    );
  });

  group('KeyExpr compose -- edge cases', () {
    test('the forbidden junction errors with the measured code', () {
      final left = KeyExpr('foo/*');
      expect(() => left.concat('*bar'), throwsZenohCode(-128));
      left.dispose();
    });

    test('any wildcard-adjacent concat errors the same way', () {
      final cases = <(String, String)>[
        ('foo/*', 'bar'),
        ('foo/**', 'bar'),
        ('foo', '*bar'),
        ('demo', '/'),
        ('demo', '?x'),
      ];
      for (final (leftExpr, right) in cases) {
        final left = KeyExpr(leftExpr);
        expect(
          () => left.concat(right),
          throwsZenohCode(-128),
          reason: 'concat("$leftExpr", "$right")',
        );
        left.dispose();
      }
    });

    test('an invalid-UTF-8 right operand is a different, measured code', () {
      // Unformable through `concat(String)`: Dart's Utf8Encoder replaces an
      // unpaired surrogate with U+FFFD, so a Dart String can never carry
      // invalid UTF-8 to the seam. The distinction between Z_EINVAL and
      // Z_EGENERIC is canon's and the shim must not flatten it, so the leg is
      // driven at the bindings level -- the only instrument that can express
      // the input.
      final left = KeyExpr('FOO');
      final right = calloc<Uint8>(2);
      final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
      try {
        right[0] = 0xFF;
        right[1] = 0xFE;
        final rc = bindings.zd_keyexpr_concat(
          slot.cast(),
          left.loanedKeyExpr.cast(),
          right.cast(),
          2,
        );
        expect(rc, equals(-1));
      } finally {
        calloc
          ..free(slot)
          ..free(right);
        left.dispose();
      }
    });

    test('a failed compose leaves no half-built handle', () {
      // Canon writes a gravestone into the out-param on every failure path,
      // and a gravestone reads back as the literal "dummy". Nothing may
      // escape carrying that.
      final left = KeyExpr('foo/*');
      Object? escaped;
      try {
        escaped = left.concat('*bar');
      } on ZenohException catch (_) {
        escaped = null;
      }
      expect(escaped, isNull);
      left.dispose();
    });

    test('a gravestoned left operand cannot even be formed', () {
      // The counterpart guard: canon does NOT validate concat's left operand,
      // so a gravestone left silently concatenates onto the literal "dummy".
      // This binding never constructs a KeyExpr around a failed out-param, so
      // there is no way to obtain one to pass in -- the invalid constructor
      // throws instead of yielding a gravestone-backed handle.
      expect(() => KeyExpr('demo//x'), throwsZenohCode(-1));
    });

    test('a disposed receiver is rejected', () {
      final dead = KeyExpr('FOO')..dispose();
      expect(() => dead.concat('BAR'), throwsStateError);
      expect(() => dead.join('BAR'), throwsStateError);
    });

    test('a wrong-typed join argument fails loudly and early', () {
      final foo = KeyExpr('FOO');
      for (final bad in <Object>[
        42,
        <String>['a', 'b'],
      ]) {
        expect(
          () => foo.join(bad),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'other')
                .having(
                  (e) => e.message.toString(),
                  'message',
                  allOf(contains('String'), contains('KeyExpr')),
                ),
          ),
        );
      }
      foo.dispose();
    });
  });
}
