/// Cells for the alignment axis: the value class, its domain guard, and the
/// measured ceiling the shipped default provider imposes on it.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

void main() {
  group(
    'AllocAlignment',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('carries pow full-width and exactly', () {
        // canon's z_alloc_alignment_t is { uint8_t pow; } — an 8-bit field, so
        // the domain is 0..255 and every value in it must survive the trip
        // unchanged. No clamping, no truncation, no substitution.
        for (final pow in [0, 1, 63, 200, 255]) {
          expect(AllocAlignment(pow: pow).pow, pow);
        }
      });

      test('rejects an out-of-domain pow at construction', () {
        // CONV-4(c): a narrower native width gets an explicit Dart-side range
        // guard naming the domain. Putting it in the constructor rather than
        // in each of the five allocation methods satisfies "before any native
        // call" a fortiori — an out-of-domain value cannot be carried by a
        // value that cannot be built.
        for (final pow in [-1, 256, 1000]) {
          expect(
            () => AllocAlignment(pow: pow),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message.toString(),
                'message',
                contains('0..255'),
              ),
            ),
            reason: "pow $pow is outside canon's uint8_t domain",
          );
        }
      });

      test('the guard is a real throw, not an assert', () {
        // An `assert` vanishes in a release build, so a guard written that way
        // protects only the test run — the exact defect the roadmap's
        // Timestamp.fromRaw item exists to correct. Two instruments, because
        // neither alone is decisive: the thrown type discriminates at run time
        // (an assert raises AssertionError, not ArgumentError), and the source
        // check catches a future edit that swaps them back, which the type
        // check would not see under `dart test` where asserts are enabled.
        expect(() => AllocAlignment(pow: 256), throwsArgumentError);
        expect(
          () => AllocAlignment(pow: 256),
          isNot(throwsA(isA<AssertionError>())),
        );

        final source = File('lib/src/unstable/alloc_alignment.dart')
            .readAsStringSync();
        expect(source, isNot(contains('assert(')));
      });
    },
  );

  group(
    'The alignment parameter',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      late ShmProvider provider;

      setUp(() {
        provider = ShmProvider(size: 4096);
      });

      tearDown(() {
        provider.close();
      });

      ShmMutBuffer ok(AllocResult result) => switch (result) {
        AllocOk(:final buffer) => buffer,
        AllocError(:final kind) => fail('got AllocError($kind)'),
        LayoutError(:final kind) => fail('got LayoutError($kind)'),
      };

      test('null means "canon decides" and reaches the unaligned entry', () {
        // CONV-2: a nullable parameter defaults to null and the binding leaves
        // canon's own choice untouched. Here the two are MEASURABLY the same
        // request, not merely documented as such — canon's unaligned entries
        // implement themselves by passing pow 0.
        final omitted = ok(provider.alloc(128));
        addTearDown(omitted.dispose);
        final explicit = ok(
          provider.alloc(128, alignment: AllocAlignment(pow: 0)),
        );
        addTearDown(explicit.dispose);

        expect(omitted.length, 128);
        expect(explicit.length, omitted.length);
      });

      test('the ceiling is pow 0, and canon says why', () {
        for (final pow in [1, 2]) {
          expect(
            provider.alloc(128, alignment: AllocAlignment(pow: pow)),
            isA<LayoutError>().having(
              (e) => e.kind,
              'kind',
              LayoutErrorKind.providerIncompatibleLayout,
            ),
            reason: "pow $pow is stricter than the provider's own layout",
          );
        }
      });

      test('the aligned axis is wired on every strategy, not only alloc', () {
        // The matched pair per method again: pow 0 must succeed and pow 1 must
        // be refused. A method whose ALIGNED dispatch code was mis-wired would
        // still succeed at pow 0 — it is the refusal that can only come from
        // the aligned entry actually being reached.
        final methods =
            <(String, AllocResult Function(int, {AllocAlignment? alignment}))>[
              ('alloc', provider.alloc),
              ('allocGc', provider.allocGc),
              ('allocGcDefrag', provider.allocGcDefrag),
              ('allocGcDefragDealloc', provider.allocGcDefragDealloc),
              ('allocGcDefragBlocking', provider.allocGcDefragBlocking),
            ];
        for (final (name, call) in methods) {
          final buffer = ok(call(128, alignment: AllocAlignment(pow: 0)));
          addTearDown(buffer.dispose);
          expect(buffer.length, 128, reason: '$name at pow 0');

          expect(
            call(128, alignment: AllocAlignment(pow: 1)),
            isA<LayoutError>().having(
              (e) => e.kind,
              'kind',
              LayoutErrorKind.providerIncompatibleLayout,
            ),
            reason: '$name at pow 1',
          );
        }
      });

      test('the two layout verdicts follow a rule, not a band', () {
        // ADJUDICATED. Two independent sweeps of the whole 0..255 domain
        // disagreed about pow=200 -- one at request size 128 said
        // incorrect-args, one at size 1024 said provider-incompatible. Both
        // were right: the classification is TWO-VARIABLE, and each sweep was a
        // correct projection of the rule at its own request size.
        //
        //   effective alignment = 2^(pow mod 64)
        //   incorrect-args        <=> effective alignment > requested size
        //   provider-incompatible <=> a well-formed pair that is stricter
        //                             than the provider's own layout
        //
        // So the cell drives the rule rather than a band, and the decisive
        // leg is the SAME pow flipping verdict with the size: no single-size
        // measurement can produce that, and no band can explain it.
        LayoutErrorKind verdict(int size, int pow) {
          final result = provider.alloc(
            size,
            alignment: AllocAlignment(pow: pow),
          );
          return switch (result) {
            LayoutError(:final kind) => kind,
            AllocOk(:final buffer) => () {
              buffer.dispose();
              return fail('pow $pow at size $size unexpectedly succeeded');
            }(),
            AllocError(:final kind) => fail('unexpected AllocError($kind)'),
          };
        }

        // pow 8 is an effective alignment of 256: larger than a 128-byte
        // request, smaller than a 1024-byte one.
        expect(
          verdict(128, 8),
          LayoutErrorKind.incorrectLayoutArgs,
          reason: '256-byte alignment exceeds a 128-byte request',
        );
        expect(
          verdict(1024, 8),
          LayoutErrorKind.providerIncompatibleLayout,
          reason:
              '256-byte alignment fits a 1024-byte request, so the '
              "provider's own layout is what refuses it",
        );

        // The two ends, to bracket the flip: an alignment that fits both
        // sizes is provider-incompatible at both; one that fits neither is
        // incorrect-args at both.
        expect(verdict(128, 1), LayoutErrorKind.providerIncompatibleLayout);
        expect(verdict(1024, 1), LayoutErrorKind.providerIncompatibleLayout);
        expect(verdict(128, 11), LayoutErrorKind.incorrectLayoutArgs);
        expect(verdict(1024, 11), LayoutErrorKind.incorrectLayoutArgs);

        // ⚠️ NOTHING ABOVE pow 63 IS ASSERTED, and the reason is that the
        // model does not fully explain it. The I/P band positions do repeat
        // with period 64 -- consistent with pow being used as a shift on a
        // 64-bit word below the C boundary -- but pow 0 is the ONLY value that
        // yields OK: pow 64, 128 and 192 all carry effective alignment 1 and
        // are still refused as provider-incompatible. So the congruence is not
        // clean, the values above 63 are artefacts rather than verdicts canon
        // offers, and a cell pinning them would be pinning the artefact.
        // Measured and recorded, not asserted.
      });
    },
  );
}
