#include "zenoh_dart.h"
#include "dart/dart_api_dl.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The thread that initialised the Dart API DL. `native_lib.dart` loads this
// shim eagerly on the main thread and calls zd_init_dart_api_dl from there, so
// this IS the mutator -- captured rather than assumed. Declared HERE, above
// its first use, rather than beside the finalizer counters it serves: C needs
// the declaration before zd_init_dart_api_dl, which is the capture site.
static pthread_t zd_dart_init_thread;
static atomic_int zd_dart_init_thread_known;

// ---------------------------------------------------------------------------
// Dart API initialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT intptr_t zd_init_dart_api_dl(void* data) {
  // Capture the mutator's thread id here, where we are certainly on it:
  // native_lib.dart loads this shim eagerly on the main thread and calls this
  // first. zd_fin_last_on_main() compares against it. Store the id BEFORE the
  // "known" flag so no reader can see the flag set over an unwritten id.
  zd_dart_init_thread = pthread_self();
  atomic_store(&zd_dart_init_thread_known, 1);
  return Dart_InitializeApiDL(data);
}

// Defined with the other marshalling helpers further down; forward-declared
// up here because the logging block and the session block both precede them
// in this file.
static void _zd_str_to_cobject(const char* data, size_t len,
                               Dart_CObject* obj);

// ---------------------------------------------------------------------------
// The logging slot
// ---------------------------------------------------------------------------
//
// Canon's three inits are FIRST-WINS, PROCESS-GLOBAL AND SILENTLY IDEMPOTENT:
// whichever runs first owns logging for the life of the process, and every
// later call no-ops WITH NO REPORT. zc_init_log_with_callback returns void, so
// canon has no channel to say "you were too late" even in principle.
//
// That silence is a diagnosability defect created by this binding's own
// feature: a consumer who calls zd_init_log and then installs a sink would get
// no sink and no error, and would debug a delivery problem that is really an
// ordering one. So the shim keeps its own record of whether an init MADE
// THROUGH THIS BINDING has claimed the slot, and zd_init_log_with_callback
// reports it.
//
// ⚠️ WHAT THE FLAG CANNOT SEE, stated because the dartdoc promises only what
// is true: an init made by other code in the same process -- another binding,
// a Rust crate linked into the same image -- claims canon's slot without
// touching this flag. The flag is a guard against OUR OWN ordering mistake,
// not a view of canon's state, which canon does not expose.
//
// Atomic because the claim must be exactly-once even if two isolates race the
// install. The loser is told nothing was installed, which is true.
static atomic_int zd_log_slot_claimed = 0;

/// Context for the log closure.
///
/// ⛔ FILE-SCOPE, NOT HEAP, and deliberately. Canon's slot is process-global
/// and first-wins, so at most ONE sink can ever exist -- there is nothing for
/// a second allocation to hold. Making it static buys three things: "never
/// freed" becomes literally true rather than a documented leak; there is no
/// window in which a drop could race a call and free the context out from
/// under the emitting thread; and no allocation-counting instrument in this
/// repo is perturbed by the feature at all.
typedef struct {
  Dart_Port_DL dart_port;
} zd_log_sink_ctx_t;

static zd_log_sink_ctx_t zd_log_sink_ctx;

/// Canon's log callback. RUNS ON THE EMITTING THREAD, POSSIBLY CONCURRENTLY.
///
/// ⛔ THE PROHIBITIONS BELOW BIND THIS FUNCTION, NOT THE DART LISTENER. This
/// body really does run synchronously on whichever tokio thread emitted the
/// record, so anything slow here back-pressures zenoh's own runtime. The Dart
/// listener never runs here: it runs on its own event loop, one post later.
///
///   * NEVER BLOCK. Copy, post, return.
///   * NEVER REENTER zenoh from here -- a logging callback that calls back
///     into the runtime that is mid-log is a deadlock waiting for a rate.
///   * NEVER ALLOCATE UNBOUNDEDLY. This body allocates nothing at all.
///
/// The message pointer is BORROWED and valid only for the duration of this
/// call. It is handed to Dart_PostCObject_DL as length-carried typed data,
/// which copies the bytes into the receiving isolate BEFORE returning -- so
/// the copy happens inside this call, while the borrow is still valid, and
/// nothing is retained past the return. Never Dart_CObject_kString: that
/// truncates at an interior NUL and validates as UTF-8, and canon's messages
/// are neither our data nor our encoding to assume.
///
/// Only severity and message cross: canon drops target, file, line, thread and
/// span at the zenoh-c layer, so a host sink cannot recover them.
static void _zd_log_call(enum zc_log_severity_t severity,
                         const z_loaned_string_t* msg, void* context) {
  zd_log_sink_ctx_t* ctx = (zd_log_sink_ctx_t*)context;

  Dart_CObject c_severity;
  c_severity.type = Dart_CObject_kInt64;
  c_severity.value.as_int64 = (int64_t)severity;

  Dart_CObject c_message;
  _zd_str_to_cobject(z_string_data(msg), z_string_len(msg), &c_message);

  Dart_CObject* elements[2] = {&c_severity, &c_message};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 2;
  c_array.value.as_array.values = elements;

  // A closed port returns false. There is nothing to do about it and nothing
  // to clean up: the record is simply lost, which is what a host that stopped
  // listening asked for.
  Dart_PostCObject_DL(ctx->dart_port, &c_array);
}

/// Canon's drop hook. Nothing to free -- the context is file-scope.
///
/// Canon has NO REMOVAL, so this is not expected to fire at all; it exists
/// because the closure struct has the slot and leaving it NULL would be a
/// promise about canon's behaviour we cannot make.
static void _zd_log_drop(void* context) { (void)context; }

FFI_PLUGIN_EXPORT void zd_init_log(const char* fallback_filter) {
  // Claims the slot: see the block above. Unconditional, because canon's init
  // claims whether or not it had anything to do.
  atomic_store(&zd_log_slot_claimed, 1);
  // rc-hygiene (F12): best-effort logger init; failure is non-fatal and there
  // is nothing to surface from a void init, so the rc is captured and ignored
  // deliberately rather than discarded silently.
  z_result_t rc = zc_init_log_from_env_or(fallback_filter);
  (void)rc;
}

FFI_PLUGIN_EXPORT int zd_init_log_with_callback(int min_severity,
                                                int64_t dart_port) {
  if (min_severity < ZC_LOG_SEVERITY_TRACE ||
      min_severity > ZC_LOG_SEVERITY_ERROR) {
    // ⚠️ A BARE -1, AND IT IS DEFENSIBLE HERE FOR THE REASON THE BLOCK ABOVE
    // zd_open_session_async REFUSES IT ELSEWHERE. That comment objects to
    // spelling an ALLOCATION FAILURE as -1, because an allocation failure is
    // not an invalid argument. This is the other case: the argument really is
    // invalid, which is exactly what canon's Z_EINVAL (-1) names. The sign
    // also carries information here -- the caller discriminates a NEGATIVE
    // (bad argument, nothing attempted) from a POSITIVE (the slot was already
    // claimed), and collapsing them would lose that.
    //
    // Unreachable from Dart, where the parameter is an enum. It exists
    // because the shim's contract is with the ABI, not with one caller.
    return -1;
  }
  // Exactly-once. The loser installs nothing and is told so, which is the
  // truth: canon's slot belongs to whoever got here first.
  if (atomic_exchange(&zd_log_slot_claimed, 1) != 0) {
    return 1;
  }

  zd_log_sink_ctx.dart_port = (Dart_Port_DL)dart_port;

  zc_owned_closure_log_t closure;
  closure._context = &zd_log_sink_ctx;
  closure._call = _zd_log_call;
  closure._drop = _zd_log_drop;

  // MOVED: canon takes the closure whole. It is constructed and moved here, so
  // Dart never sees a closure and has nothing to mark consumed.
  zc_init_log_with_callback((enum zc_log_severity_t)min_severity,
                            zc_closure_log_move(&closure));
  return 0;
}

// ---------------------------------------------------------------------------
// Build feature detection
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT uint32_t zd_features(void) {
  uint32_t features = 0;
#if defined(Z_FEATURE_UNSTABLE_API)
  features |= ZD_FEATURE_UNSTABLE_API;
#endif
#if defined(Z_FEATURE_SHARED_MEMORY)
  features |= ZD_FEATURE_SHARED_MEMORY;
#endif
  return features;
}

// ---------------------------------------------------------------------------
// NativeFinalizer entry points  (seed [OWN])
// ---------------------------------------------------------------------------
//
// The shared contract is in the header, beside the declarations. What lives
// here is only the counter's storage and the entries themselves.

// Static storage duration => zero-initialised, which is the correct starting
// value for every counter. `atomic_int` because these increment from whatever
// thread the VM runs the finalizer on -- measured on the MUTATOR in this VM,
// but the SDK documents "an arbitrary thread with no current isolate" and a
// counter that is only correct on one of them is not an instrument.
static atomic_int zd_fin_counts[ZD_FIN_KIND_COUNT];

// ZD_FIN_ON_MAIN_* per kind; zero-initialised to UNOBSERVED, which is why that
// value is 0 and the two real answers are 1 and 2. See the header.
static atomic_int zd_fin_on_main[ZD_FIN_KIND_COUNT];

static void zd_fin_note(int kind) {
  atomic_fetch_add(&zd_fin_counts[kind], 1);
  int on_main = ZD_FIN_ON_MAIN_UNOBSERVED;
  if (atomic_load(&zd_dart_init_thread_known)) {
    on_main = pthread_equal(pthread_self(), zd_dart_init_thread)
                  ? ZD_FIN_ON_MAIN_YES
                  : ZD_FIN_ON_MAIN_NO;
  }
  atomic_store(&zd_fin_on_main[kind], on_main);
}

FFI_PLUGIN_EXPORT void zd_fin_free_block(void* token) {
  zd_fin_note(ZD_FIN_KIND_FREE_BLOCK);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_config(void* token) {
  zd_fin_note(ZD_FIN_KIND_CONFIG);
  zd_config_drop((z_owned_config_t*)token);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_bytes(void* token) {
  zd_fin_note(ZD_FIN_KIND_BYTES);
  zd_bytes_drop((z_owned_bytes_t*)token);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_keyexpr(void* token) {
  zd_fin_note(ZD_FIN_KIND_KEYEXPR);
  zd_keyexpr_drop((z_owned_keyexpr_t*)token);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_bytes_writer(void* token) {
  zd_fin_note(ZD_FIN_KIND_BYTES_WRITER);
  zd_bytes_writer_drop((z_owned_bytes_writer_t*)token);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_serializer(void* token) {
  zd_fin_note(ZD_FIN_KIND_SERIALIZER);
  zd_serializer_drop((ze_owned_serializer_t*)token);
  free(token);
}

FFI_PLUGIN_EXPORT void zd_fin_publisher(void* token) {
  zd_fin_note(ZD_FIN_KIND_PUBLISHER);
  zd_publisher_drop((z_owned_publisher_t*)token);
  free(token);
}

#if defined(Z_FEATURE_UNSTABLE_API)
FFI_PLUGIN_EXPORT void zd_fin_advanced_publisher(void* token) {
  zd_fin_note(ZD_FIN_KIND_ADVANCED_PUBLISHER);
  zd_advanced_publisher_drop((ze_owned_advanced_publisher_t*)token);
  free(token);
}
#endif // Z_FEATURE_UNSTABLE_API

#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)
FFI_PLUGIN_EXPORT void zd_fin_shm_provider(void* token) {
  zd_fin_note(ZD_FIN_KIND_SHM_PROVIDER);
  zd_shm_provider_drop((z_owned_shm_provider_t*)token);
  free(token);
}
#endif // Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API

#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)
FFI_PLUGIN_EXPORT void zd_fin_shm_mut(void* token) {
  zd_fin_note(ZD_FIN_KIND_SHM_MUT);
  zd_shm_mut_drop((z_owned_shm_mut_t*)token);
  free(token);
}
#endif // Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API

FFI_PLUGIN_EXPORT int zd_fin_invocations(int kind) {
  // Unreachable by construction -- the Dart mirror validates the kind before
  // calling. Returning 0 rather than inventing a failure code keeps this
  // family's "no new failure codes" position true; see the header.
  if (kind < 0 || kind >= ZD_FIN_KIND_COUNT) return 0;
  return atomic_load(&zd_fin_counts[kind]);
}

FFI_PLUGIN_EXPORT int zd_fin_last_on_main(int kind) {
  if (kind < 0 || kind >= ZD_FIN_KIND_COUNT) return ZD_FIN_ON_MAIN_UNOBSERVED;
  return atomic_load(&zd_fin_on_main[kind]);
}

// ---------------------------------------------------------------------------
// Last-error capture (F12, UNSTABLE) -- INTO CALLER-SUPPLIED STORAGE
// ---------------------------------------------------------------------------
//
// zc_get_last_error fills a BORROWED/transient view into zenoh's per-thread
// ERROR_DESCRIPTION (never emptied; only report_error! overwrites it). We copy
// it, immediately after the failing call, into storage THE CALLER SUPPLIED --
// so the detail travels with the call and is never read back afterwards.
//
// ⛔ WHAT THIS REPLACED, AND WHY IT IS A REPLACEMENT RATHER THAN A REPAIR.
// The previous shape was a durable _Thread_local buffer plus an exported
// reader, which Dart called at the throw site. (The reader's name is
// deliberately not spelled here: an identifier sweep for the deleted mechanism
// should return nothing outside the cells that assert its absence.) It was
// measured returning ANOTHER OPERATION'S message 249 times out of 300 when the
// read straddled an event-loop turn
// (development/independent/concurrency-reappraisal-20260827.md:118): the VM
// migrates an isolate between OS threads, so the read landed on a thread that
// had never made the call. Pinning the isolate to its thread was measured NOT
// to fix it -- 255 of 300 migrations happened anyway.
//
// No sequence check or identity stamp closes it either: a read carries no
// identity linking it to a capture, so it cannot distinguish MY capture from a
// foreign one that is both globally latest and collocated with my thread. The
// only shape with no such gap is one with no read at all, which is this one.
//
// The clear-on-entry discipline is gone with the buffer it guarded. Its job --
// "the buffer is empty-or-mine" -- is now done by the wrappers writing
// *err_len = 0 before the call, into the caller's own out-parameter, which no
// other caller can observe.

// ---------------------------------------------------------------------------
// THE ENRICHMENT SURFACE, AND WHY IT IS FENCED
// ---------------------------------------------------------------------------
//
// The definition comes BEFORE the count. An enriched site is a throw or post
// site in package/lib whose exception carries canon's own text for the failure
// being reported. TWO mechanisms produce one, and the one-mechanism definition
// is blind to the second:
//
//   (a) the enriching factory, called where the detail came back from the
//       failing call in caller-supplied storage -- the five entries below;
//   (b) the offloaded open's POST, where the worker captures and marshals the
//       detail with the post. It never calls the factory.
//
// Census, measured, two disjoint patterns (the plain form cannot match the
// factory form -- the `.` sits between them), each with the awk form that
// produced it:
//
//   find package/lib -name '*.dart' | xargs \
//     awk '{n+=gsub(/ZenohException\(/,"")} END{print n+0}'            -> 105
//   find package/lib -name '*.dart' | xargs \
//     awk '{n+=gsub(/ZenohException\.enriched\(/,"")} END{print n+0}'  ->   4
//
// The 4 is 3 call sites plus the factory's own declaration; the declaration is
// not a site, and the two numbers are not a subset relation.
//
// ⛔ WIDENING THE SURFACE REQUIRES DECIDING REDACTION FIRST. Canon echoes the
// offending config value and its surrounding source line -- adjacent intact
// secrets included -- and its json5 parser prints a caret under the offending
// token. That is the cost side of every proposal to enrich more sites, and it
// is a separate bar from the wrong-attribution defect the mechanism above
// closed. Fixing one does not license the other. A general redactor is not
// implementable at this seam: the shim receives ONE OPAQUE STRING with no
// structure to redact against, and a partial redactor manufactures confidence.
//
// Deliberate non-adoptions, recorded rather than silent: zd_scout's path was
// verified enrichment-eligible in an earlier unit and is deliberately not
// adopted; zd_config_to_string's capture was removed rather than promoted.

// Copies zc_get_last_error's BORROWED view into the CALLER's storage.
//
// Call IMMEDIATELY after a failing call, on the thread that made it. Never a
// deferred read: there is nothing durable left to read from.
//
// *out_len is set on every path, including the compiled-out one -- so a caller
// on the `stable` variant reads 0 rather than an uninitialised int. That is
// the whole `stable` behaviour: an honest absence, not a degraded value.
//
// Not unstable-guarded as a FUNCTION (the wrappers call it on both variants);
// only its body is, exactly as the exported reader used to be. Clamps to
// ZD_LAST_ERROR_CAP - 1 whatever out_cap says, so the documented chain holds
// no matter how large a buffer a caller hands in.
static void _zd_capture_last_error(uint8_t* out_buf, int out_cap,
                                   int* out_len) {
  if (out_len != NULL) *out_len = 0;
#if defined(Z_FEATURE_UNSTABLE_API)
  if (out_buf == NULL || out_cap <= 1) return;
  z_view_string_t view;
  zc_get_last_error(&view);
  const z_loaned_string_t* s = z_view_string_loan(&view);
  size_t len = z_string_len(s);
  const char* data = z_string_data(s);
  size_t room = (size_t)out_cap - 1;
  if (room > ZD_LAST_ERROR_CAP - 1) room = ZD_LAST_ERROR_CAP - 1;
  if (len > room) len = room;
  memcpy(out_buf, data, len);
  out_buf[len] = '\0';
  if (out_len != NULL) *out_len = (int)len;
#else
  (void)out_buf;
  (void)out_cap;
#endif
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_config_sizeof(void) {
  return sizeof(z_owned_config_t);
}

FFI_PLUGIN_EXPORT int zd_config_default(z_owned_config_t* config) {
  return z_config_default(config);
}

// The five detail-carrying config entries. Each writes *err_len before the
// call and fills the caller's buffer only on failure, so the out-length is
// defined on every path and nothing durable survives the return.

FFI_PLUGIN_EXPORT int zd_config_insert_json5(
    z_owned_config_t* config, const char* key, const char* value,
    uint8_t* err_buf, int err_cap, int* err_len) {
  if (err_len != NULL) *err_len = 0;
  z_loaned_config_t* loaned = z_config_loan_mut(config);
  int rc = zc_config_insert_json5(loaned, key, value);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

FFI_PLUGIN_EXPORT int zd_config_from_str(
    z_owned_config_t* config, const char* s,
    uint8_t* err_buf, int err_cap, int* err_len) {
  if (err_len != NULL) *err_len = 0;
  int rc = zc_config_from_str(config, s);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

FFI_PLUGIN_EXPORT int zd_config_from_file(
    z_owned_config_t* config, const char* path,
    uint8_t* err_buf, int err_cap, int* err_len) {
  if (err_len != NULL) *err_len = 0;
  int rc = zc_config_from_file(config, path);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

FFI_PLUGIN_EXPORT int zd_config_from_env(
    z_owned_config_t* config,
    uint8_t* err_buf, int err_cap, int* err_len) {
  if (err_len != NULL) *err_len = 0;
  int rc = zc_config_from_env(config);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

FFI_PLUGIN_EXPORT int zd_config_get(const z_owned_config_t* config,
                                    const char* key, z_owned_string_t* out,
                                    uint8_t* err_buf, int err_cap,
                                    int* err_len) {
  if (err_len != NULL) *err_len = 0;
  const z_loaned_config_t* loaned = z_config_loan(config);
  int rc = zc_config_get_from_str(loaned, key, out);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

// ⛔ NOT detail-carrying. It was wired to the deleted capture and nothing ever
// read the result. Promoting it would widen the enrichment surface to a call
// whose input is the whole rendered config; its Dart site is Object.toString(),
// which must not throw and so has no throw to enrich.
FFI_PLUGIN_EXPORT int zd_config_to_string(const z_owned_config_t* config,
                                          z_owned_string_t* out) {
  const z_loaned_config_t* loaned = z_config_loan(config);
  // rc-checked (F12): canon/cpp leaves zc_config_to_string's rc unchecked; we
  // check it so a serialization failure surfaces rather than yielding garbage.
  return zc_config_to_string(loaned, out);
}

FFI_PLUGIN_EXPORT void zd_config_drop(z_owned_config_t* config) {
  z_config_drop(z_config_move(config));
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_session_sizeof(void) {
  return sizeof(z_owned_session_t);
}

FFI_PLUGIN_EXPORT int zd_open_session(z_owned_session_t* session,
                                      z_owned_config_t* config) {
  return z_open(session, z_config_move(config), NULL);
}

FFI_PLUGIN_EXPORT const z_loaned_session_t* zd_session_loan(
    const z_owned_session_t* session) {
  return z_session_loan(session);
}

// --- Offloaded open ----------------------------------------------------------
//
// z_open BLOCKS for a caller-controlled duration -- measured 505 ms against a
// configured-but-unreachable endpoint and 3005 ms for a client-mode failure at
// the pinned 1.8.0. Called synchronously it freezes the calling isolate for
// that whole window (0 timer ticks out of a possible 20, measured). So it runs
// on a shim-owned detached thread and the wrapper returns immediately, exactly
// the shape zd_scout uses.
//
// THE rc CONTRACT. zd_open_session_async's return means "DID IT START", not
// "did it succeed":
//
//   0                     the worker started; EXACTLY ONE post will arrive
//   12  ZD_OPEN_EALLOC    a heap allocation failed; nothing started
//   13  ZD_OPEN_ETHREAD   pthread_create failed; nothing started
//
// Non-zero therefore means NO post is coming, and Dart must throw rather than
// await a future that can never complete.
//
// The two codes live in canon-free POSITIVE space, and 12/13 specifically:
// canon's own positive returns are 1 (Z_CHANNEL_DISCONNECTED) and 2
// (Z_CHANNEL_NODATA), and this shim already uses 10 and 11 elsewhere.
//   * 10 is UNREACHABLE here -- it is the capacity-argument rejection, and
//     this entry takes no capacity argument.
//   * 11 is DELIBERATELY NOT REUSED. reply_channel_alloc_harness.dart:18 opens
//     a session under the malloc injector and its driver asserts code == 11
//     from zd_get_channel; reusing it here would let a green report come from
//     the wrong site.
// canon's bare -1 (Z_EINVAL) is NOT copied from the zd_scout exemplar -- an
// allocation failure is not an invalid argument.
//
// THE DELIVERY CHANNEL DISCRIMINATES, AND THE SIGN CONFIRMS IT:
//   a START failure is a synchronous throw carrying a POSITIVE code;
//   a CANON failure is a rejected future carrying canon's NEGATIVE code.

#define ZD_OPEN_EALLOC 12
#define ZD_OPEN_ETHREAD 13

/// Worker block (block A): everything the background z_open can still reach
/// once zd_open_session_async has returned.
///
/// All of it is heap-owned. A wrapper stack local would be a use-after-return
/// the moment the call returns ahead of the open -- the move macros are pure
/// pointer casts, not copies, so they hand the callee a pointer into the
/// caller's frame.
typedef struct {
  z_owned_config_t config;
  /// Block B: the session slot itself, shim-malloc'd so its lifetime is not
  /// tied to this block's. On failure the worker frees it before posting; on
  /// success its address crosses to Dart and the shim frees it at
  /// zd_session_close_drop.
  z_owned_session_t* session;
  Dart_Port_DL dart_port;
} zd_open_worker_t;

/// Detached worker: runs the blocking z_open off the caller's isolate, posts
/// exactly once, and exits through a SINGLE path -- which is what "exactly one
/// post, exactly one free" rests on. Read the function bottom-up: there is one
/// `return`, and every branch above it falls through to the same post + free.
static void* _zd_open_worker(void* arg) {
  zd_open_worker_t* w = (zd_open_worker_t*)arg;

  z_result_t rc = z_open(w->session, z_config_move(&w->config), NULL);

  // The failure detail is captured HERE, on this thread, immediately after the
  // failing call, and TRAVELS WITH THE POST. It is never read back later.
  //
  // detail_buf is a stack local: storage local to this call, owned by the
  // frame that made the failing call and gone when the frame is. Nothing
  // outside this invocation can name it, so no other operation's text can
  // reach this post and this post's text cannot reach anyone else. That is the
  // same property the five config entries get from caller-supplied storage,
  // obtained here without a caller to supply it.
  //
  // Its content is marshalled into the post BEFORE this frame returns (a few
  // lines down), so the pointer never outlives the buffer.
  uint8_t detail_buf[ZD_LAST_ERROR_CAP];
  int detail_n = 0;
  const char* detail = NULL;
  size_t detail_len = 0;
  if (rc != 0) {
    _zd_capture_last_error(detail_buf, (int)sizeof(detail_buf), &detail_n);
    if (detail_n > 0) {
      detail = (const char*)detail_buf;
      detail_len = (size_t)detail_n;
    }
  }

  int64_t session_ptr = 0;
  if (rc == 0) {
    session_ptr = (int64_t)(intptr_t)w->session;
  } else {
    // Canon failure: nothing escapes. The session slot is released by the
    // worker BEFORE the post, and 0 goes over the wire in its place, so Dart
    // never sees an address it could construct a Session around.
    free(w->session);
  }

  Dart_CObject c_rc;
  c_rc.type = Dart_CObject_kInt64;
  c_rc.value.as_int64 = (int64_t)rc;

  Dart_CObject c_session;
  c_session.type = Dart_CObject_kInt64;
  c_session.value.as_int64 = session_ptr;

  // Length-carried, never Dart_CObject_kString: a kString truncates at an
  // interior NUL, which is the seam this repo already closed on the
  // parameters path.
  Dart_CObject c_detail;
  if (detail != NULL) {
    _zd_str_to_cobject(detail, detail_len, &c_detail);
  } else {
    c_detail.type = Dart_CObject_kNull;
  }

  Dart_CObject* elements[3] = {&c_rc, &c_session, &c_detail};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 3;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(w->dart_port, &c_array)) {
    // Port closed: no Dart future is still waiting. On the success path this
    // strands the session block, but the alternative -- closing it here --
    // would race a Dart side that may still hold the address. Dart closes its
    // port only after completing, so this is unreachable in practice.
  }

  free(w);
  return NULL;
}

FFI_PLUGIN_EXPORT int zd_open_session_async(z_owned_config_t* config,
                                            int64_t dart_port) {
  // Take the caller's config content into our own storage FIRST, ahead of
  // every fallible step -- same discipline as zd_scout, and load-bearing for
  // the same two reasons: Dart frees its block as soon as this returns, which
  // is now before z_open runs; and taking it ahead of anything that can fail
  // makes the Dart-side markConsumed unconditional, with no pre-move early
  // return left for the caller to distinguish.
  z_owned_config_t taken;
  if (config != NULL) {
    z_config_take(&taken, z_config_move(config));
  } else {
    z_result_t rc = z_config_default(&taken);
    if (rc != 0) return (int)rc;
  }

  zd_open_worker_t* w = (zd_open_worker_t*)malloc(sizeof(zd_open_worker_t));
  if (!w) {
    z_config_drop(z_config_move(&taken));
    return ZD_OPEN_EALLOC;
  }

  w->session = (z_owned_session_t*)malloc(sizeof(z_owned_session_t));
  if (!w->session) {
    z_config_drop(z_config_move(&taken));
    free(w);
    return ZD_OPEN_EALLOC;
  }

  w->config = taken;  // POD struct copy; `taken` is dead from here on
  w->dart_port = (Dart_Port_DL)dart_port;

  pthread_t tid;
  if (pthread_create(&tid, NULL, _zd_open_worker, w) != 0) {
    // Nothing started. Release everything taken and post NOTHING -- the
    // non-zero return tells Dart no post will ever arrive.
    z_config_drop(z_config_move(&w->config));
    free(w->session);
    free(w);
    return ZD_OPEN_ETHREAD;
  }
  pthread_detach(tid);

  return 0;
}

/// Closes and frees a session block that zd_open_session_async allocated.
///
/// Takes uint8_t* rather than z_owned_session_t* DELIBERATELY, and the
/// asymmetry with its sibling zd_close_session is the point. That one takes a
/// typed pointer because DART allocates the slot and knows its shape. This
/// block is SHIM-owned: its address crosses to Dart as a plain kInt64 and
/// comes back as an opaque block pointer, which is exactly the shape
/// zd_query_drop(uint8_t* query) already uses in this header.
///
/// Allocator-side frees: the shim malloc'd it, so the shim frees it. Dart must
/// never calloc.free this address.
FFI_PLUGIN_EXPORT void zd_session_close_drop(uint8_t* session) {
  z_owned_session_t* s = (z_owned_session_t*)session;
  // Same best-effort teardown as zd_close_session: the drop is idempotent and
  // must run even if close reported an error.
  z_result_t rc = z_close(z_session_loan_mut(s), NULL);
  (void)rc;
  z_session_drop(z_session_move(s));
  free(s);
}

FFI_PLUGIN_EXPORT void zd_close_session(z_owned_session_t* session) {
  // rc-hygiene (F12): best-effort teardown. Capture z_close's rc but proceed
  // to z_session_drop regardless — the drop is idempotent and must run to free
  // the owned handle even if close reported an error, preserving the existing
  // idempotent-close semantics.
  z_result_t rc = z_close(z_session_loan_mut(session), NULL);
  (void)rc;
  z_session_drop(z_session_move(session));
}

// Returns 1 if the session is closed, 0 if open.
FFI_PLUGIN_EXPORT int8_t zd_session_is_closed(
    const z_loaned_session_t* session) {
  return z_session_is_closed(session) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_bytes_sizeof(void) {
  return sizeof(z_owned_bytes_t);
}

FFI_PLUGIN_EXPORT int zd_bytes_copy_from_buf(z_owned_bytes_t* bytes,
                                             const uint8_t* data, size_t len) {
  return z_bytes_copy_from_buf(bytes, data, len);
}

FFI_PLUGIN_EXPORT const z_loaned_bytes_t* zd_bytes_loan(
    const z_owned_bytes_t* bytes) {
  return z_bytes_loan(bytes);
}

FFI_PLUGIN_EXPORT size_t zd_bytes_len(const uint8_t* bytes) {
  const z_owned_bytes_t* owned = (const z_owned_bytes_t*)bytes;
  const z_loaned_bytes_t* loaned = z_bytes_loan(owned);
  return z_bytes_len(loaned);
}

FFI_PLUGIN_EXPORT int8_t zd_bytes_to_buf(const uint8_t* bytes,
                                          uint8_t* out, size_t capacity) {
  const z_owned_bytes_t* owned = (const z_owned_bytes_t*)bytes;
  const z_loaned_bytes_t* loaned = z_bytes_loan(owned);
  z_bytes_reader_t reader = z_bytes_get_reader(loaned);
  // Check the reader rc: on a short read (fewer bytes than requested) the
  // tail of `out` would otherwise stay uninitialized. Zero-fill the untouched
  // tail so the caller never reads garbage. (No exported signature change --
  // the int8_t return is preserved.)
  size_t read_len = z_bytes_reader_read(&reader, out, capacity);
  if (read_len < capacity) {
    memset(out + read_len, 0, capacity - read_len);
  }
  return 0;
}

FFI_PLUGIN_EXPORT void zd_bytes_drop(z_owned_bytes_t* bytes) {
  z_bytes_drop(z_bytes_move(bytes));
}

FFI_PLUGIN_EXPORT int8_t zd_bytes_clone(uint8_t* dst, const uint8_t* src) {
  z_owned_bytes_t* dst_owned = (z_owned_bytes_t*)dst;
  const z_owned_bytes_t* src_owned = (const z_owned_bytes_t*)src;
  const z_loaned_bytes_t* loaned = z_bytes_loan(src_owned);
  z_bytes_clone(dst_owned, loaned);
  return 0;
}

// ---------------------------------------------------------------------------
// Owned String
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_string_sizeof(void) {
  return sizeof(z_owned_string_t);
}

FFI_PLUGIN_EXPORT const z_loaned_string_t* zd_string_loan(
    const z_owned_string_t* str) {
  return z_string_loan(str);
}

FFI_PLUGIN_EXPORT const char* zd_string_data(const z_loaned_string_t* str) {
  return z_string_data(str);
}

FFI_PLUGIN_EXPORT size_t zd_string_len(const z_loaned_string_t* str) {
  return z_string_len(str);
}

FFI_PLUGIN_EXPORT void zd_string_drop(z_owned_string_t* str) {
  z_string_drop(z_string_move(str));
}

// ---------------------------------------------------------------------------
// KeyExpr
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_view_keyexpr_sizeof(void) {
  return sizeof(z_view_keyexpr_t);
}

FFI_PLUGIN_EXPORT int zd_view_keyexpr_from_substr(z_view_keyexpr_t* ke,
                                                  const char* expr,
                                                  size_t len) {
  return z_view_keyexpr_from_substr(ke, expr, len);
}

FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_view_keyexpr_loan(
    const z_view_keyexpr_t* ke) {
  return z_view_keyexpr_loan(ke);
}

FFI_PLUGIN_EXPORT void zd_keyexpr_as_view_string(
    const z_loaned_keyexpr_t* ke, z_view_string_t* out) {
  z_keyexpr_as_view_string(ke, out);
}

FFI_PLUGIN_EXPORT bool zd_keyexpr_intersects(const z_loaned_keyexpr_t* a,
                                             const z_loaned_keyexpr_t* b) {
  return z_keyexpr_intersects(a, b);
}

FFI_PLUGIN_EXPORT bool zd_keyexpr_includes(const z_loaned_keyexpr_t* a,
                                           const z_loaned_keyexpr_t* b) {
  return z_keyexpr_includes(a, b);
}

FFI_PLUGIN_EXPORT bool zd_keyexpr_equals(const z_loaned_keyexpr_t* a,
                                         const z_loaned_keyexpr_t* b) {
  return z_keyexpr_equals(a, b);
}

FFI_PLUGIN_EXPORT size_t zd_keyexpr_sizeof(void) {
  return sizeof(z_owned_keyexpr_t);
}

FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_keyexpr_loan(
    const z_owned_keyexpr_t* ke) {
  return z_keyexpr_loan(ke);
}

FFI_PLUGIN_EXPORT void zd_keyexpr_drop(z_owned_keyexpr_t* ke) {
  z_keyexpr_drop(z_keyexpr_move(ke));
}

FFI_PLUGIN_EXPORT void zd_keyexpr_clone(z_owned_keyexpr_t* dst,
                                        const z_loaned_keyexpr_t* src) {
  z_keyexpr_clone(dst, src);
}

FFI_PLUGIN_EXPORT int zd_keyexpr_from_substr(z_owned_keyexpr_t* out,
                                             const char* expr,
                                             size_t len) {
  return z_keyexpr_from_substr(out, expr, len);
}

FFI_PLUGIN_EXPORT int zd_declare_keyexpr(const z_loaned_session_t* session,
                                         z_owned_keyexpr_t* declared_out,
                                         const z_loaned_keyexpr_t* key_expr) {
  return z_declare_keyexpr(session, declared_out, key_expr);
}

FFI_PLUGIN_EXPORT int zd_undeclare_keyexpr(const z_loaned_session_t* session,
                                           z_owned_keyexpr_t* key_expr) {
  // z_keyexpr_move is a pointer cast, so `key_expr` must be caller-owned
  // storage that outlives this call -- it is: Dart callocs the slot and frees
  // it after this returns.
  return z_undeclare_keyexpr(session, z_keyexpr_move(key_expr));
}

FFI_PLUGIN_EXPORT int zd_keyexpr_concat(z_owned_keyexpr_t* out,
                                        const z_loaned_keyexpr_t* left,
                                        const char* right_start,
                                        size_t right_len) {
  return z_keyexpr_concat(out, left, right_start, right_len);
}

FFI_PLUGIN_EXPORT int zd_keyexpr_join(z_owned_keyexpr_t* out,
                                      const z_loaned_keyexpr_t* left,
                                      const z_loaned_keyexpr_t* right) {
  return z_keyexpr_join(out, left, right);
}

FFI_PLUGIN_EXPORT int zd_keyexpr_is_canon(const char* expr, size_t len) {
  // Canon's raw return code, not a bool. The shim never discards a return
  // code; collapsing rc == 0 to a bool is a public-API rendering decision and
  // lives in the Dart layer, where it is documented and testable.
  return z_keyexpr_is_canon(expr, len);
}

FFI_PLUGIN_EXPORT int zd_keyexpr_from_substr_autocanonize(
    z_owned_keyexpr_t* out, const char* expr, size_t* len) {
  return z_keyexpr_from_substr_autocanonize(out, expr, len);
}

FFI_PLUGIN_EXPORT int zd_keyexpr_canonize(char* buf, size_t* len) {
  // A pure passthrough, deliberately: the writable copy is made by the
  // marshalling layer above (Dart's `_copyToNative`), which already mallocs a
  // process-heap block it owns and releases. A shim-side copy would make the
  // shim own a block that escapes to Dart and would need its own drop entry.
  return z_keyexpr_canonize(buf, len);
}

// ---------------------------------------------------------------------------
// View String utilities
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_view_string_sizeof(void) {
  return sizeof(z_view_string_t);
}

FFI_PLUGIN_EXPORT const char* zd_view_string_data(const z_view_string_t* str) {
  const z_loaned_string_t* loaned = z_view_string_loan(str);
  return z_string_data(loaned);
}

FFI_PLUGIN_EXPORT size_t zd_view_string_len(const z_view_string_t* str) {
  const z_loaned_string_t* loaned = z_view_string_loan(str);
  return z_string_len(loaned);
}

// ---------------------------------------------------------------------------
// Put / Delete
// ---------------------------------------------------------------------------

/// Builds canon's encoding from the two INDEPENDENT length-carried channels.
///
/// R-2's contract, in one place, so the ten send exports cannot drift apart.
/// Both channels are length-carried because both domains admit an interior NUL
/// and canon carries one across the wire byte-exact -- `z_encoding_from_substr`
/// and `z_encoding_set_schema_from_substr` are canon's own length-carried
/// entries, and their strlen siblings would truncate there.
///
/// The three states, and why composition is NOT an alternative carriage:
///
///   mime == NULL                 no encoding at all; the caller leaves canon's
///                                option field untouched and `*out_set` is false
///   schema == NULL               no schema; the setter is never called
///   schema != NULL, len == 0     the PRESENT-BUT-EMPTY schema; the setter runs
///                                with length 0 and canon renders a bare
///                                trailing separator on a well-known id
///
/// Passing a Dart-composed "mime;schema" through the mime channel alone is
/// length-carried too, and it is still wrong: measured, it COLLAPSES
/// empty-schema onto absent for well-known ids ("text/plain;" renders
/// "text/plain") while preserving it for custom ones ("foo/bar;" renders
/// "foo/bar;"). The structured route collapses on the opposite half of the
/// domain -- a custom id's empty schema renders "foo/bar", equal to absent
/// under z_encoding_equals. Each route is a silent default substitution on one
/// half; only the structured one is what canon exposes, and it is the one B3
/// ruled for.
///
/// Returns 0 on success, or canon's own negative rc. On failure nothing is
/// left owned: a partially-built encoding is dropped here.
static z_result_t _zd_build_encoding(z_owned_encoding_t* out,
                                     const char* mime, size_t mime_len,
                                     const char* schema, size_t schema_len,
                                     bool* out_set) {
  *out_set = false;
  if (mime == NULL) {
    return 0;
  }
  z_result_t rc = z_encoding_from_substr(out, mime, mime_len);
  if (rc != 0) {
    return rc;
  }
  if (schema != NULL) {
    rc = z_encoding_set_schema_from_substr(z_loan_mut(*out), schema,
                                           schema_len);
    if (rc != 0) {
      z_encoding_drop(z_encoding_move(out));
      return rc;
    }
  }
  *out_set = true;
  return 0;
}

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
    int allowed_destination) {
  z_put_options_t opts;
  z_put_options_default(&opts);

  // Negative means "unspecified -- leave whatever z_put_options_default put
  // there". Every wire domain in play is non-negative (locality 0..2,
  // congestion 0..1 -- but see below, priority 1..7, bool 0/1), so -1 is
  // outside all of them. This is the criterion-B mechanism: an omitted option
  // must resolve to CANON's per-path default, never to one chosen here or in
  // Dart.
  //
  // THE CONGESTION DOMAIN IS NOT THE SAME ON BOTH BUILDS. It is 0..1 on a
  // stable build; BLOCK_FIRST (2) is declared only under
  // Z_FEATURE_UNSTABLE_API, where the domain becomes 0..2. The check below is
  // LOWER-BOUND ONLY, so a 2 arriving on a stable build would be cast into a
  // two-variant #[repr(C)] enum -- a discriminant outside it, which is
  // undefined behaviour, not a substitution. Nothing here bounds it: the
  // refusal lives in Dart, at the seven send entry points
  // (requireCongestionControlSupported in congestion_control.dart). A bound
  // here would have to be variant-aware at five cast sites and could only
  // report a return code, which is a worse diagnosis than the Dart guard's.
  if (congestion_control >= 0) {
    opts.congestion_control = (z_congestion_control_t)congestion_control;
  }
  if (priority >= 0) {
    opts.priority = (z_priority_t)priority;
  }
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }
  if (allowed_destination >= 0) {
    opts.allowed_destination = (z_locality_t)allowed_destination;
  }

  // z_timestamp_t is ALIGN(8). The incoming Dart pointer may be unaligned;
  // x86_64 tolerates unaligned u64 reads but Android/ARM can fault. memcpy the
  // 24 raw bytes into an 8-byte-aligned stack local (borrowed, valid through
  // the synchronous z_put below).
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  // Two independent length-carried channels (R-2); see _zd_build_encoding.
  // The rc is checked: a bad MIME or a non-UTF-8 schema must not silently
  // substitute canon's default.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    // z_put will not run, so the owned payload/attachment would otherwise
    // leak. Drop them here so this early-return matches the Dart caller's
    // unconditional markConsumed (gravestone) and frees native memory.
    z_bytes_drop(z_bytes_move(payload));
    if (attachment != NULL) {
      z_bytes_drop(z_bytes_move(attachment));
    }
    return enc_rc;
  }
  if (has_encoding) {
    opts.encoding = z_encoding_move(&owned_encoding);
  }
  if (attachment != NULL) {
    opts.attachment = z_bytes_move(attachment);
  }

  return z_put(session, keyexpr, z_bytes_move(payload), &opts);
}

FFI_PLUGIN_EXPORT int zd_delete(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    const uint8_t* timestamp,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination) {
  z_delete_options_t opts;
  z_delete_options_default(&opts);

  // Copy the raw 24 bytes into 8-byte-aligned stack storage (see zd_put).
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  // Negative means "unspecified" -- leave z_delete_options_default's value.
  if (congestion_control >= 0) {
    opts.congestion_control = (z_congestion_control_t)congestion_control;
  }
  if (priority >= 0) {
    opts.priority = (z_priority_t)priority;
  }
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }
  if (allowed_destination >= 0) {
    opts.allowed_destination = (z_locality_t)allowed_destination;
  }

  return z_delete(session, keyexpr, &opts);
}

// ---------------------------------------------------------------------------
// Subscriber
// ---------------------------------------------------------------------------

/// Context struct passed to the closure callbacks.
typedef struct {
  Dart_Port_DL dart_port;
  /// Seed [10a]: when non-zero, `_zd_sample_callback` clones the LOANED
  /// payload into a stack `z_owned_bytes_t` and posts its `sizeof` byte image
  /// as element 9, TRANSFERRING that clone to Dart. Zero posts kNull there and
  /// costs nothing. Every site that mallocs this struct sets the field
  /// explicitly -- `malloc` does not zero it, and an uninitialised value here
  /// would retain on a surface nobody asked to retain on.
  int retain_payload;
} zd_subscriber_context_t;

/// What a bytes->CObject conversion did, because "it worked" is not a
/// two-valued question.
///
/// ⛔ THE THIRD STATE IS THE POINT OF THIS ENUM. It used to be a `bool`
/// meaning "is there a slice to drop", and a FAILED conversion shared the
/// `false` arm with a legitimately EMPTY value -- so a failure was posted as a
/// zero-length success, on every receive surface, with no error signal
/// anywhere. Empty and failed are different answers and now have different
/// values.
typedef enum {
  /// Nothing to convert: the value is legitimately empty. Post length 0.
  ZD_BYTES_EMPTY = 0,
  /// Converted. `slice` is live and the caller MUST drop it after the post.
  ZD_BYTES_SLICE = 1,
  /// Canon refused the conversion. `obj` carries canon's rc as an int64 and
  /// there is NO slice to drop.
  ZD_BYTES_FAILED = 2,
} zd_bytes_conv_t;

/// Fills `obj` with byte-faithful Uint8 typed data extracted from `bytes`.
///
/// Uses z_bytes_to_slice, which flattens fragments and never validates
/// UTF-8 — unlike z_bytes_to_string, which writes a NULL-data gravestone
/// on invalid UTF-8 (corrupting binary payloads). Empty bytes post
/// length=0 with a non-NULL static buffer, because Dart_PostCObject_DL
/// rejects NULL typed-data values (delete samples must keep delivering).
///
/// ⛔ ON FAILURE `obj` BECOMES AN INT64 CARRYING CANON'S RC, not typed data.
/// A bytes slot is never legitimately an integer, so the Dart side can tell
/// the two apart without a new array element and without a sentinel value
/// inside the bytes. The rc is CANON'S OWN -- no binding code is minted for
/// this, because there is no rc channel here to allocate into and inventing
/// one would put a number on the wire that means nothing to anybody.
///
/// ⚠️ The failure branch is UNREACHABLE at the pinned zenoh-c:
/// `extern/zenoh-c/src/zbytes.rs:144-152` returns Z_OK unconditionally, from
/// a single definition. It is driven by an LD_PRELOAD interposer
/// (`package/test/helpers/slice_fail_injector.c`), which is why the branch is
/// tested rather than merely written.
static zd_bytes_conv_t _zd_bytes_to_cobject(const z_loaned_bytes_t* bytes,
                                            Dart_CObject* obj,
                                            z_owned_slice_t* slice) {
  size_t len = 0;
  const uint8_t* data = (const uint8_t*)"";
  zd_bytes_conv_t outcome = ZD_BYTES_EMPTY;
  if (z_bytes_len(bytes) > 0) {
    z_result_t rc = z_bytes_to_slice(bytes, slice);
    if (rc == 0) {
      outcome = ZD_BYTES_SLICE;
      const z_loaned_slice_t* loaned = z_slice_loan(slice);
      len = z_slice_len(loaned);
      data = z_slice_data(loaned);
    } else {
      // The value existed and could not be converted. Say so.
      obj->type = Dart_CObject_kInt64;
      obj->value.as_int64 = (int64_t)rc;
      return ZD_BYTES_FAILED;
    }
  }
  obj->type = Dart_CObject_kTypedData;
  obj->value.as_typed_data.type = Dart_TypedData_kUint8;
  obj->value.as_typed_data.length = (intptr_t)len;
  obj->value.as_typed_data.values = (uint8_t*)data;
  return outcome;
}

// Channel-kind dispatch codes. THESE ARE OURS, NOT CANON'S: canon has no
// channel-kind enum at all -- it ships two separately-named constructor pairs
// (z_ring_channel_sample_new / z_fifo_channel_sample_new) over two distinct
// handler types, and the choice is made by which symbol you call. Dart cannot
// select a C symbol at run time across the FFI seam, so the kind crosses as an
// int and every pull entry dispatches on it here.
//
// The set is CLOSED and is produced only by our own `ChannelKind` enum, never
// by a remote peer, so it is not untrusted input. Anything that is not
// ZD_CHANNEL_FIFO is treated as ring -- the shipped default, and the value a
// zeroed slot would carry.
#define ZD_CHANNEL_RING 0
#define ZD_CHANNEL_FIFO 1

// Shim-originated return codes on the DECLARE channel. They are POSITIVE, and
// that is a fidelity decision rather than a style one: canon owns 0-and-
// negative there (`Z_EINVAL -1`, `Z_EPARSE -2` in zenoh_concrete.h, both
// emittable by z_declare_subscriber), so a shim-owned -1 would squat on a live
// canon code and let a canon EINVAL masquerade as our allocation failure --
// the same rc-conflation this seed exists to cure, one layer down. The
// positive space is entirely free on this channel. Low positives 1 and 2 stay
// reserved repo-wide for canon's channel-state meanings, so ours start at 10.
//
// ⚠️ This does NOT disturb zd_pull_subscriber_try_recv's -1, which stays:
// canon's recv family provably emits no negatives (zero Z_E* references in
// zenoh-c's src/closures/, every implementation a total 2- or 3-arm match), so
// on THAT channel the negative space is genuinely free. The two entries differ
// because their canon contracts differ, not by accident.
#define ZD_DECLARE_ECAPACITY 10
#define ZD_DECLARE_EALLOC 11

// (Defined here rather than beside the pull-subscriber block they were
// written for: three channel columns now dispatch on them, and the query
// column sits earlier in this file than the sample column does.)

// ---------------------------------------------------------------------------
// The readiness tee: what makes an ASYNC recv() possible without a thread.
//
// Canon's blocking `z_*_handler_sample_recv` parks the calling thread until a
// sample arrives or the channel dies, and it is UNINTERRUPTIBLE -- there is no
// timeout or deadline variant anywhere in the API, and the only way to release
// a parked call is to drop the producer closure. Hosting it on a shim-owned
// worker thread would therefore force close() to drop the SUBSCRIBER to
// unblock the worker, join it, and only then drop the handler -- a parked
// worker holding a loan on a handler another thread is dropping, which is
// undefined behaviour in canon and lands squarely in the v0.6.2 crash
// neighbourhood.
//
// So nothing blocks. Instead we interpose a closure of our own between zenoh
// and the channel:
//
//     zenoh delivery thread
//            |
//            v
//     tee _call  --(1) inner closure, SYNCHRONOUSLY, on this thread
//            |          (a full fifo blocks HERE -- canon's backpressure,
//            |           untouched, because we are standing exactly where
//            |           canon's own closure would have stood)
//            +--(2) if a waiter is armed: post ONE readiness ping to Dart
//
// Dart then does the consuming through the ordinary synchronous try_recv.
// CORRECTNESS RESTS ON try_recv; the ping only ever supplies *when to look*.
//
// WHY THE `armed` GATE IS MANDATORY, not an optimisation. An unconditional
// per-sample ping would queue one port message per delivered sample. On the
// RING kind the producer never blocks, so that queue grows without bound --
// memory not bounded by `capacity`, which is precisely the fake bound this
// design exists to avoid. With the gate, at most one ping is outstanding per
// armed waiter, and none at all when nobody is waiting.
//
// WHY THE DROP CALLBACK DOES NOT FREE THE CONTEXT. Freeing there would leave
// zd_pull_tee_arm able to touch freed memory whenever a SESSION dies
// underneath a live PullSubscriber: session close drops every remaining
// closure, so the drop callback fires while the Dart handle is still alive and
// may still arm. The free is therefore a separate designated entry,
// zd_pull_tee_drop, called from close() AFTER zd_subscriber_drop -- which
// zenoh-c 1.8.0 (#1221) guarantees blocks until executing callbacks are
// destroyed. That separation is the only thing standing between this design
// and a use-after-free.
//
// There is deliberately NO `producer_dead` flag here. Canon's DISCONNECTED is
// already sticky and synchronously observable through try_recv, so a mirror of
// it would be a second source of truth for a state canon already answers.
//
// ONE HEAD, THREE PAYLOADS. `dart_port` and `armed` are payload-agnostic, and
// so is the release, so the head sits first in every tee struct and the two
// exported entries (`zd_pull_tee_arm`, `zd_pull_tee_drop`) take it directly and
// serve the sample, reply and query columns alike. Only the inner closure and
// the `_on_call`/`_on_drop` statics are per payload type.
//
// WHY THE HEAD CARRIES A REFERENCE COUNT. On the sample and query columns the
// entity drop (`zd_subscriber_drop`, `zd_queryable_drop`) blocks until executing
// callbacks are destroyed (zenoh-c 1.8.0 #1221), which is what made
// "the drop callback does not free; the designated entry does" safe. THE REPLY
// COLUMN HAS NO ENTITY HANDLE: canon owns the closure and drops it at query
// completion, so a Dart-side release can race a delivery executing inside the
// tee on zenoh's own thread. Two owners -- canon's closure and the Dart handle
// -- an atomic count, last one frees. Note the NORMAL case inverts too: on
// every query the closure's drop fires BEFORE the handle is disposed, so the
// separation of drop-from-free is load-bearing on every single query rather
// than only when a session dies under a live handle.
typedef struct {
  Dart_Port_DL dart_port;
  // 1 = a Dart waiter wants exactly one ping. Cleared by whichever delivery
  // posts it, so a ping is never posted twice for one arming.
  atomic_int armed;
  // Starts at 2: canon's closure and the Dart handle. Whichever releases last
  // frees the block.
  atomic_int refcount;
} zd_tee_head_t;

typedef struct {
  zd_tee_head_t head;
  // Canon's own channel-producer closure, moved in at declaration. We call it;
  // we never inspect it.
  z_owned_closure_sample_t inner;
} zd_pull_tee_t;

typedef struct {
  zd_tee_head_t head;
  z_owned_closure_reply_t inner;
} zd_reply_tee_t;

typedef struct {
  zd_tee_head_t head;
  z_owned_closure_query_t inner;
} zd_query_tee_t;

/// Initialises a tee head: no waiter armed, two owners.
static void _zd_tee_head_init(zd_tee_head_t* head, int64_t dart_port) {
  head->dart_port = (Dart_Port_DL)dart_port;
  atomic_init(&head->armed, 0);
  atomic_init(&head->refcount, 2);
}

/// Posts one readiness ping if -- and only if -- a waiter is armed.
///
/// WHY THE GATE IS MANDATORY, not an optimisation. An unconditional per-delivery
/// ping would queue one port message per delivered value. On the RING kind the
/// producer never blocks, so that queue grows without bound -- memory not
/// bounded by `capacity`, which is precisely the fake bound this design exists
/// to avoid. With the gate, at most one ping is outstanding per arming, and
/// none at all when nobody is waiting.
static void _zd_tee_ping_if_armed(zd_tee_head_t* head) {
  int expected = 1;
  if (atomic_compare_exchange_strong(&head->armed, &expected, 0)) {
    Dart_CObject ping;
    ping.type = Dart_CObject_kInt64;
    ping.value.as_int64 = 1;
    if (!Dart_PostCObject_DL(head->dart_port, &ping)) {
      // Port closed: no Dart waiter is still listening. Nothing to reclaim --
      // and nothing is lost either, because the ping carries no data. The value
      // is in the channel and try_recv is what reads it.
    }
  }
}

/// Posts the completion sentinel, then releases this owner's reference.
static void _zd_tee_head_release(zd_tee_head_t* head, bool post_sentinel) {
  if (post_sentinel) {
    Dart_CObject sentinel;
    sentinel.type = Dart_CObject_kNull;
    if (!Dart_PostCObject_DL(head->dart_port, &sentinel)) {
      // Port already closed, so no Dart future is waiting on this sentinel.
    }
  }
  if (atomic_fetch_sub(&head->refcount, 1) == 1) {
    free(head);
  }
}

/// Tee call: deliver to the real channel first, then ping an armed waiter.
static void _zd_pull_tee_on_call(z_loaned_sample_t* sample, void* context) {
  zd_pull_tee_t* tee = (zd_pull_tee_t*)context;

  // (1) SYNCHRONOUS, on zenoh's delivery thread. This ordering is the whole
  // reason fifo backpressure survives the interposition: a full fifo blocks
  // inside this call, exactly as it would have blocked inside canon's own
  // closure. Posting before this would also introduce a wake-before-data race
  // that strands the sample until the next delivery.
  z_closure_sample_call(z_closure_sample_loan(&tee->inner), sample);

  // (2) Exactly-once per arming: only the delivery that wins the compare-
  // exchange posts. Everything else is silent.
  _zd_tee_ping_if_armed(&tee->head);
}

/// Tee drop: canon's designated release point for the closure.
///
/// Drops the inner closure -- so the handler observes DISCONNECTED exactly as
/// it would have without the interposition -- and posts the completion
/// sentinel UNCONDITIONALLY, the same sentinel-from-the-drop-callback
/// discipline _zd_scout_drop uses. It does NOT free the context; see the block
/// comment above.
static void _zd_pull_tee_on_drop(void* context) {
  zd_pull_tee_t* tee = (zd_pull_tee_t*)context;
  z_closure_sample_drop(z_closure_sample_move(&tee->inner));
  _zd_tee_head_release(&tee->head, true);
}

/// Reply tee call: deliver to the real channel first, then ping an armed
/// waiter. Identical discipline to the sample tee -- the synchronous inner call
/// is what leaves fifo backpressure untouched by the interposition.
static void _zd_reply_tee_on_call(z_loaned_reply_t* reply, void* context) {
  zd_reply_tee_t* tee = (zd_reply_tee_t*)context;
  z_closure_reply_call(z_closure_reply_loan(&tee->inner), reply);
  _zd_tee_ping_if_armed(&tee->head);
}

/// Reply tee drop: canon's designated release point for the closure.
///
/// On this column canon drops the closure at QUERY COMPLETION, with no entity
/// handle to serialise against -- so this release and the Dart handle's may run
/// in either order, and on the normal path this one runs FIRST. The reference
/// count in the head is what makes both orders safe.
static void _zd_reply_tee_on_drop(void* context) {
  zd_reply_tee_t* tee = (zd_reply_tee_t*)context;
  z_closure_reply_drop(z_closure_reply_move(&tee->inner));
  _zd_tee_head_release(&tee->head, true);
}

/// Query tee call: deliver to the real channel first, then ping an armed
/// waiter. Same discipline as the other two columns -- the synchronous inner
/// call is what leaves fifo backpressure untouched by the interposition, and on
/// this column that backpressure is what stalls the hosting session's inbound
/// query delivery while the channel sits full.
static void _zd_query_tee_on_call(z_loaned_query_t* query, void* context) {
  zd_query_tee_t* tee = (zd_query_tee_t*)context;
  z_closure_query_call(z_closure_query_loan(&tee->inner), query);
  _zd_tee_ping_if_armed(&tee->head);
}

/// Query tee drop: canon's designated release point for the closure.
static void _zd_query_tee_on_drop(void* context) {
  zd_query_tee_t* tee = (zd_query_tee_t*)context;
  z_closure_query_drop(z_closure_query_move(&tee->inner));
  _zd_tee_head_release(&tee->head, true);
}

FFI_PLUGIN_EXPORT void zd_pull_tee_arm(uint8_t* tee) {
  atomic_store(&((zd_tee_head_t*)tee)->armed, 1);
}

FFI_PLUGIN_EXPORT void zd_pull_tee_drop(uint8_t* tee) {
  // The Dart handle's side of the reference count, and the allocator's own side
  // of the seam: the shim malloc'd this block, so the shim frees it -- when the
  // last owner lets go. No sentinel is posted here: the Dart side is the caller,
  // and it has already completed any pending waiter itself.
  _zd_tee_head_release((zd_tee_head_t*)tee, false);
}

/// Fills `obj` with Uint8 typed data over the `len` bytes at `data`.
///
/// The counterpart of _zd_bytes_to_cobject for a value zenoh hands over as a
/// (pointer, length) string view rather than as z_loaned_bytes_t. Posting it
/// as typed data rather than as Dart_CObject_kString is what preserves an
/// interior NUL: a C string is measured with strlen at the Dart seam and
/// truncates there, and the key expression grammar permits an interior NUL --
/// canon carries one through declaration, matching and the wire byte-exact.
///
/// No allocation, and nothing for the caller to release: Dart_PostCObject_DL
/// COPIES typed data before it returns, and `data` borrows storage that
/// outlives the post (the sample, query or reply the callback was handed).
/// An empty value posts length 0 over a non-NULL static buffer, because
/// Dart_PostCObject_DL rejects NULL typed-data values.
static void _zd_str_to_cobject(const char* data, size_t len,
                               Dart_CObject* obj) {
  obj->type = Dart_CObject_kTypedData;
  obj->value.as_typed_data.type = Dart_TypedData_kUint8;
  obj->value.as_typed_data.length = (intptr_t)len;
  obj->value.as_typed_data.values =
      (uint8_t*)((data != NULL && len > 0) ? data : "");
}

/// Sample callback: extracts fields and posts to Dart via native port.
static void _zd_sample_callback(z_loaned_sample_t* sample, void* context) {
  zd_subscriber_context_t* ctx = (zd_subscriber_context_t*)context;

  // 1. Key expression as string
  z_view_string_t key_view;
  z_keyexpr_as_view_string(z_sample_keyexpr(sample), &key_view);
  const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
  size_t key_len = z_string_len(key_loaned);
  const char* key_data = z_string_data(key_loaned);

  // 2. Payload as bytes (byte-faithful; see _zd_bytes_to_cobject)
  const z_loaned_bytes_t* payload_loaned = z_sample_payload(sample);

  // 3. Kind as int
  z_sample_kind_t kind = z_sample_kind(sample);

  // 4. Attachment (nullable)
  const z_loaned_bytes_t* attachment = z_sample_attachment(sample);

  // 5. Encoding as string
  const z_loaned_encoding_t* encoding = z_sample_encoding(sample);
  z_owned_string_t encoding_str;
  z_encoding_to_string(encoding, &encoding_str);
  const z_loaned_string_t* enc_loaned = z_string_loan(&encoding_str);
  size_t enc_len = z_string_len(enc_loaned);
  const char* enc_data = z_string_data(enc_loaned);

  // Build Dart_CObject array: [keyexpr, payload, kind, attachment, encoding]
  // Length-carried (see _zd_str_to_cobject): the key expression borrows the
  // sample's own storage and needs no copy of ours, which also retires the
  // REMOTE-LENGTH-DRIVEN allocation this site used to have to guard.
  Dart_CObject c_keyexpr;
  _zd_str_to_cobject(key_data, key_len, &c_keyexpr);

  Dart_CObject c_payload;
  z_owned_slice_t payload_slice;
  zd_bytes_conv_t payload_conv =
      _zd_bytes_to_cobject(payload_loaned, &c_payload, &payload_slice);

  Dart_CObject c_kind;
  c_kind.type = Dart_CObject_kInt64;
  c_kind.value.as_int64 = (int64_t)kind;

  Dart_CObject c_attachment;
  z_owned_slice_t attachment_slice;
  zd_bytes_conv_t attachment_conv = ZD_BYTES_EMPTY;
  if (attachment != NULL) {
    attachment_conv =
        _zd_bytes_to_cobject(attachment, &c_attachment, &attachment_slice);
  } else {
    c_attachment.type = Dart_CObject_kNull;
  }

  // Length-carried, exactly like the key expression above. A z_encoding_t's
  // rendered MIME string is an arbitrary byte sequence -- canon builds one with
  // z_encoding_from_substr and carries an interior NUL across the wire
  // byte-exact -- so posting it as Dart_CObject_kString truncated it at the
  // Dart seam, where a C string is measured with strlen. That also retires the
  // REMOTE-LENGTH-DRIVEN allocation this site used to have to guard: `enc_data`
  // borrows `encoding_str`, which is declared at function scope and dropped in
  // the trailing cleanup, so it outlives the post.
  Dart_CObject c_encoding;
  _zd_str_to_cobject(enc_data, enc_len, &c_encoding);

  // 6. Timestamp (nullable): the raw 24-byte z_timestamp_t image, or kNull.
  // z_sample_timestamp returns NULL when the sample carries no timestamp.
  // The pointer is valid for the callback's duration and Dart_PostCObject_DL
  // copies the bytes before returning, so no malloc is needed (mirrors c_zid).
  Dart_CObject c_timestamp;
  const z_timestamp_t* ts = z_sample_timestamp(sample);
  if (ts != NULL) {
    c_timestamp.type = Dart_CObject_kTypedData;
    c_timestamp.value.as_typed_data.type = Dart_TypedData_kUint8;
    c_timestamp.value.as_typed_data.length = 24;
    c_timestamp.value.as_typed_data.values = (uint8_t*)ts;
  } else {
    c_timestamp.type = Dart_CObject_kNull;
  }

  // 7. Priority (1..7), 8. Congestion control (0/1), 9. Express (0/1).
  Dart_CObject c_priority;
  c_priority.type = Dart_CObject_kInt64;
  c_priority.value.as_int64 = (int64_t)z_sample_priority(sample);

  Dart_CObject c_congestion;
  c_congestion.type = Dart_CObject_kInt64;
  c_congestion.value.as_int64 = (int64_t)z_sample_congestion_control(sample);

  Dart_CObject c_express;
  c_express.type = Dart_CObject_kInt64;
  c_express.value.as_int64 = z_sample_express(sample) ? 1 : 0;

  // Seed [10a] element 9: the RETAINED payload handle.
  //
  // THIS ELEMENT TRANSFERS OWNERSHIP, which none of the other nine do. The
  // clone is taken into a STACK z_owned_bytes_t and its `sizeof` byte image is
  // posted as typed data, because Dart_PostCObject_DL copies typed data before
  // it returns -- so Dart ends up holding the struct bytes and the refcount
  // they carry, and the local is nulled on the delivered path so the cleanup
  // below cannot drop what Dart now owns.
  //
  // ZERO new shim allocations: the Dart side sizes its own slot from
  // zd_bytes_sizeof() at run time, so no block of ours crosses the seam and no
  // size class is added to this path. That is what keeps the 40-byte exact-size
  // injector on the reply receive path discriminating.
  z_owned_bytes_t retained_payload;
  bool has_retained = false;
  Dart_CObject c_retained;
  if (ctx->retain_payload) {
    z_bytes_clone(&retained_payload, payload_loaned);
    has_retained = true;
    c_retained.type = Dart_CObject_kTypedData;
    c_retained.value.as_typed_data.type = Dart_TypedData_kUint8;
    c_retained.value.as_typed_data.length = (intptr_t)sizeof(z_owned_bytes_t);
    c_retained.value.as_typed_data.values = (uint8_t*)&retained_payload;
  } else {
    c_retained.type = Dart_CObject_kNull;
  }

  Dart_CObject* elements[10] = {&c_keyexpr,   &c_payload,    &c_kind,
                                &c_attachment, &c_encoding,   &c_timestamp,
                                &c_priority,   &c_congestion, &c_express,
                                &c_retained};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 10;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
    // Port closed (the receiving isolate is gone, or Dart closed its
    // ReceivePort): the VM discards the message.
    //
    // ⛔ CORRECTED at seed [10a]. This comment used to read "This message ships
    // only COPIES, so the cost is exactly one lost sample and there is nothing
    // to reclaim". That is FALSE the moment retention is on: element 9
    // TRANSFERS an owned payload clone, and the only reference to it is the
    // image inside the message the VM just discarded. Reclaim it here or it is
    // orphaned with nothing left anywhere pointing at it -- the same shape
    // _zd_query_callback has always carried, now on this site too.
    //
    // The other nine elements are still copies and still cost one lost sample.
    if (has_retained) {
      z_bytes_drop(z_bytes_move(&retained_payload));
      has_retained = false;
    }
  } else if (has_retained) {
    // Delivered: Dart owns the clone now. Null the local so the trailing
    // cleanup, and any later reader of this frame, cannot drop it out from
    // under the Dart owner.
    z_internal_bytes_null(&retained_payload);
    has_retained = false;
  }

  // Cleanup
  if (payload_conv == ZD_BYTES_SLICE) {
    z_slice_drop(z_slice_move(&payload_slice));
  }
  z_string_drop(z_string_move(&encoding_str));
  if (attachment_conv == ZD_BYTES_SLICE) {
    z_slice_drop(z_slice_move(&attachment_slice));
  }
}

/// Drop callback: frees the context struct.
static void _zd_sample_drop(void* context) {
  free(context);
}

/// Drop callback that posts a null sentinel before freeing.
/// Used by background subscribers to signal stream completion when the
/// session closes and the background subscriber is dropped by zenoh-c.
static void _zd_sample_drop_with_sentinel(void* context) {
  zd_subscriber_context_t* ctx = (zd_subscriber_context_t*)context;
  Dart_CObject null_obj;
  null_obj.type = Dart_CObject_kNull;
  if (!Dart_PostCObject_DL(ctx->dart_port, &null_obj)) {
    // Port already closed, so the Dart side has stopped listening and cannot
    // be waiting on this sentinel. Nothing to reclaim; the context is freed
    // below on both paths.
  }
  free(context);
}

FFI_PLUGIN_EXPORT size_t zd_subscriber_sizeof(void) {
  return sizeof(z_owned_subscriber_t);
}

FFI_PLUGIN_EXPORT int zd_declare_subscriber(
    const z_loaned_session_t* session,
    z_owned_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    int allowed_origin,
    int retain_payload) {
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: the caller's opt-in. This is the one sample surface wired in
  // slice 2; the rest are opted in by their own later slice and pass 0 until
  // then. Explicit at every site, because malloc does not zero.
  ctx->retain_payload = retain_payload;

  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback, _zd_sample_drop, ctx);

  // `z_subscriber_options_t` is INTRODUCED here: this path passed a literal
  // NULL before, so there was no options struct on it at all. Negative means
  // "unspecified" -- leave z_subscriber_options_default's value (ANY).
  z_subscriber_options_t opts;
  z_subscriber_options_default(&opts);
  if (allowed_origin >= 0) {
    opts.allowed_origin = (z_locality_t)allowed_origin;
  }

  int rc = z_declare_subscriber(
      session, subscriber, keyexpr,
      z_closure_sample_move(&callback), &opts);

  if (rc != 0) {
    // NOT "the closure was not consumed" — that claim is inverted for
    // zenoh-c 1.x. canon takes the closure at ENTRY and drops it itself on a
    // fallible path (subscriber.rs:129), so this manual drop is a gravestone
    // no-op: z_closure_*_drop on an already-moved closure is defined and does
    // nothing. It is a deliberate backstop, kept so the release guarantee is
    // ours rather than a canon-version dependency.
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return rc;
}

FFI_PLUGIN_EXPORT void zd_subscriber_drop(z_owned_subscriber_t* subscriber) {
  z_subscriber_drop(z_subscriber_move(subscriber));
}

FFI_PLUGIN_EXPORT int8_t zd_declare_background_subscriber(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t dart_port,
    int allowed_origin,
    int retain_payload) {
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: explicit, because malloc does not zero. Slice 2 wires
  // the flag on zd_declare_subscriber only; every other sample surface
  // is opted in by its own later slice and retains nothing until then.
  ctx->retain_payload = retain_payload;

  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback,
                   _zd_sample_drop_with_sentinel, ctx);

  // `z_subscriber_options_t` is introduced here too (second of the three
  // literal-NULL sites), following the pattern zd_declare_subscriber set. Negative means
  // "unspecified" -- leave z_subscriber_options_default's value (ANY).
  z_subscriber_options_t opts;
  z_subscriber_options_default(&opts);
  if (allowed_origin >= 0) {
    opts.allowed_origin = (z_locality_t)allowed_origin;
  }

  int rc = z_declare_background_subscriber(
      session, key_expr,
      z_closure_sample_move(&callback), &opts);

  if (rc != 0) {
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return rc;
}

// ---------------------------------------------------------------------------
// Publisher
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_publisher_sizeof(void) {
  return sizeof(z_owned_publisher_t);
}

FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    int congestion_control,
    int priority,
    int8_t is_express,
    int allowed_destination) {
  z_publisher_options_t opts;
  z_publisher_options_default(&opts);

  // Two independent length-carried channels (R-2); see _zd_build_encoding.
  // No payload move here (declaration-time encoding), so a simple early-return
  // is safe.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    return enc_rc;
  }
  if (has_encoding) {
    opts.encoding = z_encoding_move(&owned_encoding);
  }
  if (congestion_control >= 0) {
    opts.congestion_control = (z_congestion_control_t)congestion_control;
  }
  if (priority >= 0) {
    opts.priority = (z_priority_t)priority;
  }
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }
  if (allowed_destination >= 0) {
    opts.allowed_destination = (z_locality_t)allowed_destination;
  }

  return z_declare_publisher(session, publisher, keyexpr, &opts);
}

FFI_PLUGIN_EXPORT const z_loaned_publisher_t* zd_publisher_loan(
    const z_owned_publisher_t* publisher) {
  return z_publisher_loan(publisher);
}

FFI_PLUGIN_EXPORT void zd_publisher_drop(z_owned_publisher_t* publisher) {
  z_publisher_drop(z_publisher_move(publisher));
}

FFI_PLUGIN_EXPORT int zd_publisher_put(
    const z_loaned_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    z_owned_bytes_t* attachment,
    const uint8_t* timestamp) {
  z_publisher_put_options_t opts;
  z_publisher_put_options_default(&opts);

  // z_timestamp_t is ALIGN(8). The incoming Dart pointer may be unaligned;
  // x86_64 tolerates unaligned u64 reads but Android/ARM can fault. memcpy the
  // 24 raw bytes into an 8-byte-aligned stack local (borrowed, valid through
  // the synchronous z_publisher_put below). opts.timestamp is a
  // const z_timestamp_t*, so pointing it at &ts_storage is fine.
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  // Two independent length-carried channels (R-2); see _zd_build_encoding.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    // z_publisher_put will not run, so the owned payload/attachment would
    // otherwise leak. Drop them here so this early-return matches the Dart
    // caller's unconditional markConsumed (gravestone) and frees native
    // memory. Mirrors zd_put's consume discipline.
    z_bytes_drop(z_bytes_move(payload));
    if (attachment != NULL) {
      z_bytes_drop(z_bytes_move(attachment));
    }
    return enc_rc;
  }
  if (has_encoding) {
    opts.encoding = z_encoding_move(&owned_encoding);
  }
  if (attachment != NULL) {
    opts.attachment = z_bytes_move(attachment);
  }

  return z_publisher_put(publisher, z_bytes_move(payload), &opts);
}

FFI_PLUGIN_EXPORT int zd_publisher_delete(
    const z_loaned_publisher_t* publisher,
    const uint8_t* timestamp) {
  z_publisher_delete_options_t opts;
  z_publisher_delete_options_default(&opts);

  // Copy the raw 24 bytes into 8-byte-aligned stack storage (see
  // zd_publisher_put). opts.timestamp is a const z_timestamp_t*.
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  return z_publisher_delete(publisher, &opts);
}

FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_publisher_keyexpr(
    const z_loaned_publisher_t* publisher) {
  return z_publisher_keyexpr(publisher);
}

/// Context struct for matching status callback.
typedef struct {
  Dart_Port_DL dart_port;
} zd_matching_context_t;

/// Matching status callback: posts matching status to Dart.
static void _zd_matching_status_callback(
    const z_matching_status_t* status, void* context) {
  zd_matching_context_t* ctx = (zd_matching_context_t*)context;

  Dart_CObject c_matching;
  c_matching.type = Dart_CObject_kInt64;
  c_matching.value.as_int64 = status->matching ? 1 : 0;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_matching)) {
    // Port closed: one matching-status transition is lost. Copies only —
    // nothing to reclaim.
  }
}

/// Drop callback for matching status context.
static void _zd_matching_drop(void* context) {
  free(context);
}

FFI_PLUGIN_EXPORT int zd_publisher_declare_background_matching_listener(
    const z_loaned_publisher_t* publisher,
    int64_t dart_port) {
  zd_matching_context_t* ctx =
      (zd_matching_context_t*)malloc(sizeof(zd_matching_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;

  z_owned_closure_matching_status_t callback;
  z_closure_matching_status(
      &callback, _zd_matching_status_callback, _zd_matching_drop, ctx);

  int rc = z_publisher_declare_background_matching_listener(
      publisher, z_closure_matching_status_move(&callback));

  if (rc != 0) {
    z_closure_matching_status_drop(z_closure_matching_status_move(&callback));
  }

  return rc;
}

FFI_PLUGIN_EXPORT int zd_publisher_get_matching_status(
    const z_loaned_publisher_t* publisher,
    int* matching) {
  z_matching_status_t status;
  int rc = z_publisher_get_matching_status(publisher, &status);
  if (rc == 0) {
    *matching = status.matching ? 1 : 0;
  }
  return rc;
}

// ---------------------------------------------------------------------------
// Info (Session identity)
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_id_sizeof(void) {
  return sizeof(z_id_t);
}

FFI_PLUGIN_EXPORT void zd_info_zid(const z_loaned_session_t* session,
                                   uint8_t* out_id) {
  z_id_t zid = z_info_zid(session);
  memcpy(out_id, zid.id, 16);
}

FFI_PLUGIN_EXPORT void zd_id_to_string(const uint8_t* id,
                                       z_owned_string_t* out) {
  z_id_t zid;
  memcpy(zid.id, id, 16);
  z_id_to_string(&zid, out);
}

// Context for ZID collection closure.
//
// The buffer grows by realloc INSIDE the closure, with capacity
// 0 -> 1 -> 2 -> 4 -> 8 ... -- verbatim the growth policy of our structural
// peer's own collector (`session.hxx:873-874`: a default-constructed
// `std::vector<Id>` with no reserve, and push_back in the closure). Two merits
// beyond parity: an EMPTY enumeration allocates nothing at all (the old shape
// calloc'd a flat 16 KiB per call whatever the answer was), and the common
// case of 0-4 peers never over-allocates.
//
// Growing inside a callback is safe here because canon's callback is invoked
// once per id, never concurrently, synchronously on the caller's thread, and
// is dropped before the enumeration function returns (`info.rs:123-133` --
// `.wait()` then a plain `for` loop). There is no re-entrancy and no thread
// to race.
typedef struct {
  uint8_t* buf;  // shim-owned, cap * 16 bytes; NULL while cap == 0
  size_t count;  // ids collected so far
  size_t cap;    // ids the buffer can hold
  int failed;    // 1 once a growth allocation has failed
} zd_zid_collect_context_t;

// Appends one id, growing the buffer when it is full.
//
// The growth allocation's size is chosen by the NETWORK -- one rung per
// connected peer -- which is exactly the case the FFI ownership rule singles
// out ("guard every malloc whose size a remote peer chose"). The callback is
// `void` and canon offers no early stop, so a failure cannot be signalled from
// here: it is recorded in the context, canon keeps calling, and the WRAPPER
// reads the flag after the enumeration returns. Nothing is silently truncated
// and Dart never copies from a half-populated buffer.
static void _zd_zid_collect_callback(const z_id_t* id, void* context) {
  zd_zid_collect_context_t* ctx = (zd_zid_collect_context_t*)context;
  // Once failed, stay failed: canon keeps calling for every remaining peer,
  // and retrying the same allocation each time would hammer the allocator on
  // a real OOM for no gain.
  if (ctx->failed) return;
  if (ctx->count == ctx->cap) {
    size_t next_cap = (ctx->cap == 0) ? 1 : ctx->cap * 2;
    // NEVER `ctx->buf = realloc(ctx->buf, ...)`: on failure that assignment
    // loses the live pointer, and the ids already collected leak.
    void* tmp = realloc(ctx->buf, next_cap * 16);
    if (!tmp) {
      ctx->failed = 1;
      return;
    }
    ctx->buf = (uint8_t*)tmp;
    ctx->cap = next_cap;
  }
  memcpy(ctx->buf + ctx->count * 16, id->id, 16);
  ctx->count++;
}

// The two enumerators differ only in which canon call they make.
typedef z_result_t (*zd_zid_enumerator_t)(const z_loaned_session_t*,
                                          struct z_moved_closure_zid_t*);

static int _zd_collect_zids(const z_loaned_session_t* session,
                            zd_zid_enumerator_t enumerate,
                            uint8_t** out_ids, size_t* out_count) {
  zd_zid_collect_context_t ctx = {NULL, 0, 0, 0};
  z_owned_closure_zid_t closure;
  z_closure_zid(&closure, _zd_zid_collect_callback, NULL, &ctx);
  z_result_t rc = enumerate(session, z_closure_zid_move(&closure));

  // ONE release branch covers BOTH failure arms. A canon rc != 0 arriving
  // after the closure has already collected ids would otherwise leave a shim
  // allocation unreleased on that control path -- and unreleasable by Dart
  // too, since its out-cell was never written. That is precisely what the FFI
  // ownership convention bars ("every heap allocation on either side of the
  // seam has a release on every control path"). Merging the arms also makes
  // their post-conditions identical (*out_ids == NULL, *out_count == 0), which
  // is what lets the Dart side's unconditional zd_zid_list_drop stay correct
  // with no case analysis.
  if (ctx.failed || rc != 0) {
    free(ctx.buf);
    *out_ids = NULL;
    *out_count = 0;
    // The shim's own failure is the one the caller can act on. Canon's arm has
    // no producer at this pin: both bodies end in an unconditional
    // `return result::Z_OK` (`info.rs:112`, `:132`).
    return ctx.failed ? 11 : (int)rc;
  }

  *out_ids = ctx.buf;
  *out_count = ctx.count;
  return 0;
}

FFI_PLUGIN_EXPORT int zd_info_routers_zid(const z_loaned_session_t* session,
                                          uint8_t** out_ids,
                                          size_t* out_count) {
  return _zd_collect_zids(session, z_info_routers_zid, out_ids, out_count);
}

FFI_PLUGIN_EXPORT int zd_info_peers_zid(const z_loaned_session_t* session,
                                        uint8_t** out_ids, size_t* out_count) {
  return _zd_collect_zids(session, z_info_peers_zid, out_ids, out_count);
}

FFI_PLUGIN_EXPORT void zd_zid_list_drop(uint8_t* ids) {
  free(ids);
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_timestamp_sizeof(void) {
  return sizeof(z_timestamp_t);
}

// Creates a uhlc timestamp from the session clock; writes the 24 raw bytes to
// out_ts. Returns the zenoh result code (0 = success). Caller MUST check it.
FFI_PLUGIN_EXPORT int zd_timestamp_new(const z_loaned_session_t* session,
                                       uint8_t* out_ts) {
  z_timestamp_t ts;  // stack, 8-byte aligned
  z_result_t rc = z_timestamp_new(&ts, session);
  if (rc != 0) return rc;
  memcpy(out_ts, &ts, 24);
  return rc;
}

// Reads the NTP64 unsigned-64 time from the 24 raw timestamp bytes.
FFI_PLUGIN_EXPORT uint64_t zd_timestamp_ntp64_time(const uint8_t* ts) {
  z_timestamp_t t;
  memcpy(&t, ts, 24);  // copy into aligned stack storage
  return z_timestamp_ntp64_time(&t);
}

// Reads the 16-byte ZenohId from the 24 raw timestamp bytes into out_id.
FFI_PLUGIN_EXPORT void zd_timestamp_id(const uint8_t* ts, uint8_t* out_id) {
  z_timestamp_t t;
  memcpy(&t, ts, 24);
  z_id_t id = z_timestamp_id(&t);
  memcpy(out_id, id.id, 16);
}

// ---------------------------------------------------------------------------
// Scout
// ---------------------------------------------------------------------------

/// Context struct for scout hello callback.
///
/// Owned by the hello closure and released from exactly one place: the
/// closure's drop callback (_zd_scout_drop). Nothing else may free or read it
/// once the closure has been handed to z_scout.
typedef struct {
  Dart_Port_DL dart_port;
  /// 0 suppresses the completion sentinel on drop. Set only on a synchronous
  /// failure path, where zd_scout returns non-zero and Dart is contractually
  /// told that no sentinel will ever arrive. Carrying the suppression in the
  /// context (rather than choosing between two drop callbacks) keeps a single
  /// release point on every path.
  int post_sentinel;
} zd_scout_context_t;

/// Hello callback: extracts fields and posts to Dart via native port.
static void _zd_scout_hello_callback(z_loaned_hello_t* hello, void* context) {
  zd_scout_context_t* ctx = (zd_scout_context_t*)context;

  // 1. Extract ZID (16 bytes)
  z_id_t zid = z_hello_zid(hello);

  // 2. Extract whatami
  z_whatami_t whatami = z_hello_whatami(hello);

  // 3. Extract locators, marshalled PER ELEMENT as a nested array of strings.
  //    A ';'-joined blob was lossy: a locator containing ';' was mis-split on
  //    the Dart side, and an empty locator set collapsed to a single empty
  //    string. Per-element marshalling keeps each locator byte-exact and makes
  //    a 0-element set distinct from a lone empty-string element.
  z_owned_string_array_t locators;
  z_hello_locators(hello, &locators);
  const z_loaned_string_array_t* locs_loaned = z_string_array_loan(&locators);
  size_t loc_count = z_string_array_len(locs_loaned);

  // Copy each locator into its own NUL-terminated C string (zenoh strings are
  // not NUL-terminated; Dart_CObject_kString needs a C string). Each becomes a
  // Dart_CObject string element of a nested Dart_CObject_kArray.
  Dart_CObject* loc_objs = NULL;
  Dart_CObject** loc_ptrs = NULL;
  char** loc_strs = NULL;
  if (loc_count > 0) {
    // REMOTE-LENGTH-DRIVEN: both loc_count and each locator's length come out
    // of the received Hello, so every allocation below is sized by the peer.
    loc_objs = (Dart_CObject*)malloc(sizeof(Dart_CObject) * loc_count);
    loc_ptrs = (Dart_CObject**)malloc(sizeof(Dart_CObject*) * loc_count);
    loc_strs = (char**)malloc(sizeof(char*) * loc_count);
    if (!loc_objs || !loc_ptrs || !loc_strs) {
      // free(NULL) is a no-op, so this releases whichever of the three
      // succeeded without needing to know which.
      free(loc_objs);
      free(loc_ptrs);
      free(loc_strs);
      z_string_array_drop(z_string_array_move(&locators));
      return;
    }
    for (size_t i = 0; i < loc_count; i++) {
      const z_loaned_string_t* loc = z_string_array_get(locs_loaned, i);
      size_t len = z_string_len(loc);
      char* s = (char*)malloc(len + 1);
      if (!s) {
        // Unwind the locators already copied -- loc_strs is only populated up
        // to i, so anything past it is uninitialised and must not be freed.
        for (size_t j = 0; j < i; j++) free(loc_strs[j]);
        free(loc_strs);
        free(loc_objs);
        free(loc_ptrs);
        z_string_array_drop(z_string_array_move(&locators));
        return;
      }
      memcpy(s, z_string_data(loc), len);
      s[len] = '\0';
      loc_strs[i] = s;
      loc_objs[i].type = Dart_CObject_kString;
      loc_objs[i].value.as_string = s;
      loc_ptrs[i] = &loc_objs[i];
    }
  }

  z_string_array_drop(z_string_array_move(&locators));

  // Build Dart_CObject array: [zid_bytes, whatami_int, locators_array]
  Dart_CObject c_zid;
  c_zid.type = Dart_CObject_kTypedData;
  c_zid.value.as_typed_data.type = Dart_TypedData_kUint8;
  c_zid.value.as_typed_data.length = 16;
  c_zid.value.as_typed_data.values = zid.id;

  Dart_CObject c_whatami;
  c_whatami.type = Dart_CObject_kInt64;
  c_whatami.value.as_int64 = (int64_t)whatami;

  Dart_CObject c_locators;
  c_locators.type = Dart_CObject_kArray;
  c_locators.value.as_array.length = (intptr_t)loc_count;
  c_locators.value.as_array.values = loc_ptrs;

  Dart_CObject* elements[3] = {&c_zid, &c_whatami, &c_locators};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 3;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
    // Port closed: one Hello is lost. Copies only — the locator arrays below
    // are freed on both paths.
  }

  if (loc_count > 0) {
    for (size_t i = 0; i < loc_count; i++) free(loc_strs[i]);
    free(loc_strs);
    free(loc_objs);
    free(loc_ptrs);
  }
}

/// Drop callback for the scout hello closure.
///
/// Canon's designated release point: it posts the null completion sentinel
/// that completes the Dart future, then frees the context. Making the sentinel
/// structural -- rather than a post from the zd_scout body -- is what keeps
/// "exactly one sentinel, exactly one free, on every path" a property of the
/// closure's lifecycle instead of three hand-held invariants. Same idiom as
/// _zd_sample_drop_with_sentinel.
static void _zd_scout_drop(void* context) {
  zd_scout_context_t* ctx = (zd_scout_context_t*)context;
  if (ctx->post_sentinel) {
    Dart_CObject null_obj;
    null_obj.type = Dart_CObject_kNull;
    if (!Dart_PostCObject_DL(ctx->dart_port, &null_obj)) {
      // Port already closed, so no Dart future is still waiting on this
      // sentinel. Nothing to reclaim; the context is freed below either way.
    }
  }
  free(ctx);
}

/// Worker block: every object z_scout can still reach once zd_scout has
/// returned. All of it is heap-owned, because a zd_scout stack local would be
/// a use-after-return the moment the call returns ahead of the scout -- the
/// move macros are pure pointer casts, not copies, so they hand the callee a
/// pointer into the caller's frame.
///
/// Deliberately separate from zd_scout_context_t, which is owned by the
/// closure and released by its drop. The two blocks have different lifetimes
/// and are never touched by both owners: the drop may fire well before the
/// worker finishes unwinding.
typedef struct {
  z_owned_config_t config;
  z_scout_options_t opts;
  z_owned_closure_hello_t closure;
} zd_scout_worker_t;

/// Detached worker: runs the blocking z_scout off the caller's isolate.
///
/// Touches no Dart API after z_scout returns -- the sentinel is the drop
/// callback's job, and by then it has already fired.
static void* _zd_scout_worker(void* arg) {
  zd_scout_worker_t* w = (zd_scout_worker_t*)arg;

  z_result_t res = z_scout(z_config_move(&w->config),
                           z_closure_hello_move(&w->closure), &w->opts);

  // A z_scout failure leaves the closure unconsumed, and nothing else would
  // ever drop it: the context would leak and the Dart future would hang. The
  // manual drop posts the sentinel, so an internal failure surfaces as a
  // normally-completing future with an empty list rather than a hang. Measured
  // never to fire on the success path (canon consumes the closure every time).
  if (z_internal_closure_hello_check(&w->closure)) {
    z_closure_hello_drop(z_closure_hello_move(&w->closure));
  }
  (void)res;

  free(w);
  return NULL;
}

FFI_PLUGIN_EXPORT int zd_scout(z_owned_config_t* config, int64_t dart_port,
                               uint64_t timeout_ms, int what) {
  // Take the caller's config content into our own storage FIRST, before any
  // step that can fail. Two reasons, both load-bearing:
  //
  //  * Dart frees the caller's block as soon as zd_scout returns, which is now
  //    before z_scout runs. z_config_take copies the content out and
  //    gravestones the source, so the later Dart-side free lands on a
  //    moved-out husk and no interleaving exists in which the worker reads
  //    freed memory.
  //  * Doing it ahead of every fallible step makes the Dart-side consume
  //    unconditional: on every path where zd_scout was entered with a config,
  //    that config has been taken and is ours to release. There is no
  //    pre-move early return left for the caller to distinguish.
  z_owned_config_t taken;
  if (config != NULL) {
    z_config_take(&taken, z_config_move(config));
  } else {
    // rc-hygiene (F12): a failed default-config build must abort the scout
    // rather than hand an uninitialized config to the worker. Nothing has been
    // taken or allocated yet, so there is nothing to release.
    z_result_t rc = z_config_default(&taken);
    if (rc != 0) return (int)rc;
  }

  zd_scout_worker_t* w =
      (zd_scout_worker_t*)malloc(sizeof(zd_scout_worker_t));
  if (!w) {
    z_config_drop(z_config_move(&taken));
    return -1;
  }

  zd_scout_context_t* ctx =
      (zd_scout_context_t*)malloc(sizeof(zd_scout_context_t));
  if (!ctx) {
    z_config_drop(z_config_move(&taken));
    free(w);
    return -1;
  }
  ctx->dart_port = (Dart_Port_DL)dart_port;
  ctx->post_sentinel = 1;

  w->config = taken;  // POD struct copy; `taken` is dead from here on
  z_closure_hello(&w->closure, _zd_scout_hello_callback, _zd_scout_drop, ctx);
  z_scout_options_default(&w->opts);
  w->opts.timeout_ms = timeout_ms;
  w->opts.what = (z_what_t)what;

  pthread_t tid;
  if (pthread_create(&tid, NULL, _zd_scout_worker, w) != 0) {
    // Nothing started. Release everything taken and post NO sentinel -- the
    // non-zero return tells Dart that none will ever arrive, and Dart throws
    // rather than awaiting a future that can never complete.
    z_config_drop(z_config_move(&w->config));
    ctx->post_sentinel = 0;
    z_closure_hello_drop(z_closure_hello_move(&w->closure));  // frees ctx
    free(w);
    return -1;
  }
  // Fire and forget: one detached worker per call, never joined.
  pthread_detach(tid);

  // rc contract: 0 means the worker started and exactly one sentinel will
  // arrive. It no longer reports z_scout's own outcome -- that is reached
  // long after this return.
  return 0;
}

// ---------------------------------------------------------------------------
// Queryable
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int32_t zd_queryable_sizeof(void) {
  return (int32_t)sizeof(z_owned_queryable_t);
}

FFI_PLUGIN_EXPORT int32_t zd_query_sizeof(void) {
  return (int32_t)sizeof(z_owned_query_t);
}

/// Context struct for queryable callback.
typedef struct {
  Dart_Port_DL dart_port;
} zd_queryable_context_t;

/// Query callback: clones the query and posts fields to Dart via native port.
static void _zd_query_callback(z_loaned_query_t* query, void* context) {
  zd_queryable_context_t* ctx = (zd_queryable_context_t*)context;

  // 1. Clone query to heap (query is only valid during this callback)
  z_owned_query_t* cloned = (z_owned_query_t*)malloc(sizeof(z_owned_query_t));
  if (!cloned) return;
  z_query_clone(cloned, query);

  // 2. Key expression as string
  const z_loaned_keyexpr_t* ke = z_query_keyexpr(query);
  z_view_string_t key_view;
  z_keyexpr_as_view_string(ke, &key_view);
  const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
  size_t key_len = z_string_len(key_loaned);
  const char* key_data = z_string_data(key_loaned);

  // 3. Parameters as string
  z_view_string_t params_view;
  z_query_parameters(query, &params_view);
  const z_loaned_string_t* params_loaned = z_view_string_loan(&params_view);
  size_t params_len = z_string_len(params_loaned);
  const char* params_data = z_string_data(params_loaned);
  // No copy any more: the value is posted length-carried straight from the
  // view, exactly as the key expression beside it is. The malloc'd C-string
  // copy this replaced was the receive half of the strlen seam -- it survived
  // the buffer faithfully and then lost everything past the first interior NUL
  // at the Dart boundary, where a kString is measured.

  // 4. Payload (nullable)
  const z_loaned_bytes_t* payload = z_query_payload(query);

  // 5. Attachment (nullable)
  const z_loaned_bytes_t* attachment = z_query_attachment(query);

  // Build Dart_CObject array:
  //   [query_ptr, keyexpr, params, payload_or_null, attachment_or_null,
  //    encoding_or_null, accepts_replies_int]
  Dart_CObject c_query_ptr;
  c_query_ptr.type = Dart_CObject_kInt64;
  c_query_ptr.value.as_int64 = (int64_t)(intptr_t)cloned;

  // Length-carried (see _zd_str_to_cobject) so an interior NUL survives; the
  // view borrows the query's own storage, valid for this callback.
  Dart_CObject c_keyexpr;
  _zd_str_to_cobject(key_data, key_len, &c_keyexpr);

  // Length-carried, like the key expression above: the parameters segment is
  // UTF-8 text whose domain includes an interior NUL, and a kString would
  // truncate there. This is the receive half of the seed's parameters rebase;
  // the send half is z_get_with_parameters_substr in zd_get / zd_querier_get.
  Dart_CObject c_params;
  _zd_str_to_cobject(params_data, params_len, &c_params);

  // Payload as bytes (byte-faithful; see _zd_bytes_to_cobject). Empty != absent:
  // a present payload (even zero-length) posts non-null Uint8 typed data;
  // an absent payload (NULL) posts kNull. Mirrors _zd_sample_callback.
  Dart_CObject c_payload;
  z_owned_slice_t payload_slice;
  zd_bytes_conv_t payload_conv = ZD_BYTES_EMPTY;
  if (payload != NULL) {
    payload_conv =
        _zd_bytes_to_cobject(payload, &c_payload, &payload_slice);
  } else {
    c_payload.type = Dart_CObject_kNull;
  }

  // Attachment as bytes (byte-faithful). Empty != absent, same discipline.
  Dart_CObject c_attachment;
  z_owned_slice_t attachment_slice;
  zd_bytes_conv_t attachment_conv = ZD_BYTES_EMPTY;
  if (attachment != NULL) {
    attachment_conv =
        _zd_bytes_to_cobject(attachment, &c_attachment, &attachment_slice);
  } else {
    c_attachment.type = Dart_CObject_kNull;
  }

  // 6. Encoding (nullable -- z_query_encoding returns NULL when the requester
  // set none). Empty != absent: an unset encoding posts kNull; a present but
  // empty encoding posts zero-length typed data. Length-carried like the key
  // expression and the parameters above, so an interior NUL in the rendered
  // MIME string or its schema survives the seam rather than being measured
  // with strlen there.
  //
  // ⚠️ BORROW LIFETIME -- the one property this posting does NOT share with
  // _zd_sample_callback, whose extraction it otherwise mirrors.
  // `_zd_str_to_cobject` BORROWS: Dart_PostCObject_DL copies typed data before
  // it returns, and `data` must point at storage that outlives the post. So
  // `enc_str` is declared HERE, in a scope enclosing the post, and dropped in
  // the trailing cleanup. It used to live and die inside the `if` below --
  // dropped eighteen lines BEFORE the post -- which was safe only because what
  // got posted was a malloc'd copy. This file already carries the idiom the fix
  // needs, twice in this same callback family: `z_id_t _rzid;  // branch-scope:
  // alive through Dart_PostCObject_DL`.
  const z_loaned_encoding_t* q_encoding = z_query_encoding(query);
  Dart_CObject c_encoding;
  z_owned_string_t enc_str;
  bool has_enc_str = false;
  if (q_encoding != NULL) {
    z_encoding_to_string(q_encoding, &enc_str);
    has_enc_str = true;
    const z_loaned_string_t* enc_loaned = z_string_loan(&enc_str);
    _zd_str_to_cobject(z_string_data(enc_loaned), z_string_len(enc_loaned),
                       &c_encoding);
  } else {
    c_encoding.type = Dart_CObject_kNull;
  }

  // 7. Accepts-replies policy (z_reply_keyexpr_t: ANY=0, MATCHING_QUERY=1)
  Dart_CObject c_accepts;
  c_accepts.type = Dart_CObject_kInt64;
  c_accepts.value.as_int64 = (int64_t)z_query_accepts_replies(query);

  Dart_CObject* elements[7] = {&c_query_ptr, &c_keyexpr,    &c_params,
                               &c_payload,   &c_attachment, &c_encoding,
                               &c_accepts};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 7;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
    // THE one post site that TRANSFERS ownership. `cloned`'s address rides
    // this message as a bare integer and Dart is what frees it, via
    // Query.dispose() -> zd_query_drop. A false return means the port is
    // closed and the VM discarded the message, so that Dart owner never
    // materialises: reclaim here, or both the block and the cloned query's
    // contents are orphaned with no reference left anywhere.
    z_query_drop(z_query_move(cloned));
    free(cloned);
  }

  // Cleanup temporary buffers. The encoding's owned string is released HERE
  // and not inside the branch that built it -- see the borrow-lifetime note
  // above; the post reads its bytes.
  if (payload_conv == ZD_BYTES_SLICE) {
    z_slice_drop(z_slice_move(&payload_slice));
  }
  if (attachment_conv == ZD_BYTES_SLICE) {
    z_slice_drop(z_slice_move(&attachment_slice));
  }
  if (has_enc_str) {
    z_string_drop(z_string_move(&enc_str));
  }
}

/// Drop callback for queryable context.
static void _zd_queryable_drop(void* context) {
  free(context);
}

/// Drop callback that posts a null sentinel before freeing.
/// Used by background queryables to signal stream completion when the
/// session closes and the background queryable is dropped by zenoh-c.
/// (The plain _zd_queryable_drop above posts no sentinel — the handle-based
/// path completes its stream explicitly on close().)
static void _zd_queryable_drop_with_sentinel(void* context) {
  zd_queryable_context_t* ctx = (zd_queryable_context_t*)context;
  Dart_CObject null_obj;
  null_obj.type = Dart_CObject_kNull;
  if (!Dart_PostCObject_DL(ctx->dart_port, &null_obj)) {
    // Port already closed, so no Dart stream is still waiting to complete on
    // this sentinel. Nothing to reclaim.
  }
  free(context);
}

/// Fills `opts` from the flattened queryable option arguments.
///
/// ONE BODY FOR BOTH MODES, exactly as `_zd_fill_get_options` is for the get
/// paths: `zd_declare_queryable` (stream) and `zd_declare_queryable_channel`
/// (bounded channel) differ only in which closure canon receives, so their
/// option surfaces cannot drift.
static void _zd_fill_queryable_options(
    z_queryable_options_t* opts, int8_t complete, int allowed_origin) {
  z_queryable_options_default(opts);
  opts->complete = (bool)complete;
  // Negative means "unspecified" -- canon's default is ANY.
  if (allowed_origin >= 0) {
    opts->allowed_origin = (z_locality_t)allowed_origin;
  }
}

FFI_PLUGIN_EXPORT int8_t zd_declare_queryable(
    uint8_t* queryable_out,
    const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t port,
    int8_t complete,
    int allowed_origin) {
  zd_queryable_context_t* ctx =
      (zd_queryable_context_t*)malloc(sizeof(zd_queryable_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)port;

  z_owned_closure_query_t callback;
  z_closure_query(&callback, _zd_query_callback, _zd_queryable_drop, ctx);

  z_queryable_options_t opts;
  _zd_fill_queryable_options(&opts, complete, allowed_origin);

  int rc = z_declare_queryable(
      (const z_loaned_session_t*)session,
      (z_owned_queryable_t*)queryable_out,
      key_expr,
      z_closure_query_move(&callback),
      &opts);

  if (rc != 0) {
    z_closure_query_drop(z_closure_query_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_declare_background_queryable(
    const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr,
    int64_t port,
    int8_t complete,
    int allowed_origin) {
  zd_queryable_context_t* ctx =
      (zd_queryable_context_t*)malloc(sizeof(zd_queryable_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)port;

  // Sentinel-posting drop so the Dart stream completes when the session drops
  // this background queryable.
  z_owned_closure_query_t callback;
  z_closure_query(&callback, _zd_query_callback,
                  _zd_queryable_drop_with_sentinel, ctx);

  z_queryable_options_t opts;
  z_queryable_options_default(&opts);
  opts.complete = (bool)complete;
  // Field add on an existing struct (not a struct introduction like the three
  // subscriber paths). Negative means "unspecified" -- canon's default is ANY.
  if (allowed_origin >= 0) {
    opts.allowed_origin = (z_locality_t)allowed_origin;
  }

  int rc = z_declare_background_queryable(
      (const z_loaned_session_t*)session,
      key_expr,
      z_closure_query_move(&callback),
      &opts);

  if (rc != 0) {
    z_closure_query_drop(z_closure_query_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT void zd_queryable_drop(uint8_t* queryable) {
  z_queryable_drop(z_queryable_move((z_owned_queryable_t*)queryable));
}

// ---------------------------------------------------------------------------
// Query channels: canon's bounded fifo/ring delivery on the queryable path.
//
// The mirror of the reply column, with the lifecycle inverted. A reply channel
// self-terminates at query completion; a query channel lives "until the channel
// is dropped (normally when the Queryable is dropped)" in canon's own words, so
// its terminal state means the PRODUCER is gone. The handle's release is
// therefore remote-visible -- it undeclares -- which is why the Dart side spells
// it `close()` rather than `dispose()`.
//
// WHY THERE IS NO UNDELIVERED-SET HERE. The callback path tracks which queries
// it has handed to a listener, because a query parsed off the port but never
// delivered has no other owner. On a pull handle a query that has not been
// recv'd is still IN THE NATIVE CHANNEL, and the handler's own drop releases it
// -- canon frees the buffered `z_owned_query_t`s. The only Dart-owned blocks on
// this path are the per-DELIVERED-query heap wrappers, freed by the shipped
// allocator-side `zd_query_drop` through `Query.dispose()`, identically to the
// callback path.
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int32_t zd_query_handler_sizeof(int32_t kind) {
  return kind == ZD_CHANNEL_FIFO
             ? (int32_t)sizeof(z_owned_fifo_handler_query_t)
             : (int32_t)sizeof(z_owned_ring_handler_query_t);
}

FFI_PLUGIN_EXPORT void zd_query_handler_drop(uint8_t* handler, int32_t kind) {
  // Through the entry matching the kind it was CONSTRUCTED with: the two owned
  // handler types are distinct, and releasing one through the other's entry is
  // undefined behaviour rather than a reported error. This is also what
  // releases any queries still buffered in the channel.
  if (kind == ZD_CHANNEL_FIFO) {
    z_owned_fifo_handler_query_t* h = (z_owned_fifo_handler_query_t*)handler;
    z_fifo_handler_query_drop(z_fifo_handler_query_move(h));
  } else {
    z_owned_ring_handler_query_t* h = (z_owned_ring_handler_query_t*)handler;
    z_ring_handler_query_drop(z_ring_handler_query_move(h));
  }
}

FFI_PLUGIN_EXPORT int8_t zd_declare_queryable_channel(
    uint8_t* queryable_out, uint8_t* handler_out, uint8_t** tee_out,
    int64_t dart_port,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, int8_t complete, int allowed_origin) {
  *tee_out = NULL;
  // CAPACITY first, and BEFORE anything is allocated. Canon's constructors take
  // a `size_t` and return void, so every domain check that exists at all has to
  // exist here; Dart rejects a negative before the call and this is the
  // structural backstop that makes the property hold at the seam.
  if (capacity < 0) {
    return ZD_DECLARE_ECAPACITY;
  }
#if SIZE_MAX < INT64_MAX
  // Live on ILP32, which this product ships: 2^32 would truncate to 0, a
  // WORKING capacity, i.e. a silent transform.
  if (capacity > (int64_t)SIZE_MAX) {
    return ZD_DECLARE_ECAPACITY;
  }
#endif

  z_owned_closure_query_t closure;
  if (kind == ZD_CHANNEL_FIFO) {
    z_fifo_channel_query_new(
        &closure, (z_owned_fifo_handler_query_t*)handler_out,
        (size_t)capacity);
  } else {
    z_ring_channel_query_new(
        &closure, (z_owned_ring_handler_query_t*)handler_out,
        (size_t)capacity);
  }

  // ALLOCATE-LAST: the tee context is claimed only after everything that can
  // fail without it has succeeded.
  zd_query_tee_t* tee = (zd_query_tee_t*)malloc(sizeof(zd_query_tee_t));
  if (!tee) {
    z_closure_query_drop(z_closure_query_move(&closure));
    zd_query_handler_drop(handler_out, kind);
    return ZD_DECLARE_EALLOC;
  }

  // Move canon's channel closure into heap-owned storage: the move macros are
  // pointer casts, not copies, so a stack local would become a use-after-return
  // the moment this function returns ahead of a delivery.
  tee->inner = closure;
  z_internal_closure_query_null(&closure);
  _zd_tee_head_init(&tee->head, dart_port);

  z_owned_closure_query_t tee_closure;
  z_closure_query(&tee_closure, _zd_query_tee_on_call, _zd_query_tee_on_drop,
                  tee);

  z_queryable_options_t opts;
  _zd_fill_queryable_options(&opts, complete, allowed_origin);

  int rc = z_declare_queryable(
      (const z_loaned_session_t*)session,
      (z_owned_queryable_t*)queryable_out,
      key_expr,
      z_closure_query_move(&tee_closure),
      &opts);

  if (rc != 0) {
    // zenoh-c 1.x takes the closure at entry and drops it on this path; the
    // check makes "exactly once" a property of this code rather than of a
    // zenoh-c internal. The HANDLER is the separately-owned half and genuinely
    // does need dropping here.
    if (z_internal_closure_query_check(&tee_closure)) {
      z_closure_query_drop(z_closure_query_move(&tee_closure));
    }
    // ...and the Dart handle's reference goes HERE, because no Dart handle will
    // ever exist to release it.
    zd_pull_tee_drop((uint8_t*)tee);
    zd_query_handler_drop(handler_out, kind);
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;
  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_query_channel_try_recv(
    const uint8_t* handler, int32_t kind,
    int64_t* out_query,
    uint8_t** out_keyexpr, size_t* out_keyexpr_len,
    uint8_t** out_parameters, size_t* out_parameters_len,
    uint8_t** out_payload, size_t* out_payload_len,
    uint8_t** out_attachment, size_t* out_attachment_len,
    char** out_encoding, size_t* out_encoding_len,
    int8_t* out_accepts_replies) {
  *out_query = 0;
  *out_keyexpr = NULL;
  *out_keyexpr_len = 0;
  *out_parameters = NULL;
  *out_parameters_len = 0;
  *out_payload = NULL;
  *out_payload_len = 0;
  *out_attachment = NULL;
  *out_attachment_len = 0;
  *out_encoding = NULL;
  *out_encoding_len = 0;
  *out_accepts_replies = 1;  // canon's default: MATCHING_QUERY

  // The ONLY kind-dependent lines; everything past the discriminant check is
  // one shared extraction body serving both kinds.
  z_owned_query_t query;
  z_result_t res;
  if (kind == ZD_CHANNEL_FIFO) {
    const z_loaned_fifo_handler_query_t* h = z_fifo_handler_query_loan(
        (const z_owned_fifo_handler_query_t*)handler);
    res = z_fifo_handler_query_try_recv(h, &query);
  } else {
    const z_loaned_ring_handler_query_t* h = z_ring_handler_query_loan(
        (const z_owned_ring_handler_query_t*)handler);
    res = z_ring_handler_query_try_recv(h, &query);
  }

  if (res == Z_CHANNEL_DISCONNECTED) {
    return 1;  // the queryable was undeclared, or its session closed
  }
  if (res == Z_CHANNEL_NODATA) {
    return 2;  // alive, buffer empty right now
  }

  // ON Z_OK ONLY: claim the heap wrapper whose address rides back to Dart as a
  // bare integer, and which `Query.dispose()` hands to the shipped
  // allocator-side `zd_query_drop`. Nothing is allocated on a non-OK recv.
  z_owned_query_t* wrapper = (z_owned_query_t*)malloc(sizeof(z_owned_query_t));
  if (!wrapper) {
    z_query_drop(z_query_move(&query));
    return -1;
  }
  // Move, not copy: the move macros are pointer casts, so the recv'd stack
  // value is taken into heap storage before this function returns.
  *wrapper = query;
  z_internal_query_null(&query);

  const z_loaned_query_t* q = z_query_loan(wrapper);

  // Everything from here releases the WRAPPER too on failure -- it has no Dart
  // owner until the address is handed back.
#define ZD_QUERY_RECV_FAIL()                                          \
  do {                                                                \
    free(*out_keyexpr);                                               \
    *out_keyexpr = NULL;                                              \
    *out_keyexpr_len = 0;                                             \
    free(*out_parameters);                                            \
    *out_parameters = NULL;                                           \
    *out_parameters_len = 0;                                          \
    free(*out_payload);                                               \
    *out_payload = NULL;                                              \
    *out_payload_len = 0;                                             \
    free(*out_attachment);                                            \
    *out_attachment = NULL;                                           \
    *out_attachment_len = 0;                                          \
    free(*out_encoding);                                              \
    *out_encoding = NULL;                                             \
    z_query_drop(z_query_move(wrapper));                              \
    free(wrapper);                                                    \
    return -1;                                                        \
  } while (0)

  // 1. Key expression, LENGTH-CARRIED. REMOTE-LENGTH-DRIVEN, like every
  // allocation below: the requester chose the length.
  z_view_string_t key_view;
  z_keyexpr_as_view_string(z_query_keyexpr(q), &key_view);
  const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
  size_t key_len = z_string_len(key_loaned);
  *out_keyexpr = (uint8_t*)malloc(key_len + 1);
  if (!*out_keyexpr) ZD_QUERY_RECV_FAIL();
  memcpy(*out_keyexpr, z_string_data(key_loaned), key_len);
  (*out_keyexpr)[key_len] = '\0';
  *out_keyexpr_len = key_len;

  // 2. Parameters, LENGTH-CARRIED for the same reason the send seam is: the
  // selector's parameters segment admits an interior NUL.
  z_view_string_t params_view;
  z_query_parameters(q, &params_view);
  const z_loaned_string_t* params_loaned = z_view_string_loan(&params_view);
  size_t params_len = z_string_len(params_loaned);
  *out_parameters = (uint8_t*)malloc(params_len + 1);
  if (!*out_parameters) ZD_QUERY_RECV_FAIL();
  memcpy(*out_parameters, z_string_data(params_loaned), params_len);
  (*out_parameters)[params_len] = '\0';
  *out_parameters_len = params_len;

  // 3. Payload (NULLABLE). Empty != absent, and on this path BOTH are
  // reachable: canon returns NULL when the requester attached none, and a
  // present-but-empty payload must come back as a non-NULL pointer at length 0.
  // Discriminate on the POINTER.
  const z_loaned_bytes_t* payload = z_query_payload(q);
  if (payload != NULL) {
    size_t payload_len = z_bytes_len(payload);
    *out_payload = (uint8_t*)malloc(payload_len > 0 ? payload_len : 1);
    if (!*out_payload) ZD_QUERY_RECV_FAIL();
    if (payload_len > 0) {
      z_bytes_reader_t reader = z_bytes_get_reader(payload);
      *out_payload_len = z_bytes_reader_read(&reader, *out_payload,
                                             payload_len);
    }
  }

  // 4. Attachment (NULLABLE), same empty-vs-absent discipline.
  const z_loaned_bytes_t* attachment = z_query_attachment(q);
  if (attachment != NULL) {
    size_t att_len = z_bytes_len(attachment);
    *out_attachment = (uint8_t*)malloc(att_len > 0 ? att_len : 1);
    if (!*out_attachment) ZD_QUERY_RECV_FAIL();
    if (att_len > 0) {
      z_bytes_reader_t reader = z_bytes_get_reader(attachment);
      *out_attachment_len = z_bytes_reader_read(&reader, *out_attachment,
                                                att_len);
    }
  }

  // 5. Encoding (NULLABLE -- canon returns NULL when the requester set none).
  // Allocated whenever present, so a present-but-empty encoding reads as ''
  // rather than as absent, matching the callback path.
  const z_loaned_encoding_t* q_encoding = z_query_encoding(q);
  if (q_encoding != NULL) {
    z_owned_string_t enc_str;
    z_encoding_to_string(q_encoding, &enc_str);
    const z_loaned_string_t* enc_loaned = z_string_loan(&enc_str);
    size_t enc_len = z_string_len(enc_loaned);
    *out_encoding = (char*)malloc(enc_len + 1);
    if (!*out_encoding) {
      z_string_drop(z_string_move(&enc_str));
      ZD_QUERY_RECV_FAIL();
    }
    memcpy(*out_encoding, z_string_data(enc_loaned), enc_len);
    (*out_encoding)[enc_len] = '\0';
    // LENGTH-CARRIED: the trailing NUL is hygiene, the length is the contract.
    *out_encoding_len = enc_len;
    z_string_drop(z_string_move(&enc_str));
  }

  // 6. Accepts-replies policy (z_reply_keyexpr_t: ANY=0, MATCHING_QUERY=1).
  *out_accepts_replies = (int8_t)z_query_accepts_replies(q);

#undef ZD_QUERY_RECV_FAIL

  // LAST: hand the wrapper's address over. Every failure above released it, so
  // this is the single point at which Dart becomes its owner.
  *out_query = (int64_t)(intptr_t)wrapper;
  return 0;
}

/// Drops a received query and frees its wrapper block.
///
/// ALLOCATOR-SIDE FREE. The `z_owned_query_t` this receives is a block the
/// shim malloc'd, on one of two routes. A PUSHED query's block comes from
/// `_zd_query_callback`, and its address rides the NativePort message to Dart
/// as a bare integer; a PULLED query's block comes from
/// `zd_query_channel_try_recv`, and its address returns through `*out_query`.
/// On both, `Query.dispose()` hands it straight back here, and once Dart owns
/// the block nothing else frees it: without this `free()` one block leaks per
/// received query even when the consumer disposes correctly.
///
/// (Corrected: this used to add a parenthetical saying zd_query_sizeof had
/// no callers. That is false -- `finalizer_harness.dart` calls it through the
/// bindings. The claim that mattered is about this DELIVERY path, and it is
/// stated directly above.)
FFI_PLUGIN_EXPORT void zd_query_drop(uint8_t* query) {
  z_query_drop(z_query_move((z_owned_query_t*)query));
  free(query);
}

// ---------------------------------------------------------------------------
// Get (query with reply callback via NativePort)
// ---------------------------------------------------------------------------

/// Context struct for get reply callback.
typedef struct {
  Dart_Port_DL dart_port;
  /// Seed [10a]: when non-zero, the OK arm of `_zd_reply_callback` clones the
  /// loaned payload and posts its `sizeof` byte image as element 12,
  /// TRANSFERRING that clone to Dart. The ERROR arm is untouched -- the
  /// error-reply payload is a carve homed to the terminal unit.
  int retain_payload;
} zd_get_context_t;

/// Reply callback: extracts reply fields and posts to Dart via native port.
/// Ok reply: [1, keyexpr_string, payload_bytes, kind_int, attachment_or_null, encoding_string]
/// Error reply: [0, error_payload_bytes, error_encoding_string]
static void _zd_reply_callback(z_loaned_reply_t* reply, void* context) {
  zd_get_context_t* ctx = (zd_get_context_t*)context;

  if (z_reply_is_ok(reply)) {
    const z_loaned_sample_t* sample = z_reply_ok(reply);

    // 1. Key expression as string
    const z_loaned_keyexpr_t* ke = z_sample_keyexpr(sample);
    z_view_string_t key_view;
    z_keyexpr_as_view_string(ke, &key_view);
    const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
    size_t key_len = z_string_len(key_loaned);
    const char* key_data = z_string_data(key_loaned);

    // 2. Payload as bytes (byte-faithful; see _zd_bytes_to_cobject)
    const z_loaned_bytes_t* payload_loaned = z_sample_payload(sample);

    // 3. Kind as int
    z_sample_kind_t kind = z_sample_kind(sample);

    // 4. Attachment (nullable)
    const z_loaned_bytes_t* attachment = z_sample_attachment(sample);

    // 5. Encoding as string
    const z_loaned_encoding_t* encoding = z_sample_encoding(sample);
    z_owned_string_t encoding_str;
    z_encoding_to_string(encoding, &encoding_str);
    const z_loaned_string_t* enc_loaned = z_string_loan(&encoding_str);
    size_t enc_len = z_string_len(enc_loaned);
    const char* enc_data = z_string_data(enc_loaned);

    // Build tag
    Dart_CObject c_tag;
    c_tag.type = Dart_CObject_kInt64;
    c_tag.value.as_int64 = 1;

    // Length-carried (see _zd_str_to_cobject) so an interior NUL survives; the
    // view borrows the reply sample's storage, valid for this callback.
    Dart_CObject c_keyexpr;
    _zd_str_to_cobject(key_data, key_len, &c_keyexpr);

    Dart_CObject c_payload;
    z_owned_slice_t payload_slice;
    zd_bytes_conv_t payload_conv =
        _zd_bytes_to_cobject(payload_loaned, &c_payload, &payload_slice);

    Dart_CObject c_kind;
    c_kind.type = Dart_CObject_kInt64;
    c_kind.value.as_int64 = (int64_t)kind;

    Dart_CObject c_attachment;
    z_owned_slice_t attachment_slice;
    zd_bytes_conv_t attachment_conv = ZD_BYTES_EMPTY;
    if (attachment != NULL) {
      attachment_conv =
          _zd_bytes_to_cobject(attachment, &c_attachment, &attachment_slice);
    } else {
      c_attachment.type = Dart_CObject_kNull;
    }

    // Length-carried, like the key expression above. BORROW LIFETIME is
    // already right on this arm and stays that way: `encoding_str` is declared
    // at branch scope (above, beside the extraction) and dropped in this
    // branch's trailing cleanup, AFTER the post -- re-checked at this edit and
    // recorded rather than changed. The malloc'd copy and its
    // remote-length-driven allocation guard are gone with it.
    Dart_CObject c_encoding;
    _zd_str_to_cobject(enc_data, enc_len, &c_encoding);

    // 6. Timestamp (nullable): raw 24-byte z_timestamp_t image, or kNull.
    // Mirrors _zd_sample_callback: z_sample_timestamp returns NULL when absent;
    // the pointer is valid for the callback's duration and Dart_PostCObject_DL
    // copies the bytes before returning, so no malloc is needed.
    Dart_CObject c_timestamp;
    const z_timestamp_t* ts = z_sample_timestamp(sample);
    if (ts != NULL) {
      c_timestamp.type = Dart_CObject_kTypedData;
      c_timestamp.value.as_typed_data.type = Dart_TypedData_kUint8;
      c_timestamp.value.as_typed_data.length = 24;
      c_timestamp.value.as_typed_data.values = (uint8_t*)ts;
    } else {
      c_timestamp.type = Dart_CObject_kNull;
    }

    // 7. Priority (1..7), 8. Congestion control (0/1), 9. Express (0/1).
    Dart_CObject c_priority;
    c_priority.type = Dart_CObject_kInt64;
    c_priority.value.as_int64 = (int64_t)z_sample_priority(sample);

    Dart_CObject c_congestion;
    c_congestion.type = Dart_CObject_kInt64;
    c_congestion.value.as_int64 = (int64_t)z_sample_congestion_control(sample);

    Dart_CObject c_express;
    c_express.type = Dart_CObject_kInt64;
    c_express.value.as_int64 = z_sample_express(sample) ? 1 : 0;

    // 10. Replier zid (16-byte Uint8List) + 11. Replier eid (int), or kNull.
    // z_reply_replier_id takes the whole reply (works ok+err) and is
    // UNSTABLE-guarded. The #ifdef gates ONLY the value extraction; the array
    // length stays CONSTANT (kNull placeholders when unstable is off) so the
    // Dart parse is platform-invariant.
    Dart_CObject c_replier_zid;
    Dart_CObject c_replier_eid;
#if defined(Z_FEATURE_UNSTABLE_API)
    z_entity_global_id_t _replier;
    z_id_t _rzid;  // branch-scope: alive through Dart_PostCObject_DL
    if (z_reply_replier_id(reply, &_replier)) {
      _rzid = z_entity_global_id_zid(&_replier);
      c_replier_zid.type = Dart_CObject_kTypedData;
      c_replier_zid.value.as_typed_data.type = Dart_TypedData_kUint8;
      c_replier_zid.value.as_typed_data.length = 16;
      c_replier_zid.value.as_typed_data.values = _rzid.id;
      c_replier_eid.type = Dart_CObject_kInt64;
      c_replier_eid.value.as_int64 = (int64_t)z_entity_global_id_eid(&_replier);
    } else {
      c_replier_zid.type = Dart_CObject_kNull;
      c_replier_eid.type = Dart_CObject_kNull;
    }
#else
    c_replier_zid.type = Dart_CObject_kNull;
    c_replier_eid.type = Dart_CObject_kNull;
#endif

    // Seed [10a] element 12: the RETAINED payload handle, same mechanism as
    // the sample column -- clone into a STACK z_owned_bytes_t, post its
    // `sizeof` byte image (Dart_PostCObject_DL copies typed data before it
    // returns), null the local when delivered, drop it on a failed post.
    z_owned_bytes_t retained_payload;
    bool has_retained = false;
    Dart_CObject c_retained;
    if (ctx->retain_payload) {
      z_bytes_clone(&retained_payload, payload_loaned);
      has_retained = true;
      c_retained.type = Dart_CObject_kTypedData;
      c_retained.value.as_typed_data.type = Dart_TypedData_kUint8;
      c_retained.value.as_typed_data.length = (intptr_t)sizeof(z_owned_bytes_t);
      c_retained.value.as_typed_data.values = (uint8_t*)&retained_payload;
    } else {
      c_retained.type = Dart_CObject_kNull;
    }

    Dart_CObject* elements[13] = {&c_tag,         &c_keyexpr,     &c_payload,
                                  &c_kind,        &c_attachment,  &c_encoding,
                                  &c_timestamp,   &c_priority,    &c_congestion,
                                  &c_express,     &c_replier_zid, &c_replier_eid,
                                  &c_retained};
    Dart_CObject c_array;
    c_array.type = Dart_CObject_kArray;
    c_array.value.as_array.length = 13;
    c_array.value.as_array.values = elements;

    if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
      // Port closed: one OK reply is lost.
      //
      // CORRECTED at seed [10a]. This read "Copies only, nothing to
      // reclaim", which is false the moment retention is on: element 12
      // TRANSFERS an owned clone whose only reference is the image inside
      // the message the VM just discarded.
      if (has_retained) {
        z_bytes_drop(z_bytes_move(&retained_payload));
        has_retained = false;
      }
    } else if (has_retained) {
      // Delivered: Dart owns the clone. Null the local so the cleanup
      // below cannot drop it out from under the Dart owner.
      z_internal_bytes_null(&retained_payload);
      has_retained = false;
    }

    // Cleanup
    if (payload_conv == ZD_BYTES_SLICE) {
      z_slice_drop(z_slice_move(&payload_slice));
    }
    z_string_drop(z_string_move(&encoding_str));
    if (attachment_conv == ZD_BYTES_SLICE) {
      z_slice_drop(z_slice_move(&attachment_slice));
    }
  } else {
    // Error reply
    const z_loaned_reply_err_t* err = z_reply_err(reply);

    // Error payload as bytes (byte-faithful; see _zd_bytes_to_cobject)
    const z_loaned_bytes_t* err_payload = z_reply_err_payload(err);

    // Error encoding as string
    const z_loaned_encoding_t* err_encoding = z_reply_err_encoding(err);
    z_owned_string_t err_enc_str;
    z_encoding_to_string(err_encoding, &err_enc_str);
    const z_loaned_string_t* err_enc_loaned = z_string_loan(&err_enc_str);
    size_t err_enc_len = z_string_len(err_enc_loaned);
    const char* err_enc_data = z_string_data(err_enc_loaned);

    Dart_CObject c_tag;
    c_tag.type = Dart_CObject_kInt64;
    c_tag.value.as_int64 = 0;

    Dart_CObject c_err_payload;
    z_owned_slice_t err_payload_slice;
    zd_bytes_conv_t err_payload_conv =
        _zd_bytes_to_cobject(err_payload, &c_err_payload, &err_payload_slice);

    // Length-carried, same as the ok arm. BORROW LIFETIME already right here
    // too: `err_enc_str` is declared at branch scope above and dropped in this
    // branch's trailing cleanup, after the post.
    Dart_CObject c_err_encoding;
    _zd_str_to_cobject(err_enc_data, err_enc_len, &c_err_encoding);

    // Replier zid (16-byte Uint8List) + eid (int) on the ERROR path too —
    // z_reply_replier_id takes the whole reply. Same constant-length /
    // #ifdef-only-around-extraction discipline as the ok branch.
    Dart_CObject c_replier_zid;
    Dart_CObject c_replier_eid;
#if defined(Z_FEATURE_UNSTABLE_API)
    z_entity_global_id_t _replier_e;
    z_id_t _rzid_e;  // branch-scope: alive through Dart_PostCObject_DL
    if (z_reply_replier_id(reply, &_replier_e)) {
      _rzid_e = z_entity_global_id_zid(&_replier_e);
      c_replier_zid.type = Dart_CObject_kTypedData;
      c_replier_zid.value.as_typed_data.type = Dart_TypedData_kUint8;
      c_replier_zid.value.as_typed_data.length = 16;
      c_replier_zid.value.as_typed_data.values = _rzid_e.id;
      c_replier_eid.type = Dart_CObject_kInt64;
      c_replier_eid.value.as_int64 =
          (int64_t)z_entity_global_id_eid(&_replier_e);
    } else {
      c_replier_zid.type = Dart_CObject_kNull;
      c_replier_eid.type = Dart_CObject_kNull;
    }
#else
    c_replier_zid.type = Dart_CObject_kNull;
    c_replier_eid.type = Dart_CObject_kNull;
#endif

    Dart_CObject* elements[5] = {&c_tag, &c_err_payload, &c_err_encoding,
                                 &c_replier_zid, &c_replier_eid};
    Dart_CObject c_array;
    c_array.type = Dart_CObject_kArray;
    c_array.value.as_array.length = 5;
    c_array.value.as_array.values = elements;

    if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
      // Port closed: one error reply is lost. Copies only — nothing to
      // reclaim.
    }

    if (err_payload_conv == ZD_BYTES_SLICE) {
      z_slice_drop(z_slice_move(&err_payload_slice));
    }
    z_string_drop(z_string_move(&err_enc_str));
  }
}

/// Drop callback for get context: posts null sentinel and frees context.
static void _zd_get_drop(void* context) {
  zd_get_context_t* ctx = (zd_get_context_t*)context;

  // Post null sentinel to signal completion to Dart
  Dart_CObject null_obj;
  null_obj.type = Dart_CObject_kNull;
  if (!Dart_PostCObject_DL(ctx->dart_port, &null_obj)) {
    // Port already closed, so no Dart reply stream is still waiting on this
    // sentinel. Nothing to reclaim.
  }

  free(ctx);
}

/// Fills `opts` from the flattened option arguments the Dart seam sends.
///
/// ONE BODY FOR BOTH MODES. `zd_get` (stream) and `zd_get_channel` (bounded
/// channel) differ only in which closure they hand canon -- canon's options
/// struct is orthogonal to the closure slot -- so the twelve options are
/// filled here rather than twice. Option parity between the two modes is then
/// STRUCTURAL: there is no second copy that can drift.
///
/// `owned_encoding` must be the CALLER's storage: `opts.encoding` holds a move
/// out of it, so a local here would be a use-after-return the moment canon
/// reads the options.
///
/// Returns 0, or canon's encoding rc. On the encoding failure the payload and
/// attachment this was handed are DROPPED before returning -- they were moved
/// into `opts` already, so the caller's unconditional `markConsumed` on the
/// Dart side is true on every path. The caller still owns releasing its own
/// closure.
static int8_t _zd_fill_get_options(
    z_get_options_t* opts, z_owned_encoding_t* owned_encoding,
    int8_t target, int8_t consolidation, uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint64_t timeout_ms, uint8_t* attachment,
    int congestion_control, int priority, int8_t is_express,
    int allowed_destination, int accept_replies) {
  z_get_options_default(opts);
  opts->target = (z_query_target_t)target;
  opts->timeout_ms = timeout_ms;

  if (consolidation == -1) {
    opts->consolidation = z_query_consolidation_default();
  } else {
    opts->consolidation.mode = (z_consolidation_mode_t)consolidation;
  }

  // Negative means "unspecified" -- leave z_get_options_default's value. NOTE
  // the default differs from the push paths: canon assigns DEFAULT_REQUEST
  // (BLOCK) here, where put/delete/publisher get DEFAULT_PUSH (DROP).
  if (congestion_control >= 0) {
    opts->congestion_control = (z_congestion_control_t)congestion_control;
  }
  if (priority >= 0) {
    opts->priority = (z_priority_t)priority;
  }
  if (is_express >= 0) {
    opts->is_express = (bool)is_express;
  }
  if (allowed_destination >= 0) {
    opts->allowed_destination = (z_locality_t)allowed_destination;
  }
  if (accept_replies >= 0) {
    opts->accept_replies = (z_reply_keyexpr_t)accept_replies;
  }

  // Optional payload (z_owned_bytes_t*, consumed via move)
  if (payload != NULL) {
    opts->payload = z_bytes_move((z_owned_bytes_t*)payload);
  }
  // Optional attachment (z_owned_bytes_t*, consumed via move)
  if (attachment != NULL) {
    opts->attachment = z_bytes_move((z_owned_bytes_t*)attachment);
  }

  // Optional encoding: two independent length-carried channels (R-2); see
  // _zd_build_encoding. Check the rc -- do not silently substitute the default
  // on a bad MIME or a non-UTF-8 schema.
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(owned_encoding, encoding, encoding_len,
                                         encoding_schema, encoding_schema_len,
                                         &has_encoding);
  if (enc_rc != 0) {
    if (opts->payload != NULL) {
      z_bytes_drop(opts->payload);
    }
    if (opts->attachment != NULL) {
      z_bytes_drop(opts->attachment);
    }
    return (int8_t)enc_rc;
  }
  if (has_encoding) {
    opts->encoding = z_encoding_move(owned_encoding);
  }

  return 0;
}

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
    int retain_payload) {
  // The malloc-failure early-return below runs BEFORE the payload/attachment
  // are moved -- and the Dart caller marks them consumed UNCONDITIONALLY after
  // this call.
  //
  // ⚠️ The comment that used to sit here said the caller "still owns them (no
  // markConsumed on this path)". That was factually wrong: session.dart marks
  // after every return code, so leaving the bytes un-dropped here gravestoned
  // the Dart wrapper while nothing released the native handle. Rather than
  // make the Dart side conditional -- which cannot distinguish a pre-move from
  // a post-move rc -- this path drops what it was handed, exactly as the
  // encoding-error path further down already does. Every path then ends with
  // the bytes released, which is what the unconditional mark asserts.
  //
  // The key-expression early-return that used to sit alongside it is gone: the
  // selector arrives already validated as a loaned handle.
  zd_get_context_t* ctx =
      (zd_get_context_t*)malloc(sizeof(zd_get_context_t));
  if (!ctx) {
    if (payload != NULL) z_bytes_drop(z_bytes_move((z_owned_bytes_t*)payload));
    if (attachment != NULL) {
      z_bytes_drop(z_bytes_move((z_owned_bytes_t*)attachment));
    }
    return -1;
  }
  ctx->dart_port = (Dart_Port_DL)port;
  // Seed [10a]: the caller's opt-in, explicit because malloc does not zero.
  ctx->retain_payload = retain_payload;

  z_owned_closure_reply_t callback;
  z_closure_reply(&callback, _zd_reply_callback, _zd_get_drop, ctx);

  z_get_options_t opts;
  z_owned_encoding_t owned_encoding;
  int8_t opt_rc = _zd_fill_get_options(
      &opts, &owned_encoding, target, consolidation, payload, encoding,
      encoding_len, encoding_schema, encoding_schema_len,
      timeout_ms, attachment, congestion_control, priority, is_express,
      allowed_destination, accept_replies);
  if (opt_rc != 0) {
    // POST-move: the helper has already dropped the payload/attachment it was
    // handed, so only the closure is left to release here.
    z_closure_reply_drop(z_closure_reply_move(&callback));
    return opt_rc;
  }

  // LENGTH-CARRIED, not strlen'd. `z_get` IS this call with
  // `strlen_or_zero(parameters)` substituted (zenoh-c src/get.rs:305), so this
  // is canon's own wider entry rather than a different code path -- and an
  // interior NUL in the parameters, which the selector grammar permits and
  // canon carries byte-exact, no longer truncates at our seam.
  // A NULL pointer with length 0 is canon's own "no parameters" spelling
  // (CStringView::new_borrowed accepts it; only NULL-with-length is refused).
  int rc = z_get_with_parameters_substr(
      (const z_loaned_session_t*)session,
      selector,
      parameters,
      parameters_len,
      z_closure_reply_move(&callback),
      &opts);

  if (rc != 0) {
    z_closure_reply_drop(z_closure_reply_move(&callback));
  }

  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Query reply
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int8_t zd_query_reply(
    const uint8_t* query,
    const z_loaned_keyexpr_t* key_expr,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment,
    const uint8_t* timestamp,
    int8_t is_express) {
  // Loan the cloned query
  const z_loaned_query_t* loaned = z_query_loan((z_owned_query_t*)query);

  // The key expression arrives already validated, as a loaned handle. It used
  // to be re-parsed here behind a PRE-move early-return -- a third validation
  // of the same string, after Query.reply and Query.replyBytes had each done
  // one. Validation now lands exactly once, in the Dart union dispatch, which
  // is still before any move, so the pre-move/post-move discipline below is
  // unchanged.

  // Options
  z_query_reply_options_t opts;
  z_query_reply_options_default(&opts);

  // Negative means "unspecified" -- leave canon's default (false).
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }

  // Optional timestamp. z_timestamp_t is ALIGN(8): memcpy the 24 incoming
  // bytes into 8-byte-aligned stack storage and point opts.timestamp at it
  // (never cast the raw incoming pointer, which may be unaligned -- x86
  // tolerates it, Android/ARM can fault). The timestamp is BORROWED (zenoh-c
  // reads it, does not own it), so it needs no drop on any path; ts_storage
  // stays valid through the synchronous z_query_reply below. Placed BEFORE the
  // payload/attachment move staging so the pre-move/post-move discipline is
  // untouched.
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  // Stage the payload + attachment moves up front so the encoding-error
  // path below can drop the already-gravestoned bytes consistently
  // (mirroring zd_get / zd_put).
  z_moved_bytes_t* moved_payload = z_bytes_move((z_owned_bytes_t*)payload);
  // Optional attachment (z_owned_bytes_t*, consumed via move)
  if (attachment != NULL) {
    opts.attachment = z_bytes_move((z_owned_bytes_t*)attachment);
  }

  // Optional encoding. Check the rc: do not silently substitute the default
  // on a bad MIME. This is a POST-move error path -- the payload/attachment
  // are already gravestoned, so drop them here and return non-zero. The Dart
  // caller's unconditional post-call markConsumed matches: both ZBytes end up
  // consumed on this path.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    if (moved_payload != NULL) {
      z_bytes_drop(moved_payload);
    }
    if (opts.attachment != NULL) {
      z_bytes_drop(opts.attachment);
    }
    return (int8_t)enc_rc;
  }
  if (has_encoding) {
    opts.encoding = z_encoding_move(&owned_encoding);
  }

  int rc = z_query_reply(
      loaned,
      key_expr,
      moved_payload,
      &opts);

  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Query DELETE-kind reply
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int8_t zd_query_reply_del(
    const uint8_t* query,
    const z_loaned_keyexpr_t* key_expr,
    uint8_t* attachment,        // z_owned_bytes_t*, moved (NULL = none)
    const uint8_t* timestamp,   // raw 24 bytes, borrowed (NULL = none)
    int8_t is_express) {        // 1/0, or -1 to leave canon's default
  // Loan the cloned query.
  const z_loaned_query_t* loaned = z_query_loan((z_owned_query_t*)query);

  // The key expression arrives already validated, as a loaned handle;
  // validation lands once, Dart-side, before any move.

  // Options
  z_query_reply_del_options_t opts;
  z_query_reply_del_options_default(&opts);

  // Negative means "unspecified" -- leave canon's default (false).
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }

  // Optional timestamp. z_timestamp_t is ALIGN(8): memcpy the 24 incoming
  // bytes into 8-byte-aligned stack storage and point opts.timestamp at it
  // (never cast the raw incoming pointer, which may be unaligned -- x86
  // tolerates it, Android/ARM can fault). The timestamp is BORROWED (zenoh-c
  // reads it, does not own it), so it needs no drop; ts_storage stays valid
  // through the synchronous z_query_reply_del below.
  z_timestamp_t ts_storage;
  if (timestamp != NULL) {
    memcpy(&ts_storage, timestamp, 24);
    opts.timestamp = &ts_storage;
  }

  // Optional attachment (z_owned_bytes_t*, consumed via move). Moved just
  // before the call; the Dart caller's unconditional post-call markConsumed
  // matches (once this line runs the bytes are gravestoned regardless of rc).
  if (attachment != NULL) {
    opts.attachment = z_bytes_move((z_owned_bytes_t*)attachment);
  }

  int rc = z_query_reply_del(loaned, key_expr, &opts);

  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Query error reply
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int8_t zd_query_reply_err(
    const uint8_t* query,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len) {
  // Loan the cloned query. Error replies carry NO key expression and NO
  // attachment (z_query_reply_err_options_t has only `encoding`).
  const z_loaned_query_t* loaned = z_query_loan((z_owned_query_t*)query);

  z_query_reply_err_options_t opts;
  z_query_reply_err_options_default(&opts);

  // Stage the payload move up front so the encoding-error path below can drop
  // the already-gravestoned bytes consistently (mirrors zd_query_reply).
  z_moved_bytes_t* moved_payload = z_bytes_move((z_owned_bytes_t*)payload);

  // Optional encoding. Check the rc: do not silently substitute the default
  // on a bad MIME. This is a POST-move error path -- the payload is already
  // gravestoned, so drop it here and return non-zero. The Dart caller's
  // unconditional post-call markConsumed matches: the payload ends up consumed
  // on this path.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    if (moved_payload != NULL) {
      z_bytes_drop(moved_payload);
    }
    return (int8_t)enc_rc;
  }
  if (has_encoding) {
    opts.encoding = z_encoding_move(&owned_encoding);
  }

  int rc = z_query_reply_err(loaned, moved_payload, &opts);

  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Query accessors
// ---------------------------------------------------------------------------

/// ⚠️ DORMANT on the API path, and deliberately NOT widened.
///
/// It carries the same int32 length narrowing the D-4 rider fixed on
/// zd_bytes_len / zd_bytes_to_buf / the pull out-lens. Descoped 2026-08-16 by
/// the fix-round directive: the dead-export prune homed to seed #11 disposes
/// of it, and widening a symbol on its way out is waste.
///
/// Precisely: nothing in `package/lib` calls it — queries arrive with their
/// payload already pushed over the NativePort — but ONE direct-bindings test
/// does (`get_queryable_test.dart`, "returns byte-exact payload"). So it is
/// not unreferenced, and #11's prune must retire that test with the symbol.
FFI_PLUGIN_EXPORT int32_t zd_query_payload(
    const uint8_t* query,
    uint8_t* payload_out,
    int32_t max_len) {
  const z_loaned_query_t* loaned = z_query_loan((z_owned_query_t*)query);
  const z_loaned_bytes_t* payload = z_query_payload(loaned);
  // Empty != absent: an absent payload returns -1 (distinct from a
  // present-but-empty payload, which returns 0 with no bytes written).
  if (payload == NULL) {
    return -1;
  }
  size_t actual_len = z_bytes_len(payload);
  if (actual_len == 0) {
    return 0;
  }
  // Copy payload bytes via the byte-faithful reader. The reader returns the
  // number of bytes actually read; on a short read (dst smaller than the
  // payload) we must report ACTUAL bytes written, not the requested length,
  // so the caller never reads an uninitialized tail.
  size_t copy_len = actual_len < (size_t)max_len ? actual_len : (size_t)max_len;
  z_bytes_reader_t reader = z_bytes_get_reader(payload);
  size_t read_len = z_bytes_reader_read(&reader, payload_out, copy_len);
  return (int32_t)read_len;
}

/// Clones a received query's payload into a caller-supplied owned slot.
///
/// Seed [10a] slice 8 — the query column's whole mechanism, and it needs no
/// declaration flag. `_zd_query_callback` already heap-clones the entire owned
/// query and hands Dart its address, so the query — and therefore its payload —
/// is alive until `Query.dispose()`. The payload is reachable WHENEVER Dart
/// asks, which is what lets this be a lazy accessor rather than a retention
/// decision taken at declaration time.
///
/// `dst` is a caller-supplied `z_owned_bytes_t`-sized slot, allocated by Dart
/// from `zd_bytes_sizeof()`. Nothing is allocated here.
///
/// Presence is reported through `has_payload` rather than a return code:
/// `z_bytes_clone` returns `void` and cannot fail, so there is no failure to
/// report and no new code is minted. An ABSENT payload writes 0 and leaves
/// `dst` untouched; a present one writes 1 and fills `dst`.
///
/// ⛔ OWNERSHIP: on a present payload the clone belongs to Dart, which must
/// release it. It is INDEPENDENT of the query it came from — canon's
/// `z_bytes_drop` states that shallow copies stay valid — so it outlives
/// `zd_query_drop`.
FFI_PLUGIN_EXPORT void zd_query_payload_clone(
    const uint8_t* query,
    uint8_t* dst,
    int32_t* has_payload) {
  const z_loaned_query_t* loaned = z_query_loan((z_owned_query_t*)query);
  const z_loaned_bytes_t* payload = z_query_payload(loaned);
  // Empty != absent, exactly as zd_query_payload distinguishes them: an absent
  // payload reports 0 here, while a present-but-empty one reports 1 and yields
  // a live zero-length handle. Conflating the two is the NULL-vs-empty
  // transform this project's fidelity doctrine names outright.
  if (payload == NULL) {
    *has_payload = 0;
    return;
  }
  *has_payload = 1;
  z_bytes_clone((z_owned_bytes_t*)dst, payload);
}

// ---------------------------------------------------------------------------
// Shared Memory (SHM)
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)

FFI_PLUGIN_EXPORT size_t zd_shm_provider_sizeof(void) {
  return sizeof(z_owned_shm_provider_t);
}

// The seventh detail-carrying entry, and the first outside Config. Same
// triple, same order, same names as the six that came before it -- see the
// err_buf/err_cap/err_len contract in the header.
//
// It earns the widening the way the config entries did: canon answers EVERY
// rejection class here with Z_EINVAL, so the rc alone cannot say which rule
// the caller broke. Measured, three classes behind one code -- a pool too
// small to back the Talc allocator, a pool over the host's RLIMIT_MEMLOCK,
// and a pool whose element count a 32-bit ElemIndex cannot address. Canon
// distinguishes all three in zc_get_last_error's text and nowhere else.
//
// ⚠️ The out-length is written before the canon call on EVERY path, so a
// successful creation reports 0 and a caller can never render text an
// earlier failure left behind. That is the whole of this entry's
// out-length contract.
//
// ⛔ It is NOT the `stable` out-length contract, and it cannot be: this
// function sits inside the SHM/unstable guard, so the stable native has no
// entry to call rather than a compiled-out body. The stable property belongs
// to _zd_capture_last_error, which is unguarded AS A FUNCTION precisely
// because its five config callers ship on both variants.
FFI_PLUGIN_EXPORT int zd_shm_provider_new(z_owned_shm_provider_t* provider,
                                          size_t total_size,
                                          uint8_t* err_buf, int err_cap,
                                          int* err_len) {
  if (err_len != NULL) *err_len = 0;
  int rc = z_shm_provider_default_new(provider, total_size);
  if (rc != 0) _zd_capture_last_error(err_buf, err_cap, err_len);
  return rc;
}

FFI_PLUGIN_EXPORT const z_loaned_shm_provider_t* zd_shm_provider_loan(
    const z_owned_shm_provider_t* provider) {
  return z_shm_provider_loan(provider);
}

FFI_PLUGIN_EXPORT void zd_shm_provider_drop(z_owned_shm_provider_t* provider) {
  z_shm_provider_drop(z_shm_provider_move(provider));
}

FFI_PLUGIN_EXPORT size_t zd_shm_mut_sizeof(void) {
  return sizeof(z_owned_shm_mut_t);
}

// The strategy dispatch codes. Internal to this seam: canon has no strategy
// enum at all -- it ships ten separately-named symbols, and Dart cannot select
// a C symbol at run time -- so the code crosses as an int and this file
// dispatches on it. Written out here and in the header, never derived.
#define ZD_SHM_STRATEGY_PLAIN 0
#define ZD_SHM_STRATEGY_GC 1
#define ZD_SHM_STRATEGY_GC_DEFRAG 2
#define ZD_SHM_STRATEGY_GC_DEFRAG_DEALLOC 3
#define ZD_SHM_STRATEGY_GC_DEFRAG_BLOCKING 4

// Argument rejected; nothing ran. Positive, matching ZD_DECLARE_ECAPACITY's
// meaning on the declare-channel entries -- one meaning per positive code,
// repo-wide. Here the whole rc space is free (canon's ten sync entries return
// void), so this cannot collide with a canon code in either sign.
#define ZD_SHM_EARG 10

FFI_PLUGIN_EXPORT int8_t zd_shm_provider_alloc(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    int64_t size,
    int32_t strategy,
    int32_t alignment_pow,
    zd_shm_alloc_result_t* out) {
  // Validation FIRST, and before a single byte is written anywhere: that is
  // what makes rc 10 mean "nothing ran, your out-params are as you left them"
  // rather than "something ran and I am not telling you how far it got".
  if (size < 0) {
    return ZD_SHM_EARG;
  }
#if SIZE_MAX < INT64_MAX
  // Live on ILP32: a size above SIZE_MAX would truncate to a smaller WORKING
  // size, i.e. a silent transform. SHM is platform-clamped off on the only
  // 32-bit targets this product ships (both Android ABIs are 64-bit), so this
  // arm is unreachable today; it is the structural backstop, not the guard of
  // record, which is Dart-side.
  if (size > (int64_t)SIZE_MAX) {
    return ZD_SHM_EARG;
  }
#endif
  // -1 is the unaligned sentinel; 0..255 is canon's own uint8_t domain.
  if (alignment_pow < -1 || alignment_pow > 255) {
    return ZD_SHM_EARG;
  }
  if (strategy < ZD_SHM_STRATEGY_PLAIN ||
      strategy > ZD_SHM_STRATEGY_GC_DEFRAG_BLOCKING) {
    return ZD_SHM_EARG;
  }

  z_buf_layout_alloc_result_t result;
  const size_t alloc_size = (size_t)size;
  if (alignment_pow < 0) {
    switch (strategy) {
      case ZD_SHM_STRATEGY_GC:
        z_shm_provider_alloc_gc(&result, provider, alloc_size);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG:
        z_shm_provider_alloc_gc_defrag(&result, provider, alloc_size);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG_DEALLOC:
        z_shm_provider_alloc_gc_defrag_dealloc(&result, provider, alloc_size);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG_BLOCKING:
        z_shm_provider_alloc_gc_defrag_blocking(&result, provider, alloc_size);
        break;
      case ZD_SHM_STRATEGY_PLAIN:
      default:
        z_shm_provider_alloc(&result, provider, alloc_size);
        break;
    }
  } else {
    z_alloc_alignment_t alignment;
    alignment.pow = (uint8_t)alignment_pow;
    switch (strategy) {
      case ZD_SHM_STRATEGY_GC:
        z_shm_provider_alloc_gc_aligned(&result, provider, alloc_size,
                                        alignment);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG:
        z_shm_provider_alloc_gc_defrag_aligned(&result, provider, alloc_size,
                                               alignment);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG_DEALLOC:
        z_shm_provider_alloc_gc_defrag_dealloc_aligned(&result, provider,
                                                       alloc_size, alignment);
        break;
      case ZD_SHM_STRATEGY_GC_DEFRAG_BLOCKING:
        z_shm_provider_alloc_gc_defrag_blocking_aligned(&result, provider,
                                                        alloc_size, alignment);
        break;
      case ZD_SHM_STRATEGY_PLAIN:
      default:
        z_shm_provider_alloc_aligned(&result, provider, alloc_size, alignment);
        break;
    }
  }

  // Branch on status; carry ONLY the field the status selects. The other gets
  // -1, which is outside both canon domains. Canon backfills the unselected
  // field with an arbitrary real member (on OK: alloc_error = OTHER,
  // layout_error = PROVIDER_INCOMPATIBLE_LAYOUT), and forwarding all three
  // fields as independently meaningful is exactly how that garbage would reach
  // a consumer wearing the costume of a diagnosis.
  out->status = (int8_t)result.status;
  out->alloc_error = -1;
  out->layout_error = -1;
  switch (result.status) {
    case ZC_BUF_LAYOUT_ALLOC_STATUS_OK:
      *buf = result.buf;
      break;
    case ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR:
      out->alloc_error = (int8_t)result.alloc_error;
      break;
    case ZC_BUF_LAYOUT_ALLOC_STATUS_LAYOUT_ERROR:
      out->layout_error = (int8_t)result.layout_error;
      break;
    default:
      // A status outside canon's own domain. It crosses VERBATIM rather than
      // being smoothed into one of the three: the Dart decode seam reports it
      // as a contract violation, which is the only honest rendering of "canon
      // said something this binding was not written against".
      break;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// The ASYNC allocation entry
// ---------------------------------------------------------------------------

// Shim-owned heap failure; nothing started. Positive, and the SAME MEANING 12
// already carries on the open channel ("a heap allocation failed; nothing
// started") -- one meaning per positive code, repo-wide, so a reader never has
// to check the mapping per site.
#define ZD_SHM_EALLOC 12

/// The shim-owned box that outlives BOTH parties, so the provider drop can be
/// deferred safely.
///
/// ⛔ WHY A SECOND BLOCK EXISTS AT ALL. Dropping a provider while canon still
/// holds a request against it FAULTS -- measured 3/3 against a clean control.
/// So `close()` cannot drop, and something has to drop later. That something
/// cannot be the callback context: canon frees it through `delete_fn` at a
/// time neither side controls, so a Dart-held handle to it would dangle.
///
/// This box is refcounted instead. **Whoever decrements it to zero performs
/// the drop** -- one release point, rather than two branches that have to
/// agree. Refs start at 2: one for Dart, one for canon.
typedef struct {
  pthread_mutex_t mu;
  int refs;
  /// ⛔ `completed` WAS HERE AND IS REMOVED, 2026-09-03 at the merge gate.
  /// Its only consumer was the `defer_drop` gate that the same gate's F-3
  /// repair deleted, so it was written on every completion and read nowhere.
  /// ⚠️ Dead state that implies a synchronisation decision which no longer
  /// exists is worse than no state: the next reader reasons about a race the
  /// field is not protecting against.
  /// The provider slot, non-NULL only once Dart has handed ownership over at
  /// `close()`. ⚠️ OWNERSHIP MOVES with it: the shim drops the content AND
  /// frees the block, because Dart cannot know when it becomes safe to.
  z_owned_shm_provider_t* deferred_owner;
} zd_shm_async_box_t;

static void _zd_shm_box_release(zd_shm_async_box_t* box) {
  pthread_mutex_lock(&box->mu);
  const int remaining = --box->refs;
  z_owned_shm_provider_t* owner = NULL;
  if (remaining == 0) {
    owner = box->deferred_owner;
    box->deferred_owner = NULL;
  }
  pthread_mutex_unlock(&box->mu);
  if (remaining > 0) return;

  // The last reference. Nobody else can reach this box, so the drop happens
  // outside the lock and the box is destroyed after it.
  if (owner != NULL) {
    z_shm_provider_drop(z_shm_provider_move(owner));
    free(owner);
  }
  pthread_mutex_destroy(&box->mu);
  free(box);
}

/// Everything canon can still reach after the wrapper returns.
///
/// ⛔ HEAP-OWNED, and it has to be. Canon writes its outcome into
/// `result` from a background thread at an unpredictable later time, so a
/// wrapper stack local would be a use-after-return the moment the wrapper
/// returns ahead of the allocation. zenoh-cpp reaches the same shape from the
/// other direction: its receiver is heap-allocated and owns `_result` as a
/// member (`shm_provider.hxx:29-48`).
typedef struct {
  z_buf_layout_alloc_result_t result;
  Dart_Port_DL dart_port;
  zd_shm_async_box_t* box;
} zd_shm_async_ctx_t;

/// Canon's designated release point for the context.
///
/// ⚠️ MEASURED: canon runs this whenever it COMPLETES the request -- on the OK
/// arm and on the layout-refusal arm alike. It does NOT run for a request the
/// pool can never satisfy, because canon never completes that one at all; that
/// context is leaked for the life of the process and there is no entry to
/// reclaim it. Recorded at `development/research/probes-ci-shm-20260902/`.
static void _zd_shm_async_delete(void* context) {
  zd_shm_async_ctx_t* ctx = (zd_shm_async_ctx_t*)context;
  // Canon is done with this request. Releasing its reference is what lets a
  // deferred provider drop finally happen -- and it happens HERE rather than
  // in the result callback because canon guarantees this runs after the last
  // callback returns, which is the only point at which canon is provably
  // finished with the provider.
  _zd_shm_box_release(ctx->box);
  free(ctx);
}

/// Canon's result callback. Runs on a NON-CALLER thread.
///
/// ⛔ THE BUFFER IS TAKEN OUT HERE, NOT BY DART LATER, and that is load-bearing
/// rather than stylistic. Canon guarantees `delete_fn` only "at some point of
/// time after the last associated callback call returns" -- so by the time Dart
/// reads the post, the context may already be freed. Moving the buffer into its
/// own block now means the handle Dart receives outlives the context.
///
/// zenoh-cpp does not need this because it does its work INSIDE the callback;
/// this bridge posts and returns, which is exactly the window canon reserves.
static void _zd_shm_async_result(void* context,
                                 z_buf_layout_alloc_result_t* result) {
  zd_shm_async_ctx_t* ctx = (zd_shm_async_ctx_t*)context;

  int64_t buf_handle = 0;
  int64_t status = (int64_t)result->status;
  int64_t alloc_error = -1;
  int64_t layout_error = -1;

  switch (result->status) {
    case ZC_BUF_LAYOUT_ALLOC_STATUS_OK: {
      z_owned_shm_mut_t* buf =
          (z_owned_shm_mut_t*)malloc(sizeof(z_owned_shm_mut_t));
      if (buf == NULL) {
        // Nothing can carry the buffer to Dart, so release the CHUNK rather
        // than leaking it, and let the OK-with-no-handle pair say so. Canon's
        // OK arm always carries a buffer, so handle 0 on status 0 is
        // unambiguous and needs no code of its own.
        z_shm_mut_drop(z_shm_mut_move(&result->buf));
      } else {
        // POD move: the same struct copy `zd_shm_provider_alloc` already
        // performs on its own OK arm. Canon's delete_fn frees the context
        // without dropping the result's buffer, so the content is ours to
        // take.
        *buf = result->buf;
        buf_handle = (int64_t)(intptr_t)buf;
      }
      break;
    }
    case ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR:
      alloc_error = (int64_t)result->alloc_error;
      break;
    case ZC_BUF_LAYOUT_ALLOC_STATUS_LAYOUT_ERROR:
      layout_error = (int64_t)result->layout_error;
      break;
    default:
      // Outside canon's own domain: it crosses VERBATIM, and the Dart decode
      // seam reports it as a contract violation. Smoothing it into one of the
      // three would be inventing an outcome canon did not report.
      break;
  }

  Dart_CObject c_status, c_alloc, c_layout, c_buf;
  c_status.type = Dart_CObject_kInt64;
  c_status.value.as_int64 = status;
  c_alloc.type = Dart_CObject_kInt64;
  c_alloc.value.as_int64 = alloc_error;
  c_layout.type = Dart_CObject_kInt64;
  c_layout.value.as_int64 = layout_error;
  c_buf.type = Dart_CObject_kInt64;
  c_buf.value.as_int64 = buf_handle;

  Dart_CObject* elements[4] = {&c_status, &c_alloc, &c_layout, &c_buf};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 4;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
    // The port is closed, so nobody will ever call the take entry and the
    // buffer would be stranded. Release it here -- one release point per path.
    if (buf_handle != 0) {
      z_owned_shm_mut_t* buf = (z_owned_shm_mut_t*)(intptr_t)buf_handle;
      z_shm_mut_drop(z_shm_mut_move(buf));
      free(buf);
    }
  }
  // ⛔ The context is NOT freed here. Canon calls _zd_shm_async_delete for it,
  // and freeing it twice is the double-free this split exists to avoid.
}

FFI_PLUGIN_EXPORT int8_t zd_shm_provider_alloc_async(
    const z_loaned_shm_provider_t* provider,
    int64_t size,
    int64_t dart_port,
    int64_t* out_box) {
  if (out_box != NULL) *out_box = 0;
  // ⛔ EVERY SHIM-SIDE REJECTION HAPPENS BEFORE THE CONTEXT EXISTS. That
  // ordering is what makes the ownership question decidable: on a positive
  // return canon has never seen a context, so there is nothing to double-free
  // and nothing to leak.
  if (size < 0) {
    return ZD_SHM_EARG;
  }
#if SIZE_MAX < INT64_MAX
  if (size > (int64_t)SIZE_MAX) {
    return ZD_SHM_EARG;
  }
#endif

  zd_shm_async_box_t* box =
      (zd_shm_async_box_t*)malloc(sizeof(zd_shm_async_box_t));
  if (box == NULL) {
    return ZD_SHM_EALLOC;
  }
  memset(box, 0, sizeof(*box));
  if (pthread_mutex_init(&box->mu, NULL) != 0) {
    free(box);
    return ZD_SHM_EALLOC;
  }
  // Two references: one Dart's, released at close(); one canon's, released by
  // delete_fn. Set BEFORE the call, so nothing can decrement a count that has
  // not been established yet.
  box->refs = 2;

  zd_shm_async_ctx_t* ctx =
      (zd_shm_async_ctx_t*)malloc(sizeof(zd_shm_async_ctx_t));
  if (ctx == NULL) {
    pthread_mutex_destroy(&box->mu);
    free(box);
    return ZD_SHM_EALLOC;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->dart_port = (Dart_Port_DL)dart_port;
  ctx->box = box;

  zc_threadsafe_context_t canon_ctx;
  canon_ctx.context.ptr = ctx;
  canon_ctx.delete_fn = _zd_shm_async_delete;

  z_result_t rc = z_shm_provider_alloc_gc_defrag_async(
      &ctx->result, provider, (size_t)size, canon_ctx, _zd_shm_async_result);
  if (rc != 0) {
    // ⛔ MEASURED UNREACHABLE ON THE PROVIDER THIS BINDING CONSTRUCTS: canon's
    // rc is zero for every size in the domain, swept to SIZE_MAX. Canon
    // documents Z_EINVAL for a NON-THREADSAFE provider, and ours was measured
    // to be accepted.
    //
    // ⚠️ The context is deliberately NOT freed on this branch. Canon's own
    // note leaves it unstated whether a REJECTED call counts as "moved to
    // zenoh-c ownership", and the two answers give opposite code: freeing when
    // canon took it is a double free; not freeing when it did not is a leak.
    // On an unreachable path a leak is strictly the safer half of that pair.
    // The box is left with it, for the same reason.
    return (int8_t)rc;
  }
  if (out_box != NULL) *out_box = (int64_t)(intptr_t)box;
  return 0;
}

/// Hands the provider slot to the box. UNCONDITIONALLY.
///
/// @return 1  the box took it — the normal answer. The caller must NOT drop
///            and must NOT free the slot: the shim does both when the last
///            reference goes.
///         0  ONLY when an argument was null. Nothing was taken.
///
/// ⚠️ **CORRECTED 2026-09-03 at the merge gate.** This block previously said
/// the decision *"is made UNDER THE LOCK, against `completed`"* — twelve lines
/// above the comment explaining that it is unconditional. It described a gate
/// the implementation had already lost, and it is exactly the kind of stale
/// contract a reader trusts because it sounds like a synchronisation argument.
///
/// The lock is still taken, and still for a real reason: the result callback
/// can be running on another thread at this instant, so the WRITE has to be
/// serialised against `_zd_shm_box_release`. What the lock does NOT do any
/// more is decide anything.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_defer_drop(
    int64_t box_handle,
    z_owned_shm_provider_t* provider) {
  if (box_handle == 0 || provider == NULL) {
    return 0;
  }
  zd_shm_async_box_t* box = (zd_shm_async_box_t*)(intptr_t)box_handle;
  pthread_mutex_lock(&box->mu);
  // ⛔ UNCONDITIONAL, AND AN EARLIER CUT GATED THIS ON `completed`. The gate
  // looked right -- "canon has finished, so the caller may drop directly" --
  // and it was wrong for the way this is actually used: the slot is handed
  // over when a request STARTS, and canon can satisfy a small request from a
  // fresh pool INSIDE the call that starts it. The callback then runs before
  // the handover, `completed` is already 1, the gate refuses the slot, and
  // NOTHING ever drops the provider. Measured: the provider-level reading
  // stayed +65536 through forty rounds of convergence.
  //
  // Taking it unconditionally is correct on every path, because the drop
  // happens at the LAST reference rather than on this call: if canon is
  // already done, its reference is already gone and the caller's release is
  // the last one.
  box->deferred_owner = provider;
  pthread_mutex_unlock(&box->mu);
  return 1;
}

/// Takes the provider slot back OUT of the box, without dropping it.
///
/// ⛔ WHY THIS EXISTS. The slot is handed to a box when a request STARTS, so
/// that a finalizer -- which has no way to reach a box handle -- can defer
/// through it. A second request gets a NEW box, and the slot has to move: left
/// on the old one, releasing it would drop a provider that is still in use.
///
/// @return 1 if the slot was taken back, 0 if the box did not hold it.
FFI_PLUGIN_EXPORT int8_t zd_shm_provider_undefer_drop(int64_t box_handle) {
  if (box_handle == 0) return 0;
  zd_shm_async_box_t* box = (zd_shm_async_box_t*)(intptr_t)box_handle;
  pthread_mutex_lock(&box->mu);
  const int had = box->deferred_owner != NULL;
  box->deferred_owner = NULL;
  pthread_mutex_unlock(&box->mu);
  return (int8_t)had;
}

/// `ShmProvider`'s net WHILE A REQUEST HAS BEEN STARTED: release the box.
///
/// ⛔⛔ WHY THE NET SWAPS AT ALL. The ordinary entry drops the provider
/// directly, and dropping a provider while canon holds a request against it
/// FAULTS -- measured 3/3 by explicit drop, and 3/3 again through the
/// FINALIZER itself once the pool is exhausted so canon has a live waiter.
/// ⚠️ That second measurement matters: a first attempt to drive this used a
/// request four times the pool, which canon parks with no waiter, and it
/// survived 5/5 -- a green that proved nothing, on a state that cannot crash.
///
/// This entry drops nothing. It releases the collecting side's reference, and
/// the provider is dropped by whichever party releases the LAST one -- which
/// is the only point at which canon is provably finished with it.
FFI_PLUGIN_EXPORT void zd_fin_shm_provider_deferred(void* token) {
  zd_fin_note(ZD_FIN_KIND_SHM_PROVIDER_DEFERRED);
  _zd_shm_box_release((zd_shm_async_box_t*)token);
}

/// Releases DART's reference to the box.
///
/// Called once per started request, at `close()` or when the provider starts
/// its next request -- never from the result handler, because the handle must
/// still be valid for `zd_shm_provider_defer_drop`.
FFI_PLUGIN_EXPORT void zd_shm_async_box_release(int64_t box_handle) {
  if (box_handle == 0) return;
  _zd_shm_box_release((zd_shm_async_box_t*)(intptr_t)box_handle);
}

FFI_PLUGIN_EXPORT void zd_shm_async_take(int64_t buf_handle,
                                         z_owned_shm_mut_t* out) {
  z_owned_shm_mut_t* buf = (z_owned_shm_mut_t*)(intptr_t)buf_handle;
  // Content moves to the caller's slot; the shim's block is released here, so
  // each allocator frees its own -- the FFI ownership rule.
  *out = *buf;
  free(buf);
}

FFI_PLUGIN_EXPORT size_t zd_shm_provider_defragment(
    const z_loaned_shm_provider_t* provider) {
  return z_shm_provider_defragment(provider);
}

FFI_PLUGIN_EXPORT size_t zd_shm_provider_garbage_collect(
    const z_loaned_shm_provider_t* provider) {
  return z_shm_provider_garbage_collect(provider);
}

FFI_PLUGIN_EXPORT z_loaned_shm_mut_t* zd_shm_mut_loan_mut(
    z_owned_shm_mut_t* buf) {
  return z_shm_mut_loan_mut(buf);
}

FFI_PLUGIN_EXPORT uint8_t* zd_shm_mut_data_mut(z_loaned_shm_mut_t* buf) {
  return z_shm_mut_data_mut(buf);
}

FFI_PLUGIN_EXPORT size_t zd_shm_mut_len(const z_loaned_shm_mut_t* buf) {
  return z_shm_mut_len(buf);
}

FFI_PLUGIN_EXPORT int zd_bytes_from_shm_mut(z_owned_bytes_t* bytes,
                                            z_owned_shm_mut_t* buf) {
  return z_bytes_from_shm_mut(bytes, z_shm_mut_move(buf));
}

FFI_PLUGIN_EXPORT void zd_shm_mut_drop(z_owned_shm_mut_t* buf) {
  z_shm_mut_drop(z_shm_mut_move(buf));
}

FFI_PLUGIN_EXPORT int8_t zd_bytes_is_shm(const uint8_t* bytes) {
  const z_owned_bytes_t* owned = (const z_owned_bytes_t*)bytes;
  const z_loaned_bytes_t* loaned = z_bytes_loan(owned);
  const z_loaned_shm_t* shm = NULL;
  z_result_t rc = z_bytes_as_loaned_shm(loaned, &shm);
  return (rc == 0) ? 1 : 0;
}

#endif // Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API

// ---------------------------------------------------------------------------
// Pull Subscriber (ring and fifo sample channels)
// ---------------------------------------------------------------------------



FFI_PLUGIN_EXPORT int32_t zd_pull_handler_sizeof(int32_t kind) {
  return kind == ZD_CHANNEL_FIFO
             ? (int32_t)sizeof(z_owned_fifo_handler_sample_t)
             : (int32_t)sizeof(z_owned_ring_handler_sample_t);
}

/// Builds a bounded SAMPLE channel of `kind` at `capacity` and interposes the
/// readiness tee — the sample column's counterpart to
/// `_zd_reply_channel_build`, shared by the pull subscriber and the pull
/// liveliness subscriber.
///
/// On success `*tee_closure_out` is the closure to hand canon and `*tee_out` is
/// the context. On failure NOTHING is left claimed.
static int8_t _zd_sample_channel_build(
    uint8_t* handler_out, int32_t kind, int64_t capacity, int64_t dart_port,
    z_owned_closure_sample_t* tee_closure_out, zd_pull_tee_t** tee_out) {
  *tee_out = NULL;
  // CAPACITY: rejected loudly BEFORE anything is allocated, never silently
  // transformed. Canon's capacity is a `size_t` and its constructor returns
  // void -- it cannot fail and cannot reject a capacity -- so every domain
  // check that exists at all has to exist here.
  if (capacity < 0) {
    return ZD_DECLARE_ECAPACITY;
  }
#if SIZE_MAX < INT64_MAX
  // ⚠️ LIVE ON ILP32, WHICH THIS PRODUCT SHIPS: a capacity of 2^32 would
  // truncate to 0 -- a WORKING capacity, i.e. a silent transform of exactly the
  // class the no-truncation property bars.
  if (capacity > (int64_t)SIZE_MAX) {
    return ZD_DECLARE_ECAPACITY;
  }
#endif

  z_owned_closure_sample_t closure;
  if (kind == ZD_CHANNEL_FIFO) {
    z_fifo_channel_sample_new(
        &closure, (z_owned_fifo_handler_sample_t*)handler_out,
        (size_t)capacity);
  } else {
    z_ring_channel_sample_new(
        &closure, (z_owned_ring_handler_sample_t*)handler_out,
        (size_t)capacity);
  }

  // ALLOCATE-LAST: the tee context is claimed only after everything that can
  // fail without it has succeeded.
  zd_pull_tee_t* tee = (zd_pull_tee_t*)malloc(sizeof(zd_pull_tee_t));
  if (!tee) {
    z_closure_sample_drop(z_closure_sample_move(&closure));
    zd_pull_handler_drop(handler_out, kind);
    return ZD_DECLARE_EALLOC;
  }

  // Move canon's channel closure into heap-owned storage. The move macros are
  // pointer casts, not copies, so a stack local here would become a
  // use-after-return the moment the caller returns ahead of a delivery.
  tee->inner = closure;
  z_internal_closure_sample_null(&closure);
  _zd_tee_head_init(&tee->head, dart_port);

  // Our closure stands where canon's would have stood.
  z_closure_sample(tee_closure_out, _zd_pull_tee_on_call, _zd_pull_tee_on_drop,
                   tee);
  *tee_out = tee;
  return 0;
}

/// Releases a channel built by `_zd_sample_channel_build` when the canon entry
/// meant to consume its closure failed.
static void _zd_sample_channel_abandon_built(
    uint8_t* handler_out, int32_t kind,
    z_owned_closure_sample_t* tee_closure, zd_pull_tee_t* tee) {
  if (z_internal_closure_sample_check(tee_closure)) {
    z_closure_sample_drop(z_closure_sample_move(tee_closure));
  }
  zd_pull_tee_drop((uint8_t*)tee);
  zd_pull_handler_drop(handler_out, kind);
}

FFI_PLUGIN_EXPORT int8_t zd_declare_pull_subscriber(
    uint8_t* subscriber_out, uint8_t* handler_out, uint8_t** tee_out,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, int allowed_origin,
    int64_t dart_port) {
  z_owned_closure_sample_t tee_closure;
  zd_pull_tee_t* tee;
  int8_t build_rc = _zd_sample_channel_build(
      handler_out, kind, capacity, dart_port, &tee_closure, &tee);
  if (build_rc != 0) {
    *tee_out = NULL;
    return build_rc;
  }

  // `z_subscriber_options_t` is introduced here. Negative means "unspecified"
  // -- leave z_subscriber_options_default's value (ANY).
  z_subscriber_options_t opts;
  z_subscriber_options_default(&opts);
  if (allowed_origin >= 0) {
    opts.allowed_origin = (z_locality_t)allowed_origin;
  }

  // Declare the subscriber with the TEE closure, not canon's.
  int rc = z_declare_subscriber(
      (const z_loaned_session_t*)session,
      (z_owned_subscriber_t*)subscriber_out,
      key_expr,
      z_closure_sample_move(&tee_closure),
      &opts);

  if (rc != 0) {
    _zd_sample_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;

  // Canon's own code, passed through unchanged. Negative means canon refused;
  // the shim's own refusals are the positives returned above.
  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_declare_pull_liveliness_subscriber(
    uint8_t* subscriber_out, uint8_t* handler_out, uint8_t** tee_out,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, int8_t history, int64_t dart_port) {
  // THE THINNEST CARRIER OF THE FIVE. Canon's liveliness declare consumes the
  // SAMPLE closure, so this reuses the sample column's shared channel build,
  // its handlers, its extraction body and its `PullSubscriber` handle
  // wholesale. Only the canon entry and its options struct differ -- and that
  // struct carries exactly one field.
  z_owned_closure_sample_t tee_closure;
  zd_pull_tee_t* tee;
  int8_t build_rc = _zd_sample_channel_build(
      handler_out, kind, capacity, dart_port, &tee_closure, &tee);
  if (build_rc != 0) {
    *tee_out = NULL;
    return build_rc;
  }

  z_liveliness_subscriber_options_t opts;
  z_liveliness_subscriber_options_default(&opts);
  opts.history = (bool)history;

  int rc = z_liveliness_declare_subscriber(
      (const z_loaned_session_t*)session,
      (z_owned_subscriber_t*)subscriber_out,
      key_expr,
      z_closure_sample_move(&tee_closure),
      &opts);

  if (rc != 0) {
    _zd_sample_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;
  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_pull_subscriber_try_recv(
    const uint8_t* handler, int32_t kind,
    uint8_t** out_keyexpr, size_t* out_keyexpr_len,
    uint8_t** out_payload, size_t* out_payload_len,
    int8_t* out_kind, char** out_encoding, size_t* out_encoding_len,
    uint8_t** out_attachment, size_t* out_attachment_len,
    uint8_t** out_timestamp, int8_t* out_priority,
    int8_t* out_congestion, int8_t* out_express,
    uint8_t* retain_slot, int32_t* out_has_retained) {
  // Seed [10a]: default BEFORE any early return, so an EMPTY or DISCONNECTED
  // result never leaves the caller reading an uninitialised flag and freeing a
  // slot that was never filled.
  if (out_has_retained != NULL) *out_has_retained = 0;

  // The ONLY kind-dependent lines in this function. Everything past the
  // discriminant check is one shared extraction body serving both kinds --
  // ~165 lines carrying twelve out-params, four remote-length-driven malloc
  // guards and the encoding render. Duplicating that per kind would double the
  // fidelity surface and split every future fix across two sites.
  z_owned_sample_t sample;
  z_result_t res;
  if (kind == ZD_CHANNEL_FIFO) {
    const z_loaned_fifo_handler_sample_t* h = z_fifo_handler_sample_loan(
        (const z_owned_fifo_handler_sample_t*)handler);
    res = z_fifo_handler_sample_try_recv(h, &sample);
  } else {
    const z_loaned_ring_handler_sample_t* h = z_ring_handler_sample_loan(
        (const z_owned_ring_handler_sample_t*)handler);
    res = z_ring_handler_sample_try_recv(h, &sample);
  }

  if (res == Z_CHANNEL_DISCONNECTED) {
    return 1;  // channel disconnected
  }
  if (res == Z_CHANNEL_NODATA) {
    return 2;  // buffer empty
  }

  // res == Z_OK: extract sample fields
  const z_loaned_sample_t* s = z_sample_loan(&sample);

  // 1. Key expression
  z_view_string_t key_view;
  z_keyexpr_as_view_string(z_sample_keyexpr(s), &key_view);
  const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
  size_t key_len = z_string_len(key_loaned);
  const char* key_data = z_string_data(key_loaned);
  // REMOTE-LENGTH-DRIVEN, all four allocations below. Each is sized by the
  // publisher, so on a memory-constrained target they can fail with no bug on
  // our side; an unguarded malloc + memcpy writes through NULL.
  //
  // The -1 these guards return now reaches Dart as a THROWN ZenohException.
  // (It used to be collapsed into the same `null` as an empty buffer, so an
  // out-of-memory presented to the caller as "nothing available". The TODO
  // that recorded that gap is retired here: the result contract it was
  // waiting on -- sealed data/empty/disconnected, with call failures thrown
  // -- is in place.)
  //
  // Length-carried: the caller reads `*out_keyexpr_len` bytes and never
  // measures with strlen, so an interior NUL survives -- the same contract the
  // callback postings carry (see _zd_str_to_cobject). The trailing NUL below
  // is hygiene only; nothing reads it, and it is what keeps the allocation
  // non-zero for the (grammar-excluded) empty key expression.
  *out_keyexpr = (uint8_t*)malloc(key_len + 1);
  if (!*out_keyexpr) {
    *out_keyexpr_len = 0;
    z_sample_drop(z_sample_move(&sample));
    return -1;
  }
  memcpy(*out_keyexpr, key_data, key_len);
  (*out_keyexpr)[key_len] = '\0';
  *out_keyexpr_len = key_len;

  // 2. Payload as bytes (byte-faithful reader pattern, per zd_bytes_to_buf).
  // Check the reader rc and report ACTUAL bytes read, so a short read never
  // exposes an uninitialized tail to the caller.
  const z_loaned_bytes_t* payload_loaned = z_sample_payload(s);
  size_t payload_byte_len = z_bytes_len(payload_loaned);
  if (payload_byte_len > 0) {
    *out_payload = (uint8_t*)malloc(payload_byte_len);
    if (!*out_payload) {
      free(*out_keyexpr);
      *out_keyexpr = NULL;
      *out_keyexpr_len = 0;
      z_sample_drop(z_sample_move(&sample));
      return -1;
    }
    z_bytes_reader_t pl_reader = z_bytes_get_reader(payload_loaned);
    size_t pl_read = z_bytes_reader_read(&pl_reader, *out_payload,
                                         payload_byte_len);
    *out_payload_len = pl_read;
  } else {
    *out_payload = NULL;
    *out_payload_len = 0;
  }


  // 3. Kind
  *out_kind = (int8_t)z_sample_kind(s);

  // 4. Encoding
  const z_loaned_encoding_t* encoding = z_sample_encoding(s);
  z_owned_string_t enc_str;
  z_encoding_to_string(encoding, &enc_str);
  const z_loaned_string_t* enc_loaned = z_string_loan(&enc_str);
  size_t enc_len = z_string_len(enc_loaned);
  const char* enc_data = z_string_data(enc_loaned);
  // D-7 ALIGNMENT: allocate UNCONDITIONALLY, exactly as the subscriber
  // callback path does at _zd_sample_callback. This branch used to read
  //
  //     if (enc_len > 0) { ...malloc... } else { *out_encoding = NULL; }
  //
  // so a rendered encoding of zero length surfaced in Dart as `null`
  // (ABSENT) here and as `''` (PRESENT BUT EMPTY) on the callback path --
  // the same wire sample yielding two different Dart values depending on
  // which receive surface you used. malloc(enc_len + 1) is >= 1 byte, so the
  // pointer is non-NULL for a zero-length encoding too and Dart renders ''.
  //
  // ⚠️ VERIFICATION CLASS -- and the behavioural leg NOW EXISTS. This used to
  // read "verified STRUCTURALLY ... no behavioural leg is claimed", because the
  // enc_len == 0 cell is unreachable from our public API: it needs a wire peer
  // sending an id-0xFFFF-no-schema encoding. Seed #10 built that peer.
  // `package/test/helpers/encoding_peer.c`'s PUB_EMPTY mode constructs exactly
  // that state through `zc_internal_encoding_from_data({65535, NULL, 0})` --
  // guard depth 0, so it compiles on both variants -- and
  // `encoding_receive_fidelity_test.dart`'s "the push and pull surfaces agree
  // on present-but-empty" observes the SAME wire sample through a push
  // Subscriber and a PullSubscriber, asserting '' on both and null on neither.
  // That closes the open question seed #5's plan archive recorded at
  // development/planning/20260818_1030_seed5_ch_channels.md:294-296.
  //
  // Because one shared extraction body serves both kinds, this lands ONCE
  // and covers ring and fifo alike.
  *out_encoding = (char*)malloc(enc_len + 1);
  if (!*out_encoding) {
    z_string_drop(z_string_move(&enc_str));
    free(*out_keyexpr);
    *out_keyexpr = NULL;
    *out_keyexpr_len = 0;
    free(*out_payload);
    *out_payload = NULL;
    *out_payload_len = 0;
    z_sample_drop(z_sample_move(&sample));
    return -1;
  }
  memcpy(*out_encoding, enc_data, enc_len);
  (*out_encoding)[enc_len] = '\0';
  // LENGTH-CARRIED: the trailing NUL is hygiene, the length is the contract.
  *out_encoding_len = enc_len;
  z_string_drop(z_string_move(&enc_str));

  // 5. Attachment (nullable; byte-faithful reader pattern). Empty != absent:
  // a present-but-empty attachment must surface as a non-NULL pointer with
  // len 0 (matching the subscriber callback discipline), while an absent
  // attachment is NULL. We malloc at least 1 byte so the pointer is non-NULL
  // even for a zero-length attachment; the caller distinguishes on the
  // pointer, not the length. Check the reader rc and report actual bytes read.
  const z_loaned_bytes_t* attachment = z_sample_attachment(s);
  if (attachment != NULL) {
    size_t att_len = z_bytes_len(attachment);
    *out_attachment = (uint8_t*)malloc(att_len > 0 ? att_len : 1);
    if (!*out_attachment) {
      free(*out_keyexpr);
      *out_keyexpr = NULL;
      *out_keyexpr_len = 0;
      free(*out_payload);
      *out_payload = NULL;
      *out_payload_len = 0;
      free(*out_encoding);
      *out_encoding = NULL;
      z_sample_drop(z_sample_move(&sample));
      return -1;
    }
    if (att_len > 0) {
      z_bytes_reader_t att_reader = z_bytes_get_reader(attachment);
      size_t att_read = z_bytes_reader_read(&att_reader, *out_attachment,
                                            att_len);
      *out_attachment_len = att_read;
    } else {
      *out_attachment_len = 0;
    }
  } else {
    *out_attachment = NULL;
    *out_attachment_len = 0;
  }

  // 6. Timestamp (nullable — present/absent by pointer null; malloc'd, Dart
  // frees). Copy the 24 raw z_timestamp_t bytes so the caller can re-represent
  // it bit-exact.
  const z_timestamp_t* ts = z_sample_timestamp(s);
  if (ts != NULL) {
    *out_timestamp = (uint8_t*)malloc(24);
    memcpy(*out_timestamp, ts, 24);
  } else {
    *out_timestamp = NULL;
  }

  // 7. QoS metadata.
  *out_priority = (int8_t)z_sample_priority(s);           // 1..7
  // 0=block, 1=drop, 2=blockFirst (the true domain -- see zd_put above).
  *out_congestion = (int8_t)z_sample_congestion_control(s);
  *out_express = z_sample_express(s) ? 1 : 0;

  // Seed [10a]: the retained payload handle, on the PULL path.
  //
  // Unlike the push columns this needs no cross-thread post and no byte image:
  // the shim already owns the container on DART'S OWN THREAD at the moment
  // Dart asks, so the clone goes straight into a caller-supplied slot. NULL
  // means "do not retain" and costs nothing.
  //
  // ⛔ TAKEN LAST, AND THAT POSITION IS THE WHOLE FIX. It was first written
  // beside the payload copy, high up -- where later `return -1` paths (the
  // encoding, attachment and timestamp mallocs) each returned WITHOUT dropping
  // it. Neither side reclaimed: the shim returned an error, and Dart's
  // `finally` freed the raw slot with a bare `calloc.free` rather than a
  // `zd_bytes_drop`, so the payload's refcount was never decremented.
  // MEASURED by injecting a failure at the encoding malloc -- 26,092 KB of RSS
  // growth over 100 rounds of a 256 KiB payload, against 532 KB when the
  // injected site sat BEFORE the clone.
  //
  // Placing it after every fallible allocation REMOVES the failure window
  // rather than handling it at each site: there is now no `return -1` between
  // the clone and the caller taking ownership.
  if (retain_slot != NULL) {
    z_bytes_clone((z_owned_bytes_t*)retain_slot, payload_loaned);
    if (out_has_retained != NULL) *out_has_retained = 1;
  } else if (out_has_retained != NULL) {
    *out_has_retained = 0;
  }

  // Drop the owned sample
  z_sample_drop(z_sample_move(&sample));

  return 0;  // success
}

// ---------------------------------------------------------------------------
// Reply channels: canon's bounded fifo/ring delivery on the get paths.
//
// The sample column shipped at seed #5; this is the reply column. The shape is
// the same -- a channel constructor writes a closure and a handler, the closure
// goes to canon and the handler stays with us -- but the LIFECYCLE differs, and
// the difference is canon's own: a reply closure "will be automatically dropped
// once all replies are processed", so a reply channel SELF-TERMINATES at query
// completion. There is no entity to undeclare and nothing for a `close()` to
// tell a peer, which is why the Dart handle's release is `dispose()` rather
// than `close()`.
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int32_t zd_reply_handler_sizeof(int32_t kind) {
  return kind == ZD_CHANNEL_FIFO
             ? (int32_t)sizeof(z_owned_fifo_handler_reply_t)
             : (int32_t)sizeof(z_owned_ring_handler_reply_t);
}

FFI_PLUGIN_EXPORT void zd_reply_handler_drop(uint8_t* handler, int32_t kind) {
  // Through the entry matching the kind it was CONSTRUCTED with: the two owned
  // handler types are distinct, and releasing one through the other's entry is
  // undefined behaviour rather than a reported error.
  if (kind == ZD_CHANNEL_FIFO) {
    z_owned_fifo_handler_reply_t* h = (z_owned_fifo_handler_reply_t*)handler;
    z_fifo_handler_reply_drop(z_fifo_handler_reply_move(h));
  } else {
    z_owned_ring_handler_reply_t* h = (z_owned_ring_handler_reply_t*)handler;
    z_ring_handler_reply_drop(z_ring_handler_reply_move(h));
  }
}

/// Drops a freshly-built reply channel's handler. Used only on the failure
/// paths of zd_get_channel, where no Dart handle will ever exist to do it.
static void _zd_reply_channel_abandon(uint8_t* handler_out, int32_t kind) {
  zd_reply_handler_drop(handler_out, kind);
}

/// Builds a bounded reply channel of `kind` at `capacity` and interposes the
/// readiness tee in front of it.
///
/// ONE BODY FOR ALL THREE REPLY CARRIERS -- `zd_get_channel`,
/// `zd_querier_get_channel` and `zd_liveliness_get_channel`. The capacity
/// domain check, the kind dispatch, the tee's heap-owned closure move and the
/// arming state are identical on all three; only which canon entry consumes the
/// closure differs. Sharing the construction makes their behaviour identical BY
/// CONSTRUCTION rather than by three copies staying in step -- which is also
/// why the park-and-wake cells written against one carrier cover the others.
///
/// On success `*tee_closure_out` is the closure to hand canon and `*tee_out` is
/// the context. On failure NOTHING is left claimed.
static int8_t _zd_reply_channel_build(
    uint8_t* handler_out, int32_t kind, int64_t capacity, int64_t dart_port,
    z_owned_closure_reply_t* tee_closure_out, zd_reply_tee_t** tee_out) {
  *tee_out = NULL;
  // CAPACITY first, and BEFORE anything is allocated. Canon's constructors take
  // a `size_t` and return void -- they cannot fail and cannot reject -- so
  // every domain check that exists at all has to exist here. This is the
  // structural backstop; Dart rejects a negative before the call.
  if (capacity < 0) {
    return ZD_DECLARE_ECAPACITY;
  }
#if SIZE_MAX < INT64_MAX
  // Live on ILP32, which this product ships: 2^32 would truncate to 0, a
  // WORKING capacity, i.e. a silent transform.
  if (capacity > (int64_t)SIZE_MAX) {
    return ZD_DECLARE_ECAPACITY;
  }
#endif

  z_owned_closure_reply_t closure;
  if (kind == ZD_CHANNEL_FIFO) {
    z_fifo_channel_reply_new(
        &closure, (z_owned_fifo_handler_reply_t*)handler_out,
        (size_t)capacity);
  } else {
    z_ring_channel_reply_new(
        &closure, (z_owned_ring_handler_reply_t*)handler_out,
        (size_t)capacity);
  }

  // ALLOCATE-LAST: the tee context is claimed only after everything that can
  // fail without it has succeeded.
  zd_reply_tee_t* tee = (zd_reply_tee_t*)malloc(sizeof(zd_reply_tee_t));
  if (!tee) {
    z_closure_reply_drop(z_closure_reply_move(&closure));
    zd_reply_handler_drop(handler_out, kind);
    return ZD_DECLARE_EALLOC;
  }

  // Move canon's channel closure into heap-owned storage: the move macros are
  // pointer casts, not copies, so a stack local would become a
  // use-after-return the moment the caller returns ahead of a delivery.
  tee->inner = closure;
  z_internal_closure_reply_null(&closure);
  _zd_tee_head_init(&tee->head, dart_port);

  // Our closure stands where canon's would have stood.
  z_closure_reply(tee_closure_out, _zd_reply_tee_on_call, _zd_reply_tee_on_drop,
                  tee);
  *tee_out = tee;
  return 0;
}

/// Releases a channel built by `_zd_reply_channel_build` when the canon entry
/// meant to consume its closure failed or was never reached.
static void _zd_reply_channel_abandon_built(
    uint8_t* handler_out, int32_t kind,
    z_owned_closure_reply_t* tee_closure, zd_reply_tee_t* tee) {
  // zenoh-c 1.x takes the closure at entry and drops it on a failure path, so
  // the check makes "exactly once" a property of this code rather than of a
  // zenoh-c internal.
  if (z_internal_closure_reply_check(tee_closure)) {
    z_closure_reply_drop(z_closure_reply_move(tee_closure));
  }
  // The Dart handle's reference, released here because no Dart handle will ever
  // exist to release it.
  zd_pull_tee_drop((uint8_t*)tee);
  zd_reply_handler_drop(handler_out, kind);
}


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
    int accept_replies) {
  z_owned_closure_reply_t tee_closure;
  zd_reply_tee_t* tee;
  int8_t build_rc = _zd_reply_channel_build(
      handler_out, kind, capacity, dart_port, &tee_closure, &tee);
  if (build_rc != 0) {
    // PRE-MOVE: the payload and attachment have not been touched, which is why
    // these codes must stay distinguishable from the post-move ones. The Dart
    // guard makes the capacity code unreachable from the public API.
    *tee_out = NULL;
    return build_rc;
  }

  // The SAME options body zd_get uses (see _zd_fill_get_options): option parity
  // between the stream mode and the channel mode is structural here, not
  // maintained by hand.
  z_get_options_t opts;
  z_owned_encoding_t owned_encoding;
  int8_t opt_rc = _zd_fill_get_options(
      &opts, &owned_encoding, target, consolidation, payload, encoding,
      encoding_len, encoding_schema, encoding_schema_len,
      timeout_ms, attachment, congestion_control, priority, is_express,
      allowed_destination, accept_replies);
  if (opt_rc != 0) {
    // POST-move: the helper dropped the payload/attachment; the channel is ours
    // to release.
    _zd_reply_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return opt_rc;
  }

  int rc = z_get_with_parameters_substr(
      (const z_loaned_session_t*)session, selector, parameters, parameters_len,
      z_closure_reply_move(&tee_closure), &opts);

  if (rc != 0) {
    _zd_reply_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;
  return (int8_t)rc;
}

/// Releases every buffer zd_reply_channel_try_recv may have claimed, and
/// re-zeroes the out-params.
///
/// ONE release definition rather than a cleanup block repeated at each of the
/// six allocation sites. The sample column's try_recv repeats its blocks, which
/// was tractable at four allocations and is not at six: an omission in one of
/// six near-identical blocks is exactly the defect the FFI ownership rule
/// exists to prevent, and it is invisible to every behavioural assertion.
/// `free(NULL)` is a no-op, so this is correct at any point after the entry
/// zeroes its out-params.
static void _zd_reply_out_release(
    uint8_t** keyexpr, size_t* keyexpr_len,
    uint8_t** payload, size_t* payload_len,
    char** encoding,
    uint8_t** attachment, size_t* attachment_len,
    uint8_t** timestamp, uint8_t** replier_zid) {
  free(*keyexpr);
  *keyexpr = NULL;
  *keyexpr_len = 0;
  free(*payload);
  *payload = NULL;
  *payload_len = 0;
  free(*encoding);
  *encoding = NULL;
  free(*attachment);
  *attachment = NULL;
  *attachment_len = 0;
  free(*timestamp);
  *timestamp = NULL;
  free(*replier_zid);
  *replier_zid = NULL;
}

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
    uint8_t* retain_slot, int32_t* out_has_retained) {
  *out_is_ok = 0;
  *out_keyexpr = NULL;
  *out_keyexpr_len = 0;
  *out_payload = NULL;
  *out_payload_len = 0;
  // Seed [10a]: default BEFORE any early return, so an EMPTY or
  // DISCONNECTED result never leaves the caller reading a stale flag.
  if (out_has_retained != NULL) *out_has_retained = 0;
  *out_kind = 0;
  *out_encoding = NULL;
  *out_encoding_len = 0;
  *out_attachment = NULL;
  *out_attachment_len = 0;
  *out_timestamp = NULL;
  *out_priority = 0;
  *out_congestion = 0;
  *out_express = 0;
  *out_replier_zid = NULL;
  *out_replier_eid = 0;

  // The ONLY kind-dependent lines. Everything past the discriminant check is
  // one shared extraction body serving both kinds, for the same reason the
  // sample column has one: duplicating it would double the fidelity surface and
  // split every future fix across two sites.
  z_owned_reply_t reply;
  z_result_t res;
  if (kind == ZD_CHANNEL_FIFO) {
    const z_loaned_fifo_handler_reply_t* h = z_fifo_handler_reply_loan(
        (const z_owned_fifo_handler_reply_t*)handler);
    res = z_fifo_handler_reply_try_recv(h, &reply);
  } else {
    const z_loaned_ring_handler_reply_t* h = z_ring_handler_reply_loan(
        (const z_owned_ring_handler_reply_t*)handler);
    res = z_ring_handler_reply_try_recv(h, &reply);
  }

  if (res == Z_CHANNEL_DISCONNECTED) {
    return 1;  // the query completed; canon dropped its closure
  }
  if (res == Z_CHANNEL_NODATA) {
    return 2;  // alive, buffer empty right now
  }

  const z_loaned_reply_t* r = z_reply_loan(&reply);

  // The replier id, on BOTH branches -- z_reply_replier_id takes the whole
  // reply. The #ifdef gates ONLY the value extraction; the out-params keep
  // their meaning across variants (a NULL zid means absent), so the Dart parse
  // is platform-invariant.
#if defined(Z_FEATURE_UNSTABLE_API)
  z_entity_global_id_t replier;
  if (z_reply_replier_id(r, &replier)) {
    z_id_t rzid = z_entity_global_id_zid(&replier);
    *out_replier_zid = (uint8_t*)malloc(16);
    if (!*out_replier_zid) {
      z_reply_drop(z_reply_move(&reply));
      return -1;
    }
    memcpy(*out_replier_zid, rzid.id, 16);
    *out_replier_eid = (int64_t)z_entity_global_id_eid(&replier);
  }
#endif

  if (z_reply_is_ok(r)) {
    *out_is_ok = 1;
    const z_loaned_sample_t* sample = z_reply_ok(r);

    // 1. Key expression, LENGTH-CARRIED (never strlen-measured): the grammar
    // permits an interior NUL and canon carries one byte-exact.
    z_view_string_t key_view;
    z_keyexpr_as_view_string(z_sample_keyexpr(sample), &key_view);
    const z_loaned_string_t* key_loaned = z_view_string_loan(&key_view);
    size_t key_len = z_string_len(key_loaned);
    const char* key_data = z_string_data(key_loaned);
    // REMOTE-LENGTH-DRIVEN, every allocation below: the replier chose the
    // length, so on a constrained target it can fail with no bug on our side,
    // and an unguarded malloc + memcpy would write through NULL.
    *out_keyexpr = (uint8_t*)malloc(key_len + 1);
    if (!*out_keyexpr) {
      _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                            out_payload_len, out_encoding, out_attachment,
                            out_attachment_len, out_timestamp,
                            out_replier_zid);
      z_reply_drop(z_reply_move(&reply));
      return -1;
    }
    memcpy(*out_keyexpr, key_data, key_len);
    (*out_keyexpr)[key_len] = '\0';
    *out_keyexpr_len = key_len;

    // 2. Payload, byte-faithful reader pattern. Report ACTUAL bytes read, so a
    // short read never exposes an uninitialized tail.
    const z_loaned_bytes_t* payload = z_sample_payload(sample);
    size_t payload_len = z_bytes_len(payload);
    if (payload_len > 0) {
      *out_payload = (uint8_t*)malloc(payload_len);
      if (!*out_payload) {
        _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                              out_payload_len, out_encoding, out_attachment,
                              out_attachment_len, out_timestamp,
                              out_replier_zid);
        z_reply_drop(z_reply_move(&reply));
        return -1;
      }
      z_bytes_reader_t reader = z_bytes_get_reader(payload);
      *out_payload_len = z_bytes_reader_read(&reader, *out_payload,
                                             payload_len);
    }


    // 3. Sample kind (put / delete).
    *out_kind = (int8_t)z_sample_kind(sample);

    // 4. Encoding. Allocated UNCONDITIONALLY (>= 1 byte), so a zero-length
    // rendered encoding surfaces as '' here exactly as it does on the callback
    // path -- the same wire reply must not yield two different Dart values
    // depending on which receive surface read it.
    const z_loaned_encoding_t* encoding = z_sample_encoding(sample);
    z_owned_string_t enc_str;
    z_encoding_to_string(encoding, &enc_str);
    const z_loaned_string_t* enc_loaned = z_string_loan(&enc_str);
    size_t enc_len = z_string_len(enc_loaned);
    const char* enc_data = z_string_data(enc_loaned);
    *out_encoding = (char*)malloc(enc_len + 1);
    if (!*out_encoding) {
      z_string_drop(z_string_move(&enc_str));
      _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                            out_payload_len, out_encoding, out_attachment,
                            out_attachment_len, out_timestamp,
                            out_replier_zid);
      z_reply_drop(z_reply_move(&reply));
      return -1;
    }
    memcpy(*out_encoding, enc_data, enc_len);
    (*out_encoding)[enc_len] = '\0';
    *out_encoding_len = enc_len;
    z_string_drop(z_string_move(&enc_str));

    // 5. Attachment (nullable). EMPTY != ABSENT: a present-but-empty
    // attachment must surface as a non-NULL pointer with len 0, so we malloc at
    // least 1 byte and the caller discriminates on the POINTER, not the length.
    const z_loaned_bytes_t* attachment = z_sample_attachment(sample);
    if (attachment != NULL) {
      size_t att_len = z_bytes_len(attachment);
      *out_attachment = (uint8_t*)malloc(att_len > 0 ? att_len : 1);
      if (!*out_attachment) {
        _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                              out_payload_len, out_encoding, out_attachment,
                              out_attachment_len, out_timestamp,
                              out_replier_zid);
        z_reply_drop(z_reply_move(&reply));
        return -1;
      }
      if (att_len > 0) {
        z_bytes_reader_t att_reader = z_bytes_get_reader(attachment);
        *out_attachment_len = z_bytes_reader_read(&att_reader, *out_attachment,
                                                  att_len);
      }
    }

    // 6. Timestamp (nullable, present/absent by pointer). The raw 24-byte
    // z_timestamp_t image, so the caller can re-represent it bit-exact.
    const z_timestamp_t* ts = z_sample_timestamp(sample);
    if (ts != NULL) {
      *out_timestamp = (uint8_t*)malloc(24);
      if (!*out_timestamp) {
        _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                              out_payload_len, out_encoding, out_attachment,
                              out_attachment_len, out_timestamp,
                              out_replier_zid);
        z_reply_drop(z_reply_move(&reply));
        return -1;
      }
      memcpy(*out_timestamp, ts, 24);
    }

    // 7. QoS metadata.
    *out_priority = (int8_t)z_sample_priority(sample);
    *out_congestion = (int8_t)z_sample_congestion_control(sample);
    *out_express = z_sample_express(sample) ? 1 : 0;

    // Seed [10a]: the retained payload handle, on the PULL REPLY path.
    //
    // ⛔ TAKEN LAST WITHIN THE OK ARM, for the reason the sample extractor
    // records: four `return -1` paths sat after its first position, and none
    // of them dropped the slot. Placed here, no fallible allocation remains
    // between the clone and the caller taking ownership.
    //
    // ⛔ OK ARM ONLY. The error arm never reaches here, which is the carve:
    // ReplyError gets no retained handle in this unit.
    if (retain_slot != NULL) {
      z_bytes_clone((z_owned_bytes_t*)retain_slot, payload);
      if (out_has_retained != NULL) *out_has_retained = 1;
    } else if (out_has_retained != NULL) {
      *out_has_retained = 0;
    }
  } else {
    *out_is_ok = 0;
    const z_loaned_reply_err_t* err = z_reply_err(r);

    // The error payload and encoding ride the SAME out-params as the ok ones.
    // One extraction body, one set of guards, and `out_is_ok` tells the Dart
    // side which reading applies.
    const z_loaned_bytes_t* err_payload = z_reply_err_payload(err);
    size_t err_len = z_bytes_len(err_payload);
    if (err_len > 0) {
      *out_payload = (uint8_t*)malloc(err_len);
      if (!*out_payload) {
        _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                              out_payload_len, out_encoding, out_attachment,
                              out_attachment_len, out_timestamp,
                              out_replier_zid);
        z_reply_drop(z_reply_move(&reply));
        return -1;
      }
      z_bytes_reader_t reader = z_bytes_get_reader(err_payload);
      *out_payload_len = z_bytes_reader_read(&reader, *out_payload, err_len);
    }

    const z_loaned_encoding_t* err_encoding = z_reply_err_encoding(err);
    z_owned_string_t err_enc_str;
    z_encoding_to_string(err_encoding, &err_enc_str);
    const z_loaned_string_t* err_enc_loaned = z_string_loan(&err_enc_str);
    size_t err_enc_len = z_string_len(err_enc_loaned);
    const char* err_enc_data = z_string_data(err_enc_loaned);
    *out_encoding = (char*)malloc(err_enc_len + 1);
    if (!*out_encoding) {
      z_string_drop(z_string_move(&err_enc_str));
      _zd_reply_out_release(out_keyexpr, out_keyexpr_len, out_payload,
                            out_payload_len, out_encoding, out_attachment,
                            out_attachment_len, out_timestamp,
                            out_replier_zid);
      z_reply_drop(z_reply_move(&reply));
      return -1;
    }
    memcpy(*out_encoding, err_enc_data, err_enc_len);
    (*out_encoding)[err_enc_len] = '\0';
    *out_encoding_len = err_enc_len;
    z_string_drop(z_string_move(&err_enc_str));
  }

  z_reply_drop(z_reply_move(&reply));
  return 0;
}

FFI_PLUGIN_EXPORT void zd_pull_handler_drop(uint8_t* handler, int32_t kind) {
  if (kind == ZD_CHANNEL_FIFO) {
    z_owned_fifo_handler_sample_t* h = (z_owned_fifo_handler_sample_t*)handler;
    z_fifo_handler_sample_drop(z_fifo_handler_sample_move(h));
  } else {
    z_owned_ring_handler_sample_t* h = (z_owned_ring_handler_sample_t*)handler;
    z_ring_handler_sample_drop(z_ring_handler_sample_move(h));
  }
}

// ---------------------------------------------------------------------------
// Querier
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_querier_sizeof(void) {
  return sizeof(z_owned_querier_t);
}

FFI_PLUGIN_EXPORT int8_t zd_declare_querier(
    uint8_t* querier_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr, int8_t target,
    int8_t consolidation, uint64_t timeout_ms,
    int congestion_control, int priority, int8_t is_express,
    int allowed_destination, int accept_replies) {
  z_querier_options_t opts;
  z_querier_options_default(&opts);

  opts.target = (z_query_target_t)target;

  if (consolidation == -1) {
    opts.consolidation = z_query_consolidation_default();
  } else {
    opts.consolidation.mode = (z_consolidation_mode_t)consolidation;
  }

  if (timeout_ms > 0) {
    opts.timeout_ms = timeout_ms;
  }

  // Negative means "unspecified" -- leave z_querier_options_default's value.
  // As with get, canon's congestion default here is DEFAULT_REQUEST (BLOCK).
  if (congestion_control >= 0) {
    opts.congestion_control = (z_congestion_control_t)congestion_control;
  }
  if (priority >= 0) {
    opts.priority = (z_priority_t)priority;
  }
  if (is_express >= 0) {
    opts.is_express = (bool)is_express;
  }
  if (allowed_destination >= 0) {
    opts.allowed_destination = (z_locality_t)allowed_destination;
  }
  if (accept_replies >= 0) {
    opts.accept_replies = (z_reply_keyexpr_t)accept_replies;
  }

  return (int8_t)z_declare_querier(
      (const z_loaned_session_t*)session,
      (z_owned_querier_t*)querier_out,
      key_expr,
      &opts);
}

FFI_PLUGIN_EXPORT void zd_querier_drop(uint8_t* querier) {
  z_querier_drop(z_querier_move((z_owned_querier_t*)querier));
}

/// Fills `opts` from the flattened per-get querier options.
///
/// ONE BODY FOR BOTH MODES, exactly as `_zd_fill_get_options` is for the
/// session gets. `owned_encoding` must be the CALLER's storage: `opts->encoding`
/// holds a move out of it. On the encoding failure the payload and attachment
/// are DROPPED before returning -- they were already moved into `opts` -- which
/// is what makes the Dart side's unconditional `markConsumed` true on every
/// path. The caller still owns releasing its own closure.
static int8_t _zd_fill_querier_get_options(
    z_querier_get_options_t* opts, z_owned_encoding_t* owned_encoding,
    uint8_t* payload, const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment) {
  z_querier_get_options_default(opts);

  if (payload != NULL) {
    opts->payload = z_bytes_move((z_owned_bytes_t*)payload);
  }
  if (attachment != NULL) {
    opts->attachment = z_bytes_move((z_owned_bytes_t*)attachment);
  }

  // Two independent length-carried channels (R-2); see _zd_build_encoding.
  // Check the rc: do not silently substitute the default on a bad MIME or a
  // non-UTF-8 schema.
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(owned_encoding, encoding, encoding_len,
                                         encoding_schema, encoding_schema_len,
                                         &has_encoding);
  if (enc_rc != 0) {
    if (opts->payload != NULL) {
      z_bytes_drop(opts->payload);
    }
    if (opts->attachment != NULL) {
      z_bytes_drop(opts->attachment);
    }
    return (int8_t)enc_rc;
  }
  if (has_encoding) {
    opts->encoding = z_encoding_move(owned_encoding);
  }

  return 0;
}

FFI_PLUGIN_EXPORT int8_t zd_querier_get(
    const uint8_t* querier, const char* parameters, size_t parameters_len,
    int64_t port, uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment, int retain_payload) {
  const z_loaned_querier_t* loaned =
      z_querier_loan((const z_owned_querier_t*)querier);

  // PRE-move early-return, and the Dart caller marks payload/attachment
  // consumed unconditionally after this call -- so drop what we were handed
  // rather than leaving a gravestoned wrapper over a live native handle. Same
  // reasoning as zd_get; see the comment there.
  zd_get_context_t* ctx =
      (zd_get_context_t*)malloc(sizeof(zd_get_context_t));
  if (!ctx) {
    if (payload != NULL) z_bytes_drop(z_bytes_move((z_owned_bytes_t*)payload));
    if (attachment != NULL) {
      z_bytes_drop(z_bytes_move((z_owned_bytes_t*)attachment));
    }
    return -1;
  }
  ctx->dart_port = (Dart_Port_DL)port;
  // Seed [10a]: the caller's opt-in, explicit because malloc does not zero.
  ctx->retain_payload = retain_payload;

  z_owned_closure_reply_t callback;
  z_closure_reply(&callback, _zd_reply_callback, _zd_get_drop, ctx);

  z_querier_get_options_t opts;
  z_owned_encoding_t owned_encoding;
  int8_t opt_rc = _zd_fill_querier_get_options(
      &opts, &owned_encoding, payload, encoding, encoding_len,
      encoding_schema, encoding_schema_len, attachment);
  if (opt_rc != 0) {
    // POST-move: the helper has already dropped the payload/attachment, so only
    // the closure is left to release here.
    z_closure_reply_drop(z_closure_reply_move(&callback));
    return opt_rc;
  }

  // LENGTH-CARRIED; see the note in zd_get. Same seam, same domain, same
  // canon-provided substr sibling.
  int rc = z_querier_get_with_parameters_substr(
      loaned,
      parameters,
      parameters_len,
      z_closure_reply_move(&callback),
      &opts);

  if (rc != 0) {
    z_closure_reply_drop(z_closure_reply_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_querier_get_channel(
    uint8_t* handler_out, uint8_t** tee_out, int64_t dart_port,
    const uint8_t* querier, int32_t kind, int64_t capacity,
    const char* parameters, size_t parameters_len,
    uint8_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    uint8_t* attachment) {
  const z_loaned_querier_t* loaned =
      z_querier_loan((const z_owned_querier_t*)querier);

  z_owned_closure_reply_t tee_closure;
  zd_reply_tee_t* tee;
  int8_t build_rc = _zd_reply_channel_build(
      handler_out, kind, capacity, dart_port, &tee_closure, &tee);
  if (build_rc != 0) {
    // PRE-move: the payload and attachment are untouched on this path.
    *tee_out = NULL;
    return build_rc;
  }

  // The SAME options body zd_querier_get uses, so the two modes cannot drift.
  z_querier_get_options_t opts;
  z_owned_encoding_t owned_encoding;
  int8_t opt_rc = _zd_fill_querier_get_options(
      &opts, &owned_encoding, payload, encoding, encoding_len,
      encoding_schema, encoding_schema_len, attachment);
  if (opt_rc != 0) {
    _zd_reply_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return opt_rc;
  }

  // LENGTH-CARRIED parameters, exactly as on the stream sibling.
  int rc = z_querier_get_with_parameters_substr(
      loaned, parameters, parameters_len,
      z_closure_reply_move(&tee_closure), &opts);

  if (rc != 0) {
    _zd_reply_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;
  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_querier_declare_background_matching_listener(
    const uint8_t* querier, int64_t dart_port) {
  const z_loaned_querier_t* loaned =
      z_querier_loan((const z_owned_querier_t*)querier);

  zd_matching_context_t* ctx =
      (zd_matching_context_t*)malloc(sizeof(zd_matching_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;

  z_owned_closure_matching_status_t callback;
  z_closure_matching_status(
      &callback, _zd_matching_status_callback, _zd_matching_drop, ctx);

  int rc = z_querier_declare_background_matching_listener(
      loaned, z_closure_matching_status_move(&callback));

  if (rc != 0) {
    z_closure_matching_status_drop(z_closure_matching_status_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_querier_get_matching_status(
    const uint8_t* querier, int8_t* matching_out) {
  const z_loaned_querier_t* loaned =
      z_querier_loan((const z_owned_querier_t*)querier);

  z_matching_status_t status;
  int rc = z_querier_get_matching_status(loaned, &status);
  if (rc == 0) {
    *matching_out = status.matching ? 1 : 0;
  }
  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Liveliness
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT size_t zd_liveliness_token_sizeof(void) {
  return sizeof(z_owned_liveliness_token_t);
}

FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_token(
    uint8_t* token_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr) {
  const z_loaned_session_t* loaned_session =
      (const z_loaned_session_t*)session;

  z_owned_liveliness_token_t* token = (z_owned_liveliness_token_t*)token_out;
  int rc = z_liveliness_declare_token(
      loaned_session, token, key_expr, NULL);
  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT void zd_liveliness_token_drop(uint8_t* token) {
  z_owned_liveliness_token_t* t = (z_owned_liveliness_token_t*)token;
  z_liveliness_token_drop(z_liveliness_token_move(t));
}

FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_subscriber(
    uint8_t* subscriber_out, const uint8_t* session,
    const z_loaned_keyexpr_t* key_expr, int64_t port, int8_t history,
    int retain_payload) {
  const z_loaned_session_t* loaned_session =
      (const z_loaned_session_t*)session;

  // Allocate context for the sample callback
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)port;
  // Seed [10a]: explicit, because malloc does not zero. Slice 2 wires
  // the flag on zd_declare_subscriber only; every other sample surface
  // is opted in by its own later slice and retains nothing until then.
  ctx->retain_payload = retain_payload;

  // Create closure reusing the existing sample callback/drop
  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback, _zd_sample_drop, ctx);

  // Set up options with history flag
  z_liveliness_subscriber_options_t opts;
  z_liveliness_subscriber_options_default(&opts);
  opts.history = history ? true : false;

  z_owned_subscriber_t* subscriber = (z_owned_subscriber_t*)subscriber_out;
  int rc = z_liveliness_declare_subscriber(
      loaned_session, subscriber, key_expr,
      z_closure_sample_move(&callback), &opts);

  if (rc != 0) {
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_background_subscriber(
    const z_loaned_session_t* session, const z_loaned_keyexpr_t* key_expr,
    int64_t dart_port, int8_t history, int retain_payload) {
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: explicit, because malloc does not zero. Slice 2 wires
  // the flag on zd_declare_subscriber only; every other sample surface
  // is opted in by its own later slice and retains nothing until then.
  ctx->retain_payload = retain_payload;

  // Sentinel-posting drop so the stream completes when the session drops.
  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback,
                   _zd_sample_drop_with_sentinel, ctx);

  z_liveliness_subscriber_options_t opts;
  z_liveliness_subscriber_options_default(&opts);
  opts.history = history ? true : false;

  int rc = z_liveliness_declare_background_subscriber(
      session, key_expr,
      z_closure_sample_move(&callback), &opts);

  if (rc != 0) {
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_liveliness_get(
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int64_t port, uint64_t timeout_ms, int retain_payload) {
  zd_get_context_t* ctx =
      (zd_get_context_t*)malloc(sizeof(zd_get_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)port;
  // Seed [10a]: the caller's opt-in, explicit because malloc does not zero.
  ctx->retain_payload = retain_payload;

  z_owned_closure_reply_t callback;
  z_closure_reply(&callback, _zd_reply_callback, _zd_get_drop, ctx);

  z_liveliness_get_options_t opts;
  z_liveliness_get_options_default(&opts);
  opts.timeout_ms = timeout_ms;

  int rc = z_liveliness_get(
      (const z_loaned_session_t*)session,
      key_expr,
      z_closure_reply_move(&callback),
      &opts);

  if (rc != 0) {
    z_closure_reply_drop(z_closure_reply_move(&callback));
  }

  return (int8_t)rc;
}

FFI_PLUGIN_EXPORT int8_t zd_liveliness_get_channel(
    uint8_t* handler_out, uint8_t** tee_out, int64_t dart_port,
    const uint8_t* session, const z_loaned_keyexpr_t* key_expr,
    int32_t kind, int64_t capacity, uint64_t timeout_ms) {
  z_owned_closure_reply_t tee_closure;
  zd_reply_tee_t* tee;
  int8_t build_rc = _zd_reply_channel_build(
      handler_out, kind, capacity, dart_port, &tee_closure, &tee);
  if (build_rc != 0) {
    *tee_out = NULL;
    return build_rc;
  }

  // ⚠️ `timeout_ms` is NOT a 0-sentinel here; see zd_liveliness_get's contract.
  // The Dart side sends its explicit default, exactly as on the stream sibling.
  z_liveliness_get_options_t opts;
  z_liveliness_get_options_default(&opts);
  opts.timeout_ms = timeout_ms;

  int rc = z_liveliness_get(
      (const z_loaned_session_t*)session, key_expr,
      z_closure_reply_move(&tee_closure), &opts);

  if (rc != 0) {
    _zd_reply_channel_abandon_built(handler_out, kind, &tee_closure, tee);
    *tee_out = NULL;
    return (int8_t)rc;
  }

  *tee_out = (uint8_t*)tee;
  return (int8_t)rc;
}

// ---------------------------------------------------------------------------
// Serializer
// ---------------------------------------------------------------------------

size_t zd_serializer_sizeof(void) {
  return sizeof(ze_owned_serializer_t);
}

int8_t zd_serializer_empty(ze_owned_serializer_t* ser) {
  return (int8_t)ze_serializer_empty(ser);
}

void zd_serializer_loan_mut(
    ze_owned_serializer_t* ser, ze_loaned_serializer_t** out) {
  *out = ze_serializer_loan_mut(ser);
}

void zd_serializer_finish(
    ze_owned_serializer_t* ser, z_owned_bytes_t* out) {
  ze_serializer_finish(ze_serializer_move(ser), out);
}

void zd_serializer_drop(ze_owned_serializer_t* ser) {
  ze_serializer_drop(ze_serializer_move(ser));
}

// ---------------------------------------------------------------------------
// Serializer — arithmetic type serialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_uint8(ze_loaned_serializer_t* ser, uint8_t val) {
  return (int8_t)ze_serializer_serialize_uint8(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_uint16(ze_loaned_serializer_t* ser, uint16_t val) {
  return (int8_t)ze_serializer_serialize_uint16(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_uint32(ze_loaned_serializer_t* ser, uint32_t val) {
  return (int8_t)ze_serializer_serialize_uint32(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_uint64(ze_loaned_serializer_t* ser, uint64_t val) {
  return (int8_t)ze_serializer_serialize_uint64(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_int8(ze_loaned_serializer_t* ser, int8_t val) {
  return (int8_t)ze_serializer_serialize_int8(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_int16(ze_loaned_serializer_t* ser, int16_t val) {
  return (int8_t)ze_serializer_serialize_int16(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_int32(ze_loaned_serializer_t* ser, int32_t val) {
  return (int8_t)ze_serializer_serialize_int32(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_int64(ze_loaned_serializer_t* ser, int64_t val) {
  return (int8_t)ze_serializer_serialize_int64(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_float(ze_loaned_serializer_t* ser, float val) {
  return (int8_t)ze_serializer_serialize_float(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_double(ze_loaned_serializer_t* ser, double val) {
  return (int8_t)ze_serializer_serialize_double(ser, val);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_bool(ze_loaned_serializer_t* ser, bool val) {
  return (int8_t)ze_serializer_serialize_bool(ser, val);
}

// ---------------------------------------------------------------------------
// Serializer — compound type serialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_string(ze_loaned_serializer_t* ser,
                                     const uint8_t* val, size_t len) {
  // Length-delimited substr: embedded NULs are preserved (the NUL-terminated
  // ze_serializer_serialize_str would truncate at the first NUL byte).
  return (int8_t)ze_serializer_serialize_substr(ser, (const char*)val, len);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_buf(ze_loaned_serializer_t* ser, const uint8_t* data, size_t len) {
  return (int8_t)ze_serializer_serialize_buf(ser, data, len);
}

FFI_PLUGIN_EXPORT
int8_t zd_serializer_serialize_sequence_length(ze_loaned_serializer_t* ser, size_t len) {
  return (int8_t)ze_serializer_serialize_sequence_length(ser, len);
}

// ---------------------------------------------------------------------------
// Deserializer
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
size_t zd_deserializer_sizeof(void) {
  return sizeof(ze_deserializer_t);
}

FFI_PLUGIN_EXPORT
void zd_deserializer_from_bytes(const z_loaned_bytes_t* bytes, ze_deserializer_t* out) {
  *out = ze_deserializer_from_bytes(bytes);
}

FFI_PLUGIN_EXPORT
bool zd_deserializer_is_done(const ze_deserializer_t* deser) {
  return ze_deserializer_is_done(deser);
}

// ---------------------------------------------------------------------------
// Deserializer — type deserialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_uint8(ze_deserializer_t* deser, uint8_t* out) {
  return (int8_t)ze_deserializer_deserialize_uint8(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_uint16(ze_deserializer_t* deser, uint16_t* out) {
  return (int8_t)ze_deserializer_deserialize_uint16(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_uint32(ze_deserializer_t* deser, uint32_t* out) {
  return (int8_t)ze_deserializer_deserialize_uint32(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_uint64(ze_deserializer_t* deser, uint64_t* out) {
  return (int8_t)ze_deserializer_deserialize_uint64(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_int8(ze_deserializer_t* deser, int8_t* out) {
  return (int8_t)ze_deserializer_deserialize_int8(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_int16(ze_deserializer_t* deser, int16_t* out) {
  return (int8_t)ze_deserializer_deserialize_int16(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_int32(ze_deserializer_t* deser, int32_t* out) {
  return (int8_t)ze_deserializer_deserialize_int32(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_int64(ze_deserializer_t* deser, int64_t* out) {
  return (int8_t)ze_deserializer_deserialize_int64(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_float(ze_deserializer_t* deser, float* out) {
  return (int8_t)ze_deserializer_deserialize_float(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_double(ze_deserializer_t* deser, double* out) {
  return (int8_t)ze_deserializer_deserialize_double(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_bool(ze_deserializer_t* deser, bool* out) {
  return (int8_t)ze_deserializer_deserialize_bool(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_string(ze_deserializer_t* deser, z_owned_string_t* out) {
  return (int8_t)ze_deserializer_deserialize_string(deser, out);
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_buf(ze_deserializer_t* deser, z_owned_bytes_t* out) {
  z_owned_slice_t slice;
  z_result_t rc = ze_deserializer_deserialize_slice(deser, &slice);
  if (rc != 0) return (int8_t)rc;
  z_bytes_from_slice(out, z_slice_move(&slice));
  return 0;
}

FFI_PLUGIN_EXPORT
int8_t zd_deserializer_deserialize_sequence_length(ze_deserializer_t* deser, size_t* out) {
  return (int8_t)ze_deserializer_deserialize_sequence_length(deser, out);
}

// ---------------------------------------------------------------------------
// Bytes Writer
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
size_t zd_bytes_writer_sizeof(void) {
  return sizeof(z_owned_bytes_writer_t);
}

FFI_PLUGIN_EXPORT
int8_t zd_bytes_writer_empty(z_owned_bytes_writer_t* writer) {
  return (int8_t)z_bytes_writer_empty(writer);
}

FFI_PLUGIN_EXPORT
void zd_bytes_writer_loan_mut(
    z_owned_bytes_writer_t* writer, z_loaned_bytes_writer_t** out) {
  *out = z_bytes_writer_loan_mut(writer);
}

FFI_PLUGIN_EXPORT
int8_t zd_bytes_writer_write_all(
    z_loaned_bytes_writer_t* writer, const uint8_t* data, size_t len) {
  return (int8_t)z_bytes_writer_write_all(writer, data, len);
}

FFI_PLUGIN_EXPORT
int8_t zd_bytes_writer_append(
    z_loaned_bytes_writer_t* writer, z_owned_bytes_t* bytes) {
  return (int8_t)z_bytes_writer_append(writer, z_bytes_move(bytes));
}

FFI_PLUGIN_EXPORT
void zd_bytes_writer_finish(
    z_owned_bytes_writer_t* writer, z_owned_bytes_t* out) {
  z_bytes_writer_finish(z_bytes_writer_move(writer), out);
}

FFI_PLUGIN_EXPORT
void zd_bytes_writer_drop(z_owned_bytes_writer_t* writer) {
  z_bytes_writer_drop(z_bytes_writer_move(writer));
}

// ---------------------------------------------------------------------------
// Bytes Slice Iterator
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
size_t zd_bytes_slice_iterator_sizeof(void) {
  return sizeof(z_bytes_slice_iterator_t);
}

FFI_PLUGIN_EXPORT
void zd_bytes_get_slice_iterator(
    const z_loaned_bytes_t* bytes, z_bytes_slice_iterator_t* iter) {
  *iter = z_bytes_get_slice_iterator(bytes);
}

FFI_PLUGIN_EXPORT
bool zd_bytes_slice_iterator_next(
    z_bytes_slice_iterator_t* iter, z_view_slice_t* out) {
  return z_bytes_slice_iterator_next(iter, out);
}

FFI_PLUGIN_EXPORT
size_t zd_view_slice_sizeof(void) {
  return sizeof(z_view_slice_t);
}

FFI_PLUGIN_EXPORT
const uint8_t* zd_view_slice_data(const z_view_slice_t* slice) {
  const z_loaned_slice_t* loaned = z_view_slice_loan(slice);
  return z_slice_data(loaned);
}

FFI_PLUGIN_EXPORT
size_t zd_view_slice_len(const z_view_slice_t* slice) {
  const z_loaned_slice_t* loaned = z_view_slice_loan(slice);
  return z_slice_len(loaned);
}

// ---------------------------------------------------------------------------
// Advanced Publisher
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_UNSTABLE_API)

FFI_PLUGIN_EXPORT
size_t zd_advanced_publisher_sizeof(void) {
  return sizeof(ze_owned_advanced_publisher_t);
}

FFI_PLUGIN_EXPORT
int zd_declare_advanced_publisher(
    const z_loaned_session_t* session,
    ze_owned_advanced_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    bool enable_cache,
    int64_t cache_max_samples,
    bool publisher_detection,
    bool sample_miss_detection,
    int heartbeat_mode,
    uint64_t heartbeat_period_ms) {

  // DOMAIN FIRST, before anything is declared. -1 is the house "unspecified"
  // sentinel (as at zd_declare_publisher's is_express); canon's field is a
  // size_t, so -1 cannot collide with a legitimate canon value.
  if (cache_max_samples < -1) {
    return ZD_DECLARE_ECAPACITY;
  }
#if SIZE_MAX < INT64_MAX
  // Live on ILP32, which this product ships -- the advanced family is built
  // for armeabi-v7a and x86 (build_zenoh_android.sh), and only SHM is clamped
  // there. 2^32 would truncate to 0, a WORKING bound, i.e. a silent transform.
  if (cache_max_samples > (int64_t)SIZE_MAX) {
    return ZD_DECLARE_ECAPACITY;
  }
#endif

  ze_advanced_publisher_options_t opts;
  ze_advanced_publisher_options_default(&opts);

  if (enable_cache) {
    ze_advanced_publisher_cache_options_default(&opts.cache);
    // >= 0, not > 0. The old `> 0` guard silently swallowed a caller's zero
    // into canon's one-sample default while our own docs called zero
    // "unlimited" -- the substitution this seed exists to cure. Zero is a
    // legitimate canon value and is now assigned verbatim; canon's own
    // measured behaviour for it (a one-sample cache, indistinguishable from
    // the default) is documented rather than hidden behind a guard.
    if (cache_max_samples >= 0) {
      opts.cache.max_samples = (size_t)cache_max_samples;
    }
  }

  if (publisher_detection) {
    opts.publisher_detection = true;
  }

  if (sample_miss_detection) {
    ze_advanced_publisher_sample_miss_detection_options_default(
        &opts.sample_miss_detection);
    opts.sample_miss_detection.heartbeat_mode =
        (ze_advanced_publisher_heartbeat_mode_t)heartbeat_mode;
    if (heartbeat_period_ms > 0) {
      opts.sample_miss_detection.heartbeat_period_ms = heartbeat_period_ms;
    }
  }

  return ze_declare_advanced_publisher(session, publisher, keyexpr, &opts);
}

FFI_PLUGIN_EXPORT
int zd_advanced_publisher_put(
    const ze_loaned_advanced_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding, size_t encoding_len,
    const char* encoding_schema, size_t encoding_schema_len,
    z_owned_bytes_t* attachment) {
  ze_advanced_publisher_put_options_t opts;
  ze_advanced_publisher_put_options_default(&opts);

  // Two independent length-carried channels (R-2); see _zd_build_encoding.
  // The helper is OUTSIDE this file's unstable guard, so it is shared with the
  // ten stable-door send bodies rather than duplicated behind the #ifdef.
  z_owned_encoding_t owned_encoding;
  bool has_encoding = false;
  z_result_t enc_rc = _zd_build_encoding(&owned_encoding, encoding,
                                         encoding_len, encoding_schema,
                                         encoding_schema_len, &has_encoding);
  if (enc_rc != 0) {
    // ze_advanced_publisher_put will not run, so the owned payload/attachment
    // would otherwise leak. Drop them here so this early-return matches the
    // Dart caller's unconditional markConsumed (gravestone) and frees memory.
    z_bytes_drop(z_bytes_move(payload));
    if (attachment != NULL) {
      z_bytes_drop(z_bytes_move(attachment));
    }
    return enc_rc;
  }
  if (has_encoding) {
    opts.put_options.encoding = z_encoding_move(&owned_encoding);
  }
  if (attachment != NULL) {
    opts.put_options.attachment = z_bytes_move(attachment);
  }

  return ze_advanced_publisher_put(publisher, z_bytes_move(payload), &opts);
}

FFI_PLUGIN_EXPORT
int zd_advanced_publisher_delete(
    const ze_loaned_advanced_publisher_t* publisher) {
  return ze_advanced_publisher_delete(publisher, NULL);
}

FFI_PLUGIN_EXPORT
int zd_advanced_publisher_get_matching_status(
    const ze_loaned_advanced_publisher_t* publisher,
    int* matching) {
  // The byte-for-byte analogue of zd_publisher_get_matching_status: canon
  // reuses the plain one-field z_matching_status_t here -- there is no
  // ze_matching_status_t -- so only the loaned handle type differs.
  z_matching_status_t status;
  int rc = ze_advanced_publisher_get_matching_status(publisher, &status);
  if (rc == 0) {
    // Written on rc 0 ONLY. Canon leaves its out-struct untouched on error,
    // so writing here unconditionally would manufacture a value out of
    // uninitialized stack.
    *matching = status.matching ? 1 : 0;
  }
  return rc;
}

FFI_PLUGIN_EXPORT
int zd_advanced_publisher_declare_background_matching_listener(
    const ze_loaned_advanced_publisher_t* publisher,
    int64_t dart_port) {
  // Third consumer of the matching bridge (plain publisher, querier, and now
  // this): canon's advanced listener takes the SAME closure type, so the
  // callback and drop are reused unchanged.
  zd_matching_context_t* ctx =
      (zd_matching_context_t*)malloc(sizeof(zd_matching_context_t));
  // Positive, not -1. -1 is Z_EINVAL on this channel, so a shim-owned -1 would
  // let a canon EINVAL masquerade as our allocation failure. The two shipped
  // siblings still carry the pre-#5 -1; those are existing surface.
  if (!ctx) return ZD_DECLARE_EALLOC;
  ctx->dart_port = (Dart_Port_DL)dart_port;

  z_owned_closure_matching_status_t callback;
  z_closure_matching_status(
      &callback, _zd_matching_status_callback, _zd_matching_drop, ctx);

  int rc = ze_advanced_publisher_declare_background_matching_listener(
      publisher, z_closure_matching_status_move(&callback));

  if (rc != 0) {
    // Canon did not take the closure, so its drop never runs and ctx would
    // leak. Dropping the closure here runs _zd_matching_drop, which frees it.
    z_closure_matching_status_drop(z_closure_matching_status_move(&callback));
  }

  return rc;
}

FFI_PLUGIN_EXPORT
const ze_loaned_advanced_publisher_t* zd_advanced_publisher_loan(
    const ze_owned_advanced_publisher_t* publisher) {
  return ze_advanced_publisher_loan(publisher);
}

FFI_PLUGIN_EXPORT
void zd_advanced_publisher_drop(ze_owned_advanced_publisher_t* publisher) {
  ze_advanced_publisher_drop(ze_advanced_publisher_move(publisher));
}

// ---------------------------------------------------------------------------
// Advanced Subscriber
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT
size_t zd_advanced_subscriber_sizeof(void) {
  return sizeof(ze_owned_advanced_subscriber_t);
}

FFI_PLUGIN_EXPORT
int zd_declare_advanced_subscriber(
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
    int retain_payload) {

  // Create closure context with the Dart port
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: explicit, because malloc does not zero. Slice 2 wires
  // the flag on zd_declare_subscriber only; every other sample surface
  // is opted in by its own later slice and retains nothing until then.
  ctx->retain_payload = retain_payload;

  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback, _zd_sample_drop, ctx);

  ze_advanced_subscriber_options_t opts;
  ze_advanced_subscriber_options_default(&opts);

  if (history) {
    ze_advanced_subscriber_history_options_default(&opts.history);
    if (history_detect_late_publishers) {
      opts.history.detect_late_publishers = true;
    }
  }

  if (recovery) {
    ze_advanced_subscriber_recovery_options_default(&opts.recovery);
    if (recovery_last_sample_miss_detection) {
      ze_advanced_subscriber_last_sample_miss_detection_options_default(
          &opts.recovery.last_sample_miss_detection);
      if (recovery_periodic_queries_period_ms > 0) {
        opts.recovery.last_sample_miss_detection.periodic_queries_period_ms =
            recovery_periodic_queries_period_ms;
      }
    }
  }

  if (subscriber_detection) {
    opts.subscriber_detection = true;
  }

  int rc = ze_declare_advanced_subscriber(
      session, subscriber, keyexpr,
      z_closure_sample_move(&callback), &opts);

  if (rc != 0) {
    // The house backstop its twelve sibling declare paths carry. canon 1.8.0
    // takes the closure at entry and drops it itself on a fallible path
    // (advanced_subscriber.rs:195->201/:419), so this is a gravestone no-op
    // today — z_closure_*_drop on an already-moved closure is defined. It is
    // here so the guarantee does not depend on that canon detail holding.
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return rc;
}

/// Miss callback: posts miss info to Dart via native port.
static void _zd_miss_callback(const ze_miss_t* miss, void* context) {
  zd_subscriber_context_t* ctx = (zd_subscriber_context_t*)context;

  // Extract ZID + EID from the source entity global id. The whole callback is
  // already inside the outer Z_FEATURE_UNSTABLE_API guard (there is no
  // unstable-off compilation path for it), so eid is read directly alongside
  // zid — no inner #ifdef and no kNull placeholder is needed here (note (e)'s
  // constant-length concern applies only to callbacks that compile in both
  // unstable-on and unstable-off; this one never compiles unstable-off).
  z_id_t zid = z_entity_global_id_zid(&miss->source);
  uint32_t eid = z_entity_global_id_eid(&miss->source);
  uint32_t nb = miss->nb;

  // Post [Uint8List(16 bytes of zid.id), Int64(nb), Int64(eid)] to Dart.
  Dart_CObject c_zid;
  c_zid.type = Dart_CObject_kTypedData;
  c_zid.value.as_typed_data.type = Dart_TypedData_kUint8;
  c_zid.value.as_typed_data.length = 16;
  c_zid.value.as_typed_data.values = zid.id;

  Dart_CObject c_nb;
  c_nb.type = Dart_CObject_kInt64;
  c_nb.value.as_int64 = (int64_t)nb;

  Dart_CObject c_eid;
  c_eid.type = Dart_CObject_kInt64;
  c_eid.value.as_int64 = (int64_t)eid;

  Dart_CObject* elements[3] = {&c_zid, &c_nb, &c_eid};
  Dart_CObject c_array;
  c_array.type = Dart_CObject_kArray;
  c_array.value.as_array.length = 3;
  c_array.value.as_array.values = elements;

  if (!Dart_PostCObject_DL(ctx->dart_port, &c_array)) {
    // Port closed: one miss event is lost. Copies only — nothing to reclaim.
  }
}

FFI_PLUGIN_EXPORT
int zd_advanced_subscriber_declare_background_sample_miss_listener(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port) {

  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return -1;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: ZERO HERE PERMANENTLY, and not because nobody got round to
  // it. This registers `ze_closure_miss` / `_zd_miss_callback`, which carries
  // a source id and a count -- no payload at all -- so there is nothing to
  // retain. It is the one `zd_subscriber_context_t` site that is NOT one of
  // the six payload-carrying sample registrations.
  ctx->retain_payload = 0;

  ze_owned_closure_miss_t miss_callback;
  ze_closure_miss(&miss_callback, _zd_miss_callback, _zd_sample_drop, ctx);

  int rc = ze_advanced_subscriber_declare_background_sample_miss_listener(
      subscriber, ze_closure_miss_move(&miss_callback));

  if (rc != 0) {
    // Same house backstop as the declare path above: a gravestone no-op under
    // canon 1.8.0's take-at-entry handling, present so the guarantee is ours
    // rather than canon's.
    ze_closure_miss_drop(ze_closure_miss_move(&miss_callback));
  }

  return rc;
}

FFI_PLUGIN_EXPORT
int zd_advanced_subscriber_detect_publishers_background(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port,
    int history,
    int retain_payload) {
  zd_subscriber_context_t* ctx =
      (zd_subscriber_context_t*)malloc(sizeof(zd_subscriber_context_t));
  if (!ctx) return ZD_DECLARE_EALLOC;
  ctx->dart_port = (Dart_Port_DL)dart_port;
  // Seed [10a]: explicit, because malloc does not zero. Slice 2 wires
  // the flag on zd_declare_subscriber only; every other sample surface
  // is opted in by its own later slice and retains nothing until then.
  ctx->retain_payload = retain_payload;

  // The SENTINEL drop, not the plain one. Canon owns this listener's lifetime
  // (it lives to session close, outliving the advanced subscriber), so the
  // only signal the Dart side can get for "no more events are coming" is the
  // null sentinel this drop posts. That is the same contract
  // zd_declare_background_subscriber already ships and createSampleChannel()
  // already consumes.
  z_owned_closure_sample_t callback;
  z_closure_sample(&callback, _zd_sample_callback,
                   _zd_sample_drop_with_sentinel, ctx);

  // Negative means "unspecified": pass NULL and let canon's own default stand
  // (history = false). Canon accepts NULL options here.
  z_liveliness_subscriber_options_t opts;
  z_liveliness_subscriber_options_default(&opts);
  if (history >= 0) {
    opts.history = history != 0;
  }

  int rc = ze_advanced_subscriber_detect_publishers_background(
      subscriber, z_closure_sample_move(&callback),
      history >= 0 ? &opts : NULL);

  if (rc != 0) {
    // Canon did not take the closure, so its drop never runs. Dropping it here
    // runs _zd_sample_drop_with_sentinel, which frees ctx -- and posts the
    // sentinel, which is correct: the Dart side is told no events are coming.
    z_closure_sample_drop(z_closure_sample_move(&callback));
  }

  return rc;
}

FFI_PLUGIN_EXPORT
const ze_loaned_advanced_subscriber_t* zd_advanced_subscriber_loan(
    const ze_owned_advanced_subscriber_t* subscriber) {
  return ze_advanced_subscriber_loan(subscriber);
}

FFI_PLUGIN_EXPORT
void zd_advanced_subscriber_drop(ze_owned_advanced_subscriber_t* subscriber) {
  ze_advanced_subscriber_drop(ze_advanced_subscriber_move(subscriber));
}

#endif // Z_FEATURE_UNSTABLE_API
