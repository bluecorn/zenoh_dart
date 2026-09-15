// ⛔ FILE-LEVEL TIMEOUT, AND IT MUST EXCEED THE HARNESS DEADLINE.
//
// Every cell here runs a bounded subprocess whose OS-level deadline is 180 s
// (`_deadline`), and several apply up to 120 rounds of allocation pressure.
// `package:test`'s DEFAULT per-test timeout is 30 s — so under load the Dart
// side fired FIRST and reported `TimeoutException after 0:00:30`, discarding
// the harness's own `frozen` flag, last marker and captured output.
//
// That is worse than a slow test: it defeats the entire bounded-subprocess
// design, whose whole point is that a freeze surfaces as a DIAGNOSIS rather
// than as a bare timeout. Measured — two cells failed this way and then passed
// on the runner's retry, which is the shape of a flake, not of a defect.
//
// The file-level bound is therefore set ABOVE the harness deadline, so the
// harness is always the thing that reports.
@Timeout(Duration(minutes: 6))
library;

// Seed [OWN] — the `NativeFinalizer` safety net, proved end-to-end.
//
// ⚠️ WHY THIS FILE EXISTS SEPARATELY FROM `ffi_ownership_test.dart`, and the
// reason is a discovery hazard rather than tidiness. `package:test` runs files
// in ALPHABETICAL order, and `ffi_ownership_test.dart` sorts BEFORE
// `fifo_close_deadlock_test.dart` and `fifo_close_window_test.dart` — the two
// files whose bounded cells exist to catch a freeze. A freezing cell placed in
// `ffi_` would run first and the bounded cells meant to catch it would never
// be reached. `fina` sorts after `fifo`, so a freezing finalizer cell here
// cannot pre-empt them.
//
// ⛔ EVERY CELL IS A FRESH BOUNDED SUBPROCESS, for two reasons that are not
// stylistic. `zd_fin_invocations()` is a PROCESS-WIDE counter that is never
// reset, so two cells in one process would read each other's firings; and
// `MALLOC_PERTURB_` — the named driver for the premature-free class — is read
// by glibc once at startup and cannot be set for part of a process.
//
// ⛔ A LEAK IS INVISIBLE TO A BEHAVIOURAL ASSERTION. dispose-after-consume,
// double-dispose, mark-idempotence and accessor-guard cells all pass
// IDENTICALLY on leaking and on fixed code — nine such cells were once written
// for a real leak and all nine passed on both legs. So every cell here measures
// a RESOURCE, and every one carries a both-ways calibration: a `no-attach` arm
// that must read 0 through the full round cap (the false-GREEN direction) and
// an `attach-without-detach` arm that must resolve one firing from two (the
// fault direction). A finalizer cell that would pass with no finalizer attached
// is worthless, and those two arms are what show these would not.
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/bounded_subprocess.dart';

const _finHarness = 'test/helpers/finalizer_harness.dart';
const _hookHarness = 'test/helpers/post_hook_harness.dart';

/// Generous, because these children apply up to 120 rounds of allocation
/// pressure. The bound exists to stop a freeze burning the serial run, not to
/// police duration.
const _deadline = Duration(seconds: 180);

Future<HarnessOutcome> _runArm(
  String arm, {
  Map<String, String>? environment,
  List<String> extra = const [],
}) => runBoundedHarness(
  _finHarness,
  ['--arm', arm, ...extra],
  deadline: _deadline,
  environment: environment,
  label: 'finalizer[$arm]',
);

/// The counter reading a run reported, or null when the marker is absent.
int? _count(HarnessOutcome o) {
  for (final line in o.output.split('\n')) {
    final t = line.trimRight();
    if (t.startsWith('FIN_COUNT ')) {
      final m = RegExp(r'value=(\d+)').firstMatch(t);
      if (m != null) return int.parse(m.group(1)!);
    }
  }
  return null;
}

int? _onMain(HarnessOutcome o) {
  for (final line in o.output.split('\n')) {
    final t = line.trimRight();
    if (t.startsWith('FIN_ON_MAIN ')) {
      final m = RegExp(r'value=(\d+)').firstMatch(t);
      if (m != null) return int.parse(m.group(1)!);
    }
  }
  return null;
}

int? _marker(HarnessOutcome o, String prefix) => o.markerValue(prefix);

/// The text after a marker prefix, for markers whose payload is not a number.
String _markerText(HarnessOutcome o, String prefix) {
  for (final line in o.output.split('\n')) {
    final t = line.trimRight();
    if (t.startsWith(prefix)) return t.substring(prefix.length);
  }
  return '<absent>';
}

void main() {
  // -------------------------------------------------------------------------
  // Slice 3 — the mechanism, on ZDeserializer
  // -------------------------------------------------------------------------
  //
  // ZDeserializer FIRST because its entire release is `calloc.free(_ptr)` —
  // no canon drop, no state transition, no second block. That isolates the two
  // questions the whole mechanism turns on (does the symbol-name lookup work,
  // and is a C `free()` on a Dart-`calloc`'d block sound) from every
  // class-specific complication that follows.
  group('the finalizer mechanism', () {
    test('a dropped-without-dispose deserializer releases its native block', () async {
      final o = await _runArm('deser-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
      // The round it fired on is REPORTED, not asserted to a value: it is a
      // property of the collector's scheduling, and pinning it would make this
      // cell fail on a VM that simply collected later.
      printOnFailure('fired at round ${_marker(o, 'FIN_ROUND=')}');
      expect(
        _marker(o, 'FIN_ROUND='),
        greaterThan(0),
        reason:
            'the finalizer never fired within the round cap. ${o.diagnosis}',
      );
      // ⚠️ THE THREAD, recorded beside every observation. A hypothesis of the
      // form "the callback runs on the finalizer thread" cannot be established
      // by a stopwatch, and this seed's exclusion rulings turn on it.
      expect(
        _onMain(o),
        ZdFinOnMain.yes,
        reason:
            'the finalizer did not run on the mutator. That is not a failure '
            'of the net, but it CHANGES the ground under several exclusion '
            'rulings in this seed and must be escalated, not absorbed. '
            '${o.diagnosis}',
      );
    });

    test('the instrument is calibrated in the FAULT direction', () async {
      // Two attachments, two blocks, no detach key: the counter must resolve
      // one firing from two. If it cannot, a missed detach reads exactly like
      // a correct release and every other cell in this file is worthless.
      final o = await _runArm('attach-without-detach');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 2, reason: o.diagnosis);
    });

    test('the instrument is calibrated in the FALSE-GREEN direction', () async {
      // Nothing attached, full round cap. A cell that would pass with no
      // finalizer attached proves nothing; this is the arm that shows these
      // would not.
      final o = await _runArm('no-attach');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(
        _marker(o, 'FIN_ROUND='),
        -1,
        reason: 'the no-attach arm did not run the full cap. ${o.diagnosis}',
      );
    });

    test('an explicitly disposed deserializer never runs its finalizer', () async {
      // ⛔ THE PREMATURE-FREE CLASS, which a counting leg explicitly cannot
      // see. Its named driver is `MALLOC_PERTURB_` on a subprocess with a
      // printed success marker: a use-after-free on a freed-but-untouched
      // block returns plausible bytes and stays green, while under a perturbed
      // pattern it aborts.
      //
      // ⚠️ `MALLOC_PERTURB_` does NOT induce allocation failure — it perturbs
      // freed memory. Stated so nobody reaches for it as a fault injector.
      final o = await _runArm(
        'deser-dispose',
        environment: {'MALLOC_PERTURB_': '165'},
      );
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(
        o.hasMarker('FIN_MARKER_OK'),
        isTrue,
        reason:
            'no success marker — a child that died early would otherwise pass '
            'this cell for the wrong reason. ${o.diagnosis}',
      );
    });

    test('a C free() on a Dart-calloc-d block is sound on this target', () async {
      // F-5 pinned as a test rather than as a comment. `package:ffi` 2.2.0
      // resolves malloc/calloc/free to libc on POSIX — the same libc this shim
      // links — so the shim's `free()` releases exactly what Dart's
      // `calloc.allocate` claimed. On Windows the same package routes through
      // CoTaskMemAlloc/Free and this would be wrong; Windows is not a shipped
      // target (no preset, no prebuilt, no CI leg), which is why that is an
      // n/a-with-reason in the header rather than a silence.
      final o = await _runArm(
        'deser-mass-free',
        environment: {'MALLOC_PERTURB_': '165'},
        extra: const ['--count', '64'],
      );
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_marker(o, 'FIN_RELEASED='), 64, reason: o.diagnosis);
      expect(_count(o), 64, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test(
      'the eight unconditional entries work on the STABLE variant too',
      () async {
        // ⛔ EACH FINALIZER IS RESOLVED AT FIRST ATTACH, NEVER AT LOAD, and this
        // is the cell that pins why. Three of the ten planned entries are
        // `#ifdef`-guarded and are ABSENT from the stable native this package
        // also ships (measured: `nm -D` reads 175 vs 204 today). Eager
        // resolution of the whole family would throw at initialization on the
        // stable variant, for a consumer who never touched shared memory.
        final o = await _runArm(
          'deser-drop',
          environment: {'ZENOH_DART_VARIANT': 'stable'},
        );
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 1, reason: o.diagnosis);
      },
    );

    test('the Dart kind mirror agrees with the C header', () async {
      // `finalizers.dart` claims this file asserts the mirror; this is that
      // assertion, so the claim is not a decoration. The kinds are uppercase C
      // macros precisely so ffigen does not emit them, and the price of that
      // choice is a hand-written mirror that can drift.
      final header = File('../src/zenoh_dart.h').readAsStringSync();
      int headerValue(String macro) {
        final m = RegExp('#define $macro (\\d+)').firstMatch(header);
        expect(m, isNotNull, reason: '$macro is not defined in the header');
        return int.parse(m!.group(1)!);
      }

      expect(headerValue('ZD_FIN_KIND_FREE_BLOCK'), ZdFinKind.freeBlock);
      expect(headerValue('ZD_FIN_KIND_CONFIG'), ZdFinKind.config);
      expect(headerValue('ZD_FIN_KIND_KEYEXPR'), ZdFinKind.keyExpr);
      expect(headerValue('ZD_FIN_KIND_BYTES'), ZdFinKind.bytes);
      expect(headerValue('ZD_FIN_KIND_BYTES_WRITER'), ZdFinKind.bytesWriter);
      expect(headerValue('ZD_FIN_KIND_SERIALIZER'), ZdFinKind.serializer);
      expect(headerValue('ZD_FIN_KIND_PUBLISHER'), ZdFinKind.publisher);
      expect(
        headerValue('ZD_FIN_KIND_ADVANCED_PUBLISHER'),
        ZdFinKind.advancedPublisher,
      );
      expect(headerValue('ZD_FIN_KIND_SHM_MUT'), ZdFinKind.shmMut);
      expect(headerValue('ZD_FIN_KIND_SHM_PROVIDER'), ZdFinKind.shmProvider);
      // Added at [SHM] slice 12. A provider collected while an async request
      // had been started runs the DEFERRING entry rather than the dropping
      // one, and it is counted separately so a cell can tell "the deferring
      // net fired" from "nothing fired" -- two readings one counter would
      // conflate, and conflating them is how a reachability cell passes while
      // proving nothing.
      expect(
        headerValue('ZD_FIN_KIND_SHM_PROVIDER_DEFERRED'),
        ZdFinKind.shmProviderDeferred,
      );
      expect(headerValue('ZD_FIN_KIND_COUNT'), ZdFinKind.count);
      expect(headerValue('ZD_FIN_ON_MAIN_UNOBSERVED'), ZdFinOnMain.unobserved);
      expect(headerValue('ZD_FIN_ON_MAIN_NO'), ZdFinOnMain.no);
      expect(headerValue('ZD_FIN_ON_MAIN_YES'), ZdFinOnMain.yes);
    });
  });

  // -------------------------------------------------------------------------
  // Slice 4 — Config, and the markConsumed detach that is a double free if
  // missed
  // -------------------------------------------------------------------------
  //
  // ⛔ THIS IS THE HOT DETACH OF THE WHOLE SEED. `Config.markConsumed()` FREES
  // the Dart block rather than transferring it, so a missed detach there is a
  // DOUBLE FREE on the session-open path, not a leak — and its ordering is a
  // pinned regression guard from PR #47 ("a use-after-free on a 2008-byte
  // block"). `Config` goes before `ZBytes` deliberately: it is the same defect
  // at one call per session rather than one per message, which makes it the
  // cheapest place to get wrong.
  //
  // ⚠️ EVERY ARM BELOW RUNS UNDER `MALLOC_PERTURB_=165` where a premature or
  // double free is what it would catch. A counting leg cannot see a premature
  // free at all — a use-after-free on a freed-but-untouched block returns
  // plausible bytes and stays green; under a perturbed pattern it aborts.
  group('Config in the net', () {
    Future<HarnessOutcome> perturbed(String arm) =>
        _runArm(arm, environment: {'MALLOC_PERTURB_': '165'});

    test('a dropped-without-dispose config releases native and slot', () async {
      final o = await _runArm('config-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
      expect(_onMain(o), ZdFinOnMain.yes, reason: o.diagnosis);
    });

    // --- the four explicit release paths, enumerated per CONV-5 -------------
    //
    // CONV-5 requires the release paths to be ENUMERATED, not represented.
    // `markConsumed` has two distinct call sites and three distinct
    // situations, and a list naming one of them is incomplete by CONV-5's own
    // terms — which is why `Zenoh.scout` gets its own cell below even though
    // it marks through the same method as `Session.open`.

    test(
      'dispose() detaches, and the finalizer never runs afterwards',
      () async {
        final o = await perturbed('config-dispose');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 0, reason: o.diagnosis);
        expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
      },
    );

    test('markConsumed() detaches on the Session.open path (explicit config)', () async {
      final o = await perturbed('config-consumed-explicit');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _count(o),
        0,
        reason:
            'the finalizer ran on a config whose handle canon had already '
            'gravestoned and whose slot markConsumed had already freed — that '
            'is a drop-after-move AND a double free. ${o.diagnosis}',
      );
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test(
      'the internally-created config of Session.open() is also detached',
      () async {
        // This one has NO other owner: nothing but markConsumed can reclaim it,
        // so it is the path where a wrong detach is least visible.
        final o = await perturbed('config-consumed-internal');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 0, reason: o.diagnosis);
        expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
      },
    );

    test('markConsumed() detaches on the Zenoh.scout path too', () async {
      // The SECOND consumer. Same method, different call site — and CONV-5
      // asks for the enumeration rather than a representative.
      final o = await perturbed('config-consumed-scout');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    // --- edge cases --------------------------------------------------------

    test('dispose() after markConsumed() still throws, unchanged', () async {
      // The pinned asymmetry with `ZBytes.dispose` (which no-ops on a consumed
      // payload) must SURVIVE the finalizer: disposing a config already handed
      // to the session is a caller bug worth reporting, and the detach must
      // not quietly turn that throw into a no-op.
      final o = await perturbed('config-dispose-after-consume');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _marker(o, 'FIN_THREW='),
        1,
        reason:
            'dispose() after markConsumed() no longer throws StateError. '
            '${o.diagnosis}',
      );
      expect(_count(o), 0, reason: o.diagnosis);
    });

    test(
      'a config whose construction throws leaves no attachment behind',
      () async {
        // ALLOCATE-LAST means the object never existed to attach to. The
        // constructor's own free is the only release, and a finalizer attached
        // before the rc check would hand that same address to free() again.
        final o = await perturbed('config-construct-throws');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_marker(o, 'FIN_THREW='), 1, reason: o.diagnosis);
        expect(_count(o), 0, reason: o.diagnosis);
        expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 5 — ZBytes: the net on the per-message class
  // -------------------------------------------------------------------------
  //
  // ⚠️ `ZBytes` is constructed ONCE PER MESSAGE on the clone-in-loop
  // throughput and ping paths, so two things are different here from Config.
  // The double-free consequence of a missed `markConsumed` detach happens per
  // message rather than per session; and the cost of attach+detach is priced
  // rather than assumed (A9b) — this package ships latency and throughput
  // examples whose entire purpose is a number. Those figures are a slice
  // measurement, run by hand on the pre-marker and post-net trees, and they
  // live in the slice notes and the PR body. They are deliberately NOT a suite
  // file: a suite file runs only on the post-net tree, so it can measure
  // "after" and can never measure "before".
  group('ZBytes in the net', () {
    Future<HarnessOutcome> perturbed(
      String arm, {
      List<String> extra = const [],
    }) => _runArm(arm, environment: {'MALLOC_PERTURB_': '165'}, extra: extra);

    test(
      'a dropped-without-dispose payload releases its native bytes',
      () async {
        final o = await _runArm('bytes-drop');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 1, reason: o.diagnosis);
        expect(_onMain(o), ZdFinOnMain.yes, reason: o.diagnosis);
      },
    );

    test('dispose() detaches', () async {
      final o = await perturbed('bytes-dispose');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test(
      'markConsumed() on the send path detaches, 200 messages deep',
      () async {
        // The clone-in-loop shape, at volume, under a perturbed allocator. A
        // missed detach here is one double free PER MESSAGE.
        final o = await perturbed(
          'bytes-consumed',
          extra: const ['--count', '200'],
        );
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(
          _count(o),
          0,
          reason:
              'the net fired on a payload the send path had already consumed — '
              'that is a drop-after-move AND a double free, once per message. '
              '${o.diagnosis}',
        );
        expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
      },
    );

    test('a payload borrowed by a live ZDeserializer is not collected under it', () async {
      // Criterion (i) for `ZBytes`, driven rather than read. The deserializer
      // holds a native CURSOR into these bytes and a Dart reference to the
      // wrapper; if the collector took the bytes out from under that cursor,
      // the read after the pressure would be a use-after-free the VM cannot
      // see. The readback value is what makes this an assertion rather than an
      // absence.
      final o = await _runArm('bytes-borrowed');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(
        _marker(o, 'FIN_READBACK='),
        7,
        reason:
            'the borrowed payload did not read back its own content after '
            '120 rounds of pressure. ${o.diagnosis}',
      );
    });

    test(
      'an SHM-backed payload from toBytes() returns its chunk to the pool',
      skip: ZenohFeatures.hasSharedMemory
          ? false
          : 'requires the unstable variant (shared memory)',
      () async {
        // ⛔ THE INSTRUMENT IS POOL EXHAUSTION THROUGH `allocGc`, and both of
        // the obvious alternatives are measured unfit. `ShmProvider.available`
        // -- ⚠️ REMOVED at [SHM] slice 14 on that very measurement --
        // is a CONSTANT 0 at every lifecycle point — the class's own dartdoc
        // records the measurement — so branching on it is branching on a
        // constant. And a CHUNK release moves /dev/shm entries, fds and
        // mappings by ZERO; those discriminate at PROVIDER level only, and the
        // first allocation in a process adds one of each that never returns.
        //
        // ⚠️ `allocGc`, never plain `alloc`: `alloc` after a release returns
        // AllocError because it does not process the deallocation queue, so a
        // cell reaching for it goes red on correct code.
        final o = await _runArm('bytes-shm');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);

        // CONTROL FIRST: while the payload is live the pool must NOT satisfy a
        // second request of the same size. Without this the success below
        // would be consistent with a pool that was never exhausted at all.
        expect(
          _marker(o, 'FIN_SHM_WHILE_LIVE='),
          0,
          reason:
              'the pool satisfied a second 40960 request while the first was '
              'still live, so it was never exhausted and the reclaim below '
              'proves nothing. ${o.diagnosis}',
        );
        expect(
          _marker(o, 'FIN_SHM_AFTER_DROP='),
          1,
          reason:
              'the chunk was not returned to the pool after the payload was '
              'dropped un-disposed. ${o.diagnosis}',
        );
        expect(_count(o), 1, reason: o.diagnosis);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 6 — KeyExpr: two backings, two blocks, four release paths
  // -------------------------------------------------------------------------
  //
  // THE MULTI-BLOCK CASE, and the answer is not a token struct. A view-backed
  // key expression holds a `calloc`'d `z_view_keyexpr_t` slot AND the
  // `malloc`'d string it borrows; one token cannot reach both. A shim-side
  // token struct would cost a `malloc` PER WRAPPER OBJECT, which on a
  // per-message class is exactly the cost this seed is trying not to add. Two
  // attachments under ONE detach key cost nothing extra, and a single
  // `detach(this)` per finalizer reverses both.
  //
  // ⛔ THE TWO COUNTERS ARE READ SEPARATELY, and that is the whole reason the
  // counter is per-entry rather than global. An OWNED backing wrongly put on
  // the free-only shape leaks canon's keyexpr silently — and would read 1 on a
  // single global counter, passing the very cell that exists to catch it.
  //
  // ⚠️ FOUR release paths, not three: `dispose()` (owned), `dispose()` (view),
  // `undeclareFrom()`, and the construction-failure path that frees before the
  // object exists. The seed names three.
  group('KeyExpr in the net', () {
    Future<HarnessOutcome> perturbed(String arm) =>
        _runArm(arm, environment: {'MALLOC_PERTURB_': '165'});

    test('a dropped view-backed key expression releases BOTH blocks', () async {
      final o = await _runArm('keyexpr-view-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _count(o),
        2,
        reason:
            'a view backing holds two blocks and must fire once per '
            'attachment. ${o.diagnosis}',
      );
    });

    test('a dropped owned-backed key expression releases through the canon '
        'drop, and NOT through the free-only shape', () async {
      final o = await _runArm('keyexpr-owned-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
      // ⛔ The discriminating half. Without it, an owned key expression
      // attached to `zd_fin_free_block` would leak canon's keyexpr and this
      // cell would still be green.
      expect(
        _marker(o, 'FIN_FREEBLOCK='),
        0,
        reason:
            'the owned backing fired the FREE-ONLY entry, which frees the slot '
            'and leaks the canon key expression inside it. ${o.diagnosis}',
      );
    });

    test('dispose() detaches BOTH attachments of a view backing', () async {
      final o = await perturbed('keyexpr-view-dispose');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _count(o),
        0,
        reason:
            'one detach(this) did not reverse both attachments. '
            '${o.diagnosis}',
      );
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test('undeclareFrom() detaches, with the unconditional free', () async {
      // ⚠️ The detach must sit WITH the unconditional `calloc.free` and BEFORE
      // the rc check: canon takes the handle before checking anything, so it
      // is a gravestone whatever the call returned, and the slot is freed on
      // both paths. A detach placed after the throw would leave the net armed
      // over freed memory on exactly the failure path.
      final o = await perturbed('keyexpr-undeclare');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(_marker(o, 'FIN_FREEBLOCK='), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test(
      'a key expression rejected at construction leaves no attachment',
      () async {
        // ⚠️ THE PREMISE MATTERS. `a//b` and the empty string are inputs the
        // STRICT door genuinely rejects. A lone surrogate — the obvious third
        // candidate — does NOT work: it CONSTRUCTS, because `utf8.encode`
        // substitutes U+FFFD before canon sees a byte, so on a correct
        // implementation both view attachments land and the counter reads 2.
        // That cell would go red on correct code.
        final o = await perturbed('keyexpr-construct-throws');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(
          _marker(o, 'FIN_THREW='),
          2,
          reason: 'both rejected inputs must throw. ${o.diagnosis}',
        );
        expect(_count(o), 0, reason: o.diagnosis);
        expect(_marker(o, 'FIN_KEYEXPR='), 0, reason: o.diagnosis);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 7 — ZBytesWriter and ZSerializer: `finish()` is a release
  // -------------------------------------------------------------------------
  //
  // ⚠️ BOTH CLASSES HAVE A THIRD STATE THE SEED'S `_consumed` VOCABULARY DOES
  // NOT NAME: `_finished`. `finish()` moves the handle into canon and
  // `calloc.free`s the slot, so it is a RELEASE PATH and must detach for
  // exactly the reason `markConsumed()` does. A plan that enumerated only
  // `dispose()` and the finalizer would have left the hot path uncovered.
  group('ZBytesWriter and ZSerializer in the net', () {
    Future<HarnessOutcome> perturbed(String arm) =>
        _runArm(arm, environment: {'MALLOC_PERTURB_': '165'});

    test('an abandoned writer releases its native writer', () async {
      final o = await _runArm('writer-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
    });

    test('finish() detaches — no drop-after-move, no double free', () async {
      final o = await perturbed('writer-finish');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test('an abandoned serializer releases its native serializer', () async {
      final o = await _runArm('serializer-drop');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
    });

    test('ZSerializer.finish() detaches', () async {
      final o = await perturbed('serializer-finish');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    // --- edge cases --------------------------------------------------------

    test('dispose() on an already-finished writer stays a no-op', () async {
      // The "safe to call multiple times" contract has to survive the detach,
      // and a second detach on an already-detached key must be harmless.
      final o = await perturbed('writer-finish-dispose');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test('a writer abandoned by a caller-s error handling is still released', () async {
      // ⛔ THE NET'S WHOLE PURPOSE — a LIVE, UN-FINISHED writer dropped on the
      // floor by a `catch`.
      //
      // ⚠️ The first version of this arm was WRONG AND THE COUNTER CAUGHT IT.
      // It finished the writer and then called `writeAll` on it to provoke the
      // throw — but `finish()` is itself a correct release, so the writer had
      // already been handed over cleanly and the counter read 0. The arm was
      // measuring a properly-released writer while claiming to measure an
      // abandoned one, and it would have been a green cell asserting nothing.
      // The failure has to come from the CALLER, not from the writer's own
      // state machine.
      final o = await _runArm('writer-abandoned');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _count(o),
        1,
        reason:
            'a live un-finished writer abandoned in a catch was not reclaimed '
            '— which is the one path this net exists for. ${o.diagnosis}',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Slice 9 — Publisher and AdvancedPublisher: the net is conditional, the
  // marker is not
  // -------------------------------------------------------------------------
  //
  // The finalizer attaches ONLY when `_matchingPort == null` — one `if` per
  // constructor. The class is unsendable in BOTH configurations because slice
  // 1's marker is unconditional; only the NET is conditional, and it is
  // conditional on the exact fact that decides whether a drop callback can
  // post.
  //
  // ⛔ `Querier` IS NOT IN THIS NET. It was, on `Publisher`'s ground — "as
  // (10)", copied rather than re-derived — and that ground is FALSE for it:
  // `put()` is synchronous and outlives nothing, while `get()` hands out a
  // `Stream<Reply>` that outlives the reference. They differ on exactly the
  // criterion that decides membership, which is why a family term had no
  // business in the map.
  group('Publisher and AdvancedPublisher in the net', () {
    Future<HarnessOutcome> perturbed(String arm) =>
        _runArm(arm, environment: {'MALLOC_PERTURB_': '165'});

    test('a dropped ml:off publisher is undeclared', () async {
      final o = await _runArm('pub-drop-mloff');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 1, reason: o.diagnosis);
    });

    test('an ml:ON publisher is NOT in the net', () async {
      // The leak is PRESERVED here, deliberately. A matching listener means the
      // object holds a `ReceivePort` and canon's drop callback for it posts to
      // a Dart port — and a post from a `NativeFinalizer` callback is
      // documented undefined behaviour. Leaking a slot beats invoking UB.
      final o = await _runArm('pub-drop-mlon');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _count(o),
        0,
        reason:
            'a finalizer fired on an ml:ON publisher, whose drop callback can '
            'post to a Dart port. ${o.diagnosis}',
      );
    });

    test('close() detaches on the ml:off path', () async {
      final o = await perturbed('pub-close');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
    });

    test(
      'the same three cells hold for AdvancedPublisher',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (unstable API)',
      () async {
        // ⛔ MEASURED SEPARATELY, not inferred from `Publisher`. Different class,
        // different surface — and inferring one class from another on this exact
        // axis is what cost `Querier` its admission.
        final off = await _runArm('apub-drop-mloff');
        expect(off.exitCode, 0, reason: off.diagnosis);
        expect(_count(off), 1, reason: off.diagnosis);

        final on = await _runArm('apub-drop-mlon');
        expect(on.exitCode, 0, reason: on.diagnosis);
        expect(_count(on), 0, reason: on.diagnosis);

        final closed = await perturbed('apub-close');
        expect(closed.exitCode, 0, reason: closed.diagnosis);
        expect(_count(closed), 0, reason: closed.diagnosis);
        expect(
          closed.hasMarker('FIN_MARKER_OK'),
          isTrue,
          reason: closed.diagnosis,
        );
      },
    );

    // --- criterion (i), the last two IN rows resting on a reading -----------

    for (final entry
        in const <({String arm, String label, String cls, bool unstable})>[
          (
            arm: 'pub-reach',
            label: 'PUBLISHER',
            cls: 'Publisher',
            unstable: false,
          ),
          (
            arm: 'apub-reach',
            label: 'ADVPUBLISHER',
            cls: 'AdvancedPublisher',
            unstable: true,
          ),
        ]) {
      test(
        'criterion (i) is MEASURED for ${entry.cls}(ml:off)',
        // `AdvancedPublisher` IS the unstable API: under the stable native the
        // arm cannot declare one, and exits 255 instead of measuring.
        skip: entry.unstable && !ZenohFeatures.hasUnstableApi
            ? 'requires the unstable variant (unstable API)'
            : false,
        () async {
          // ⛔ TWO MEASUREMENTS, NOT ONE EXTRAPOLATED TO THE OTHER. These are the
          // last two IN rows whose criterion (i) rested on a reading — "using it
          // requires holding it" — which is the same sentence, on the same axis,
          // that was measured FALSE for `Querier` this round.
          final o = await _runArm(entry.arm);
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);

          // ⛔ THE CONTROL FIRST. A kept-in-a-list instance must survive the same
          // pressure. If it did not, the instrument would be reporting
          // collection for everything and the row below would mean nothing.
          expect(
            _marker(o, 'FIN_REACH_CONTROL_LIVE='),
            1,
            reason:
                'the kept-in-a-list control was collected too, so this arm '
                'reports collection for everything. ${o.diagnosis}',
          );

          // ⭐ THE STRUCTURAL HALF, and it is what decides the criterion.
          // `matchingStatus` is NULL in the ml:off configuration — so the one
          // obvious derived holder, the thing that could outlive the reference
          // without referencing it, DOES NOT EXIST HERE. Everything else the
          // ml:off surface hands out is a value: `keyExpr` is a Dart String
          // copy, `hasMatchingSubscribers()` is a bool, and
          // put/putBytes/deleteResource are synchronous and return void.
          expect(
            _marker(o, 'FIN_MATCHING_NULL='),
            1,
            reason:
                '${entry.cls}(ml:off) exposed a matchingStatus stream, which '
                'would be a derived holder that does not reference the wrapper '
                '— criterion (i) then FAILS and this class goes OUT of the net. '
                'ESCALATE to the gate with the re-reconciled sum 9 + 11 = 20; '
                'do not reclassify here. ${o.diagnosis}',
          );

          // The collection round is REPORTED, not asserted to a value. An
          // unreferenced object being collected is true of every object and is
          // not itself a criterion (i) failure — the criterion is about
          // collection WHILE IN USE, and the assertion above is what establishes
          // there is nothing outstanding that constitutes use.
          printOnFailure(
            '${entry.cls}(ml:off) unreferenced: collected at round '
            '${_marker(o, 'FIN_REACH_${entry.label}=')}',
          );
        },
      );
    }

    // --- edge cases --------------------------------------------------------

    test('a publisher whose declaration fails leaves no attachment', () async {
      final o = await perturbed('pub-declare-throws');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(_marker(o, 'FIN_THREW='), 1, reason: o.diagnosis);
      expect(_count(o), 0, reason: o.diagnosis);
    });

    test(
      'Querier gets the marker and NO finalizer, in both configurations',
      () async {
        // Asserted HERE as well as in slice 13, because this is the slice a
        // reader will check when asking why the publisher family got a net and
        // the querier did not.
        final o = await _runArm('querier-no-net');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        final kinds = RegExp(r'FIN_ALL_KINDS=([\d,]+)')
            .firstMatch(o.output)
            ?.group(1)
            ?.split(',')
            .map(int.parse)
            .toList();
        expect(kinds, isNotNull, reason: o.diagnosis);
        expect(
          kinds,
          everyElement(0),
          reason:
              'a finalizer fired while only Queriers were dropped. There is no '
              'zd_fin_querier to fire, and the counters are read PER KIND so a '
              'stray attachment to any entry is visible. ${o.diagnosis}',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 10 — ShmProvider: the net, on the measurement the map lacked
  // -------------------------------------------------------------------------
  //
  // The seed's own map admitted `ShmProvider` on grounds that were ASSERTED and
  // never measured — CA2's reachability census covered ten classes and no SHM
  // class, and its §7 declares SHM "unexamined", while a ruling to the
  // developer rested on this row's membership. CP measured (i) and (iii) at
  // planning; Slice 8 measured (ii). These cells promote that from a planner
  // probe to shipped regression guards, because a future reader must be able to
  // re-run it rather than trust it.
  //
  // ⚠️ THE RESOURCE IS DIRECTLY OBSERVABLE AT **PROVIDER** LEVEL, and that is
  // what separates this slice from the next one. Creating and releasing a
  // PROVIDER moves `/dev/shm` entries; releasing a CHUNK moves them by ZERO.
  // A3's named SHM instrument applies here and not one slice further on.
  group(
    'ShmProvider in the net',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('a dropped provider releases its segment', () async {
        final o = await _runArm('shmprov-drop');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 1, reason: o.diagnosis);

        // ⚠️ THE ASSERTION IS ON THE DELTA WITHIN A RUN, NOT ON AN ABSOLUTE
        // COUNT. `/dev/shm` is machine-global: measured across runs the
        // baseline moved 5 -> 6 -> 5 as other processes' segments came and
        // went. An absolute expectation would be a flake generator; the
        // question is only whether THIS process's segment survived.
        // ⛔ WAS A COUNT DELTA, AND THE COUNT IS MACHINE-GLOBAL — the same
        // defect as the cell below, mirrored: `after - base <= 0` goes red
        // whenever a SIBLING creates a segment inside the window. Both
        // directions are properties of the machine, not of this process.
        // What is meant is that no zenoh segment appeared and stayed.
        printOnFailure(
          '/dev/shm leaked zenoh segments: '
          '${_markerText(o, "FIN_SHM_LEAKED_NAMES=")}',
        );
        expect(
          _marker(o, 'FIN_SHM_LEAKED='),
          0,
          reason:
              'the provider was collected but its /dev/shm segment outlived '
              'it. ${o.diagnosis}',
        );
      });

      test('the resource instrument is calibrated — a KEPT provider holds its '
          'segment through the full cap', () async {
        // ⛔ WITHOUT THIS THE CELL ABOVE PROVES NOTHING. "The entry count did
        // not rise" would read identically if `/dev/shm` never moved for a
        // provider at all — i.e. if the instrument were blind. This is the
        // same shape in the other direction: a provider held across the whole
        // 120-round cap must show its segment PRESENT.
        final o = await _runArm('shmprov-noattach');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 0, reason: o.diagnosis);

        // ⛔ THIS ASSERTED A COUNT DELTA AND THE COUNT IS MACHINE-GLOBAL.
        // `expect(after - base, greaterThan(0))` asks "did the number of
        // segments on this MACHINE go up", which any sibling process answers
        // as readily as we do. Measured red under `--concurrency=4` at
        // base=28 after=26 — a sibling released two segments inside the
        // window while our provider was demonstrably still holding one.
        //
        // ⚠️ AND IT IS NOT A PARALLEL DEFECT. Re-running the arm alone on an
        // idle machine gave base=24 after=6: the old assertion fails at
        // `--concurrency=1` too. Concurrency only raised the odds of a window
        // in which other segments moved. The cell was always flaky; the
        // parallel run is merely where it was first seen.
        //
        // The fix is the SET, not the count. A sibling's RELEASE cannot remove
        // an entry we added, so the exact failure that produced the red cannot
        // recur. The remaining hazard is the other direction — a sibling
        // CREATING a segment inside our window — and that is what the
        // vanish-on-close check below excludes.
        final appeared = _marker(o, 'FIN_SHM_APPEARED=')!;
        printOnFailure(
          'kept provider, /dev/shm appeared: $appeared '
          '(${_markerText(o, "FIN_SHM_APPEARED_NAMES=")})',
        );
        expect(
          appeared,
          greaterThan(0),
          reason:
              'a provider held live through the whole cap added no entry to '
              '/dev/shm — the instrument is blind, and the release cell above '
              'is vacuous. ${o.diagnosis}',
        );
        expect(_marker(o, 'FIN_SHM_KEPT_OK='), 1, reason: o.diagnosis);

        // ⭐ Attribution by behaviour: at least one entry that appeared when
        // the provider was created must disappear when it is closed. A
        // sibling's segment landing in `appeared` by coincidence will not
        // vanish in step with OUR close, so this is what keeps the cell from
        // passing on somebody else's segment.
        expect(
          _marker(o, 'FIN_SHM_VANISHED='),
          greaterThan(0),
          reason:
              'no entry that appeared with the provider disappeared when it '
              'was closed, so the entry counted above cannot be attributed to '
              'this provider. ${o.diagnosis}',
        );
      });

      test('close() detaches', () async {
        // The reviewer's most severe reported crash shape is a double drop of
        // the segment; this is the cell that pins it cannot happen.
        final o = await _runArm(
          'shmprov-close',
          environment: {'MALLOC_PERTURB_': '165'},
        );
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 0, reason: o.diagnosis);
        expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
      });

      test('a provider released while a child buffer is live leaves the buffer '
          'usable', () async {
        // ⭐ CRITERION (iii) AS A CELL — the measurement the seed's map assumed.
        // `close()` calls the SAME `zd_shm_provider_drop` the finalizer would,
        // so this is the finalizer's effect driven through a shipped path.
        final o = await _runArm('shmprov-live-child');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_marker(o, 'FIN_SHM_CHILD_LEN='), 1024, reason: o.diagnosis);
        expect(
          _marker(o, 'FIN_SHM_CHILD_FIRST='),
          1,
          reason:
              'a write through the child buffer after the provider was '
              'released did not read back. ${o.diagnosis}',
        );
        expect(_marker(o, 'FIN_SHM_CHILD_SHM='), 1, reason: o.diagnosis);
      });

      test('a provider released while a derived ZBytes is live leaves the '
          'payload readable AND publishable', () async {
        final o = await _runArm('shmprov-live-bytes');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_marker(o, 'FIN_SHM_BYTES_LEN='), 256, reason: o.diagnosis);
        expect(
          _marker(o, 'FIN_SHM_BYTES_ALL7='),
          1,
          reason:
              'the payload was not byte-identical to what was written after '
              'the provider was released. ${o.diagnosis}',
        );
        expect(_marker(o, 'FIN_SHM_PUBLISHED='), 1, reason: o.diagnosis);
      });

      test(
        'a second release after a write is a no-op, not a double free',
        () async {
          // ⛔ NEWLY LOAD-BEARING AT SLICE 5, which is why it is a cell now
          // and was not before. A written buffer used to sit in the
          // SLOT-ONLY state, where `dispose()` had no chunk to release and a
          // second call was trivially harmless. The escape is gone, so a
          // written buffer now carries the CHUNK-releasing net -- and a
          // second release landing on that chunk would be a real double free.
          //
          // ⚠️ A double free is invisible to a behavioural assertion: the
          // second `dispose()` returns normally either way. So the observable
          // is the PROCESS -- `MALLOC_PERTURB_` turns a use-after-free on a
          // poisoned block into an abort -- and the printed marker is what
          // stops a child that died early from passing for the wrong reason.
          final o = await _runArm(
            'shmmut-dispose-twice',
            environment: {'MALLOC_PERTURB_': '165'},
          );
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);
          expect(
            o.hasMarker('FIN_MARKER_OK'),
            isTrue,
            reason:
                'the child must reach its own end; a process that aborted '
                'mid-way must not read as a pass. ${o.diagnosis}',
          );
          expect(
            _count(o),
            0,
            reason:
                'an explicit release detaches the net, so no finalizer may '
                'fire afterwards. ${o.diagnosis}',
          );
        },
      );

      // --- edge cases ------------------------------------------------------

      test(
        'a provider whose construction fails leaves no attachment',
        () async {
          // A pool below the Talc minimum. Canon's own example loans the
          // provider without checking the return code and segfaults on this
          // input; this constructor is a straight pass-through, so it throws.
          final o = await _runArm(
            'shmprov-construct-throws',
            environment: {'MALLOC_PERTURB_': '165'},
          );
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);
          expect(_marker(o, 'FIN_THREW='), 1, reason: o.diagnosis);
          expect(_count(o), 0, reason: o.diagnosis);
        },
      );

      // ⚠️ NO ASSERTION IS MADE ANYWHERE IN THIS GROUP ABOUT STDERR SILENCE —
      // upstream #814 means the SHM path can emit diagnostics on a healthy
      // run, and a cell requiring quiet stderr would go red on correct code.
      //
      // ⚠️ AND EVERY NUMBER HERE CARRIES ITS CONDITIONS: Linux POSIX, one
      // host, Android UNEXAMINED. `[SHM]`'s queue position is ruled to be
      // decided on this evidence, so an unconditioned number would be worse
      // than none.
    },
  );

  // -------------------------------------------------------------------------
  // Slice 11 — ShmMutBuffer: the net, and the escaped-pointer opt-out
  // -------------------------------------------------------------------------
  //
  // ⛔ THE ONE THREE-STATE MEMBER OF THE NET:
  //   fresh              -> zd_fin_shm_mut     the chunk AND the slot
  //   `data` has escaped -> zd_fin_free_block  the slot ONLY
  //   toBytes() consumed -> zd_fin_free_block  the slot ONLY
  //
  // The escape case is the design. Once a caller holds the raw `data` pointer,
  // freeing the chunk under it would turn today's LEAK-on-forget into a
  // USE-AFTER-FREE — strictly worse. So the escape DOWNGRADES the net rather
  // than arming it: the chunk keeps exactly today's behaviour and the
  // wrapper's slot is still reclaimed. **The severity never increases**, which
  // is what lets this land without `[SHM]`'s own remedy for the escaped
  // pointer (review finding S3, out of scope here).
  //
  // ⛔ THE CHUNK-LEVEL INSTRUMENT IS POOL EXHAUSTION THROUGH `allocGc`, and
  // both obvious alternatives are measured unfit. `ShmProvider.available` was
  // a
  // CONSTANT 0 at every lifecycle point — the class's own dartdoc records the
  // measurement, so branching on it is branching on a constant. And `/dev/shm`
  // entries, fds and mappings move by ZERO on a CHUNK release; they
  // discriminate at PROVIDER level only, which is slice 10's cell.
  // ⚠️ `allocGc`, NEVER plain `alloc` — `alloc` after a release returns
  // AllocError because it does not process the deallocation queue, so a cell
  // reaching for it goes red on correct code.
  group(
    'ShmMutBuffer in the net',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test(
        'a fresh buffer dropped without dispose() releases its chunk',
        () async {
          final o = await _runArm('shmmut-fresh-drop');
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);

          // ⛔ THE CONTROL IS READ FIRST. While the buffer is live the pool must
          // NOT satisfy a second full-size chunk — otherwise the success below
          // is equally consistent with a pool that was never exhausted at all.
          expect(
            _marker(o, 'FIN_SHM_WHILE_LIVE='),
            0,
            reason:
                'the pool satisfied a second 40960 request while the first was '
                'still live, so it was never exhausted and the reclaim below '
                'proves nothing. ${o.diagnosis}',
          );
          expect(
            _marker(o, 'FIN_SHM_AFTER_DROP='),
            1,
            reason: 'the chunk was not returned to the pool. ${o.diagnosis}',
          );
          expect(_count(o), 1, reason: o.diagnosis);
          expect(
            _marker(o, 'FIN_FREEBLOCK='),
            0,
            reason:
                'a fresh buffer fired the SLOT-ONLY entry, which leaves the '
                'chunk allocated forever. ${o.diagnosis}',
          );
        },
      );

      test(
        'a buffer WRITTEN and then dropped releases its whole chunk',
        () async {
          // ⛔ RETARGETED 2026-09-02 (slice 4). This cell was 'a buffer whose
          // data pointer ESCAPED releases only its slot', and it asserted the
          // chunk stayed PINNED: a caller held the raw `data` pointer, so the
          // net could only detach to slot-only. That is the leak this unit
          // closes. Nothing in the tree escapes a pointer any more — every
          // caller writes through the copying `write` — and slice 5 removes
          // `ShmMutBuffer.data`, at which point the escape it measured cannot
          // be reached. Named here rather than dropped so it stays traceable.
          //
          // The reading INVERTS, and the inversion is the product claim: a
          // buffer that has been written and then forgotten must give its
          // chunk BACK.
          final o = await _runArm('shmmut-written-drop');
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);

          // ⛔ THE CONTROL IS READ FIRST. While the buffer is live the pool
          // must NOT satisfy a second full-size chunk — otherwise the reclaim
          // below is equally consistent with a pool that was never exhausted.
          expect(
            _marker(o, 'FIN_SHM_WHILE_LIVE='),
            0,
            reason:
                'the pool satisfied a second 40960 request while the first was '
                'still live, so it was never exhausted. ${o.diagnosis}',
          );
          expect(
            _count(o),
            1,
            reason:
                'the DROP+FREE entry did not fire on a buffer filled with '
                '`write` — which means the chunk was never released. '
                '${o.diagnosis}',
          );
          expect(
            _marker(o, 'FIN_FREEBLOCK='),
            0,
            reason:
                '`write` downgraded the net to slot-only, exactly as reading '
                '`data` used to. The slot is freed and the CHUNK is pinned for '
                'the life of the process. ⛔ The two counters are read '
                'separately precisely so this is visible. ${o.diagnosis}',
          );
          expect(
            _marker(o, 'FIN_SHM_AFTER_DROP='),
            1,
            reason: 'the chunk was not returned to the pool. ${o.diagnosis}',
          );
        },
      );

      test('toBytes() re-attaches the slot-only shape', () async {
        final o = await _runArm('shmmut-consumed');
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(o.exitCode, 0, reason: o.diagnosis);
        expect(_count(o), 1, reason: o.diagnosis);
        expect(
          _marker(o, 'FIN_SHMMUT='),
          0,
          reason:
              'zd_shm_mut_drop was called on a handle toBytes() had already '
              'moved — the drop-after-move class. ${o.diagnosis}',
        );
        expect(
          RegExp(r'FIN_SHM_PAYLOAD=([\d,]+)').firstMatch(o.output)?.group(1),
          '1,1,2,3',
          reason:
              'the payload did not read back byte-exactly after the buffer '
              'was collected. ${o.diagnosis}',
        );
      });

      // ⛔ TWO STATES, NOT THREE, as of 2026-09-02 (slice 5). The loop used
      // to read ['fresh', 'escaped', 'consumed']. The `escaped` state was the
      // one a live `data` pointer put a buffer into, and the getter is gone,
      // so the state is unreachable rather than merely untested. The retired
      // arm's own tombstone is in `finalizer_harness.dart` beside where it
      // stood.
      for (final state in const ['fresh', 'consumed']) {
        test('dispose() detaches in the $state state', () async {
          final o = await _runArm(
            'shmmut-dispose-$state',
            environment: {'MALLOC_PERTURB_': '165'},
          );
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);
          expect(_count(o), 0, reason: o.diagnosis);
          expect(_marker(o, 'FIN_FREEBLOCK='), 0, reason: o.diagnosis);
          expect(o.hasMarker('FIN_MARKER_OK'), isTrue, reason: o.diagnosis);
        });
      }

      // --- edge cases ------------------------------------------------------

      test(
        'write called five times leaves the net exactly as it was',
        () async {
          // ⛔ RETARGETED 2026-09-02 (slice 4). This cell was 'data called
          // five times does not attach five times', and its subject was the
          // IDEMPOTENCE of the escape transition — five attachments on one
          // slot would have been five frees of it. Slice 5 removes
          // `ShmMutBuffer.data` and with it that transition; named here rather
          // than dropped so it stays traceable.
          //
          // The same repetition, against the copying accessor: five writes must
          // leave the drop+free entry armed and must never arm the slot-only
          // one, so the chunk still comes back.
          final o = await _runArm('shmmut-write-five-times');
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);
          expect(
            _count(o),
            1,
            reason:
                'the DROP+FREE entry fired ${_count(o)} times for five writes '
                'on one buffer. ${o.diagnosis}',
          );
          expect(
            _marker(o, 'FIN_FREEBLOCK='),
            0,
            reason:
                'repeated `write` downgraded the net to slot-only, which pins '
                'the chunk. ${o.diagnosis}',
          );
          expect(
            _marker(o, 'FIN_SHM_AFTER_DROP='),
            1,
            reason: 'the chunk was not returned to the pool. ${o.diagnosis}',
          );
        },
      );

      test(
        'chunks released by the net are genuinely returned, N times over',
        () async {
          // ⚠️ The pool holds ONE chunk of this size, so each cycle depends on
          // the previous one having been reclaimed. `allocGc` is named because
          // plain `alloc` after a release returns AllocError — it does not
          // process the deallocation queue — and a cell using it would go red
          // on correct code.
          final o = await _runArm(
            'shmmut-cycle',
            extra: const ['--count', '6'],
          );
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, 0, reason: o.diagnosis);
          expect(
            _marker(o, 'FIN_SHM_CYCLES='),
            6,
            reason:
                'a cycle stalled — the net did not return the chunk before the '
                'next allocation. ${o.diagnosis}',
          );
          expect(_count(o), 6, reason: o.diagnosis);
          expect(
            _marker(o, 'FIN_SHM_POOL_FREE='),
            1,
            reason:
                'the pool could not satisfy a full-size request after six '
                'allocate-and-drop cycles — criterion (iii) in the child to '
                'parent direction. ${o.diagnosis}',
          );
        },
      );

      // ⚠️ THE RESIDUAL `[SHM]` INHERITS, stated rather than measured: a
      // FORGOTTEN buffer whose `data` pointer escaped still pins its chunk.
      // This net closes the fresh and consumed cases; it deliberately does not
      // close that one, because closing it would require freeing a chunk under
      // a live pointer. Reported at the close so `[SHM]` gets an accurate
      // premise.
    },
  );

  // -------------------------------------------------------------------------
  // Slice 12 — the kNativePointer decision: a MEASUREMENT slice
  // -------------------------------------------------------------------------
  //
  // ⛔ ITS OUTPUT IS A NUMBER AND A RULING; the implementation follows only if
  // the number supports it. Both cells below carry the number. The ruling and
  // its grounds are in the slice notes and the PR body.
  //
  // THE HOLE. `_zd_query_callback` malloc's a `z_owned_query_t` clone per
  // query and posts its ADDRESS as a bare integer — "THE one post site that
  // TRANSFERS ownership", in the shim's own words. Dart frees it, through
  // `Query.dispose()`. If the VM destroys the message before delivering it,
  // that Dart owner never materialises and the clone — block AND canon
  // contents — is orphaned with no reference anywhere.
  // `Dart_CObject_kNativePointer` exists for exactly this: its finalizer
  // "will only be invoked if the message is not delivered" (vendored header,
  // verbatim).
  group('the kNativePointer decision', () {
    late Directory tmp;
    late String hookPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_knp');
      hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<HarnessOutcome> runHook(String subject, int port) =>
        runBoundedHarness(
          _hookHarness,
          [
            '--hook',
            hookPath,
            '--subject',
            subject,
            '--topology',
            'one',
            '--port',
            '$port',
          ],
          deadline: _deadline,
          label: 'knp[$subject]',
        );

    test('the delivered-then-destroyed hole is DRIVEN, and its magnitude '
        'recorded', () async {
      expect(haveClang, isTrue, reason: 'clang is required');

      // ⚠️ `seen == 0` ALONE IS AMBIGUOUS — it fits both "N clones orphaned"
      // and "no clone was ever created", because a queryable closed fast
      // enough might never have had its callback run at all. The POST COUNT is
      // the discriminator: a post means the callback ran, which means a clone
      // exists.
      final prompt = await runHook('knp-shipped', 19650);
      expect(prompt.frozen, isFalse, reason: prompt.diagnosis);
      expect(
        prompt.markerValue('HOOK_INSTALL_RC='),
        0,
        reason: prompt.diagnosis,
      );

      // ⭐ THE CONTROL, and it is PR #86's own recorded shape: "closing the
      // port in the same turn delivers 0 of 5 queued messages; deferring by
      // one turn delivers 5 of 5." Deferring is what ATTRIBUTES the post
      // count — whatever the deferred arm delivers is how many of the posts
      // were QUERY posts, and therefore how many the prompt arm orphaned.
      final deferred = await runHook('knp-shipped-deferred', 19651);
      expect(deferred.frozen, isFalse, reason: deferred.diagnosis);

      final promptPosts = prompt.markerValue('HOOK_POSTS=')!;
      final deferredPosts = deferred.markerValue('HOOK_POSTS=')!;
      final promptSeen = prompt.markerValue('HOOK_SEEN=')!;
      final deferredSeen = deferred.markerValue('HOOK_SEEN=')!;
      printOnFailure(
        'prompt: posts=$promptPosts seen=$promptSeen · '
        'deferred: posts=$deferredPosts seen=$deferredSeen',
      );

      // The same clones are created either way — that is what makes the
      // delivery difference attributable to the close timing and nothing else.
      expect(
        promptPosts,
        deferredPosts,
        reason:
            'the two arms did not create the same number of clones, so the '
            'delivery difference is not attributable to the close timing. '
            'prompt=${prompt.diagnosis}',
      );
      expect(
        deferredSeen,
        greaterThan(0),
        reason:
            'the DEFERRED arm delivered nothing either, so the prompt '
            "arm's zero says nothing about the hole. ${deferred.diagnosis}",
      );
      expect(
        promptSeen,
        0,
        reason:
            'the prompt close delivered some queries, so this shape does not '
            'reproduce the hole on this host. ${prompt.diagnosis}',
      );

      // ⛔ THE MAGNITUDE. Every clone the deferred arm delivered is one the
      // prompt arm orphaned — through the SHIPPED `Queryable.close()` path,
      // with no unusual usage, and `closeAndDrain()` cannot see them because
      // they never reached the channel.
      printOnFailure('ORPHANED CLONES = $deferredSeen');
      expect(deferredSeen, greaterThanOrEqualTo(8), reason: deferred.diagnosis);
    });

    test('the false-post branch is NOT confused with the other one', () async {
      // ⚠️ STRUCTURAL, and it must stay that way. PR #86 records the rejected-
      // post branch as "not deterministically drivable at this pin", so it is
      // verified by reading the code rather than by driving it — and dressing
      // it as driven would be exactly the false green this seed's discipline
      // forbids.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      expect(
        shim,
        contains('if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {'),
        reason: 'the rejected-post branch is no longer at the query post site',
      );
      // It reclaims BOTH the canon contents and the block — the two halves the
      // shim comment names.
      final idx = shim.indexOf('THE one post site that TRANSFERS ownership');
      expect(idx, greaterThan(0));
      final branch = shim.substring(idx, idx + 700);
      expect(branch, contains('z_query_drop(z_query_move(cloned));'));
      expect(branch, contains('free(cloned);'));
    });
  });

  // -------------------------------------------------------------------------
  // Slice 13 — the TEN classes OUT of the net
  // -------------------------------------------------------------------------
  //
  // ⛔ AN EXCLUSION NOBODY CAN OBSERVE IS INDISTINGUISHABLE FROM AN OVERSIGHT.
  // These cells make the ten absences assertable, and they carry the two
  // measurements that MOVED classes out of the net this round — `Querier` and
  // `Query` — as standing guards rather than as footnotes. That is the right
  // home for them: a measurement that removes a class belongs with the
  // exclusion it created, not as a qualification on an admission that no
  // longer exists.
  group('the ten classes OUT of the net', () {
    test('no finalizer is attached to any excluded class', () async {
      final o = await _runArm('out-of-net');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      final kinds = RegExp(r'FIN_ALL_KINDS=([\d,]+)')
          .firstMatch(o.output)
          ?.group(1)
          ?.split(',')
          .map(int.parse)
          .toList();
      expect(kinds, isNotNull, reason: o.diagnosis);
      expect(kinds, hasLength(ZdFinKind.count), reason: o.diagnosis);
      // ⚠️ `AdvancedSubscriber` is the unstable API, so the arm constructs it
      // only where the loaded native has it, and says whether it did. Pinned
      // per variant: the stable run cannot fail on the absent class, and the
      // unstable run cannot silently shrink to the stable set.
      expect(
        _marker(o, 'FIN_OUT_ADVSUB='),
        ZenohFeatures.hasUnstableApi ? 1 : 0,
        reason: o.diagnosis,
      );
      // ⛔ READ PER KIND, not as one total: a stray attachment to ANY entry is
      // visible, where a sum would let one entry's firing hide another's zero.
      expect(
        kinds,
        everyElement(0),
        reason:
            'a finalizer fired while only excluded classes were dropped. '
            'Counters by kind: $kinds. ${o.diagnosis}',
      );
    });

    test('the idiomatic no-handle shape keeps delivering across a GC', () async {
      // ⭐ THE REGRESSION GUARD FOR THE 27th PASS'S CENTRAL FINDING, and the
      // single most important cell in this group. `declareSubscriber(k).stream`
      // retains NO handle — the stream does not reference the wrapper — so the
      // subscriber is unreferenced from the first line. THIS CELL GOES 3 -> 0
      // if a `Subscriber` finalizer is ever added.
      final o = await _runArm('gc-sub');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _marker(o, 'FIN_DELIVERED='),
        3,
        reason:
            'a subscriber declared in the idiomatic no-handle shape stopped '
            'delivering under allocation pressure. If a Subscriber finalizer '
            'was added, THIS is the cell that catches it. ${o.diagnosis}',
      );
    });

    test('Querier — the in-flight get() shape that disqualified it', () async {
      // The querier itself is UNREFERENCED while its get() is in flight: the
      // listener captures the port and controller, not the querier. A
      // finalizer there undeclares it mid-flight and the get completes with
      // zero replies.
      final o = await _runArm('querier-inflight-guard');
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(
        _marker(o, 'FIN_REPLIES='),
        greaterThan(0),
        reason:
            'an in-flight get() delivered no replies while its querier was '
            'unreferenced — which is what a Querier finalizer would cause. '
            '${o.diagnosis}',
      );
      final kinds = RegExp(r'FIN_ALL_KINDS=([\d,]+)')
          .firstMatch(o.output)
          ?.group(1)
          ?.split(',')
          .map(int.parse);
      expect(kinds, everyElement(0), reason: o.diagnosis);
    });

    // ⚠️ A5's fifo half is NOT a cell here, deliberately. `fifo_close_deadlock`
    // and `fifo_close_window` are whole test FILES; asserting them from inside
    // this file would nest one suite run inside another, and at the seed's
    // close that nested run would re-run itself. They are run TARGETED by CI
    // and the result is reported in the slice notes and the PR body — which is
    // what "run targeted" means.

    test('a leaked IN-NET object is released at isolate-group shutdown', () async {
      // ⛔ NEITHER HALF OF THIS CAN BE OBSERVED FROM DART. A `test()` cannot
      // see its own file's isolate-group shutdown from inside that file, and a
      // counter read FROM DART cannot be read once the isolate is gone —
      // which is exactly when the answer exists. So the child leaks two
      // port-free IN-NET objects, RETURNS from main (never `exit()`), and the
      // counters are printed by a native `__attribute__((destructor))` in an
      // LD_PRELOAD helper, after the VM has finished.
      final tmp = await Directory.systemTemp.createTemp('zd_atexit');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final soPath = '${tmp.path}/fin_atexit.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-o',
        soPath,
        'test/helpers/fin_atexit.c',
        '-ldl',
      ]);
      expect(build.exitCode, 0, reason: 'clang: ${build.stderr}');

      final o = await _runArm(
        'leak-at-shutdown',
        environment: {'LD_PRELOAD': soPath},
      );
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(o.exitCode, 0, reason: o.diagnosis);
      expect(o.hasMarker('FIN_MAIN_RETURNS'), isTrue, reason: o.diagnosis);

      // ⚠️ The helper also runs in the `dart` wrapper processes, which never
      // load the shim and report NO_SYMBOL. Matching on the NUMERIC markers is
      // what makes those inert — and a run where ONLY NO_SYMBOL appeared would
      // fail here rather than passing as "zero".
      expect(
        o.markerValue('FIN_ATEXIT_CONFIG='),
        1,
        reason:
            'a leaked Config was not released at isolate-group shutdown, or '
            'the at-exit reporter never found the shim. ${o.diagnosis}',
      );
      expect(
        o.markerValue('FIN_ATEXIT_FREEBLOCK='),
        2,
        reason:
            'a leaked view-backed KeyExpr holds TWO blocks and both must be '
            'released at shutdown. ${o.diagnosis}',
      );
    });

    test('A-2-s Session-finalizer falsifier: RUN, and NOT DRIVABLE', () async {
      // ⚠️ THE RESULT IS "COULD NOT BE DRIVEN", AND IT COMES WITH THE CONTROL
      // THAT ESTABLISHES IT — which is worth more than the green it replaces.
      //
      // A-2 hypothesises that a `Session` finalizer under a pull channel in
      // overflow freezes the isolate GROUP. Driving it needs the finalizer to
      // actually fire, and the post-site hook is what shows whether it did:
      // `z_close` drops closures that post, so a post after the attach is the
      // evidence.
      //
      // Measured: ZERO posts in the treatment arm AND zero in the control arm
      // (same shape, no pull channel). The control is what makes this
      // interpretable — a zero in the treatment arm alone would say only
      // "sessions are not collected in this harness", which is a statement
      // about the harness rather than about the hypothesis.
      //
      // ⛔ So the run COMPLETING says nothing about A-2, and this cell asserts
      // only what was actually established: the finalizer did not fire, in
      // either arm, so the hypothesis is neither confirmed nor refuted here.
      // Reported as unforced-with-evidence, which is the form A-2 authorizes
      // ("the plan runs it or records it unforced").
      final tmp = await Directory.systemTemp.createTemp('zd_falsify');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      expect(build.exitCode, 0, reason: 'clang: ${build.stderr}');

      final treatment = await _runArm(
        'session-falsifier',
        extra: ['--hook', hookPath],
      );
      final control = await _runArm(
        'session-falsifier-control',
        extra: ['--hook', hookPath],
      );

      expect(
        treatment.markerValue('FIN_HOOK_RC='),
        0,
        reason: treatment.diagnosis,
      );
      expect(
        treatment.markerValue('FIN_ALIAS='),
        1,
        reason:
            'loanedHandle did not alias the slot. '
            '${treatment.diagnosis}',
      );

      // Whatever happened, it is REPORTED rather than asserted into a shape.
      printOnFailure(
        'treatment: frozen=${treatment.frozen} '
        'posts=${treatment.markerValue('FIN_HOOK_POSTS=')} '
        'on_main=${treatment.markerValue('FIN_HOOK_ON_MAIN=')} · '
        'control: frozen=${control.frozen} '
        'posts=${control.markerValue('FIN_HOOK_POSTS=')}',
      );

      // The one thing this run DOES establish, and the only thing asserted:
      // the control shows the instrument could not fire a Session finalizer at
      // all, so neither arm speaks to the hypothesis.
      expect(
        control.markerValue('FIN_HOOK_POSTS='),
        0,
        reason:
            'the CONTROL fired a Session finalizer, which would make the '
            'treatment arm interpretable after all — A-2 is then drivable and '
            'this cell must be rewritten to assert its outcome rather than '
            'its non-drivability. ESCALATE. ${control.diagnosis}',
      );
      expect(
        treatment.markerValue('FIN_HOOK_POSTS='),
        0,
        reason: treatment.diagnosis,
      );
    }, timeout: const Timeout(Duration(minutes: 12)));
  });

  // -------------------------------------------------------------------------
  // Slice 13 — the two exclusions that were MEASURED this round
  // -------------------------------------------------------------------------
  group('Query is out of the net, and the measurement that put it there', () {
    late Directory tmp;
    late String hookPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_qdrop');
      hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('zd_query_drop POSTS on the one-session path, and not over TCP', () async {
      // ⛔ THE GROUND FOR THE EXCLUSION, reproduced. A `NativeFinalizer` routed
      // into `zd_query_drop` would make this post happen INSIDE the callback,
      // on a thread with no current isolate — `Dart_PostCObject_DL` is a Dart
      // C API and re-entering the VM from a finalizer callback is documented
      // UNDEFINED BEHAVIOUR. It was observed to WORK, which is exactly the
      // evidentiary class this seed refuses.
      //
      // ⭐ AND THE TOPOLOGY DEPENDENCE IS THE POINT: the same release posts
      // once in one process and not at all over TCP loopback, which is why
      // "it worked once" is worthless as evidence here.
      expect(haveClang, isTrue, reason: 'clang is required');

      Future<HarnessOutcome> run(String topology, int port) =>
          runBoundedHarness(
            _hookHarness,
            [
              '--hook',
              hookPath,
              '--subject',
              'query-drop',
              '--topology',
              topology,
              '--port',
              '$port',
            ],
            deadline: _deadline,
            label: 'qdrop[$topology]',
          );

      final one = await run('one', 19661);
      expect(one.frozen, isFalse, reason: one.diagnosis);
      expect(
        one.markerValue('HOOK_CONTROL_POSTS='),
        greaterThan(0),
        reason: one.diagnosis,
      );
      expect(
        one.markerValue('HOOK_POSTS_UNDER_MARKER='),
        greaterThan(0),
        reason:
            'zd_query_drop no longer posts on the one-session path. That is '
            'the whole ground for keeping Query out of the net — if it has '
            'genuinely changed, the exclusion should be revisited at the '
            'gate rather than silently kept. ${one.diagnosis}',
      );
      // The thread, recorded beside the observation as every (ii) result must
      // be: on the one-session path the post lands on the MUTATOR.
      expect(one.markerValue('HOOK_ON_MAIN='), 2, reason: one.diagnosis);

      final tcp = await run('tcp', 19662);
      expect(tcp.frozen, isFalse, reason: tcp.diagnosis);
      expect(
        tcp.markerValue('HOOK_CONTROL_POSTS='),
        greaterThan(0),
        reason: tcp.diagnosis,
      );
      expect(
        tcp.markerValue('HOOK_POSTS_UNDER_MARKER='),
        0,
        reason:
            'the TCP arm posted too, so the topology dependence this exclusion '
            'rests on no longer holds. ${tcp.diagnosis}',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Slice 15 — the documentation payload
  // -------------------------------------------------------------------------
  //
  // ⚠️ A HARD IN-SEED DELIVERABLE, NOT RELEASE WORK. "A seed does not ship
  // falsehoods it created." The Parity Release docs pass exists to reconcile
  // the shipped surface, not to repair statements this unit made false.
  group('the documentation payload', () {
    const inNet = <String>[
      'lib/src/config.dart',
      'lib/src/keyexpr.dart',
      'lib/src/bytes.dart',
      'lib/src/bytes_writer.dart',
      'lib/src/serializer.dart',
      'lib/src/deserializer.dart',
      'lib/src/publisher.dart',
      'lib/src/unstable/shm_provider.dart',
      'lib/src/unstable/shm_mut_buffer.dart',
      'lib/src/unstable/advanced_publisher.dart',
    ];
    const excluded = <String>[
      'lib/src/session.dart',
      'lib/src/querier.dart',
      'lib/src/query.dart',
      'lib/src/liveliness.dart',
      'lib/src/subscriber.dart',
      'lib/src/queryable.dart',
      'lib/src/pull_subscriber.dart',
      'lib/src/pull_queryable.dart',
      'lib/src/pull_replies.dart',
      'lib/src/unstable/advanced_subscriber.dart',
    ];

    test('every one of the twenty states the unsendability contract', () {
      for (final f in [...inNet, ...excluded]) {
        expect(
          File(f).readAsStringSync(),
          contains('cannot cross an isolate'),
          reason: '$f does not state that its class cannot cross an isolate',
        );
      }
    });

    test(
      'the ten IN the net state the net, and that it is not a substitute',
      () {
        for (final f in inNet) {
          final text = File(f).readAsStringSync();
          expect(text, contains('safety net'), reason: '$f omits the net');
          expect(
            text,
            contains('not a substitute'),
            reason:
                '$f states the net without saying it is not a substitute for '
                'explicit release — which is the sentence that stops a reader '
                'treating it as a lifecycle',
          );
        }
      },
    );

    test('the ten OUT of the net state the ABSENCE and name its ground', () {
      // ⛔ An exclusion a reader cannot see reads as an oversight, and a
      // reader who assumes the net is universal will write code that leaks.
      for (final f in excluded) {
        final text = File(f).readAsStringSync();
        expect(
          text,
          contains('No `NativeFinalizer` is attached'),
          reason: '$f does not state that it carries no finalizer',
        );
        expect(
          text,
          contains('deliberately'),
          reason: '$f states the absence without naming it as a decision',
        );
      }
    });

    test('the 21 Safe-to-call-multiple-times hits partition 10 + 10 + 1', () {
      // ⛔ THE CELL ASSERTS THE PARTITION, NOT A UNIVERSAL. An earlier plan
      // draft asserted that EVERY hit sits on a method that now detaches;
      // measured, nine of them sit on excluded classes or on
      // `ensureInitialized`, so that cell would have failed on correct code —
      // or forced a false doc edit to make it pass.
      var total = 0;
      var detaching = 0;
      var untouched = 0;
      var unrelated = 0;
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        final hits = 'Safe to call multiple times'.allMatches(text).length;
        if (hits == 0) continue;
        total += hits;
        final rel = f.path;
        if (inNet.any((p) => rel.endsWith(p.split('/').last))) {
          detaching += hits;
          expect(
            text,
            contains("detaches this object's finalizer"),
            reason: '$rel is in the net but its note does not say it detaches',
          );
        } else if (excluded.any((p) => rel.endsWith(p.split('/').last))) {
          untouched += hits;
          expect(
            text,
            isNot(contains("detaches this object's finalizer")),
            reason:
                '$rel is EXCLUDED from the net, so its note must not claim a '
                'detach. ⛔ No doc edit is made to satisfy a checklist on a '
                'class that gained no finalizer',
          );
        } else {
          unrelated += hits;
        }
      }
      expect(detaching, 10, reason: 'detaching hits');
      expect(untouched, 10, reason: 'untouched excluded hits');
      expect(unrelated, 1, reason: 'the ensureInitialized hit');
      expect(
        detaching + untouched + unrelated,
        total,
        reason: 'the partition must sum to the search own total ($total)',
      );
    });

    test('the stable door export-directive count has not moved', () {
      // ⚖️ SPLIT OUT 2026-09-12 (roadmap R8). This assertion used to sit
      // inside `CLAUDE.md describes the shipped surface`, which reads the
      // repository-root CLAUDE.md and therefore cannot run where the
      // candidate is certified (ruling 9: the public repository, whose
      // CLAUDE.md is a different document). ⛔ The count is a PRODUCT fact
      // and had no business travelling with a governance cell: moving the
      // pair wholesale would have taken a real check out of the certified
      // suite. The governance half now lives in
      // test/dev/finalizer_ownership_governance_test.dart.
      // The export count and WHAT MOVED IT, so the number stays an
      // instrument rather than becoming a rubber stamp that gets bumped
      // whenever it goes red.
      //
      // 34 -> 36 at seed [D1] slice 5: `src/log_severity.dart` and
      // `src/log_record.dart`, the two types the host log sink delivers.
      // Nothing was removed. If this goes red again, find the delta before
      // changing the number -- an export added without a plan entry is
      // exactly what this cell exists to catch.
      final exports = File('lib/zenoh.dart')
          .readAsLinesSync()
          .where((l) => l.startsWith('export'))
          .length;
      expect(exports, 36, reason: 'the Dart export count moved');
    });
  });

  // -------------------------------------------------------------------------
  // Slice 3 — a stale native fails LOUDLY, not silently
  // -------------------------------------------------------------------------
  group('a native missing an unconditional entry', () {
    late Directory stage;
    late String variant;
    var staged = false;

    setUpAll(() async {
      // A REAL native with a REAL missing entry, loaded through the REAL load
      // path. Getting all three at once takes some staging, and the
      // alternative — looking up a name that was never there — would exercise
      // the accessor rather than the loader and would not test what this cell
      // claims.
      //
      // The staging: a package root of our own whose `lib` is a symlink to the
      // real one, a copy of the package config with `zenoh_dart`'s rootUri
      // repointed at it, and a doctored native underneath. `native_lib.dart`
      // resolves its probe path from `Isolate.resolvePackageUriSync`, so the
      // repointed root is what it loads from — verified through
      // `resolvedLibraryPath` before this cell was written.
      //
      // ⚠️ NOTHING IN THE REPO IS MUTATED. An earlier design swapped the
      // shipped `.so` in place and restored it afterwards; a crash between the
      // two steps would have left the tree broken for every later run.
      // ⛔ THE VARIANT THIS PROCESS LOADED, never a literal. The staging path
      // used to read `unstable`, and under the stable native the child never
      // loaded what was staged: it ran to completion on an intact library.
      // The stable variant's first full run (1.0.0-rc.1's certification) is
      // where that surfaced. The child's `FIN_LIB` assertion below is what
      // makes a mis-stage loud from now on.
      variant = ZenohFeatures.hasUnstableApi ? 'unstable' : 'stable';
      stage = await Directory.systemTemp.createTemp('zd_stale');
      final pkg = Directory('${stage.path}/pkg/native/linux/x86_64/$variant');
      await pkg.create(recursive: true);
      await Link('${stage.path}/pkg/lib').create(
        Directory('lib').absolute.path,
      );

      // ⚠️ `objcopy --redefine-sym` DOES NOT WORK HERE, and it is the obvious
      // tool: it rewrites the static symbol table and leaves `.dynsym`
      // untouched, so the doctored library still exports the symbol. Measured
      // — the rename reported success and `nm -D` still listed the original.
      // Patching the name in `.dynstr` to an equal-length string is what
      // actually removes it from the dynamic table: the `.gnu.hash` bucket
      // then no longer matches, which is precisely "this symbol is not
      // resolvable", i.e. the stale-native condition.
      final src = File(
        'native/linux/x86_64/$variant/libzenoh_dart.so',
      ).readAsBytesSync();
      final needle = 'zd_fin_free_block '.codeUnits;
      final replacement = 'zd_fin_free_blocX '.codeUnits;
      final bytes = List<int>.of(src);
      for (var i = 0; i + needle.length <= bytes.length; i++) {
        var hit = true;
        for (var j = 0; j < needle.length; j++) {
          if (bytes[i + j] != needle[j]) {
            hit = false;
            break;
          }
        }
        if (hit) {
          bytes.setRange(i, i + replacement.length, replacement);
          staged = true;
        }
      }
      File('${pkg.path}/libzenoh_dart.so').writeAsBytesSync(bytes);
      File(
        'native/linux/x86_64/$variant/libzenohc.so',
      ).copySync('${pkg.path}/libzenohc.so');
      File('${stage.path}/harness.dart')
          .writeAsStringSync(File(_finHarness).readAsStringSync());

      final cfg = File('.dart_tool/package_config.json').readAsStringSync();
      File('${stage.path}/package_config.json').writeAsStringSync(
        cfg.replaceAllMapped(
          RegExp(r'"name":\s*"zenoh_dart",\s*"rootUri":\s*"[^"]*"'),
          (_) =>
              '"name": "zenoh_dart", '
              '"rootUri": "file://${stage.path}/pkg/"',
        ),
      );
    });

    tearDownAll(() async {
      if (stage.existsSync()) await stage.delete(recursive: true);
    });

    test('fails loudly at the first attach, naming the missing symbol', () async {
      expect(
        staged,
        isTrue,
        reason:
            'the doctored native was never produced — the symbol name was not '
            'found in the binary, so this cell would be vacuous',
      );

      // The variant is SET, not inherited: tests control their environment.
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          '--packages=${stage.path}/package_config.json',
          '${stage.path}/harness.dart',
          '--arm',
          'deser-drop',
        ],
        environment: {'ZENOH_DART_VARIANT': variant},
      );
      final out = StringBuffer();
      process.stdout.transform(systemEncoding.decoder).listen(out.write);
      process.stderr.transform(systemEncoding.decoder).listen(out.write);
      final code = await process.exitCode.timeout(_deadline);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // ⛔ "NEVER A SILENT NO-NET" is the whole point. A missing entry that
      // degraded to "no finalizer attached" would leave the contract looking
      // enforced while it was not, and nothing would ever say so.
      expect(
        code,
        isNot(0),
        reason: 'the stale native ran to completion. Output:\n$out',
      );
      expect(
        out.toString(),
        contains('zd_fin_free_block'),
        reason: 'the failure did not name the missing symbol. Output:\n$out',
      );
      expect(
        out.toString(),
        contains('Invalid argument'),
        reason:
            'the failure was not the ArgumentError `lookup` throws. That is '
            'the type this cell asserts, measured — not StateError. '
            'Output:\n$out',
      );
      // At FIRST ATTACH, not at load: the harness got as far as printing its
      // ready marker, which happens after initialization.
      expect(
        out.toString(),
        contains('FIN_READY'),
        reason:
            'the failure happened before the harness started, i.e. at load '
            'rather than at first attach. Output:\n$out',
      );
      // ⭐ AND IT FAILED IN THE LIBRARY THIS CELL DOCTORED. Without this, a
      // child that loaded some other, intact native reads as "ran to
      // completion" — which is how the wrong staging variant presented —
      // and a child failing for an unrelated reason on an unrelated library
      // could satisfy the assertions above.
      final loaded = RegExp(
        r'FIN_LIB=(\S+)',
      ).firstMatch(out.toString())?.group(1);
      expect(
        loaded,
        isNotNull,
        reason: 'the child never reported the library it loaded. Output:\n$out',
      );
      expect(
        File(loaded!).resolveSymbolicLinksSync(),
        File(
          '${stage.path}/pkg/native/linux/x86_64/$variant/libzenoh_dart.so',
        ).resolveSymbolicLinksSync(),
        reason: 'the child did not load the doctored native. Output:\n$out',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Slice 3 — criterion (ii), MEASURED for the entries this slice declares
  // -------------------------------------------------------------------------
  //
  // ⛔ THIS IS THE ADMISSION GATE FOR SLICES 4-7. Criterion (ii) — *does this
  // class's native release transitively reach a Dart C API* — was READ from
  // source for every class in the map, and reading it is exactly what cost two
  // admission rows this round: `z_undeclare_querier` posts a getter's sentinel
  // from inside the undeclare, and `zd_query_drop` posts TWICE on the
  // one-session path. Neither was going to be found by reading harder.
  //
  // ⚠️ A (ii) RESULT WITHOUT ITS TOPOLOGY IS NOT A RESULT. The same release
  // posts or does not depending on whether the peers share a process, so every
  // row below runs in both.
  group('criterion (ii), measured', () {
    late Directory tmp;
    late String hookPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_posthook');
      hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
      if (!haveClang) {
        printOnFailure('clang build failed: ${build.stderr}');
      }
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<HarnessOutcome> runHook(
      String subject,
      String topology,
      int port, {
      String? marker,
    }) => runBoundedHarness(
      _hookHarness,
      [
        '--hook',
        hookPath,
        '--subject',
        subject,
        '--topology',
        topology,
        '--port',
        '$port',
        if (marker != null) ...['--marker', marker],
      ],
      deadline: _deadline,
      label: 'hook[$subject/$topology]',
    );

    test('the hook is calibrated BOTH ways, here, where it is built', () async {
      expect(haveClang, isTrue, reason: 'clang is required to build the hook');

      // POSITIVE. `Querier.close()` with a `get()` in flight is a release
      // MEASURED to post — the shape that disqualified `Querier` from the
      // net. An instrument that reports 0 everywhere has not been shown to
      // see anything, and it must be shown before slices 4-7 rely on it.
      final pos = await runHook('querier-inflight', 'one', 19600);
      expect(pos.frozen, isFalse, reason: pos.diagnosis);
      expect(pos.markerValue('HOOK_INSTALL_RC='), 0, reason: pos.diagnosis);
      expect(
        pos.markerValue('HOOK_POSTS='),
        greaterThan(0),
        reason:
            'the hook saw no posts at all on a shape measured to post. '
            '${pos.diagnosis}',
      );
      expect(
        pos.markerValue('HOOK_POSTS_UNDER_MARKER='),
        greaterThan(0),
        reason:
            'the hook saw posts but never with `z_undeclare_querier` on '
            'the stack — the marker filter is not resolving. ${pos.diagnosis}',
      );

      // NEGATIVE — and it is the MARKER that is being calibrated, not the
      // topology.
      //
      // ⚠️ THE PLAN ASKED FOR A DIFFERENT NEGATIVE AND IT CANNOT HOLD. It
      // specified the same querier shape over TCP loopback reading 0. Measured,
      // it reads 1 under the marker in BOTH topologies — and the seed itself
      // says why: its `Querier` row records this shape as
      // "Topology-independent", because `z_undeclare_querier` drops the
      // querier's OWN getter closure locally, wherever the queryable lives.
      // The plan's negative control would have gone red on correct code.
      //
      // What actually needs calibrating is whether the marker filter
      // DISCRIMINATES — a filter that matched every frame would look identical
      // to one that worked. So: the same posting shape, armed on a symbol that
      // exists but is nowhere on that stack. Posts still seen, none attributed.
      final neg = await runHook(
        'querier-inflight',
        'one',
        19601,
        marker: 'zd_config_drop',
      );
      expect(neg.frozen, isFalse, reason: neg.diagnosis);
      expect(
        neg.markerValue('HOOK_POSTS='),
        greaterThan(0),
        reason: neg.diagnosis,
      );
      expect(
        neg.markerValue('HOOK_POSTS_UNDER_MARKER='),
        0,
        reason:
            'the marker matched a symbol that is not on that stack, so it '
            'is matching everything and attributes nothing. ${neg.diagnosis}',
      );
    });

    // The five value-drop entries this slice declares, plus the degenerate
    // row. Each gates a later slice: a post on any of them is escalated to the
    // gate, not reclassified here.
    var port = 19602;
    for (final subject in const [
      'config',
      'bytes',
      'keyexpr',
      'writer',
      'serializer',
    ]) {
      for (final topology in const ['one', 'tcp']) {
        final assignedPort = port++;
        test('$subject: its release reaches no Dart post ($topology)', () async {
          expect(haveClang, isTrue, reason: 'clang is required');
          final o = await runHook(subject, topology, assignedPort);
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.markerValue('HOOK_INSTALL_RC='), 0, reason: o.diagnosis);

          // ⛔ THE IN-RUN CONTROL IS READ FIRST, DELIBERATELY. "0 posts" is
          // also what a hook that failed to install, or that wrapped an empty
          // slot, reports — and the calibration cell above ran in a DIFFERENT
          // process and cannot speak for this one. A run whose control reads 0
          // has proved nothing about its subject.
          expect(
            o.markerValue('HOOK_CONTROL_POSTS='),
            greaterThan(0),
            reason:
                "the in-run control saw no posts, so this run's zero is not "
                'evidence about $subject — the instrument was not live. '
                '${o.diagnosis}',
          );

          expect(
            o.markerValue('HOOK_POSTS_UNDER_MARKER='),
            0,
            reason:
                "$subject's release posted to a Dart port in the $topology "
                'topology. That is criterion (ii) failing, which sends this '
                'class OUT of the finalized net — ESCALATE to the gate, do '
                'not reclassify. ${o.diagnosis}',
          );
        });
      }
    }

    test('ZDeserializer is DEGENERATE, not a measured zero', () async {
      // ⚠️ Its whole release is a bare `free` with no canon entry beneath it,
      // so there is nothing to hook. A row reading "0 posts" here would LOOK
      // like evidence and is not — the honest record is "n/a: no canon call",
      // and this cell exists to make that distinction explicit rather than to
      // add a zero to the table.
      expect(haveClang, isTrue, reason: 'clang is required');
      final o = await runHook('deserializer', 'one', 19612);
      expect(o.frozen, isFalse, reason: o.diagnosis);
      expect(
        o.markerValue('HOOK_MARKER='),
        isNull,
        reason:
            'the harness armed a symbol for a release that makes no canon '
            'call; the degenerate row must arm nothing. ${o.diagnosis}',
      );
      expect(
        o.markerValue('HOOK_CONTROL_POSTS='),
        greaterThan(0),
        reason: o.diagnosis,
      );
    });

    test('the hook reaches no shipped path', () async {
      // Swapping an exported writable global is legitimate for a measurement
      // and unacceptable anywhere else, so the confinement is asserted rather
      // than trusted.
      //
      // ⚠️ THE SEARCH TARGETS THE SITE, NOT THE WORD, and the first cut of
      // this cell did not — it went red on `lib/src/bindings.dart`, whose
      // GENERATED dartdoc quotes `Dart_PostCObject_DL` in a sentence
      // describing how samples reach the isolate. That is a comment mention,
      // and this project's own export-liveness rule already says comment
      // mentions do not count as references. A search for a word, run over a
      // tree that documents that word, cannot return zero — it is self-
      // refuting by construction and it reads as proof.
      //
      // So: comments are stripped before matching, and the file-name probe
      // (`post_hook`) runs over everything since no comment in `lib` has any
      // business naming a test helper.
      String stripComments(String text) => text
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///');
          })
          .join('\n');

      final libHits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        if (text.contains('post_hook') ||
            stripComments(text).contains('Dart_PostCObject_DL')) {
          libHits.add(f.path);
        }
      }
      expect(
        libHits,
        isEmpty,
        reason: 'the post-site hook is referenced from shipped code: $libHits',
      );

      // ⛔ POSITIVE CONTROL FOR THE SEARCH ITSELF, including the comment
      // stripper: an empty result above says nothing about `lib/` if the
      // matcher cannot see a real occurrence. The hook's own source contains
      // the symbol on a CODE line, so both halves must find it.
      final hookSource = File('test/helpers/post_hook.c').readAsStringSync();
      expect(
        hookSource,
        contains('Dart_PostCObject_DL'),
        reason: 'the search pattern does not match its own subject',
      );
      expect(
        stripComments(hookSource),
        contains('Dart_PostCObject_DL'),
        reason:
            'the comment stripper removed the only real occurrence — it is '
            'over-eager, and the lib/ result above is therefore vacuous',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Slice 8 — criterion (ii), the COMPLETE table
  // -------------------------------------------------------------------------
  //
  // Slice 3 measured the five value-drop entries it declares, because those
  // gate slices 4–7 and the gate ruling is *whichever slice first needs the
  // hook builds it*. This slice CONSUMES that hook — it adds no helper source
  // — and produces the full ten-class × two-topology table, which is what
  // gates 9, 10 and 11.
  //
  // ⚠️ WHY THIS IS NOT BOOKKEEPING. Criterion (ii) was READ FROM SOURCE for
  // every class in the map, and reading it is exactly what cost two admission
  // rows this round: `z_undeclare_querier` posts a getter's sentinel from
  // inside the undeclare, and `zd_query_drop` posts TWICE on the one-session
  // path. `Publisher(ml:off)` and `AdvancedPublisher(ml:off)` are the two rows
  // whose (ii) was read statically in the plan AND in the 27th pass — the same
  // provenance defect, twice, on rows nobody re-derived. They are measured
  // here.
  //
  // ⚠️ CRITERION (ii) IS A PROPERTY OF THE NATIVE RELEASE ENTRY, NOT OF THE
  // FINALIZER. `zd_publisher_drop` posts or it does not, whether it is reached
  // from `close()` or from a callback — so every arm drives the SHIPPED
  // release path and needs no finalizer to exist. That is what lets this
  // measure a class before it is admitted to the net rather than after.
  group('criterion (ii), the complete net table', () {
    late Directory tmp;
    late String hookPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_posthook8');
      hookPath = '${tmp.path}/post_hook.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-g',
        '-o',
        hookPath,
        'test/helpers/post_hook.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
      if (!haveClang) printOnFailure('clang build failed: ${build.stderr}');
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<HarnessOutcome> runHook(String subject, String topology, int port) =>
        runBoundedHarness(
          _hookHarness,
          [
            '--hook',
            hookPath,
            '--subject',
            subject,
            '--topology',
            topology,
            '--port',
            '$port',
          ],
          deadline: _deadline,
          label: 'hook8[$subject/$topology]',
        );

    // ⛔ CALIBRATION IS RE-ASSERTED WHERE THE TABLE IS PRODUCED, not inherited
    // across a slice boundary. The topology is what moves between runs, not
    // the entry, and a table of zeros from an instrument nobody re-checked in
    // this file is not a table.
    test('the hook still sees a post, here, in this slice', () async {
      expect(haveClang, isTrue, reason: 'clang is required to build the hook');
      final pos = await runHook('querier-inflight', 'one', 19630);
      expect(pos.frozen, isFalse, reason: pos.diagnosis);
      expect(pos.markerValue('HOOK_INSTALL_RC='), 0, reason: pos.diagnosis);
      expect(
        pos.markerValue('HOOK_POSTS_UNDER_MARKER='),
        greaterThan(0),
        reason:
            'the instrument saw nothing on a shape measured to post, so every '
            'zero below is uninterpretable. ${pos.diagnosis}',
      );
    });

    // The four rows Slice 3 does not cover. Each one GATES a later slice, and
    // a post on any of them sends that class OUT of the net.
    var port = 19632;
    for (final entry in const <({String subject, String gates})>[
      (subject: 'publisher', gates: 'slice 9'),
      (subject: 'advpublisher', gates: 'slice 9'),
      (subject: 'shmprovider', gates: 'slice 10'),
      (subject: 'shmmut', gates: 'slice 11'),
    ]) {
      for (final topology in const ['one', 'tcp']) {
        final assignedPort = port++;
        test(
          '${entry.subject}: its release reaches no Dart post ($topology)',
          skip: ZenohFeatures.hasSharedMemory
              ? false
              : 'requires the unstable variant',
          () async {
            expect(haveClang, isTrue, reason: 'clang is required');
            final o = await runHook(entry.subject, topology, assignedPort);
            expect(o.frozen, isFalse, reason: o.diagnosis);
            expect(o.markerValue('HOOK_INSTALL_RC='), 0, reason: o.diagnosis);

            // The in-run control is read FIRST. "0 posts" is also what a hook
            // that failed to install reports, and the calibration above ran in
            // a different process.
            expect(
              o.markerValue('HOOK_CONTROL_POSTS='),
              greaterThan(0),
              reason:
                  "the in-run control saw no posts, so this run's zero is not "
                  'evidence about ${entry.subject}. ${o.diagnosis}',
            );

            expect(
              o.markerValue('HOOK_POSTS_UNDER_MARKER='),
              0,
              reason:
                  "${entry.subject}'s release posted to a Dart port in the "
                  '$topology topology. Criterion (ii) fails, which sends the '
                  'class OUT of the net and invalidates ${entry.gates} — '
                  'ESCALATE to the gate, do not reclassify. ${o.diagnosis}',
            );
          },
        );
      }
    }

    test('Slice 3-s five rows AGREE when re-run here', () async {
      // ⚠️ A disagreement is itself the finding: it would mean the instrument
      // or the topology moved between slices, and neither table could then be
      // trusted. Re-run in the `one` topology, which is the one where a drop
      // can run canon's callbacks inline and is therefore the harder side.
      expect(haveClang, isTrue, reason: 'clang is required');
      var p = 19640;
      for (final subject in const [
        'config',
        'bytes',
        'keyexpr',
        'writer',
        'serializer',
      ]) {
        final o = await runHook(subject, 'one', p++);
        expect(o.frozen, isFalse, reason: o.diagnosis);
        expect(
          o.markerValue('HOOK_CONTROL_POSTS='),
          greaterThan(0),
          reason: o.diagnosis,
        );
        expect(
          o.markerValue('HOOK_POSTS_UNDER_MARKER='),
          0,
          reason:
              '$subject disagrees with the reading Slice 3 took. That is not '
              'a $subject finding — it means the instrument or the topology '
              'moved between slices. ${o.diagnosis}',
        );
      }
    });
  });
}
