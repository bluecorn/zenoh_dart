// THE POST-SITE HOOK — a TEST INSTRUMENT that answers "does this native
// release reach a Dart C API?" by measurement rather than by reading.
//
// ⛔ THIS IS NEVER PRODUCTION SURFACE, AND THE CONFINEMENT IS PART OF THE
// DESIGN. It swaps an exported writable global inside a loaded library. That is
// legitimate for a measurement and unacceptable anywhere else, so: it lives
// under `package/test/helpers/`, it is loaded only under an explicit harness
// arm, nothing in `package/lib` references it, and its built `.so` is not
// committed. If you find yourself wanting it on a shipped path, you want a
// different design.
//
// WHY IT EXISTS. Criterion (ii) of the finalized-subset test is: *this class's
// native release does not transitively call any Dart C API.* A
// `NativeFinalizer` callback runs with no current isolate, and the SDK is
// explicit that re-entering the VM from one "results in undefined behavior" —
// `Dart_PostCObject_DL` is such an entry, and five of this shim's own drop
// callbacks post.
//
// That criterion was READ FROM SOURCE for every class in the map, and reading
// it is exactly what cost two admission rows: `z_undeclare_querier` posts a
// getter's sentinel from INSIDE the undeclare, and `zd_query_drop` posts TWICE
// on the one-session path. Neither is visible from the Dart side, and neither
// was going to be found by reading harder. So the instrument.
//
// HOW IT WORKS. `libzenoh_dart.so` reaches the VM through a writable exported
// global — `nm -D` reports `B Dart_PostCObject_DL`, an 8-byte OBJECT in .bss.
// `zdh_install()` takes that variable's address with `dlsym`, saves the real
// entry, and writes a wrapper in its place. The wrapper records the calling
// thread and whether an armed marker symbol is anywhere on the stack, then
// forwards. Zero patching of `package/`.
//
// ⚠️ THE TOPOLOGY IS PART OF EVERY RESULT THIS PRODUCES. The same release posts
// or does not depending on whether the peers are in one process or two: on the
// one-session path a drop can run canon's callbacks inline, while over TCP the
// same posts land on IO threads. A criterion-(ii) number without its topology
// is not a result. The harness, not this file, is responsible for saying which
// one it ran.
//
//   clang -shared -fPIC -O0 -g -o post_hook.so post_hook.c -ldl
//
// Symbols are `zdh_`-prefixed (h for harness) rather than `zd_`: this is not
// the shim, it is never parsed by ffigen, and a `zd_` symbol here would be
// indistinguishable from shipped surface in a symbol dump.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Mirrors Dart's own signature. Declared locally rather than including
// dart_native_api.h so this helper builds with no include path beyond libc.
typedef struct _Dart_CObject Dart_CObject;
typedef int64_t Dart_Port_DL;
typedef bool (*PostFn)(Dart_Port_DL port, Dart_CObject* message);

static PostFn zdh_real_post = NULL;
static PostFn* zdh_slot = NULL;

static atomic_int zdh_total;
static atomic_int zdh_under_marker;
static atomic_int zdh_last_on_main;

// ZD_FIN_ON_MAIN_* mirrored, so one vocabulary describes "which thread" across
// both instruments in this seed.
#define ZDH_ON_MAIN_UNOBSERVED 0
#define ZDH_ON_MAIN_NO 1
#define ZDH_ON_MAIN_YES 2

static pthread_t zdh_install_thread;
static atomic_int zdh_install_thread_known;

#define ZDH_MARKER_MAX 128
static char zdh_marker[ZDH_MARKER_MAX];
static atomic_int zdh_marker_armed;

#define ZDH_FRAMES 64

// Is the armed marker symbol anywhere on the current call stack?
//
// `backtrace` + `dladdr` rather than a symbol table walk: `dladdr` resolves an
// address to the nearest preceding EXPORTED symbol, which is exactly what we
// want here -- the drop entries we arm on (`zd_config_drop`, `z_query_drop`,
// `z_undeclare_querier`) are all exported, and an inlined helper inside one of
// them resolves to its enclosing export rather than vanishing.
//
// ⚠️ That resolution rule is also this instrument's known limit, stated rather
// than discovered later: a STATIC function in a stripped object resolves to
// whatever export precedes it, so a marker match is evidence the post happened
// somewhere at or after that export, not that it happened in that exact frame.
// Every use of this is paired with a negative control for that reason.
static bool zdh_marker_on_stack(void) {
  if (!atomic_load(&zdh_marker_armed)) return false;
  void* frames[ZDH_FRAMES];
  int n = backtrace(frames, ZDH_FRAMES);
  for (int i = 0; i < n; i++) {
    Dl_info info;
    if (dladdr(frames[i], &info) == 0) continue;
    if (info.dli_sname == NULL) continue;
    if (strcmp(info.dli_sname, zdh_marker) == 0) return true;
  }
  return false;
}

static bool zdh_wrapper(Dart_Port_DL port, Dart_CObject* message) {
  atomic_fetch_add(&zdh_total, 1);
  if (zdh_marker_on_stack()) atomic_fetch_add(&zdh_under_marker, 1);

  int on_main = ZDH_ON_MAIN_UNOBSERVED;
  if (atomic_load(&zdh_install_thread_known)) {
    on_main = pthread_equal(pthread_self(), zdh_install_thread)
                  ? ZDH_ON_MAIN_YES
                  : ZDH_ON_MAIN_NO;
  }
  atomic_store(&zdh_last_on_main, on_main);

  // FORWARD, always. This instrument must not change what the program does --
  // a hook that swallowed a post would turn every measurement into a study of
  // the hook.
  return zdh_real_post(port, message);
}

/// Installs the wrapper. Call from Dart AFTER the package has initialised, so
/// `libzenoh_dart.so` is loaded and its Dart API DL slot is populated.
///
/// @return 0 on success; 1 if the library is not loaded; 2 if the symbol is
///         absent; 3 if the slot is empty (the Dart API DL was never
///         initialised, so there is nothing to wrap and a measurement here
///         would read a spurious zero).
///
/// Positive codes with distinct meanings, deliberately: "0 posts" and "the
/// hook never installed" are the same reading to a caller who only checks
/// whether it returned, and they mean opposite things.
int zdh_install(void) {
  void* h = dlopen("libzenoh_dart.so", RTLD_NOLOAD | RTLD_LAZY);
  if (h == NULL) return 1;
  PostFn* slot = (PostFn*)dlsym(h, "Dart_PostCObject_DL");
  if (slot == NULL) return 2;
  if (*slot == NULL) return 3;
  if (zdh_slot == NULL) {
    zdh_slot = slot;
    zdh_real_post = *slot;
  }
  zdh_install_thread = pthread_self();
  atomic_store(&zdh_install_thread_known, 1);
  *zdh_slot = zdh_wrapper;
  return 0;
}

/// Restores the real entry. Idempotent.
void zdh_uninstall(void) {
  if (zdh_slot != NULL && zdh_real_post != NULL) *zdh_slot = zdh_real_post;
}

/// Arms the stack marker. Pass an exported symbol name; NULL or "" disarms.
void zdh_arm(const char* symbol) {
  if (symbol == NULL || symbol[0] == '\0') {
    atomic_store(&zdh_marker_armed, 0);
    return;
  }
  snprintf(zdh_marker, ZDH_MARKER_MAX, "%s", symbol);
  atomic_store(&zdh_marker_armed, 1);
}

/// Zeroes the counters. Does NOT uninstall or disarm.
void zdh_reset(void) {
  atomic_store(&zdh_total, 0);
  atomic_store(&zdh_under_marker, 0);
  atomic_store(&zdh_last_on_main, ZDH_ON_MAIN_UNOBSERVED);
}

/// Posts observed since the last reset.
int zdh_posts(void) { return atomic_load(&zdh_total); }

/// Posts observed with the armed marker on the stack.
int zdh_posts_under_marker(void) { return atomic_load(&zdh_under_marker); }

/// ZDH_ON_MAIN_* for the most recent post.
int zdh_last_on_main_value(void) { return atomic_load(&zdh_last_on_main); }
