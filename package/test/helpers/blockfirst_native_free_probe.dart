// Reports whether touching the congestion-control seam LOADS A NATIVE.
//
// ⛔ WHY IT IS A SEPARATE PROBE, and why it is a subprocess at all. The thing
// under test is a property of a WHOLE PROCESS — "no native was loaded" — and
// the suite's own process has loaded one long before any cell runs. There is
// no in-process instrument for it.
//
// ⛔ WHAT IT PROTECTS. `enum_wire_value_test.dart` and
// `wire_enum_decode_test.dart` touch only `.value` and `fromWire`, and run
// today without loading a native. The block-first guard consults
// `ZenohFeatures`, which does load one — so the guard short-circuits on the
// value comparison BEFORE reading the feature bits. Move that read above the
// short-circuit and this probe reports a path where it reported null.
//
// ⚠️ It deliberately sets NO `ZENOH_DART_VARIANT`: the question is whether a
// native is loaded at all, not which one.
//
// Output:
//   VALUE=<int>
//   FROMWIRE2=<name>
//   GUARD_NULL=<ok|threw: ...>
//   GUARD_BLOCK=<ok|threw: ...>
//   LOADED=<resolved library path, or the literal null>
//   PROBE_DONE
import 'dart:io';

import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/native_lib.dart';

String _drive(void Function() body) {
  try {
    body();
    return 'ok';
  } on Object catch (e) {
    return 'threw: $e';
  }
}

void main() {
  stdout
    ..writeln('VALUE=${CongestionControl.blockFirst.value}')
    ..writeln('FROMWIRE2=${CongestionControl.fromWire(2).name}')
    ..writeln(
      'GUARD_NULL=${_drive(() => requireCongestionControlSupported(null))}',
    )
    ..writeln(
      'GUARD_BLOCK=${_drive(
        () => requireCongestionControlSupported(CongestionControl.block),
      )}',
    )
    // LAST, because reading it must not itself be what loads the library.
    ..writeln('LOADED=$resolvedLibraryPath')
    ..writeln('PROBE_DONE');
}
