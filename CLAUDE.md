# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pure Dart FFI package providing bindings for [Zenoh](https://zenoh.io/) (a pub/sub/query protocol) via a C shim layer wrapping zenoh-c v1.7.2. This is the product repo — clean, publishable code. Development happens in the companion `zenoh_dart_dev` repo.

## Repository Structure

```
zenoh_dart/
  package/                      # PUBLISH BOUNDARY — dart pub publish runs here
    lib/                        #   Dart API (36 classes/enums)
    hook/                       #   Dart build hooks (CodeAsset registration)
    native/                     #   Prebuilt shared libraries (linux/x86_64/, android/<abi>/)
    example/                    #   CLI examples (26: z_put, z_sub, z_pub, z_get, z_queryable, z_ping, z_storage, z_advanced_pub, etc.)
    test/                       #   Integration tests (571 tests)
    pubspec.yaml
  src/                          # C shim source (outside publish boundary)
    zenoh_dart.{h,c}            #   156 C shim functions
    CMakeLists.txt
    dart/                       #   Dart API DL headers
  extern/
    zenoh-c/                    # Only submodule — pinned at v1.7.2
  scripts/
    build_zenoh_android.sh      # Android cross-compilation
  CMakeLists.txt                # Root superbuild
  CMakePresets.json             # Platform presets
```

## Build & Development Commands

### Native library build (Linux)

```bash
# Full build: zenoh-c from source + C shim + install to package/native/
git submodule update --init
cmake --preset linux-x64
cmake --build --preset linux-x64 --target install
```

First build takes ~3 minutes (cargo). Subsequent builds are incremental (~2s for C shim changes).

**Rust version constraint:** zenoh-c 1.7.2 requires Rust 1.85.0 — Rust >= 1.86 breaks `static_init`. The preset pins `+1.85.0` via `ZENOHC_CARGO_CHANNEL`. Install with `rustup toolchain install 1.85.0`.

**C shim only** (when zenoh-c is already built):
```bash
cmake --preset linux-x64-shim-only
cmake --build --preset linux-x64-shim-only --target install
```

### Android cross-compilation

```bash
./scripts/build_zenoh_android.sh                  # arm64-v8a + x86_64
./scripts/build_zenoh_android.sh --abi arm64-v8a  # single ABI
```

SHM features are excluded on Android.

### Dart package commands

```bash
# Regenerate FFI bindings after modifying src/zenoh_dart.h
cd package && dart run ffigen --config ffigen.yaml

# Analyze Dart code
cd package && dart analyze

# Run all tests
cd package && dart test

# Run a single test file
cd package && dart test test/session_test.dart

# Run a single test by name
cd package && dart test --name "opens session"
```

### CLI examples

```bash
# Put data on a key expression
cd package && dart run example/z_put.dart -k demo/example/test -p 'Hello from Dart!'

# Delete a key expression
cd package && dart run example/z_delete.dart -k demo/example/test

# Subscribe to a key expression (runs until Ctrl-C)
cd package && dart run example/z_sub.dart -k 'demo/example/**'

# Publish in a loop on a key expression (runs until Ctrl-C)
cd package && dart run example/z_pub.dart -k demo/example/test -p 'Hello from Dart!'

# Publish via shared memory in a loop (runs until Ctrl-C)
cd package && dart run example/z_pub_shm.dart -k demo/example/test -p 'Hello from SHM!'

# Print own session ZID and connected router/peer ZIDs
cd package && dart run example/z_info.dart

# Discover zenoh entities on the network
cd package && dart run example/z_scout.dart

# Send a query and receive replies
cd package && dart run example/z_get.dart -s 'demo/example/**' -t BEST_MATCHING

# Declare a queryable and reply to incoming queries (runs until Ctrl-C)
cd package && dart run example/z_queryable.dart -k demo/example/zenoh-dart-queryable -p 'Reply from Dart!'

# Send a query with an SHM-backed payload
cd package && dart run example/z_get_shm.dart -s 'demo/example/**' -p 'Query from SHM!'

# Declare a queryable and reply with SHM-backed payload (runs until Ctrl-C)
cd package && dart run example/z_queryable_shm.dart -k demo/example/zenoh-dart-queryable -p 'SHM reply from Dart!'

# Declare a pull subscriber; press ENTER to poll buffered samples, 'q' to quit
cd package && dart run example/z_pull.dart -k 'demo/example/**'

# Declare a querier and send periodic queries (runs until Ctrl-C)
cd package && dart run example/z_querier.dart -s 'demo/example/**' -t BEST_MATCHING

# Declare a liveliness token (announces presence, runs until Ctrl-C)
cd package && dart run example/z_liveliness.dart -k group1/zenoh-dart

# Subscribe to liveliness changes (runs until Ctrl-C)
cd package && dart run example/z_sub_liveliness.dart -k 'group1/**' --history

# Query currently alive liveliness tokens
cd package && dart run example/z_get_liveliness.dart -k 'group1/**'

# Start pong responder (echoes ping payload, runs until Ctrl-C)
cd package && dart run example/z_pong.dart

# Measure round-trip latency (requires z_pong running; PAYLOAD_SIZE in bytes)
cd package && dart run example/z_ping.dart 64 -n 100 -w 1000

# Measure round-trip latency with SHM zero-copy (requires z_pong running)
cd package && dart run example/z_ping_shm.dart 64 -n 100 -w 1000

# Tight-loop throughput publisher (heap; requires z_sub_thr in another terminal)
cd package && dart run example/z_pub_thr.dart 8192 --express

# Background subscriber counting throughput rounds (reports msg/s)
cd package && dart run example/z_sub_thr.dart -s 10 -n 100000

# Tight-loop SHM throughput publisher (zero-copy; requires z_sub_thr)
cd package && dart run example/z_pub_shm_thr.dart 8192

# Serialization round-trip demo (no network)
cd package && dart run example/z_bytes.dart

# In-memory storage: subscriber stores PUT/DELETE, queryable replies (runs until Ctrl-C)
cd package && dart run example/z_storage.dart -k 'demo/example/**'

# Advanced publisher with cache and heartbeat (runs until Ctrl-C)
cd package && dart run example/z_advanced_pub.dart -k demo/example/zenoh-dart-advanced-pub -i 10

# Advanced subscriber with history recovery and miss detection (runs until Ctrl-C)
cd package && dart run example/z_advanced_sub.dart -k 'demo/example/**'
```

## Architecture

**Data flow:** Dart API (`package/lib/zenoh.dart`) -> Generated bindings (`package/lib/src/bindings.dart`) -> Native C (`src/zenoh_dart.{h,c}`) -> `libzenohc.so` (resolved by OS linker via DT_NEEDED)

### Key Conventions

- **`zd_` prefix**: All C shim symbols use `zd_` to avoid collisions with zenoh-c's `z_`/`zc_` namespace.
- **Binding generation**: `package/lib/src/bindings.dart` is auto-generated — never edit manually. Regenerate with `dart run ffigen --config ffigen.yaml` after changing `src/zenoh_dart.h`.
- **`DynamicLibrary.open()` loading**: `native_lib.dart::ensureInitialized()` resolves `libzenoh_dart.so` via `Isolate.resolvePackageUriSync()` and loads eagerly. On Android, bare `DynamicLibrary.open('libzenoh_dart.so')` is used. Do NOT use `@Native` annotations — they cause tokio waker vtable crashes in multi-process TCP scenarios.
- **Build hook**: `package/hook/build.dart` registers CodeAsset entries for distribution. The hook is target-aware (Linux/Android).
- **Entity lifecycle**: sizeof -> declare -> loan -> operations -> drop/close. Idempotent close, StateError after close.

### Available Dart API classes

- `Zenoh` — Static utilities: `initLog()`, `scout()`
- `Config` — Session configuration with JSON5 insertion
- `Session` — Open/close sessions; `put`, `putBytes`, `deleteResource`, `declareSubscriber`, `declareBackgroundSubscriber`, `declarePublisher`, `declareAdvancedPublisher`, `declareAdvancedSubscriber`, `get`, `declareQueryable`, `declarePullSubscriber`, `declareQuerier`, `declareLivelinessToken`, `declareLivelinessSubscriber`, `livelinessGet`, `zid`, `routersZid()`, `peersZid()` (`put`/`putBytes`/`get` accept optional `attachment:` + `encoding:`)
- `KeyExpr` — Key expression creation and validation; `intersects()`, `includes()`, `equals()` matching
- `ZBytes` — Binary payload container; `clone()` (shallow ref-counted copy), `toBytes()` (read content as `Uint8List`), `fromInt()`/`toInt()`, `fromDouble()`/`toDouble()`, `fromBool()`/`toBool()`, `slices` (lazy fragment iteration), `isShmBacked` detects SHM backing
- `ZSerializer` — Streaming serializer for multi-value payloads (uint8–int64, float, double, bool, string, bytes, sequence length)
- `ZDeserializer` — Type-safe streaming deserializer with `isDone` state tracking
- `ZBytesWriter` — Raw byte assembler: `writeAll()`, `append()` (consumed), `finish()`
- `LivelinessToken` — Announces entity presence on the network; `keyExpr`, `close()`
- `Publisher` — Declared publisher with `put`/`putBytes`/`deleteResource`/`matchingStatus`/`isExpress` mode
- `AdvancedPublisher` — Publisher with cache, publisher detection, and sample miss detection (requires `timestamping/enabled: true`); `put`/`putBytes` accept optional `attachment:` + `encoding:`
- `AdvancedPublisherOptions` — Cache size, publisher detection, miss detection, heartbeat mode/period
- `HeartbeatMode` — Enum: `none`, `periodic`, `sporadic`
- `Subscriber` — Callback-based subscriber delivering `Stream<Sample>`
- `AdvancedSubscriber` — Subscriber with history recovery, late publisher detection, miss events (`stream`, `missEvents`)
- `AdvancedSubscriberOptions` — History, recovery, miss detection, subscriber detection, miss listener
- `MissEvent` — Missed-sample notification with source `ZenohId` and count
- `PullSubscriber` — Ring-buffer-backed pull subscriber with `tryRecv()` (lossy, drops oldest)
- `Querier` — Declared querier for repeated queries with `get()` -> `Stream<Reply>`, `matchingStatus`, `hasMatchingQueryables()`; `get()` accepts optional `attachment:` + `encoding:`
- `Query` — Received query with `reply()`/`replyBytes()`/`replyErr()`/`replyErrBytes()`/`dispose()`, `keyExpr`, `parameters`, `payloadBytes`, `attachmentBytes`; `reply`/`replyBytes` accept optional `attachment:` (`replyErr` carries payload + encoding only — no attachment, per the zenoh-c contract)
- `Queryable` — Callback-based queryable delivering `Stream<Query>`
- `Reply` — Tagged union: `isOk`, `ok` (Sample), `error` (ReplyError)
- `ReplyError` — Error reply with `payloadBytes`, `payload`, `encoding`
- `QueryTarget` — Enum: `bestMatching`, `all`, `allComplete`
- `ConsolidationMode` — Enum: `auto`, `none`, `monotonic`, `latest`
- `Sample` — Received data with `keyExpr`, `payload` (lenient UTF-8 display; invalid bytes become U+FFFD), `payloadBytes` (exact raw bytes), `kind`, `attachment` (lenient UTF-8 display), `attachmentBytes` (exact raw attachment bytes), `encoding`
- `SampleKind` — Enum: `put`, `delete`
- `Encoding` — MIME type wrapper with predefined constants
- `CongestionControl` — Enum: `block`, `drop`
- `Priority` — 7 priority levels
- `ShmProvider` — POSIX shared memory provider
- `ShmMutBuffer` — Mutable SHM buffer for zero-copy writes
- `ZenohId` — 16-byte session identifier
- `WhatAmI` — Enum: `router`, `peer`, `client`
- `Hello` — Scouting result
- `ZenohException` — Error type

## Linting

Uses `lints` package (configured in `package/analysis_options.yaml`).

## Contributing

### Adding a C shim function

1. Add the function declaration to `src/zenoh_dart.h` and implementation to `src/zenoh_dart.c`
2. Use the `zd_` prefix
3. Rebuild: `cmake --build --preset linux-x64 --target install`
4. Regenerate bindings: `cd package && dart run ffigen --config ffigen.yaml`
5. Add Dart API wrapper in `package/lib/src/`
6. Add tests in `package/test/`
7. Run: `cd package && dart test`
