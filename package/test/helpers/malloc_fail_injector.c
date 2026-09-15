// LD_PRELOAD allocation-failure injector for the fix-round's group E leg.
//
// Group E guards `malloc` on paths whose size is chosen by the PEER. Proving a
// guard live needs an induced NULL, and the two obvious instruments do not
// work here:
//
//   * MALLOC_PERTURB_ does not induce failure at all -- it poisons bytes and
//     malloc still succeeds, so every `if (!ptr)` branch stays unreachable and
//     the leg is green before and after the fix (measured 2026-08-07).
//   * RLIMIT_AS does return NULL, but zenoh reaches the same wall FIRST and
//     Rust's allocator ABORTS rather than returning NULL:
//       "memory allocation of 419430400 bytes failed / Aborted (core dumped)"
//     (measured here: `ulimit -v 2000000` + a 400 MB payload). The process
//     dies inside canon before our shim is ever called.
//
// So the failure is injected surgically instead: fail `malloc` only when the
// CALLER is libzenoh_dart.so and the request is at least
// ZD_FAIL_MALLOC_OVER bytes. Canon's own allocator is untouched, so nothing
// aborts and the only NULL in the process is the one under test.
//
//   clang -shared -fPIC -O0 -o malloc_fail_injector.so malloc_fail_injector.c -ldl
//   ZD_FAIL_MALLOC_OVER=600000 LD_PRELOAD=./malloc_fail_injector.so <program>
//
// It prints `INJECTOR_FIRED size=<n>` to stderr on every injected failure --
// the positive control. A run that produces the pass markers WITHOUT that line
// proves nothing, because the branch under test was never entered.
//
// ---------------------------------------------------------------------------
// SEED #9: a `realloc` interposer and an EXACT-size mode.
//
// The zid enumeration collects into a shim-owned buffer that grows by
// `realloc` inside canon's closure. Two reasons the existing mode cannot
// reach it, both measured rather than assumed:
//
//   * glibc's `realloc` does NOT route through an interposed `malloc`. The
//     malloc-only interposer above is blind to every growth allocation on that
//     path, so it would fire on nothing and the leg would read as a clean
//     green -- the same false-negative class the header already records for
//     MALLOC_PERTURB_ and RLIMIT_AS.
//   * The threshold mode is unfit even with a realloc hook. The buffer's size
//     VARIES along the growth ladder (16, 32, 64 ...) and every rung is tiny,
//     so any threshold low enough to catch a rung also catches unrelated small
//     allocations, and any threshold high enough to be selective catches
//     nothing at all.
//
// So the realloc arm is armed at an EXACT size instead:
//
//   ZD_FAIL_REALLOC_SIZE=32 LD_PRELOAD=./malloc_fail_injector.so <program>
//
// 32 is the ladder's SECOND rung -- `realloc(buf, 32)` with a live 16-byte
// buffer already held. That choice is what makes the cell reach the thing it
// exists to prove: failing the FIRST rung, `realloc(NULL, 16)`, leaves
// `buf == NULL`, so "the wrapper released the partial buffer" degrades to a
// `free(NULL)` no-op and the cell would pass identically against a wrapper
// that freed nothing.
//
// The two modes are independent: leaving ZD_FAIL_MALLOC_OVER unset keeps
// `malloc` entirely untouched while the realloc arm is armed, and vice versa.
// Both keep the same caller filter (libzenoh_dart.so), so canon's own
// allocator is never made to fail and nothing aborts.
//
// ---------------------------------------------------------------------------
// SEED #10b: an EXACT-size mode for `malloc`, for the same reason.
//
// `Session.open` is now OFFLOADED, and the offloaded entry allocates two heap
// blocks of its own before canon is ever called. Measured on the reply-channel
// harness path, the three shim mallocs in that process are:
//
//   2024  zd_open_session_async's worker block
//      8  zd_open_session_async's session block
//     40  the reply tee context -- the ONLY one under test
//
// So the threshold mode is now unfit for that leg exactly as it was for the
// realloc ladder: ZD_FAIL_MALLOC_OVER=8 fails all three, the open dies with
// ZD_OPEN_EALLOC before the harness reaches pullGet, and the cell asserting
// `code=11` from zd_get_channel reads a failure from the WRONG SITE. That is a
// red the leg could not have shown before the offload landed -- no run prior
// to it touched an allocating open.
//
// The malloc arm therefore gains an exact-size mode, symmetrical with the
// realloc one:
//
//   ZD_FAIL_MALLOC_SIZE=40 LD_PRELOAD=./malloc_fail_injector.so <program>
//
// ⚠️ An exact size is a sizeof, and a sizeof can drift. It fails SAFE: a drift
// makes the injector fire on nothing, `INJECTOR_FIRED` disappears, and the
// positive control in the driver cell goes RED. It cannot produce a false
// green.
//
// The three modes are mutually independent; ZD_FAIL_MALLOC_SIZE and
// ZD_FAIL_MALLOC_OVER may be armed together, and either alone.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// glibc's own allocator entry point. Used directly rather than via
// dlsym(RTLD_NEXT, "malloc"), which allocates during resolution and would
// re-enter this interposer before it is ready.
extern void* __libc_malloc(size_t size);
extern void* __libc_realloc(void* ptr, size_t size);

static size_t zd_threshold(void) {
  static size_t threshold = (size_t)-1;
  if (threshold == (size_t)-1) {
    const char* env = getenv("ZD_FAIL_MALLOC_OVER");
    threshold = env ? (size_t)strtoull(env, NULL, 10) : 0;
  }
  return threshold;
}

// The exact request size the malloc arm fails at. 0 disables the arm.
static size_t zd_malloc_exact(void) {
  static size_t exact = (size_t)-1;
  if (exact == (size_t)-1) {
    const char* env = getenv("ZD_FAIL_MALLOC_SIZE");
    exact = env ? (size_t)strtoull(env, NULL, 10) : 0;
  }
  return exact;
}

// The exact request size the realloc arm fails at. 0 disables the arm.
static size_t zd_realloc_exact(void) {
  static size_t exact = (size_t)-1;
  if (exact == (size_t)-1) {
    const char* env = getenv("ZD_FAIL_REALLOC_SIZE");
    exact = env ? (size_t)strtoull(env, NULL, 10) : 0;
  }
  return exact;
}

// Returns 1 when the immediate caller lives in libzenoh_dart.so.
//
// dladdr can allocate, so the guard keeps a nested call on the real path.
static int zd_caller_is_shim(void* return_address) {
  static __thread int in_dladdr = 0;
  if (in_dladdr) return 0;
  in_dladdr = 1;
  Dl_info info;
  int ok = dladdr(return_address, &info);
  in_dladdr = 0;
  return ok && info.dli_fname && strstr(info.dli_fname, "libzenoh_dart.so");
}

void* malloc(size_t size) {
  size_t threshold = zd_threshold();
  size_t exact = zd_malloc_exact();
  int matches = (threshold != 0 && size >= threshold) ||
                (exact != 0 && size == exact);
  if (matches && zd_caller_is_shim(__builtin_return_address(0))) {
    fprintf(stderr, "INJECTOR_FIRED size=%zu\n", size);
    return NULL;
  }
  return __libc_malloc(size);
}

void* realloc(void* ptr, size_t size) {
  size_t exact = zd_realloc_exact();
  if (exact != 0 && size == exact &&
      zd_caller_is_shim(__builtin_return_address(0))) {
    fprintf(stderr, "INJECTOR_FIRED realloc size=%zu\n", size);
    return NULL;
  }
  return __libc_realloc(ptr, size);
}
