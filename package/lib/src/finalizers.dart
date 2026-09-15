// Seed [OWN] — the `NativeFinalizer` safety net's Dart half.
//
// WHAT THIS FILE IS. A wrapper in this package owns a native handle, and the
// contract for releasing it — `dispose()`, `close()`, `markConsumed()`,
// `finish()` — is written down everywhere and enforced nowhere. A caller who
// drops the last reference without calling one of them leaks, silently, with
// no observable at all. These finalizers are the net beneath that contract.
//
// ⛔ THE NET IS NOT A SUBSTITUTE FOR EXPLICIT RELEASE, and nothing here should
// be read as making one optional. A finalizer runs at an unpredictable time,
// or never — a program that exits before the collector gets round to an object
// never runs it. It converts a leak that lasts for the process's life into one
// that lasts until the next collection. That is worth having; it is not a
// lifecycle.
//
// ⛔ AND THE NET IS NOT UNIVERSAL. Ten of the twenty native-handle wrappers get
// a finalizer; ten deliberately do not, and each exclusion has a measured
// ground (a class collected while still in use, a release that reaches a Dart
// C API from a callback where that is documented undefined behaviour, or a
// release with a remote-visible effect a working program does not expect).
// The MARKER (`implements Finalizable`) goes on all twenty; the NET does not.
// See each class's own dartdoc for which side it is on and why.
//
// WHY LOOKUP RATHER THAN `bindings`. A `NativeFinalizer` needs a
// `Pointer<NativeFinalizerFunction>` — the raw entry address. The generated
// `bindings.dart` emits *callable* Dart functions, not addresses, so it cannot
// supply one. The family is therefore resolved by symbol name through
// `nativeLibrary.lookup`, which is also precisely why these symbols read as
// dead under the export-liveness rule and carry an explicit exemption in
// `src/zenoh_dart.h`.
//
// WHY EACH ONE IS LAZY. A top-level `final` in Dart initialises on FIRST READ,
// so each entry is resolved once, at its first `attach()`, and never at load.
// ⛔ That is load-bearing, not a micro-optimisation: three of the ten entries
// are `#ifdef`-guarded and are ABSENT from the `stable` native this package
// also ships (measured: `nm -D` reads 174 vs 203). Resolving the family
// eagerly at initialization would throw on the stable variant and on every
// Android build, for a consumer who never touched shared memory. The three
// guarded entries are only ever read from code paths already behind the same
// feature predicate as the canon code they release.
//
// If an UNCONDITIONAL entry is missing — a stale `.so` against newer Dart —
// `lookup` throws `ArgumentError` naming the symbol. That is deliberate and it
// is loud: the alternative is a silent no-net, where the contract looks
// enforced and is not.
import 'dart:ffi';

import 'package:meta/meta.dart';

import 'package:zenoh_dart/src/native_lib.dart';

/// Mirrors the `ZD_FIN_KIND_*` macros in `src/zenoh_dart.h`.
///
/// They are uppercase C macros precisely so ffigen's lowercase-only `zd_.*`
/// filter does not emit them, keeping the generated-binding delta for this
/// seed to exactly the function declarations — the same idiom
/// `ZD_FEATURE_UNSTABLE_API` already uses. The cost is this mirror, and the
/// cost of the mirror being wrong is a test reading the wrong counter, so it
/// is asserted against the header in `finalizer_ownership_test.dart`.
@internal
abstract final class ZdFinKind {
  /// `zd_fin_free_block` — the slot-only shape.
  static const int freeBlock = 0;

  /// `zd_fin_config`.
  static const int config = 1;

  /// `zd_fin_keyexpr` — the owned backing only; a view's string block is
  /// released through [freeBlock].
  static const int keyExpr = 2;

  /// `zd_fin_bytes`.
  static const int bytes = 3;

  /// `zd_fin_bytes_writer`.
  static const int bytesWriter = 4;

  /// `zd_fin_serializer`.
  static const int serializer = 5;

  /// `zd_fin_publisher` — matching-listener-off configuration only.
  static const int publisher = 6;

  /// `zd_fin_advanced_publisher` — matching-listener-off only, and guarded by
  /// `Z_FEATURE_UNSTABLE_API`.
  static const int advancedPublisher = 7;

  /// `zd_fin_shm_mut` — SHM-guarded.
  static const int shmMut = 8;

  /// `zd_fin_shm_provider` — SHM-guarded.
  static const int shmProvider = 9;

  /// A provider collected while an async request had been started, so the
  /// DEFERRING entry ran rather than the dropping one.
  ///
  /// ⛔ Counted separately so a cell can tell "the deferring net fired" from
  /// "nothing fired", which are the two readings a single counter would
  /// conflate — and conflating them is how a cell proving the net is reachable
  /// would pass while proving nothing.
  static const int shmProviderDeferred = 10;

  /// One past the last kind. Mirrors `ZD_FIN_KIND_COUNT`.
  static const int count = 11;
}

/// Mirrors the `ZD_FIN_ON_MAIN_*` wire values in `src/zenoh_dart.h`.
///
/// Three values, not a bool, because 0 must mean "nothing observed" rather
/// than "observed, and not the main thread" — a zero-initialised flag
/// conflates those, and they are different facts. CONV-1: the wire values are
/// declared in the header and mirrored here, and the mirror is asserted
/// against the header in `finalizer_ownership_test.dart`.
@internal
abstract final class ZdFinOnMain {
  /// The entry has not fired yet in this process.
  static const int unobserved = 0;

  /// The last firing was NOT on the Dart mutator thread.
  static const int no = 1;

  /// The last firing WAS on the Dart mutator thread.
  static const int yes = 2;
}

/// Resolves one `zd_fin_*` entry by symbol name.
///
/// Kept as a named helper so the failure has one shape and one message: a
/// bare `lookup` failure reads as an SDK error rather than as "this native is
/// older than this Dart code", which is what it always means here.
Pointer<NativeFinalizerFunction> _entry(String symbol) =>
    nativeLibrary.lookup<NativeFinalizerFunction>(symbol);

/// `zd_fin_free_block` — frees a block with no canon handle left in it.
///
/// Two users, and they are different situations that happen to share a shape:
/// a wrapper whose entire release is a `calloc.free` (`ZDeserializer`), and a
/// wrapper whose canon handle has MOVED OUT from under it, leaving only the
/// Dart-allocated slot to reclaim (a consumed `ShmMutBuffer`, a `KeyExpr`
/// view's string block).
@internal
final NativeFinalizer freeBlockFinalizer = NativeFinalizer(
  _entry('zd_fin_free_block'),
);

/// `Config`'s net: `zd_config_drop`, then the slot.
///
/// ⚠️ THE HOT DETACH. `Config.markConsumed()` FREES the Dart block rather than
/// moving ownership, so a missed detach there is a **double free** on the
/// session-open path — not a leak. Its ordering is a pinned regression guard
/// from PR #47 ("a use-after-free on a 2008-byte block"), which is why `Config`
/// is the first class this pattern is applied to: it is the same defect at one
/// call per session rather than one per message, and therefore the cheapest
/// place to get it wrong.
@internal
final NativeFinalizer configFinalizer = NativeFinalizer(
  _entry('zd_fin_config'),
);

/// `ZBytes`'s net: `zd_bytes_drop`, then the slot.
///
/// ⚠️ THE PER-MESSAGE CLASS. `ZBytes` is constructed once per message on the
/// clone-in-loop throughput and ping paths, which is why this entry's cost is
/// measured rather than assumed — this package ships latency and throughput
/// examples whose entire purpose is a number, and a silent regression on them
/// is not acceptable. The figures are in the seed's slice notes.
///
/// Its `markConsumed()` frees the Dart block on the send path exactly as
/// `Config`'s does, with the same double-free consequence for a missed detach.
@internal
final NativeFinalizer bytesFinalizer = NativeFinalizer(_entry('zd_fin_bytes'));

/// `KeyExpr`'s net, OWNED backing only: `zd_keyexpr_drop`, then the slot.
///
/// ⚠️ A VIEW-backed key expression does not use this. It owns nothing — it
/// borrows the caller's bytes — so it carries TWO [freeBlockFinalizer]
/// attachments instead, its `calloc`'d view slot and its `malloc`'d string,
/// under ONE detach key. `NativeFinalizer.detach` removes every attachment of
/// that finalizer carrying the key, so one `detach(this)` per finalizer
/// reverses both.
@internal
final NativeFinalizer keyExprFinalizer = NativeFinalizer(
  _entry('zd_fin_keyexpr'),
);

/// `ZBytesWriter`'s net: `zd_bytes_writer_drop`, then the slot.
///
/// ⚠️ THREE STATES, NOT TWO. Besides `dispose()` this class has `finish()`,
/// which moves the handle into canon and frees the slot — a release path the
/// `_consumed` vocabulary does not name, and one that must detach for exactly
/// the reason `markConsumed()` does.
@internal
final NativeFinalizer bytesWriterFinalizer = NativeFinalizer(
  _entry('zd_fin_bytes_writer'),
);

/// `ZSerializer`'s net: `zd_serializer_drop`, then the slot.
///
/// Same three-state shape as [bytesWriterFinalizer].
@internal
final NativeFinalizer serializerFinalizer = NativeFinalizer(
  _entry('zd_fin_serializer'),
);

/// `Publisher`'s net: `zd_publisher_drop`, then the slot.
///
/// ⚠️ **ATTACHED ONLY WHEN `_matchingPort == null`.** A publisher declared
/// with `enableMatchingListener: true` holds a `ReceivePort`; its drop
/// callback can post to a Dart port, and a post from a finalizer callback is
/// documented undefined behaviour. That configuration keeps today's
/// leak-on-forget, deliberately, and the reason is in the constructor beside
/// the `if`.
///
/// The MARKER is unconditional — the class cannot cross an isolate boundary in
/// either configuration. Only the NET is conditional, and it is conditional on
/// the exact fact that decides whether a drop callback can post.
@internal
final NativeFinalizer publisherFinalizer = NativeFinalizer(
  _entry('zd_fin_publisher'),
);

/// `AdvancedPublisher`'s net: `zd_advanced_publisher_drop`, then the slot.
///
/// ⚠️ Matching-listener-off only, exactly as [publisherFinalizer].
/// ⛔ **`Z_FEATURE_UNSTABLE_API`-guarded, so the symbol is ABSENT from the
/// `stable` native.** This is one of the three entries whose laziness is
/// load-bearing rather than a micro-optimisation: it is read from
/// `AdvancedPublisher`'s constructor, and nothing else reads it.
///
/// ⚠️ **That constructor has TWO routes, not one.** `Session`'s
/// `declareAdvancedPublisher` (`session_advanced_ext.dart`) calls
/// `requireUnstable()` first. But `AdvancedPublisher.declare`
/// (`advanced_publisher.dart`) is a **public factory on a class the unstable
/// door exports**, and it reaches `zd_advanced_publisher_sizeof()` with no
/// such gate. *(Corrected: this said the constructor was "reachable only
/// through `declareAdvancedPublisher`". The second route was always there.)*
///
/// ⛔ **What happens on a `stable` native down that second route is NOT
/// asserted here**, deliberately. It is a question about `NativeFinalizer`
/// resolving an absent symbol, nobody has measured it, and a comment is the
/// wrong place to guess.
@internal
final NativeFinalizer advancedPublisherFinalizer = NativeFinalizer(
  _entry('zd_fin_advanced_publisher'),
);

/// `ShmProvider`'s net: `zd_shm_provider_drop`, then the slot.
///
/// ⛔ **SHM-guarded — the symbol is ABSENT from the `stable` native and from
/// every Android build**, which is the second of the three entries whose lazy
/// resolution is load-bearing. It is read only from `ShmProvider`'s
/// constructor, which calls `requireShm()` before allocating anything.
///
/// ⚠️ **Its release does not change the contract of any live Dart object**, and
/// that is what makes it admissible: the segment is refcounted by the chunks,
/// so a live `ShmMutBuffer`, a `toBytes()` payload and a `putBytes` through one
/// all keep working after the provider is dropped. Measured.
@internal
final NativeFinalizer shmProviderFinalizer = NativeFinalizer(
  _entry('zd_fin_shm_provider'),
);

/// `ShmProvider`'s net WHILE AN ASYNC REQUEST HAS BEEN STARTED.
///
/// ⛔⛔ **THE SECOND SHAPE OF `ShmProvider`'s NET, AND IT EXISTS BECAUSE THE
/// FIRST ONE FAULTS.** [shmProviderFinalizer] drops the provider directly.
/// Dropping a provider while canon still holds a request against it segfaults
/// on a zenoh thread — measured 3/3 by explicit drop, and **3/3 again through
/// the finalizer itself**, once the pool is exhausted so canon has a live
/// waiter.
///
/// ⚠️ **The first attempt to drive that survived 5/5 and proved nothing.** It
/// used a request four times the pool, which canon parks with no waiter at
/// all — a state that cannot crash. **The discriminator is the POOL STATE, not
/// the request size**, and a cell that gets it wrong is green for the wrong
/// reason.
///
/// This entry drops nothing. It releases the collecting side's reference to
/// the shim's refcounted box, and the provider is dropped by whichever party
/// releases the **last** one — which is the only point at which canon is
/// provably finished with it.
///
/// ⛔ **SHM-guarded, so ABSENT from the `stable` native and from Android.**
@internal
final NativeFinalizer shmProviderDeferredFinalizer = NativeFinalizer(
  _entry('zd_fin_shm_provider_deferred'),
);

/// `ShmMutBuffer`'s net, FRESH state only: `zd_shm_mut_drop`, then the slot.
///
/// **TWO states, and they are not decoration:**
///
/// | state | attachment | what the finalizer releases |
/// |---|---|---|
/// | fresh | this entry | the chunk AND the slot |
/// | `toBytes()` consumed | [freeBlockFinalizer] | the slot only |
///
/// The consumed row is the ordinary one: `toBytes()` moves the chunk into a
/// `ZBytes` that carries its own net, so releasing it here as well would be a
/// double release. The slot is still this wrapper's, and is still reclaimed.
///
/// ⛔ **THERE WAS A THIRD ROW — `data` has escaped — AND IT IS RECORDED HERE
/// RATHER THAN SILENTLY DROPPED**, because a table that merely shrank invites
/// the next reader to restore it.
///
/// Its condition was: a caller had taken the raw `data` pointer. Freeing the
/// chunk under a live pointer would have turned a **leak**-on-forget into a
/// **use-after-free** — strictly worse — so that state DOWNGRADED the net
/// instead of arming it. ⚠️ The cost was that it was not an edge case: every
/// documented use of the class began by reading `data`, so for the producer
/// path the net was **structurally absent**.
///
/// ⭐ **The row is gone because the state is unreachable, not because the rule
/// changed.** `[SHM] shared-memory-lifetime` removed the getter and replaced it
/// with the copying `write`/`read` accessors. Nothing escapes, so CONV-6
/// clause (i) holds by construction and this entry is now armed unconditionally
/// on every buffer that has not been converted.
///
/// ⚠️ **What that means for a reader of an older record:** the earlier note
/// here said the downgrade *"is what lets this land without `[SHM]`'s own
/// remedy for the escaped pointer."* **That remedy has now landed.** The
/// severity-never-increases argument was correct on the surface it was given
/// and no longer has a surface to apply to.
@internal
final NativeFinalizer shmMutFinalizer = NativeFinalizer(
  _entry('zd_fin_shm_mut'),
);
