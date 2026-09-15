# CLAUDE.md

Guidance for AI coding assistants — and for human maintainers — working in this repository.

⛔ **This file carries conventions and rules only: no counts, no class lists, no example lists.** Those are properties of the
code, and the instruments below answer them. A number written here is wrong the next time the code changes.

## What this repository is

`zenoh_dart`: Dart FFI bindings for zenoh-c 1.8.0 through a C shim. `package/` is the published Dart package; the rest of
the repository rebuilds its native libraries and runs its tests. Each release is assembled from the project's development
repository, so a checkout of a release tag is that release exactly.

## Toolchain — pinned, never ambient

- **Every Dart and Flutter command goes through `fvm`** — `fvm dart …`, `fvm flutter …`. `.fvmrc` pins the SDK. A bare
  `dart` may well be on `PATH` and run a different SDK than the one this repository declares; it will not fail loudly.
- **The Dart SDK floor in `package/pubspec.yaml` equals the SDK `.fvmrc` provides.** They are equal so that analysis and
  every test run execute on the floor SDK itself. If the pin moves above the floor, the analyzer resolves SDK library APIs
  against the newer SDK, and a floor violation becomes silent. Move them together, and re-certify when you do. The
  pubspec's comment beside `sdk:` states why the floor is where it is.
- **Rust 1.93.0**, the version zenoh-c 1.8.0 pins. The CMake superbuild and `scripts/build_zenoh_android.sh` both select
  it. Never build with a newer toolchain because it is installed.
- **Android NDK 28.2.13676358.** `scripts/build_zenoh_android.sh` refuses any other, and it reads the NDK's
  `source.properties` rather than the directory name, because a beta NDK's directory name does not say it is a beta.

## Building

```sh
git submodule update --init extern/zenoh-c
cmake --preset linux-x64        && cmake --build --preset linux-x64        --target install   # unstable
cmake --preset linux-x64-stable && cmake --build --preset linux-x64-stable --target install   # stable
./scripts/build_zenoh_android.sh                                                               # Android, both variants
./scripts/check_native_pins.sh --all-shipped
```

- ⚠️ **`--target install` writes only the variant its preset selects.** A change to the C shim therefore needs **both**
  Linux invocations, or one shipped variant keeps the old ABI. When zenoh-c is already built, the `linux-x64-shim-only` and
  `linux-x64-stable-shim-only` presets rebuild the shim alone. ⚠️ **They link a `libzenohc.so` from outside their own build
  tree by absolute path, so the shim they install depends on where the checkout lives.** Release libraries are built with
  the two full presets above, whose installed shims do not.
- **`build-pins/` holds the zenoh core resolution** every shipped `libzenohc.so` must embed. zenoh-c asks for zenoh by
  branch, and a branch moves; the pinned lockfiles are applied before Cargo runs, Cargo runs with `--locked`, and
  `scripts/check_native_pins.sh` asserts the pinned version string on the built library. ⛔ **A missing `build-pins/` fails
  the build on purpose.** To move the core, change the lockfiles and `build-pins/zenoh-core.pin` together, in one commit.
- **The Android entry point is `scripts/build_zenoh_android.sh`**, which builds zenoh-c and the shim per ABI and variant in
  one interleaved loop, and checks 16 KB page alignment before it places a library.

## Testing

- **Run tests only through `./scripts/test.sh`**, full or targeted (`./scripts/test.sh test/session_test.dart`,
  `./scripts/test.sh --name "…"`). It runs serially and loads the native variant `package/pubspec.yaml` declares from
  `package/native/`, a path the Dart toolchain does not rewrite. A bare `fvm dart test` loads from `.dart_tool/lib/`, which
  every child `dart run` rewrites while the test process has it mapped — the result is a SIGBUS, not a test failure.
- **To test the other variant, change `hooks.user_defines.zenoh_dart.variant` locally. Never commit that change.**
- The suite calls the real native libraries through FFI. **Nothing mocks the FFI layer**, and tests belong at the Dart API
  layer: the C shim is exercised through it.
- Several tests read zenoh-c's build-generated headers under `build/`, so the Linux superbuild must have run.

## Architecture

**Dart API** (`package/lib/src/`) → **generated bindings** (`package/lib/src/bindings.dart`) → **C shim**
(`src/zenoh_dart.{h,c}`) → **`libzenohc.so`**, which the OS linker resolves through the shim's `DT_NEEDED` entry.

- **Every C shim symbol carries the `zd_` prefix.** `package/ffigen.yaml` filters on `zd_.*`; a symbol without it never
  reaches the bindings.
- **`bindings.dart` is generated — never edit it.** After changing `src/zenoh_dart.h`, run a full Linux build first, then
  `cd package && fvm dart run ffigen --config ffigen.yaml`: ffigen parses zenoh-c's build-generated headers.
- **The reference for what zenoh-c declares is the build-generated header tree**,
  `build/linux-x64/extern/zenoh-c/release/include/` (the stable build's under `build/linux-x64-stable/`). Not
  `extern/zenoh-c/include/`, which does not carry the generated feature flags of either variant.
- **The native library is loaded eagerly, on the main thread, with `DynamicLibrary.open()`** — not through `@Native`,
  whose lazy load crashed multi-process sessions. The build hook only bundles the libraries.
- **Results from zenoh-c's threads reach Dart through a native port** (`Dart_PostCObject`) into a `ReceivePort`; a blocking
  zenoh-c call is hosted on a thread the shim owns, never on a Dart helper isolate.
- **The public API is `package/lib/zenoh.dart` and `package/lib/zenoh_unstable.dart`.** Their `show` lists are the
  inventory; a class in an exported file is not exported unless a `show` names it.

## Ownership — the rules that are not visible in a signature

- **Every class holding a native handle implements `Finalizable`, so it cannot cross an isolate boundary** — `SendPort.send`,
  `Isolate.spawn` and `Isolate.run` throw `ArgumentError`, and they refuse an ordinary object whose field holds one.
- **The finalizer safety net is not universal.** Some classes carry it and some deliberately do not; each class's dartdoc
  says which and why. Where it is absent, an explicit `close()` or `dispose()` is the only thing that frees the handle.
- **The side that allocates frees**, on every control path, unless a documented move transfers ownership. Dart-side
  allocations come after every check that can throw, and their release sits in a `finally` that encloses everything that
  can throw. A `malloc` whose size a remote peer chose is checked for failure.
- A leak is invisible to a behavioural assertion. Verify one by counting distinct block addresses over many cycles, never by
  asserting that an exception was thrown.

## Instruments — which tool answers which question

| question | instrument | why not the obvious thing |
|---|---|---|
| which `zd_` symbols a variant exports | `nm -D --defined-only package/native/linux/x86_64/<variant>/libzenoh_dart.so \| awk '$3 ~ /^zd_/{n++} END{print n+0}'` — drop `{n++}` to list the names | the header declares symbols behind `#if` guards, so a text scan reads the same for both variants |
| what a shared object needs at load time | `readelf -d <so> \| grep NEEDED`, `ldd <so>` | — |
| an Android library's page alignment | `readelf -lW <so>`, the `LOAD` rows | — |
| count matching lines across the tests | `awk '/pattern/{n++} END{print n+0}'`, or `grep -a … \| wc -l` | some test files carry NUL bytes; without `-a`, grep prints nothing for them and the count comes out low |
| whether the analyzer is clean | `fvm dart analyze package --fatal-infos --fatal-warnings`, exit 0 | — |
| whether formatting is clean | `fvm dart format --output=none --set-exit-if-changed package/lib package/example package/test package/hook` | — |
| what an upload would contain | `fvm dart pub publish --dry-run` in `package/` | pub reads the disk minus ignored files — and the ignore files from the repository root down — not what git tracks |

## Conventions for changes

- Lints: `very_good_analysis`, configured in `package/analysis_options.yaml`; `bindings.dart` is excluded.
- Command-line examples in `package/example/` mirror zenoh-c's examples flag for flag, and take their common flags from
  `package/example/common_args.dart`.
- Merge with merge commits; never squash.
