// Unit [SHM] shared-memory-lifetime, slice 7 — the shim captures canon's own
// text when a provider cannot be created.
//
// ⭐ WHY THIS FILE EXISTS. `zd_shm_provider_new` was a bare pass-through of
// `z_shm_provider_default_new`, and canon answers EVERY rejection class with
// the same `-1` (Z_EINVAL): a pool too small to back the Talc allocator, a
// pool over the host's locked-memory budget, and a pool beyond what canon's
// segment element index can address. One code for three different rules, so
// the single signal a caller gets cannot say which rule they broke.
//
// Canon does distinguish them — in `zc_get_last_error`'s text. This slice
// widens the entry to carry that text out in caller-supplied storage, the
// seventh site to use the shipped err_buf/err_cap/err_len triple. Slice 8
// renders it at the Dart surface; nothing here touches `ShmProvider`.
//
// ⛔ NO CANON WORDING IS ASSERTED ANYWHERE IN THIS FILE. The texts are
// canon's and an upstream edit to any of them is not a defect in this
// binding, so the cells assert that the three classes DIFFER FROM ONE
// ANOTHER, never that any equals a literal.
//
// ⛔ NO HOST NUMBER IS WRITTEN DOWN. The locked-memory budget is read from
// `/proc/self/limits`, the cap from `src/zenoh_dart.h`, and the
// beyond-representable size is derived from the width of canon's element
// index. A cell of this file asserts that discipline against its own source.
//
// ⚠️ THE PLAN'S TEST 5 IS UNSATISFIABLE AS WRITTEN AND IS REPLACED. See the
// second group below for the measurement and the honest substitute.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// This file's own path, package-relative. The suite runs with `package/` as
/// its working directory (`scripts/test.sh` cd's there), and one cell reads
/// this source back to check that no host number was written into it.
const _selfPath = 'test/shm_provider_error_test.dart';

/// Bytes allocated BEYOND the capacity the shim is told about, poisoned and
/// then asserted untouched.
///
/// This is what turns "it truncated" into "it truncated AND wrote nothing
/// past the capacity it was handed" — a capture that overran would otherwise
/// pass every length assertion in the file.
const _guardBytes = 32;

/// The byte every caller buffer is filled with before a call.
///
/// A capture that writes nothing leaves this in place, so "the buffer is
/// untouched" is observable rather than assumed.
const _poison = 0xAB;

/// The value `*err_len` is set to before a call.
///
/// Negative and impossible as a length, so a path that fails to write the
/// out-length is distinguishable from one that writes 0. Without it the
/// success cell would pass on `calloc`'s own zeroing.
const _lenSentinel = -7;

/// A pool size this host satisfies.
///
/// Where the floor sits is host- and pin-specific and is measured in
/// `development/research/probes-seed7-pool-floor-20260819/`; this is the size
/// the shipped SHM cells already use, not a fresh claim about the floor.
const _satisfiablePool = 65536;

/// The bit width of canon's segment element index.
///
/// Canon addresses a segment's elements with a 32-bit `ElemIndex` and refuses
/// a segment whose element count it cannot index. Everything below is
/// computed from this width, so the fixture is a statement about the type
/// rather than about one machine.
const _elemIndexBits = 32;

/// The largest pool canon still routes to the POSIX segment path.
///
/// ⚠️ MEASURED AT THIS PIN, and it is one MORE than the naive reading of the
/// width. A bisection over `zd_shm_provider_new` put the boundary at exactly
/// 2^32 accepted and 2^32 + 1 refused — canon's own off-by-one against
/// `u32::MAX`, not ours. Recorded because the first version of this file
/// assumed the boundary sat AT 2^32, drove the range class with that size,
/// and got the over-budget text instead: the two classes collided and the
/// difference cell went red. That red is the reason this constant exists.
const int _elemIndexCeiling = 1 << _elemIndexBits;

/// A pool size canon's element index cannot address.
///
/// Twice the index space rather than one byte past the measured boundary:
/// the cell's subject is the rejection CLASS, not canon's exact edge, and
/// sitting on the edge would make it sensitive to an upstream off-by-one it
/// is not trying to watch.
const int _beyondElemIndex = _elemIndexCeiling * 2;

/// The shim's own bound on a captured message, READ FROM THE HEADER.
///
/// `ZD_LAST_ERROR_CAP` is one stage of the truncation chain and the shim
/// clamps to it whatever capacity a caller passes. Reading it keeps this file
/// honest if the bound ever moves.
final int _shimCap = _readShimCap();

int _readShimCap() {
  final header = File('../src/zenoh_dart.h').readAsStringSync();
  final match = RegExp(
    r'^#define ZD_LAST_ERROR_CAP (\d+)$',
    multiLine: true,
  ).firstMatch(header);
  if (match == null) {
    fail('ZD_LAST_ERROR_CAP is not declared in ../src/zenoh_dart.h');
  }
  return int.parse(match.group(1)!);
}

/// What one call to the widened entry returned and wrote.
typedef _Attempt = ({int rc, int detailLen, String? detail, Uint8List raw});

/// Drives `zd_shm_provider_new` at the seam with storage this call owns.
///
/// Allocate-last / outer-finally: every block is released on every path, and
/// a successful creation is dropped here so a cell never leaks a segment —
/// an SHM segment a process leaks is gone for the life of that process.
_Attempt _createProvider(int poolSize, {int? cap}) {
  final capacity = cap ?? _shimCap;
  final total = capacity + _guardBytes;
  final slot = calloc.allocate<Void>(bindings.zd_shm_provider_sizeof());
  final errBuf = calloc<Uint8>(total);
  final errLen = calloc<Int>();
  try {
    errBuf.asTypedList(total).fillRange(0, total, _poison);
    errLen.value = _lenSentinel;
    final rc = bindings.zd_shm_provider_new(
      slot.cast(),
      poolSize,
      errBuf,
      capacity,
      errLen,
    );
    if (rc == 0) bindings.zd_shm_provider_drop(slot.cast());
    final raw = Uint8List.fromList(errBuf.asTypedList(total));
    final n = errLen.value;
    return (
      rc: rc,
      detailLen: n,
      // Lenient, mirroring the shipped Dart-side decode: the shim's clamp can
      // cut a multi-byte sequence, and U+FFFD beats a throw while reporting
      // an error.
      detail: n > 0
          ? utf8.decode(raw.sublist(0, n), allowMalformed: true)
          : null,
      raw: raw,
    );
  } finally {
    calloc
      ..free(errLen)
      ..free(errBuf)
      ..free(slot);
  }
}

/// The host's own `RLIMIT_MEMLOCK` soft limit in bytes.
///
/// Null when the host does not bound locked memory, or when the file cannot
/// be read — in which case the over-budget rejection class is not drivable
/// here and the cells that need it say so rather than inventing a number.
int? _lockedMemoryLimit() {
  const label = 'Max locked memory';
  final file = File('/proc/self/limits');
  if (!file.existsSync()) return null;
  for (final line in file.readAsLinesSync()) {
    if (!line.startsWith(label)) continue;
    final fields = line.substring(label.length).trim().split(RegExp(r'\s+'));
    if (fields.isEmpty) return null;
    // The soft limit is the first field; "unlimited" parses to null, which
    // is exactly the undrivable case.
    return int.tryParse(fields.first);
  }
  return null;
}

/// A pool size the host's locked-memory budget cannot back, DERIVED from it.
///
/// ⛔ `8` is a statement about one machine. Four times whatever this host
/// allows is a statement about the rule. Null when the budget is unbounded,
/// or when four times it would clear the element-index ceiling and land in
/// the beyond-representable class instead — at which point the two cells
/// would stop being about different rules.
int? _overLockedMemoryBudget() {
  final limit = _lockedMemoryLimit();
  if (limit == null || limit <= 0) return null;
  final size = limit * 4;
  return size > _elemIndexCeiling ? null : size;
}

String _nativePath(String variant) =>
    'native/linux/x86_64/$variant/libzenoh_dart.so';

/// Every `zd_`-prefixed dynamic symbol defined by [variant]'s native.
///
/// The linker is the only instrument that can answer this: every SHM entry
/// sits behind `#if (Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API)`, so
/// a text scan of the header reads identically for both variants.
Set<String> _dynamicZdSymbols(String variant) {
  final path = _nativePath(variant);
  expect(
    File(path).existsSync(),
    isTrue,
    reason:
        'both variants must be built for this cell to mean anything: '
        '$path is missing',
  );
  final result = Process.runSync('nm', ['-D', '--defined-only', path]);
  expect(
    result.exitCode,
    0,
    reason: 'nm failed on $variant: ${result.stderr}',
  );
  return (result.stdout as String)
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((parts) => parts.length >= 3 && parts[2].startsWith('zd_'))
      .map((parts) => parts[2])
      .toSet();
}

void main() {
  group(
    'zd_shm_provider_new carries canon detail',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('a pool too small to back an allocator yields canon own text', () {
        final attempt = _createProvider(1);

        expect(
          attempt.rc,
          isNot(0),
          reason: 'a one-byte pool cannot back an allocator; canon refuses it',
        );
        expect(
          attempt.rc,
          isNegative,
          reason:
              'the code is canon own, passed through unchanged. The shim '
              'mints only POSITIVE codes at this seam, so a negative one came '
              'from canon',
        );
        expect(
          attempt.detailLen,
          greaterThan(0),
          reason:
              'canon left text for this failure and the widened entry '
              'must have copied it into the caller storage',
        );
        expect(
          attempt.raw[attempt.detailLen],
          isZero,
          reason:
              'the copy is NUL-terminated INSIDE the capacity, matching '
              'the six shipped capture sites',
        );
        expect(
          attempt.raw.sublist(0, attempt.detailLen),
          isNot(contains(0)),
          reason: 'the reported length must cover text, not the terminator',
        );
        expect(attempt.detail, isNotNull);
        expect(attempt.detail!.trim(), isNotEmpty);
      });

      test('a satisfiable pool leaves the caller storage untouched', () {
        // ONE buffer, TWO calls, and that is the whole point: the claim is
        // that a caller cannot render text an EARLIER failure left behind.
        // Two independently-allocated buffers could not show it.
        //
        // ⭐ THE RE-GROUNDING BETWEEN THE CALLS IS LOAD-BEARING, and it is
        // here because the cell was MEASURED BLIND without it. A perturbation
        // that captured unconditionally and then forced the out-length back
        // to 0 passed the whole file: canon's last error is thread-local and
        // survives a successful call, so the bytes re-copied on the success
        // path were IDENTICAL to the ones the failing call had already
        // written, and a straight before/after comparison could not tell
        // "did not write" from "wrote the same thing again". Poisoning the
        // buffer first replaces the comparison ground with something canon
        // would never produce, and the same perturbation now goes red.
        //
        // ⚠️ The two assertions below are INDEPENDENT instruments, not a
        // belt-and-braces pair: the out-length one catches a missing
        // pre-call reset, and the untouched-storage one catches a write that
        // reports nothing. Neither subsumes the other.
        final capacity = _shimCap;
        final slot = calloc.allocate<Void>(bindings.zd_shm_provider_sizeof());
        final errBuf = calloc<Uint8>(capacity);
        final errLen = calloc<Int>();
        try {
          errBuf.asTypedList(capacity).fillRange(0, capacity, _poison);

          errLen.value = _lenSentinel;
          final failRc = bindings.zd_shm_provider_new(
            slot.cast(),
            1,
            errBuf,
            capacity,
            errLen,
          );
          expect(failRc, isNot(0));
          final staleLen = errLen.value;
          expect(
            staleLen,
            greaterThan(0),
            reason:
                'the first call must leave text behind, or the second '
                'call proves nothing',
          );
          // Ground the buffer with something canon cannot produce, so that
          // a re-copy of the same message is distinguishable from silence.
          errBuf.asTypedList(capacity).fillRange(0, capacity, _poison);
          final beforeSuccess = Uint8List.fromList(
            errBuf.asTypedList(capacity),
          );

          errLen.value = _lenSentinel;
          final okRc = bindings.zd_shm_provider_new(
            slot.cast(),
            _satisfiablePool,
            errBuf,
            capacity,
            errLen,
          );
          expect(
            okRc,
            isZero,
            reason:
                'this pool size is satisfiable on this host; if it is not '
                'the cell below is measuring the wrong path',
          );
          expect(
            errLen.value,
            isZero,
            reason:
                'the out-length is written on EVERY path, success '
                'included. A caller that reads the buffer on the strength of '
                'the length can therefore never render the previous failure',
          );
          expect(
            errBuf.asTypedList(capacity),
            equals(beforeSuccess),
            reason:
                'the success path must not touch the caller storage at '
                'all — not even to write a terminator, which is what an '
                'unconditional capture would do',
          );

          bindings.zd_shm_provider_drop(slot.cast());
        } finally {
          calloc
            ..free(errLen)
            ..free(errBuf)
            ..free(slot);
        }
      });

      test('the three rejection classes are distinguishable by their text', () {
        final overBudget = _overLockedMemoryBudget();
        if (overBudget == null) {
          markTestSkipped(
            'this host does not bound locked memory, so the over-budget '
            'rejection class is not drivable here',
          );
          return;
        }

        final tooSmall = _createProvider(1);
        final overLimit = _createProvider(overBudget);
        final beyondRange = _createProvider(_beyondElemIndex);

        for (final attempt in <_Attempt>[tooSmall, overLimit, beyondRange]) {
          expect(attempt.rc, isNot(0));
          expect(
            attempt.detailLen,
            greaterThan(0),
            reason: 'every rejection class must carry canon own explanation',
          );
        }

        // The motivation, asserted rather than asserted-about: the code alone
        // cannot tell these apart. If canon ever mints distinct codes this
        // goes red, and that is a change worth being told about.
        expect(
          <int>{tooSmall.rc, overLimit.rc, beyondRange.rc},
          hasLength(1),
          reason:
              'three different rules, one return code — which is why the '
              'text has to travel',
        );

        // ⛔ DIFFERENCE, NEVER A LITERAL. The wording is canon own and a pin
        // on it would break on any upstream edit.
        expect(tooSmall.detail, isNot(overLimit.detail));
        expect(overLimit.detail, isNot(beyondRange.detail));
        expect(tooSmall.detail, isNot(beyondRange.detail));
      });

      // --- Edge cases ---

      test(
        'the capture obeys the capacity it is handed and the shipped cap',
        () {
          const smallCap = 16;

          final full = _createProvider(1);
          expect(
            full.detailLen,
            greaterThan(smallCap),
            reason:
                'the fixture message must be longer than the small capacity '
                'below, or the truncation is never exercised',
          );

          final clipped = _createProvider(1, cap: smallCap);
          expect(
            clipped.detailLen,
            smallCap - 1,
            reason:
                'a NUL terminator is written inside the capacity, so at '
                'most cap - 1 detail bytes are copied',
          );
          expect(clipped.raw[smallCap - 1], isZero);
          expect(
            clipped.raw.sublist(0, smallCap - 1),
            equals(full.raw.sublist(0, smallCap - 1)),
            reason:
                'truncation is a PREFIX of the same message, not a '
                'differently-built short string',
          );
          expect(
            clipped.raw.sublist(smallCap),
            everyElement(_poison),
            reason:
                'the shim must never write past the capacity it was told, '
                'whatever canon had to say',
          );

          // The shipped clamp, as an upper bound. ⚠️ Stated honestly: no canon
          // message this seam produces is anywhere near the cap, so this cell
          // asserts the bound rather than exercising it.
          final generous = _createProvider(1, cap: _shimCap * 4);
          expect(
            generous.detailLen,
            lessThanOrEqualTo(_shimCap - 1),
            reason:
                'the shim clamps to ZD_LAST_ERROR_CAP - 1 whatever capacity '
                'it is handed, so a larger buffer buys nothing',
          );
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  // The variant question, and the plan criterion it replaces.
  // -------------------------------------------------------------------------
  //
  // ⛔ THE PLAN'S TEST 5 CANNOT HOLD. It asks that the out-length still be
  // written as 0 on the stable variant, "when the guarded body is compiled
  // out". `zd_shm_provider_new` is not compiled out in BODY — the whole
  // function is absent from the stable native, because it lives inside
  // `#if (Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API)`, which is where
  // the plan's own later criterion requires it to stay. There is no
  // out-length to observe on stable because there is no entry to call.
  //
  // ⭐ THE PROPERTY IS REAL, IT JUST BELONGS SOMEWHERE ELSE.
  // `_zd_capture_last_error` is unguarded AS A FUNCTION — only its body is
  // guarded — precisely because its five config callers exist on BOTH
  // variants, and it is those callers that read 0 on stable. That is asserted
  // in `test/last_error_binding_test.dart`, not here.
  //
  // ▶ The honest form for THIS entry is structural, and it is the cell below.
  group('the stable native carries no SHM entry at all', () {
    test('the entry is present on unstable and absent on stable', () {
      final unstable = _dynamicZdSymbols('unstable');
      final stable = _dynamicZdSymbols('stable');

      // The control, first: without it an `nm` that silently produced nothing
      // would report every absence below as a pass. `zd_config_from_str` is
      // one of the five capture sites this slice copies, and it is unguarded.
      expect(
        stable,
        contains('zd_config_from_str'),
        reason:
            'positive control — nm must be able to see stable symbols at '
            'all, or the absences below prove nothing',
      );
      expect(unstable, contains('zd_config_from_str'));

      expect(
        unstable,
        contains('zd_shm_provider_new'),
        reason: 'the widened entry ships on the unstable variant',
      );
      expect(
        stable,
        isNot(contains('zd_shm_provider_new')),
        reason:
            'there is no entry to call on stable, which is why this '
            'entry has no out-length property to observe there',
      );

      // And it is not alone: the whole SHM family is absent, so Android — a
      // build with neither feature — is excluded by the same guard.
      expect(
        stable.where((s) => s.toLowerCase().contains('shm')),
        isEmpty,
        reason: 'the SHM family is guarded as a whole',
      );
      expect(
        unstable.where((s) => s.toLowerCase().contains('shm')),
        isNotEmpty,
        reason: 'control for the filter above',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The discipline this file owes about its own fixtures.
  // -------------------------------------------------------------------------
  group('the sizes are derived, never written down', () {
    test('the over-budget size comes from the host own limit', () {
      final limit = _lockedMemoryLimit();
      if (limit == null) {
        markTestSkipped(
          'this host does not bound locked memory, so there is no limit to '
          'derive from',
        );
        return;
      }

      final derived = _overLockedMemoryBudget();
      expect(derived, isNotNull);
      expect(
        derived! % limit,
        isZero,
        reason:
            'the size must be a multiple of the host budget, so it moves '
            'when the host does',
      );
      expect(derived, greaterThan(limit));

      final source = File(_selfPath).readAsStringSync();
      expect(
        source,
        contains('/proc/self/limits'),
        reason: 'the derivation must read the host, not a table',
      );
      expect(
        source,
        isNot(contains('$limit')),
        reason:
            'the host own locked-memory budget must appear nowhere in '
            'this file as a literal',
      );
      expect(
        source,
        isNot(contains('$derived')),
        reason:
            'nor may the derived size, which would be the same claim '
            'about one machine written one multiplication later',
      );
    });

    test('the beyond-representable size comes from an index width', () {
      final source = File(_selfPath).readAsStringSync();
      for (final derived in <int>[_elemIndexCeiling, _beyondElemIndex]) {
        expect(
          source,
          isNot(contains('$derived')),
          reason:
              'every size here is computed from the element-index width, '
              'so no byte count is ever typed out',
        );
      }
      expect(
        _beyondElemIndex,
        greaterThan(_elemIndexCeiling),
        reason:
            'the fixture must clear the ceiling canon still accepts, or '
            'it drives the over-budget class instead',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Slice 8 — the Dart surface renders canon's detail
  // ---------------------------------------------------------------------------

  group(
    'ShmProvider renders canon detail at the throw',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('the thrown exception carries canon own text', () {
        // The base text is unchanged, so every message assertion written
        // against the old form still holds; canon's own sentence is appended
        // after a colon, which is what the enriching factory does.
        Object? thrown;
        try {
          ShmProvider(size: 1);
        } on Object catch (e) {
          thrown = e;
        }
        expect(thrown, isA<ZenohException>());
        final ex = thrown! as ZenohException;

        expect(
          ex.message,
          startsWith('Failed to create SHM provider'),
          reason: 'the base text is a superset contract; it must survive',
        );
        expect(
          ex.message.length,
          greaterThan('Failed to create SHM provider'.length + 1),
          reason: 'nothing of canon own text reached the message',
        );
        // The code and its canon name still render, unchanged by enrichment.
        expect(ex.toString(), contains('(code: ${ex.returnCode})'));
        expect(ex.toString(), contains('[Z_EINVAL]'));
      });

      test(
        'the over-budget class is distinguishable from the too-small one',
        () {
          final overBudget = _overLockedMemoryBudget();
          if (overBudget == null) {
            markTestSkipped(
              'this host reports no finite locked-memory budget, or four times '
              'it clears the element-index ceiling, so the two classes cannot '
              'be driven apart here',
            );
            return;
          }

          String messageFor(int size) {
            try {
              ShmProvider(size: size).close();
            } on ZenohException catch (e) {
              return e.message;
            }
            return fail('a pool of $size was expected to be refused');
          }

          final tooSmall = messageFor(1);
          final budget = messageFor(overBudget);

          // ⛔ ASSERTED AS A DIFFERENCE, NEVER AS A LITERAL. The wording is
          // canon's; a pin on it would break on any upstream edit and would be
          // reporting an upstream change as a defect here.
          expect(
            tooSmall,
            isNot(budget),
            reason:
                'both classes rendered the same message, so the caller still '
                'cannot tell which rule they broke -- which is the defect this '
                'slice exists to close',
          );
          // And the distinction is CANON'S, not one this binding constructed:
          // both carry the same rc, so nothing here could have branched on it.
          expect(_createProvider(1).rc, _createProvider(overBudget).rc);
        },
      );

      test('a successful construction is unchanged, and fetches no detail', () {
        final provider = ShmProvider(size: _satisfiablePool);
        addTearDown(provider.close);
        // Reaching here at all is the assertion: the enriched path is entered
        // only on failure, and a detail fetched on the success path would be
        // the previous failure's text (canon's last-error is thread-local and
        // is never cleared -- measured at slice 7, perturbation P2).
        expect(provider.garbageCollect(), isA<int>());
      });

      test('an empty detail degrades to the plain rendering', () {
        // The shipped `.enriched` behaviour, asserted rather than assumed:
        // with nothing to append there must be no trailing separator, so a
        // `stable` build -- where the shim captures nothing -- reads exactly
        // as the plain form did.
        final plain = ZenohException('Failed to create SHM provider', -1);
        for (final empty in <String?>[null, '']) {
          final degraded = ZenohException.enriched(
            'Failed to create SHM provider',
            -1,
            empty,
          );
          expect(degraded.message, plain.message);
          expect(degraded.toString(), plain.toString());
        }
      });

      test('the redaction decision is stated at the site', () {
        // ⛔ A DOC CELL, and it is the record of a DECISION rather than a
        // description. Canon's text for the over-budget class was measured to
        // carry absolute filesystem paths from inside the building
        // developer's home directory. No redaction is applied, and the reason
        // is that a general redactor is not implementable at this seam -- the
        // shim receives one opaque string with no structure to redact
        // against, and a partial one manufactures confidence.
        final src = File(
          'lib/src/unstable/shm_provider.dart',
        ).readAsStringSync();
        final region = src.substring(
          src.indexOf('static Pointer<Void> _create('),
        );
        final head = region.substring(0, region.indexOf('return ptr;'));

        expect(
          head.toLowerCase(),
          contains('redact'),
          reason:
              'the site must state the redaction decision, not leave a '
              'reader to infer it from silence',
        );
        expect(
          head,
          contains('enriched'),
          reason: 'and it must point at where the reasoning lives',
        );
      });
    },
  );
}
