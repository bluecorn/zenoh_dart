// THE POST-DELAY HOOK — the CALIBRATION for seed [D1] slice 9's flood arm.
//
// ⛔ WHY IT EXISTS, and it is the only reason. Slice 9's first cell measures
// that a slow log sink does NOT slow zenoh's producing side, by comparing wall
// times. On its own that comparison is worthless: two numbers that match are
// equally consistent with "the post never blocks" and with "the instrument
// cannot see blocking at all". A leg that reads identically either way is
// worth nothing while looking like proof.
//
// So this hook INJECTS the defect. It swaps the same writable exported global
// `post_hook.c` swaps -- `nm -D` reports `B Dart_PostCObject_DL`, an 8-byte
// OBJECT in .bss -- and sleeps for a configured interval BEFORE forwarding.
// With it armed the driving loop must slow by a wide margin. That separation
// is what licenses the unarmed reading.
//
// ⛔ LD_PRELOAD CANNOT REACH THIS. The post is made through a function POINTER
// held in a variable, not through an interposable dynamic function symbol, so
// the loader never consults a preloaded definition. The swap has to happen at
// the variable.
//
// ⛔ NEVER PRODUCTION SURFACE, and the confinement is part of the design: it
// lives under `package/test/helpers/`, is loaded only under an explicit
// harness arm, is referenced from nothing in `package/lib`, and its built
// `.so` is not committed.
//
//   clang -shared -fPIC -O0 -g -o post_delay_hook.so post_delay_hook.c -ldl
//
// Symbols are `zdd_`-prefixed (d for delay): not `zd_`, which would be
// indistinguishable from shipped surface in a symbol dump, and not `zdh_`,
// which is `post_hook.c`'s. The two hooks must never be confused in a
// measurement, because they answer different questions.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

typedef struct _Dart_CObject Dart_CObject;
typedef int64_t Dart_Port_DL;
typedef bool (*PostFn)(Dart_Port_DL port, Dart_CObject* message);

static PostFn zdd_real_post = NULL;
static PostFn* zdd_slot = NULL;

/// Microseconds to sleep before each forward. 0 disarms.
static atomic_int zdd_delay_us = 0;

/// Posts seen since the last reset, and how many were actually delayed.
static atomic_int zdd_total = 0;
static atomic_int zdd_delayed = 0;

static bool zdd_wrapper(Dart_Port_DL port, Dart_CObject* message) {
  atomic_fetch_add(&zdd_total, 1);
  int us = atomic_load(&zdd_delay_us);
  if (us > 0) {
    atomic_fetch_add(&zdd_delayed, 1);
    struct timespec ts;
    ts.tv_sec = us / 1000000;
    ts.tv_nsec = (long)(us % 1000000) * 1000L;
    // nanosleep, not a busy loop: the point is to hold the EMITTING THREAD,
    // and a spin would also compete for the CPU the control run needs.
    nanosleep(&ts, NULL);
  }
  // FORWARD, always. A hook that swallowed a post would turn the measurement
  // into a study of the hook.
  return zdd_real_post(port, message);
}

/// Installs the wrapper. Call AFTER the package has initialised.
///
/// @return 0 installed; 1 library not loaded; 2 symbol absent; 3 slot empty.
///
/// Distinct positive codes deliberately: "0 delayed posts" and "the hook never
/// installed" read identically to a caller who only checks that it returned,
/// and they mean opposite things.
int zdd_install(void) {
  void* h = dlopen("libzenoh_dart.so", RTLD_NOLOAD | RTLD_LAZY);
  if (h == NULL) return 1;
  PostFn* slot = (PostFn*)dlsym(h, "Dart_PostCObject_DL");
  if (slot == NULL) return 2;
  if (*slot == NULL) return 3;
  if (zdd_slot == NULL) {
    zdd_slot = slot;
    zdd_real_post = *slot;
  }
  *zdd_slot = zdd_wrapper;
  return 0;
}

/// Restores the real entry. Idempotent.
void zdd_uninstall(void) {
  if (zdd_slot != NULL && zdd_real_post != NULL) *zdd_slot = zdd_real_post;
}

/// Sets the per-post delay in microseconds. 0 disarms without uninstalling,
/// so a run can measure armed and unarmed through the identical code path.
void zdd_set_delay_us(int us) { atomic_store(&zdd_delay_us, us); }

/// Posts observed since install.
int zdd_posts(void) { return atomic_load(&zdd_total); }

/// Posts that were actually delayed. ⛔ THE HOOK'S OWN POSITIVE CONTROL: a
/// wide wall-time separation with this at 0 would mean something else slowed
/// the run.
int zdd_delayed_posts(void) { return atomic_load(&zdd_delayed); }

/// Zeroes the counters. Does not uninstall or disarm.
void zdd_reset(void) {
  atomic_store(&zdd_total, 0);
  atomic_store(&zdd_delayed, 0);
}
