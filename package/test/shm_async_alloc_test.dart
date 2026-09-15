// Unit [SHM] shared-memory-lifetime, slice 9 — the shim's async allocation
// entry and its context lifecycle.
//
// ⭐ WHY THIS ENTRY EXISTS. Canon's ten SYNCHRONOUS allocation entries include
// one that BLOCKS until the pool can satisfy the request, and in Dart that
// blocks the isolate: no await point, no timer, no cancellation, and on a
// request the pool can never satisfy it never returns at all. Canon also ships
// an ASYNC sibling that returns immediately and delivers its outcome on a
// non-caller thread. This binds that sibling.
//
// ⛔ THESE CELLS DRIVE THE SHIM DIRECTLY, through the generated bindings and a
// raw native port. They are about the SEAM -- what the shim starts, what it
// posts, and what it releases. `ShmProvider.allocGcDefragAsync`, the Dart
// surface, is slice 10 and is not exercised here.
//
// ---------------------------------------------------------------------------
// WHAT WAS MEASURED BEFORE ANY OF THIS WAS DESIGNED
// ---------------------------------------------------------------------------
//
// Committed probes: `development/research/probes-ci-shm-20260902/`. Calling
// canon directly, on the provider this binding constructs:
//
//   * a request the pool cannot satisfy is ACCEPTED (rc=0) and then NOTHING
//     ever fires -- no result callback, and no context delete_fn either. The
//     context is never reclaimed.
//   * dropping the provider with such a request pending SEGFAULTS, 3/3,
//     against a control that performs the identical drop on the identical
//     exhausted pool with no request started. (Slice 12 closes that route;
//     nothing here drops a provider with a request outstanding.)
//   * `delete_fn` DOES fire whenever canon completes -- on the OK arm and on
//     the layout-refusal arm alike.
//   * ⭐ canon's rc is ZERO for every size in the domain, up to SIZE_MAX. The
//     canon-rejection arm is UNREACHABLE on this provider, which is what makes
//     the shim's error path safe: its non-zero returns are its OWN, minted
//     before the context is ever handed over.
//   * a refusal arrives through the CALLBACK with rc=0 -- `size: 0` returns 0
//     and reports a layout error in the result. The return code is not an
//     outcome channel here, exactly as it is not for the sync ten.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// The pool every cell here builds, and the chunk they ask for.
const _pool = 65536;
const _chunk = 8192;

/// The shim's "argument rejected, nothing ran" code.
const _rcArgumentRejected = 10;

/// A request this pool can never satisfy.
///
/// ⚠️ Four times the pool rather than "the pool size": the probes measured
/// that even the NOMINAL pool size never completes, because the pool carries
/// its own overhead. Four times it is unambiguous about the class.
const int _neverSatisfiable = _pool * 4;

/// A throwaway out-param for the box handle.
///
/// ⚠️ These cells drive the SEAM, not a provider's lifetime: they never close
/// a provider with a request outstanding, so no deferral is ever needed here.
///
/// ⚠️ **CORRECTED 2026-09-03 at the merge gate.** This said the reference was
/// *"deliberately NOT released -- these cells drop their providers directly
/// and a released box would drop again"*, which teaches a danger that does not
/// exist here: **no cell in this file calls `zd_shm_provider_defer_drop`**, so
/// none of these boxes ever holds a provider slot, and releasing one could
/// drop nothing. The reference is simply left for the process to reclaim,
/// which is what a seam cell can afford and a lifetime cell cannot.
///
/// The lifetime cells that DO exercise the deferral live in shm_lifetime_test.
final Pointer<Int64> _boxSink = calloc<Int64>();

/// One posted result, decoded.
typedef _Post = ({int status, int allocError, int layoutError, int bufHandle});

_Post _decode(Object? message) {
  final list = message! as List<Object?>;
  return (
    status: list[0]! as int,
    allocError: list[1]! as int,
    layoutError: list[2]! as int,
    bufHandle: list[3]! as int,
  );
}

/// Opens a provider, runs [body] with its loaned pointer, and closes it.
///
/// ⛔ Never drops a provider with a request outstanding -- that is the
/// measured segfault, and slice 12 is what makes it unreachable. Every cell
/// here either completes its request first or never starts one.
Future<T> _withProvider<T>(
  Future<T> Function(Pointer<Opaque> loaned) body,
) async {
  final slot = calloc.allocate<Void>(bindings.zd_shm_provider_sizeof());
  final rc = bindings.zd_shm_provider_new(
    slot.cast(),
    _pool,
    nullptr,
    0,
    nullptr,
  );
  expect(rc, 0, reason: 'the cell could not build its provider');
  try {
    return await body(bindings.zd_shm_provider_loan(slot.cast()));
  } finally {
    bindings.zd_shm_provider_drop(slot.cast());
    calloc.free(slot);
  }
}

// ===========================================================================
// SLICE 10 -- `ShmProvider.allocGcDefragAsync`: the DART SURFACE over the
// seam above, on its SATISFIABLE path.
// ===========================================================================
//
// The never-satisfiable arm, `close()`'s new duty and the safe provider drop
// are later slices, and nothing here builds them.
//
// MEASURED BEFORE THESE CELLS WERE WRITTEN -- a throwaway probe driving the
// seam directly on this host, unstable variant, 65536-byte pool:
//
//   sync alloc 40960              -> OK, held by the caller
//   async request 40960           -> rc 0, THE CALL RETURNED IN 298us
//   +500 ms, buffer still held    -> no post: the request is genuinely pending
//   the caller disposes at t+522ms
//   the post arrives at  t+524ms  -> status 0, a live 40960-byte buffer
//
// That is the shape the BLOCKING sibling makes impossible, because there the
// caller is the party frozen. It is the whole reason this entry is bound.

/// The chunk the exhaustion cell holds, and then re-requests.
///
/// 40960 out of 65536 is measured to fit once and not twice, which is what
/// makes a second outstanding request pend rather than complete.
const _holdChunk = 40960;

/// What the usability cell writes through a buffer.
const _probe = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x7F];

/// The Dart source this slice's structural cells read.
const _providerSource = 'lib/src/unstable/shm_provider.dart';

/// How many requests this cell has started and not yet seen settle.
///
/// It exists because of a HAZARD, not for tidiness. Dropping a provider with
/// a request outstanding is a MEASURED SEGFAULT (3/3 against a clean control,
/// `development/research/probes-ci-shm-20260902/`), and a segfault is not a
/// red cell -- it is a dead run that reports nothing. Making the drop safe is
/// a later slice, so until then a cell that fails while a request is
/// outstanding must LEAK its provider rather than close it.
class _Pending {
  int count = 0;
}

/// Opens a provider, runs [body], and closes it **only if nothing is
/// outstanding**.
Future<void> _withShmProvider(
  Future<void> Function(ShmProvider provider, _Pending pending) body,
) async {
  final provider = ShmProvider(size: _pool);
  final pending = _Pending();
  try {
    await body(provider, pending);
  } finally {
    if (pending.count == 0) {
      provider.close();
    } else {
      printOnFailure(
        'the provider was deliberately LEAKED (one $_pool-byte pool): '
        '${pending.count} request(s) still outstanding, and dropping a '
        'provider in that state is the measured segfault',
      );
    }
  }
}

/// Counts [future] as outstanding until it settles, either way.
Future<AllocResult> _track(_Pending pending, Future<AllocResult> future) {
  pending.count++;
  return future.whenComplete(() {
    pending.count--;
  });
}

/// The OK arm, or a failure naming what arrived instead.
AllocOk _expectAllocOk(AllocResult result) {
  expect(
    result,
    isA<AllocOk>(),
    reason: 'the request was expected to be satisfiable, and was not',
  );
  return result as AllocOk;
}

/// One buffer's observable behaviour, so the async arm can be COMPARED with
/// the sync one rather than merely asserted about.
typedef _Observed = ({int length, List<int> readBack, bool shmBacked});

/// Writes through [buffer], reads it back, converts it, and releases it.
_Observed _exercise(ShmMutBuffer buffer) {
  final length = buffer.length;
  buffer.write(_probe);
  final readBack = buffer.read(length: _probe.length);
  final bytes = buffer.toBytes();
  final shmBacked = bytes.isShmBacked;
  bytes.dispose();
  buffer.dispose();
  return (length: length, readBack: readBack, shmBacked: shmBacked);
}

/// The `///` block immediately preceding [declaration].
String _docBlockBefore(String source, String declaration) {
  final index = source.indexOf(declaration);
  expect(index, isNot(-1), reason: 'declaration not found: $declaration');
  final lines = source.substring(0, index).split('\n');
  final doc = <String>[];
  for (var i = lines.length - 2; i >= 0; i--) {
    if (!lines[i].trimLeft().startsWith('///')) break;
    doc.insert(0, lines[i]);
  }
  return doc.join('\n');
}

/// [source] with every whole-line comment removed.
///
/// ⛔ IT EXISTS BECAUSE A CELL WAS MEASURED BLIND WITHOUT IT. The port-shape
/// cell asserted that the async carriage contains `keepIsolateAlive = false`,
/// and a perturbation flipping the CODE to `true` left it green -- the
/// comment two lines above the assignment quotes the same words, and a
/// substring search cannot tell the two apart. A structural cell must read
/// the code, never the prose describing it.
///
/// Whole lines only, deliberately: stripping trailing `//` would also cut
/// anything after a `//` inside a string literal.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// A member's body, bounded by the closing brace at class indentation.
String _memberBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'member not found: $signature');
  final end = source.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: 'member body not delimited: $signature');
  return source.substring(start, end);
}

void main() {
  group(
    'the shim async allocation entry',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('it starts a request and returns immediately, and the result '
          'arrives from a non-caller thread intact', () async {
        await _withProvider((loaned) async {
          final port = ReceivePort();
          addTearDown(port.close);
          final first = port.first;

          final started = DateTime.now();
          final rc = bindings.zd_shm_provider_alloc_async(
            loaned,
            _chunk,
            port.sendPort.nativePort,
            _boxSink,
          );
          final returnedAfter = DateTime.now().difference(started);

          expect(rc, 0, reason: 'the entry did not start');
          // "Returns immediately" is a claim about the CALL, and the only
          // honest form of it here is that it returned before the result did
          // -- which the await below establishes by construction. The elapsed
          // bound is a generous sanity check, not a performance assertion.
          expect(returnedAfter.inSeconds, lessThan(5));

          final post = _decode(
            await first.timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail(
                'no result arrived within 10s; the entry returned 0, which '
                'contracts that exactly one post is coming',
              ),
            ),
          );

          expect(post.status, 0, reason: 'canon refused a satisfiable request');
          expect(
            post.allocError,
            -1,
            reason: 'the unselected field must be -1',
          );
          expect(post.layoutError, -1);
          expect(
            post.bufHandle,
            isNot(0),
            reason: 'the OK arm must carry a buffer the caller can take',
          );

          // The buffer is reachable through the take entry, and is a real
          // buffer: it reports the length that was asked for.
          final slot = calloc.allocate<Void>(bindings.zd_shm_mut_sizeof());
          bindings.zd_shm_async_take(post.bufHandle, slot.cast());
          final buffer = ShmMutBuffer.fromNative(slot);
          addTearDown(buffer.dispose);
          expect(buffer.length, _chunk);
        });
      });

      test('a refusal arrives in the RESULT, not in the return code', () async {
        await _withProvider((loaned) async {
          final port = ReceivePort();
          addTearDown(port.close);
          final first = port.first;

          // Zero is canon's own layout-error trigger, measured.
          final rc = bindings.zd_shm_provider_alloc_async(
            loaned,
            0,
            port.sendPort.nativePort,
            _boxSink,
          );
          expect(
            rc,
            0,
            reason:
                'canon reports refusals through the result struct; the '
                'return code says only whether the request STARTED',
          );

          final post = _decode(
            await first.timeout(
              const Duration(seconds: 10),
              onTimeout: () =>
                  fail('no result arrived for a zero-size request'),
            ),
          );
          expect(post.status, 2, reason: 'canon calls this a layout error');
          expect(post.layoutError, isNot(-1), reason: 'the selected field');
          expect(post.allocError, -1, reason: 'the unselected field');
          expect(post.bufHandle, 0, reason: 'a refusal carries no buffer');
        });
      });

      test('a rejected argument starts nothing and posts nothing', () async {
        await _withProvider((loaned) async {
          final port = ReceivePort();
          addTearDown(port.close);
          var posts = 0;
          port.listen((_) => posts++);

          final rc = bindings.zd_shm_provider_alloc_async(
            loaned,
            -1,
            port.sendPort.nativePort,
            _boxSink,
          );
          expect(
            rc,
            _rcArgumentRejected,
            reason:
                'a negative size is the shim own rejection, minted BEFORE '
                'the context is handed to canon',
          );

          // ⛔ THE ASSERTION IS THE ABSENCE OF A POST, and it needs a window to
          // be worth anything. A post would arrive on this isolate's event
          // loop, so yielding repeatedly is what gives one the chance to land.
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(
            posts,
            0,
            reason:
                'non-zero means NOTHING started, so no completion may '
                'arrive -- a caller told nothing is coming must not then be '
                'sent something',
          );
        });
      });

      test('a never-satisfiable request stays pending, and the caller is told '
          'nothing is wrong', () async {
        // ⚠️ THIS CELL DOES NOT DROP THE PROVIDER WHILE THE REQUEST IS
        // PENDING. That is the measured segfault, and making it unreachable is
        // slice 12's work, not this slice's. Here the provider is leaked
        // deliberately for the life of the cell -- one 65536-byte pool -- and
        // the cell's subject is only that canon ACCEPTS the request and then
        // says nothing.
        final slot = calloc.allocate<Void>(bindings.zd_shm_provider_sizeof());
        final created = bindings.zd_shm_provider_new(
          slot.cast(),
          _pool,
          nullptr,
          0,
          nullptr,
        );
        expect(created, 0);
        final loaned = bindings.zd_shm_provider_loan(slot.cast());

        final port = ReceivePort();
        addTearDown(port.close);
        var posts = 0;
        port.listen((_) => posts++);

        final rc = bindings.zd_shm_provider_alloc_async(
          loaned,
          _neverSatisfiable,
          port.sendPort.nativePort,
          _boxSink,
        );
        expect(
          rc,
          0,
          reason:
              'canon ACCEPTS a request it can never satisfy -- which is '
              'exactly why a Future built naively on this entry could never '
              'complete',
        );

        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(
          posts,
          0,
          reason:
              'canon completed a request the pool cannot satisfy; the '
              'measured behaviour this binding is designed around has changed',
        );
      });

      test(
        'canon negative space is not colonised, and the header says why',
        () {
          // ⛔ THE JUSTIFICATION THE SYNC FAMILY USES DOES NOT CARRY OVER, and
          // that is the whole point of this cell. The sync entries return
          // `void`, so the shim owns their entire code space and says so. This
          // entry returns `z_result_t`: canon occupies the NEGATIVE channel, so
          // every shim-owned code here must be POSITIVE or it could masquerade
          // as a canon one.
          final header = File('../src/zenoh_dart.h').readAsStringSync();
          // ⚠️ ANCHORED ON THE DECLARATION, not on an offset from the first
          // mention of the name. An earlier cut took a fixed window before the
          // first occurrence, and adding one `@param` line to the doc shifted
          // the window off the text it was asserting over -- a cell that went
          // red on a correct header. The declaration is the fixed point.
          const decl = 'FFI_PLUGIN_EXPORT int8_t zd_shm_provider_alloc_async(';
          final start = header.indexOf(decl);
          expect(start, isNot(-1), reason: 'the entry is not declared');
          // Walk back to the start of the doc block: the first line that is
          // neither a `///` comment nor blank ends it.
          final lines = header.substring(0, start).split('\n');
          final docLines = <String>[];
          for (var i = lines.length - 1; i >= 0; i--) {
            final line = lines[i].trimLeft();
            if (line.startsWith('///') || line.isEmpty) {
              docLines.insert(0, lines[i]);
              continue;
            }
            break;
          }
          final doc = docLines.join('\n');
          expect(
            doc.length,
            greaterThan(500),
            reason:
                'the doc-block walk found only ${doc.length} characters, so '
                'everything asserted below would be vacuous',
          );
          expect(
            doc,
            contains('z_result_t'),
            reason:
                'the header must say that canon occupies the negative '
                'channel here, unlike the sync family',
          );
          expect(
            doc,
            contains('11'),
            reason:
                'and it must record that 11 is deliberately not reused -- a '
                'shipped harness asserts code == 11 from another site',
          );
        },
      );
    },
  );
  group(
    'ShmProvider.allocGcDefragAsync',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('a satisfiable request completes with a buffer that behaves '
          'exactly as a synchronously allocated one', () async {
        await _withShmProvider((provider, pending) async {
          final result =
              await _track(
                pending,
                provider.allocGcDefragAsync(_chunk),
              ).timeout(
                const Duration(seconds: 10),
                onTimeout: () => fail(
                  'the async allocation never completed within 10s. The call '
                  'returned a Future, which contracts that exactly one result '
                  'is coming',
                ),
              );

          final fromAsync = _exercise(_expectAllocOk(result).buffer);
          // The same request through the shipped synchronous sibling, on the
          // same provider, exercised identically.
          final fromSync = _exercise(
            _expectAllocOk(provider.allocGcDefrag(_chunk)).buffer,
          );

          expect(fromAsync.length, _chunk);
          expect(fromAsync.readBack, equals(_probe));
          expect(fromAsync.shmBacked, isTrue);
          expect(fromAsync.length, fromSync.length);
          expect(
            fromAsync.readBack,
            equals(fromSync.readBack),
            reason:
                'the async arm delivered a buffer that reads back '
                'differently from a synchronously allocated one',
          );
          expect(fromAsync.shmBacked, fromSync.shmBacked);
        });
      });

      test('the result is canon own three-way shape, and no second shape is '
          'minted for the async entry', () async {
        await _withShmProvider((provider, pending) async {
          // Zero is canon's own layout-error trigger, measured, and the sync
          // suite already pins it to this exact kind.
          final result =
              await _track(
                pending,
                provider.allocGcDefragAsync(0),
              ).timeout(
                const Duration(seconds: 10),
                onTimeout: () =>
                    fail('no result arrived for a zero-size async request'),
              );

          expect(
            result,
            isA<LayoutError>().having(
              (e) => e.kind,
              'kind',
              LayoutErrorKind.incorrectLayoutArgs,
            ),
          );

          // ⛔ THE CLAIM IS SAMENESS, so it is asserted against the sibling
          // rather than against a literal: same sealed family, same member,
          // same canon kind, for the identical request.
          final sync = provider.allocGcDefrag(0);
          expect(result.runtimeType, sync.runtimeType);
          expect(
            (result as LayoutError).kind,
            (sync as LayoutError).kind,
            reason:
                'the async entry reported a different kind than the sync '
                'entry for the same request',
          );
        });
      });

      test('the call returns before the pool can satisfy it, and the caller '
          'own release is what completes it', () async {
        await _withShmProvider((provider, pending) async {
          final held = _expectAllocOk(provider.alloc(_holdChunk)).buffer;

          var settled = false;
          Object? failure;
          final startedAt = DateTime.now();
          final watched =
              _track(
                pending,
                provider.allocGcDefragAsync(_holdChunk),
              ).then<AllocResult?>(
                (result) {
                  settled = true;
                  return result;
                },
                onError: (Object error) {
                  settled = true;
                  failure = error;
                  return null;
                },
              );
          final callTook = DateTime.now().difference(startedAt);

          expect(
            callTook.inSeconds,
            lessThan(2),
            reason:
                'the call did not return promptly; measured at 298us at '
                'the seam, and the point of this entry is that it returns '
                'while the request is still outstanding',
          );

          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(
            settled,
            isFalse,
            reason:
                'the request completed while the caller still held the '
                'only chunk the pool can serve -- the premise of this cell '
                '(a pool that cannot satisfy it YET) no longer holds',
          );

          // ⭐ THE CALLER releases. Under the blocking sibling this line is
          // unreachable, because the caller is the party frozen.
          held.dispose();

          final result = await watched.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail(
              'the release did not complete the pending request within 10s',
            ),
          );
          expect(
            failure,
            isNull,
            reason: 'the request completed with an error: $failure',
          );
          final buffer = _expectAllocOk(result!).buffer;
          expect(buffer.length, _holdChunk);
          buffer.dispose();
        });
      });

      test(
        'a start failure throws synchronously and creates no Future',
        () async {
          await _withShmProvider((provider, pending) async {
            Object? thrown;
            Object? returned;
            try {
              returned = provider.allocGcDefragAsync(-1);
            } on Object catch (error) {
              thrown = error;
            }

            // Keeps a perturbation run readable: an entry that wrongly built a
            // Future would otherwise reject into an unhandled async error and
            // bury the cell's own diagnosis.
            if (returned is Future<AllocResult>) {
              unawaited(returned.then<void>((_) {}, onError: (Object _) {}));
            }

            expect(
              returned,
              isNull,
              reason:
                  'a Future was handed back for a request that NEVER '
                  'STARTED. Non-zero from the seam means no post is coming, so '
                  'a caller told nothing is coming must not be given something '
                  'to await',
            );
            expect(
              thrown,
              isA<ArgumentError>(),
              reason:
                  'the shim rejection code 10 is an ArgumentError '
                  'repo-wide',
            );
            expect(pending.count, 0, reason: 'nothing was started');

            // And nothing was consumed on the way out: the provider still
            // serves an ordinary request.
            _exercise(_expectAllocOk(provider.alloc(_chunk)).buffer);
          });
        },
      );

      test('a closed provider is refused before anything is allocated', () {
        final provider = ShmProvider(size: _pool)..close();

        Object? thrown;
        Object? returned;
        try {
          returned = provider.allocGcDefragAsync(_chunk);
        } on Object catch (error) {
          thrown = error;
        }
        if (returned is Future<AllocResult>) {
          unawaited(returned.then<void>((_) {}, onError: (Object _) {}));
        }

        expect(
          returned,
          isNull,
          reason:
              'a closed provider handed back a Future; the guard must '
              'refuse before a request or a port exists',
        );
        expect(thrown, isA<StateError>());

        // ⚠️ The OTHER half of the guard pair -- a native built WITHOUT
        // shared memory -- cannot be driven from here: this group only runs
        // when the loaded native HAS it. It is asserted on the stable leg, by
        // the group at the bottom of this file.
      });

      test('the blocking sibling is untouched by this slice', () {
        // ⛔ THE HONEST ABSENCE, stated beside the cell: NOTHING here drives
        // `allocGcDefragBlocking`'s parking behaviour, and nothing may. An
        // oversized request through it does not return, and because the call
        // is synchronous FFI the isolate is simply gone -- there is no
        // timeout, no cancellation and no watchdog that can reach it. A
        // ratified amendment struck exactly that cell, and the test mandate
        // forbids an unbounded wait. So the comparison this slice makes is
        // STRUCTURAL: the sibling's symbol and its dartdoc are byte-for-byte
        // what they were before this slice, which is a claim a test can
        // settle without ever calling it.
        final source = File(_providerSource).readAsStringSync();
        const first =
            '  /// Allocates a mutable SHM buffer, blocking until the pool '
            'can satisfy it.';
        const last = '_allocate(size, _strategyGcDefragBlocking, alignment);';

        final start = source.indexOf(first);
        expect(start, isNot(-1), reason: 'the blocking sibling dartdoc moved');
        final end = source.indexOf(last, start);
        expect(
          end,
          isNot(-1),
          reason:
              'the blocking sibling declaration '
              'moved or was renamed',
        );
        final region = source.substring(start, end + last.length);

        // A fingerprint, not a paraphrase: any edit inside the region changes
        // its length or its line count. If a LATER slice deliberately edits
        // it, these two numbers move with it -- that is the point.
        expect(
          region.length,
          2367,
          reason:
              'the blocking sibling dartdoc or declaration changed '
              'length; this slice must leave it byte-for-byte alone',
        );
        expect(region.split('\n').length, 42);
        expect(
          region,
          endsWith(
            'AllocResult allocGcDefragBlocking(int size, '
            '{AllocAlignment? alignment}) =>\n      $last',
          ),
        );
      });

      test('the pending request cannot pin the provider, and the port does '
          'not pin the isolate', () {
        // ⛔ STRUCTURAL, and the absence is stated rather than hidden. The
        // isolate-exit behaviour cannot be driven by a cell: every route to
        // observing it leaves a request outstanding at process exit, which is
        // the measured segfault by its second route. What CAN be settled
        // statically is the shape that makes the behaviour true, and it is a
        // compile-time guarantee rather than a convention: the port and its
        // handler are built inside a STATIC member, where no `this` exists to
        // capture. A later slice asserts that a provider with a pending
        // request is still collectable, and if the handler pinned the wrapper
        // that cell would pass VACUOUSLY -- this harness has a recorded
        // instance of exactly that trap.
        final source = File(_providerSource).readAsStringSync();

        expect(
          source,
          contains('static Future<AllocResult> _startAsync('),
          reason:
              'the async port setup is not in a static member, so its '
              'listener CAN capture the provider wrapper',
        );
        // ⛔ THE CODE, NOT THE PROSE. Every assertion below reads the
        // comment-stripped body: measured, the same cell asserting on the raw
        // body stayed GREEN while the code said `keepIsolateAlive = true`,
        // because the comment above the assignment quotes `= false`.
        final body = _codeOnly(
          _memberBody(source, 'static Future<AllocResult> _startAsync('),
        );
        expect(
          body,
          contains('RawReceivePort()..keepIsolateAlive = true'),
          reason:
              '⚠️ REVERSED AT SLICE 11 ON MEASUREMENT. The plan gate '
              'ruled `false`, reasoning that holding the isolate open turns '
              'a leak into a hang. Measured: with `false` a standalone '
              'program awaiting this method SEGFAULTS in libzenohc -- the '
              'isolate begins shutting down while canon background thread '
              'is live. The trade is not leak-versus-hang; it is hang on the '
              'pathological path versus CRASH on the ordinary one.',
        );
        expect(
          body,
          isNot(contains('keepIsolateAlive = false')),
          reason:
              'the port must keep the isolate alive for the life of the '
              'request; close() is what releases it, measured to let a '
              'never-answered request exit 0',
        );
        expect(body, contains('port.handler ='));
        for (final instanceOnly in ['_ptr', '_closed', '_ensureOpen', 'this']) {
          expect(
            body,
            isNot(contains(instanceOnly)),
            reason:
                'the static carriage reaches instance state '
                '($instanceOnly); it must take everything it needs as an '
                'argument',
          );
        }
        expect(
          RegExp(r'(?<!Raw)ReceivePort\(').hasMatch(_codeOnly(source)),
          isFalse,
          reason:
              'a plain ReceivePort does not declare keepIsolateAlive at '
              'all, so the raw form is what makes the choice explicit and '
              'reviewable rather than implicit',
        );
      });

      test('no absence-calibrated instrument shares a process with this path', () {
        // ⛔⛔ THE §3b CELL. This unit added an ALLOCATION, a POST, a THREAD
        // and a CALLBACK to a path that had none -- all four of the things
        // that invalidate an instrument calibrated on their absence. The rule
        // is to enumerate every such instrument and re-derive it, and the
        // enumeration's own soundness is what this cell keeps true.
        //
        // ⭐ THE ANSWER IS DISJOINTNESS, NOT ARITHMETIC. The exposure needs
        // CO-RESIDENCE: an instrument only miscounts if the new allocation or
        // post happens in a process it is watching. Measured at this commit,
        // the two sets do not overlap -- so no threshold was widened and none
        // needed to be, which is the outcome the rule prefers and rarely gets.
        //
        // ⚠️ Last time this shape landed, three instruments broke silently and
        // ALL THREE were invisible to targeted runs, because the change that
        // broke them was not in the files they test. A disjointness that holds
        // only by accident of today's tree would rot the same way, so it is
        // asserted rather than noted.
        //
        // MEASURED, and stated so the next reader can re-derive rather than
        // trust: the shim's new blocks are 56 bytes (the refcounted box), 112
        // (the callback context) and 80 (the buffer hand-off). The suite's
        // calibrated size classes are 202, 8, 16, 40, 1021 and 2024, and its
        // two thresholds are 400000 and 600000. Nothing collides -- but that
        // is the SECOND line of defence, not the first.
        const instrumentBearing = <String>[
          'test/ffi_ownership_test.dart',
          'test/finalizer_ownership_test.dart',
          'test/helpers/finalizer_harness.dart',
        ];
        for (final path in instrumentBearing) {
          final src = File(path).readAsStringSync();
          expect(
            src,
            isNot(contains('allocGcDefragAsync')),
            reason:
                '$path carries an instrument calibrated on the ABSENCE of '
                'an allocation, a post or a callback on this path -- and now '
                'exercises the path. Re-derive that instrument before adding '
                'this call, and do NOT widen a threshold to make it green: a '
                'number that no longer separates is not repaired by widening '
                'it.',
          );
        }

        // The control: the scan can see the call where it really is, so the
        // absences above are real negatives rather than a broken reader.
        expect(
          File(_providerSource).readAsStringSync(),
          contains('allocGcDefragAsync'),
          reason:
              'the scan found the call nowhere at all, so it proves '
              'nothing about the files above',
        );
      });

      test('the dartdoc records its shape reference, the absent oracle and '
          'the alignment carve', () {
        // The measurements this cell pins were re-run at this slice's head:
        //   find extern/zenoh-c/tests extern/zenoh-c/examples -name '*.c'
        //     -> 56 files
        //   grep -ra alloc_gc_defrag_async  <those trees>  -> 0
        //   grep -rla z_shm_provider_default_new           -> 5 files
        //   grep -rla alloc_gc_defrag_blocking             -> 2 files
        // The controls are what make the zero a finding rather than a broken
        // instrument.
        final source = File(_providerSource).readAsStringSync();
        final doc = _docBlockBefore(
          source,
          'Future<AllocResult> allocGcDefragAsync(',
        );

        expect(
          doc,
          contains('shm_provider.hxx:118'),
          reason: 'the shape reference is zenoh-cpp, cited to the line',
        );
        expect(
          doc,
          contains('no canon oracle'),
          reason:
              'canon uses this entry in none of its own C tests or '
              'examples, and a reader must be told that rather than assume '
              'the usual oracle exists',
        );
        expect(doc, contains('56'));
        expect(
          doc,
          contains('_aligned_async'),
          reason:
              'the aligned sibling is CARVED, and a carve is only a carve '
              'if it is named',
        );
        expect(
          doc,
          contains('pow: 0'),
          reason:
              'the carve carries its measured reason: the alignment '
              'ceiling on this provider is pow 0 only, so an aligned async '
              'entry has no reachable behaviour to differ on',
        );
      });
    },
  );

  group(
    'the async entry under a native without shared memory',
    skip: ZenohFeatures.hasSharedMemory
        ? 'unstable variant — the SHM gate does not fire'
        : false,
    () {
      test('the constructor gate is what refuses, and it refuses first', () {
        // The second half of the guard pair. `allocGcDefragAsync` is an
        // INSTANCE member, so the only route to it is the constructor, and
        // the constructor calls `requireShm()` before anything else -- so on
        // a native without shared memory the entry is unreachable rather than
        // merely guarded. Asserting the throw a second time under the
        // method's name would assert the constructor twice under two names.
        expect(() => ShmProvider(size: _pool), throwsUnsupportedError);
      });
    },
  );
}
