# S6 — certification, `1.0.0-rc.1`, iteration 4 — targeted by the developer's ruling (a deviation from A2a)

> **Where the cited evidence lives.** Paths under `development/` and `gate1-evidence/` name files in the private development
> repository, `bluecorn/zenoh_dart_dev`, at the commits named beside them; this repository does not carry that tree, by the
> assembly's rules. The counting instrument (`suite_count.py`), the comparison instruments (`compare_cases.py`,
> `compare_tsv.py`), the stage scripts and the earlier iterations' records are committed there on `release-record/1.0.0-rc.1`
> (`iteration-1-public/`, `iteration-2/`, `iteration-3/`, `iteration-4/`).

**Stage:** S6 of `development/release/release-procedure.md` (A2; A6; P30–P36), run by CB on 2026-09-15 in the build clone at
**N = `88a7314bb2e9e1d10642a895773b70944832ae26`**, built from **A = `b96458b`** (dev E = `036c8e1`) — the libraries certified
are the ones committed at N, built in this repository (S4), **byte-identical to iteration 3's N**, which a second clone
reproduced (S5 there; discharged here on that identity, `rebuild-compare.md`).
**Why a fourth iteration:** the newcomer read of iteration 3's documents held `rc.1` on the example cookbook (dev roadmap R55) and
the developer ruled the release notes authored as one entry (R57); the documentation round landed as PR #125, and the pub.dev
README's two sentences as PR #126. **The diff `215c3bb..036c8e1` changed six carried files and one overlay** — the root
`CHANGELOG.md`, the cookbook, the divergences page, `package/README.md`, one test file (`z_pub_shm_cli_test.dart`, one cell
removed) and one new test file (`example_readme_coverage_test.dart`) — **and no library, build input, package code, carriage rule
or exclusion list** (`iteration-4/s1-s3-iteration-4.md`, each by an empty path diff with a control).

## ⚖️ Scope — the developer's ruling R59, recorded as a DEVIATION from A2a

**Ruled 2026-09-15 by the developer (dev roadmap R59), verbatim:** *"I do not want to have CB run the full test run that last 2
hours... we have already done it multiple times and the code has not changed"*, then *"skip both"* — to CA's proposal of a
stable-only full run.

**What ran:** the changed carried test files and every carried test file that reads a changed carried file — **seven files**,
selected by CB's own scan at E (`iteration-4/s6-reader-scan-at-E.txt`; three controls) and identical to the seven the implementer
named in PR #125 — **on both variants, serially, in this repository at N.** **Everything else in the carried suite is discharged BY
RULING.**

⛔ **This is a deviation from A2a, not an amendment to it.** A2a's S6 row and its four discharge conditions are unchanged and bind
the next release. **Under A2a as written, the rest of the suite could not have been discharged in this iteration:** condition (iii)
needs a dev full serial run *on both variants* at a commit whose package paths equal E's — the implementer's full **unstable** run at
`7a86279` exists (2,194 cases · 2,157 passed · 28 failed, all in excluded files · 9 skipped; `development/research/probes-ci-rc1-docs-round-20260915/suite/`),
but **the stable full run was stopped at the developer's word** (PR #125's body) — so (iii) fails and the rule would have required
S6 in full. **The ruling substitutes for the condition; it does not satisfy it, and this record does not pretend that it does.**

**What the ruling rests on, re-read here rather than quoted:** the sixteen libraries are byte-identical across four iterations
(S4's comparison, aggregate `7255a821…`); no library, `lib/`, hook or shim code changed (the S1 record's path diffs); iteration 3
ran the full carried suite in this repository on both variants, clean — unstable **2,063 · 0 · 9**, stable **1,797 · 0 · 275**
(its `certification.md`, preserved at `iteration-3/public/`); and the implementer's full dev unstable run at this exact test code
was clean outside the excluded files.

⚠️ **The residual, stated so it is not discovered later:** on the **stable** variant, the new `example_readme_coverage_test.dart`
**has never run alongside the rest of the suite in any tree** — it ran in the targeted set on stable (in dev at `fd5861d`, and
here) and in the full suite on unstable in dev only (`7a86279`). It reads documents; it opens no session and loads no native. The
risk is an interaction between that file and the stable suite: **low, and not zero.** If a later stable run surfaces something in
that file, R59 is where the decision was made. **Also given up, as A2a's own row states:** a whole-suite run in this repository
after the change — cells interact across files and through the machine, and that interaction is seen only in the dev unstable run.

**Run by a script** (`iteration-4/runners/s6t-run.sh`, iteration 3's with the selection as arguments and a 30 s host sampler) that
asserts HEAD = N, an unmodified `package/pubspec.yaml` and the presence of every selected file before starting, runs every step
below, and does not stop on a red suite. **Nothing else of the release's own ran on the host during the suites:** both Android
end-to-end legs had finished; the emulator was stopped (`adb emu kill`), the fixture's host subscribers and its Gradle and Kotlin
daemons were stopped by pid and verified gone (`android-e2e.md`, finding 1); the Pixel carried no `adb reverse` rule; port 7447
read 0 sockets.

## Pre-flight (P30) and the analyzer (P34)

| # | instrument | reading | verdict |
|---|---|---|---|
| P30 | the import-closure scan of `gate1-evidence/import-closure.md`, verbatim, over `test example lib hook` in `package/`, against `exclusions.txt` at E (unchanged) | **0** hits; `test/interop` and `test/dev` absent; none of the 8 excluded files present | **met** — its positive control fires (*The controls*, below) |
| P30 | `test -e` over every outside path of `gate1-evidence/test-reach/reach.md` Table 1 | **all 11 present**; control `build/does-not-exist` → absent | **met** |
| P30 | the CHANGELOG anchor check: `anchor: '<v>'` literals in carried tests, then the `## <v>` heading in the root `CHANGELOG.md` | 4 call sites, all `0.19.0`; `## 0.19.0` → **1**; control `## 9.9.9` → 0. The authored release section and the restored `0.20.0` entry sit above the anchor; the helper returns the section *closest* to it — the four anchored cells passed in both arms below | **met** |
| P34 | `fvm dart pub get` in `package/`, then `fvm dart analyze package --fatal-infos --fatal-warnings` from the clone's root | exit **0**, *"No issues found!"*, Dart 3.13.1 | **met** — its planted-issue control fires (*The controls*, below) |

## The unstable arm (P31, P33)

**Run:** 06:45:30–06:48:43 UTC; `./scripts/test.sh --reporter expanded --file-reporter json:<file> <the seven files>`, serial
(`--concurrency=1`, the runner's own); the runner printed `ZENOH_DART_VARIANT=unstable (declared in package/pubspec.yaml)` and
`native: …/package/native/linux/x86_64/unstable`. **Exit 0.**

**Counts — test CASES, from the JSON reporter's `testDone` events with `hidden: false`, cross-checked against the expanded
reporter's closing tally** (`suite_count.py`):

| passed | failed | skipped | wall | the two mechanisms |
|---|---|---|---|---|
| **137** | **0** | **0** | 03:07 | **AGREE** — the reporter's closing line: *"All tests passed!"* |

**P33 — loaded-library identity:** `sha256sum` of `package/native/linux/x86_64/unstable/*.so` before and after the run → equal
(`8d3524a0…` shim, `bdc530f4…` core, the manifest's values), and `native_manifest.py check` before and after → all 16 equal the
manifest.

## The stable arm (P32, P33)

**Run:** 06:48:43–06:51:25 UTC, after **the uncommitted flip** — `sed` on `package/pubspec.yaml`'s `variant:` line, the flipped
`hooks:` block captured as `variant: stable`; the runner printed `ZENOH_DART_VARIANT=stable (declared in package/pubspec.yaml)` and
`native: …/package/native/linux/x86_64/stable`. Same command and serial mode. **Exit 0.**

| passed | failed | skipped | wall | the two mechanisms |
|---|---|---|---|---|
| **131** | **0** | **6** | 02:39 | **AGREE** — *"All tests passed!"* |

**P33:** `sha256sum` of `package/native/linux/x86_64/stable/*.so` before and after → equal (`d731890e…` shim, `d54c00f0…` core);
`native_manifest.py check` before and after → all 16 equal the manifest.

**The flip was reverted and never committed (A1-6):** `git checkout -- package/pubspec.yaml`, then
`git diff --exit-code -- package/pubspec.yaml` → exit 0. After S6: HEAD is still N; `git status --porcelain` → only
` M extern/zenoh-c` (the applied pin lockfiles, unchanged since S4); the pubspec declares `variant: unstable`.

## P33's second half — the library-resolution group, run OUTSIDE the ruled selection

P33 names `native_lib_test.dart`'s library-resolution group as its behavioural arm, and that file is not one of the seven. **It is
an identity instrument the gate row names, not suite coverage**, so it ran after the ruled selection, as its own step
(`iteration-4/runners/p33-run.sh`, 06:52:37–06:52:46 UTC, the same flip and revert): the file's **16 cases passed, 0 failed,
0 skipped on each arm** (both mechanisms agree), and **the library-resolution group 4 of 4 on each** — *the loaded variant is the
one package/pubspec.yaml declares* · *the suite is not running off the toolchain-rewritten staging copy* · *a child process
inherits the selection* · *with no override the loader still prefers the hook output*. **Declared:** this adds one file and about
ten seconds beyond the seven the ruling enumerated; it is recorded here as P33's instrument, not as a widening of the selection.

## ⛔ Reds

**None, on either arm.** No case failed. A6 criterion 1 had nothing to apply to. **The three files kept with a recorded
intermittent** — `pull_replies_recv_test.dart`, `received_payload_lifetime_test.dart`, `routed_independence_test.dart` — **are not
in the selection and did not run in this iteration**; their last public reading is iteration 3's full runs, all green on both arms.

## A6 criterion 2 — skips explained by variant

`compare_cases.py` over the two arms' JSON runs, keyed by `suite path :: full name` (calibrated: it agrees with `suite_count.py` on
iteration 3's 2,072 cases; it reproduces iteration 3's 128-case comparison with iteration 2; a planted status flip in a copy of one
arm is reported as exactly one change).

| reading | result |
|---|---|
| case sets | stable **137** = unstable **137**; **0** in either arm only |
| the 6 cases skipped on stable, on the unstable arm | **6 passed** — all six are `z_pub_shm_cli_test.dart` cells (shared memory is absent on the stable native) |
| the cases skipped on unstable | **0** |
| **skipped on both arms** | **none** |

▶ **Met.**

## A6 criterion 3 — carriage versus product

**No red, so nothing is a carriage candidate.** For the record, the same case-level instrument against the earlier readings of
these seven suites:

| comparison | unstable | stable |
|---|---|---|
| **iteration 3's full public run**, restricted to these seven suites (132 cases per arm; `iteration3/logs/s6-*.json`) | **6 cases only here** (the new coverage file's six) · **1 only there** — the removed `z_pub_shm_cli` cell, *the coverage map summary is derived from its own table* · **0 status changes** on the 131 shared cases | the same 6 and 1 · **0 status changes** |
| **the implementer's dev targeted run at `fd5861d`** (`…/suite/targeted-<variant>-cases.tsv`, less the uncarried `test/dev/release_carriage_test.dart`: 137) | **identical** — the same 137 cases, the same statuses | **identical** — 131 passed, 6 skipped, the same six |

So iteration 4's public targeted runs contain iteration 3's readings of these suites unchanged, differ from them exactly by what
the documentation round did to the test corpus, and equal the implementer's dev readings of the merged test code exactly.

## What the certification set leaves out, and why (P35)

**By carriage, as before and unchanged:** `package/test/interop/` (ruling 3 of 2026-09-11), `package/test/dev/` as a directory
(roadmap R8, R13), and the 8 files of `development/reference/rc1-test-exclusions-20260912/exclusions.txt` at E (the ruling at
PR #113's gate) — ⛔ never `measurement-union.txt`, the 48-file census beside it.
**By ruling R59, in this iteration only:** every carried test file outside the seven. **The carried suite at N holds 2,077 cases per
arm** (iteration 3's 2,072, less the removed cell, plus the six new) — **137 ran here; 1,940 are discharged by the ruling**, on the
grounds stated above, and the three kept-intermittent files are among them.

## The host

At launch (06:45:27 UTC) the load averages read 1.61 / 2.88 / 3.52 on 20 cores; the game that had run at about 270% CPU through
S4 and S7 had ended — the top consumer was a browser at 12% (`s6-host-at-launch.txt`). **Sampled every 30 s through both arms**
(`s6-host-samples.tsv`, 12 readings): the one-minute load stayed between **1.22 and 2.23**.

## The benchmark baseline (P08) — named, not built

⚖️ **Ruled 2026-09-14 by the developer (dev roadmap R54), verbatim:** *"we dont even have a baseline test? For me the baseline is
that the examples work"*. **The baseline is the blind review's run of all 28 canon-mirroring examples on `rc.1`'s shipped bytes**
(`development/independent/rc1-blind-20260914/assessment.md`, 2026-09-14, on iteration 2's N — **byte-identical to this N's
libraries**, aggregate `7255a821…` in both manifests): every example ran from a copy of the package as pub delivers it, on the
unstable native, peers paired over a fixed localhost endpoint with multicast scouting off; all worked. **The figures it printed:**
the throughput pair about **138 k msg/s** on the heap path and **109 k and 261 k msg/s** on the shared-memory path at 1024 bytes;
the ping pair **20 round trips completed** at 64 bytes, heap and shared-memory.
⚠️ **Conditions and the caveat:** taken on this build host on a day it also ran a game at about 280% CPU (CB's readings during
iteration 2's stages; the review's record does not sample load) — **an order-of-magnitude floor, not a precision baseline.** At
`1.0.0` the comparison is *do the examples still work, and are the figures in the same ballpark*. ⛔ **No benchmark apparatus is
built before `1.0.0`.**

## The controls, run after both suites

Neither ran during a suite, so neither added load to one. Both are iteration 3's controls, re-run on this tree.

| # | instrument | reading | verdict |
|---|---|---|---|
| P34 | `git archive N package .fvmrc` into a scratch copy; `fvm dart pub get`; a planted `lib/src/zz_planted.dart` (an undocumented public function, a non-final local, a `print`); the same `fvm dart analyze package --fatal-infos --fatal-warnings` | exit **1**, *"3 issues found"* (`public_member_api_docs`, `prefer_final_locals`, `avoid_print`). **Plant removed, same copy:** exit 0, *"No issues found!"* | **the control fires** |
| P30 | the same import-closure `awk`, in `package/`, over a copy of the 8-file list with `test/helpers/canon_zid.dart` appended | the real list: **0** hits · with the plant: **2** — `test/advanced_detect_test.dart:20` and `test/session_test.dart:16`, that helper's two importers | **the control fires** |

## The certified-on statement (P36)

**What ran, where, on N's libraries — and nothing wider is implied.**

- **Linux x86_64 — the seven carried test files that read the changed documents, serially, in this repository, both variants,
  on a quiet host:** unstable **137 passed · 0 failed · 0 skipped**, stable **131 · 0 · 6**; the library-resolution group **4 of 4**
  on each arm. **The rest of the carried suite — 1,940 cases per arm — did not run in this iteration**, by the developer's ruling
  R59; its last public reading is **iteration 3's full serial runs on byte-identical libraries** — unstable **2,063 · 0 · 9**,
  stable **1,797 · 0 · 275** — and the one file that never ran beside the stable suite anywhere is named above. The libraries'
  glibc floor is **2.34** (`objdump -T`, in the manifest); the shims were built with Ubuntu clang 21.1.8 and the cores with
  rustc 1.93.0, on a Linux 7.0.0 / glibc 2.43 host (`package/native/build-environment.txt`).
- **Dart:** the package's floor is **3.13.1**, equal to the Dart of the pinned Flutter 3.47.1 (the assembly's floor-equals-pin check,
  `pin=3.13.1 floor=3.13.1`); the runs above ran on Dart 3.13.1.
- **Android — built for API level 24** on all twelve libraries (`.note.android.ident`), with the pinned **NDK r28c
  (28.2.13676358)**, every library LOAD-aligned **`0x4000`**. **Android is never suite-run.** What runs is one end-to-end exchange
  per ABI and variant: the APK carries N's libraries after the packaging strip, and a message crosses a pinned router in each
  direction (`android-e2e.md`) — **this iteration's own runs, in full, on both devices.**
  - **`x86_64` — the host's emulator**, API 37 with **16 KB pages**: stable and unstable **PASS**, 2026-09-15 06:42:39 and
    06:43:06 UTC.
  - **`arm64-v8a` — a physical device**, the developer's Google Pixel 9a on Android 17 (API 37) with **4 KB pages**: stable and
    unstable **PASS**, 2026-09-15 06:41:05 and 06:41:53 UTC.
  - **`armeabi-v7a` — built, aligned `0x4000`, and never loaded on any device.** Shipped *caveat emptor — use at your own discretion*
    (ruling 11). A permanent caveat on this hardware (R39): the one physical device lists `arm64-v8a` as its only ABI.
- **Interop with canon** is not run in this repository (ruling 3). In dev it certifies the source, not these bytes.

**Not certified on, stated so it is not inferred:** a full-suite run of this N on either variant (iteration 3's N, byte-identical,
has one); any other operating system or CPU architecture; an Android API level other than 37 (the libraries declare 24, and both
end-to-end devices run 37); a 32-bit ARM device of any kind; a build on a second host.
