// LD_PRELOAD malloc/free COUNTER for shim-side context blocks.
//
// WHY A COUNTER AND NOT THE PROBE THIS FILE'S SIBLINGS USE. A leak is invisible
// to every behavioural assertion — dispose, double-dispose and accessor-guard
// cells all pass identically on leaking and on fixed code — so the discipline
// is to measure the RESOURCE and to count rather than sample once. The usual
// in-tree instrument for that is the block's own address, exposed to Dart
// (`Query.handle`, `PullSubscriber.teeAddressForTesting`). That instrument does
// not exist for `zd_matching_context_t` or `zd_subscriber_context_t`: the shim
// mallocs them and hands them to canon, never to Dart.
//
// The fallback in `ffi_ownership_test.dart` — allocate a same-size proxy per
// cycle and watch whether its address is reused — is measured NON-discriminating
// at this size class. That file's own comments record both failures: a 32-byte
// proxy swamped by declare churn (13 distinct fixed vs 6 leaking, the leak
// making the assertion pass MORE easily), and a ~48-byte block a coin toss with
// Session.open in the loop (16 vs 20, "a margin of 4, which is not an
// instrument"). Both new contexts are a single Dart_Port_DL — EIGHT bytes, the
// most heavily trafficked size class in the process. A proxy there would be
// worse than either.
//
// So this counts the real blocks instead, filtered the way
// `malloc_fail_injector.c` already filters: by CALLER. Only allocations of
// exactly ZD_COUNT_SIZE bytes made from inside libzenoh_dart.so are tracked,
// which is what keeps Dart's and canon's own 8-byte traffic out of the number.
//
//   clang -shared -fPIC -O0 -o shim_alloc_counter.so shim_alloc_counter.c -ldl
//   ZD_COUNT_SIZE=8 LD_PRELOAD=./shim_alloc_counter.so <program>
//
// TWO AXES, ADDED AT SEED #10, and the reason is a measurement. This counter
// tracked `malloc` only, filtered to callers inside libzenoh_dart.so. That is
// exactly right for shim-owned context blocks -- and BLIND to the other side of
// the FFI seam. The send-path marshalling buffers are allocated by DART, with
// `package:ffi`'s calloc, so they are neither `malloc` nor called from the
// shim. Measured before this change: five deliberately leaked 61-byte Dart
// blocks reported `allocs=0 frees=0 outstanding=0` -- a clean count on a
// leaking program, which is the worst possible reading.
//
//   ZD_COUNT_EXCLUDE_SYM=<name>  a shim FUNCTION whose allocations are not
//                               counted, matched exactly against dladdr's
//                               dli_sname. Unset by default. See exclude_sym().
//
//   ZD_COUNT_CALLER=<substring>  which shared object must own the allocation
//                               site. Defaults to `libzenoh_dart.so`, so every
//                               existing consumer is unchanged. Set it to `*`
//                               to count regardless of caller, which is what
//                               the Dart-side buffers need -- lean on a
//                               DISTINCTIVE size class instead, and measure the
//                               baseline noise at that size before trusting it.
//
// `calloc` is now intercepted as well as `malloc`. glibc's calloc does not
// route through malloc, so without this the Dart side is invisible whatever the
// caller filter says.
//
// On exit it prints one line to stderr:
//
//   SHIM_ALLOC_COUNTER size=8 allocs=<n> frees=<m> outstanding=<k> overflow=<0|1>
//
// `outstanding` is the measurement. `overflow=1` means the tracking table
// filled and the numbers are NOT trustworthy — reported rather than silently
// truncated, because a truncated count reads as a clean one.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *__libc_malloc(size_t size);
extern void *__libc_calloc(size_t n, size_t size);
extern void __libc_free(void *ptr);

#define TABLE_CAP 65536

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static void *tracked[TABLE_CAP];
static size_t tracked_n = 0;
static unsigned long allocs = 0;
static unsigned long frees = 0;
static int overflow = 0;

/// The caller substring an allocation site must match, or "*" for any.
static const char *count_caller(void) {
  static const char *configured = NULL;
  if (configured == NULL) {
    const char *env = getenv("ZD_COUNT_CALLER");
    configured = (env && *env) ? env : "libzenoh_dart.so";
  }
  return configured;
}

/// The shim FUNCTION whose allocations are excluded, or NULL for none.
///
/// Added at seed #10b, for a collision the counter cannot otherwise see.
/// `zd_open_session_async` allocates a `z_owned_session_t` of EXACTLY EIGHT
/// BYTES from inside libzenoh_dart.so -- the same size class and the same
/// shared object as the context blocks this counter exists to track. Every
/// counting harness opens a session, so before this filter each open added one
/// to `allocs` and the cells read one high per session (measured: 21 against
/// 20 for the matching leg, 30 against 20 for the detect leg, and an
/// outstanding of 11 against 10 for the trap leg).
///
/// Widening the expected numbers instead would have made them mean "contexts
/// PLUS session blocks", so a future leak of one could be absorbed by the
/// other. Excluding at the site keeps each number meaning what it says.
static const char *exclude_sym(void) {
  static const char *configured = NULL;
  static int resolved = 0;
  if (!resolved) {
    const char *env = getenv("ZD_COUNT_EXCLUDE_SYM");
    configured = (env && *env) ? env : NULL;
    resolved = 1;
  }
  return configured;
}

/// Records `p` if its allocation site passes the caller and symbol filters.
///
/// `ret` is the caller's return address; dladdr resolves it to a shared object
/// and to the nearest exported symbol. dladdr itself allocates, so a nested
/// call must take the plain path.
static void track(void *p, void *ret) {
  const char *want_caller = count_caller();
  const char *skip_sym = exclude_sym();
  if (strcmp(want_caller, "*") != 0 || skip_sym != NULL) {
    static __thread int busy = 0;
    if (busy) return;
    busy = 1;
    Dl_info info;
    int ok = dladdr(ret, &info);
    busy = 0;
    if (strcmp(want_caller, "*") != 0 &&
        (!ok || !info.dli_fname || !strstr(info.dli_fname, want_caller))) {
      return;
    }
    if (skip_sym != NULL && ok && info.dli_sname &&
        strcmp(info.dli_sname, skip_sym) == 0) {
      return;
    }
  }
  pthread_mutex_lock(&lock);
  if (tracked_n < TABLE_CAP) {
    tracked[tracked_n++] = p;
    allocs++;
  } else {
    overflow = 1;
  }
  pthread_mutex_unlock(&lock);
}

static size_t count_size(void) {
  static size_t configured = (size_t)-1;
  if (configured == (size_t)-1) {
    const char *env = getenv("ZD_COUNT_SIZE");
    configured = env ? (size_t)strtoull(env, NULL, 10) : 0;
  }
  return configured;
}

void *malloc(size_t size) {
  void *p = __libc_malloc(size);
  size_t want = count_size();
  if (want == 0 || size != want || p == NULL) return p;
  track(p, __builtin_return_address(0));
  return p;
}

void *calloc(size_t n, size_t size) {
  void *p = __libc_calloc(n, size);
  size_t want = count_size();
  if (want == 0 || p == NULL) return p;
  // package:ffi's calloc<Uint8>(len) reaches libc as calloc(len, 1), so the
  // tracked size is the PRODUCT, matching what the caller asked for.
  if (n * size != want) return p;
  track(p, __builtin_return_address(0));
  return p;
}

void free(void *ptr) {
  if (ptr != NULL && count_size() != 0) {
    pthread_mutex_lock(&lock);
    for (size_t i = 0; i < tracked_n; i++) {
      if (tracked[i] == ptr) {
        tracked[i] = tracked[--tracked_n];
        frees++;
        break;
      }
    }
    pthread_mutex_unlock(&lock);
  }
  __libc_free(ptr);
}

__attribute__((destructor)) static void report(void) {
  if (count_size() == 0) return;
  fprintf(stderr,
          "SHIM_ALLOC_COUNTER size=%zu allocs=%lu frees=%lu outstanding=%lu "
          "overflow=%d\n",
          count_size(), allocs, frees, allocs - frees, overflow);
}
