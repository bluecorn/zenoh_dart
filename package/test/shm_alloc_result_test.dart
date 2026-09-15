import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// Consumes an [AllocResult] through an **exhaustive** `switch` with no
/// `default` arm — the consumer contract the sealed shape exists to buy.
///
/// This function compiling at all is half of Test 1: a `default`-free switch
/// over a sealed type only typechecks when every variant is named, so a fourth
/// variant appearing later breaks the build here rather than being silently
/// absorbed. Each arm binds its own payload, which pins the payload *types* at
/// compile time — `buffer.length` is an `int` only if `AllocOk.buffer` is an
/// `ShmMutBuffer`, and `.value` is an `int` only if the two error variants
/// carry the two CONV-1 enums.
String describe(AllocResult result) => switch (result) {
  AllocOk(:final buffer) => 'ok:${buffer.length}',
  AllocError(:final kind) => 'alloc:${kind.name}:${kind.value}',
  LayoutError(:final kind) => 'layout:${kind.name}:${kind.value}',
};

void main() {
  group(
    'AllocResult',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('is exactly three-way and exhaustively switchable', () {
        final provider = ShmProvider(size: 4096);
        addTearDown(provider.close);

        // The OK arm carries a real buffer, so the arm is driven rather than
        // merely typechecked. The other two carry only their kind.
        final allocated = provider.alloc(128);
        expect(allocated, isA<AllocOk>());
        final buffer = (allocated as AllocOk).buffer;
        addTearDown(buffer.dispose);

        expect(describe(AllocOk(buffer)), 'ok:128');
        expect(
          describe(const AllocError(AllocErrorKind.outOfMemory)),
          'alloc:outOfMemory:1',
        );
        expect(
          describe(const LayoutError(LayoutErrorKind.incorrectLayoutArgs)),
          'layout:incorrectLayoutArgs:0',
        );
      });

      test('AllocErrorKind declares canon wire values explicitly', () {
        // canon's z_alloc_error_t members carry no explicit initialisers, so
        // C's implicit numbering gives 0/1/2 (zenoh_opaque.h, GT-2). Asserted
        // against literals — never against values.indexOf, which would make
        // the test agree with declaration order instead of with canon.
        expect(AllocErrorKind.needDefragment.value, 0);
        expect(AllocErrorKind.outOfMemory.value, 1);
        expect(AllocErrorKind.other.value, 2);
        expect(AllocErrorKind.unknown.value, -1);
      });

      test('LayoutErrorKind declares canon wire values explicitly', () {
        // canon's z_layout_error_t, same implicit numbering: 0/1 (GT-2).
        expect(LayoutErrorKind.incorrectLayoutArgs.value, 0);
        expect(LayoutErrorKind.providerIncompatibleLayout.value, 1);
        expect(LayoutErrorKind.unknown.value, -1);
      });

      test('every known wire value decodes to its own member', () {
        expect(AllocErrorKind.fromWire(0), AllocErrorKind.needDefragment);
        expect(AllocErrorKind.fromWire(1), AllocErrorKind.outOfMemory);
        expect(AllocErrorKind.fromWire(2), AllocErrorKind.other);

        expect(
          LayoutErrorKind.fromWire(0),
          LayoutErrorKind.incorrectLayoutArgs,
        );
        expect(
          LayoutErrorKind.fromWire(1),
          LayoutErrorKind.providerIncompatibleLayout,
        );

        // No two raws collide: each decode is distinct across the domain.
        final allocDecoded = [0, 1, 2].map(AllocErrorKind.fromWire).toSet();
        expect(allocDecoded, hasLength(3));
        final layoutDecoded = [0, 1].map(LayoutErrorKind.fromWire).toSet();
        expect(layoutDecoded, hasLength(2));
      });

      test('wire values do not derive from declaration order', () {
        // A reorder of the members breaks THIS test rather than silently
        // changing what the two layers agree the numbers mean.
        expect(
          AllocErrorKind.values.map((e) => e.value).toList(),
          [0, 1, 2, -1],
        );
        expect(
          LayoutErrorKind.values.map((e) => e.value).toList(),
          [0, 1, -1],
        );
      });

      test('an unrecognised wire value totalizes to the sentinel', () {
        // canon designates no default member for either enum, so CONV-1b's
        // no-canon-default arm governs: a binding-labelled sentinel, never a
        // silent map to a real member, and never a throw.
        for (final raw in [3, 99, -2, 255]) {
          expect(AllocErrorKind.fromWire(raw), AllocErrorKind.unknown);
          expect(LayoutErrorKind.fromWire(raw), LayoutErrorKind.unknown);
        }
      });

      test('the decode seam rejects an out-of-domain status', () {
        // A status outside canon's {0,1,2} is a contract violation. It is
        // never mapped to a real variant (the peer's default:-to-alloc-error
        // converter is the barred shape) and never mints a fourth variant.
        for (final status in [3, 10, -1]) {
          expect(
            () => AllocResult.failureFromWire(status, 1, 1),
            throwsA(
              isA<ZenohException>().having(
                (e) => e.toString(),
                'message',
                contains('unknown status'),
              ),
            ),
            reason: 'status $status must be a contract violation',
          );
        }
      });

      test('the decode seam reads only the field its status selects', () {
        expect(
          AllocResult.failureFromWire(1, 1, -1),
          isA<AllocError>().having(
            (e) => e.kind,
            'kind',
            AllocErrorKind.outOfMemory,
          ),
        );
        expect(
          AllocResult.failureFromWire(2, -1, 0),
          isA<LayoutError>().having(
            (e) => e.kind,
            'kind',
            LayoutErrorKind.incorrectLayoutArgs,
          ),
        );

        // The off-arm field cannot leak into the result: canon backfills it
        // with placeholder garbage (GT-3), so a decoder that read both fields
        // would surface a meaningless layout error alongside a real alloc one.
        expect(
          AllocResult.failureFromWire(1, 1, 1),
          isA<AllocError>().having(
            (e) => e.kind,
            'kind',
            AllocErrorKind.outOfMemory,
          ),
        );
      });
    },
  );
}
