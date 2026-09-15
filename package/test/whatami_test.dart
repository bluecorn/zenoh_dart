import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Slice 4 (A7): `WhatAmI.fromInt` must be a *total* decode so an unexpected
/// whatami bitmask value cannot throw inside the scout `receivePort.listen`
/// closure (`zenoh.dart:88`) and strand the scout `Completer` — hanging
/// `scout()`.
///
/// Reproduce-first RED (per plan convention, mirroring Slice 3): a network
/// scout cannot deterministically emit an unexpected whatami, so the seam
/// tested is the pure `fromInt` function. RED pins the CURRENT failure mode:
/// `fromInt(0)` (zero bitmask) and `fromInt(3)` (combined router|peer bits)
/// throw `ArgumentError`. GREEN flips these to expect the total
/// `WhatAmI.unknown` fallback.
void main() {
  group('WhatAmI.fromInt totalization (A7)', () {
    // Test 1: Unexpected whatami value does not throw.
    test('unexpected values (0, 3) do not throw — total decode', () {
      // GREEN: total decode returns the WhatAmI.unknown fallback instead of
      // throwing ArgumentError (RED pinned both throwing).
      expect(WhatAmI.fromInt(0), equals(WhatAmI.unknown));
      expect(WhatAmI.fromInt(3), equals(WhatAmI.unknown));
    });

    // Test 2: Known values still map correctly.
    test('known values (1, 2, 4) map to router/peer/client', () {
      expect(WhatAmI.fromInt(1), equals(WhatAmI.router));
      expect(WhatAmI.fromInt(2), equals(WhatAmI.peer));
      expect(WhatAmI.fromInt(4), equals(WhatAmI.client));
    });

    // Test 3: Totalization removes the scout-hang failure mode (seam-level).
    // Asserted against the pure decode: with a total `fromInt`, the scout
    // closure can always construct a `Hello` (whatami: unknown for unexpected
    // values) and complete the Completer — no uncaught throw path remains.
    test('totalization removes the scout-hang failure mode', () {
      // GREEN: every whatami value (including 5 and -1) decodes without
      // throwing, so the scout closure's `WhatAmI.fromInt(whatami)` call can
      // no longer be an uncaught-throw path that strands the Completer.
      expect(WhatAmI.fromInt(5), equals(WhatAmI.unknown));
      expect(WhatAmI.fromInt(-1), equals(WhatAmI.unknown));
    });
  });
}
