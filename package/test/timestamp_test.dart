import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/timestamp.dart';

void main() {
  group('Timestamp', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('Session creates a timestamp exposing time and id', () {
      final ts = session.newTimestamp();

      // Non-null Timestamp with a large non-zero NTP64 time.
      expect(ts, isNotNull);
      expect(ts.time, isNot(0));
      // NTP64 seconds live in the high 32 bits → current dates are very large.
      expect(ts.time.abs(), greaterThan(1 << 40));

      // The HLC id is the session's own ZID.
      expect(ts.id, equals(session.zid));
    });

    test('Timestamp preserves the full raw value (re-representable)', () {
      final ts = session.newTimestamp();

      // Reconstruct a second Timestamp from the first's raw 24 bytes.
      final ts2 = Timestamp.fromRaw(ts.rawBytes);

      expect(ts2, equals(ts));
      expect(ts2.hashCode, equals(ts.hashCode));
      expect(ts2.time, equals(ts.time));
      expect(ts2.id, equals(ts.id));
    });

    test('NTP64 conveys full unsigned-64 (structural u64 fidelity)', () {
      final ts = session.newTimestamp();

      // NTP64 = seconds-since-UNIX-epoch in the high 32 bits → bit 62 is set
      // for all current dates. Read bit-exact, no narrowing/sign-mangling.
      expect(
        ts.time & (1 << 62),
        isNot(0),
        reason: 'current-date NTP64 must have bit 62 set',
      );

      // Re-read via a raw round-trip: bit-exact, no stringification/narrowing.
      final ts2 = Timestamp.fromRaw(ts.rawBytes);
      expect(ts2.time, equals(ts.time));
    });

    test('id accessor returns a full 16-byte ZenohId', () {
      final ts = session.newTimestamp();

      final idBytes = ts.id.bytes;
      expect(idBytes, isA<Uint8List>());
      expect(idBytes.length, equals(16));
      expect(idBytes, equals(session.zid.bytes));
    });

    test('a 24-byte raw image still round-trips bit-exact', () {
      final ts = session.newTimestamp();

      // The length guard refuses wrong lengths without narrowing the shipped
      // re-representation contract: a well-formed 24-byte image is still
      // accepted, and comes back byte-identical (not merely `==`-equal).
      final ts2 = Timestamp.fromRaw(ts.rawBytes);

      expect(ts2, equals(ts));
      expect(ts2.rawBytes, equals(ts.rawBytes));
      expect(ts2.rawBytes.length, equals(24));
    });
  });

  // Sibling group, deliberately session-free: the length guard is reached
  // before any native call, so these cells need no open session (and never
  // load the native library). Keeping them out of the group above means a red
  // here cannot be caused by session or native-load trouble - only the guard
  // can produce it.
  group('Timestamp.fromRaw length guard', () {
    test('a 23-byte raw image is refused', () {
      // Canon's z_timestamp_t is a fixed 24 bytes, so no other length is
      // expressible. Before this guard the length was checked by an `assert`
      // only: an assert-enabled run (`dart test`) raised AssertionError, and a
      // release build - where asserts are stripped - accepted the short image
      // silently.
      final short = Uint8List(23);

      expect(
        () => Timestamp.fromRaw(short),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message.toString(),
                'message',
                contains('24 bytes'),
              )
              .having((e) => e.invalidValue, 'invalidValue', 23),
        ),
      );
    });

    test('a 25-byte raw image is refused', () {
      // The long side, which the old assert also caught only under `dart test`.
      final long = Uint8List(25);

      expect(
        () => Timestamp.fromRaw(long),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message.toString(),
                'message',
                contains('24 bytes'),
              )
              .having((e) => e.invalidValue, 'invalidValue', 25),
        ),
      );
    });

    test('the guard is a real throw, not an assert', () {
      // An `assert` vanishes in a release build, so a guard written that way
      // protects only the test run. Two instruments, because neither alone is
      // decisive: the thrown type discriminates at run time (an assert raises
      // AssertionError, not ArgumentError), and the source check catches a
      // future edit that swaps them back, which the type check would not see
      // under `dart test` where asserts are enabled.
      //
      // NEITHER instrument observes release mode. Nothing here runs with
      // asserts stripped; the type check is a PROXY for release behaviour and
      // the source check is a proxy for the shape that produces it. The
      // headline claim - "holds in release too" - is a statement of intent
      // these two cells approximate, not something they measure.
      final wrong = Uint8List(23);
      expect(() => Timestamp.fromRaw(wrong), throwsArgumentError);
      expect(
        () => Timestamp.fromRaw(wrong),
        isNot(throwsA(isA<AssertionError>())),
      );

      // TARGETED, not blanket: this file keeps two deliberate `sizeof`-drift
      // asserts (in the `time` and `id` getters) that diagnose a different
      // cause, so a blanket isNot(contains('assert(')) would go red for
      // correct code. Match only the length assert this slice replaced.
      // CWD is `package/` under `dart test`.
      final source = File('lib/src/timestamp.dart').readAsStringSync();
      expect(source, isNot(contains('assert(raw.length')));
    });
  });
}
