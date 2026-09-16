# zenoh_dart

Dart bindings for [Zenoh](https://zenoh.io/) — the pub/sub/query protocol for distributed systems — through FFI to
[zenoh-c](https://github.com/eclipse-zenoh/zenoh-c) 1.8.0, for Dart programs and Flutter apps on Linux and Android.

> **Release candidate for 1.0.0 — the API may still change before 1.0.0. See the [CHANGELOG](CHANGELOG.md).**

The native libraries ship inside the package for every supported target, and the package's build hook bundles them into
your application. There is nothing to compile.

## Requirements

**Dart SDK ≥ 3.13.1 (Flutter ≥ 3.47.1).**

- **Below Dart 3.12.0 the package does not compile:** the library uses private named parameters (in one internal
  constructor), a language feature that arrived in 3.12.0.
- **On Dart 3.11.x, loading the native library aborts** (measured). Dart 3.12.2 is the first SDK measured good at load.
- **Dart 3.13.1 is the SDK the full test suite ran on**, and the floor is set at the version measured good, not at the
  lowest that might work. Dart 3.12.x is not certified, and `pub` will not resolve the package there.

## Install

```sh
dart pub add zenoh_dart
```

0.30.0 is a mirror of the release candidate 1.0.0-rc.1 and is provided as a convenience for usage and as a record of the
current state of the zenoh_dart project. It carries the same code and the same native libraries, built from the same source —
the two releases differ only in their version number, so **do not depend on both in one project**. Every release candidate
until 1.0.0 is mirrored the same way.

pub never makes a prerelease the latest version, which is why the candidate itself is not what a bare `pub add` resolves. To
pin it instead:

```sh
dart pub add 'zenoh_dart:^1.0.0-rc.1'
```

## Quick start

```dart
import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final session = await Session.open();

  final subscriber = session.declareSubscriber('demo/example/**');
  final received = subscriber.stream.first;

  session.put('demo/example/hello', 'Hello from Dart!');

  final sample = await received;
  print('${sample.keyExpr}: ${sample.payload}');

  subscriber.close();
  session.close();
}
```

This opens a session with the default configuration. **Read [Security](#security) before you run it on a network you do not
control.**

## Two native variants — `stable` and `unstable`

Every release ships two builds of the native libraries, and your application chooses one.

| variant | what it carries |
|---|---|
| `stable` — **the default** | zenoh-c's stable API |
| `unstable` | zenoh-c's stable API **and** its unstable API, plus shared memory on Linux |

The name is the caveat: the unstable API works as documented, and zenoh-c may change it in a later release. To select it,
set it in **your application's** `pubspec.yaml` — the root package; a dependency cannot set it:

```yaml
hooks:
  user_defines:
    zenoh_dart:
      variant: unstable
```

Then import `package:zenoh_dart/zenoh_unstable.dart`, which is the stable API plus the unstable one. Calling an unstable
entry point while the `stable` native is loaded throws an `UnsupportedError` that names the setting above, and
`ZenohFeatures.hasUnstableApi` and `ZenohFeatures.hasSharedMemory` report what the loaded native carries.

A **path dependency** on a checkout of this repository is the one exception: the loader probes the package directory's own
`.dart_tool/lib/` before your application's, so it loads whatever that checkout last staged there, whichever variant your
`pubspec.yaml` asks for. Remove that directory, or do not run programs inside the checkout's `package/`.

## Platforms, and how each was validated

| target | minimum | validated by |
|---|---|---|
| Linux x86_64 | glibc 2.34 | the full test suite, on both variants |
| Android `arm64-v8a` | API 24 | built, 16 KB page-aligned, and run end to end on a physical device |
| Android `x86_64` | API 24 | built, 16 KB page-aligned, and run end to end on an emulator |
| Android `armeabi-v7a` | API 24 | built and 16 KB page-aligned — **never loaded on any device.** *Caveat emptor — use at your own discretion.* |

The Android libraries are built with NDK 28.2.13676358. The test suite does not run on Android. Shared memory is not
available on Android in either variant. No other platform is supported.

## Security

**A session opened with the default configuration is open to your network.** `Session.open()` with no `Config` listens for
TCP connections on every network interface, joins UDP multicast scouting, and accepts peers **without authentication or
encryption**. These are zenoh-c's defaults, and this package passes them through unchanged. Turning multicast scouting off
does not remove the TCP listener. On a network you do not fully trust, set the listen endpoints, authentication and TLS in a
`Config` before opening a session, as zenoh's configuration documentation describes.

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

## Parity with zenoh-c

The package binds canon zenoh-c 1.8.0. Where it deliberately does not bind a zenoh-c symbol, or binds one differently, the
reason is recorded in [doc/canon-divergences.md](doc/canon-divergences.md).

## Examples

[`example/`](example/) holds command-line programs that mirror zenoh-c's own examples, flag for flag: publish, subscribe,
query, liveliness, shared memory, benchmarks and more. [example/README.md](example/README.md) documents each one and
states where an example's flags depart from zenoh-c's. From a checkout of the repository:

```sh
cd package
dart run example/z_sub.dart -k 'demo/example/**'                # in one terminal
dart run example/z_put.dart -k demo/example/test -p 'Hello!'    # in another
```

> **`z_pub_shm_thr` needs a raised locked-memory limit at its default pool size.** Its `-s` default of **32 MB** mirrors
> zenoh-c's example — parity, not a tuning choice. Many Linux systems cap `ulimit -l` at 8 MB, and the example then stops
> with `Unable to create POSIX shm segment: OS error 12`. Pass a smaller pool (`-s 1`), or raise the limit — the *hard* limit
> is usually 8 MB too, so raising it needs root, through `/etc/security/limits.conf` or a systemd `LimitMEMLOCK=` override,
> not only `ulimit -l` in your shell.

## The native libraries

[`native/`](native/) holds the prebuilt libraries for every target and both variants. They are built in the
[repository](https://github.com/bluecorn/zenoh_dart) from the release's source, and `native/manifest.json` records for each
library its sha256, the `zd_` symbols it exports, the zenoh version it embeds, its compiler and its build environment. The
repository's README explains how to rebuild them and compare.

## License

Apache-2.0 — see [LICENSE](LICENSE). The bundled zenoh-c library (`libzenohc.so`) is zenoh-c's own build, and zenoh-c is
licensed under the Eclipse Public License 2.0 or the Apache License 2.0.
