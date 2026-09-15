import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart';

import 'helpers/poll.dart';

/// The interior NUL, built rather than escaped so no raw NUL byte reaches this
/// file (a raw NUL makes `grep` treat the whole file as binary).
final String nul = String.fromCharCode(0);

/// A session that cannot discover anything on the LAN: every assertion below
/// is about this process, so inherited discovery would make greens ambiguous.
Future<Session> _quietSession() {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  return Session.open(config: config);
}

void main() {
  group('Session.declareKeyExpr / undeclareKeyExpr', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('a declared key expression carries its source expression', () {
      final declared = session.declareKeyExpr('zenoh/dart/f5/decl');
      expect(declared.value, equals('zenoh/dart/f5/decl'));
      session.undeclareKeyExpr(declared);
    });

    test('declaring accepts a KeyExpr as well as a String', () {
      final source = KeyExpr('zenoh/dart/f5/decl');
      final declared = session.declareKeyExpr(source);

      expect(declared.value, equals('zenoh/dart/f5/decl'));
      // The callee never disposes a caller-owned KeyExpr.
      expect(source.value, equals('zenoh/dart/f5/decl'));

      session.undeclareKeyExpr(declared);
      source.dispose();
    });

    test('undeclaring consumes the handle on success', () {
      final declared = session.declareKeyExpr('zenoh/dart/f5/consume');
      expect(() => session.undeclareKeyExpr(declared), returnsNormally);

      expect(() => declared.value, throwsStateError);
      expect(declared.dispose, throwsStateError);
      expect(() => session.put(declared, 'x'), throwsStateError);
    });

    test(
      'dropping a declared handle without undeclaring is legal and local',
      () async {
        final received = <Sample>[];
        final subscriber = session.declareSubscriber('zenoh/dart/f5/drop');
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });

        final declared = session.declareKeyExpr('zenoh/dart/f5/drop');
        expect(declared.dispose, returnsNormally);
        expect(declared.dispose, returnsNormally);

        // A no-op dispose would pass either way; the put afterwards is what
        // proves the registration the dispose released was local.
        session.put('zenoh/dart/f5/drop', 'after-drop');
        await waitUntil(
          () => received.isNotEmpty,
          description: 'the sample published after the declared handle dropped',
        );
        expect(received.single.payload, equals('after-drop'));
      },
    );

    test('declaring works on a router-less local session', () {
      // Canon's own test shape: declare succeeds on a default-config session
      // with no router and no connect endpoints.
      final declared = session.declareKeyExpr('zenoh/dart/f5/routerless');
      expect(declared.value, equals('zenoh/dart/f5/routerless'));
      session.undeclareKeyExpr(declared);
    });

    test('undeclaring twice reports the wrapper own state, not canon', () {
      final declared = session.declareKeyExpr('zenoh/dart/f5/twice');
      session.undeclareKeyExpr(declared);
      expect(() => session.undeclareKeyExpr(declared), throwsStateError);
    });

    test(
      'undeclaring a view-backed key expression is rejected before any '
      'native call',
      () {
        final view = KeyExpr('demo/x');
        expect(
          () => session.undeclareKeyExpr(view),
          throwsA(isA<ArgumentError>()),
        );
        // Not consumed: no canon call ran, so the handle is untouched and
        // still owes a dispose.
        expect(view.value, equals('demo/x'));
        expect(view.dispose, returnsNormally);
      },
    );

    test('a wrong-typed argument to declareKeyExpr fails loudly and early', () {
      for (final bad in <Object>[
        42,
        <String>['a', 'b'],
      ]) {
        expect(
          () => session.declareKeyExpr(bad),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'keyExpr')
                .having(
                  (e) => e.message.toString(),
                  'message',
                  allOf(contains('String'), contains('KeyExpr')),
                ),
          ),
        );
      }
    });

    test(
      'declaring an interior-NUL key expression carries it byte-exact',
      () {
        // Send side. Canon carries interior NUL through declare and across
        // the wire; the receive surfaces carry it too since the receive-side
        // posting round, measured in keyexpr_receive_fidelity_test.dart. This
        // leg stays scoped to declare -> value so a receive-side regression
        // cannot mask a declare-side one.
        const expr = 'zenoh/dart/f5/a';
        final declared = session.declareKeyExpr('$expr${nul}b');
        expect(
          utf8.encode(declared.value),
          equals(utf8.encode('$expr${nul}b')),
        );
        session.undeclareKeyExpr(declared);
      },
    );
  });

  // The relations triad takes loaned handles, so every backing enters the same
  // seam. The view x view truth table in keyexpr_test.dart is the control: it
  // stays green with no edit.
  //
  // ⚠️ These four legs have NO behavioural discriminator, measured rather than
  // assumed: run against the pre-retype view-typed shim they were all green.
  // zenoh-c's decl_c_type! maps z_owned_keyexpr_t and z_view_keyexpr_t to the
  // same Rust KeyExpr<'static>, and both C structs are ALIGN(8) uint8_t[32],
  // so `z_view_keyexpr_loan` on an owned slot is a coincidentally-sound
  // reinterpret. Their green therefore proves the answers are canon's -- not
  // that the seam converged. The retype's own evidence is structural: the
  // signature no longer admits a view-only type, so an owned handle enters by
  // contract instead of by a representation coincidence that zenoh-c never
  // promised and could drop.
  group('KeyExpr relations across backings', () {
    late Session session;

    setUpAll(() async {
      session = await _quietSession();
    });

    tearDownAll(() {
      session.close();
    });

    test('an owned operand enters the same seam', () {
      final view = KeyExpr('foo/*');
      final owned = session.declareKeyExpr('foo/bar');

      expect(view.includes(owned), isTrue);
      expect(owned.includes(view), isFalse);
      expect(view.intersects(owned), isTrue);
      expect(owned.intersects(view), isTrue);

      session.undeclareKeyExpr(owned);
      view.dispose();
    });

    test('two owned operands compare', () {
      final a = session.declareKeyExpr('foo/bar');
      final b = session.declareKeyExpr('foo/bar');

      expect(a.equals(b), isTrue);

      session
        ..undeclareKeyExpr(a)
        ..undeclareKeyExpr(b);
    });

    test('a declared operand compares like any other', () {
      final declared = session.declareKeyExpr('foo/bar');
      final view = KeyExpr('foo/*');
      final plain = KeyExpr('foo/bar');

      expect(view.includes(declared), isTrue);
      expect(declared.equals(plain), isTrue);

      session.undeclareKeyExpr(declared);
      view.dispose();
      plain.dispose();
    });

    test('an undeclared-away handle is rejected as an operand', () {
      final declared = session.declareKeyExpr('foo/bar');
      final live = KeyExpr('foo/bar');
      session.undeclareKeyExpr(declared);

      expect(() => declared.equals(live), throwsStateError);
      expect(() => live.equals(declared), throwsStateError);

      live.dispose();
    });
  });

  group('Session.declareKeyExpr on a closed session', () {
    test(
      'declaring or undeclaring reports the session, not canon, and does not '
      'consume',
      () async {
        final live = await _quietSession();
        final declared = live.declareKeyExpr('zenoh/dart/f5/closed');
        live.close();

        expect(
          () => live.declareKeyExpr('zenoh/dart/f5/closed'),
          throwsStateError,
        );
        expect(() => live.undeclareKeyExpr(declared), throwsStateError);

        // No canon call ran, so the handle is NOT consumed -- same discipline
        // as the view-backed rejection.
        expect(declared.value, equals('zenoh/dart/f5/closed'));
        expect(declared.dispose, returnsNormally);
      },
    );
  });

  group('declared key expressions across two sessions', () {
    late Session sessionA;
    late Session sessionB;

    setUpAll(() async {
      final configA = Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19010"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionA = await Session.open(config: configA);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final configB = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19010"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      sessionB = await Session.open(config: configB);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      sessionA.close();
      sessionB.close();
    });

    test('undeclaring on the wrong session errors and still kills the handle', () {
      final declared = sessionA.declareKeyExpr('zenoh/dart/f5/wrong');
      expect(
        () => sessionB.undeclareKeyExpr(declared),
        throwsA(
          isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -128),
        ),
      );
      // Canon takes the value before it checks anything, so the handle is
      // already dead: a second use is a StateError, not another ZenohException.
      expect(() => declared.value, throwsStateError);
    });

    test(
      'a declared key expression drives a delivery round-trip identical to '
      'its string form',
      () async {
        final received = <Sample>[];
        final subscriber = sessionB.declareSubscriber('zenoh/dart/f5/rt');
        final sub = subscriber.stream.listen(received.add);
        addTearDown(() async {
          await sub.cancel();
          subscriber.close();
        });

        // Settle time, not a race: the declaration has to reach the other
        // session, and this side has nothing to poll for that.
        await Future<void>.delayed(const Duration(seconds: 1));

        final declared = sessionA.declareKeyExpr('zenoh/dart/f5/rt');
        sessionA
          ..put(declared, 'payload')
          ..put('zenoh/dart/f5/rt', 'payload');

        await waitUntil(
          () => received.length >= 2,
          description: 'both the declared-handle and string-form samples',
        );
        expect(received[0].keyExpr, equals(received[1].keyExpr));
        expect(received[0].payload, equals(received[1].payload));
        expect(received[0].keyExpr, equals('zenoh/dart/f5/rt'));

        sessionA.undeclareKeyExpr(declared);
      },
    );
  });
}
