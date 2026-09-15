// The SHM measurement instruments the lifetime cells run on.
//
// TWO of the three live here: the PROCESS-SCOPED locked-bytes reader
// (`readLockedBytes`, new in this unit) and the CHUNK-level sweep
// (`sweepToRefusal`, the prescribed one, used rather than re-derived).
// The third is machine-global and stays where it is, in
// `finalizer_harness.dart`. They are hosted together because they are
// used together: neither one alone can tell a chunk leak from a provider
// leak, and the enumeration below is what says which is which.
//
// ---------------------------------------------------------------------------
// THE THREE SHM INSTRUMENTS, AND THE LEVEL EACH ONE MEASURES
// ---------------------------------------------------------------------------
//
//   1. `allocGc` POOL EXHAUSTION -- CHUNK level.
//      How many chunks the pool still yields before refusing. This is THE
//      chunk-level instrument, and the two obvious alternatives are measured
//      unfit; the measurement and the ruling-out are already in the tree at
//      `test/helpers/finalizer_harness.dart:428-436` and are cited here rather
//      than re-derived. ⚠️ `allocGc`, never plain `alloc`: `alloc` after a
//      release returns `AllocError` because it does not process the
//      deallocation queue, so a cell reaching for it goes red on correct code.
//
//   2. `/dev/shm` NAME SET -- PROVIDER level, MACHINE-GLOBAL.
//      Which segment names exist. Provider create/release moves it; a CHUNK
//      release moves it by ZERO (same citation). It is machine-global, so it
//      is attribution-only: a set DIFFERENCE can say "an entry that was not
//      here before appeared", which no sibling process can fake, but a DELTA
//      on it is not a measurement of this process at all. The tree already
//      carries it as a SET for exactly that reason, with the recorded reason
//      being a red produced by a sibling's release inside the window
//      (`test/helpers/finalizer_harness.dart`, `_devShmNames`).
//
//   3. `VmLck` -- PROVIDER level, PROCESS-SCOPED.  ⬅ THIS FILE, and the only
//      new one.
//      How many bytes THIS process has locked. A sibling cannot move it.
//
// ---------------------------------------------------------------------------
// WHY A THIRD ONE WAS NEEDED
// ---------------------------------------------------------------------------
//
// The seed's process-scoping criterion asks for an instrument that reports
// what THIS process holds, and names none. Instrument 2 cannot answer that
// question: `/dev/shm` is machine-global, and the existing count-shaped cell
// over it was measured failing ALONE AND IDLE, because it asserted a delta on
// a count a sibling moves as easily as we do. Instrument 1 answers a different
// question, at a different level. `VmLck` is per-process by construction, so
// the failure mode that produced that red cannot occur here.
//
// ⚠️ AND IT IS PROVIDER LEVEL, WHICH IS A LIMIT AS WELL AS A STRENGTH. It sees
// a chunk pin only through the provider the pin holds: allocate and release
// chunks all day on a live provider and this reading does not move. It does
// NOT replace instrument 1 -- both run, side by side. The two cells
// `a chunk does not move it` and `the chunk-level companion` in
// `test/shm_locked_bytes_instrument_test.dart` are the pair that pins the
// split, so that no later cell reaches for this one where it cannot see.
//
// ---------------------------------------------------------------------------
// BOTH-WAYS CALIBRATION -- performed by hand, at the 64 KiB pool size
// ---------------------------------------------------------------------------
//
// A leak instrument that has only been shown to read "clean" on clean code has
// not been shown to be an instrument at all. So the chunk-level companion was
// driven both ways, by a temporary local edit that was measured and reverted
// and is NOT in the tree.
//
// A. THE DELTA FRAMING -- the shipped cell, `the chunk-level companion`,
//    64 KiB pool, 8192-byte chunks. The edit removed `victim.dispose()`.
//
//      * SHIPPED TREE:      held = 6, after release = 7.  Moves by one.
//      * RELEASE SUPPRESSED: held = 6, after release = 6.  Does not move,
//        and the cell fails `Expected: <7> Actual: <6>` -- that one cell and
//        no other (+5 ~1 -1 against +6 ~1).
//
// B. THE ACCUMULATION FRAMING -- same pool and chunk size, measured with a
//    throwaway probe (run, read, deleted), three allocate cycles between two
//    sweeps:
//
//      * RELEASE PERFORMED:  sweep 7 before, 7 after.  Delta 0 -- the
//        instrument does NOT move on correct code.
//      * RELEASE SUPPRESSED: sweep 7 before, 4 after.  Delta -3, one per
//        retained chunk.
//
// TOTAL SEPARATION in both framings: 6/7 against 6/6, and 0 against -3, with
// no overlap between the readings and no threshold to tune.
//
// ---------------------------------------------------------------------------
// ⚠️ THE ONE-TIME LAZY LOCK -- 1.25 MiB THAT IS NOT ANY POOL
// ---------------------------------------------------------------------------
//
// THE FIRST ALLOCATION IN A PROCESS LOCKS 1310720 BYTES ON TOP OF THE POOL,
// once. Provider CONSTRUCTION alone does not trigger it. Measured here, at
// this host and this pin, in this order:
//
//   * construct a 65536-byte provider and take no chunk: the reading moves by
//     exactly 65536, and closing it returns exactly to the prior value. Same
//     at 1048576 -- exactly 1048576, exactly back. So construction is clean.
//   * construct a 65536-byte provider and take ONE chunk: the reading is
//     1376256 == 65536 + 1310720. Five further chunks after it move it by
//     zero, and so does releasing them.
//
// TWO CONSEQUENCES, and the second is why this is written down rather than
// left in a working log:
//
//   * a cell asserting "chunks do not move it" MUST take its baseline AFTER
//     the first allocation, or it reads a 1.25 MiB jump it cannot explain and
//     goes red on correct code;
//   * anything ACCOUNTING for the suite process's locked bytes must expect it.
//     `RLIMIT_MEMLOCK` on this box is 8388608 bytes, so this one-time step is
//     ~16% of the entire budget, and a reader who does not know about it will
//     attribute it to a pool that is not there.
//
// ⛔ DELIBERATELY PROSE AND NOT A CELL. 1310720 is a property of this host and
// this zenoh pin, not a contract; a cell asserting it would pin something we
// do not control and would go red on a version bump that broke nothing.
//
// ⚠️ A RETAINED CHUNK MOVES THE CHUNK-LEVEL INSTRUMENT AND DOES NOT MOVE THIS
// ONE AT ALL. `a chunk does not move it` holds a chunk for the whole cell and
// reads `VmLck` twelve times at the same value. That is the level split
// above, measured rather than asserted -- and it is the reason both
// instruments run.
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// The one file this instrument reads.
///
/// It is under `/proc/self`, which is what makes the reading per-process: no
/// sibling process appears in it, by construction.
const String lockedBytesSourcePath = '/proc/self/status';

/// The row within that file.
const String _lockedBytesRow = 'VmLck';

/// Procfs reports sizes with a `kB` suffix and means 1024 bytes.
const int _bytesPerProcKb = 1024;

/// The result of asking for this process's locked bytes.
///
/// Sealed on purpose: an unavailable reading must not be representable as a
/// number, because the number it would be is `0` -- and `0` is exactly what a
/// leaked-nothing run looks like, so every leak leg would pass on a host where
/// the instrument does not work.
sealed class LockedBytesReading {
  /// Const constructor for the subclasses.
  const LockedBytesReading();
}

/// A reading was taken: [bytes] bytes are locked by this process.
final class LockedBytesOk extends LockedBytesReading {
  /// Wraps a byte count read from the procfs row.
  const LockedBytesOk(this.bytes);

  /// Locked bytes -- BYTES, converted from the row's `kB`.
  final int bytes;

  @override
  String toString() => 'LockedBytesOk($bytes bytes)';
}

/// No reading could be taken, and [reason] says why.
final class LockedBytesUnavailable extends LockedBytesReading {
  /// Wraps the reason the instrument could not read.
  const LockedBytesUnavailable(this.reason);

  /// Why there is no reading -- carried so a dependent cell can skip WITH it.
  final String reason;

  @override
  String toString() => 'LockedBytesUnavailable($reason)';
}

/// This process's locked bytes, or an explicit unavailable.
///
/// Reads [path] (default [lockedBytesSourcePath]) and parses its `VmLck:` row.
/// [path] is a parameter only so a cell can drive the unavailable branches;
/// nothing in normal use passes it.
LockedBytesReading readLockedBytes({String path = lockedBytesSourcePath}) {
  final String content;
  try {
    content = File(path).readAsStringSync();
  } on IOException catch (error) {
    return LockedBytesUnavailable('could not read $path: $error');
  }

  for (final line in content.split('\n')) {
    if (!line.startsWith('$_lockedBytesRow:')) continue;
    final match = RegExp(
      '^$_lockedBytesRow:'
      r'\s+(\d+)\s+kB',
    ).firstMatch(line);
    if (match == null) {
      return LockedBytesUnavailable(
        'the $_lockedBytesRow row in $path did not parse: '
        '${line.trim()}',
      );
    }
    return LockedBytesOk(int.parse(match.group(1)!) * _bytesPerProcKb);
  }

  return LockedBytesUnavailable('no $_lockedBytesRow row in $path');
}

/// The reading in bytes, or `null` after marking the running test skipped.
///
/// This is what a dependent cell calls. On a host where the instrument cannot
/// read, the cell leaves the run as SKIPPED, carrying the reason -- rather
/// than continuing against a `0` that would make it pass for the wrong reason.
int? lockedBytesOrSkip({String path = lockedBytesSourcePath}) {
  final reading = readLockedBytes(path: path);
  if (reading is LockedBytesOk) return reading.bytes;
  markTestSkipped(
    'locked-bytes instrument unavailable: '
    '${(reading as LockedBytesUnavailable).reason}',
  );
  return null;
}

// ---------------------------------------------------------------------------
// INSTRUMENT 1: the CHUNK-level sweep
// ---------------------------------------------------------------------------
//
// It lives beside the process-scoped reader because the two are used as a
// PAIR -- see the level split above. It is here rather than in a cell so
// that the next slice needing it reaches for this one instead of copying
// it, which is how two instruments drift into disagreeing.

/// How many `chunk`-sized buffers the pool yields before refusing — the
/// CHUNK-level instrument, used as prescribed rather than re-derived.
///
/// ⚠️ `allocGc`, NEVER plain `alloc`: `alloc` after a release returns
/// `AllocError` because it does not process the deallocation queue, so a cell
/// reaching for it goes red on correct code
/// (`test/helpers/finalizer_harness.dart:428-436`).
///
/// A sweep is a MEASUREMENT and leaves no trace: everything it took is
/// released before it returns, so two sweeps with nothing else changing read
/// the same.
int sweepToRefusal(
  ShmProvider provider, {
  required int poolBytes,
  required int chunk,
}) {
  // The bound derives from the pool the CELL chose: a pool of `poolBytes`
  // cannot yield more than `poolBytes ~/ chunk` chunks of `chunk` bytes, so
  // one more than that is already impossible and means the sweep is not
  // terminating.
  final cap = (poolBytes ~/ chunk) + 1;
  final held = <ShmMutBuffer>[];
  try {
    while (true) {
      final result = provider.allocGc(chunk);
      if (result is! AllocOk) break;
      held.add(result.buffer);
      if (held.length > cap) {
        fail(
          'sweep did not terminate: a $poolBytes-byte pool yielded more than '
          '$cap chunks of $chunk bytes, which is more than the pool holds. '
          'Either allocGc stopped consuming the pool or the buffers are not '
          'being retained.',
        );
      }
    }
    return held.length;
  } finally {
    for (final buffer in held) {
      buffer.dispose();
    }
  }
}
