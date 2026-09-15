import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/bindings.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// Bindings-level cells for the SHM allocation carriage.
///
/// These drive `zd_shm_provider_alloc` **directly at the seam**, below the
/// Dart types, because that is the only place three of its obligations are
/// observable: that canon's placeholder garbage is gravestoned before it
/// crosses; that the aligned dispatch reaches canon's `_aligned` sibling
/// rather than the unaligned one; and that the shim's own argument guard runs
/// with nothing else, which the public API's guards make unreachable from
/// above. Everything here is a raw struct read — no decoding, no Dart types.

/// A live provider held as its raw slot, so the loaned pointer the shim wants
/// is available without going through the Dart wrapper's private field.
class _RawProvider {
  _RawProvider(int size)
    : _slot = calloc.allocate<Void>(
        bindings.zd_shm_provider_sizeof(),
      ) {
    // Declines the detail triple: this harness only needs a live provider,
    // and the capture itself is exercised in shm_provider_error_test.dart.
    final rc = bindings.zd_shm_provider_new(
      _slot.cast(),
      size,
      nullptr,
      0,
      nullptr,
    );
    if (rc != 0) {
      calloc.free(_slot);
      throw StateError('provider construction failed with rc $rc');
    }
  }

  final Pointer<Void> _slot;

  Pointer<Opaque> get loaned => bindings.zd_shm_provider_loan(_slot.cast());

  void close() {
    bindings.zd_shm_provider_drop(_slot.cast());
    calloc.free(_slot);
  }
}

void main() {
  group(
    'SHM allocation carriage (bindings level)',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      late _RawProvider provider;
      late Pointer<zd_shm_alloc_result_t> out;
      late Pointer<Void> buf;

      setUp(() {
        provider = _RawProvider(4096);
        out = calloc<zd_shm_alloc_result_t>();
        buf = calloc.allocate<Void>(bindings.zd_shm_mut_sizeof());
      });

      tearDown(() {
        calloc
          ..free(buf)
          ..free(out);
        provider.close();
      });

      /// Fills the result struct with a value canon can never write, so a
      /// field the shim leaves alone is distinguishable from a field it wrote.
      void poison() {
        out.ref
          ..status = 127
          ..alloc_error = 127
          ..layout_error = 127;
      }

      test('an OK allocation carries no error payload at all', () {
        final rc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          128,
          0, // plain
          -1, // unaligned
          out,
        );
        addTearDown(() => bindings.zd_shm_mut_drop(buf.cast()));

        expect(rc, 0, reason: 'a canon call ran');
        expect(out.ref.status, 0, reason: "canon's OK status, verbatim");
        // canon's own OK result carries alloc_error = OTHER (2) and
        // layout_error = PROVIDER_INCOMPATIBLE_LAYOUT (1) as placeholder
        // garbage. Neither may cross the seam.
        expect(out.ref.alloc_error, -1);
        expect(out.ref.layout_error, -1);
      });

      test('an allocation error carries canon code and gravestones layout', () {
        final rc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          8192, // larger than the pool
          0,
          -1,
          out,
        );

        expect(rc, 0);
        expect(out.ref.status, 1, reason: "canon's ALLOC_ERROR");
        expect(out.ref.alloc_error, 1, reason: "canon's OUT_OF_MEMORY");
        expect(out.ref.layout_error, -1, reason: 'the off-arm field');
      });

      test('a layout error carries canon code and gravestones alloc', () {
        final rc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          0, // zero size is a LAYOUT error, not exhaustion
          0,
          -1,
          out,
        );

        expect(rc, 0);
        expect(out.ref.status, 2, reason: "canon's LAYOUT_ERROR");
        expect(
          out.ref.layout_error,
          0,
          reason: "canon's INCORRECT_LAYOUT_ARGS",
        );
        expect(out.ref.alloc_error, -1, reason: 'the off-arm field');
      });

      test("the aligned path reaches canon's _aligned sibling", () {
        // The default provider accepts only its own construction layout, so
        // pow 0 succeeds and anything stricter is refused. That refusal is the
        // discriminator: an unaligned entry can never produce it, so seeing it
        // proves the _aligned symbol was the one called.
        final okRc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          128,
          0,
          0, // pow 0
          out,
        );
        expect(okRc, 0);
        expect(out.ref.status, 0);
        bindings.zd_shm_mut_drop(buf.cast());

        final refusedRc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          128,
          0,
          1, // pow 1 — stricter than the provider's own layout
          out,
        );
        expect(refusedRc, 0);
        expect(out.ref.status, 2);
        expect(
          out.ref.layout_error,
          1,
          reason: "canon's PROVIDER_INCOMPATIBLE_LAYOUT",
        );
      });

      test('both maintenance entries are callable and return an int', () {
        // Fresh pool.
        expect(
          bindings.zd_shm_provider_defragment(provider.loaned),
          isA<int>(),
        );
        expect(
          bindings.zd_shm_provider_garbage_collect(provider.loaned),
          isA<int>(),
        );

        // After a buffer has been allocated and dropped.
        final rc = bindings.zd_shm_provider_alloc(
          provider.loaned,
          buf.cast(),
          512,
          0,
          -1,
          out,
        );
        expect(rc, 0);
        expect(out.ref.status, 0);
        bindings.zd_shm_mut_drop(buf.cast());

        // NO MAGNITUDE ASSERTION on either return: canon documents no meaning
        // for these numbers, and garbage_collect() was measured returning
        // 16384 where 32768 bytes were pending. Asserting a magnitude would be
        // asserting the allocator's history, not a contract.
        expect(
          bindings.zd_shm_provider_defragment(provider.loaned),
          isA<int>(),
        );
        expect(
          bindings.zd_shm_provider_garbage_collect(provider.loaned),
          isA<int>(),
        );
      });

      test('an out-of-domain argument is rejected with nothing run', () {
        // Each tuple is (size, strategy, alignment_pow).
        const rejected = [
          (128, 99, -1), // strategy outside 0..4
          (128, 0, 256), // pow above canon's uint8_t domain
          (128, 0, -2), // below the unaligned sentinel
          (-1, 0, -1), // negative size
        ];

        for (final (size, strategy, pow) in rejected) {
          poison();
          // A byte pattern in the buffer slot, so "untouched" is observable
          // rather than assumed.
          final bufBytes = buf.cast<Uint8>();
          for (var i = 0; i < 8; i++) {
            bufBytes[i] = 0xAB;
          }

          final rc = bindings.zd_shm_provider_alloc(
            provider.loaned,
            buf.cast(),
            size,
            strategy,
            pow,
            out,
          );

          expect(rc, 10, reason: 'size=$size strategy=$strategy pow=$pow');
          expect(out.ref.status, 127, reason: 'the poison survived');
          expect(out.ref.alloc_error, 127);
          expect(out.ref.layout_error, 127);
          for (var i = 0; i < 8; i++) {
            expect(bufBytes[i], 0xAB, reason: 'the buffer slot was untouched');
          }
        }
      });
    },
  );
}
