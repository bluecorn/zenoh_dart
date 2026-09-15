// The locked-bytes instrument, and the proof that it is fit — both ways.
//
// This file exists because the SHM lifetime work needs a PROCESS-SCOPED
// resource instrument, and the two instruments already in the tree are not
// that:
//
//   * `allocGc` pool exhaustion discriminates at CHUNK level, and is the
//     prescribed one for chunks — `test/helpers/finalizer_harness.dart:428-436`
//     records the measurement and the two alternatives it rules out;
//   * the `/dev/shm` NAME SET discriminates at PROVIDER level but is
//     MACHINE-GLOBAL — a sibling process moves it, which is why the harness
//     reaches for the name set rather than a count.
//
// `VmLck` is the third: PROVIDER level, and per-process, so no sibling can
// move it. The pair of cells below (`a chunk does not move it` /
// `the chunk-level companion`) is what pins the level split, because an
// instrument whose blind spot is undocumented gets used where it cannot see.
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/shm_locked_bytes.dart';

/// Unwraps an [AllocResult] the cell requires to have succeeded.
///
/// The exhaustive `switch` with no `default` arm is this repo's SHM cell
/// convention (`test/shm_provider_test.dart`): a cell whose subject is the
/// buffer should fail with the discriminant canon reported rather than with a
/// null-check crash three lines later.
ShmMutBuffer _expectOk(AllocResult result) => switch (result) {
  AllocOk(:final buffer) => buffer,
  AllocError(:final kind) => fail('expected AllocOk, got AllocError($kind)'),
  LayoutError(:final kind) => fail('expected AllocOk, got LayoutError($kind)'),
};

/// The reading, or a failed cell — for use AFTER a `lockedBytesOrSkip` in the
/// same cell has already established that the instrument is available.
int _mustReadLockedBytes() => switch (readLockedBytes()) {
  LockedBytesOk(:final bytes) => bytes,
  LockedBytesUnavailable(:final reason) => fail(
    'the instrument was available at the start of this cell and is not now: '
    '$reason',
  ),
};

/// Everything in the helper source that is not a `//` comment line.
///
/// The doc DOES name `/dev/shm` — it has to, that is the distinction it
/// draws — so a scan for what the CODE reaches for has to exclude the prose.
String _helperCode(String source) =>
    source.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  const helperPath = 'test/helpers/shm_locked_bytes.dart';

  group('the VmLck instrument itself', () {
    test("reports the process's own locked bytes, from the VmLck: row", () {
      final reading = readLockedBytes();

      final bytes = switch (reading) {
        LockedBytesOk(:final bytes) => bytes,
        LockedBytesUnavailable(:final reason) => fail(
          'this host exposes /proc/self/status but the instrument reported '
          'unavailable: $reason',
        ),
      };

      expect(bytes, greaterThanOrEqualTo(0));

      // PROVENANCE, not merely a plausible number: the same row, parsed
      // independently here, must give the same answer. `VmLck:` is in kB and
      // the instrument reports BYTES, so the factor is part of the claim.
      final row = File(
        '/proc/self/status',
      ).readAsLinesSync().firstWhere((l) => l.startsWith('VmLck:'));
      final kb = int.parse(RegExp(r'(\d+)').firstMatch(row)!.group(1)!);
      expect(bytes, kb * 1024);

      // And it names where it read from, in its own doc.
      final source = File(helperPath).readAsStringSync();
      expect(source, contains('/proc/self/status'));
      expect(lockedBytesSourcePath, '/proc/self/status');
    });

    test('a missing row reports unavailable, never a silent zero', () {
      // Two ways to have no reading, and NEITHER may come back as 0 — a zero
      // is indistinguishable from "nothing is locked", which is what every
      // leak leg looks like when it passes for the wrong reason.
      final absentFile = readLockedBytes(
        path: '/nonexistent/shm-locked-bytes-probe/status',
      );
      expect(absentFile, isA<LockedBytesUnavailable>());
      expect(absentFile, isNot(isA<LockedBytesOk>()));
      expect(
        (absentFile as LockedBytesUnavailable).reason,
        contains('/nonexistent/shm-locked-bytes-probe/status'),
      );

      // A file that exists and simply has no VmLck: row — a kernel without
      // the row reads exactly like this, and must not read as zero either.
      final tmp = Directory.systemTemp.createTempSync('vmlck_probe');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final rowless = File('${tmp.path}/status')
        ..writeAsStringSync('Name:\tdart\nVmRSS:\t   1024 kB\n');
      final noRow = readLockedBytes(path: rowless.path);
      expect(noRow, isA<LockedBytesUnavailable>());
      expect((noRow as LockedBytesUnavailable).reason, contains('VmLck'));
    });

    test('a dependent cell skips with the reason rather than reading zero', () {
      // This cell REPORTS AS SKIPPED, and that is the assertion: the helper's
      // unavailable path is what dependent cells call, and it must take them
      // out of the run rather than hand them a 0 they would pass on.
      final bytes = lockedBytesOrSkip(
        path: '/nonexistent/shm-locked-bytes-probe/status',
      );
      expect(bytes, isNull);
    });

    test('nothing in it consults a machine-global resource', () {
      final source = File(helperPath).readAsStringSync();
      final code = _helperCode(source);

      // PROVENANCE first: the constant the instrument actually reads through
      // is under /proc/self, which is per-process by construction.
      expect(lockedBytesSourcePath, startsWith('/proc/self/'));

      // Then the file-scoped absence — scoped to THIS FILE's code, which is
      // the only scope an absence assertion can honestly carry.
      expect(
        code,
        isNot(contains('/dev/shm')),
        reason: 'the code must not reach for the machine-global companion',
      );
      expect(
        code,
        isNot(contains('Directory(')),
        reason:
            'a directory listing is how the machine-global instrument is '
            'built; this one reads a single per-process file',
      );
      final literals = RegExp("'(/[^']*)'")
          .allMatches(code)
          .map((m) => m.group(1))
          .toSet();
      expect(literals, {'/proc/self/status'});

      // And the doc draws the distinction it has to draw, naming all three
      // instruments and the level each one sees.
      expect(source, contains('/dev/shm'));
      expect(source, contains('allocGc'));
      expect(source, contains('machine-global'));
      expect(source, contains('attribution'));
      expect(source, contains('finalizer_harness.dart:428-436'));

      // The citation is CHECKED, not just made: the cited text must actually
      // carry the claim the doc leans on it for.
      //
      // ⛔ ANCHORED ON CONTENT, NOT ON A LINE RANGE, and the first cut was the
      // other way. It read `sublist(427, 436)` -- and a later slice of this
      // same unit edited that comment, made it longer, and pushed the claim
      // past line 436. The cell went red on a document that still says exactly
      // what it is cited for. ⭐ A pin is a promise the document is frozen;
      // this one was not, and the pin became a trap rather than a check.
      final harness = File(
        'test/helpers/finalizer_harness.dart',
      ).readAsStringSync();
      final from = harness.indexOf('THE CHUNK-LEVEL INSTRUMENT IS POOL');
      expect(
        from,
        isNot(-1),
        reason:
            'the cited comment block is gone from the harness entirely, '
            'so the doc above is citing something that no longer exists',
      );
      final cited = harness.substring(from, from + 1200);
      expect(cited, contains('allocGc'));
      expect(cited, contains('/dev/shm'));
      expect(cited, contains('PROVIDER level'));
    });
  });

  group(
    'the instrument against live SHM',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      // The pool size every cell in this group derives its thresholds from.
      // It is the size the FAILING SUITE uses, which is why the calibration
      // was performed at it.
      const poolBytes = 64 * 1024;

      test('a provider moves the instrument 1:1, in both directions', () {
        // ⚠️ THE ONE ASSUMPTION: `VmLck` is process-wide, so the three
        // readings below are exact only while nothing ELSE in this process
        // moves it inside the window. Serially -- the posture this suite is
        // certified under -- nothing does. Run in parallel, a sibling suite
        // in the same process that creates or closes a provider between two
        // of these reads produces a SPURIOUS red, never a missed defect: the
        // reading it perturbs cannot look like a clean 1:1 by accident.
        final baseline = lockedBytesOrSkip();
        if (baseline == null) return;

        final provider = ShmProvider(size: poolBytes);
        // The NET. `_mustReadLockedBytes` can `fail()`, which throws before
        // the inline `close()` below is reached and would pin the pool for
        // the rest of the process -- inside the very suite whose locked bytes
        // this unit accounts for. `close()` is idempotent, so the inline one
        // stays exactly where it is: it is load-bearing for the MEASUREMENT,
        // this one is only the net beneath it.
        addTearDown(provider.close);
        final live = _mustReadLockedBytes();
        provider.close();
        final closed = _mustReadLockedBytes();

        // TOTAL in both directions, not merely non-zero in one: an instrument
        // that rises by "something" on create and falls by "something" on
        // close cannot tell a full release from a partial one.
        expect(
          live - baseline,
          poolBytes,
          reason: 'a live $poolBytes-byte provider must show exactly its pool',
        );
        expect(
          closed,
          baseline,
          reason: 'closing it must return the reading to where it started',
        );
      });

      test('a chunk does not move it -- the level split, asserted', () {
        const chunk = poolBytes ~/ 8;
        final provider = ShmProvider(size: poolBytes);
        addTearDown(provider.close);

        // The baseline is taken AFTER the first allocation on purpose: the
        // first allocation in a process locks the SHM subsystem's own
        // machinery as well, and that one-time step is not what this cell is
        // about.
        final firstChunk = _expectOk(provider.allocGc(chunk));
        final baseline = lockedBytesOrSkip();
        if (baseline == null) return;

        for (var i = 0; i < 5; i++) {
          final buffer = _expectOk(provider.allocGc(chunk));
          expect(
            _mustReadLockedBytes(),
            baseline,
            reason: 'allocating chunk $i moved a PROVIDER-level instrument',
          );
          buffer.dispose();
          expect(
            _mustReadLockedBytes(),
            baseline,
            reason: 'releasing chunk $i moved a PROVIDER-level instrument',
          );
        }

        // Releasing the chunk the baseline was taken after does not move it
        // either: the provider is still open, and the provider is the level
        // this instrument sees.
        firstChunk.dispose();
        expect(
          _mustReadLockedBytes(),
          baseline,
          reason:
              'a chunk pin reaches this instrument only through the '
              'provider the pin holds, and that provider is still open',
        );
      });

      test('the chunk-level companion discriminates where this one cannot', () {
        const chunk = poolBytes ~/ 8;
        final provider = ShmProvider(size: poolBytes);
        addTearDown(provider.close);

        final victim = _expectOk(provider.allocGc(chunk));
        final withVictimHeld = sweepToRefusal(
          provider,
          poolBytes: poolBytes,
          chunk: chunk,
        );
        expect(
          withVictimHeld,
          greaterThan(0),
          reason:
              'a pool holding one $chunk-byte chunk must still yield at '
              'least one more, or the sweep measures nothing',
        );

        victim.dispose();
        final afterRelease = sweepToRefusal(
          provider,
          poolBytes: poolBytes,
          chunk: chunk,
        );

        expect(
          afterRelease,
          withVictimHeld + 1,
          reason:
              'releasing exactly one chunk must let the pool yield '
              'exactly one more -- this is the level VmLck cannot see',
        );
      });
    },
  );
}
