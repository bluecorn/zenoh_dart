# S6 — certification, `0.30.0` — targeted on both variants, by the developer's ruling

> **Where the cited tools live.** `native_manifest.py`, `suite_count.py`, `reader_scan.py` and the stage runners are committed
> in the private development repository, `bluecorn/zenoh_dart_dev`, on `release-record/0.30.0`
> (`development/release/0.30.0/`); this repository does not carry that tree.

**Stage:** S6 of `development/release/release-procedure.md` (A2; A6; P30–P36), run by CB on 2026-09-16 in the build clone at
**N = `fd73f75dd7aca25e50efc54c88c8c1d13f789fc6`**, built from **A = `673e669`** (dev E = `8fb1a3b`). The libraries certified
are the ones committed at N — **and S4's identity gate read them byte-identical to the sixteen `1.0.0-rc.1` ships**, which a
second clone reproduced (S5, `rebuild-compare.md`).

**What this release is:** a mirror of `1.0.0-rc.1` — the same code and the same libraries under a `0.30.0` version number so a
bare `dart pub add zenoh_dart` resolves to the current state (roadmap R64). **The diff `E → E′` is four files:** the pubspec's
`version:` line, the root `CHANGELOG.md`, the pub README, and the release assembly's own script. **No test file, no `lib/`, no
`hook/`, no `example/` program, no shim source, no build input and no library byte changed** — measured by path diff with a
control that fires.

## ⚖️ Scope — the developer's ruling, recorded as a DEVIATION

**Ruled 2026-09-16 by the developer, verbatim:** *"we have made the run multiple times and the code has not changed."*

**What ran:** the **eight** carried test files the ruled reader scan selects for the three changed carried files, **on both
variants, serially, in this repository at N**. **Everything else in the carried suite did not run.**

⛔ **This is a ruled scope, not a discharge.** A2a's rest-of-suite discharge governs fix iterations within a release and has no
anchor at a release's first pass; it is not claimed to be satisfied. **CB's own proposal at gate 1 was wider** — the whole
carried suite on the stable arm, to close a residual the previous release left open — and CA recommended it; **the developer
ruled it out on the ground quoted above.**

**The selection, and its controls** (`s6-reader-scan-at-Eprime.txt`): the scan reads the non-comment lines of every carried
test file and helper for each changed file's basename, then follows helpers transitively. **8 files selected, 0 helpers hit.**
Control 1: adding one planted helper basename selects exactly the three files that name it (8 → 11), so the transitive step is
live. Control 2: scanning for a known helper finds exactly its two importers.

⚠️ **Four of the eight are false positives of basename matching** — they read `example/README.md`, the cookbook, which this
release does not touch; every `README.md` literal in the carried suite names that file, never `package/README.md`. **They were
run anyway:** the scan is the ruled instrument and it errs toward selecting.

## Pre-flight (P30) and the analyzer (P34)

| # | instrument | reading |
|---|---|---|
| P30 | every outside path the carried suite reaches (`gate1-evidence/test-reach/reach.md`, Table 1) | **all present** — both build include trees, `scripts/instruments/export_surface.dart`, `src/zenoh_dart.{c,h}`, `scripts/`, `CHANGELOG.md`, `extern/zenoh-c/src/zbytes.rs`, `extern/zenoh-c/examples`, `package/example/README.md` |
| P30 | every `anchor:` a carried test names, against the carried CHANGELOG | `0.19.0` → **1 heading found**. ⭐ The new `## 0.30.0` section sits above that anchor and does not disturb it |
| P30 | the import closure of the carried tree | **0 relative directives naming no carried file** (the assembly's R11, at S3) |
| P34 | `fvm dart analyze package --fatal-infos --fatal-warnings` in this clone | **exit 0** |

## The runs

Run by `runners/s6-run.sh`, which asserts HEAD = N, an unmodified `package/pubspec.yaml` and the presence of all eight files
before starting, and does not stop on a red suite. **Nothing else of the release ran on the host during the suites:** S4 and S5
had finished, no build process was alive, and port 7447 carried no socket.

**Counts — test CASES, from the JSON reporter's `testDone` events with `hidden: false`, cross-checked against the expanded
reporter's closing tally** (`suite_count.py`): **two mechanisms, and they must agree.**

| arm | passed | failed | skipped | wall | the two mechanisms |
|---|---|---|---|---|---|
| **unstable** | **153** | **0** | **0** | 03:09 | **AGREE** — *"All tests passed!"* |
| **stable** | **147** | **0** | **6** | 02:49 | **AGREE** — *"All tests passed!"* |

**The stable arm ran after the uncommitted flip** — `sed` on `package/pubspec.yaml`'s `variant:` line; the runner printed
`ZENOH_DART_VARIANT=stable (declared in package/pubspec.yaml)` and `native: …/package/native/linux/x86_64/stable`. **The flip
was reverted and `git diff --exit-code -- package/pubspec.yaml` asserted clean afterwards; the committed pubspec still reads
`variant: unstable`.**

### A6's green, leg by leg

1. **Every failure reported by name with its message — there are none**, on either arm.
2. **Skips explained by variant.** All **6** stable skips are shared-memory cells of `z_pub_shm_cli_test.dart`, and **each one
   passes on the unstable arm** (matched by full test name). ⭐ **No case was skipped on both arms**, so there is nothing to
   list individually.
3. **Carriage versus product:** no case was red, so there is no carriage candidate.
4. **P33 holds** — see below.

### P33 — loaded-library identity

`sha256sum` of `package/native/linux/x86_64/<variant>/*.so` **before and after each run** → equal on both arms;
`native_manifest.py check` before and after each run → **all 16 equal the manifest**, four readings. `native_lib_test.dart` is
in the selected set, and its **library-resolution group passed on both arms** — the loaded variant is the declared one, the
suite is not running off the toolchain-rewritten staging copy, a child process inherits the selection, and the loader prefers
the hook output with no override.

## P35 — what was left out of the certifying run, and why

| left out | why |
|---|---|
| `package/test/interop/` | dev only — the developer's ruling 3 of 2026-09-11. Not carried, and its matrix is a dev-side row (P05) |
| `package/test/dev/` | cells about the dev repository itself; excluded **as a directory**, so a cell added there later needs no list |
| the **8 files** of `development/reference/rc1-test-exclusions-20260912/exclusions.txt` | the failing shared-memory cells, ruled at PR #113's gate. **Verified absent from the assembled tree**, with a control that a required file is present |
| the rest of the carried suite | ⚖️ **the developer's ruling above.** Not an exclusion from the package — those files ship in neither release, since no test file is published — but an exclusion from *this run* |

## P36 — the certified-on statement

**Certified on linux/x86_64**, glibc floor **2.34**, Dart floor **3.13.1** (the SDK the run used, equal to the FVM pin).
**Android is build-, pin- and alignment-validated here and was not suite-run** — no suite has ever run on Android; the three
ABIs `arm64-v8a`, `armeabi-v7a` and `x86_64` ship in both variants, built with NDK **28.2.13676358**, every Android library at
**`0x4000`** LOAD alignment and API level **24**. ⛔ **`armeabi-v7a` ships *caveat emptor — use at your own discretion*, and has
never been loaded on any device**; the only device available is 64-bit only (a permanent caveat, not an open item).

**What ran where, at this release:** the **eight selected files** on linux/x86_64, on **both** variants. **No Android
end-to-end run was made at this release** — the previous release's dated runs stand over libraries proven byte-identical and
code proven unchanged; the Android consumer path is exercised again after publication, against the hosted package.

⏰ **Carried forward, not closed — and named here the way the previous release named it:** `example_readme_coverage_test.dart`
**has still never run alongside the rest of the suite on the stable variant in any tree.** It ran in the targeted set on both
arms here, and in a full unstable suite in dev at this test code. It reads documents; it opens no session and loads no native.
The risk is an interaction between that file and the stable suite: **low, and not zero.** ▶ **It is carried to `1.0.0`'s
certification by ruling, not forgotten.**

⚠️ **Also given up, stated:** a whole-suite run in this repository after this assembly, on either arm. Cells interact across
files and through the machine; for these libraries and this code that interaction was seen in the previous release's full
public runs on both variants — unstable 2,063 · 0 · 9 and stable 1,797 · 0 · 275, both clean — and in CI's full dev runs, not
in this one.
