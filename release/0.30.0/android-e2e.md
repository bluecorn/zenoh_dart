# S7 — Android end-to-end, `0.30.0` — ⚖️ NOT RE-RUN, a recorded deviation

**Stage:** S7 of `development/release/release-procedure.md` (A2; P36–P38). ⛔ **No Android end-to-end run was made at this
release.** Ruled by CB at gate 1 and confirmed by the developer on 2026-09-16 with the scope ruling. This record states what
the deviation rests on, what it gives up, and where the behavioural arm moved to — **so that "not run" is a decision with
evidence, not an absence.**

**Object it would have run over:** **N = `fd73f75dd7aca25e50efc54c88c8c1d13f789fc6`**.

## Why not

A full S7 needs the developer's physical device and their time. This release changes **no library byte and no code the APK or
the host side runs.** Both halves were measured, not assumed:

| what | instrument | reading |
|---|---|---|
| the sixteen libraries | S4's identity gate: `native_manifest.py check` against `1.0.0-rc.1`'s shipped manifest, plus the two aggregates | **16 of 16 equal**; aggregates equal (`7255a821…`) |
| everything the APK and the host side consume | `git diff --quiet` over `E → E′` for `package/lib`, `package/hook`, `package/example`, **the two programs the fixture runs** (`example/z_sub.dart`, `example/z_put.dart`), the fixture `development/release/fixtures/android-e2e/`, and `.fvmrc` | **every one unchanged** |
| the pubspec | `git diff --numstat` | **1 insertion, 1 deletion — the `version:` line**, a string nothing the APK or the host side executes ever reads |
| the control | the same test over `package/pubspec.yaml` | **reports it changed**, so the instrument can see a difference |

**The previous release's dated runs therefore stand**, over byte-identical libraries and unchanged code:
`arm64-v8a` on the developer's Pixel 9 and `x86_64` on the host's emulator image (API 37, 16 KB pages), both variants, both
**PASS**, 2026-09-15 — recorded at `release/1.0.0-rc.1/android-e2e.md` in this repository, which this branch preserves.

⚠️ **A note on the rule's wording, carried to S12.** A2a's S7 row names `package/example/` and `package/pubspec.yaml` as whole
paths where it means *what the fixture and the APK consume*. The previous release hit the same class — it ran S7 in full
because the example **cookbook** had changed — and homed the correction to S12. The amendment is written at
`development/release/0.30.0/gate1-evidence/per-stage-ruling.md` §4.2 in the development repository. ⛔ **It is not this
release's authority for anything:** A2a governs fix iterations within a release, and this deviation stands on the readings
above.

## Where the behavioural arm moved to

**P55, after publication:** a default-target Android APK built against the **hosted `0.30.0`** package, with the loaded
library's sha256 checked against the manifest. That exercises the Android consumer path against what pub.dev actually serves,
which is a stronger object than this branch. **The on-device run of the previous release's shape is offered if the developer
makes the Pixel available; it is not required by this record.**

## What it gives up, named

**Nothing is loaded on a physical device or an emulator before this version is published.** For `armeabi-v7a` that was already
permanently true and remains so (P38: the only device is 64-bit only and cannot load a 32-bit library — a permanent caveat, not
an open item). **For `arm64-v8a` and `x86_64` it is true for this release only**, on bytes that were run on both at the
previous release.

## P36 and P38 are unchanged

The certified-on statement is in `certification.md`. `armeabi-v7a` ships **built, aligned at `0x4000`, and never loaded on any
device**, labelled *caveat emptor — use at your own discretion*.
