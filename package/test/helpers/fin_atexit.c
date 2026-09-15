// Seed [OWN], slice 13 — reports the finalizer counters AFTER the Dart isolate
// group is gone.
//
// WHY THIS EXISTS AT ALL. The shutdown-guarantee cell asks whether objects
// still attached when a program simply RETURNS FROM MAIN get released at
// isolate-group shutdown. Two things make that unmeasurable from Dart:
//
//   1. A `test()` cannot observe its own file's isolate-group shutdown from
//      inside that file — the observation point is after everything Dart in
//      the process has stopped.
//   2. A counter read FROM DART cannot be read after the Dart isolate is gone,
//      which is precisely when the answer exists.
//
// So the reading is taken from a native `__attribute__((destructor))`, which
// runs during library teardown, after the VM has finished.
//
// ⚠️ `dlsym(RTLD_DEFAULT, ...)` DOES NOT WORK HERE and the first cut of this
// file used it. `DynamicLibrary.open` loads with RTLD_LOCAL, so the shim's
// symbols never enter the global namespace and the lookup returns NULL — the
// helper reported NO_SYMBOL from a process that had the library mapped.
// Re-acquiring the handle with `dlopen(..., RTLD_NOLOAD)` and looking up
// through it is what works, and it is the same route `post_hook.c` already
// takes for the same reason.
//
//   clang -shared -fPIC -O0 -o fin_atexit.so fin_atexit.c -ldl
//   LD_PRELOAD=./fin_atexit.so <program>
//
// ⚠️ IT PRINTS TO STDERR AND STARTS WITH A NEWLINE, deliberately: at
// destructor time stdout may already be torn down, and the leading newline
// keeps the marker at the start of a line so `startsWith` matching in
// `HarnessOutcome` can see it.
//
// ⛔ TEST HELPER. Never referenced from `package/lib`, loaded only under an
// explicit harness arm, and its built `.so` is not committed.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

// Mirrors ZD_FIN_KIND_* in src/zenoh_dart.h. Kept as literals rather than an
// include so this helper needs no include path.
#define K_FREE_BLOCK 0
#define K_CONFIG 1
#define K_KEYEXPR 2

typedef int (*zd_fin_invocations_fn)(int);

__attribute__((destructor)) static void zd_atexit_report(void) {
  void* h = dlopen("libzenoh_dart.so", RTLD_NOLOAD | RTLD_LAZY);
  zd_fin_invocations_fn f =
      h ? (zd_fin_invocations_fn)dlsym(h, "zd_fin_invocations") : NULL;
  if (f == NULL) {
    // Distinct from "the counters were zero" -- a missing symbol means THIS
    // process never loaded the shim (the `fvm`/`dart` wrapper processes run
    // this destructor too), and reporting zeros there would be a false
    // negative of exactly the kind this seed keeps catching. The cell matches
    // on the NUMERIC markers, so a wrapper's NO_SYMBOL line is inert.
    fprintf(stderr, "\nFIN_ATEXIT_NO_SYMBOL\n");
    fflush(stderr);
    return;
  }
  fprintf(stderr, "\nFIN_ATEXIT_FREEBLOCK=%d\n", f(K_FREE_BLOCK));
  fprintf(stderr, "FIN_ATEXIT_CONFIG=%d\n", f(K_CONFIG));
  fprintf(stderr, "FIN_ATEXIT_KEYEXPR=%d\n", f(K_KEYEXPR));
  fflush(stderr);
}
