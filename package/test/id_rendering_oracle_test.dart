// Seed #9 slice 7: the rendering oracle.
//
// `ZenohId.toHexString()` is RE-IMPLEMENTED in Dart rather than delegated to
// the bound `zd_id_to_string`. That is a deliberate choice with a cost and a
// payoff, and this file is the payoff: because the two implementations are
// genuinely independent, comparing them is a cross-check rather than
// self-agreement. Under delegation this whole file would be `x == x` — a
// vacuous green at the seed's most load-bearing cell, and blind to a silent
// drift at the next canon pin.
//
// The reason for re-implementing is not primarily about this file, though.
// `ZenohId` has ZERO native dependency: `id.dart` imports only
// `dart:typed_data` and `package:meta`. Delegating would make rendering —
// and therefore
// `toString()` — require the native library to be loaded and able to allocate:
// a `toString()` that can throw, on an `@immutable` value class that outlives
// its session and is called by every log line and every debugger.
//
// ⚠️ WHY THE ORACLE CELLS LIVE HERE AND NOT IN id_test.dart. That file keeps
// the literal pins and imports neither `dart:ffi` nor the bindings. Keeping it
// that way is not tidiness — it is the STRUCTURAL demonstration that an id
// renders without the native library at all.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh.dart';

/// Renders [id16] through CANON's own formatter, via the shim.
///
/// ⚠️ THE OWNED STRING IS DROPPED IN THE `finally`, NOT AS THE LAST STATEMENT
/// OF THE `try`. The nearest working code an implementer would copy — the
/// seed's own authoring probe `probe_zid_render.dart:15-33` — calls
/// `zd_string_drop` as the try's last statement, with only the two Dart
/// `calloc` cells in its `finally`. A throw from `zd_string_data`,
/// `zd_string_len` or `String.fromCharCodes` leaks the zenoh-owned string
/// there. That is fine in a probe and a violation here: the FFI ownership
/// conventions bind the test too, and this is the exact path the criterion
/// names.
///
/// The drop is guarded on `written` because before `zd_id_to_string` returns
/// there is no owned string to drop — the out-cell holds uninitialised bytes,
/// not a gravestone.
String canonRender(Uint8List id16) {
  final b = bindings;
  final idPtr = calloc<Uint8>(16);
  final out = calloc<Uint8>(b.zd_string_sizeof());
  var written = false;
  try {
    idPtr.asTypedList(16).setAll(0, id16);
    b.zd_id_to_string(idPtr, out.cast());
    written = true;
    final loaned = b.zd_string_loan(out.cast());
    final data = b.zd_string_data(loaned);
    // z_string_len is authoritative: canon's rendering carries no NUL
    // terminator and no `0x` prefix.
    final len = b.zd_string_len(loaned);
    return String.fromCharCodes(data.cast<Uint8>().asTypedList(len));
  } finally {
    if (written) b.zd_string_drop(out.cast());
    calloc
      ..free(idPtr)
      ..free(out);
  }
}

/// The storage-order, always-padded rendering — i.e. what `toHexString()`
/// produced BEFORE this seed, and what `bytes` still means.
///
/// Used only as a control, never as an expected value.
String storageOrderHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final byte in bytes) {
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// The deterministic fixture family, named rather than left as "each fixture".
///
/// Under the padding discriminator it is **F2 and the migrated pair** that
/// carry the two-digit-per-interior-byte axis, so whether this leg inherits
/// them is exactly what matters. Both are here.
final _f1 = Uint8List.fromList([
  0x11, 0x22, 0x33, 0x44, //
  0x55, 0x66, 0x77, 0x88, //
  0x99, 0xaa, 0xbb, 0xcc, //
  0xdd, 0xee, 0xff, 0x10, //
]);
final _f2 = Uint8List.fromList(_f1)..[0] = 0x0a;
final _f3 = Uint8List.fromList(_f1)..[15] = 0x0a;
final _f4 = Uint8List.fromList(_f1)..[15] = 0x00;
final _f0 = Uint8List(16);

/// The 2026-07-31 cross-implementation observation, as BYTES.
///
/// Our storage-order rendering of this session was
/// `97de82dbf35194668e4e660391907e0e`; canon printed
/// `e7e909103664e8e669451f3db82de97` (31 digits). A real measured pair, not a
/// constructed example.
final _migrated = Uint8List.fromList([
  0x97, 0xde, 0x82, 0xdb, //
  0xf3, 0x51, 0x94, 0x66, //
  0x8e, 0x4e, 0x66, 0x03, //
  0x91, 0x90, 0x7e, 0x0e, //
]);

final _family = <String, Uint8List>{
  'F1 distinct-per-position': _f1,
  'F2 id[0]=0x0a (interior low nibble)': _f2,
  'F3 id[15]=0x0a (one digit stripped)': _f3,
  'F4 id[15]=0x00 (two digits stripped)': _f4,
  'F0 all-zero': _f0,
  'the migrated 2026-07-31 pair': _migrated,
};

void main() {
  group('ZenohId rendering vs canon (oracle round-trip)', () {
    // The control that keeps the whole file from being vacuous.
    //
    // Every other cell asserts that two renderings AGREE. That is only
    // evidence if the oracle can disagree — and the specific disagreement
    // worth ruling out is "canon's renderer is just storage order too", which
    // would make agreement prove nothing about the axis under test.
    test('the oracle is discriminating: canon is NOT storage order', () {
      expect(
        canonRender(_f1),
        isNot(equals(storageOrderHex(_f1))),
        reason:
            'if canon rendered storage order, agreement with toHexString '
            'would be trivial and this file would test nothing',
      );
      // ...and the pre-seed rendering is exactly what it disagrees with.
      expect(storageOrderHex(_f1), equals('112233445566778899aabbccddeeff10'));
    });

    // Test 8: the whole family, with NO normalization at the seam.
    test('the oracle agrees on the whole fixture family', () {
      _family.forEach((name, bytes) {
        final canon = canonRender(bytes);
        final ours = ZenohId(bytes).toHexString();
        expect(
          ours,
          equals(canon),
          reason:
              'rendering diverges from canon on $name\n'
              '  canon: $canon\n  ours : $ours',
        );
      });
    });

    // Test 9: the leg no literal can cover, and the one that would catch a
    // silent drift at the next canon pin.
    test('the oracle agrees on a live draw', () async {
      final session = await Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      addTearDown(session.close);

      final zid = session.zid;
      expect(
        zid.toHexString(),
        equals(canonRender(zid.bytes)),
        reason:
            'a value no literal can anticipate must still render exactly '
            'as canon renders it',
      );
    });

    // THE OWNED STRING'S RELEASE, MEASURED — not asserted structurally.
    //
    // A leak neither throws nor corrupts, so no behavioural assertion at any
    // position can see one. The instrument is the house one used for the zid
    // buffer: run N cycles and count how many DISTINCT addresses the allocator
    // had to hand out for canon's string data. Released => the same block is
    // reissued and the set stays tiny. Leaked => every cycle needs a fresh
    // block and the set grows to N.
    //
    // This is what makes the `finally` placement in canonRender above evidence
    // rather than a claim about code shape.
    test("canon's owned string is returned to the allocator once per render", () {
      const cycles = 50;
      final addresses = <int>{};
      final b = bindings;
      final idPtr = calloc<Uint8>(16);
      try {
        idPtr.asTypedList(16).setAll(0, _f1);
        for (var i = 0; i < cycles; i++) {
          final out = calloc<Uint8>(b.zd_string_sizeof());
          try {
            b.zd_id_to_string(idPtr, out.cast());
            final loaned = b.zd_string_loan(out.cast());
            addresses.add(b.zd_string_data(loaned).address);
            b.zd_string_drop(out.cast());
          } finally {
            calloc.free(out);
          }
        }
      } finally {
        calloc.free(idPtr);
      }
      // MEASURED BOTH WAYS at this seed, injected defect = the
      // `zd_string_drop` call above removed (temporary local edit, never
      // committed):
      //   removed -> 50 distinct   present -> 1 distinct
      // Total separation, and the cell goes RED under the injection. The block
      // counted IS the allocation under test -- canon's own string buffer --
      // not a same-size proxy, and the threshold sits inside that margin.
      expect(addresses.length, lessThan(10));
    });
  });
}
