# zenoh_dart

This repository holds the Dart package [`zenoh_dart`](https://pub.dev/packages/zenoh_dart) — Dart bindings for
[Zenoh](https://zenoh.io/) through FFI to [zenoh-c](https://github.com/eclipse-zenoh/zenoh-c) 1.8.0 — together with
everything needed to rebuild its native libraries from source and to run its test suite.

> **Release candidate for 1.0.0 — the API may still change before 1.0.0. See the [CHANGELOG](CHANGELOG.md).**

**Using the package?** Start at [package/README.md](package/README.md).

## Layout

| path | what |
|---|---|
| `package/` | the Dart package — the publish boundary |
| `package/native/` | the prebuilt native libraries, both variants, every target, with `manifest.json` |
| `src/` | the C shim between Dart and zenoh-c |
| `extern/zenoh-c/` | zenoh-c, as a git submodule |
| `build-pins/` | the pinned zenoh core resolution every build uses |
| `scripts/` | the Android build, the pin checks and the test runner |
| `release/<version>/` | a release's records: the rebuild comparison, the certification, the Android runs, the pre-tag checks — committed after the release's native libraries, so present from its tag on, not in the commits that assemble and build it |

## Requirements

**Dart SDK ≥ 3.13.1 (Flutter ≥ 3.47.1).**

- **Below Dart 3.12.0 the package does not compile:** the library uses private named parameters (in one internal
  constructor), a language feature that arrived in 3.12.0.
- **On Dart 3.11.x, loading the native library aborts** (measured). Dart 3.12.2 is the first SDK measured good at load.
- **Dart 3.13.1 is the SDK the full test suite ran on**, and the floor is set at the version measured good, not at the
  lowest that might work. Dart 3.12.x is not certified, and `pub` will not resolve the package there.

*Maintainers:* the floor equals the SDK that `.fvmrc` pins, and a release checks that they are equal. Move them together,
and re-certify when you do.

To build and test you also need:

| tool | version |
|---|---|
| [FVM](https://fvm.app/) | any — it provides the SDK `.fvmrc` pins; run every Dart command as `fvm dart` |
| clang and clang++ | any recent |
| CMake | 3.21 or newer |
| Ninja | any |
| Rust | 1.93.0 exactly — `rustup toolchain install 1.93.0` |
| Android NDK | 28.2.13676358 exactly, for the Android build, with [cargo-ndk](https://github.com/bbqsrc/cargo-ndk) |

## Rebuilding the native libraries

```sh
git clone https://github.com/bluecorn/zenoh_dart.git
cd zenoh_dart
git submodule update --init extern/zenoh-c

# Linux x86_64: the unstable variant, then the stable one
cmake --preset linux-x64        && cmake --build --preset linux-x64        --target install
cmake --preset linux-x64-stable && cmake --build --preset linux-x64-stable --target install

# Android: arm64-v8a, armeabi-v7a and x86_64, both variants
./scripts/build_zenoh_android.sh

# every library embeds the pinned zenoh core and no path from the machine that built it
./scripts/check_native_pins.sh --all-shipped
```

The first Linux build takes a few minutes, because Cargo builds zenoh-c. The Android script looks for NDK 28.2.13676358
under `~/Android/Sdk/ndk/` unless `ANDROID_NDK_HOME` points at it, and refuses any other NDK. Every build applies
`build-pins/` and builds zenoh-c with `--locked`, so it cannot quietly resolve a different zenoh core.

The builds install into `package/native/`, over the committed libraries, so `git status package/native` lists every library
you built that differs from the one shipped; `package/native/manifest.json` has each shipped library's sha256. Each release
records its own rebuild-and-compare under `release/<version>/`, identical or not.

## Running the tests

```sh
./scripts/test.sh                            # the full suite, serially
./scripts/test.sh test/session_test.dart     # one file
```

The suite needs the Linux build above: several tests read zenoh-c's build-generated headers under `build/`. Run it only
through `scripts/test.sh`, which loads the native variant `package/pubspec.yaml` declares (`unstable`) from a path the Dart
toolchain does not rewrite during the run. To test the `stable` variant, change that declaration locally — and do not
commit the change. A full serial run takes over an hour.

## Platforms, and how each was validated

| target | minimum | validated by |
|---|---|---|
| Linux x86_64 | glibc 2.34 | the full test suite, on both variants |
| Android `arm64-v8a` | API 24 | built, 16 KB page-aligned, and run end to end on a physical device |
| Android `x86_64` | API 24 | built, 16 KB page-aligned, and run end to end on an emulator |
| Android `armeabi-v7a` | API 24 | built and 16 KB page-aligned — **never loaded on any device.** *Caveat emptor — use at your own discretion.* |

The test suite does not run on Android. Shared memory is not available on Android in either variant.

## Security

**A session opened with the default configuration is open to your network.** `Session.open()` with no `Config` listens for
TCP connections on every network interface, joins UDP multicast scouting, and accepts peers **without authentication or
encryption**. These are zenoh-c's defaults, and the package passes them through unchanged. Turning multicast scouting off
does not remove the TCP listener. On a network you do not fully trust, set the listen endpoints, authentication and TLS in a
`Config` before opening a session.

### Known issue

**Linux: the native library is looked up in the current working directory.** When the package's own directory holds no copy
of the library — which is the case when the package comes from the pub cache, and in executables built with `dart build cli` —
the loader looks for `.dart_tool/lib/libzenoh_dart.so` relative to the process's **working directory**, and only then asks
the system loader for `libzenoh_dart.so` by name. So:

- **A process started in a directory that someone else can write to can load a library placed there and run its code**, even
  with `LD_LIBRARY_PATH` set, because the working directory is searched first.
- **A process started in a directory without that file fails** with `Could not find libzenoh_dart.so`. `dart run` works from
  the project directory, where the build hook places the library. An executable built with `dart build cli` does not look in
  its own bundle: run it with `LD_LIBRARY_PATH` set to the bundle's `lib/` directory.

Until this is fixed, start these processes only from a directory you control. `dart compile exe` refuses packages with build
hooks, so it cannot build an executable from this package. **This issue blocks 1.0.0.**

## How this repository changes

Each release is assembled from the project's development repository. Please report problems through
[issues](https://github.com/bluecorn/zenoh_dart/issues).

## License

Apache-2.0 — see [LICENSE](LICENSE).
