import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

// Slice 3 (A3): total QoS wire->enum decode across 5 receive sites / 3 enums.
//
// A network peer cannot deterministically emit an out-of-range wire value, so
// the only testable surface is the pure decode seam. These tests exercise the
// three extracted static factories directly.
//
// RED (current unguarded bodies `values[raw-1]` / `values[raw]`): out-of-range
// wire values throw RangeError, pinning the live crash.
// GREEN (bounds-checked): each returns its per-enum fallback.
void main() {
  group('CongestionControl.fromWire', () {
    test('wire value 2 (BLOCK_FIRST) decodes to blockFirst', () {
      // Z_CONGESTION_CONTROL_BLOCK_FIRST = 2 is a legal congestion value under
      // Z_FEATURE_UNSTABLE_API, so the Dart enum must represent all three and
      // wire 2 must decode to blockFirst (not clamped to block).
      expect(CongestionControl.values.length, 3);
      expect(CongestionControl.fromWire(2), CongestionControl.blockFirst);
    });
  });

  group('Priority.fromWire', () {
    test('out-of-range wire values 0 and 8 do not crash', () {
      // Wire domain is 1..7 mapped via raw-1; 0 and 8 are out of range.
      // GREEN (bounds-checked): both fall back to Priority.data.
      expect(Priority.fromWire(0), Priority.data);
      expect(Priority.fromWire(8), Priority.data);
    });
  });

  group('ReplyKeyExpr.fromWire', () {
    test('out-of-range wire value 2 does not crash', () {
      // 2 members (0/1); 2 is out of range.
      // GREEN (bounds-checked): falls back to ReplyKeyExpr.matchingQuery.
      expect(ReplyKeyExpr.fromWire(2), ReplyKeyExpr.matchingQuery);
    });
  });

  group('in-range values map correctly (behavioral parity)', () {
    test('Priority 1..7 maps to today .values indexing', () {
      expect(Priority.fromWire(1), Priority.realTime);
      expect(Priority.fromWire(2), Priority.interactiveHigh);
      expect(Priority.fromWire(3), Priority.interactiveLow);
      expect(Priority.fromWire(4), Priority.dataHigh);
      expect(Priority.fromWire(5), Priority.data);
      expect(Priority.fromWire(6), Priority.dataLow);
      expect(Priority.fromWire(7), Priority.background);
    });

    test('CongestionControl 0/1/2 maps to today .values indexing', () {
      expect(CongestionControl.fromWire(0), CongestionControl.block);
      expect(CongestionControl.fromWire(1), CongestionControl.drop);
      expect(CongestionControl.fromWire(2), CongestionControl.blockFirst);
      expect(CongestionControl.blockFirst.index, 2);
    });

    test('genuinely-invalid wire values fall back without throwing', () {
      // 3 and -1 are outside the legal 0..2 domain.
      expect(CongestionControl.fromWire(3), CongestionControl.block);
      expect(CongestionControl.fromWire(-1), CongestionControl.block);
    });

    test('ReplyKeyExpr 0/1 maps to today .values indexing', () {
      expect(ReplyKeyExpr.fromWire(0), ReplyKeyExpr.any);
      expect(ReplyKeyExpr.fromWire(1), ReplyKeyExpr.matchingQuery);
    });
  });
}
