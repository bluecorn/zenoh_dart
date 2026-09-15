import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/bindings.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/alloc_alignment.dart';
import 'package:zenoh_dart/src/unstable/alloc_result.dart';
import 'package:zenoh_dart/src/unstable/features.dart';
import 'package:zenoh_dart/src/unstable/shm_mut_buffer.dart';

/// The at-most-one in-flight async allocation, held apart from the provider.
///
/// ⛔ SEPARATE FROM [ShmProvider] ON PURPOSE, and it is a reachability
/// decision rather than a tidiness one. The result handler has to clear this
/// state when a request completes, and a handler that captured the provider
/// wrapper to do so would keep it ALIVE for as long as the request is
/// pending — which for a never-answered request is the life of the process.
/// A later cell asserts that a provider with a request outstanding can still
/// be collected; if the handler pinned it, that cell would pass while
/// exercising nothing.
///
/// So the handler captures THIS, which references nothing back.
final class _AsyncSlot {
  Completer<AllocResult>? completer;
  RawReceivePort? port;

  /// The shim's reference-counted box for the request, or 0.
  ///
  /// ⛔ HELD PAST COMPLETION, DELIBERATELY. The handle is what `close()` uses
  /// to hand the provider slot over for a deferred drop, and that decision is
  /// made under the shim's lock against whether canon has finished. Releasing
  /// it when the result arrives would leave `close()` holding a dangling
  /// handle in exactly the window the deferral exists for.
  ///
  /// It is released at `close()`, or when the next request replaces it -- so
  /// at most one is live at a time, which the one-in-flight rule guarantees.
  int box = 0;

  bool get busy => completer != null;

  /// Releases the port and forgets the REQUEST. Idempotent.
  ///
  /// ⚠️ Does NOT touch [box]; see its doc.
  void clear() {
    port?.close();
    port = null;
    completer = null;
  }

  /// Forgets the request but LEAVES THE PORT ARMED.
  ///
  /// ⛔ WHY THIS EXISTS, and it cost a leak to find. `close()` answers an
  /// outstanding Future itself -- but canon does not know that, and goes on to
  /// satisfy the request and post a BUFFER. If the port is closed at that
  /// moment the message is discarded and nobody takes the handle, so the chunk
  /// is never released and pins its segment: the provider drop then reclaims
  /// nothing, and the whole deferral buys nothing.
  ///
  /// Measured: the provider-level reading stayed +65536 with the port closed
  /// at `close()`, and returned to baseline once it was left armed to drain.
  void forgetRequestKeepingPort() {
    completer = null;
    // ⛔ AND THE ISOLATE IS RELEASED HERE, which is the other half. The port
    // has to stay ARMED so a result arriving after close() is drained rather
    // than stranded -- but it must no longer keep the program alive, because
    // for a request canon can never answer that result never comes and the
    // program could never exit.
    //
    // ⭐ The property is needed only WHILE A CALLER IS WAITING. `close()` has
    // just answered them, so nobody is. Measured both ways: closed at close()
    // leaks the chunk (+65536 that the provider drop cannot reclaim); armed
    // and still holding the isolate hangs a never-answered request; armed and
    // released does neither.
    port?.keepIsolateAlive = false;
  }

  /// Releases this side's reference to the shim box, if one is held.
  void releaseBox() {
    if (box == 0) return;
    final handle = box;
    box = 0;
    bindings.zd_shm_async_box_release(handle);
  }
}

/// A shared memory provider for zero-copy data transfer.
///
/// Wraps `z_owned_shm_provider_t`. Allocate a buffer with [alloc] or one of its
/// strategy siblings, fill it with `ShmMutBuffer.write`, convert with
/// `toBytes()`, and publish. Call [close] when done.
///
/// Every allocation returns a sealed [AllocResult] — canon reports three
/// distinct outcomes and this binding preserves all three, so consume it with
/// an exhaustive `switch` and no `default` arm.
///
/// ⚠️ **No thread-safety claim is made here, deliberately.** Whether
/// [garbageCollect], [defragment] and the allocation methods are safe to call
/// concurrently against one provider — for instance while another thread
/// publishes from a buffer it holds — is **unanswered upstream**
/// (eclipse-zenoh/zenoh-c#909, still open). Canon does ship an answer-shaped
/// surface, a thread-safe provider constructor, but that constructor is a
/// carved capability this binding does not expose, so it cannot stand in as
/// the answer either. Treat one provider as belonging to one isolate until
/// upstream says otherwise; this binding will not invent a guarantee its own
/// dependency declines to give.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// It carries a `NativeFinalizer` **safety net**: if it is dropped without an
/// explicit release, its native resources are reclaimed when the object is
/// collected.
/// ⛔ The net is **not a substitute** for releasing it explicitly — a finalizer
/// runs at an unpredictable time, or not at all if the program exits first.
///
/// ## CONV-6, re-stated per clause — because this unit changed clause (iii)
///
/// 1. **Not reachable-in-use by construction.** ✅ Unchanged. Nothing a caller
///    holds in order to *use* a provider fails to reference it. ⚠️ Re-checked
///    for the new pending-request state: the async result handler captures the
///    request slot and the completer, **never this object**, so an outstanding
///    request does not make the provider reachable — which is what lets it be
///    collected at all, and is asserted by a cell.
/// 2. **Its native release calls no Dart C API.** ✅ Unchanged for the
///    dropping entry. ⚠️ The **deferring** entry added here also posts nothing:
///    it decrements a reference count and, at zero, drops. No
///    `Dart_PostCObject_DL` on either path.
/// 3. ⛔ **Its release changes no other live Dart object's contract.** **THIS
///    IS THE CLAUSE THIS UNIT MOVED, and it is why the net has two entries.**
///    The old answer rested on the segment being refcounted by its chunks, so
///    a live buffer or payload kept working after a drop — still true. What
///    was **not** true is the case nobody had: a provider collected while
///    **canon** holds an allocation request against it. Dropping there does
///    not merely change a contract, it **faults** — measured 3/3 by explicit
///    drop and 3/3 again **through the finalizer itself** on an exhausted
///    pool. So the net swaps to [shmProviderDeferredFinalizer] the moment a
///    request starts, and the drop happens when the last reference goes.
///    ▶ The clause now holds **because the release is deferred**, not because
///    the situation was impossible.
class ShmProvider implements Finalizable {
  /// Creates an SHM provider with the given total pool [size] in bytes.
  ///
  /// **A pool too small to back an allocator is refused cleanly** — this
  /// throws, and the process carries on. That is worth stating because canon's
  /// own example does not: it loans the provider without checking the return
  /// code first and segfaults on the same input (recorded at
  /// `development/reviews/canon-shm-provider-defect-20260730.md`). This
  /// constructor is a straight return-code pass-through, so the failure
  /// surfaces as an exception rather than as a crash.
  ///
  /// Where that floor sits is **host- and pin-specific**, so no number is
  /// quoted here. The committed sweep at
  /// `development/research/probes-seed7-pool-floor-20260819/` measures it,
  /// along with the per-allocation headroom a pool needs above the size you
  /// intend to allocate from it — and it carries the recipe, so the numbers
  /// can be re-derived rather than believed. What is worth knowing without
  /// reading it: **a pool sized to exactly the allocation you plan to make
  /// will not satisfy it**, at any size.
  ///
  /// Throws [ZenohException] if the provider cannot be created.
  ShmProvider({required int size}) : _ptr = _create(size) {
    // `_create` either returns a live provider or throws without constructing,
    // so reaching here means the object exists and the net is safe to arm.
    shmProviderFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_shm_provider_sizeof(),
    );
  }

  final Pointer<Void> _ptr;
  bool _closed = false;

  /// At most ONE in-flight async allocation. See [_AsyncSlot].
  final _AsyncSlot _asyncSlot = _AsyncSlot();

  static Pointer<Void> _create(int totalSize) {
    // Unstable-door gate: fail loudly on a native built without shared memory,
    // instead of a DynamicLibrary.lookup failure on the SHM symbols below.
    requireShm();
    final size = bindings.zd_shm_provider_sizeof();
    final ptr = calloc.allocate<Void>(size);

    // ⛔ WHY THE DETAIL IS FETCHED AT ALL. Canon answers EVERY rejection class
    // here with the same `-1` (Z_EINVAL): a pool too small to back the
    // allocator, a pool over the host's locked-memory budget, and a pool
    // beyond what canon's segment element index can address. One code for
    // three different rules, so the rc alone points a caller away from the
    // cause -- and the ceiling MOVES, because it is the process's
    // `RLIMIT_MEMLOCK`, so a size that worked at startup can fail later in the
    // same process for reasons that have nothing to do with size.
    //
    // Canon does distinguish them, in `zc_get_last_error`'s text. This
    // forwards canon's own sentence; it classifies nothing itself.
    //
    // ## ⚠️ NO REDACTION IS APPLIED, AND THAT IS A DECISION
    //
    // Canon's text for the over-budget class was measured to carry absolute
    // filesystem paths from inside the building developer's home directory.
    // Nothing here strips them, for the reason recorded on
    // [ZenohException.enriched]: a general redactor is not implementable at
    // this seam -- the shim receives one opaque string with no structure to
    // redact against -- and a partial one manufactures confidence. Do not
    // forward this message into a log or a bug report without deciding that
    // first.
    //
    // ⚠️ The cap is written here rather than shared with the config path's
    // copy. It degrades rather than corrupts if the two ever drift: the shim
    // clamps to its own `ZD_LAST_ERROR_CAP - 1` whatever capacity a caller
    // passes, so a stale value here costs a shorter message and nothing else.
    // A THIRD caller is the point at which hoisting earns its cost.
    const detailCap = 512;
    final errBuf = calloc<Uint8>(detailCap);
    final errLen = calloc<Int>();
    final int rc;
    final String? detail;
    try {
      rc = bindings.zd_shm_provider_new(
        ptr.cast(),
        totalSize,
        errBuf,
        detailCap,
        errLen,
      );
      final n = errLen.value;
      // Lenient by design: the shim's clamp can cut a multi-byte sequence, and
      // a message arriving with U+FFFD in it is strictly better than a decode
      // that throws while reporting an error.
      detail = n <= 0
          ? null
          : utf8.decode(errBuf.asTypedList(n), allowMalformed: true);
    } finally {
      calloc
        ..free(errBuf)
        ..free(errLen);
    }

    if (rc != 0) {
      calloc.free(ptr);
      throw ZenohException.enriched(
        'Failed to create SHM provider',
        rc,
        detail,
      );
    }

    return ptr;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('ShmProvider has been closed');
  }

  // The shim's strategy dispatch codes. Private: canon has no strategy enum,
  // and register row :90 keeps the family name-encoded as methods rather than
  // exposing a selector, so these numbers are an internal contract between
  // this file and the shim and never reach a consumer.
  static const int _strategyPlain = 0;
  static const int _strategyGc = 1;
  static const int _strategyGcDefrag = 2;
  static const int _strategyGcDefragDealloc = 3;
  static const int _strategyGcDefragBlocking = 4;

  // The shim's "argument rejected, nothing ran" code. Positive because canon's
  // ten sync allocation entries return void, so the whole code space is
  // shim-owned here; the value matches the meaning code 10 carries on the
  // declare-channel entries.
  static const int _rcArgumentRejected = 10;

  /// The one carriage: every strategy method routes here.
  ///
  /// Both heap blocks are released on **every** path. The result struct's
  /// release encloses everything that can throw; the buffer slot's ownership
  /// moves to [ShmMutBuffer] on the OK arm and is freed here on every other,
  /// including the decode seam's contract-violation throw.
  AllocResult _allocate(int size, int strategy, AllocAlignment? alignment) {
    // null routes to canon's own unaligned entry via the -1 sentinel. -1 and
    // not 0, because canon's unaligned entries are a distinct pair of symbols
    // — even though canon implements them by passing pow 0, which is why the
    // two are measurably the same request.
    final alignmentPow = alignment?.pow ?? -1;
    _ensureOpen();
    // CONV-4(a), and ALLOCATE-LAST: this precedes every calloc on the path, so
    // a rejected size leaks nothing. It has to live here rather than at the
    // seam because a negative Dart int marshalled into canon's size_t arrives
    // as a huge unsigned value and produces a legitimate-looking
    // OUT_OF_MEMORY — a caller bug reported as a capacity problem. Zero is
    // deliberately NOT rejected: CONV-4(b) passes it through, and canon
    // reports it as a layout error, which is a different and useful answer.
    //
    // CONV-4(d), the ILP32 SIZE_MAX half, is N/A here WITH REASON: SHM is
    // platform-clamped off on Android, and the only Android ABIs this product
    // ships (arm64-v8a, x86_64 — see scripts/build_zenoh_android.sh) are both
    // 64-bit, so there is no narrow target in existence to guard. The shim
    // carries the guard anyway under `#if SIZE_MAX < INT64_MAX`, which costs
    // nothing and is where it would start mattering.
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'must be non-negative');
    }
    final loaned = bindings.zd_shm_provider_loan(_ptr.cast());

    final resultPtr = calloc<zd_shm_alloc_result_t>();
    try {
      final bufPtr = calloc.allocate<Void>(bindings.zd_shm_mut_sizeof());
      var bufferHandedOff = false;
      try {
        final rc = bindings.zd_shm_provider_alloc(
          loaned,
          bufPtr.cast(),
          size,
          strategy,
          alignmentPow,
          resultPtr,
        );
        if (rc == _rcArgumentRejected) {
          // Unreachable from here: every trigger is guarded before the call.
          // Kept as the backstop, and rendered as the same ArgumentError this
          // repo maps code 10 to everywhere it appears.
          throw ArgumentError(
            'the SHM shim rejected an allocation argument and ran nothing '
            '(size $size, strategy $strategy, alignment pow $alignmentPow)',
          );
        }
        if (rc != 0) {
          throw ZenohException('SHM allocation failed to start', rc);
        }

        final result = resultPtr.ref;
        if (result.status == 0) {
          bufferHandedOff = true;
          return AllocOk(ShmMutBuffer.fromNative(bufPtr));
        }
        // Canon's error-arm `buf` is a null gravestone owning nothing, so
        // freeing our slot is complete cleanup — there is no native drop owed.
        return AllocResult.failureFromWire(
          result.status,
          result.alloc_error,
          result.layout_error,
        );
      } finally {
        if (!bufferHandedOff) calloc.free(bufPtr);
      }
    } finally {
      calloc.free(resultPtr);
    }
  }

  /// Allocates a mutable SHM buffer of the given [size], with no extra work.
  ///
  /// Canon's own words for this strategy: *"Make allocation without any
  /// additional actions."* If the pool has no room, it says so — it will not
  /// collect, defragment, or wait. `allocGcDefragBlocking` is the strategy that
  /// tries harder.
  ///
  /// [alignment] is optional: omitting it leaves canon's own choice alone and
  /// reaches canon's unaligned entry. ⚠️ On the provider this class builds,
  /// only `pow: 0` succeeds — see [AllocAlignment] for the ceiling and where
  /// its lift lives; the same applies to every allocation method here and is
  /// not repeated on each.
  ///
  /// Returns canon's three-way [AllocResult]; switch over it exhaustively.
  /// A zero [size] is **not** rejected here — it reaches canon and comes back
  /// as `LayoutError(LayoutErrorKind.incorrectLayoutArgs)`, which is a
  /// different outcome from the pool being full.
  AllocResult alloc(int size, {AllocAlignment? alignment}) =>
      _allocate(size, _strategyPlain, alignment);

  /// Allocates a mutable SHM buffer, collecting first if the pool is full.
  ///
  /// Canon's own words: *"Make allocation performing garbage collection if
  /// needed."* Garbage collection reclaims buffers that have been dropped but
  /// not yet returned to the pool — so this succeeds on space [alloc] reports
  /// as exhausted, which is the whole difference between the two.
  ///
  /// Returns canon's three-way [AllocResult]; switch over it exhaustively.
  AllocResult allocGc(int size, {AllocAlignment? alignment}) =>
      _allocate(size, _strategyGc, alignment);

  /// Allocates a mutable SHM buffer, collecting and defragmenting if needed.
  ///
  /// Canon's own words: *"Make allocation performing garbage collection and/or
  /// defragmentation if needed."*
  ///
  /// Returns canon's three-way [AllocResult]; switch over it exhaustively.
  AllocResult allocGcDefrag(int size, {AllocAlignment? alignment}) =>
      _allocate(size, _strategyGcDefrag, alignment);

  /// Allocates a mutable SHM buffer, **forcibly deallocating live buffers** if
  /// that is what it takes.
  ///
  /// Canon's own words: *"Make allocation performing garbage collection and/or
  /// defragmentation and/or forced deallocation if needed."*
  ///
  /// ⚠️ **Hazard, and it is first-class rather than a footnote.** "Forced
  /// deallocation" means this call may take space away from buffers other
  /// holders are still using — measured: a second 40960-byte request was met
  /// from a 65536-byte pool while the first 40960-byte buffer was held live,
  /// which is arithmetically only possible by displacing it. **The displaced
  /// holder observes nothing**: its handle stays readable and disposes
  /// cleanly, so there is no error to catch and no state to check. That is
  /// precisely why the hazard has to be documented rather than detected.
  ///
  /// ⛔⛔ **AND THE DISPLACED HOLDER CAN SILENTLY CORRUPT YOURS. MEASURED
  /// 2026-09-02, and it is worse than the paragraph above on its own reads.**
  ///
  /// The victim's chunk and the evictor's are **the same bytes**. A victim that
  /// is still held reads back the *evictor's* content, and — the half that
  /// matters — **a write through the surviving victim lands in the evictor's
  /// buffer**. Neither party is told. So "the displaced holder observes
  /// nothing" is true and is not the whole hazard: the displaced holder can
  /// also *act*, and its actions reach data another holder believes is its own.
  ///
  /// Conditions, because a measurement without them is a different claim: this
  /// host, zenoh-c 1.8.0, a 65536-byte pool, two 40960-byte requests through
  /// the default provider. ⚠️ **Aliasing is the allocator's history, not a
  /// contract canon states** — a backend change could stop it being true
  /// without anything being wrong, which is why no test pins it and why this
  /// is written as a hazard rather than as a guarantee.
  ///
  /// ✅ **What IS safe, and was re-measured because this binding changed it.**
  /// Releasing the victim — explicitly, or by dropping it and letting its
  /// finalizer run — leaves the evictor's bytes and length intact, under
  /// `MALLOC_PERTURB_`. That needed re-measuring: until the raw-pointer escape
  /// was removed, a written buffer's finalizer never touched its chunk at all,
  /// so the earlier "the victim dropped cleanly" finding could not have covered
  /// a chunk-releasing net firing on a chunk the evictor holds.
  ///
  /// Use this only where the provider's buffers are all yours. Where they are
  /// not, [allocGcDefrag] is the same call without the eviction.
  ///
  /// Returns canon's three-way [AllocResult]; switch over it exhaustively.
  AllocResult allocGcDefragDealloc(int size, {AllocAlignment? alignment}) =>
      _allocate(size, _strategyGcDefragDealloc, alignment);

  /// Allocates a mutable SHM buffer, blocking until the pool can satisfy it.
  ///
  /// Canon's own words: *"Make allocation performing garbage collection
  /// and/or defragmentation and/or blocking if needed."*
  ///
  /// ⛔ **This blocks the calling thread, and in Dart that means the calling
  /// isolate.** The call is synchronous FFI: there is no await point, nothing
  /// else in the isolate runs while it waits, and no timer, timeout or
  /// cancellation can reach it. That is canon's primitive rendered faithfully
  /// — offloading it to a worker would be a different function wearing this
  /// one's name — and it is why the siblings exist.
  ///
  /// ⛔ **On a request that can NEVER be satisfied it never returns.** Not
  /// "eventually gives up": there is no timeout, no exception and no recovery
  /// path, so the isolate is gone. Measured: an oversized request parked past
  /// a 5 s watchdog, while the same request with space freed by a helper
  /// thread at t+500 ms unblocked at ~501 ms — so the wait itself works
  /// exactly as advertised, and that is the problem. **A size simply larger
  /// than the pool is enough**; it does not take an exhausted pool full of
  /// live buffers. A typo in a size expression reaches this.
  ///
  /// Which inputs park and which return, measured:
  ///
  /// | input | behaviour |
  /// |---|---|
  /// | a size the pool can satisfy | returns [AllocOk] |
  /// | a size the pool can satisfy *after* waiting | parks, then returns |
  /// | a size the pool can **never** satisfy | **parks forever** |
  /// | `size: 0` | returns a layout error immediately |
  /// | an [alignment] the provider cannot honour | returns a layout error |
  ///
  /// The pattern is that **layout-class** refusals happen before the retry
  /// loop is entered, and **size-class** ones happen inside it.
  ///
  /// **The way out is a sibling.** [alloc], [allocGc], [allocGcDefrag] and
  /// [allocGcDefragDealloc] make the same request and report
  /// `AllocError(AllocErrorKind.outOfMemory)` instead of waiting. Prefer one
  /// of them unless you know another party frees space on another thread.
  ///
  /// Returns canon's three-way [AllocResult]; switch over it exhaustively.
  AllocResult allocGcDefragBlocking(int size, {AllocAlignment? alignment}) =>
      _allocate(size, _strategyGcDefragBlocking, alignment);

  /// Allocates a mutable SHM buffer **without parking the isolate**,
  /// completing when canon has an answer.
  ///
  /// Canon's `z_shm_provider_alloc_gc_defrag_async`. It is the same request
  /// [allocGcDefragBlocking] makes — garbage-collect, defragment, then wait —
  /// handed to canon's own background machinery instead of waited on inside
  /// the call. The call returns while the request is still outstanding
  /// (measured at ~300 µs) and the outcome arrives on the calling isolate's
  /// event loop.
  ///
  /// Returns canon's same three-way [AllocResult]; switch over it
  /// exhaustively. ⛔ **An async entry does not get a second result shape** —
  /// canon reports every allocation through one struct however the request
  /// was made, so the outcomes here are the outcomes there.
  ///
  /// ⭐ **The shape this makes possible and the blocking sibling cannot.** A
  /// caller holding the pool's only free chunk can issue a request the pool
  /// cannot satisfy *yet*, and then release that chunk itself — measured, the
  /// Future completed 2 ms after the caller's own `dispose()`. Under
  /// [allocGcDefragBlocking] that release is unreachable, because the caller
  /// is the party frozen.
  ///
  /// ```dart
  /// switch (await provider.allocGcDefragAsync(8192)) {
  ///   case AllocOk(:final buffer): // write, toBytes(), publish
  ///   case AllocError(:final kind): // the pool could not do it
  ///   case LayoutError(:final kind): // the request itself was refused
  /// }
  /// ```
  ///
  /// ## ⛔ It can stay pending forever, and there is no way to cancel it
  ///
  /// ⚠️ **A request the pool can NEVER satisfy is accepted and then never
  /// answered** — no result, no error, no timeout, and canon does not reclaim
  /// its own context either. It does not take an absurd size: the pool's
  /// **nominal** size never completes, because the pool carries overhead, so
  /// a request for "the pool size" is already in this class.
  ///
  /// **There is no cancellation, deliberately.** Canon ships no cancel entry
  /// for this family, and a Dart-side one would abandon the Future while
  /// leaving canon's request outstanding — saying the opposite of what
  /// happened. **And no `Duration timeout` parameter**, for the same reason:
  /// it would bound the Future rather than the thing that matters, and it is
  /// a parameter canon does not have. Wrap the returned Future in
  /// `.timeout(...)` if a bounded *Dart* wait is what you want, knowing the
  /// native request outlives it.
  ///
  /// ⚠️ **A pending request DOES hold the isolate open, and closing the
  /// provider is what releases it.** An awaited allocation keeps your program
  /// alive until it is answered — which is what you want, and is why an
  /// ordinary `await` of this method works in a small program. A request the
  /// pool can never satisfy therefore keeps the program alive too, and
  /// [close] is the escape: it answers the Future and releases the port, and
  /// the program exits.
  ///
  /// ⛔ **So a never-answered request that is never closed will not let your
  /// program exit.** That request was already leaking its segment for the
  /// life of the process, and it is a program error rather than a recoverable
  /// condition — but the failure it produces is a hang, and you should know
  /// that rather than discover it.
  ///
  /// ## ⛔ ONE IN FLIGHT PER PROVIDER — a second call throws
  ///
  /// While a request is pending, another `allocGcDefragAsync` on the **same
  /// provider** throws [StateError]. It is refused, not queued: nothing is
  /// started and the outstanding request is untouched.
  ///
  /// **The ground is upstream, not convenience.** Whether this provider is
  /// safe to use concurrently is **unanswered** (eclipse-zenoh/zenoh-c#909,
  /// still open), and two in-flight allocations on one provider *is*
  /// concurrent use of it by canon's own background tasks. This class already
  /// says it will not invent a guarantee its dependency declines to give;
  /// accepting a second request would contradict that in code.
  ///
  /// ⚠️ **A local measurement cannot license the other answer.** A red result
  /// would force this narrowing anyway; a green one would establish only
  /// *"it worked twice, on this box, at this pin, while the upstream question
  /// is open"*, which is not a contract. **The widening trigger is #909
  /// resolving.**
  ///
  /// ⭐ **The refusal is transient, not terminal.** The slot is freed the
  /// moment a request is answered — by completion or by [close] — so a
  /// provider whose request has finished accepts the next one immediately.
  /// ⛔ The **synchronous** allocation methods are unaffected: they cannot
  /// overlap within an isolate.
  ///
  /// ⚠️ The consequence, stated rather than hidden: a request the pool can
  /// never satisfy **dead-ends this provider's async lane** for its lifetime,
  /// because the slot is never freed. That request already leaks its segment
  /// permanently, so the lane was already dead — but it is worth knowing that
  /// the two failures arrive together.
  ///
  /// ## The aligned sibling is carved, with its reason
  ///
  /// There is **no `alignment` parameter**. Canon's `..._aligned_async`
  /// exists and is not bound: the alignment ceiling on the provider this
  /// class constructs is measured `pow: 0` only (see [AllocAlignment]), so an
  /// aligned async entry has no reachable behaviour to differ on. If that
  /// ceiling ever lifts, the parameter arrives with it.
  ///
  /// ## ⚠️ There is no canon oracle for this entry
  ///
  /// **Canon uses it in none of its own C tests or examples** — measured
  /// across 56 files in `extern/zenoh-c/{tests,examples}`, zero uses of
  /// `alloc_gc_defrag_async`, against live controls in the same trees
  /// (`z_shm_provider_default_new` in 5 files, `..._blocking` in 2). The
  /// symbol appears only in canon's Rust and its header. So the shape
  /// reference is the structural peer instead: **zenoh-cpp
  /// `shm_provider.hxx:118`**, which passes a receiver object canon owns and
  /// deletes; this binding posts to a port and completes a Future, because a
  /// Dart caller has no receiver to hand over.
  ///
  /// Throws [StateError] if the provider has been closed, and [ArgumentError]
  /// if [size] is negative. ⛔ **Both throw synchronously, before any Future
  /// exists** — a caller told that nothing started must not be handed
  /// something to await. Throws [ZenohException] if the request could not be
  /// started at all.
  Future<AllocResult> allocGcDefragAsync(int size) {
    _ensureOpen();
    // CONV-4(a) and ALLOCATE-LAST, exactly as on the synchronous carriage: a
    // negative Dart int marshalled into canon's size_t arrives as a huge
    // unsigned value and comes back as a legitimate-looking OUT_OF_MEMORY —
    // a caller bug reported as a capacity problem. Zero is deliberately NOT
    // rejected; canon answers it with a layout error, which is useful.
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'must be non-negative');
    }
    // ⛔ ONE IN-FLIGHT ASYNC ALLOCATION PER PROVIDER. Refused, not queued.
    //
    // The ground is upstream, not convenience: whether this provider is safe
    // to use concurrently is UNANSWERED (eclipse-zenoh/zenoh-c#909, open),
    // and two in-flight allocations on one provider IS concurrent use of it
    // by canon's own background tasks. This class already says in prose that
    // it "will not invent a guarantee its own dependency declines to give";
    // accepting a second request would contradict that in code.
    //
    // ⚠️ And a probe cannot license the other answer. A red result forces the
    // narrowing anyway; a green one establishes only "it worked twice, on
    // this box, at this pin, while the upstream question is open" — which is
    // not a contract. So the widening trigger is **#909 resolving**, not a
    // measurement of ours.
    if (_asyncSlot.busy) {
      throw StateError(
        'ShmProvider already has an async allocation in flight. This binding '
        'permits one at a time per provider, because whether canon is safe '
        'to use concurrently on one provider is unanswered upstream '
        '(eclipse-zenoh/zenoh-c#909). Await the outstanding request first; '
        'the synchronous allocation methods are unaffected.',
      );
    }
    final previousBox = _asyncSlot.box;
    final future = _startAsync(
      bindings.zd_shm_provider_loan(_ptr.cast()),
      size,
      _asyncSlot,
    );

    // ⛔⛔ THE NET SWAPS HERE, AND THE ORDER IS THE WHOLE OF IT.
    //
    // From this point the provider must NOT be dropped directly: doing so
    // while canon holds a request faults, and that is reachable through the
    // FINALIZER, not only through close() -- measured 3/3 on an exhausted
    // pool. So the slot is handed to the request's box, and the net is
    // swapped to an entry that releases that box instead of dropping.
    //
    // The slot then MOVES off the previous box before that one is released:
    // left there, releasing it would drop a provider still in use.
    final box = _asyncSlot.box;
    if (box != 0) {
      bindings.zd_shm_provider_defer_drop(box, _ptr.cast());
      if (previousBox != 0 && previousBox != box) {
        bindings
          ..zd_shm_provider_undefer_drop(previousBox)
          ..zd_shm_async_box_release(previousBox);
      }
      shmProviderFinalizer.detach(this);
      shmProviderDeferredFinalizer
        ..detach(this)
        ..attach(
          this,
          Pointer<Void>.fromAddress(box).cast(),
          detach: this,
          externalSize: bindings.zd_shm_provider_sizeof(),
        );
    }
    return future;
  }

  /// Starts one asynchronous request and returns the Future its single post
  /// completes.
  ///
  /// ⛔⛔ **STATIC ON PURPOSE, and it is a correctness constraint rather than
  /// a style one.** The port's handler must not capture the [ShmProvider]
  /// wrapper: a request that is still outstanding would then keep the wrapper
  /// reachable, and a later test asserting that a provider with a pending
  /// request can still be collected would pass **vacuously**. A static member
  /// has no receiver at all, so the capture is unrepresentable rather than
  /// merely avoided; everything the carriage needs arrives as an argument.
  ///
  /// The port is created here and closed by the handler, on every arm.
  static Future<AllocResult> _startAsync(
    Pointer<Opaque> loaned,
    int size,
    _AsyncSlot slot,
  ) {
    final completer = Completer<AllocResult>();
    // ⛔⛔ `keepIsolateAlive = TRUE`, AND THIS REVERSES A PLAN-GATE DECISION
    // ON MEASUREMENT. The gate ruled `false`, reasoning that a pending
    // allocation holding the isolate open would turn a permanent leak into a
    // permanent hang. The reasoning is sound and the premise is wrong: with
    // `false` the ordinary path does not exit cleanly, it CRASHES.
    //
    // Measured, standalone program, `await provider.allocGcDefragAsync(...)`
    // with nothing else pending:
    //
    //   keepIsolateAlive = false  ->  SIGSEGV in libzenohc on a zenoh thread
    //                                 (isolate=nil), before the result lands
    //   keepIsolateAlive = true   ->  COMPLETED=AllocOk, clean exit
    //
    // With `false` the isolate has no reason to stay alive -- the port is the
    // only thing waiting -- so it begins shutting down while canon's
    // background thread is still live, and canon then touches a torn-down VM.
    // ▶ The trade is not "leak versus hang". It is "hang on the pathological
    // path" versus "SEGFAULT ON THE ORDINARY ONE", and the ordinary one is
    // exactly what a small program or an example does.
    //
    // ⚠️ AND THE HANG IS ESCAPABLE, measured on the same probe: a
    // never-satisfiable request followed by `close()` prints CLOSED and the
    // program EXITS 0, because close() releases this port. The escape is the
    // one `close()` was already designed to be.
    //
    // ⛔ WHY THE CITED PRECEDENT DOES NOT TRANSFER. The gate reasoned from
    // `Zenoh.initLogWithSink`, which uses `false` correctly -- but that sink
    // has NO REMOVAL, so its port would pin the isolate FOREVER. This port is
    // closed when the request completes or when the provider is closed. The
    // two lifetimes are different in kind: one is unbounded by construction,
    // the other is bounded by the request.
    //
    // RawReceivePort, not ReceivePort: `keepIsolateAlive` is declared on the
    // raw form and not on the other, so the shape is part of the constraint.
    final port = RawReceivePort()..keepIsolateAlive = true;
    // The handler is assigned separately rather than folded into the cascade
    // above: it closes over `port`, and a cascade would reference the
    // variable inside its own initializer. ⚠️ The cascade's exact text is
    // PINNED by a cell -- it asserts `keepIsolateAlive = true` and forbids
    // `= false`, on the measurement in the block above, RATIFIED at the merge
    // gate 2026-09-03 -- so do not reflow this into two plain statements to
    // satisfy the linter.
    // ignore: cascade_invocations
    port.handler = (dynamic message) {
      // Exactly one post arrives per started request, so the port has done
      // its whole job by the time the first one lands.
      //
      // ⛔ THE SLOT IS FREED FIRST, and the order matters: the one-in-flight
      // rule bounds CONCURRENCY, not the provider's lifetime, so the next
      // request must be accepted the moment this one is answered. Clearing
      // after the completion would leave the lane shut for an event-loop
      // turn, and a caller chaining allocations would see a StateError it
      // could not have avoided.
      //
      // ⚠️ `close()` may have got here first, in which case it already
      // completed this Completer and cleared the slot. `clear()` is
      // idempotent and the guard below stops a second completion.
      final alreadyAnswered = completer.isCompleted;
      slot.clear();
      if (alreadyAnswered) {
        // ⛔⛔ THE RESULT STILL HAS TO BE DRAINED, AND MISSING THIS LEAKED A
        // CHUNK. `close()` may have answered this Future already -- with the
        // exception naming that the provider was closed mid-request. Canon
        // does not know that: it goes on to satisfy the request and posts a
        // BUFFER, and nobody is waiting for it any more.
        //
        // Returning here strands that buffer: the chunk is never released, so
        // it pins its segment and the deferred provider drop reclaims
        // nothing. Measured -- the provider-level reading came back +65536
        // with this branch bare, and 0 once the buffer was taken and
        // released.
        //
        // ⚠️ It is taken and DISPOSED rather than handed anywhere: the caller
        // has already been told the request failed, and giving them a buffer
        // afterwards would contradict that.
        _drainOrphanedResult(message);
        return;
      }
      try {
        completer.complete(_resultFromPost(message));
      } on Object catch (error, stackTrace) {
        // A malformed post is a contract violation, and it belongs on the
        // Future the caller is already awaiting — never thrown from a
        // handler, where nobody is listening.
        completer.completeError(error, stackTrace);
      }
    };

    slot
      ..completer = completer
      ..port = port;

    // The previous request's box, if any, is released here rather than at its
    // completion -- see [_AsyncSlot.box]. At most one is ever live, because a
    // second request cannot start while one is pending.
    final outBox = calloc<Int64>();
    final int rc;
    try {
      rc = bindings.zd_shm_provider_alloc_async(
        loaned,
        size,
        port.sendPort.nativePort,
        outBox,
      );
      slot.box = outBox.value;
    } finally {
      calloc.free(outBox);
    }
    if (rc != 0) {
      // ⛔ Non-zero means NOTHING started, so no post is coming. The port is
      // released, the slot is freed -- a request that never began must not
      // hold the lane shut -- and the caller gets a throw rather than a
      // Future that could never complete.
      slot.clear();
      if (rc == _rcArgumentRejected) {
        // Unreachable from the public entry, whose own guard rejects the one
        // trigger first. Kept as the backstop, rendered as the ArgumentError
        // code 10 maps to repo-wide.
        throw ArgumentError(
          'the SHM shim rejected an async allocation argument and started '
          'nothing (size $size)',
        );
      }
      throw ZenohException('SHM async allocation failed to start', rc);
    }
    return completer.future;
  }

  /// Decodes one posted result into canon's three-way [AllocResult].
  ///
  /// The wire is four `int64` values — status, alloc error, layout error,
  /// buffer handle — and they cross into Dart `int`s at full width, so
  /// nothing is narrowed, defaulted or discarded between the shim and the
  /// sealed result. The two error codes travel to canon's own decoders
  /// unmodified; only the SELECTED one is read, because the shim gravestones
  /// the other to -1.
  /// Releases a buffer that arrived after its Future was already answered.
  ///
  /// The only caller is the result handler's already-answered branch; see the
  /// comment there for why this exists and what it cost to find.
  static void _drainOrphanedResult(dynamic message) {
    if (message is! List || message.length < 4) return;
    final handle = message[3];
    if (handle is! int || handle == 0) return;
    final slot = calloc.allocate<Void>(bindings.zd_shm_mut_sizeof());
    var handedOff = false;
    try {
      bindings.zd_shm_async_take(handle, slot.cast());
      handedOff = true;
      // Straight through the shipped wrapper, so the chunk-releasing net and
      // the drop path are the same ones every other buffer uses.
      ShmMutBuffer.fromNative(slot).dispose();
    } finally {
      if (!handedOff) calloc.free(slot);
    }
  }

  static AllocResult _resultFromPost(dynamic message) {
    final post = message as List<Object?>;
    final status = post[0]! as int;
    if (status != 0) {
      // Canon's two failure arms, through the single production decoder. An
      // out-of-domain status throws there and reaches the caller's Future.
      return AllocResult.failureFromWire(
        status,
        post[1]! as int,
        post[2]! as int,
      );
    }

    final handle = post[3]! as int;
    if (handle == 0) {
      // The shim could not allocate a block to carry the buffer, and released
      // the chunk rather than leaking it. Canon's OK arm always carries a
      // buffer, so the pair is unambiguous — and there is nothing owed here.
      throw ZenohException(
        'the SHM shim reported a successful async allocation with no buffer '
        'to take: it could not allocate a carrier block, and released the '
        'chunk instead of leaking it',
        status,
      );
    }

    final bufPtr = calloc.allocate<Void>(bindings.zd_shm_mut_sizeof());
    var bufferHandedOff = false;
    try {
      bindings.zd_shm_async_take(handle, bufPtr.cast());
      final buffer = ShmMutBuffer.fromNative(bufPtr);
      bufferHandedOff = true;
      return AllocOk(buffer);
    } finally {
      if (!bufferHandedOff) calloc.free(bufPtr);
    }
  }

  /// Performs manual memory defragmentation on the pool.
  ///
  /// Canon's own words: *"Perform memory defragmentation. The real operations
  /// taken depend on the provider's backend allocator implementation."*
  ///
  /// This is the actionable arm of canon's `needDefragment` vocabulary — the
  /// call whose name matches that condition. Canon states no relationship
  /// between the two beyond the naming, and this binding invents none.
  ///
  /// Returns canon's `size_t` verbatim. ⚠️ **Canon documents no meaning for
  /// the number** — not bytes reclaimed, not a count of anything — and it was
  /// measured returning 0 throughout a run in which defragmentable space
  /// existed. Do not assert a magnitude on it or branch on it; it is carried
  /// rather than interpreted because dropping a return value canon chose to
  /// have is not this binding's call to make.
  ///
  /// Throws [StateError] if the provider has been closed.
  int defragment() {
    _ensureOpen();
    final loaned = bindings.zd_shm_provider_loan(_ptr.cast());
    return bindings.zd_shm_provider_defragment(loaned);
  }

  /// Performs manual garbage collection on the pool.
  ///
  /// Canon's own words: *"Perform memory garbage collection and reclaim all
  /// dereferenced SHM buffers."* Buffers that have been dropped but not yet
  /// returned to the pool are what this reclaims — the same work [allocGc]
  /// does on your behalf when a plain [alloc] would have reported the pool
  /// full.
  ///
  /// Returns canon's `size_t` verbatim, with the same caveat as [defragment]:
  /// ⚠️ canon documents no meaning for it, and it was measured returning
  /// 16384 where 32768 bytes were pending, so it is **not** bytes reclaimed.
  ///
  /// ⚠️ The C API binds canon's **unsafe** garbage-collection flavour, and
  /// the safe/unsafe distinction is invisible at the C boundary — there is no
  /// second entry to choose. Stated because a reader who knows the Rust API
  /// would otherwise wonder which one they got; this binding cannot resolve it
  /// upstream of the contract it wraps.
  ///
  /// Throws [StateError] if the provider has been closed.
  int garbageCollect() {
    _ensureOpen();
    final loaned = bindings.zd_shm_provider_loan(_ptr.cast());
    return bindings.zd_shm_provider_garbage_collect(loaned);
  }

  /// Releases the provider.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  ///
  /// ⚠️ **The shared-memory segment is an OS object, and it can outlive this
  /// call and this process.** A segment is visible to other processes by
  /// design; closing the provider releases *this* handle on it, not
  /// necessarily the segment itself, and upstream has reported segments
  /// surviving the owning process (eclipse-zenoh/zenoh-c#1267). So a crashed
  /// or killed publisher can leave a segment behind, and this method is not a
  /// remedy for that. It is remote-visible in the sense CONV-3 means — peers
  /// stop being able to read through this provider — but it is not a
  /// system-level cleanup guarantee, and nothing in this binding provides one.
  void close() {
    if (_closed) return;
    _closed = true;
    shmProviderFinalizer.detach(this);

    // ⛔ THE OUTSTANDING REQUEST IS ANSWERED, NOT ABANDONED. Its Future is
    // completed with an exception naming what happened, and the port is
    // released. A Future left dangling forever is the deadlock in Dart
    // clothing, and this method's whole contract is that it always
    // terminates and never throws.
    //
    // ⚠️ CLOSING DOES NOT CANCEL CANON'S REQUEST. Canon ships no cancel
    // entry. Completing this Future ends the DART-side wait and nothing else:
    // canon's request stays outstanding, and if it can never be satisfied it
    // is never answered and its context is never reclaimed.
    final pending = _asyncSlot.completer;
    if (pending != null) {
      // ⛔ The port stays ARMED -- see [_AsyncSlot.forgetRequestKeepingPort].
      _asyncSlot.forgetRequestKeepingPort();
    } else {
      _asyncSlot.clear();
    }
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        ZenohException(
          'ShmProvider was closed with an async allocation outstanding. The '
          'Dart wait ends here; canon offers no way to cancel the request '
          'itself, so its segment is not reclaimed.',
          -1,
        ),
      );
    }

    final box = _asyncSlot.box;
    shmProviderDeferredFinalizer.detach(this);
    if (box != 0) {
      // ⛔⛔ THE NATIVE PROVIDER IS DELIBERATELY NOT DROPPED HERE, AND THE
      // ALTERNATIVE IS NOT A LEAK -- IT IS A SEGFAULT. Dropping a provider
      // while canon still holds a request against it faults on a zenoh
      // thread: measured 3/3 against a clean control that performs the
      // identical drop on the identical exhausted pool with no request
      // started. The probe and its readings are committed at
      // `development/research/probes-ci-shm-20260902/`.
      //
      // ⚠️ The drop returns FIRST and the fault lands afterwards, so a caller
      // sees a clean return and dies later -- which is why this cannot be
      // left to be noticed in testing.
      //
      // So the provider and its slot are retained. This trades a segfault for
      // a leak, which is the same trade `[OWN]` made when it chose a leak
      // over a use-after-free, in the same direction: the severity never
      // increases.
      //
      // ▶ THE SLOT IS ALREADY THE BOX'S -- it was handed over when the request
      // started, so that the FINALIZER could defer through it too. Releasing
      // this side's reference is all that is left; the provider is dropped by
      // whoever releases the last one, which is the only point at which canon
      // is provably finished with it.
      //
      // ⚠️ For a request canon can NEVER answer, canon never releases its
      // reference, so the provider is retained for the life of the process.
      // Unavoidable at this pin: canon ships no cancel entry. Every request
      // that DOES complete is reclaimed, which was the reclaimable part.
      //
      // ⛔ Ownership of the slot BLOCK moved with it. The shim frees it, so
      // there is no `calloc.free` on this path.
      _asyncSlot.releaseBox();
      return;
    }

    bindings.zd_shm_provider_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
