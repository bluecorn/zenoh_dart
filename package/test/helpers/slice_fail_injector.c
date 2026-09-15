// THE SLICE-CONVERSION INJECTOR — makes an unreachable failure branch
// reachable, for seed [D1] slice 13.
//
// ⛔ WHY IT HAS TO EXIST. The defect this slice fixes is that a FAILED payload
// conversion is posted as a zero-length success: the shim tests
// `z_bytes_len(bytes) > 0 && z_bytes_to_slice(bytes, slice) == 0` and, when
// the second half is false, posts an empty buffer with no error signal at all.
// At the pinned zenoh-c that branch CANNOT BE ENTERED —
// `extern/zenoh-c/src/zbytes.rs:144-152` returns `Z_OK` unconditionally, from
// a single definition. So the fix is untestable without injection, and an
// untested fix on a receive path is how the original defect got there.
//
// ⛔ LD_PRELOAD IS THE RIGHT TOOL *HERE*, and it is worth saying why, because
// the sibling hook in this directory needed a different one. `z_bytes_to_slice`
// is a TEXT symbol defined by libzenohc.so and IMPORTED by libzenoh_dart.so, so
// the call goes through the PLT and a preloaded definition wins. The post-site
// hook could not use this: `Dart_PostCObject_DL` is a writable data POINTER,
// not an interposable function symbol, and the loader never consults a preload
// for it.
//
// ⛔ AND IT MUST LEAVE `dst` DEFINED. Canon's signature takes
// `&mut MaybeUninit<z_owned_slice_t>`, so returning an error without writing
// it would hand the shim uninitialised memory and make every result a study of
// undefined behaviour rather than of the branch. This writes canon's own
// gravestone with `z_internal_slice_null` before returning the error — a
// gravestone needs no drop, so the shim's "do not drop on failure" path stays
// correct and nothing leaks.
//
// ⛔ ARMED FROM DART, NOT FROM THE ENVIRONMENT, and the difference decides
// whether the cells mean anything. An env-armed injector fires on the nth
// process-wide call, and setup — opening sessions, declaring entities —
// makes an unpredictable number of them. The cell would then be asserting
// against whichever call happened to be nth, which is not a controlled
// experiment. Dart opens the SAME already-preloaded object (dlopen of a
// loaded library returns the existing handle), calls `zdi_arm` immediately
// before the operation under test and `zdi_disarm` immediately after, so the
// window is exactly the one the cell describes.
//
//   zdi_arm(skip, count, rc)
//                        let `skip` conversions through, then fail `count`
//                        of them with `rc`. ⚠️ `skip` is what reaches the
//                        ATTACHMENT arm: a sample carrying both converts its
//                        payload FIRST, so arming from zero fails the payload
//                        and never exercises the attachment branch at all --
//                        which the first run of this did, reporting a
//                        "payload" error from a cell about attachments.
//   zdi_disarm()         stop failing; the counter is left readable
//   zdi_fired()          how many failures were actually injected
//
// ⛔ `zdi_fired()` IS THE POSITIVE CONTROL, and every cell reads it. A run
// that produces the expected output with it at 0 proves nothing, because the
// branch under test was never entered.
//
//   clang -shared -fPIC -O0 -g -o slice_fail_injector.so \
//       slice_fail_injector.c -ldl
//
// Symbols are `zdi_`-prefixed (i for injector): not `zd_`, which would be
// indistinguishable from shipped surface in a symbol dump, and not `zdh_`/
// `zdd_`, which belong to the two post-site hooks and answer other questions.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

typedef int8_t z_result_t;
typedef void z_loaned_bytes_t;
typedef void z_owned_slice_t;
typedef z_result_t (*ToSliceFn)(const z_loaned_bytes_t*, z_owned_slice_t*);
typedef void (*SliceNullFn)(z_owned_slice_t*);

static atomic_int zdi_remaining = 0;
static atomic_int zdi_skip = 0;
static atomic_int zdi_fired_count = 0;
static atomic_int zdi_rc = -7;

/// Lets [skip] conversions through, then fails the next [count] with [rc].
void zdi_arm(int skip, int count, int rc) {
  atomic_store(&zdi_rc, rc);
  atomic_store(&zdi_skip, skip);
  atomic_store(&zdi_remaining, count);
}

/// Disarms. The fired counter is deliberately NOT reset: a cell reads it
/// after the window has closed.
void zdi_disarm(void) {
  atomic_store(&zdi_remaining, 0);
  atomic_store(&zdi_skip, 0);
}

/// Failures actually injected. ⛔ THE POSITIVE CONTROL.
int zdi_fired(void) { return atomic_load(&zdi_fired_count); }

/// Zeroes the fired counter. Does not arm or disarm.
void zdi_reset(void) { atomic_store(&zdi_fired_count, 0); }

/// Resolves a canon symbol, past this interposer.
///
/// ⛔ RTLD_NEXT ALONE IS NOT ENOUGH HERE, AND FINDING THAT OUT COST A CORE
/// DUMP. `RTLD_NEXT` searches the objects that follow this one in the INITIAL
/// link map — but `libzenohc.so` is not in it: the Dart side loads
/// `libzenoh_dart.so` with `dlopen` at runtime and libzenohc arrives with it
/// as a DT_NEEDED of that. So `dlsym(RTLD_NEXT, ...)` returned NULL, and the
/// delegating call went through a null pointer: `pc 0x0`, `isolate=(nil)`,
/// SIGABRT, with nothing naming the cause.
///
/// The fallback asks the already-loaded library directly, exactly as the
/// sibling post-site hook does for its own symbol.
static void* zdi_resolve(const char* name) {
  void* fn = dlsym(RTLD_NEXT, name);
  if (fn != NULL) return fn;
  void* h = dlopen("libzenohc.so", RTLD_NOLOAD | RTLD_LAZY);
  return h == NULL ? NULL : dlsym(h, name);
}

z_result_t z_bytes_to_slice(const z_loaned_bytes_t* this_,
                            z_owned_slice_t* dst) {
  static ToSliceFn real = NULL;
  static SliceNullFn slice_null = NULL;
  if (real == NULL) real = (ToSliceFn)zdi_resolve("z_bytes_to_slice");
  if (slice_null == NULL) {
    slice_null = (SliceNullFn)zdi_resolve("z_internal_slice_null");
  }

  // ⛔ NEVER CALL THROUGH A NULL POINTER. An instrument that segfaults when it
  // cannot resolve its target destroys the run it was measuring and says
  // nothing about the thing under test. Report and degrade instead: the
  // gravestone keeps `dst` defined, and the distinctive marker tells a reader
  // the injector — not the binding — is what went wrong.
  if (real == NULL) {
    if (slice_null != NULL) slice_null(dst);
    fprintf(stderr, "ZDI_UNRESOLVED\n");
    fflush(stderr);
    return -1;
  }

  // Burn the skip quota first, so `skip` counts CONVERSIONS rather than wall
  // time -- the payload and attachment of one sample convert microseconds
  // apart and no delay could separate them reliably.
  int skip = atomic_load(&zdi_skip);
  while (skip > 0) {
    if (atomic_compare_exchange_weak(&zdi_skip, &skip, skip - 1)) {
      return real(this_, dst);
    }
  }

  // Decrement-and-test, so N armed calls fail exactly N times even when the
  // conversions run concurrently on different tokio threads.
  int remaining = atomic_load(&zdi_remaining);
  while (remaining > 0) {
    if (atomic_compare_exchange_weak(&zdi_remaining, &remaining,
                                     remaining - 1)) {
      // Gravestone first, THEN the error: dst is never left uninitialised,
      // and a gravestone needs no drop -- so the shim's "do not drop on
      // failure" path stays correct and nothing leaks.
      if (slice_null != NULL) slice_null(dst);
      atomic_fetch_add(&zdi_fired_count, 1);
      fprintf(stderr, "ZDI_FIRED\n");
      fflush(stderr);
      return (z_result_t)atomic_load(&zdi_rc);
    }
  }
  return real(this_, dst);
}
