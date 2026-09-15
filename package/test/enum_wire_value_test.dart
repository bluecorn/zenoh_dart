import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Seed D slice 1 — the setup step for the send-side options surface.
//
// Two conventions are under test here, both from the binding Dart API
// conventions document (R7, `development/reference/dart-api-conventions-20260806.md`):
//
//   CONV-1  — every enum crossing the FFI boundary declares an explicit
//             `final int value` supplied by a `const` constructor, and the
//             send side emits `.value`. Never `.index`, never `.index + 1`.
//             Three of our enums currently couple the wire contract to Dart
//             DECLARATION ORDER, so reordering members — a change every linter
//             and reviewer treats as cosmetic — silently changes the wire.
//
//   G5      — `fromWire` is required only of enums that have a DECODE leg.
//             `Locality` crosses in one direction only (Dart -> canon); canon
//             exposes no accessor returning a locality on any surface, so a
//             decoder here would be UNTESTABLE public API. (Ruled at seed #2's
//             plan gate, ratified in the conventions document. Note the reason
//             is untestability, not linting: `unused_element` is private-only,
//             so an uncalled public decoder draws no diagnostic — measured.)
//
// This slice is pure Dart: no shim change, no rebuild, no ffigen. It changes
// no wire behaviour, and Test 4 is the proof of that.
void main() {
  group('Locality wire values', () {
    test('declares canon own wire values', () {
      // z_locality_t (zenoh_commons.h:68-94) assigns ANY=0, SESSION_LOCAL=1,
      // REMOTE=2 explicitly. We mirror canon rather than re-deriving.
      expect(Locality.any.value, 0);
      expect(Locality.sessionLocal.value, 1);
      expect(Locality.remote.value, 2);
      expect(Locality.values.length, 3);
    });

    test('wire values are independent of declaration order', () {
      // Asserted against a LITERAL, not against `values.indexOf` — deriving
      // the expectation from the declaration order would make this test agree
      // with any reordering, which is the exact failure CONV-1 exists to stop.
      expect(Locality.values.map((l) => l.value).toList(), <int>[0, 1, 2]);
    });

    test('exposes no decoder, and the check can see one when it is there', () {
      // G5: Locality is send-only, so it declares `value` and a `const`
      // constructor and NO `fromWire`.
      //
      // Dart cannot reflect over static members without dart:mirrors, so the
      // surface is read from source. That makes the CONTROL load-bearing: a
      // mistyped path would leave the absence assertion passing vacuously.
      // The control reads a sibling enum that DOES declare a decoder, through
      // the same instrument.
      //
      // Comment lines are stripped first, so the assertion is about the CODE
      // surface and not about the prose. Locality's own dartdoc names
      // `fromWire` in order to explain why it does not have one; matching that
      // sentence would be a false red.
      String code(String path) =>
          File('${Directory.current.path}/$path')
              .readAsLinesSync()
              .where((l) => !l.trimLeft().startsWith('//'))
              .join('\n');

      final locality = code('lib/src/locality.dart');
      final replyKeyExpr = code('lib/src/reply_keyexpr.dart');

      expect(
        replyKeyExpr,
        contains('fromWire'),
        reason:
            'CONTROL: ReplyKeyExpr has a decode leg and declares fromWire. If '
            'this fails the instrument is broken and the assertion below '
            'proves nothing.',
      );
      expect(
        locality,
        isNot(contains('fromWire')),
        reason:
            'Locality crosses in one direction only; canon exposes no '
            'accessor returning a locality, so a decoder would be untestable.',
      );
      expect(
        locality,
        contains('const Locality(this.value)'),
        reason: 'CONV-1: the wire value comes from an explicit const ctor.',
      );
    });
  });

  group('retrofitted enums expose explicit wire values', () {
    test('ReplyKeyExpr, CongestionControl and Priority declare value', () {
      expect(ReplyKeyExpr.any.value, 0);
      expect(ReplyKeyExpr.matchingQuery.value, 1);

      expect(CongestionControl.block.value, 0);
      expect(CongestionControl.drop.value, 1);
      expect(CongestionControl.blockFirst.value, 2);

      expect(Priority.realTime.value, 1);
      expect(Priority.interactiveHigh.value, 2);
      expect(Priority.interactiveLow.value, 3);
      expect(Priority.dataHigh.value, 4);
      expect(Priority.data.value, 5);
      expect(Priority.dataLow.value, 6);
      expect(Priority.background.value, 7);
    });

    test('the retrofit is wire-identical to the encoding it replaces', () {
      // This is the whole safety argument for slice 1 shipping no behaviour
      // change: the send sites at publisher.dart:46-47 emit `.index` and
      // `.index + 1` today. If `.value` equals those expressions for every
      // member, swapping the call sites to `.value` cannot move the wire.
      for (final cc in CongestionControl.values) {
        expect(cc.value, cc.index, reason: 'CongestionControl.$cc');
      }
      for (final p in Priority.values) {
        expect(p.value, p.index + 1, reason: 'Priority.$p');
      }
      for (final r in ReplyKeyExpr.values) {
        expect(r.value, r.index, reason: 'ReplyKeyExpr.$r');
      }
    });

    test('every declared wire value decodes back to its own member', () {
      // The retrofit adds an encode leg beside an existing decode leg. Neither
      // wire_enum_decode_test.dart (which pins the out-of-range fallbacks) nor
      // the equality test above would catch the two legs disagreeing on an
      // in-domain value, so pin the round-trip explicitly.
      for (final cc in CongestionControl.values) {
        expect(CongestionControl.fromWire(cc.value), cc);
      }
      for (final p in Priority.values) {
        expect(Priority.fromWire(p.value), p);
      }
      for (final r in ReplyKeyExpr.values) {
        expect(ReplyKeyExpr.fromWire(r.value), r);
      }
    });
  });
}
