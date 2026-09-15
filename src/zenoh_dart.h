#ifndef ZENOH_DART_H
#define ZENOH_DART_H

#include <stdint.h>
#include <zenoh.h>

// FFI_PLUGIN_EXPORT: marks symbols for visibility from Dart FFI.
#if defined(_WIN32) || defined(__CYGWIN__)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// Dart API initialization
// ---------------------------------------------------------------------------

/// Initializes the Dart native API for dynamic linking.
///
/// Must be called before any other zenoh_dart functions that use
/// Dart native ports. Pass `NativeApi.initializeApiDLData` from Dart.
///
/// Returns 0 on success.
FFI_PLUGIN_EXPORT intptr_t zd_init_dart_api_dl(void* data);

/// Initializes the zenoh logger from the RUST_LOG environment variable,
/// falling back to the provided filter string if RUST_LOG is not set.
///
/// ⛔ CLAIMS THE PROCESS-GLOBAL LOGGING SLOT, PERMANENTLY. Canon's inits are
/// first-wins and silently idempotent, so calling this forecloses installing
/// a host sink for the life of the process -- see zd_init_log_with_callback,
/// which reports the foreclosure rather than returning a dead channel. It
/// stays void itself: a caller who wanted the env logger got the env logger,
/// and there is nothing to report.
///
/// @param fallback_filter  Filter string (e.g., "error", "info", "debug").
FFI_PLUGIN_EXPORT void zd_init_log(const char* fallback_filter);

/// Installs a host log sink: routes canon's own log records to a Dart port.
///
/// Wraps zc_init_log_with_callback(). Canon's records normally go to stderr
/// under RUST_LOG; this hands them to the host application instead, which is
/// what makes a level ceiling in code -- and host-side redaction -- possible
/// at all.
///
/// ⛔ THE RETURN IS "DID OUR BINDING CLAIM THE SLOT", NOT "DID IT SUCCEED".
/// Canon returns void: it has no channel to report anything, because its
/// three inits are first-wins, process-global and SILENTLY idempotent, and
/// whichever runs first owns logging for the life of the process. So this
/// wrapper keeps its own record of whether an init MADE THROUGH THIS BINDING
/// has already claimed the slot, and reports that. It is the zd_scout
/// did-it-start contract in the same words: non-zero means nothing was
/// installed and no record will ever arrive, so the caller must fail rather
/// than hand back a channel that can never deliver.
///
/// ⚠️ The flag sees only inits made through this binding. An init made by
/// other code in the same process is invisible to it, and canon reports
/// nothing itself.
///
/// Records are posted to dart_port as a two-element array: the severity as an
/// int64 matching zc_log_severity_t, and the message as length-carried bytes.
///
/// @param min_severity  0=trace 1=debug 2=info 3=warn 4=error; lower-severity
///                      records are dropped by canon before the callback.
/// @param dart_port     NativePort to post records to.
/// @return 0 when this call claimed the slot and installed the sink;
///         non-zero when the slot was already claimed (nothing installed) or
///         min_severity is outside canon's domain.
FFI_PLUGIN_EXPORT int zd_init_log_with_callback(int min_severity,
                                                int64_t dart_port);

// ---------------------------------------------------------------------------
// The upstream-detail contract: err_buf / err_cap / err_len
// ---------------------------------------------------------------------------
//
// Every entry point below that can surface canon's own explanation of ITS OWN
// failure takes the same trailing triple. The detail is written by the call
// that produced the rc, into storage the CALLER supplied, and is never read
// back by a later call. There is no shim-owned buffer to read, so a foreign
// read is not representable.
//
// This replaced a _Thread_local durable buffer plus an exported reader. That
// mechanism was measured returning ANOTHER OPERATION'S message 249 times in
// 300 when the read straddled an event-loop turn
// (development/independent/concurrency-reappraisal-20260827.md:118): the VM
// migrates an isolate between OS threads, so the read landed on a thread that
// had not made the call. Thread-pinning was measured NOT to fix it (255 of 300
// migrated anyway). The repair is structural, not a tightening.
//
//   err_buf  Caller-allocated storage for THIS call's detail. May be NULL to
//            decline the detail; the call still reports its rc.
//   err_cap  Capacity of err_buf in bytes. A NUL terminator is written within
//            it, so at most err_cap - 1 detail bytes are copied -- and never
//            more than ZD_LAST_ERROR_CAP - 1 (511) whatever err_cap says.
//            Pass ZD_LAST_ERROR_CAP to receive everything the shim will give.
//   err_len  Out: bytes written to err_buf, ALWAYS SET, on every path
//            including success. 0 means no detail -- which is the whole
//            answer on the `stable` variant, where zc_get_last_error is
//            compiled out. It is length-carried rather than NUL-delimited
//            because that is this repo's rule for every value crossing the
//            seam, terminator notwithstanding.

/// Bound on the detail any one call will copy out, terminator included.
///
/// One stage of the chain a message crosses; the others are documented on the
/// Dart surface (`ZenohException`).
#define ZD_LAST_ERROR_CAP 512

// ---------------------------------------------------------------------------
// Build feature detection
// ---------------------------------------------------------------------------

// Feature bits returned by zd_features(). NOT guarded -- these macros and the
// function are compiled into EVERY variant so a caller can detect, at runtime,
// which optional features the loaded native was built with. (ffigen's zd_.*
// filter is lowercase-only and case-sensitive, so these uppercase macros are
// NOT emitted to bindings.dart; Dart consumers mirror the bit positions.)
#define ZD_FEATURE_UNSTABLE_API (1u << 0)
#define ZD_FEATURE_SHARED_MEMORY (1u << 1)

/// Returns a bitmask of the optional zenoh features this native was built with.
///
/// ZD_FEATURE_UNSTABLE_API is set when Z_FEATURE_UNSTABLE_API was defined at
/// compile time; ZD_FEATURE_SHARED_MEMORY when Z_FEATURE_SHARED_MEMORY was.
/// Which bits are set depends on the build variant the native was compiled
/// as, so two natives for the same platform can answer differently. One fact
/// holds on every variant: an Android native never carries shared memory. The
/// Dart layer uses this to fail loudly when an unstable entrypoint is called
/// against a native that lacks the feature (a build-variant mismatch), instead
/// of crashing in zenoh-c. Cheap enough to call once and cache.
FFI_PLUGIN_EXPORT uint32_t zd_features(void);

// ---------------------------------------------------------------------------
// NativeFinalizer entry points  (seed [OWN])
// ---------------------------------------------------------------------------
//
// THE CONTRACT EVERY zd_fin_* ENTRY BELOW SHARES. Read it once here; each
// entry repeats only what is specific to it.
//
//   * REACHABLE ONLY AS A `NativeFinalizer` CALLBACK. Never call one of these
//     from Dart. They are resolved by SYMBOL NAME through
//     `DynamicLibrary.lookup<NativeFinalizerFunction>`, never through a
//     generated `bindings.dart` call.
//
//     ⚠️ THAT MAKES THEM READ AS DEAD under this project's export-liveness rule
//     ("a symbol is live iff referenced outside generated bindings.dart;
//     comment mentions do not count"). They are NOT dead. The resolution
//     mechanism is `package/lib/src/finalizers.dart`, and the family must be
//     EXCLUDED from any dead-export sweep. Declared here so a later prune does
//     not remove live symbols while behaving correctly.
//     (`zd_fin_invocations` is the exception: it IS called through `bindings`,
//     from the test tree, and is live by the ordinary rule.)
//
//   * NOT IDEMPOTENT, AND THAT IS SAFE BY CONSTRUCTION. The house rule puts
//     idempotence in Dart, not in the C entry; here the Dart guard is the
//     DETACH. `NativeFinalizer` fires at most once per attachment, a detached
//     attachment never fires, and every explicit release path on the Dart side
//     detaches before releasing — so the explicit path and the finalizer path
//     are mutually exclusive by construction rather than by a flag.
//
//   * THEY FREE A **DART**-ALLOCATED BLOCK, and that is sound on every target
//     this package ships. `package:ffi` 2.2.0 resolves `malloc`/`calloc`/`free`
//     to libc on POSIX (`allocation.dart`: `@Native(symbol: 'malloc' |
//     'calloc' | 'free')`, verified at source) — the same libc this shim links
//     — so a C `free()` here releases exactly what Dart's `calloc.allocate`
//     claimed, on Linux x86_64 and on Android.
//     ⚠️ **n/a on Windows, stated rather than left to be rediscovered:** the
//     same package routes Windows through `CoTaskMemAlloc`/`CoTaskMemFree`, and
//     these entries would be wrong there. Windows is not a shipped target of
//     this package (no preset, no prebuilt, no CI leg). If one is ever added,
//     every entry in this family needs revisiting FIRST.
//
//     This is the *documented move* the FFI ownership rule allows: attaching
//     the finalizer IS the ownership transfer, and every explicit release path
//     detaches, so the block has exactly one owner at every instant.
//
// THE KIND CODES BELOW ARE UPPERCASE MACROS ON PURPOSE. ffigen's `zd_.*`
// filter is lowercase-only and case-sensitive, so they are NOT emitted to
// bindings.dart and the Dart side mirrors them — the same idiom
// ZD_FEATURE_UNSTABLE_API already uses above. That keeps the generated-binding
// delta for this seed to exactly the function declarations.
#define ZD_FIN_KIND_FREE_BLOCK 0
#define ZD_FIN_KIND_CONFIG 1
#define ZD_FIN_KIND_KEYEXPR 2
#define ZD_FIN_KIND_BYTES 3
#define ZD_FIN_KIND_BYTES_WRITER 4
#define ZD_FIN_KIND_SERIALIZER 5
#define ZD_FIN_KIND_PUBLISHER 6
#define ZD_FIN_KIND_ADVANCED_PUBLISHER 7
#define ZD_FIN_KIND_SHM_MUT 8
#define ZD_FIN_KIND_SHM_PROVIDER 9
/// `ShmProvider` collected while an async request had been started, so its
/// net was the DEFERRING entry rather than the dropping one.
///
/// ⛔ A SEPARATE KIND ON PURPOSE. Without it, a cell asserting that the net
/// fired on a provider with a request outstanding reads 0 on the kind it knows
/// about and cannot tell "the deferring entry ran" from "nothing ran at all" --
/// which is exactly the vacuous green this net exists to be provable against.
#define ZD_FIN_KIND_SHM_PROVIDER_DEFERRED 10
#define ZD_FIN_KIND_COUNT 11

/// Frees a block with no canon handle in it. The slot-only shape.
///
/// Used where the Dart wrapper's whole release is a `calloc.free` — today
/// `ZDeserializer` — and as the RE-ATTACHED shape for a wrapper whose canon
/// handle has moved out from under it (a consumed `ShmMutBuffer`, a
/// `KeyExpr` view's string block).
///
/// See the family contract above: callback-only, not idempotent, frees a
/// Dart-allocated block.
FFI_PLUGIN_EXPORT void zd_fin_free_block(void* token);

/// Returns how many times the entry for @p kind has fired in this process.
///
/// ⚠️ **A TEST INSTRUMENT, and the only member of this family Dart calls
/// directly.** It exists because a leak is invisible to a behavioural
/// assertion: dispose-after-consume, double-dispose and accessor-guard cells
/// all pass identically on leaking and on fixed code. This counter plus
/// allocation pressure is what makes a release-path cell a RESOURCE
/// measurement, with a both-ways injected calibration
/// (attach-without-detach → 2 · detach-before-drop → 1 · no-attach → 0).
///
/// ⚠️ **PER ENTRY, NOT GLOBAL, AND THAT IS LOAD-BEARING.** A single counter
/// cannot say WHICH entry fired, so a wrong implementation — an owned
/// `KeyExpr` left on the free-only shape (canon's keyexpr leaked), an
/// escaped-pointer `ShmMutBuffer` left on the drop+free shape (a
/// use-after-free) — would read 1 on the same counter and the cell would go
/// green on the exact hazard it exists for.
///
/// @param kind  One of the ZD_FIN_KIND_* codes above. Out-of-range returns 0:
///              the domain is a fixed header-declared enumeration and the Dart
///              mirror validates before calling, so this arm is unreachable by
///              construction — the same "the Dart guard is the guard" shape
///              the family contract describes. No failure code is introduced.
/// @return The count, monotonically non-decreasing, never reset.
FFI_PLUGIN_EXPORT int zd_fin_invocations(int kind);

// Wire values for zd_fin_last_on_main(). Uppercase macros for the same reason
// as the kind codes: ffigen does not emit them, and the Dart side mirrors
// them. Declared as an explicit enumerated domain rather than a bare bool
// because 0 must mean "nothing observed", NOT "observed, and not the main
// thread" -- those are different facts and a zero-initialised flag conflates
// them. (CONV-1: an enumerated value crossing the seam declares its wire
// values in the header and mirrors them in Dart.)
#define ZD_FIN_ON_MAIN_UNOBSERVED 0
#define ZD_FIN_ON_MAIN_NO 1
#define ZD_FIN_ON_MAIN_YES 2

/// Reports whether the LAST firing of @p kind ran on the thread that called
/// zd_init_dart_api_dl -- i.e. the Dart mutator.
///
/// ⚠️ **A TEST INSTRUMENT, and it exists because a freeze and a mutator stall
/// read identically on a stopwatch.** The SDK documents a `NativeFinalizer`
/// callback as running "on an arbitrary thread, with no current isolate", and
/// a hypothesis phrased "on the finalizer thread ... freezes the isolate
/// group" is asserting something a timing measurement alone cannot establish:
/// a blocking release reached from the MUTATOR blocks that mutator inside GC
/// instead, which is a different failure with the same observable. So every
/// finalizer-timing and criterion-(ii) result in this seed records the thread
/// beside it.
///
/// The reference thread is the one that initialised the Dart API DL, captured
/// there rather than assumed: this shim is loaded eagerly on the main thread by
/// `native_lib.dart`, so that call site IS the mutator.
///
/// @param kind  One of the ZD_FIN_KIND_* codes. Out of range returns
///              ZD_FIN_ON_MAIN_UNOBSERVED, for the same
///              unreachable-by-construction reason as zd_fin_invocations.
/// @return One of the ZD_FIN_ON_MAIN_* values above.
FFI_PLUGIN_EXPORT int zd_fin_last_on_main(int kind);

/// `Config`'s net: `zd_config_drop` then `free(token)`.
///
/// ⚠️ The hot detach of this family. `Config.markConsumed()` FREES the Dart
/// block rather than moving ownership, so a missed detach on that path is a
/// double free of a block on the session-open path — and its ordering is a
/// pinned regression guard (PR #47, "a use-after-free on a 2008-byte block").
/// See the family contract above.
FFI_PLUGIN_EXPORT void zd_fin_config(void* token);

/// `ZBytes`'s net: `zd_bytes_drop` then `free(token)`.
///
/// ⚠️ The per-message class. `ZBytes` is constructed once per message on the
/// clone-in-loop throughput and ping paths, so this is the entry whose cost is
/// priced rather than assumed (seed criterion A9b). Its `markConsumed()` frees
/// the Dart block on the send path exactly as `Config`'s does, with the same
/// double-free consequence for a missed detach. See the family contract above.
FFI_PLUGIN_EXPORT void zd_fin_bytes(void* token);

/// `KeyExpr`'s net, OWNED backing only: `zd_keyexpr_drop` then `free(token)`.
///
/// ⚠️ A VIEW-backed key expression does NOT use this entry. A view owns
/// nothing — it borrows the caller's bytes — so there is no canon handle to
/// drop, and it carries TWO `zd_fin_free_block` attachments instead (its
/// `calloc`'d view slot and its `malloc`'d string), under one detach key.
/// Routing an owned backing onto the free-only shape would leak canon's
/// keyexpr silently; routing a view onto this one would drop a handle that was
/// never owned. That is why the two counters are read separately in the cells.
FFI_PLUGIN_EXPORT void zd_fin_keyexpr(void* token);

/// `ZBytesWriter`'s net: `zd_bytes_writer_drop` then `free(token)`.
///
/// ⚠️ `finish()` is a RELEASE path, not just a state change: it moves the
/// handle into canon and frees the slot. It detaches for the same reason
/// `markConsumed()` does. See the family contract above.
FFI_PLUGIN_EXPORT void zd_fin_bytes_writer(void* token);

/// `ZSerializer`'s net: `zd_serializer_drop` then `free(token)`.
///
/// Same three-state shape as `zd_fin_bytes_writer` above.
FFI_PLUGIN_EXPORT void zd_fin_serializer(void* token);

/// `Publisher`'s net: `zd_publisher_drop` then `free(token)`.
///
/// ⚠️ **Reached only from the matching-listener-OFF configuration.** A
/// publisher declared with `enableMatchingListener: true` holds a
/// `ReceivePort`, its drop callback can post, and a post from a finalizer
/// callback is documented undefined behaviour -- so that configuration is
/// deliberately left out of the net and keeps today's leak-on-forget. The
/// MARKER is on the class either way; only the NET is conditional.
FFI_PLUGIN_EXPORT void zd_fin_publisher(void* token);

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_config_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_config_sizeof(void);

/// Creates a default configuration.
///
/// @param config  Pointer to an uninitialized z_owned_config_t.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_default(z_owned_config_t* config);

/// Inserts a JSON5 value into the configuration at the given key path.
///
/// Takes a mutable owned config pointer. Internally obtains a mutable loan
/// via z_config_loan_mut() before calling zc_config_insert_json5().
///
/// @param config   Pointer to a valid z_owned_config_t.
/// @param key      Configuration key path (e.g., "mode").
/// @param value    JSON5 value string (e.g., "\"peer\"").
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_insert_json5(
    z_owned_config_t* config, const char* key, const char* value,
    uint8_t* err_buf, int err_cap, int* err_len);

/// Creates a configuration from a JSON5 string.
///
/// Wraps zc_config_from_str(). Detail-carrying: on failure canon's own
/// explanation of THIS call is written into the caller's err_buf, so an
/// enriched ZenohException can surface it. See the err_buf/err_cap/err_len
/// contract above.
///
/// @param config   Pointer to an uninitialized z_owned_config_t.
/// @param s        JSON5 configuration string.
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_from_str(
    z_owned_config_t* config, const char* s,
    uint8_t* err_buf, int err_cap, int* err_len);

/// Creates a configuration from a JSON5 file at the given path.
///
/// Wraps zc_config_from_file(). Detail-carrying: on failure canon's own
/// explanation of THIS call is written into the caller's err_buf, so an
/// enriched ZenohException can surface it. See the err_buf/err_cap/err_len
/// contract above.
///
/// @param config   Pointer to an uninitialized z_owned_config_t.
/// @param path     Path to a JSON5 configuration file.
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_from_file(
    z_owned_config_t* config, const char* path,
    uint8_t* err_buf, int err_cap, int* err_len);

/// Creates a configuration from the ZENOH_CONFIG environment variable.
///
/// Wraps zc_config_from_env(). Detail-carrying: on failure canon's own
/// explanation of THIS call is written into the caller's err_buf, so an
/// enriched ZenohException can surface it. See the err_buf/err_cap/err_len
/// contract above.
///
/// @param config   Pointer to an uninitialized z_owned_config_t.
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_from_env(
    z_owned_config_t* config,
    uint8_t* err_buf, int err_cap, int* err_len);

/// Reads the JSON value at the given configuration key.
///
/// Loans the config internally and wraps zc_config_get_from_str(), filling the
/// caller-allocated z_owned_string_t. Detail-carrying: on failure canon's own
/// explanation of THIS call is written into the caller's err_buf, so an
/// enriched ZenohException can surface it. See the err_buf/err_cap/err_len
/// contract above.
///
/// @param config   Pointer to a valid z_owned_config_t.
/// @param key      Configuration key path.
/// @param out      Pointer to an uninitialized z_owned_string_t to fill.
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_get(const z_owned_config_t* config,
                                    const char* key, z_owned_string_t* out,
                                    uint8_t* err_buf, int err_cap,
                                    int* err_len);

/// Serializes the whole configuration to a JSON string.
///
/// Loans the config internally and wraps zc_config_to_string(), filling the
/// caller-allocated z_owned_string_t. The rc is checked (canon/cpp leaves it
/// unchecked).
///
/// ⛔ NOT detail-carrying, deliberately. It was wired to the deleted capture
/// and nothing ever read it. Promoting it to a detail-carrying entry would
/// widen the enrichment surface to a call whose input is the WHOLE RENDERED
/// CONFIG -- the value-echo hazard the enrichment fence exists to bound. Its
/// Dart site is Object.toString(), which by convention must not throw, so it
/// has no throw to enrich in the first place.
///
/// @param config  Pointer to a valid z_owned_config_t.
/// @param out     Pointer to an uninitialized z_owned_string_t to fill.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_to_string(const z_owned_config_t* config,
                                          z_owned_string_t* out);

/// Drops (frees) the configuration.
///
/// After this call the owned config is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param config  Pointer to a z_owned_config_t to drop.
FFI_PLUGIN_EXPORT void zd_config_drop(z_owned_config_t* config);

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_session_t in bytes.
///
/// RETAINED with no Dart caller, and this is the ground rather than an
/// oversight. The synchronous pair below -- zd_open_session / zd_close_session
/// -- operates on a CALLER-ALLOCATED slot, and this is the only function that
/// can size that slot. The RETAINED note on zd_close_session names a non-Dart
/// embedder or a direct-bindings test as its stated use; neither can call the
/// pair without this. Removing it would orphan the KEEP it sits beside.
///
/// (Corrected: this said "Used by Dart to allocate the correct amount of
/// native memory for opaque zenoh types." Dart stopped calling it when
/// Session.open moved to the async pair, which owns its block end to end, so
/// the sentence was false in the present tense -- and, being a statement of
/// purpose rather than of retention, it left the symbol reading as dead with
/// no reason beside it.)
FFI_PLUGIN_EXPORT size_t zd_session_sizeof(void);

/// Opens a Zenoh session with the given configuration.
///
/// @param session  Pointer to an uninitialized z_owned_session_t.
/// @param config   Pointer to a z_owned_config_t (consumed by z_open).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_open_session(z_owned_session_t* session,
                                      z_owned_config_t* config);

/// Obtains a const loaned reference to the session.
///
/// @param session  Pointer to a valid z_owned_session_t.
/// @return Const pointer to the loaned session.
FFI_PLUGIN_EXPORT const z_loaned_session_t* zd_session_loan(
    const z_owned_session_t* session);

/// Gracefully closes and drops the session.
///
/// Calls z_close for graceful shutdown, then z_session_drop to release
/// resources. After this call the owned session is in gravestone state.
///
/// RETAINED alongside zd_open_session_async / zd_session_close_drop, which the
/// Dart API now uses. This pair operates on a CALLER-allocated slot and frees
/// nothing; the async pair owns its block end to end. Both remain exported: the
/// synchronous pair is the direct, allocation-free entry a non-Dart embedder
/// or a direct-bindings test needs, and removing it would delete the only
/// non-offloaded path to z_open.
///
/// @param session  Pointer to a z_owned_session_t to close and drop.
FFI_PLUGIN_EXPORT void zd_close_session(z_owned_session_t* session);

/// Opens a session WITHOUT blocking the caller.
///
/// z_open blocks for a caller-controlled duration -- measured 505 ms against a
/// configured-but-unreachable endpoint and 3005 ms for a client-mode failure at
/// the pinned 1.8.0. This entry hands that blocking call to a shim-owned
/// detached thread and returns immediately; the outcome arrives as ONE post on
/// @p dart_port.
///
/// THE RETURN MEANS "DID IT START", NOT "DID IT SUCCEED":
///
///   0                    the worker started; EXACTLY ONE post will arrive
///   12  ZD_OPEN_EALLOC   a heap allocation failed; nothing started
///   13  ZD_OPEN_ETHREAD  pthread_create failed; nothing started
///
/// Non-zero means NO post is coming, so the caller must fail rather than wait
/// on a completion that can never arrive. Canon's own outcome -- including
/// every canon failure -- travels in the post, never in this return.
///
/// The codes sit in canon-free POSITIVE space. Canon's positive returns are 1
/// (Z_CHANNEL_DISCONNECTED) and 2 (Z_CHANNEL_NODATA); this shim already uses
/// 10 and 11 elsewhere. 10 is UNREACHABLE here -- it is the capacity-argument
/// rejection and this entry takes no capacity argument. 11 is DELIBERATELY NOT
/// REUSED: reply_channel_alloc_harness.dart:18 opens a session under the malloc
/// injector and asserts code == 11 from zd_get_channel, so reusing it here
/// would let a green report come from the wrong site.
///
/// POST SHAPE -- one array of three:
///   [0] kInt64  canon's z_open result: 0 on success, negative on failure
///   [1] kInt64  the session block's address on success, 0 on failure
///   [2] length-carried bytes, or null -- canon's failure detail, captured on
///       the worker immediately after the failing call. Never kString: that
///       truncates at an interior NUL.
///
/// On success the address in [1] is a SHIM-OWNED block; release it with
/// zd_session_close_drop and never with a caller-side free.
///
/// @param config     Config to consume, or NULL for canon defaults. Its
///                   content is taken before this returns, on every path.
/// @param dart_port  Native port the single completion post is sent to.
FFI_PLUGIN_EXPORT int zd_open_session_async(z_owned_config_t* config,
                                            int64_t dart_port);

/// Closes, drops and FREES a session block that zd_open_session_async
/// allocated.
///
/// Takes uint8_t* rather than z_owned_session_t* deliberately, and the
/// asymmetry with zd_close_session above is the point: that one takes a typed
/// pointer because DART allocates the slot. This block is SHIM-owned -- its
/// address crosses to Dart as a plain kInt64 and returns as an opaque block
/// pointer, exactly the shape zd_query_drop(uint8_t* query) already uses in
/// this header.
///
/// Allocator-side frees: the shim malloc'd it, so the shim frees it.
///
/// @param session  Address delivered in element [1] of a successful post.
FFI_PLUGIN_EXPORT void zd_session_close_drop(uint8_t* session);

/// Reports whether the session has been closed.
///
/// @param session  Const pointer to a loaned (live) session.
/// @return 1 if the session is closed, 0 if open.
FFI_PLUGIN_EXPORT int8_t zd_session_is_closed(
    const z_loaned_session_t* session);

// ---------------------------------------------------------------------------
// KeyExpr
// ---------------------------------------------------------------------------

/// Returns the size of z_view_keyexpr_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_view_keyexpr_sizeof(void);

/// Creates a view key expression from a buffer and an explicit byte length.
///
/// The buffer must remain valid for the lifetime of the view (the view
/// BORROWS it -- it does not copy). It need not be null-terminated: `len` is
/// authoritative. This is the length-carried entry, and it is the only one:
/// the key expression grammar forbids `//`, a leading or trailing `/`, and the
/// characters `?#$`, but it does NOT forbid an interior NUL, so a C-string
/// entry measuring with strlen would silently truncate a real domain value.
///
/// @param ke    Pointer to an uninitialized z_view_keyexpr_t. Written on
///              every path, including failure (canon writes a gravestone).
/// @param expr  Pointer to `len` bytes of UTF-8 key expression text.
/// @param len   Length of `expr` in bytes.
/// @return 0 on success, Z_EINVAL (-1) if the expression is invalid.
FFI_PLUGIN_EXPORT int zd_view_keyexpr_from_substr(z_view_keyexpr_t* ke,
                                                  const char* expr,
                                                  size_t len);

/// Obtains a const loaned reference to the key expression.
///
/// @param ke  Pointer to a valid z_view_keyexpr_t.
/// @return Const pointer to the loaned key expression.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_view_keyexpr_loan(
    const z_view_keyexpr_t* ke);

/// Converts a loaned key expression to a view string.
///
/// The output view string borrows from the key expression and must not
/// outlive it. Returns void -- always succeeds on a valid loaned keyexpr.
///
/// @param ke   Const pointer to a loaned key expression.
/// @param out  Pointer to an uninitialized z_view_string_t to receive the result.
FFI_PLUGIN_EXPORT void zd_keyexpr_as_view_string(
    const z_loaned_keyexpr_t* ke, z_view_string_t* out);

/// Returns true if the key expressions intersect (share at least one key).
///
/// Takes LOANED handles, so a view, an owned and a declared key expression
/// are all admissible operands. (The view and owned C types happen to share a
/// representation today, so a view-typed parameter would accept an owned
/// pointer and behave correctly -- by coincidence, not by contract. These
/// signatures do not rely on that.)
///
/// @param a  Const pointer to a loaned key expression.
/// @param b  Const pointer to a loaned key expression.
/// @return true if the key expressions intersect.
FFI_PLUGIN_EXPORT bool zd_keyexpr_intersects(const z_loaned_keyexpr_t* a,
                                             const z_loaned_keyexpr_t* b);

/// Returns true if key expression a includes b (every key in b is in a).
///
/// @param a  Const pointer to a loaned key expression.
/// @param b  Const pointer to a loaned key expression.
/// @return true if a includes b.
FFI_PLUGIN_EXPORT bool zd_keyexpr_includes(const z_loaned_keyexpr_t* a,
                                           const z_loaned_keyexpr_t* b);

/// Returns true if the key expressions are equal in zenoh semantics.
///
/// @param a  Const pointer to a loaned key expression.
/// @param b  Const pointer to a loaned key expression.
/// @return true if the key expressions are equal.
FFI_PLUGIN_EXPORT bool zd_keyexpr_equals(const z_loaned_keyexpr_t* a,
                                         const z_loaned_keyexpr_t* b);

/// Returns the size of z_owned_keyexpr_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_keyexpr_sizeof(void);

/// Obtains a const loaned reference to an OWNED key expression.
///
/// The owned and the view constructors produce different structs but loan to
/// the same `z_loaned_keyexpr_t`, which is why every operation downstream can
/// take one loaned parameter regardless of a key expression's origin.
///
/// @param ke  Pointer to a valid z_owned_keyexpr_t.
/// @return Const pointer to the loaned key expression.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_keyexpr_loan(
    const z_owned_keyexpr_t* ke);

/// Drops an owned key expression, releasing its native allocation.
///
/// This is the LOCAL release. It does not unregister a declared key
/// expression from its session -- see zd_undeclare_keyexpr for that. Safe on
/// a gravestone (canon's null-drop contract).
///
/// @param ke  Pointer to a z_owned_keyexpr_t. Left gravestoned.
FFI_PLUGIN_EXPORT void zd_keyexpr_drop(z_owned_keyexpr_t* ke);

/// Clones a key expression from a LOANED source into an owned handle.
///
/// ⚠️ This clones what the source HOLDS, which is not always the bytes. A
/// key expression built from an owned constructor holds its own storage and
/// clones independently -- but a `z_view_keyexpr_t` holds a BORROW of the
/// caller's buffer, and cloning it copies the borrow. Measured: clone a view
/// key expression, free the buffer it borrows, and the clone reads freed
/// memory. Use zd_keyexpr_from_substr to copy a view's bytes instead.
///
/// Returns void -- canon's clone cannot fail.
///
/// @param dst  Pointer to an uninitialized z_owned_keyexpr_t.
/// @param src  Const pointer to the loaned key expression to clone.
FFI_PLUGIN_EXPORT void zd_keyexpr_clone(z_owned_keyexpr_t* dst,
                                        const z_loaned_keyexpr_t* src);

/// Constructs an OWNED key expression by COPYING `expr[0..len)`.
///
/// Unlike zd_view_keyexpr_from_substr, the result borrows nothing: the buffer
/// may be freed as soon as this returns. Length-carried, so an interior NUL
/// is part of the copied expression rather than a terminator.
///
/// @param out   Pointer to an uninitialized z_owned_keyexpr_t. Written on
///              every path, gravestone included.
/// @param expr  Pointer to `len` bytes of UTF-8 key expression text.
/// @param len   Length of `expr` in bytes.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_keyexpr_from_substr(z_owned_keyexpr_t* out,
                                             const char* expr,
                                             size_t len);

/// Declares a key expression on the session, returning an owned handle.
///
/// Canon reduces the key expression to a numerical id in the session's
/// routing tables, which saves bandwidth when the expression is passed
/// between Zenoh entities. The input is LOANED, not consumed. The out-param
/// is written on EVERY path -- a gravestone on failure -- so a caller must
/// check the return code before wrapping it.
///
/// @param session       Const pointer to a loaned (live) session.
/// @param declared_out  Pointer to an uninitialized z_owned_keyexpr_t.
/// @param key_expr      Const pointer to the loaned key expression to declare.
/// @return 0 on success, Z_EGENERIC (-128) on failure.
FFI_PLUGIN_EXPORT int zd_declare_keyexpr(const z_loaned_session_t* session,
                                         z_owned_keyexpr_t* declared_out,
                                         const z_loaned_keyexpr_t* key_expr);

/// Undeclares a key expression from the session.
///
/// 🔴 The handle is CONSUMED on every return code, including errors: canon
/// takes the value out before it checks the gravestone and before it calls
/// the session. A caller must therefore mark its handle dead regardless of
/// what this returns. Undeclaring on a session other than the declaring one
/// fails with Z_EGENERIC and still consumes.
///
/// @param session   Const pointer to a loaned (live) session.
/// @param key_expr  Pointer to an owned z_owned_keyexpr_t. Left gravestoned;
///                  the caller still owns the storage and must free it.
/// @return 0 on success, Z_EINVAL (-1) on a gravestone input, Z_EGENERIC
///         (-128) for every other failure.
FFI_PLUGIN_EXPORT int zd_undeclare_keyexpr(const z_loaned_session_t* session,
                                           z_owned_keyexpr_t* key_expr);

/// Concatenates `right_start[0..right_len)` onto `left`, without a separator.
///
/// The right operand crosses as a pointer and a length, NOT as a C string, so
/// an interior NUL is carried. `right_start` must be a valid non-NULL pointer
/// even when `right_len` is 0: canon builds a Rust slice from it, and
/// slice::from_raw_parts(NULL, 0) is undefined behaviour.
///
/// Canon does NOT validate the LEFT operand -- concatenating onto a
/// gravestone silently yields the literal "dummy" followed by the right --
/// and it forbids joining an expression ending in `*` to one starting with
/// `*`. Every validation failure except invalid UTF-8 collapses to
/// Z_EGENERIC, with the reason only in canon's log.
///
/// @param out          Pointer to an uninitialized z_owned_keyexpr_t. Written
///                     on every path -- a gravestone on failure -- so the
///                     caller must check the return code before reading it.
/// @param left         Const pointer to the loaned left operand.
/// @param right_start  Pointer to `right_len` bytes. Never NULL.
/// @param right_len    Length of the right operand in bytes.
/// @return 0 on success, Z_EINVAL (-1) if the right operand is not valid
///         UTF-8, Z_EGENERIC (-128) for every other failure.
FFI_PLUGIN_EXPORT int zd_keyexpr_concat(z_owned_keyexpr_t* out,
                                        const z_loaned_keyexpr_t* left,
                                        const char* right_start,
                                        size_t right_len);

/// Joins two key expressions, inserting the `/` separator between them.
///
/// Canon inserts the separator, which is why this takes two whole key
/// expressions rather than a trailing byte range: the right operand must
/// itself be a valid key expression. Failures collapse to Z_EGENERIC.
///
/// @param out    Pointer to an uninitialized z_owned_keyexpr_t. Written on
///               every path, gravestone included.
/// @param left   Const pointer to the loaned left operand.
/// @param right  Const pointer to the loaned right operand.
/// @return 0 on success, Z_EGENERIC (-128) on failure.
FFI_PLUGIN_EXPORT int zd_keyexpr_join(z_owned_keyexpr_t* out,
                                      const z_loaned_keyexpr_t* left,
                                      const z_loaned_keyexpr_t* right);

/// Reports whether `expr[0..len)` is a key expression in CANON form.
///
/// Pure validation: the buffer is NEVER written, so a read-only or const
/// buffer is safe here (unlike zd_keyexpr_canonize).
///
/// 🔴 Canon has NO NULL guard on this entry -- it is the one family member
/// canon never NULL-tests -- so `expr` MUST be non-NULL even when `len` is 0.
/// Canon builds a Rust slice from the pointer, and
/// slice::from_raw_parts(NULL, 0) is undefined behaviour.
///
/// Length-carried, like every other key expression entry this shim binds: an
/// interior NUL is an ordinary chunk byte of the expression, not a
/// terminator.
///
/// @param expr  Pointer to `len` bytes of UTF-8 key expression text. Never
///              NULL, including at length 0.
/// @param len   Length of `expr` in bytes.
/// @return 0 if the expression is valid AND in canon form, Z_EINVAL (-1) if
///         it is invalid OR merely non-canon -- canon does not discriminate
///         the two, so a caller may collapse this to a bool without losing
///         information canon was carrying.
FFI_PLUGIN_EXPORT int zd_keyexpr_is_canon(const char* expr, size_t len);

/// Canonizes `buf[0..*len)` IN PLACE, writing the new length back to `*len`.
///
/// 🔴 `buf` MUST be writable heap memory the caller owns. Canon rewrites it
/// through a `&mut str`, so a string literal or any other read-only mapping
/// SEGFAULTs -- this is the entry the header's own read-only warning is about.
/// It must also be non-NULL, including at length 0.
///
/// `*len` is written on SUCCESS ONLY: on failure the caller's length is left
/// exactly as it was passed in.
///
/// ⚠️ The rewrite may PRESERVE the length as well as shorten it
/// (`demo/example/**/*` -> `demo/example/*/**`, 17 bytes either way), so
/// `*len` is the only truth about the result's extent -- a caller must never
/// assume the result is shorter, nor reuse the input length. Canon happens to
/// zero-fill the tail from the new length to the old, which is what makes its
/// own `strcmp`-based test pass even though this function writes no
/// terminator; that behaviour is undocumented upstream, so rely on
/// `[0..*len)` and nothing else.
///
/// @param buf  Writable, caller-owned, non-NULL buffer of `*len` bytes of
///             UTF-8 key expression text. Rewritten in place on success.
/// @param len  In: the byte length of `buf`. Out (success only): the byte
///             length of the canonized expression.
/// @return 0 on success, Z_EINVAL (-1) if the expression is invalid even
///         after canonization.
FFI_PLUGIN_EXPORT int zd_keyexpr_canonize(char* buf, size_t* len);

/// Constructs an OWNED key expression from `expr[0..*len)`, canonizing first.
///
/// This is the canonize-then-validate composition: a non-canon expression is
/// rewritten and then accepted; one that is still invalid after the rewrite
/// is rejected. There is no "was canonized" signal in the return value --
/// canon carries none, and this shim invents none.
///
/// COPIES BEFORE CANONIZING: `expr` is `const` and is never written, so a
/// read-only buffer is safe here -- unlike zd_keyexpr_canonize, which mutates
/// the caller's memory. `expr` must still be non-NULL, including at length 0.
/// (Canon's view-backed sibling `z_view_keyexpr_from_substr_autocanonize`
/// rewrites the caller's buffer in place and aliases it; it is deliberately
/// not bound -- same service, other backing.)
///
/// @param out   Pointer to an uninitialized z_owned_keyexpr_t. Written on
///              EVERY path -- a gravestone on failure -- so the caller must
///              check the return code before wrapping it.
/// @param expr  Pointer to `*len` bytes of UTF-8 key expression text. Never
///              NULL, never written.
/// @param len   In: the byte length of `expr`. Out (success only): the byte
///              length of the canonized expression, which may be shorter than
///              or equal to the input length -- never assume it shrank.
/// @return 0 on success, Z_EINVAL (-1) if the expression is invalid even
///         after canonization.
FFI_PLUGIN_EXPORT int zd_keyexpr_from_substr_autocanonize(
    z_owned_keyexpr_t* out, const char* expr, size_t* len);

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_bytes_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_bytes_sizeof(void);

/// Copies a buffer into owned bytes.
///
/// @param bytes  Pointer to an uninitialized z_owned_bytes_t.
/// @param data   Pointer to the buffer data.
/// @param len    Length of the buffer in bytes.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_copy_from_buf(z_owned_bytes_t* bytes,
                                             const uint8_t* data, size_t len);

/// Obtains a const loaned reference to the bytes.
///
/// @param bytes  Pointer to a valid z_owned_bytes_t.
/// @return Const pointer to the loaned bytes.
FFI_PLUGIN_EXPORT const z_loaned_bytes_t* zd_bytes_loan(
    const z_owned_bytes_t* bytes);

/// Returns the total number of bytes in the payload.
///
/// FULL-WIDTH: `size_t`, matching canon's `z_bytes_len`. It was `int32_t`,
/// which is a lossy narrowing of the contract's domain -- a payload in
/// [2^31, 2^32) came back negative and one at or above 2^32 came back
/// silently short. The callback receive legs were full-width all along; this
/// is the sync extractor catching up.
///
/// @param bytes  Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @return Total number of bytes.
FFI_PLUGIN_EXPORT size_t zd_bytes_len(const uint8_t* bytes);

/// Reads the content of owned bytes into a caller-provided buffer.
///
/// Uses z_bytes_reader to copy up to `capacity` bytes into `out`.
///
/// @param bytes     Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @param out       Pointer to a buffer to receive the data.
/// @param capacity  Maximum number of bytes to read (full-width `size_t`,
///                  matching zd_bytes_len's return).
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_bytes_to_buf(const uint8_t* bytes,
                                          uint8_t* out, size_t capacity);

/// Drops (frees) owned bytes.
///
/// After this call the owned bytes are in gravestone state.
/// A second drop is a safe no-op.
///
/// @param bytes  Pointer to a z_owned_bytes_t to drop.
FFI_PLUGIN_EXPORT void zd_bytes_drop(z_owned_bytes_t* bytes);

/// Clones owned bytes into a pre-allocated destination.
///
/// Loans the source, then calls z_bytes_clone() to produce an independent
/// copy that shares the underlying reference-counted data.
///
/// @param dst  Pointer to an uninitialized z_owned_bytes_t (cast to uint8_t*).
/// @param src  Pointer to a valid z_owned_bytes_t (cast to uint8_t*).
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_bytes_clone(uint8_t* dst, const uint8_t* src);

// ---------------------------------------------------------------------------
// Owned String
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_string_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_string_sizeof(void);

/// Obtains a const loaned reference to the owned string.
///
/// @param str  Pointer to a valid z_owned_string_t.
/// @return Const pointer to the loaned string.
FFI_PLUGIN_EXPORT const z_loaned_string_t* zd_string_loan(
    const z_owned_string_t* str);

/// Returns a pointer to the data of a loaned string.
///
/// The returned pointer is NOT guaranteed to be null-terminated.
///
/// @param str  Const pointer to a loaned string.
/// @return Pointer to the string data.
FFI_PLUGIN_EXPORT const char* zd_string_data(const z_loaned_string_t* str);

/// Returns the length of a loaned string (in bytes, NOT including any terminator).
///
/// @param str  Const pointer to a loaned string.
/// @return Length of the string data in bytes.
FFI_PLUGIN_EXPORT size_t zd_string_len(const z_loaned_string_t* str);

/// Drops (frees) an owned string.
///
/// After this call the owned string is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param str  Pointer to a z_owned_string_t to drop.
FFI_PLUGIN_EXPORT void zd_string_drop(z_owned_string_t* str);

// ---------------------------------------------------------------------------
// View String utilities
// ---------------------------------------------------------------------------

/// Returns the size of z_view_string_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_view_string_sizeof(void);

/// Returns a pointer to the data of a view string.
///
/// Internally loans the view string and calls z_string_data on the loaned ref.
/// The returned pointer is NOT guaranteed to be null-terminated.
///
/// @param str  Pointer to a valid z_view_string_t.
/// @return Pointer to the string data.
FFI_PLUGIN_EXPORT const char* zd_view_string_data(const z_view_string_t* str);

/// Returns the length of a view string (in bytes, NOT including any terminator).
///
/// Internally loans the view string and calls z_string_len on the loaned ref.
///
/// @param str  Pointer to a valid z_view_string_t.
/// @return Length of the string data in bytes.
FFI_PLUGIN_EXPORT size_t zd_view_string_len(const z_view_string_t* str);

// ---------------------------------------------------------------------------
// Put / Delete
// ---------------------------------------------------------------------------

/// Publishes data on the given key expression.
///
/// The payload and attachment are consumed (moved) by this call -- the
/// caller must not use the owned bytes after calling zd_put, regardless
/// of the return code (z_bytes_move gravestones them either way).
///
/// @param session     Const pointer to a loaned session.
/// @param keyexpr     Const pointer to a loaned key expression.
/// @param payload     Pointer to an owned bytes (consumed via z_bytes_move).
/// @param encoding    Optional MIME id bytes, LENGTH-CARRIED, or NULL for no
///                    encoding at all (canon's option field is left untouched).
///                    Never measured with strlen: the domain admits an interior
///                    NUL and canon carries one across the wire byte-exact.
/// @param encoding_len       Length of `encoding` in bytes.
/// @param encoding_schema    Optional schema bytes, LENGTH-CARRIED, on a channel
///                    INDEPENDENT of the MIME id. NULL means no schema (canon's
///                    setter is never called); non-NULL at length 0 means the
///                    PRESENT-BUT-EMPTY schema, a distinct third state canon
///                    renders as a bare trailing separator on a well-known id.
/// @param encoding_schema_len  Length of `encoding_schema` in bytes.
/// @param attachment  Optional owned bytes (consumed via z_bytes_move),
///                    or NULL for no attachment.
/// @param timestamp   Optional pointer to 24 raw z_timestamp_t bytes, or NULL
///                    for none. Borrowed (copied into aligned storage), not
///                    consumed -- the caller retains ownership.
/// @param congestion_control  Congestion control strategy, or -1 to leave
///                    canon's own default (DROP -- this is a push path).
/// @param priority    Priority 1..7, or -1 to leave canon's default (data=5).
/// @param is_express  1/0 to set express mode, or -1 to leave canon's
///                    default (false).
/// @param allowed_destination  z_locality_t 0..2, or -1 to leave canon's
///                    default (ANY).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_put(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    z_owned_bytes_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    z_owned_bytes_t* attachment,
    const uint8_t* timestamp,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination);

/// Deletes a resource on the given key expression.
///
/// @param session    Const pointer to a loaned session.
/// @param keyexpr    Const pointer to a loaned key expression.
/// @param timestamp  Optional pointer to 24 raw z_timestamp_t bytes, or NULL
///                   for none. Borrowed (copied into aligned storage), not
///                   consumed.
/// @param congestion_control  Congestion control strategy, or -1 to leave
///                   canon's own default (DROP -- this is a push path).
/// @param priority   Priority 1..7, or -1 to leave canon's default (data=5).
/// @param is_express 1/0 to set express mode, or -1 to leave canon's
///                   default (false).
/// @param allowed_destination  z_locality_t 0..2, or -1 to leave canon's
///                   default (ANY).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_delete(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    const uint8_t* timestamp,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination);

// ---------------------------------------------------------------------------
// Subscriber
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_subscriber_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_subscriber_sizeof(void);

/// Declares a subscriber on the given key expression.
///
/// Samples are posted to the Dart isolate via `Dart_PostCObject_DL` on
/// the given native port. Each sample is sent as a `Dart_CObject` array
/// of 9 elements: [keyexpr(Uint8List), payload(Uint8List), kind(int64),
/// attachment(null or Uint8List), encoding(string), timestamp(null or
/// Uint8List), priority(int64), congestion(int64), express(int64)].
///
/// The key expression is a `Uint8List`, not a string: it is length-carried
/// so an interior NUL survives the posting (the grammar permits one and canon
/// carries it byte-exact). Dart decodes it leniently for display.
///
/// @param session     Const pointer to a loaned session.
/// @param subscriber  Pointer to an uninitialized z_owned_subscriber_t.
/// @param keyexpr     Const pointer to a loaned key expression.
/// @param dart_port   The Dart native port to post samples to.
/// @return 0 on success, negative on failure.
/// @param allowed_origin  z_locality_t 0..2 restricting which peers' traffic
///                        this declaration accepts, or -1 to leave canon's
///                        default (ANY).
/// @param retain_payload  Non-zero makes every delivered sample carry an
///                        OWNED clone of its payload as message element 9,
///                        transferring that clone to Dart. Zero posts kNull
///                        there and allocates nothing.
///                        ⛔ OWNERSHIP: on the delivered path the clone belongs
///                        to Dart, which must release it; on a FAILED post the
///                        callback reclaims it, because the discarded message
///                        held the only reference.
FFI_PLUGIN_EXPORT int zd_declare_subscriber(
    const z_loaned_session_t* session,
    z_owned_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    int allowed_origin,
    int retain_payload);

/// Drops (undeclares and frees) a subscriber.
///
/// After this call the owned subscriber is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param subscriber  Pointer to a z_owned_subscriber_t to drop.
FFI_PLUGIN_EXPORT void zd_subscriber_drop(z_owned_subscriber_t* subscriber);

/// Declares a background subscriber on the given key expression.
///
/// Unlike a regular subscriber, a background subscriber has no handle --
/// it lives until the session is closed. Samples are posted to the Dart
/// native port. When the session closes and the background subscriber is
/// dropped internally by zenoh-c, a null sentinel is posted to signal
/// stream completion.
///
/// @param session   Const pointer to a loaned session.
/// @param key_expr  Const pointer to the loaned key expression. Already
///                  validated -- the Dart side constructs and validates it,
///                  so a declared key expression drives the declaration
///                  without a string round-trip.
/// @param dart_port The Dart native port to post samples to.
/// @return 0 on success, negative on failure.
/// @param allowed_origin  z_locality_t 0..2 restricting which peers' traffic
///                        this declaration accepts, or -1 to leave canon's
///                        default (ANY).
FFI_PLUGIN_EXPORT int8_t zd_declare_background_subscriber(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t dart_port,
    int allowed_origin,
    int retain_payload);

// ---------------------------------------------------------------------------
// Publisher
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_publisher_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_publisher_sizeof(void);

/// Declares a publisher on the given key expression.
///
/// @param session             Const pointer to a loaned session.
/// @param publisher           Pointer to an uninitialized z_owned_publisher_t.
/// @param keyexpr             Const pointer to a loaned key expression.
/// @param encoding            MIME type string for default encoding (NULL = default).
/// @param congestion_control  Congestion control strategy (-1 = default/DROP).
///                            Publisher is a PUSH path, so canon's default is
///                            CongestionControl::DEFAULT_PUSH = DROP -- not
///                            BLOCK, which is the request-path default.
/// @param priority            Message priority (-1 = default/data=5).
/// @param is_express          Express mode (-1 = default, 0 = false, 1 = true).
/// @param allowed_destination z_locality_t 0..2, or -1 to leave canon's
///                            default (ANY).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination);

/// Obtains a const loaned reference to the publisher.
FFI_PLUGIN_EXPORT const z_loaned_publisher_t* zd_publisher_loan(
    const z_owned_publisher_t* publisher);

/// Drops (undeclares and frees) a publisher.
FFI_PLUGIN_EXPORT void zd_publisher_drop(z_owned_publisher_t* publisher);

/// Publishes data through the publisher.
///
/// @param publisher   Const pointer to a loaned publisher.
/// @param payload     Pointer to owned bytes (consumed via z_bytes_move).
/// @param encoding    MIME type string for per-put encoding override (NULL = publisher default).
/// @param attachment  Pointer to owned bytes for attachment (consumed if non-NULL, NULL = no attachment).
/// @param timestamp   Optional pointer to 24 raw z_timestamp_t bytes, or NULL
///                    for none. Borrowed (copied into aligned storage), not
///                    consumed -- the caller retains ownership.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_put(
    const z_loaned_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    z_owned_bytes_t* attachment,
    const uint8_t* timestamp);

/// Sends a DELETE through the publisher.
///
/// @param publisher  Const pointer to a loaned publisher.
/// @param timestamp  Optional pointer to 24 raw z_timestamp_t bytes, or NULL
///                   for none. Borrowed (copied into aligned storage), not
///                   consumed.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_delete(
    const z_loaned_publisher_t* publisher,
    const uint8_t* timestamp);

/// Returns the key expression of a publisher.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_publisher_keyexpr(
    const z_loaned_publisher_t* publisher);

/// Declares a background matching listener on the publisher.
///
/// Matching status changes are posted to the Dart isolate via the given
/// native port as Int64 values (1 = matching, 0 = not matching).
///
/// @param publisher  Const pointer to a loaned publisher.
/// @param dart_port  The Dart native port to post matching status to.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_declare_background_matching_listener(
    const z_loaned_publisher_t* publisher,
    int64_t dart_port);

/// Gets the current matching status of a publisher.
///
/// @param publisher  Const pointer to a loaned publisher.
/// @param matching   Out parameter: filled with 0 (no match) or 1 (match).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_get_matching_status(
    const z_loaned_publisher_t* publisher,
    int* matching);

// ---------------------------------------------------------------------------
// Info (Session identity)
// ---------------------------------------------------------------------------

/// Returns the size of z_id_t in bytes (the raw ZID image, expected 16).
///
/// Lets Dart size ZID buffers from the generator-emitted layout instead of a
/// hardcoded literal, so a future zenoh-c layout change trips the Dart assert
/// rather than silently mis-sizing the buffer.
FFI_PLUGIN_EXPORT size_t zd_id_sizeof(void);

/// Copies the session's own ZID (16 bytes) into the provided buffer.
///
/// @param session  Const pointer to a loaned session.
/// @param out_id   Pointer to a 16-byte buffer to receive the ZID.
FFI_PLUGIN_EXPORT void zd_info_zid(const z_loaned_session_t* session,
                                   uint8_t* out_id);

/// Converts a 16-byte ZID to its string representation.
///
/// @param id   Pointer to a 16-byte ZID buffer.
/// @param out  Pointer to an uninitialized z_owned_string_t to receive the result.
FFI_PLUGIN_EXPORT void zd_id_to_string(const uint8_t* id,
                                       z_owned_string_t* out);

/// Collects the ZIDs of every connected router into a shim-owned buffer.
///
/// UNBOUNDED: canon's contract has no bound of any kind -- the callback fires
/// once for each ID -- so neither does this. The buffer grows by realloc
/// inside the collection closure.
///
/// @param session    Loaned session handle.
/// @param out_ids    Receives a shim-owned buffer of `*out_count * 16` bytes --
///                   each ZID is 16 bytes, in storage order. Set to NULL when
///                   the enumeration is empty or the call fails. The caller
///                   MUST release it with zd_zid_list_drop().
/// @param out_count  Receives the number of ZIDs -- **ids, not bytes**. 0 when
///                   the enumeration is empty or the call fails.
/// @return 0 success; 11 = a shim-side allocation failed; negative = canon's
///         own, passed through.
FFI_PLUGIN_EXPORT int zd_info_routers_zid(const z_loaned_session_t* session,
                                          uint8_t** out_ids,
                                          size_t* out_count);

/// Collects the ZIDs of every connected peer into a shim-owned buffer.
///
/// UNBOUNDED, exactly as zd_info_routers_zid above; the two differ only in
/// which canon enumerator they call.
///
/// @param session    Loaned session handle.
/// @param out_ids    Receives a shim-owned buffer of `*out_count * 16` bytes --
///                   each ZID is 16 bytes, in storage order. Set to NULL when
///                   the enumeration is empty or the call fails. The caller
///                   MUST release it with zd_zid_list_drop().
/// @param out_count  Receives the number of ZIDs -- **ids, not bytes**. 0 when
///                   the enumeration is empty or the call fails.
/// @return 0 success; 11 = a shim-side allocation failed; negative = canon's
///         own, passed through.
FFI_PLUGIN_EXPORT int zd_info_peers_zid(const z_loaned_session_t* session,
                                        uint8_t** out_ids, size_t* out_count);

/// Releases a buffer handed out by the two collectors.
///
/// `NULL` is a safe no-op. A second call on the same non-`NULL` pointer is a
/// **double free**: this entry is a raw free(), it holds no owned handle and so
/// has no gravestone to check. The house puts idempotence on the Dart side --
/// the same shape as zd_query_drop, whose caller guards with `Query._disposed`.
///
/// @param ids  A buffer received through a collector's `out_ids`, or NULL.
FFI_PLUGIN_EXPORT void zd_zid_list_drop(uint8_t* ids);

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

/// Returns the size of z_timestamp_t in bytes (the raw timestamp image,
/// expected 24).
///
/// Lets Dart size timestamp buffers from the generator-emitted layout instead
/// of a hardcoded literal, so a future zenoh-c layout change trips the Dart
/// assert rather than silently mis-sizing the buffer.
FFI_PLUGIN_EXPORT size_t zd_timestamp_sizeof(void);

/// Creates a uhlc timestamp from the session's HLC clock.
///
/// Writes the 24 raw bytes of the resulting z_timestamp_t into out_ts. The
/// caller MUST check the return code and never surface a garbage timestamp.
///
/// @param session  Const pointer to a loaned session.
/// @param out_ts   Pointer to a 24-byte buffer to receive the raw timestamp.
/// @return The zenoh result code (0 = success, negative = error).
FFI_PLUGIN_EXPORT int zd_timestamp_new(const z_loaned_session_t* session,
                                       uint8_t* out_ts);

/// Reads the NTP64 unsigned-64 time from a raw 24-byte timestamp.
///
/// @param ts  Pointer to a 24-byte raw z_timestamp_t image.
/// @return The NTP64 time as an unsigned 64-bit value.
FFI_PLUGIN_EXPORT uint64_t zd_timestamp_ntp64_time(const uint8_t* ts);

/// Reads the 16-byte ZenohId from a raw 24-byte timestamp.
///
/// @param ts      Pointer to a 24-byte raw z_timestamp_t image.
/// @param out_id  Pointer to a 16-byte buffer to receive the id.
FFI_PLUGIN_EXPORT void zd_timestamp_id(const uint8_t* ts, uint8_t* out_id);

// ---------------------------------------------------------------------------
// Scout
// ---------------------------------------------------------------------------

/// Scouts for zenoh entities on the network. Returns IMMEDIATELY.
///
/// The blocking z_scout runs on a detached worker thread owned by this shim,
/// so the calling (Dart isolate) thread is never blocked.
///
/// Each discovered hello is posted to the Dart native port as a
/// Dart_CObject array of 3 elements:
///   [0] TypedData(Uint8, 16 bytes) -- ZID
///   [1] Int64 -- whatami value
///   [2] Array of String -- one element per locator, each byte-exact
///
/// The null completion sentinel is posted from the hello closure's DROP
/// callback -- canon's designated release point -- and never from this
/// function's body.
///
/// @param config      Pointer to an owned config (consumed). NULL = default config.
///                    Its content is taken into worker-owned storage before
///                    this call returns, so the caller may free its block
///                    immediately afterwards.
/// @param dart_port   The Dart native port to post Hello messages to.
/// @param timeout_ms  Scouting timeout in milliseconds.
/// @param what        Bitmask of entity types to scout for (e.g., 3 = router+peer).
/// @return 0  the worker started; exactly one completion sentinel will arrive.
///         !0 nothing started, NO sentinel will ever be posted, and everything
///            this call took has been released. The caller must surface this as
///            an error rather than awaiting completion, or it will wait forever.
///            It no longer reports z_scout's own outcome, which is only reached
///            long after this returns.
FFI_PLUGIN_EXPORT int zd_scout(z_owned_config_t* config, int64_t dart_port,
                               uint64_t timeout_ms, int what);

// ---------------------------------------------------------------------------
// Queryable
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_queryable_t in bytes.
FFI_PLUGIN_EXPORT int32_t zd_queryable_sizeof(void);

/// Returns the size of z_owned_query_t in bytes.
FFI_PLUGIN_EXPORT int32_t zd_query_sizeof(void);

/// Declares a queryable on the given key expression.
///
/// Incoming queries are posted to the Dart isolate via the given native port.
/// The query's key expression rides the message as a length-carried
/// `Uint8List`, so an interior NUL survives; the selector `parameters` beside
/// it are still a C string.
///
/// @param queryable_out  Pointer to an uninitialized z_owned_queryable_t.
/// @param session        Const pointer to a loaned session (as uint8_t*).
/// @param key_expr       Const pointer to the loaned key expression, already
///                       validated Dart-side.
/// @param port           The Dart native port to post queries to.
/// @param complete       Whether this queryable is complete (1) or not (0).
/// @return 0 on success, negative on failure.
/// @param allowed_origin  z_locality_t 0..2 restricting which peers' traffic
///                        this declaration accepts, or -1 to leave canon's
///                        default (ANY).
FFI_PLUGIN_EXPORT int8_t zd_declare_queryable(
    uint8_t* queryable_out,
    const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t port,
    int8_t complete,
    int allowed_origin);

/// Declares a fire-and-forget background queryable.
///
/// No handle is returned; the queryable lives until the session is closed,
/// at which point its drop posts a null sentinel to the Dart port to signal
/// stream completion. Queries are posted to the Dart isolate via the port.
///
/// @param session   Const pointer to a loaned session (as uint8_t*).
/// @param key_expr  Const pointer to the loaned key expression, already
///                  validated Dart-side.
/// @param port      The Dart native port to post queries to.
/// @param complete  Whether the queryable is a complete data source (0/1).
/// @return 0 on success, negative on failure.
/// @param allowed_origin  z_locality_t 0..2 restricting which peers' traffic
///                        this declaration accepts, or -1 to leave canon's
///                        default (ANY).
FFI_PLUGIN_EXPORT int8_t zd_declare_background_queryable(
    const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t port,
    int8_t complete,
    int allowed_origin);

/// Drops (undeclares and frees) a queryable.
///
/// @param queryable  Pointer to a z_owned_queryable_t to drop.
FFI_PLUGIN_EXPORT void zd_queryable_drop(uint8_t* queryable);

// ---------------------------------------------------------------------------
// Query channels (bounded fifo/ring delivery on the queryable path)
// ---------------------------------------------------------------------------

/// Returns the size of the owned query handler for `kind`, in bytes.
FFI_PLUGIN_EXPORT int32_t zd_query_handler_sizeof(int32_t kind);

/// Drops an owned query handler, releasing any queries still buffered in it.
///
/// ⚠️ `kind` MUST match the kind the handler was constructed with.
///
/// This is also the answer to "who owns a query that was never recv'd": the
/// native channel does, and this drop releases it. There is deliberately no
/// Dart-side undelivered-set on this path — unlike the callback path, where a
/// query parsed off the port but never delivered would have no other owner.
FFI_PLUGIN_EXPORT void zd_query_handler_drop(uint8_t* handler, int32_t kind);

/// Declares a queryable whose queries land in a BOUNDED CHANNEL.
///
/// The channel-mode sibling of zd_declare_queryable. Both fill canon's
/// `z_queryable_options_t` through one shared body, so their option surfaces
/// cannot drift; they differ only in which closure canon receives.
///
/// Unlike a reply channel, this one lives until the queryable is undeclared or
/// its session closes — canon's own words for the recv contract — so releasing
/// the handle is REMOTE-VISIBLE.
///
/// @param queryable_out  Caller-allocated `zd_queryable_sizeof()` buffer.
/// @param handler_out    Caller-allocated `zd_query_handler_sizeof(kind)`
///                       buffer, written with the owned handler on success.
/// @param tee_out        Out-param for the SHIM-owned readiness-tee context,
///                       released through the shared `zd_pull_tee_drop`. NULL
///                       on every failure path.
/// @param dart_port      Dart NativePort the tee posts readiness pings to.
/// @param kind           0 = ring (lossy, drop-oldest), 1 = fifo (lossless,
///                       producer-backpressured).
/// @param capacity       Channel capacity, carried full width.
/// @return 0 on success.
///         **10** (`ZD_DECLARE_ECAPACITY`) — capacity outside canon's domain;
///           nothing was allocated.
///         **11** (`ZD_DECLARE_EALLOC`) — the readiness-tee context could not be
///           claimed.
///         negative — canon's own code, passed through unchanged.
FFI_PLUGIN_EXPORT int8_t zd_declare_queryable_channel(
    uint8_t* queryable_out, uint8_t* handler_out, uint8_t** tee_out,
    int64_t dart_port,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, int8_t complete, int allowed_origin);

/// Takes one query out of a bounded query channel, without waiting.
///
/// One shared extraction body serves both kinds; only the loan and the try_recv
/// call are kind-dispatched.
///
/// On `Z_OK` — and ONLY then — a per-query heap wrapper is claimed and its
/// address is written to `out_query`. That wrapper is released by the shipped
/// allocator-side `zd_query_drop`, reached through `Query.dispose()`, exactly as
/// on the callback path. Every failure inside this function releases it again
/// before returning, so the hand-over is a single point.
///
/// Empty is not absent on the payload, attachment and encoding: canon reports an
/// absent one as NULL, and a present-but-empty one comes back as a **non-NULL**
/// pointer at length 0. Discriminate on the pointer. The encoding is
/// LENGTH-CARRIED like the key expression and the parameters beside it: read
/// exactly `*out_encoding_len` bytes, never to the first NUL.
///
/// Every `out_*` pointer buffer is malloc'd HERE and freed by the CALLER.
///
/// @return 0   a query was taken.
///         1   `Z_CHANNEL_DISCONNECTED` — the producer is gone (undeclared, or
///             its session closed). Terminal and sticky.
///         2   `Z_CHANNEL_NODATA` — alive, buffer empty right now.
///         -1  a remote-length-driven allocation could not be satisfied;
///             everything already claimed has been released.
FFI_PLUGIN_EXPORT int8_t zd_query_channel_try_recv(
    const uint8_t* handler, int32_t kind,
    int64_t* out_query,
    uint8_t** out_keyexpr, size_t* out_keyexpr_len,
    uint8_t** out_parameters, size_t* out_parameters_len,
    uint8_t** out_payload, size_t* out_payload_len,
    uint8_t** out_attachment, size_t* out_attachment_len,
    char** out_encoding, size_t* out_encoding_len,
    int8_t* out_accepts_replies);


/// Performs a get query on the given selector.
///
/// Replies are posted to the Dart isolate via the given native port. An ok
/// reply's key expression rides the message as a length-carried `Uint8List`,
/// so an interior NUL survives.
///
/// @param session        Const pointer to a loaned session (as uint8_t*).
/// @param selector       Const pointer to the loaned selector key expression,
///                       already validated Dart-side. The `parameters` half of
///                       a selector is a separate argument.
/// @param port           The Dart native port to post replies to.
/// @param target         Query target (0=bestMatching, 1=all, 2=allComplete).
/// @param consolidation  Consolidation mode (-1=auto, 0=none, 1=monotonic, 2=latest).
/// @param payload        Pointer to z_owned_bytes_t (NULL = no payload).
///                       Consumed via z_bytes_move if non-NULL.
/// @param encoding       MIME type string (NULL = default).
/// @param timeout_ms     Timeout in milliseconds.
/// @param parameters     Additional query parameters, LENGTH-CARRIED rather
///                       than NUL-terminated: the selector's parameters
///                       segment is UTF-8 text whose domain includes an
///                       interior NUL, and canon's own `z_get` is this entry
///                       with `strlen` applied. NULL with `parameters_len` 0
///                       is canon's "no parameters" spelling.
/// @param parameters_len Byte length of `parameters`. Must be 0 when
///                       `parameters` is NULL (canon refuses NULL-with-length).
/// @param attachment     Pointer to z_owned_bytes_t (NULL = no attachment).
///                       Consumed via z_bytes_move if non-NULL.
/// @param congestion_control  Congestion control strategy, or -1 to leave
///                       canon's own default. NOTE: get is a REQUEST path, so
///                       canon's default here is CongestionControl::
///                       DEFAULT_REQUEST = BLOCK -- not DROP, which is the
///                       push-path default used by put/delete/publisher.
/// @param priority       Priority 1..7, or -1 to leave canon's default (data=5).
/// @param is_express     1/0 to set express mode, or -1 to leave canon's
///                       default (false).
/// @param allowed_destination  z_locality_t 0..2, or -1 to leave canon's
///                       default (ANY).
/// @param accept_replies z_reply_keyexpr_t 0..1, or -1 to leave canon's
///                       default (MATCHING_QUERY = 1).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_get(
    const uint8_t* session,
    const z_loaned_keyexpr_t* selector,
    int64_t port,
    int8_t target,
    int8_t consolidation,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint64_t timeout_ms,
    const char* parameters,
    size_t parameters_len,
    uint8_t* attachment,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination,
    int accept_replies,
    int retain_payload);

/// Sends a reply to a query.
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param key_expr     Null-terminated key expression string.
/// @param payload      Pointer to z_owned_bytes_t (consumed via z_bytes_move).
/// @param encoding     MIME type string (NULL = default).
/// @param attachment   Pointer to z_owned_bytes_t (NULL = no attachment).
///                     Consumed via z_bytes_move if non-NULL.
/// @param timestamp    Pointer to the raw 24-byte z_timestamp_t image
///                     (NULL = no timestamp). BORROWED, not consumed: the
///                     bytes are memcpy'd into 8-byte-aligned stack storage
///                     and opts.timestamp points at it for the call.
/// @param is_express   1/0 to set express mode, or -1 to leave canon's
///                     default (false). is_express is the ONLY live QoS field
///                     on the reply path: canon deprecates and ignores
///                     congestion_control and priority here, and the C++ peer
///                     does not copy them, so neither is bound.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_query_reply(
    const uint8_t* query,
    const z_loaned_keyexpr_t* key_expr,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment,
    const uint8_t* timestamp,
    int8_t is_express);

/// Sends a DELETE-kind reply to a query.
///
/// Mirrors z_query_reply_del: a DELETE-kind reply carries NO payload and NO
/// encoding, but may carry an attachment and a timestamp.
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param key_expr     Null-terminated key expression string. BORROWED (a
///                     z_view_keyexpr over the string) -- not consumed.
/// @param attachment   Pointer to z_owned_bytes_t (NULL = no attachment).
///                     Consumed via z_bytes_move if non-NULL.
/// @param timestamp    Pointer to the raw 24-byte z_timestamp_t image
///                     (NULL = no timestamp). BORROWED, not consumed: the
///                     bytes are memcpy'd into 8-byte-aligned stack storage
///                     and opts.timestamp points at it for the call.
/// @param is_express   1/0 to set express mode, or -1 to leave canon's
///                     default (false). Same deprecation as zd_query_reply:
///                     congestion_control and priority are not bound.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_query_reply_del(
    const uint8_t* query,
    const z_loaned_keyexpr_t* key_expr,
    uint8_t* attachment,
    const uint8_t* timestamp,
    int8_t is_express);

/// Sends an error reply to a query.
///
/// Mirrors z_query_reply_err: error replies carry a payload + encoding only.
/// There is NO key expression and NO attachment (unanimous oracle carve-out:
/// z_query_reply_err_options_t exposes only `encoding`).
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param payload      Pointer to z_owned_bytes_t (consumed via z_bytes_move).
/// @param encoding     MIME type string (NULL = default).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_query_reply_err(
    const uint8_t* query,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len);

/// Drops (frees) an owned query.
///
/// @param query  Pointer to a z_owned_query_t to drop.
FFI_PLUGIN_EXPORT void zd_query_drop(uint8_t* query);

/// Copies the payload of a query into a caller-provided buffer.
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param payload_out  Pointer to a buffer to receive the payload.
/// @param max_len      Maximum number of bytes to copy.
/// @return Number of bytes copied, or negative on failure.
FFI_PLUGIN_EXPORT int32_t zd_query_payload(
    const uint8_t* query,
    uint8_t* payload_out,
    int32_t max_len);

/// Clones a received query's payload into a caller-supplied owned slot.
///
/// @param query        Pointer to the owned query handle Dart holds.
/// @param dst          Caller-supplied slot of `zd_bytes_sizeof()` bytes,
///                     filled with an owned `z_owned_bytes_t` when a payload
///                     is present. Untouched when absent.
/// @param has_payload  Out-param: 1 when a payload was present and `dst` was
///                     filled, 0 when the query carried none.
///
/// No return code, and that is a result rather than an omission: `z_bytes_clone`
/// returns `void` and cannot fail, and the slot is Dart-allocated, so there is
/// nothing to report. Presence rides the out-param instead. Codes 1 and 2 stay
/// reserved repo-wide for canon's channel states and 10-13 stay taken.
///
/// ⛔ OWNERSHIP: a present payload's clone belongs to Dart, which must release
/// it, and it OUTLIVES the query — `zd_query_drop` does not invalidate it.
FFI_PLUGIN_EXPORT void zd_query_payload_clone(
    const uint8_t* query,
    uint8_t* dst,
    int32_t* has_payload);

// ---------------------------------------------------------------------------
// Shared Memory (SHM)
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)

/// Returns the size of z_owned_shm_provider_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_sizeof(void);

/// Creates a default SHM provider with the given total size.
///
/// Wraps z_shm_provider_default_new(). Detail-carrying: on failure canon's
/// own explanation of THIS call is written into the caller's err_buf, so an
/// enriched ZenohException can surface it. See the err_buf/err_cap/err_len
/// contract above.
///
/// ⭐ WHY THIS ENTRY CARRIES DETAIL. Canon returns Z_EINVAL for every
/// rejection class it has here -- a pool too small to back the Talc
/// allocator, a pool the host's locked-memory budget cannot satisfy, and a
/// pool whose element count a 32-bit ElemIndex cannot address. Three rules,
/// one code. Canon separates them in zc_get_last_error's text and nowhere
/// else, so without this triple a caller cannot be told which rule they broke.
///
/// ⚠️ NO REDACTION IS APPLIED, and the text is canon's verbatim: the
/// over-budget message carries an absolute path into canon's own sources.
/// The pool size is the caller's own number, so nothing of the caller's
/// crosses back that they did not already have -- which is why this widening
/// does not reopen the config-echo question the contract above records.
///
/// @param provider    Pointer to an uninitialized z_owned_shm_provider_t.
/// @param total_size  Total size of the SHM pool in bytes.
/// @param err_buf  Caller storage for this call's detail; NULL to decline.
/// @param err_cap  Capacity of err_buf in bytes.
/// @param err_len  Out: bytes written to err_buf; always set, 0 when none.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_shm_provider_new(z_owned_shm_provider_t* provider,
                                          size_t total_size,
                                          uint8_t* err_buf, int err_cap,
                                          int* err_len);

/// Obtains a const loaned reference to the SHM provider.
FFI_PLUGIN_EXPORT const z_loaned_shm_provider_t* zd_shm_provider_loan(
    const z_owned_shm_provider_t* provider);

/// Drops (frees) the SHM provider.
FFI_PLUGIN_EXPORT void zd_shm_provider_drop(z_owned_shm_provider_t* provider);

/// `ShmProvider`'s net: `zd_shm_provider_drop` then `free(token)`.
///
/// ⛔ **SHM-guarded, so ABSENT from the `stable` native and from every Android
/// build.** The Dart side resolves it lazily, at first attach, from a path
/// already behind `requireShm()`.
///
/// ⚠️ **Releasing a provider does NOT invalidate its children**, which is what
/// makes this admissible at all: the segment is refcounted by the chunks, so a
/// live `ShmMutBuffer`, a `toBytes()` payload and a `putBytes` all keep working
/// after the provider is dropped. Measured, both at planning and as a cell.
FFI_PLUGIN_EXPORT void zd_fin_shm_provider(void* token);

/// `ShmMutBuffer`'s net, FRESH state only: `zd_shm_mut_drop` then `free`.
///
/// ⛔ **A buffer whose `data` pointer has ESCAPED does NOT use this entry**, and
/// a consumed one does not either. Both move to `zd_fin_free_block`, which
/// reclaims the Dart slot and leaves the chunk alone.
///
/// The reason is the difference between a leak and a use-after-free. Once a
/// caller holds the raw `data` pointer, freeing the chunk under it would turn
/// today's leak-on-forget into a UAF — strictly worse. So the escape DOWNGRADES
/// the net rather than arming it: the chunk keeps exactly today's behaviour and
/// the wrapper's own slot is still reclaimed. **The severity never increases.**
///
/// ⚠️ SHM-guarded, absent from `stable` and from Android, resolved lazily from
/// a path already behind `requireShm()`.
FFI_PLUGIN_EXPORT void zd_fin_shm_mut(void* token);

/// Returns the size of z_owned_shm_mut_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_sizeof(void);

/// Canon's tagged allocation result, flattened for the FFI seam.
///
/// Canon reports every allocation through `z_buf_layout_alloc_result_t`, a
/// four-slot tagged union: a status, the buffer, and one error enum per
/// failure class. The buffer travels out through its own `buf` out-param (Dart
/// already owns a `z_owned_shm_mut_t` slot for it), so this struct carries the
/// three discriminating scalars.
///
/// ⚠️ **FIELD VALIDITY IS STATUS-GATED, and the gating is done HERE, not by
/// the caller.** Canon backfills the error field its status did NOT select
/// with an arbitrary member -- on an OK result it writes `alloc_error = OTHER`
/// and `layout_error = PROVIDER_INCOMPATIBLE_LAYOUT`, which are real enum
/// members meaning nothing. That placeholder garbage never crosses this seam:
/// the shim writes canon's raw value into the one field `status` selects and
/// writes **-1** into the other. -1 is outside both canon domains, so a caller
/// that reads the wrong field gets an obviously-invalid value rather than a
/// plausible one.
typedef struct zd_shm_alloc_result_t {
  /// Canon's `zc_buf_layout_alloc_status_t`, verbatim: 0 OK, 1 ALLOC_ERROR,
  /// 2 LAYOUT_ERROR. **Only canon's own values ever appear here** -- the
  /// shim's own signal lives in the return code, never in this field -- so a
  /// value outside {0,1,2} means canon's contract changed, and the Dart decode
  /// seam treats it as a contract violation.
  int8_t status;
  /// Canon's `z_alloc_error_t` (0 NEED_DEFRAGMENT, 1 OUT_OF_MEMORY, 2 OTHER)
  /// iff `status == 1`; otherwise **-1**.
  int8_t alloc_error;
  /// Canon's `z_layout_error_t` (0 INCORRECT_LAYOUT_ARGS,
  /// 1 PROVIDER_INCOMPATIBLE_LAYOUT) iff `status == 2`; otherwise **-1**.
  int8_t layout_error;
} zd_shm_alloc_result_t;

/// Allocates a mutable SHM buffer, dispatching over canon's ten sync entries.
///
/// One wrapper, not ten: canon's ten synchronous provider-allocation entries
/// differ only in WHICH symbol is called -- the result carriage, the
/// status branch, and the buffer move are identical in all ten. A shared body
/// makes the discriminant-dropping defect this replaced (an invented -1,
/// copy-pasted into two wrappers) structurally impossible to reintroduce in
/// one place and not the other.
///
/// **Canon entries reached** (`strategy` x `alignment_pow`), the G4.4 parity
/// checklist for this entry:
///
///   strategy 0 -> `z_shm_provider_alloc`                     / `..._aligned`
///   strategy 1 -> `z_shm_provider_alloc_gc`                  / `..._aligned`
///   strategy 2 -> `z_shm_provider_alloc_gc_defrag`           / `..._aligned`
///   strategy 3 -> `z_shm_provider_alloc_gc_defrag_dealloc`   / `..._aligned`
///   strategy 4 -> `z_shm_provider_alloc_gc_defrag_blocking`  / `..._aligned`
///
/// **What canon exposes here that this entry does not:** the two `_async`
/// siblings (`z_shm_provider_alloc_gc_defrag_async`, `..._aligned_async` --
/// the only two that return a `z_result_t`, and the only two carved from this
/// dispatch); the precomputed-layout family (`z_shm_provider_alloc_layout*`
/// and the `z_precomputed_layout_alloc*` entries, which out-param the 2-slot
/// `z_buf_alloc_result_t`); and the deprecated `z_alloc_layout_*` family.
/// Canon's own alignment struct carries exactly one field (`pow`), so nothing
/// of the alignment surface is dropped.
///
/// @param provider       Const pointer to a loaned SHM provider.
/// @param buf            Caller-allocated `zd_shm_mut_sizeof()` slot. Written
///                       with the owned buffer **iff** `out->status == 0`;
///                       left untouched on every other path, including rc 10.
///                       On a non-OK status canon's own `buf` slot is a null
///                       gravestone owning nothing, so there is nothing to
///                       drop and the caller's slot needs only to be freed.
/// @param size           Allocation size, carried full width. Domain: >= 0.
/// @param strategy       0 plain, 1 gc, 2 gc+defrag, 3 gc+defrag+dealloc,
///                       4 gc+defrag+blocking. Any other value is rejected.
/// @param alignment_pow  **-1** selects canon's unaligned entry; **0..255**
///                       selects the `_aligned` sibling with
///                       `z_alloc_alignment_t{.pow = alignment_pow}`. Canon's
///                       field is a `uint8_t`, so the domain is its full
///                       width; canon's unaligned entries implement themselves
///                       as pow 0, which is why -1 rather than 0 is the
///                       "unspecified" sentinel.
/// @param out            Caller-allocated result struct. Written **iff** the
///                       return code is 0; untouched on rc 10.
/// @return 0 -- a canon call ran; read `*out` for what it reported.
///         **10** -- the shim rejected an argument. **Nothing ran**: no canon
///           call was made, and `*out` and `*buf` are left exactly as the
///           caller left them. Rendered Dart-side as `ArgumentError`, the same
///           meaning code 10 carries on the declare-channel entries -- one
///           meaning per positive code, repo-wide, so a reader never has to
///           check the mapping per site. Unreachable from the public Dart API,
///           whose own guards reject all three triggers (`size`,
///           `alignment_pow`, `strategy`) before the call; it is a structural
///           backstop driven directly at the seam by its own test cell.
///
/// ⚠️ **The whole return-code space here is shim-owned, and that is safe by
/// construction rather than by convention:** canon's ten sync entries return
/// `void`. There is no canon code on this channel to collide with, in either
/// sign -- so nothing here needs to be "fixed" into the negative space later.
/// Canon's own outcomes travel in `*out`, where they keep canon's own values.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_alloc(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    int64_t size,
    int32_t strategy,
    int32_t alignment_pow,
    zd_shm_alloc_result_t* out);

/// Starts an ASYNCHRONOUS allocation and returns immediately.
///
/// Canon's `z_shm_provider_alloc_gc_defrag_async`. Its synchronous sibling
/// `..._blocking` waits inside the call, which in Dart parks the calling
/// ISOLATE with no await point, no timeout and no cancellation -- and on a
/// request the pool can never satisfy it never returns at all. This entry hands
/// the same request to canon's background machinery and returns; the outcome
/// arrives as ONE post on @p dart_port.
///
/// THE RETURN MEANS "DID IT START", NOT "DID IT SUCCEED":
///
///   0                     the request started; EXACTLY ONE post will arrive,
///                         IF canon ever completes it -- see the hazard below
///   10  ZD_SHM_EARG       an argument was rejected; NOTHING started
///   12  ZD_SHM_EALLOC     a heap allocation failed; NOTHING started
///
/// ⛔⛔ THE SYNC FAMILY'S JUSTIFICATION FOR OWNING THE WHOLE CODE SPACE DOES
/// NOT CARRY OVER HERE, and this is the sharp edge of this entry.
/// `zd_shm_provider_alloc` may own its entire return domain because canon's ten
/// synchronous entries return `void` -- there is no canon code on that channel
/// to collide with, in either sign. **This entry returns `z_result_t`, so canon
/// occupies the NEGATIVE channel.** Every shim-owned code here is therefore
/// POSITIVE, precisely so a shim code cannot masquerade as a canon one.
///
/// 10 keeps the meaning it carries everywhere in this shim. 12 keeps the
/// meaning it carries on the open channel. ⛔ **11 is DELIBERATELY NOT REUSED**:
/// `reply_channel_alloc_harness.dart` asserts `code == 11` from
/// `zd_get_channel` under the malloc injector, and reusing it here would let a
/// green report come from the wrong site.
///
/// ⚠️ MEASURED, and the shim is designed around it rather than hoping otherwise
/// (`development/research/probes-ci-shm-20260902/`):
///
///   * canon's own rc is **ZERO for every size in the domain, swept to
///     SIZE_MAX**, on the provider this binding constructs. A canon rejection
///     is unreachable here, so a non-zero return is always the shim's own --
///     minted BEFORE the context is handed over, which is what makes the
///     ownership question decidable.
///   * a REFUSAL arrives through the callback with rc 0. Canon's outcomes
///     travel in the result, exactly as they do for the sync ten; the return
///     code is not an outcome channel.
///   * ⛔ a request the pool cannot satisfy is ACCEPTED and then **nothing ever
///     fires** -- no result, and no context release either. That context and
///     its segment are leaked for the life of the process, and canon ships no
///     cancel entry. Not a hypothetical: even the NOMINAL pool size never
///     completes, because the pool carries its own overhead.
///   * ⛔ dropping the provider while a request is pending SEGFAULTS, 3/3,
///     against a clean control. Nothing in this entry protects against that;
///     making it unreachable is the deferred-drop work.
///
/// POST SHAPE -- one array of four int64:
///   [0] canon's status verbatim: 0 OK, 1 ALLOC_ERROR, 2 LAYOUT_ERROR
///   [1] canon's `z_alloc_error_t` iff status == 1, else -1
///   [2] canon's `z_layout_error_t` iff status == 2, else -1
///   [3] on status 0, a SHIM-OWNED handle to take the buffer with; else 0
///
/// ⚠️ Status 0 with handle 0 means the shim could not allocate a block to carry
/// the buffer and released the CHUNK rather than leaking it. Canon's OK arm
/// always carries a buffer, so the pair is unambiguous and needs no code.
///
/// @param provider   Const pointer to a loaned SHM provider.
/// @param size       Allocation size, carried full width. Domain: >= 0.
/// @param dart_port  Native port the single result is posted to.
/// @param out_box    Written with a handle to the shim's reference-counted
///                   box on a 0 return, and with 0 otherwise. The caller owns
///                   ONE reference to it and must release it exactly once,
///                   with `zd_shm_async_box_release`. That handle is what
///                   makes a DEFERRED provider drop possible.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_alloc_async(
    const z_loaned_shm_provider_t* provider,
    int64_t size,
    int64_t dart_port,
    int64_t* out_box);

/// Hands the provider slot to the shim, to be dropped when canon is finished.
///
/// ⛔ WHY THIS EXISTS: dropping a provider while canon still holds a request
/// against it FAULTS on a zenoh thread -- measured 3/3 against a clean control
/// performing the identical drop on the identical state with no request
/// started. The drop returns first and the fault lands afterwards, so it
/// cannot be relied on to surface in testing.
///
/// ⚠️ **OWNERSHIP MOVES on a 1 return.** The shim then drops the provider AND
/// frees the slot block, because the caller cannot know when that becomes
/// safe. On a 0 return nothing moved and the caller proceeds as usual.
///
/// @return 1  taken; do NOT drop and do NOT free the slot
///         0  ONLY when an argument was null. Nothing was taken.
///
/// ⚠️ **CORRECTED 2026-09-03 at the merge gate.** This arm was documented as
/// *"canon already finished; drop and free as usual"*, describing a gate on
/// `completed` that the implementation does not have. The slot is taken
/// **unconditionally**, because the hand-over happens when a request STARTS
/// and canon can satisfy a small request from a fresh pool INSIDE the call
/// that starts it — a gate there refuses the slot and nothing ever drops the
/// provider. A caller must therefore treat a 1 as the normal answer and 0 as
/// a programming error, not as a live "canon got there first" branch.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_defer_drop(
    int64_t box_handle,
    z_owned_shm_provider_t* provider);

/// Takes the provider slot back out of a box without dropping it.
///
/// Used when a second request replaces the first: the slot must move to the
/// new box, or releasing the old one would drop a live provider.
///
/// @return 1 if the slot was taken back, 0 if the box did not hold it.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_undefer_drop(int64_t box_handle);

/// `ShmProvider`'s net once an async request has been started: releases the
/// box rather than dropping the provider.
///
/// ⛔ The ordinary `zd_fin_shm_provider` drops directly, and that faults while
/// canon holds a request -- measured through the finalizer itself, 3/3, on an
/// exhausted pool. This entry defers instead; the provider is dropped by
/// whoever releases the last reference.
FFI_PLUGIN_EXPORT void zd_fin_shm_provider_deferred(void* token);

/// Releases the caller's reference to an async request's box.
///
/// Exactly once per handle returned by `zd_shm_provider_alloc_async`. The
/// deferred provider drop, if one was handed over, happens when the LAST
/// reference goes -- whichever party releases it.
FFI_PLUGIN_EXPORT void zd_shm_async_box_release(int64_t box_handle);

/// Takes the buffer a completed async allocation posted.
///
/// Moves the content of the shim-owned block named by @p buf_handle into the
/// caller's @p out slot and releases the shim's block. Call it EXACTLY ONCE per
/// posted non-zero handle: the handle is dead afterwards.
///
/// ⚠️ The buffer is moved out of canon's result INSIDE the result callback,
/// not here, because canon may free its context before Dart reads the post.
/// This entry only completes the hand-off.
FFI_PLUGIN_EXPORT void zd_shm_async_take(int64_t buf_handle,
                                         z_owned_shm_mut_t* out);

/// Performs manual memory defragmentation on the provider.
///
/// Straight pass-through of `z_shm_provider_defragment`, whose own words are:
/// *"Perform memory defragmentation. The real operations taken depend on the
/// provider's backend allocator implementation."*
///
/// @param provider  Const pointer to a loaned SHM provider.
/// @return Canon's `size_t`, verbatim. **Canon documents no meaning for it**
///         -- not bytes reclaimed, not a count -- so it is carried rather than
///         interpreted, and no caller should assert a magnitude.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_defragment(
    const z_loaned_shm_provider_t* provider);

/// Performs manual garbage collection on the provider.
///
/// Straight pass-through of `z_shm_provider_garbage_collect`, whose own words
/// are: *"Perform memory garbage collection and reclaim all dereferenced SHM
/// buffers."*
///
/// @param provider  Const pointer to a loaned SHM provider.
/// @return Canon's `size_t`, verbatim, with the same no-documented-meaning
///         caveat as `zd_shm_provider_defragment`.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_garbage_collect(
    const z_loaned_shm_provider_t* provider);

/// Obtains a mutable loaned reference to the SHM buffer.
FFI_PLUGIN_EXPORT z_loaned_shm_mut_t* zd_shm_mut_loan_mut(
    z_owned_shm_mut_t* buf);

/// Returns a mutable pointer to the SHM buffer data.
FFI_PLUGIN_EXPORT uint8_t* zd_shm_mut_data_mut(z_loaned_shm_mut_t* buf);

/// Returns the length of the SHM buffer.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_len(const z_loaned_shm_mut_t* buf);

/// Converts a mutable SHM buffer into owned bytes (consuming the buffer).
///
/// @param bytes  Pointer to an uninitialized z_owned_bytes_t.
/// @param buf    Pointer to a z_owned_shm_mut_t (consumed).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_from_shm_mut(z_owned_bytes_t* bytes,
                                            z_owned_shm_mut_t* buf);

/// Drops (frees) a mutable SHM buffer.
FFI_PLUGIN_EXPORT void zd_shm_mut_drop(z_owned_shm_mut_t* buf);

/// Checks whether owned bytes are backed by shared memory.
///
/// Uses z_bytes_as_loaned_shm() to probe the bytes. If the call succeeds
/// (returns 0), the bytes are SHM-backed.
///
/// @param bytes  Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @return 1 if SHM-backed, 0 otherwise.
FFI_PLUGIN_EXPORT int8_t zd_bytes_is_shm(const uint8_t* bytes);

#endif // Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API

// ---------------------------------------------------------------------------
// Pull Subscriber (ring and fifo sample channels)
// ---------------------------------------------------------------------------

/// Channel kind, as it crosses the FFI seam.
///
/// ⚠️ THESE VALUES ARE THE SHIM'S DISPATCH CODES, NOT CANON'S. Canon has no
/// channel-kind enum: it ships two separately-named constructor pairs over two
/// distinct handler types, and the kind is chosen by which symbol you call.
/// Dart cannot select a C symbol at run time across the seam, so the kind
/// crosses as an int and every pull entry below dispatches on it.
///
/// The set is CLOSED and originates only in our own `ChannelKind` enum, never
/// in remote input. Any value that is not 1 is treated as ring.
///
///   0 = ring -- bounded and LOSSY. Drops the oldest entry when full; never
///       blocks the producer. Discards its buffer when the producer dies.
///   1 = fifo -- bounded and LOSSLESS. Blocks the producer when full;
///       drains its buffer before reporting disconnected.

/// Returns the size in bytes of the owned handler slot for `kind`.
///
/// The two handler types are distinct, so the caller must allocate the slot
/// for the kind it is about to declare and release it through
/// `zd_pull_handler_drop` with the SAME kind.
///
/// @param kind  0 = ring, 1 = fifo (see above).
/// @return The slot size in bytes. Cannot fail.
FFI_PLUGIN_EXPORT int32_t zd_pull_handler_sizeof(int32_t kind);

/// Declares a pull subscriber backed by a bounded channel of `kind`.
///
/// RETURN CODE CONTRACT -- the channel is SPLIT, and the split is deliberate:
///
///   0            success.
///   POSITIVE     SHIM-ORIGINATED. Canon never returns a positive here.
///                  10 = capacity out of range (negative, or larger than this
///                       target's `size_t`). Nothing was allocated.
///                  11 = an allocation the shim itself needed failed. LIVE:
///                       this entry claims the readiness-tee context, and this
///                       is the code its malloc failure returns. (The comment
///                       that used to sit here still called it RESERVED and
///                       "reachable when the readiness-tee context lands" --
///                       the tee landed in the same change that wrote the code,
///                       so the line described a state that never shipped.)
///   NEGATIVE     CANON'S OWN, passed through unchanged (e.g. `Z_EINVAL -1`,
///                `Z_EPARSE -2` from `z_declare_subscriber`).
///
/// Why the shim's codes are positive rather than the usual -1: canon OWNS the
/// negative space on this channel and actively uses it, so a shim-owned -1
/// would squat on a live canon code and let a canon EINVAL masquerade as our
/// allocation failure. That is an rc-conflation -- the same defect class as
/// collapsing distinct channel states onto one value -- and it is barred.
/// Low positives 1 and 2 stay reserved repo-wide for canon's channel-state
/// meanings, which is why shim-originated call failures start at 10.
///
/// CAPACITY is validated before anything is allocated and is never silently
/// transformed. Canon documents nothing about capacity and its constructor
/// returns void -- it cannot fail and cannot reject a value -- so every domain
/// check that exists at all exists here. Capacity 0 is IN canon's domain and
/// is passed through (measured working on both kinds at 1.8.0, not promised by
/// canon).
///
/// @param subscriber_out  Pointer to an uninitialized z_owned_subscriber_t (as uint8_t*).
/// @param handler_out     Pointer to an uninitialized owned handler slot of
///                        `kind`, sized by `zd_pull_handler_sizeof(kind)`.
/// @param tee_out         Out: the readiness-tee context this call allocates,
///                        or NULL on any failure. SHIM-OWNED: release it with
///                        `zd_pull_tee_drop`, and only AFTER dropping the
///                        subscriber.
/// @param session         Const pointer to a loaned session (as uint8_t*).
/// @param key_expr        Const pointer to the loaned key expression, already
///                        validated Dart-side.
/// @param kind            0 = ring, 1 = fifo.
/// @param capacity        Channel capacity. Carried full-width so no value a
///                        caller can express is truncated on the way in.
/// @param allowed_origin  z_locality_t 0..2 restricting which peers' traffic
///                        this declaration accepts, or -1 to leave canon's
///                        default (ANY).
/// @param dart_port       NativePort the readiness tee posts to: an int64 `1`
///                        when an armed waiter should look again, and a null
///                        sentinel from the closure's drop when the producer
///                        is gone.
/// @return 0, a shim-originated positive, or canon's own negative (above).
FFI_PLUGIN_EXPORT int8_t zd_declare_pull_subscriber(
    uint8_t* subscriber_out, uint8_t* handler_out, uint8_t** tee_out,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity,
    int allowed_origin, int64_t dart_port);

/// Arms the readiness tee: the NEXT delivery posts exactly one ping.
///
/// Idempotent and cheap -- it stores 1 into an atomic flag. The delivery that
/// posts clears it, so one arming yields at most one ping, and a channel with
/// nobody waiting posts nothing at all. That gate is what keeps the mechanism
/// bounded by the channel's own capacity instead of queueing one message per
/// delivered sample.
///
/// Safe to call after the producing session has died: the context outlives the
/// closure's drop by construction (see `zd_pull_tee_drop`). NOT safe after
/// `zd_pull_tee_drop`.
///
/// @param tee  The context from `zd_declare_pull_subscriber`.
FFI_PLUGIN_EXPORT void zd_pull_tee_arm(uint8_t* tee);

/// Frees the readiness-tee context. The DESIGNATED release point.
///
/// ⚠️ Call it only AFTER `zd_subscriber_drop`, which zenoh-c 1.8.0 (#1221)
/// guarantees blocks until executing callbacks are destroyed. The closure's
/// own drop callback deliberately does NOT free this block: it fires whenever
/// the SESSION dies, which can happen while a live Dart handle may still call
/// `zd_pull_tee_arm`. Separating the free from the drop is what makes that
/// ordering safe rather than a use-after-free.
///
/// @param tee  The context from `zd_declare_pull_subscriber`.
FFI_PLUGIN_EXPORT void zd_pull_tee_drop(uint8_t* tee);

/// Tries to receive a sample from the handler, without blocking.
///
/// RETURN CODE CONTRACT -- three of these four are CANON'S OWN VALUES, passed
/// through unaltered:
///
///   0   a sample is available; every out_ parameter is populated
///       (malloc'd -- the caller frees).
///   1   `Z_CHANNEL_DISCONNECTED`: the channel was dropped. Terminal and
///       sticky; every later call reports it again.
///   2   `Z_CHANNEL_NODATA`: the channel is alive, its buffer is empty.
///  -1   SHIM-ORIGINATED: one of the four remote-length-driven allocations
///       below failed. Everything already allocated has been released and
///       every out_ parameter it had set is NULL again.
///
/// ⚠️ The -1 here is sound even though a shim-originated negative is BARRED on
/// the declare channel above, and the asymmetry is not an accident: canon's
/// recv family provably emits no negatives (zero `Z_E*` references anywhere in
/// zenoh-c's `src/closures/`, and every implementation is a total 2- or 3-arm
/// match), so the negative space is genuinely free HERE and genuinely occupied
/// THERE. The two entries differ because their canon contracts differ.
///
/// 1 and 2 are STATES, not failures -- the only positive result codes in the
/// whole zenoh-c API, deliberately outside its negative error space. The Dart
/// surface renders them as sealed variants and reserves throwing for the -1.
///
/// ONE SHARED EXTRACTION BODY serves both kinds: only the loan and the
/// try_recv call are kind-dispatched. Anything that alters how a value is
/// rendered therefore lands once and covers both kinds by construction.
///
/// The key expression AND the encoding are both LENGTH-CARRIED, not
/// NUL-terminated: read exactly `*out_keyexpr_len` / `*out_encoding_len` bytes.
/// Both domains admit an interior NUL and canon carries one byte-exact, so
/// measuring either buffer with strlen truncates a real value. A trailing NUL
/// is written as hygiene only.
///
/// ⚠️ The encoding used to stay a bare C string here, on the reason that a probe
/// had refuted the remote non-UTF-8 trigger for that field at this pin. That
/// reason is TRUE and it is about the wrong property: F-R1 refuted a
/// strict-decode CRASH trigger, and says nothing about LENGTH CARRIAGE. Measured
/// at seed #10: a canon publisher using `z_encoding_from_substr` puts an interior
/// NUL on the wire, and this surface truncated there.
///
/// @param handler           Const pointer to an owned handler of `kind` (as uint8_t*).
/// @param kind              0 = ring, 1 = fifo. MUST match the kind the
///                          handler was declared with.
/// @param out_keyexpr       Out: malloc'd key expression bytes (length-carried).
/// @param out_keyexpr_len   Out: key expression length in bytes (`size_t`).
/// @param out_payload       Out: malloc'd payload bytes.
/// @param out_payload_len   Out: payload length (full-width `size_t`).
/// @param out_kind          Out: sample kind (0=put, 1=delete).
/// @param out_encoding      Out: malloc'd encoding bytes (length-carried).
///                          ALWAYS non-NULL when the return is 0 -- a
///                          zero-length rendered encoding yields a 1-byte
///                          allocation at length 0 rather than NULL,
///                          identically to the subscriber callback path.
///                          Absent-vs-empty is not a distinction canon draws
///                          for this field.
/// @param out_encoding_len  Out: encoding length in bytes (`size_t`).
/// @param out_attachment     Out: malloc'd attachment bytes (or NULL if absent).
/// @param out_attachment_len Out: attachment length (full-width `size_t`).
/// @param out_timestamp   Out: malloc'd 24-byte z_timestamp_t image (or NULL if
///                        the sample carries no timestamp; caller frees).
/// @param out_priority    Out: sample priority (1..7).
/// @param out_congestion  Out: congestion control (0=block, 1=drop, 2=blockFirst).
/// @param out_express     Out: express flag (0/1).
/// @return 0=sample, 1=disconnected, 2=empty, -1=allocation failure.
/// Declares a LIVELINESS subscriber backed by a bounded channel of `kind`.
///
/// The fifth channel carrier, and the thinnest: canon's liveliness declare
/// consumes the SAMPLE closure, so this reuses the sample column's shared
/// channel build, handlers, extraction body and `PullSubscriber` handle
/// wholesale. Only the canon entry and its options struct differ, and that
/// struct carries exactly one field.
///
/// Delivers the alive/gone TRANSITIONS as samples — `SampleKind::Put` when a
/// token appears, `SampleKind::Delete` when it goes — which is a different
/// capability from `zd_liveliness_get`'s snapshot of who is alive now.
///
/// @param history  Non-zero to replay tokens that were already alive when this
///                 subscriber was declared. canon's only option here.
/// @return 0 / 10 (capacity) / 11 (tee allocation) / negative from canon.
FFI_PLUGIN_EXPORT int8_t zd_declare_pull_liveliness_subscriber(
    uint8_t* subscriber_out, uint8_t* handler_out, uint8_t** tee_out,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, int8_t history, int64_t dart_port);

FFI_PLUGIN_EXPORT int8_t zd_pull_subscriber_try_recv(
    const uint8_t* handler, int32_t kind,
    uint8_t** out_keyexpr, size_t* out_keyexpr_len,
    uint8_t** out_payload, size_t* out_payload_len,
    int8_t* out_kind, char** out_encoding, size_t* out_encoding_len,
    uint8_t** out_attachment, size_t* out_attachment_len,
    uint8_t** out_timestamp, int8_t* out_priority,
    int8_t* out_congestion, int8_t* out_express,
    uint8_t* retain_slot, int32_t* out_has_retained);

/// Drops (frees) the handler slot.
///
/// @param handler  Pointer to an owned handler of `kind` (as uint8_t*).
/// @param kind     0 = ring, 1 = fifo. MUST match the kind the handler was
///                 declared with -- the two owned types are distinct, and
///                 releasing one through the other's entry is undefined
///                 behaviour, not an error canon reports.
// ---------------------------------------------------------------------------
// Reply channels (bounded fifo/ring delivery on the get paths)
// ---------------------------------------------------------------------------

/// Returns the size of the owned reply handler for `kind`, in bytes.
///
/// @param kind  0 = ring, 1 = fifo (our dispatch code, not a canon value).
FFI_PLUGIN_EXPORT int32_t zd_reply_handler_sizeof(int32_t kind);

/// Drops an owned reply handler.
///
/// ⚠️ `kind` MUST match the kind the handler was constructed with: the two
/// owned handler types are distinct, and releasing one through the other's
/// entry is undefined behaviour rather than a reported error.
FFI_PLUGIN_EXPORT void zd_reply_handler_drop(uint8_t* handler, int32_t kind);

/// Sends a query whose replies land in a BOUNDED CHANNEL instead of a callback.
///
/// The channel-mode sibling of zd_get. Both fill canon's `z_get_options_t`
/// through one shared body, so their option surfaces cannot drift; they differ
/// only in which closure canon receives.
///
/// Canon drops the reply closure once all replies are processed, so the channel
/// SELF-TERMINATES at query completion — there is no entity to undeclare, and
/// nothing a release on this handle could tell a peer.
///
/// @param handler_out  Caller-allocated buffer of zd_reply_handler_sizeof(kind)
///                     bytes, written with the owned handler on success.
/// @param tee_out      Out-param for the SHIM-owned readiness-tee context.
///                     Released through `zd_pull_tee_drop`, which is shared
///                     with the sample and query columns: the tee head is
///                     payload-agnostic. Set to NULL on every failure path.
/// @param dart_port    Dart NativePort the tee posts readiness pings to (one
///                     per arming, none when nobody waits) and the completion
///                     sentinel from the closure's own drop.
/// @param session      Const pointer to a loaned session (as uint8_t*).
/// @param selector     Const pointer to the loaned selector key expression,
///                     already validated Dart-side.
/// @param kind         0 = ring (lossy, drop-oldest), 1 = fifo (lossless,
///                     producer-backpressured).
/// @param capacity     Channel capacity. Carried full width; never silently
///                     transformed.
/// @param parameters   Length-carried query parameters (see zd_get).
/// @param parameters_len  Byte length of `parameters`; 0 when it is NULL.
/// @return 0 on success.
///         **10** (`ZD_DECLARE_ECAPACITY`) — capacity outside canon's domain.
///           Returned BEFORE the payload/attachment are moved, so a caller must
///           not mark them consumed on this code; the Dart guard rejects a
///           negative capacity earlier, which makes it unreachable from the
///           public API.
///         **11** (`ZD_DECLARE_EALLOC`) — the readiness-tee context could not be
///           claimed. Returned BEFORE the payload/attachment are moved, like 10.
///         negative — canon's own code, passed through unchanged, including the
///           encoding rc from the shared options body (POST-move: the
///           payload/attachment have been dropped).
FFI_PLUGIN_EXPORT int8_t zd_get_channel(
    uint8_t* handler_out,
    uint8_t** tee_out,
    int64_t dart_port,
    const uint8_t* session,
    const z_loaned_keyexpr_t* selector,
    int32_t kind,
    int64_t capacity,
    int8_t target,
    int8_t consolidation,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint64_t timeout_ms,
    const char* parameters,
    size_t parameters_len,
    uint8_t* attachment,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination,
    int accept_replies);

/// Takes one reply out of a bounded reply channel, without waiting.
///
/// One shared extraction body serves both kinds; only the loan and the
/// try_recv call are kind-dispatched.
///
/// `out_is_ok` discriminates the two readings of the shared out-params: on an
/// ok reply they carry the sample's key expression, payload, kind, encoding,
/// attachment, timestamp and QoS; on an error reply the payload and encoding
/// carry the ERROR's, and the rest are absent. `out_replier_zid` /
/// `out_replier_eid` are filled on both branches where the unstable API is
/// compiled in, and are absent (NULL zid) otherwise — the out-param MEANING is
/// constant across variants, so the Dart parse is platform-invariant.
///
/// Empty is not absent: a present-but-empty attachment comes back as a
/// **non-NULL** pointer at length 0, so discriminate on the pointer. The
/// encoding is allocated unconditionally, matching the callback path, so a
/// zero-length rendered encoding reads as `''` on both receive surfaces rather
/// than as `''` on one and `null` on the other. It is LENGTH-CARRIED: read
/// exactly `*out_encoding_len` bytes.
///
/// Every `out_*` pointer buffer is malloc'd HERE and freed by the CALLER.
///
/// @return 0   a reply was taken (see `out_is_ok`).
///         1   `Z_CHANNEL_DISCONNECTED` — the query completed. Terminal and
///             sticky; canon's own code, passed through.
///         2   `Z_CHANNEL_NODATA` — alive, buffer empty right now. Canon's own
///             code, passed through.
///         -1  a remote-length-driven allocation could not be satisfied.
///             Everything already claimed has been released.
FFI_PLUGIN_EXPORT int8_t zd_reply_channel_try_recv(
    const uint8_t* handler, int32_t kind,
    int8_t* out_is_ok,
    uint8_t** out_keyexpr, size_t* out_keyexpr_len,
    uint8_t** out_payload, size_t* out_payload_len,
    int8_t* out_kind, char** out_encoding, size_t* out_encoding_len,
    uint8_t** out_attachment, size_t* out_attachment_len,
    uint8_t** out_timestamp, int8_t* out_priority,
    int8_t* out_congestion, int8_t* out_express,
    uint8_t** out_replier_zid, int64_t* out_replier_eid,
    uint8_t* retain_slot, int32_t* out_has_retained);

FFI_PLUGIN_EXPORT void zd_pull_handler_drop(uint8_t* handler, int32_t kind);

// ---------------------------------------------------------------------------
// Querier
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_querier_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_querier_sizeof(void);

/// Declares a querier on the given key expression.
///
/// @param querier_out    Pointer to uninitialized z_owned_querier_t (as uint8_t*).
/// @param session        Pointer to a loaned session (as uint8_t*).
/// @param key_expr       Null-terminated key expression string.
/// @param target         Query target (z_query_target_t value).
/// @param consolidation  Consolidation mode (-1=auto, 0=none, 1=monotonic, 2=latest).
/// @param timeout_ms     Timeout in milliseconds (0 = default).
/// @return 0 on success, negative on failure.
/// @param congestion_control  Congestion control strategy, or -1 to leave
///                       canon's own default. NOTE: querier is a REQUEST path,
///                       so canon's default is DEFAULT_REQUEST = BLOCK.
/// @param priority       Priority 1..7, or -1 to leave canon's default (data=5).
/// @param is_express     1/0 to set express mode, or -1 to leave canon's
///                       default (false).
/// @param allowed_destination  z_locality_t 0..2, or -1 to leave canon's
///                       default (ANY).
/// @param accept_replies z_reply_keyexpr_t 0..1, or -1 to leave canon's
///                       default (MATCHING_QUERY = 1).
///
/// All five are DECLARATION-time: canon's z_querier_get_options_t carries no
/// QoS, locality or accept-replies field, so there is no per-call form.
FFI_PLUGIN_EXPORT int8_t zd_declare_querier(
    uint8_t* querier_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr, int8_t target,
    int8_t consolidation, uint64_t timeout_ms,
    int congestion_control, int priority, int8_t is_express,
    int allowed_destination, int accept_replies);

/// Drops (frees) the querier.
///
/// @param querier  Pointer to a z_owned_querier_t (as uint8_t*).
FFI_PLUGIN_EXPORT void zd_querier_drop(uint8_t* querier);

/// Sends a query via a declared querier.
///
/// Replies are delivered asynchronously to the Dart NativePort.
/// Reuses the same reply callback as zd_get.
///
/// @param querier     Pointer to a z_owned_querier_t (as uint8_t*).
/// @param parameters  Optional query parameters, LENGTH-CARRIED (see zd_get).
///                    NULL with `parameters_len` 0 means none.
/// @param parameters_len  Byte length of `parameters`; 0 when it is NULL.
/// @param port        Dart NativePort for reply callbacks.
/// @param payload     Optional z_owned_bytes_t* (consumed if non-NULL).
/// @param encoding    Optional encoding string (NULL for none).
/// @param attachment  Optional z_owned_bytes_t* (consumed if non-NULL).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_get(
    const uint8_t* querier, const char* parameters, size_t parameters_len,
    int64_t port, uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment, int retain_payload);

/// Sends a query via a declared querier, with replies landing in a BOUNDED
/// CHANNEL instead of a callback.
///
/// The channel-mode sibling of zd_querier_get. Both fill canon's per-get
/// options through one shared body, and the channel itself is built by the same
/// shared body all three reply carriers use — so their behaviour is identical by
/// construction rather than by three copies staying in step.
///
/// @param handler_out  Caller-allocated `zd_reply_handler_sizeof(kind)` buffer.
/// @param tee_out      Out-param for the SHIM-owned readiness-tee context,
///                     released through the shared `zd_pull_tee_drop`.
/// @param dart_port    Dart NativePort the tee posts readiness pings to.
/// @param parameters   Length-carried query parameters (see zd_get).
/// @return 0 / 10 (capacity, PRE-move) / 11 (tee allocation, PRE-move) /
///         negative from canon.
FFI_PLUGIN_EXPORT int8_t zd_querier_get_channel(
    uint8_t* handler_out, uint8_t** tee_out, int64_t dart_port,
    const uint8_t* querier, int32_t kind, int64_t capacity,
    const char* parameters, size_t parameters_len,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment);

/// Declares a background matching listener for a querier.
///
/// Reuses the same matching status callback and drop function as publisher.
///
/// @param querier    Pointer to a z_owned_querier_t (as uint8_t*).
/// @param port       Dart NativePort for matching status callbacks.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_declare_background_matching_listener(
    const uint8_t* querier, int64_t port);

/// Gets the current matching status of a querier.
///
/// @param querier        Pointer to a z_owned_querier_t (as uint8_t*).
/// @param matching_out   Output: 1 if matching queryables exist, 0 otherwise.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_get_matching_status(
    const uint8_t* querier, int8_t* matching_out);

// ---------------------------------------------------------------------------
// Liveliness
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_liveliness_token_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_liveliness_token_sizeof(void);

/// Declares a liveliness token on the given key expression.
///
/// @param token_out  Pointer to an uninitialized z_owned_liveliness_token_t (as uint8_t*).
/// @param session    Const pointer to a loaned session (as uint8_t*).
/// @param key_expr   Const pointer to the loaned key expression, already
///                   validated Dart-side.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_token(
    uint8_t* token_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr);

/// Drops (undeclares and frees) a liveliness token.
///
/// @param token  Pointer to a z_owned_liveliness_token_t (as uint8_t*).
FFI_PLUGIN_EXPORT void zd_liveliness_token_drop(uint8_t* token);

/// Declares a liveliness subscriber on the given key expression.
///
/// Reuses the same z_owned_subscriber_t type and _zd_sample_callback/drop
/// as the regular subscriber. Samples are posted to the Dart NativePort.
///
/// @param subscriber_out  Pointer to an uninitialized z_owned_subscriber_t (as uint8_t*).
/// @param session         Const pointer to a loaned session (as uint8_t*).
/// @param key_expr        Const pointer to the loaned key expression,
///                        already validated Dart-side.
/// @param port            Dart NativePort for sample callbacks.
/// @param history         Boolean (0=false, 1=true) for receiving pre-existing token state.
/// @param retain_payload  Non-zero makes each delivered sample carry an OWNED
///                        clone of its payload as message element 9. Zero
///                        posts kNull there and allocates nothing.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_subscriber(
    uint8_t* subscriber_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr, int64_t port, int8_t history,
    int retain_payload);

/// Declares a background liveliness subscriber on the given key expression.
///
/// Unlike zd_liveliness_declare_subscriber, this has no handle -- it lives
/// until the session is closed. Samples (PUT on token declare, DELETE on
/// undeclare) are posted to the Dart NativePort. When the session closes and
/// the background subscriber is dropped internally by zenoh-c, a null sentinel
/// is posted to signal stream completion.
///
/// @param session   Const pointer to a loaned session.
/// @param key_expr  Const pointer to the loaned key expression, already
///                  validated Dart-side.
/// @param dart_port The Dart native port to post samples to.
/// @param history   Boolean (0=false, 1=true) for receiving pre-existing token state.
/// @param retain_payload  Non-zero makes each delivered sample carry an OWNED
///                        clone of its payload as message element 9. Zero
///                        posts kNull there and allocates nothing.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_background_subscriber(
    const z_loaned_session_t* session, const z_loaned_keyexpr_t* key_expr,
    int64_t dart_port, int8_t history, int retain_payload);

/// Queries liveliness tokens matching the given key expression.
///
/// Replies are posted to the Dart NativePort as arrays (same format as
/// zd_get replies). A null sentinel signals completion.
///
/// @param session   Loaned session pointer.
/// @param key_expr  Const pointer to the loaned key expression to query
///                  liveliness for, already validated Dart-side.
/// @param port      Dart NativePort for reply callbacks.
/// @param timeout_ms  Timeout in milliseconds. ⚠️ NOT a 0-sentinel — 0 means
///                 ZERO here, and a liveliness query with a 0 ms timeout
///                 expires immediately and returns nothing. This doc line
///                 previously repeated canon's own false claim
///                 (`zenoh_commons.h`: "0 means default query timeout from
///                 zenoh configuration"); verified at source, canon applies
///                 this value UNCONDITIONALLY for liveliness
///                 (`liveliness.rs:279` — its only guard is "were options
///                 supplied", not "is the value non-zero"), unlike `z_get`
///                 and `z_querier`, which do carry a genuine `!= 0` sentinel.
///                 canon's own default is 10000; the Dart side sends it
///                 explicitly, which is why the default works today.
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_get(
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int64_t port, uint64_t timeout_ms, int retain_payload);

/// Queries liveliness tokens, with replies landing in a BOUNDED CHANNEL.
///
/// The channel-mode sibling of zd_liveliness_get, over the same shared
/// reply-channel construction as the other two reply carriers.
///
/// @param handler_out  Caller-allocated `zd_reply_handler_sizeof(kind)` buffer.
/// @param tee_out      Out-param for the SHIM-owned readiness-tee context.
/// @param dart_port    Dart NativePort the tee posts readiness pings to.
/// @param timeout_ms   ⚠️ NOT a 0-sentinel — see zd_liveliness_get's contract.
/// @return 0 / 10 (capacity) / 11 (tee allocation) / negative from canon.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_get_channel(
    uint8_t* handler_out, uint8_t** tee_out, int64_t dart_port,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, uint64_t timeout_ms);

// ---------------------------------------------------------------------------
// Serializer
// ---------------------------------------------------------------------------

/// Returns the size of ze_owned_serializer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_serializer_sizeof(void);

/// Initializes an empty serializer.
///
/// @param ser  Pointer to an uninitialized ze_owned_serializer_t.
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_serializer_empty(ze_owned_serializer_t* ser);

/// Obtains a mutable loaned reference to the owned serializer.
///
/// @param ser  Pointer to a valid ze_owned_serializer_t.
/// @param out  Receives the mutable loaned pointer.
FFI_PLUGIN_EXPORT void zd_serializer_loan_mut(
    ze_owned_serializer_t* ser, ze_loaned_serializer_t** out);

/// Finishes the serializer and produces a z_owned_bytes_t.
///
/// The serializer is consumed (moved) by this call.
///
/// @param ser  Pointer to a valid ze_owned_serializer_t (consumed).
/// @param out  Receives the produced z_owned_bytes_t.
FFI_PLUGIN_EXPORT void zd_serializer_finish(
    ze_owned_serializer_t* ser, z_owned_bytes_t* out);

/// Drops (frees) an owned serializer.
///
/// After this call the owned serializer is in gravestone state.
///
/// @param ser  Pointer to a ze_owned_serializer_t to drop.
FFI_PLUGIN_EXPORT void zd_serializer_drop(ze_owned_serializer_t* ser);

// ---------------------------------------------------------------------------
// Serializer — arithmetic type serialization
// ---------------------------------------------------------------------------

/// Serializes a uint8_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint8(
    ze_loaned_serializer_t* ser, uint8_t val);

/// Serializes a uint16_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint16(
    ze_loaned_serializer_t* ser, uint16_t val);

/// Serializes a uint32_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint32(
    ze_loaned_serializer_t* ser, uint32_t val);

/// Serializes a uint64_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint64(
    ze_loaned_serializer_t* ser, uint64_t val);

/// Serializes an int8_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int8(
    ze_loaned_serializer_t* ser, int8_t val);

/// Serializes an int16_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int16(
    ze_loaned_serializer_t* ser, int16_t val);

/// Serializes an int32_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int32(
    ze_loaned_serializer_t* ser, int32_t val);

/// Serializes an int64_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int64(
    ze_loaned_serializer_t* ser, int64_t val);

/// Serializes a float value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_float(
    ze_loaned_serializer_t* ser, float val);

/// Serializes a double value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_double(
    ze_loaned_serializer_t* ser, double val);

/// Serializes a bool value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_bool(
    ze_loaned_serializer_t* ser, bool val);

// ---------------------------------------------------------------------------
// Serializer — compound type serialization
// ---------------------------------------------------------------------------

/// Serializes a length-delimited UTF-8 string (embedded NULs preserved).
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_string(
    ze_loaned_serializer_t* ser, const uint8_t* val, size_t len);

/// Serializes a byte buffer of the given length.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_buf(
    ze_loaned_serializer_t* ser, const uint8_t* data, size_t len);

/// Serializes a sequence length header for a subsequent sequence of elements.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_sequence_length(
    ze_loaned_serializer_t* ser, size_t len);

// ---------------------------------------------------------------------------
// Deserializer
// ---------------------------------------------------------------------------

/// Returns the size of ze_deserializer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_deserializer_sizeof(void);

/// Creates a deserializer from loaned bytes.
///
/// @param bytes  Loaned bytes to deserialize from.
/// @param out    Pointer to an uninitialized ze_deserializer_t.
FFI_PLUGIN_EXPORT void zd_deserializer_from_bytes(
    const z_loaned_bytes_t* bytes, ze_deserializer_t* out);

/// Checks if the deserializer has consumed all data.
///
/// @return true if no more data to parse, false otherwise.
FFI_PLUGIN_EXPORT bool zd_deserializer_is_done(const ze_deserializer_t* deser);

// ---------------------------------------------------------------------------
// Deserializer — type deserialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint8(
    ze_deserializer_t* deser, uint8_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint16(
    ze_deserializer_t* deser, uint16_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint32(
    ze_deserializer_t* deser, uint32_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint64(
    ze_deserializer_t* deser, uint64_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int8(
    ze_deserializer_t* deser, int8_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int16(
    ze_deserializer_t* deser, int16_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int32(
    ze_deserializer_t* deser, int32_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int64(
    ze_deserializer_t* deser, int64_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_float(
    ze_deserializer_t* deser, float* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_double(
    ze_deserializer_t* deser, double* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_bool(
    ze_deserializer_t* deser, bool* out);

/// Deserializes a string. Caller must drop the owned string.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_string(
    ze_deserializer_t* deser, z_owned_string_t* out);

/// Deserializes a byte buffer (slice). Outputs owned bytes.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_buf(
    ze_deserializer_t* deser, z_owned_bytes_t* out);

/// Deserializes a sequence length header.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_sequence_length(
    ze_deserializer_t* deser, size_t* out);

// ---------------------------------------------------------------------------
// Bytes Writer
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_bytes_writer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_bytes_writer_sizeof(void);

/// Creates an empty bytes writer.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_empty(z_owned_bytes_writer_t* writer);

/// Obtains a mutable loan of the writer.
FFI_PLUGIN_EXPORT void zd_bytes_writer_loan_mut(
    z_owned_bytes_writer_t* writer, z_loaned_bytes_writer_t** out);

/// Writes all bytes from src into the writer.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_write_all(
    z_loaned_bytes_writer_t* writer, const uint8_t* data, size_t len);

/// Appends owned bytes into the writer. Consumes the bytes.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_append(
    z_loaned_bytes_writer_t* writer, z_owned_bytes_t* bytes);

/// Finishes the writer and produces owned bytes.
FFI_PLUGIN_EXPORT void zd_bytes_writer_finish(
    z_owned_bytes_writer_t* writer, z_owned_bytes_t* out);

/// Drops the writer without finishing.
FFI_PLUGIN_EXPORT void zd_bytes_writer_drop(z_owned_bytes_writer_t* writer);

// ---------------------------------------------------------------------------
// Bytes Slice Iterator
// ---------------------------------------------------------------------------

/// Returns the size of z_bytes_slice_iterator_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_bytes_slice_iterator_sizeof(void);

/// Creates a slice iterator from loaned bytes and copies it to *iter.
///
/// @param bytes  Const pointer to loaned bytes.
/// @param iter   Pointer to caller-allocated z_bytes_slice_iterator_t.
FFI_PLUGIN_EXPORT void zd_bytes_get_slice_iterator(
    const z_loaned_bytes_t* bytes, z_bytes_slice_iterator_t* iter);

/// Advances the slice iterator.
///
/// @param iter  Pointer to a z_bytes_slice_iterator_t.
/// @param out   Pointer to a z_view_slice_t to receive the next slice.
/// @return true if a slice was written to out, false if iteration is done.
FFI_PLUGIN_EXPORT bool zd_bytes_slice_iterator_next(
    z_bytes_slice_iterator_t* iter, z_view_slice_t* out);

/// Returns the size of z_view_slice_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_view_slice_sizeof(void);

/// Returns a pointer to the slice data.
///
/// @param slice  Const pointer to a z_view_slice_t.
/// @return Pointer to the data bytes.
FFI_PLUGIN_EXPORT const uint8_t* zd_view_slice_data(
    const z_view_slice_t* slice);

/// Returns the length of the slice data.
///
/// @param slice  Const pointer to a z_view_slice_t.
/// @return Number of bytes in the slice.
FFI_PLUGIN_EXPORT size_t zd_view_slice_len(const z_view_slice_t* slice);

// ---------------------------------------------------------------------------
// Advanced Publisher
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_UNSTABLE_API)

/// Returns the size of ze_owned_advanced_publisher_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_advanced_publisher_sizeof(void);

/// Declares an advanced publisher on the given key expression.
///
/// @param enable_cache        Whether to enable the publisher-side cache.
/// @param cache_max_samples   Cache bound when the cache is enabled.
///                            **-1 means UNSPECIFIED**: canon's own default
///                            (`ze_advanced_publisher_cache_options_default`,
///                            currently 1) is left untouched. Any value >= 0 is
///                            assigned verbatim, zero included -- canon's zero
///                            carries NO unlimited semantics (measured), so
///                            there is no in-band value to misread. Ignored
///                            entirely when `enable_cache` is false.
/// @return 0 on success; canon's own negative code on a canon failure;
///         ZD_DECLARE_ECAPACITY (10) when `cache_max_samples` is outside the
///         representable domain (< -1, or > SIZE_MAX on ILP32) -- rejected
///         before anything is declared, so nothing ran.
FFI_PLUGIN_EXPORT int zd_declare_advanced_publisher(
    const z_loaned_session_t* session,
    ze_owned_advanced_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    bool enable_cache,
    int64_t cache_max_samples,
    bool publisher_detection,
    bool sample_miss_detection,
    int heartbeat_mode,
    uint64_t heartbeat_period_ms);

/// Publishes data through the advanced publisher.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_put(
    const ze_loaned_advanced_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    z_owned_bytes_t* attachment);

/// Sends a DELETE through the advanced publisher.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_delete(
    const ze_loaned_advanced_publisher_t* publisher);

/// Reads whether any subscriber currently matches the advanced publisher's
/// key expression.
///
/// @param matching  Out-param, written 1/0 ONLY on rc 0. On any error it is
///                  left untouched, mirroring canon's own contract
///                  ("in this case matching_status is not updated").
/// @return canon's rc verbatim: 0 on success, negative on a canon failure.
///         This entry adds no failure code of its own.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_get_matching_status(
    const ze_loaned_advanced_publisher_t* publisher,
    int* matching);

/// Declares a background matching listener on the advanced publisher.
///
/// Posts an int64 1/0 to @p dart_port on every matching-status transition.
/// Canon binds the listener's lifetime to the PUBLISHER: it runs until the
/// corresponding advanced publisher is dropped.
///
/// @return 0 on success; canon's own negative code on a canon failure;
///         ZD_DECLARE_EALLOC (11) if the context allocation fails, in which
///         case nothing was declared. Positive because canon owns 0-and-
///         negative on this channel.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_declare_background_matching_listener(
    const ze_loaned_advanced_publisher_t* publisher,
    int64_t dart_port);

/// Obtains a const loaned reference to the advanced publisher.
FFI_PLUGIN_EXPORT const ze_loaned_advanced_publisher_t* zd_advanced_publisher_loan(
    const ze_owned_advanced_publisher_t* publisher);

/// `AdvancedPublisher`'s net: `zd_advanced_publisher_drop` then `free(token)`.
///
/// ⚠️ Matching-listener-OFF only, exactly as `zd_fin_publisher` above.
/// ⛔ **Guarded by `Z_FEATURE_UNSTABLE_API`, so it is ABSENT from the `stable`
/// native this package also ships.** The Dart side resolves each `zd_fin_*`
/// entry lazily, at first attach, and this one is only ever reached from a
/// path already behind the same feature predicate -- eager resolution of the
/// family would throw at initialization on a variant that legitimately lacks
/// it.
FFI_PLUGIN_EXPORT void zd_fin_advanced_publisher(void* token);

/// Drops (undeclares and frees) an advanced publisher.
FFI_PLUGIN_EXPORT void zd_advanced_publisher_drop(
    ze_owned_advanced_publisher_t* publisher);

// ---------------------------------------------------------------------------
// Advanced Subscriber
// ---------------------------------------------------------------------------

/// Returns the size of ze_owned_advanced_subscriber_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_advanced_subscriber_sizeof(void);

/// Declares an advanced subscriber on the given key expression.
FFI_PLUGIN_EXPORT int zd_declare_advanced_subscriber(
    const z_loaned_session_t* session,
    ze_owned_advanced_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    bool history,
    bool history_detect_late_publishers,
    bool recovery,
    bool recovery_last_sample_miss_detection,
    uint64_t recovery_periodic_queries_period_ms,
    bool subscriber_detection,
    int retain_payload);

/// Declares a background sample miss listener on the advanced subscriber.
FFI_PLUGIN_EXPORT int zd_advanced_subscriber_declare_background_sample_miss_listener(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port);

/// Declares a background subscriber on the liveliness tokens of matching
/// advanced publishers that enable publisher detection.
///
/// Posts ordinary sample arrays to @p dart_port — PUT-kind on a publisher's
/// appearance, DELETE-kind on its disappearance — and posts a NULL sentinel
/// from its drop callback so the Dart side can complete the stream.
///
/// Canon binds this listener's lifetime to the SESSION: it runs until the
/// corresponding session is closed or dropped, outliving the advanced
/// subscriber it was declared on.
///
/// @param history  **-1 means UNSPECIFIED**: NULL options are passed and
///                 canon's own default applies (history = false). 0 or 1
///                 fills `z_liveliness_subscriber_options_t.history`.
/// @return 0 on success; canon's own negative code on a canon failure;
///         ZD_DECLARE_EALLOC (11) if the context allocation fails, in which
///         case nothing was declared and no sentinel will arrive.
FFI_PLUGIN_EXPORT int zd_advanced_subscriber_detect_publishers_background(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port,
    int history,
    int retain_payload);

/// Obtains a const loaned reference to the advanced subscriber.
FFI_PLUGIN_EXPORT const ze_loaned_advanced_subscriber_t* zd_advanced_subscriber_loan(
    const ze_owned_advanced_subscriber_t* subscriber);

/// Drops (undeclares and frees) an advanced subscriber.
FFI_PLUGIN_EXPORT void zd_advanced_subscriber_drop(
    ze_owned_advanced_subscriber_t* subscriber);

#endif // Z_FEATURE_UNSTABLE_API

#endif // ZENOH_DART_H
