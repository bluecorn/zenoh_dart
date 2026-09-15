/// Through-our-stack cells for the SHM allocation strategies.
///
/// The bindings-level seam is covered in `shm_alloc_carriage_test.dart`; this
/// file re-observes the same canon behaviour through the shipped Dart surface,
/// which is where a consumer meets it. Every consumption is an exhaustive
/// `switch` with no `default` arm.
///
/// ## Two arms are covered by wire mapping only, and neither is faked
///
/// **`AllocErrorKind.needDefragment`** was never produced by a real
/// allocation. Two recipes were driven at canon directly — a drop-then-realloc
/// cycle, and a three-buffer fragmentation recipe (allocate three, drop the
/// two non-adjacent, collect, then request their sum) — and both reported OK
/// or out-of-memory instead, with `defragment()` returning 0 throughout
/// (`development/research/probes-seed7-20260819/`, replicated independently).
/// Its coverage therefore rests on the decode and totalization cells in
/// `shm_alloc_result_test.dart`. **No cell in this file drives it, and none
/// fabricates one** — a cell that constructed the variant by hand would assert
/// only that Dart can build a Dart object.
///
/// **The blocking variant's out-of-memory arm** is untestable for a harder
/// reason: it does not return. See the blocking group below.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// Unwraps an [AllocResult] a cell requires to have succeeded, through one
/// exhaustive `switch` with no `default` arm.
ShmMutBuffer _expectOk(AllocResult result) => switch (result) {
  AllocOk(:final buffer) => buffer,
  AllocError(:final kind) => fail('expected AllocOk, got AllocError($kind)'),
  LayoutError(:final kind) => fail('expected AllocOk, got LayoutError($kind)'),
};

void main() {
  group(
    'SHM allocation discriminants',
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

      test('an oversized request is an allocation error, out of memory', () {
        switch (provider.alloc(8192)) {
          case AllocOk():
            fail('a 8192-byte request cannot be met from a 4096-byte pool');
          case AllocError(:final kind):
            expect(kind, AllocErrorKind.outOfMemory);
          case LayoutError(:final kind):
            fail('expected an allocation error, got LayoutError($kind)');
        }
      });

      test('a zero-size request is a LAYOUT error, not exhaustion', () {
        // The distinction the nullable return used to hide: the request never
        // became a layout at all, so no amount of freeing could help it.
        switch (provider.alloc(0)) {
          case AllocOk():
            fail('a zero-size allocation is not a thing canon grants');
          case AllocError(:final kind):
            fail('expected a layout error, got AllocError($kind)');
          case LayoutError(:final kind):
            expect(kind, LayoutErrorKind.incorrectLayoutArgs);
        }
      });

      test('a satisfiable request is OK and carries no error payload', () {
        switch (provider.alloc(128)) {
          case AllocOk(:final buffer):
            addTearDown(buffer.dispose);
            expect(buffer.length, 128);
          // The OK variant carries no error field at all, so there is nothing
          // to assert absent — the type is the assertion. That is what the
          // sealed shape buys over a struct with three always-present fields.
          case AllocError(:final kind):
            fail('expected AllocOk, got AllocError($kind)');
          case LayoutError(:final kind):
            fail('expected AllocOk, got LayoutError($kind)');
        }
      });
    },
  );

  group(
    'The sync strategy family',
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

      test(
        'gc succeeds where plain fails on dropped-but-uncollected space',
        () {
          // THE TWO-LINE PROOF that the missing strategies were a real gap and
          // not decoration. Fill most of the pool, drop the buffer WITHOUT
          // collecting, then ask for the same space twice:
          //   - plain alloc will not collect, so it reports the pool full;
          //   - allocGc collects first, so the same request succeeds.
          // Same provider, same size, same instant — the only variable is the
          // strategy, which is what makes this a contrast rather than a story.
          //
          // 2048 from a 4096 pool is chosen by MEASUREMENT, not by taste: the
          // contrast window on this host at this pin runs 1536..2816. Below it
          // the plain retry simply succeeds (the pool has room without
          // collecting, so there is no contrast); above it the FIRST allocation
          // already fails, because a pool carries constant per-allocation
          // overhead — 3072 from a 4096 pool never lands. A size outside the
          // window turns this cell red rather than silently vacuous, which is
          // how the window was found.
          final first = _expectOk(provider.alloc(2048))..dispose();
          expect(first.dispose, returnsNormally);

          switch (provider.alloc(2048)) {
            case AllocOk(:final buffer):
              buffer.dispose();
              fail('plain alloc collected — the contrast has no variable left');
            case AllocError(:final kind):
              expect(kind, AllocErrorKind.outOfMemory);
            case LayoutError(:final kind):
              fail('expected an allocation error, got LayoutError($kind)');
          }

          final recovered = _expectOk(provider.allocGc(2048));
          addTearDown(recovered.dispose);
          expect(recovered.length, 2048);
        },
      );

      test('each new strategy reaches canon on its success path', () {
        for (final (name, call) in <(String, AllocResult Function(int))>[
          ('allocGc', provider.allocGc),
          ('allocGcDefrag', provider.allocGcDefrag),
          ('allocGcDefragDealloc', provider.allocGcDefragDealloc),
        ]) {
          final buffer = _expectOk(call(256));
          addTearDown(buffer.dispose);
          expect(buffer.length, 256, reason: name);
        }
      });

      test('each new strategy reaches canon on a failure path', () {
        // A success alone would pass on a MIS-WIRED dispatch code: every code
        // in range reaches some canon entry, and all of them succeed on a
        // request the pool can meet outright. A matched success/failure pair
        // per method is the minimum that cannot.
        for (final (name, call) in <(String, AllocResult Function(int))>[
          ('allocGc', provider.allocGc),
          ('allocGcDefrag', provider.allocGcDefrag),
          ('allocGcDefragDealloc', provider.allocGcDefragDealloc),
        ]) {
          switch (call(8192)) {
            case AllocOk(:final buffer):
              buffer.dispose();
              fail('$name met an 8192 request from a 4096 pool');
            case AllocError(:final kind):
              expect(kind, AllocErrorKind.outOfMemory, reason: name);
            case LayoutError(:final kind):
              fail('$name: expected an allocation error, got $kind');
          }
        }
      });

      test('the strategy family adds no public enum or selector', () {
        // Register row :90 keeps the family name-encoded as methods. The
        // dispatch codes are private constants inside ShmProvider; nothing
        // named "strategy" is exported, and no method takes one. This cell is
        // the surface check that keeps a second idiom for the same capability
        // from appearing later — it reads the barrel rather than trusting a
        // memory of what was exported.
        final barrel = File('lib/zenoh_unstable.dart').readAsStringSync();
        expect(barrel, isNot(contains('strategy')));
        final providerSource = File('lib/src/unstable/shm_provider.dart')
            .readAsStringSync();
        expect(
          providerSource,
          isNot(
            matches(RegExp(r'^\s*(enum|class)\s+\w*Strategy', multiLine: true)),
          ),
        );
        // The codes exist, and they are private.
        expect(providerSource, contains('static const int _strategy'));
      });
    },
  );

  group(
    'The size domain guard (CONV-4)',
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

      test('a negative size throws before the allocator is touched', () {
        // A Dart int marshalled into an unsigned native integer: a negative
        // surviving the coercion arrives as a huge unsigned value and produces
        // a perfectly legitimate-looking OUT_OF_MEMORY — a caller bug wearing
        // the costume of a capacity problem.
        expect(
          () => provider.alloc(-1),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              contains('non-negative'),
            ),
          ),
        );

        // Provably untouched: a pool that had actually seen the bad request
        // would be in some other state. This immediately-following allocation
        // is what turns "it threw" into "it threw and changed nothing".
        final buffer = _expectOk(provider.alloc(64));
        addTearDown(buffer.dispose);
        expect(buffer.length, 64);
      });

      test('the guard is on every strategy method, not only the first', () {
        // ⚠️ This cell asserts the MESSAGE, and that is load-bearing rather
        // than fussy. Written as a bare `throwsA(isA<ArgumentError>())` it
        // passed with no Dart-side guard at all — the shim's own backstop
        // returns rc 10 and the binding renders that as an ArgumentError too,
        // so the weaker assertion could not tell "rejected before any native
        // call" from "rejected after one". Only the Dart-side guard names the
        // domain; the backstop's message names the raw arguments instead. The
        // weak version was written first, and it was a false green.
        for (final (name, call) in <(String, AllocResult Function(int))>[
          ('alloc', provider.alloc),
          ('allocGc', provider.allocGc),
          ('allocGcDefrag', provider.allocGcDefrag),
          ('allocGcDefragDealloc', provider.allocGcDefragDealloc),
          ('allocGcDefragBlocking', provider.allocGcDefragBlocking),
        ]) {
          expect(
            () => call(-1),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message.toString(),
                'message',
                contains('non-negative'),
              ),
            ),
            reason: '$name must reject a negative size Dart-side',
          );
        }
      });

      test('zero passes the guard and reaches canon', () {
        // CONV-4(b): zero passes through and its canon behaviour is PINNED per
        // surface, never assumed. Here it is a canon outcome — a layout error
        // — and not a Dart-side refusal, which is a distinction a caller can
        // act on: the guard rejects what canon could not interpret, canon
        // rejects what it interpreted and disliked.
        expect(
          provider.alloc(0),
          isA<LayoutError>().having(
            (e) => e.kind,
            'kind',
            LayoutErrorKind.incorrectLayoutArgs,
          ),
        );
      });

      // The shim carries its own copy of this guard, and it is driven directly
      // at the seam by `shm_alloc_carriage_test.dart`'s rejection cell (the
      // `(-1, 0, -1)` tuple), which asserts rc 10 with the result struct and
      // the buffer slot both left at their poison values. The defence is
      // therefore real at both layers, as it is for #5's capacity contract —
      // and it is asserted once rather than twice, because a second cell would
      // re-measure the same line of C.
    },
  );

  group(
    'Forced eviction (allocGcDefragDealloc)',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      // The arithmetic is the whole cell, so it is stated rather than left to
      // be re-derived: 40960 + 40960 = 81920 > 65536. With the first buffer
      // held LIVE — not dropped — there is nothing to collect and nothing to
      // defragment into, so no free 40960-byte region can exist. A second
      // 40960 request can therefore only be met by taking the space away from
      // the live buffer. Eviction is forced, not incidental.
      const poolSize = 65536;
      const halfish = 40960;

      late ShmProvider provider;

      setUp(() {
        provider = ShmProvider(size: poolSize);
      });

      tearDown(() {
        provider.close();
      });

      test('the dealloc strategy succeeds where gc and defrag cannot', () {
        final victim = _expectOk(provider.alloc(halfish));
        addTearDown(victim.dispose);

        final evictor = _expectOk(provider.allocGcDefragDealloc(halfish));
        addTearDown(evictor.dispose);
        expect(evictor.length, halfish);
      });

      test('the non-evicting strategy is the control', () {
        // Without this leg the cell above is not an eviction result — it is
        // just an allocation that happened to succeed. Same topology, same
        // size, the only change being the strategy.
        final victim = _expectOk(provider.alloc(halfish));
        addTearDown(victim.dispose);

        switch (provider.allocGcDefrag(halfish)) {
          case AllocOk(:final buffer):
            buffer.dispose();
            fail('gc+defrag met a request the arithmetic forbids');
          case AllocError(:final kind):
            expect(kind, AllocErrorKind.outOfMemory);
          case LayoutError(:final kind):
            fail('expected an allocation error, got LayoutError($kind)');
        }
      });

      test('the evicted holder observes nothing', () {
        final victim = _expectOk(provider.alloc(halfish))
          ..write(List<int>.filled(16, 0x5A));

        final evictor = _expectOk(provider.allocGcDefragDealloc(halfish));
        addTearDown(evictor.dispose);

        // From the victim's side the eviction is silent: no exception was
        // raised, the handle still answers, and dropping it is clean. There is
        // nothing a holder could check to discover it had been displaced —
        // which is exactly why the hazard has to be documented on the method
        // rather than detected by the caller.
        expect(() => victim.length, returnsNormally);
        expect(victim.length, halfish);
        expect(victim.dispose, returnsNormally);
      });

      // Byte-aliasing between victim and evictor is DELIBERATELY not asserted.
      // Neither the probe that found this behaviour nor the hazard statement
      // that came out of it depends on whether the new allocation reuses the
      // victim's bytes. A cell claiming it does — or does not — would be
      // asserting the allocator's history rather than a contract canon offers,
      // and would go red on any backend change without anything being wrong.
    },
  );

  group(
    'The blocking variant',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      // ⛔ THE RULE THIS GROUP OBEYS, and it has no exceptions.
      //
      // An oversized — never-satisfiable — request through a blocking entry
      // DOES NOT RETURN. Measured: parked past a 5 s watchdog, while a
      // positive control (same size, space freed by a helper thread at
      // t+500 ms) unblocked at ~501 ms. There is no timeout, no exception and
      // no recovery, and because the call is synchronous FFI the calling
      // isolate is simply gone. A cell that made that request would hang the
      // whole suite forever.
      //
      // Every cell below therefore drives a LAYOUT-class failure, and each
      // states in-line why it cannot block. Verified before being written
      // here, in a subprocess under a hard timeout: blocking(0),
      // blocking(1024, pow 1) and blocking(0, pow 1) all returned at 0 ms.
      late ShmProvider provider;

      setUp(() {
        provider = ShmProvider(size: 4096);
      });

      tearDown(() {
        provider.close();
      });

      test('the success path returns through the same carriage', () {
        // Satisfiable outright from a fresh 4096-byte pool, so the retry loop
        // is never entered — there is no wait to be unbounded.
        final buffer = _expectOk(provider.allocGcDefragBlocking(256));
        addTearDown(buffer.dispose);
        expect(buffer.length, 256);
      });

      test('a zero-size request fails fast rather than parking', () {
        // Closes a hole the shipped surface carried since it landed: this
        // method has never had a failure-path cell at all. A layout-class
        // input is rejected BEFORE the retry loop is entered — canon
        // classifies the request as un-layoutable and returns immediately, so
        // there is nothing for it to wait on.
        expect(
          provider.allocGcDefragBlocking(0),
          isA<LayoutError>().having(
            (e) => e.kind,
            'kind',
            LayoutErrorKind.incorrectLayoutArgs,
          ),
        );
      });

      test('the aligned blocking entry fails fast too', () {
        // The second measured fast-failure driver, and the proof that the
        // ALIGNED blocking dispatch code is wired: an unaligned entry could
        // not produce this discriminant. Also layout-class, so also unable to
        // park.
        expect(
          provider.allocGcDefragBlocking(
            1024,
            alignment: AllocAlignment(pow: 1),
          ),
          isA<LayoutError>().having(
            (e) => e.kind,
            'kind',
            LayoutErrorKind.providerIncompatibleLayout,
          ),
        );
      });

      // The out-of-memory arm of this entry is UNTESTABLE, and the absence is
      // recorded rather than faked. Reaching it requires a request the pool
      // can never satisfy, which is precisely the input that never returns —
      // the cell and the hazard are the same thing. No cell in this file
      // requests an unsatisfiable size through any blocking entry, and none
      // fabricates the variant by hand. The hazard is carried instead by
      // allocGcDefragBlocking's own dartdoc, where a caller meets it.
    },
  );

  group(
    'Manual maintenance',
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

      test('both are callable in any pool state on a live provider', () {
        // ⚠️ TYPE AND NON-THROWING ONLY — no magnitude is asserted on either
        // return, on purpose. Canon documents no meaning for these numbers,
        // and garbage_collect() was measured returning 16384 where 32768 bytes
        // were pending (and 40960 elsewhere), so the return demonstrably is
        // not bytes-reclaimed. An expectation like `greaterThan(0)` would be
        // asserting the allocator's history, and would go red on a backend
        // change with nothing actually wrong.
        //
        // The garbage collector's EFFECT is asserted functionally instead, by
        // the gc-vs-plain contrast in "The sync strategy family" above: a
        // plain alloc failing where allocGc succeeds on the same request is a
        // real observation of collection happening. That is where the proof
        // lives; here we only pin that the calls exist and behave.
        expect(provider.defragment(), isA<int>());
        expect(provider.garbageCollect(), isA<int>());

        final buffer = _expectOk(provider.alloc(2048));
        expect(provider.defragment(), isA<int>());
        expect(provider.garbageCollect(), isA<int>());

        buffer.dispose();
        expect(provider.defragment(), isA<int>());
        expect(provider.garbageCollect(), isA<int>());

        // Immediately again, with nothing having changed in between.
        expect(provider.defragment(), isA<int>());
        expect(provider.garbageCollect(), isA<int>());
      });

      test('both inherit the closed-provider guard', () {
        final closed = ShmProvider(size: 4096)..close();
        expect(closed.defragment, throwsStateError);
        expect(closed.garbageCollect, throwsStateError);
      });
    },
  );

  group(
    'Pool geometry (the example constants, defended)',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      // These three cells are what keep the corrected example pool constants
      // honest. They assert the CONSEQUENCES the constants rest on and never
      // the geometry itself: no cell here pins the construction boundary or
      // the per-allocation headroom, because both are host- and pin-specific.
      // The numbers live in the committed run at
      // `development/research/probes-seed7-pool-floor-20260819/`, whose
      // README carries the recipe — so a reader can re-derive them rather than
      // take them on trust, and a host whose geometry differs turns these red
      // instead of silently shipping a wrong constant.

      /// The allocation sizes the five SHM examples actually reach, including
      /// the payloads their CLI tests drive.
      const exampleAllocSizes = [8, 24, 128, 1024, 8192];

      test('a pool sized to exactly its allocation is never satisfiable', () {
        // This is the fact that FORCES z_get_shm and z_ping_shm to deviate
        // from canon's own pool sizing: canon sizes the provider to the
        // payload it then requests, and that can never work.
        for (final size in exampleAllocSizes) {
          if (size < 4096) {
            // Below the construction floor canon will not even build the
            // provider, which is the same refusal one step earlier.
            expect(
              () => ShmProvider(size: size),
              throwsA(isA<ZenohException>()),
              reason: 'pool == alloc == $size',
            );
            continue;
          }
          final provider = ShmProvider(size: size);
          addTearDown(provider.close);
          expect(
            provider.alloc(size),
            isA<AllocError>().having(
              (e) => e.kind,
              'kind',
              AllocErrorKind.outOfMemory,
            ),
            reason: 'pool == alloc == $size',
          );
        }
      });

      test("canon's own example pool satisfies canon's own example buffer", () {
        // What lets the two examples canon CAN construct drop their floors
        // entirely and use canon's exact 4096: z_pub_shm's 1024-byte
        // per-iteration buffer and z_queryable_shm's payload-sized reply.
        final provider = ShmProvider(size: 4096);
        addTearDown(provider.close);

        final pubBuffer = _expectOk(provider.alloc(1024));
        expect(pubBuffer.length, 1024);
        pubBuffer.dispose();

        final replyBuffer = _expectOk(provider.allocGc(24));
        addTearDown(replyBuffer.dispose);
        expect(replyBuffer.length, 24);
      });

      test('the doubling rule holds at every size the examples reach', () {
        // The shipped shape for the two forced-deviation examples. Driven
        // rather than argued: the constant is defended by the suite, not by a
        // comment beside it.
        for (final size in exampleAllocSizes) {
          final pool = size * 2 < 4096 ? 4096 : size * 2;
          final provider = ShmProvider(size: pool);
          addTearDown(provider.close);
          final buffer = _expectOk(provider.alloc(size));
          addTearDown(buffer.dispose);
          expect(buffer.length, size, reason: 'max(2*$size, 4096) = $pool');
        }
      });
    },
  );
}
