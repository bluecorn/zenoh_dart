# Changelog

## 0.30.0 — 2026-09-16

**A mirror of the release candidate `1.0.0-rc.1`** — the same code and the same sixteen native libraries, built from the same
source, published under a `0.x` version so that a bare `dart pub add zenoh_dart` resolves to the current state of the package.
pub never makes a prerelease the latest version, so without this a bare add still takes `0.20.0`, which is the 1.7.2-era API.
Every release candidate until `1.0.0` is mirrored the same way.

**The API may still change before 1.0.0.**

⚠️ **The two releases differ only in their version number, so do not depend on both in one project.**

**What is in it** is what `1.0.0-rc.1` announced: see the `1.0.0-rc.1` section below for the breaking changes, the additions
and the fixes. Nothing is added or removed here.

The native libraries are byte-identical to the ones `1.0.0-rc.1` ships — both releases' `native/manifest.json` carry the same
`aggregate_sha256`, and so do the two release tags.

### Known issues

- **Linux: the native library is looked up in the current working directory.** When the package's own
  directory holds no copy of the library — which is the case when the package comes from the pub cache,
  and in executables built with `dart build cli` — the loader looks for `.dart_tool/lib/libzenoh_dart.so`
  relative to the process's **working directory**, and only then asks the system loader for
  `libzenoh_dart.so` by name. So:
  - **A process started in a directory that someone else can write to can load a library placed there and
    run its code**, even with `LD_LIBRARY_PATH` set, because the working directory is searched first.
  - **A process started in a directory without that file fails** with `Could not find libzenoh_dart.so`.
    `dart run` works from the project directory, where the build hook places the library. An executable
    built with `dart build cli` does not look in its own bundle: run it with `LD_LIBRARY_PATH` set to the
    bundle's `lib/` directory.

  Until this is fixed, start these processes only from a directory you control. `dart compile exe` refuses
  packages with build hooks, so it cannot build an executable from this package. **This issue blocks
  1.0.0.**

## 1.0.0-rc.1 — 2026-09-13

Release candidate for 1.0.0 — the API may still change before 1.0.0.

### Known issues

- **Linux: the native library is looked up in the current working directory.** When the package's own
  directory holds no copy of the library — which is the case when the package comes from the pub cache,
  and in executables built with `dart build cli` — the loader looks for `.dart_tool/lib/libzenoh_dart.so`
  relative to the process's **working directory**, and only then asks the system loader for
  `libzenoh_dart.so` by name. So:
  - **A process started in a directory that someone else can write to can load a library placed there and
    run its code**, even with `LD_LIBRARY_PATH` set, because the working directory is searched first.
  - **A process started in a directory without that file fails** with `Could not find libzenoh_dart.so`.
    `dart run` works from the project directory, where the build hook places the library. An executable
    built with `dart build cli` does not look in its own bundle: run it with `LD_LIBRARY_PATH` set to the
    bundle's `lib/` directory.

  Until this is fixed, start these processes only from a directory you control. `dart compile exe` refuses
  packages with build hooks, so it cannot build an executable from this package. **This issue blocks
  1.0.0.**

### Breaking

- **Five shim exports are removed from `libzenoh_dart.so`**, on every target and both variants — `zd_bytes_to_string`, `zd_bytes_copy_from_str`, `zd_config_loan`, `zd_query_keyexpr` and `zd_whatami_to_view_string`; no Dart surface changes, and a non-Dart embedder linking the library calls canon's own `z_*` function instead.
- **The shim export `zd_query_parameters` is removed**; it has no Dart surface.
- **`completeOpenFromPost`, `openFailureMessage` and `openStartFailureMessage` are no longer exported** from `package:zenoh_dart` — a failed open's message is on the `ZenohException` that `Session.open` throws.
- **`QueryChannel`, `keyExprString` and `withLoanedKeyExpr` are no longer exported** — internal plumbing that was public by accident.
- **`Session.open` returns `Future<Session>` and no longer blocks the calling isolate** — `await` it.
- **`CongestionControl.blockFirst` is now REFUSED on a native built without `Z_FEATURE_UNSTABLE_API`** — an `ArgumentError` at all seven send entry points that take a congestion control, where it was undefined behaviour; pass `CongestionControl.block` or `CongestionControl.drop`, or select the `unstable` variant in the app's `pubspec.yaml` under `hooks: user_defines: zenoh_dart: variant`.
- **`Session.putBytes` on a CLOSED session carrying `blockFirst` throws `ArgumentError`, not `StateError`** — the refusal comes before the session-closed check.
- **Every class that holds a native handle is refused by `SendPort.send`, `Isolate.spawn` and `Isolate.run`** — send a handle-free description and re-open on the other side.
- **`PullSubscriber.tryRecv()` returns `RecvResult<Sample>` instead of `Sample?`** — `RecvData`, `RecvEmpty` or `RecvDisconnected`, switched over exhaustively.
- **`ZBytes` conversions report trailing data as code `12` instead of `-1`**, and a short payload as `-7` (`Z_EDESERIALIZE`).
- **`ShmProvider.alloc()` and `allocGcDefragBlocking()` return a sealed `AllocResult` instead of `ShmMutBuffer?`** — `AllocOk`, `AllocError` or `LayoutError`.
- **`ShmMutBuffer.data` is removed** — copy in with `ShmMutBuffer.write` and out with `ShmMutBuffer.read`.
- **`ShmProvider.available` is removed** — it read 0 at every point of a provider's life.
- **`ZenohException.enriched` takes a third, required argument, the upstream `detail` (`String?`)**, and the shim reader `zd_last_error_message` is removed.
- **`AdvancedPublisherOptions.cacheMaxSamples` is replaced by `cache: AdvancedPublisherCacheOptions(maxSamples: …)`** — `0` never meant unlimited, and a negative bound throws `ArgumentError`.
- **`ZenohId.toHexString()` and `toString()` render canon's form** — the bytes in reverse order as minimal hex, `"0"` for the all-zero id — and `Timestamp`, `Hello` and `EntityGlobalId` inherit it; `ZenohId.bytes` keeps its storage order.
- **`ZenohId` and `Timestamp.fromRaw` throw `ArgumentError` on a wrong-length image**, in release builds too.
- **`ZenohId.bytes` is unmodifiable** — a write throws `UnsupportedError`.
- **`Session.routersZid()` and `peersZid()` throw `ZenohException` when the enumeration fails**, instead of returning an empty list.
- **`serializeUint8/16/32` and `serializeInt8/16/32` throw `ArgumentError` on a value outside their width** instead of wrapping it.
- **`Encoding` equality includes the schema** — `Encoding('text/plain')` and `Encoding('text/plain').withSchema('')` are unequal, and `toString()` renders a schema set by `withSchema` in place of an existing one, as canon does.
- **A `timeout` that marshals to 0 ms is refused with `ArgumentError`** on `Session.get` and `Session.declareQuerier`, where zenoh read it as the configured default.
- **`Session.declarePullSubscriber` refuses a negative `capacity` with `ArgumentError`.**
- **The Dart SDK floor is `^3.13.1`** (was `^3.12.2`) — a Flutter app needs Flutter 3.47.1 or newer.

### Added

- **`ChannelKind` (`ring`, `fifo`) on `Session.declarePullSubscriber`** — `fifo` is bounded and loses nothing.
- **Bounded channel forms of every query and reply surface** — `Session.pullGet`, `Querier.pullGet` and `Session.pullLivelinessGet` return `PullReplies`, and `Session.declarePullQueryable` returns `PullQueryable`.
- **`Session.declarePullLivelinessSubscriber`** — liveliness transitions on a bounded channel.
- **`recv()` on the pull handles** — an awaited receive that completes with a value or `RecvDisconnected`, and never parks a thread.
- **`PullSubscriber.stream` and `PullQueryable.stream`** — a bounded `Stream` that pulls only while its listener is demanding.
- **`PullSubscriber.kind` and `Subscriber.keyExpr`.**
- **`Sample.payloadZBytes`, `Reply.ok.payloadZBytes` and `Query.payloadZBytes`** — a received payload as an owned `ZBytes`, opted into with `retainPayload: true` on samples and replies; `ZBytes.isShmBacked`, from `zenoh_unstable.dart`, reports what backs it.
- **`Encoding.withSchema` and `Encoding.schema`**, and the byte views `Sample.encodingBytes`, `Query.encodingBytes` and `ReplyError.encodingBytes`.
- **All 53 of canon's predefined encodings.**
- **Single-shot `ZBytes` conversions for every scalar width** — `fromUint8/16/32/64`, `fromInt8/16/32` and `fromFloat`, with their readers.
- **`KeyExpr.isCanon`, `KeyExpr.canonize` and `KeyExpr.autocanonize`.**
- **`Session.declareKeyExpr` and `Session.undeclareKeyExpr`.**
- **`KeyExpr.clone()`, `KeyExpr.concat` and `KeyExpr.join`.**
- **`AdvancedPublisher.hasMatchingSubscribers()` and `matchingStatus`; `AdvancedSubscriber.detectedPublishers` (with `DetectPublishersOptions`) and `AdvancedSubscriber.keyExpr`.**
- **`ShmProvider.allocGcDefragAsync`** — shared-memory allocation that does not block the isolate, one in flight per provider.
- **`ShmProvider.allocGc`, `allocGcDefrag` and `allocGcDefragDealloc`, each with an optional `AllocAlignment`, and `ShmProvider.defragment()` and `garbageCollect()`.**
- **`Zenoh.initLogWithSink(minSeverity:)`** — zenoh's own log records as a `Stream<LogRecord>`, which can carry configuration material.
- **`ZenohException.codeNames`** — canon's names for a return code, which `toString()` renders beside the number.
- **`Zenoh.resolvedLibraryPath`** — which `libzenoh_dart.so` loaded, readable without initialising anything.
- **The examples `z_non_blocking_get` and `z_queryable_with_channels`.**

### Changed

- **Every key-expression parameter accepts a `String` or a `KeyExpr`**, and a wrong-typed argument throws `ArgumentError`; `KeyExpr.intersects`, `includes` and `equals` take view, owned and declared operands alike.
- **The C shim's key-expression operations take a loaned key expression instead of a string** — a native ABI change with no Dart signature change.
- **`Queryable.close()` drops the queries no listener received**, so their getters are finalised at the close instead of waiting out their timeout.
- **Every unbounded push surface's dartdoc names its bounded alternative**, or why it has none.

### Fixed

- **A received payload or attachment that cannot be converted arrives as a stream error carrying canon's code**, not as an empty value — pass `onError`.
- **`PullSubscriber.close()` and `PullQueryable.close()` no longer hang on a full fifo channel** — close pull handles before their session.
- **Key expressions, query parameters and encodings with an interior NUL arrive whole**, in both directions.
- **`KeyExpr.clone()` of a key expression built from a string no longer aliases its source.**
- **A zero-length encoding reads the same on the pull path as on the callback path.**
- **Router and peer enumeration no longer drops ids beyond 1024.**
- **Native memory leaks are closed** — every consumed `ZBytes` and `Config`, the config `Session.open()` creates for itself, every received query, an abandoned `ZBytes.slices` iteration, and seven operations that threw between an allocation and its release.
- **`Session.get()` no longer leaves its reply channel open when it throws.**
- **Native allocations sized by a remote peer are checked**, so a failed allocation drops the message instead of crashing.
- **`ZDeserializer` refuses to read after its source `ZBytes` is disposed or consumed.**
- **`ShmMutBuffer.toBytes()` marks the buffer consumed on every return code.**
- **The synchronous byte extractors carry full-width lengths**, so a payload of 2 GiB or more reports its length correctly.
- **Shared-memory provider creation reports canon's reason for a rejection.**
- **Both library-load failures carry their cause**, and `ZENOH_DART_VARIANT` is validated rather than silently ignored.
- **Four dartdoc claims are corrected** — `ZDeserializer.deserializeString` throws on invalid UTF-8 rather than substituting U+FFFD; `allocGcDefragDealloc` can leave an evicted buffer sharing bytes with its evictor; draining is not a precondition of closing a pull handle; and a dropped ring-channel query's getter is finalised at once rather than timing out.
- **The CLI examples match canon's argument handling** — repeatable values are not split at commas, `--no-*` aliases are rejected, and a failed open prints `Unable to open session!`.

### Build and packaging

- **The zenoh core resolution is committed (`release/1.8.0#29b3e63a`) and built `--locked`**, and every shipped `libzenohc.so` is checked for it.
- **No shipped library embeds the machine it was built on.**
- **The Linux shims built by the `linux-x64` and `linux-x64-stable` presets no longer depend on the directory they were built in.**
- **Android builds are pinned to NDK `28.2.13676358`**, and one invocation builds the three shipped ABIs.
- **The `armeabi-v7a` core is linked at 16 KB page alignment**, like its shim.
- **`package/.pubignore` keeps `test/`, `dart_test.yaml` and `ffigen.yaml` out of the published archive.**
- **`LICENSE` is the canonical Apache-2.0 text again.**

## 0.20.0 — First release under this name

- **Renamed the package from `zenoh` to `zenoh_dart`.** All imports move from
  `package:zenoh/...` to `package:zenoh_dart/...`. This is a breaking change.
- **Fixed: the build hook no longer registers assets inside the package root.** It now
  stages each prebuilt into the hook's output directory and registers the copy. The
  previous behaviour pointed the build system at files in the pub cache, which it could
  then delete as stale outputs — corrupting the cached package for every project on the
  machine. See flutter/flutter#186305 for the contract.
- **Raised the Dart SDK floor to `^3.12.2`.** On 3.11.x the VM eagerly `dlopen`s the
  registered code asset, which reintroduces a tokio-waker crash in multi-process
  scenarios. 3.12.2 is the lowest measured-good floor.
- Documented the supported-target matrix and the Android feature reduction.
- **Added the `armeabi-v7a` Android prebuilt.** `flutter build apk` targets `android-arm` by
  default, so a stock APK build previously failed in the build hook. All three of Flutter's default
  Android ABIs now ship.
- Documented how the native libraries are built, what the package does and does not contain, and how
  to verify the shipped binaries.

## 0.19.0

Binary I/O fidelity for payload **and** attachment across every send/receive pair.

### Added
- `Sample.attachmentBytes` (`Uint8List?`) and `Query.attachmentBytes` (`Uint8List?`) —
  exact attachment bytes on all receive surfaces, alongside the lenient `attachment` String.
- Attachment + encoding send options on `Session.put`/`putBytes`, `Session.get`,
  `Querier.get`, `Query.reply`/`replyBytes`, and `AdvancedPublisher.put`/`putBytes`.
- `Query.replyErr`/`replyErrBytes` — send an error reply (payload + encoding),
  making `ReplyError.payloadBytes` round-trip end-to-end.

### Fixed
- Arbitrary binary (non-UTF-8) payloads and attachments now round-trip byte-exact on
  every transport pair (attachments were previously corrupted to U+FFFD on receive).
- Use-after-move: `Session.get`, `Querier.get`, and `Query.replyBytes` mark consumed
  `ZBytes` unconditionally (zenoh-c consumes the move regardless of return code).
- Present-but-empty is now distinguishable from absent for query payloads and
  pull-subscriber attachments.
- Hardened native byte-reader and `z_encoding_from_str` return-code handling.

## 0.18.1

### Fixed
- **Binary payload corruption on every receive surface** — invalid-UTF-8
  payloads (protobuf, flatbuffers, raw binary) were silently corrupted in
  transit to Dart: samples and replies arrived with `payloadBytes` emptied,
  and query payloads arrived nulled. Affected all receive paths: subscriber,
  background subscriber, liveliness subscriber, advanced subscriber,
  `Session.get` replies, `Querier.get` replies, queryable
  `Query.payloadBytes`, and `PullSubscriber.tryRecv()`. Root cause: the C
  shim flattened payloads through `z_bytes_to_string`, which at zenoh-c
  1.7.2 produces a gravestone (empty) string on invalid UTF-8. Callbacks
  now extract bytes via `z_bytes_to_slice` (byte-faithful; flattens
  fragmented payloads); sync extractors use the `z_bytes_reader` pattern
- Binary attachments no longer corrupt: the carrying sample's
  `payloadBytes` stays byte-exact and `attachment` arrives as a lossy
  display string instead of being emptied
- Empty-payload owned-string leak in the query callback eliminated by
  construction; latent memcpy-from-gravestone UB in `zd_query_payload`
  removed (reader pattern)
- CLI test portability: 22 process-spawning test files hardcoded a stale
  absolute dart interpreter path; replaced with `Platform.resolvedExecutable`

### Changed
- `payload` and `attachment` display strings now decode leniently
  (`utf8.decode(..., allowMalformed: true)`) at all 10 Dart decode sites:
  invalid UTF-8 renders as U+FFFD replacement characters instead of
  throwing — the analog of zenoh-cpp's non-validating `as_string()`.
  `payloadBytes` remains the exact ground truth; valid-UTF-8 behavior is
  byte-identical

### Added
- 13 new integration tests covering binary payload delivery on every
  receive surface, binary attachments, multi-fragment payloads, and
  empty-payload edge cases (512 → 525 total)
- No new public API, no exported C signature changes (155 shim functions
  unchanged, no ffigen regeneration)

## 0.18.0

### Added
- `AdvancedPublisher` class — advanced publisher with cache, publisher
  detection, and sample miss detection; `put()`, `putBytes()`,
  `deleteResource()`, `keyExpr`, and `close()`
- `AdvancedPublisherOptions` class — configuration for cache size
  (`cacheMaxSamples`), `publisherDetection`, `sampleMissDetection`,
  `heartbeatMode`, and `heartbeatPeriodMs`
- `HeartbeatMode` enum — `none`, `periodic`, `sporadic` heartbeat
  modes for sample miss detection signalling
- `AdvancedSubscriber` class — advanced subscriber with history
  recovery, late publisher detection, miss events, and sample miss
  detection; `stream`, `missEvents`, `keyExpr`, and `close()`
- `AdvancedSubscriberOptions` class — configuration for `history`,
  `detectLatePublishers`, `recovery`, `lastSampleMissDetection`,
  `periodicQueriesPeriodMs`, `subscriberDetection`, and
  `enableMissListener`
- `MissEvent` class — miss event with `sourceId` (`ZenohId`) and
  `count` fields delivered via `AdvancedSubscriber.missEvents` stream
- `Session.declareAdvancedPublisher()` — declare an advanced publisher
  with optional `AdvancedPublisherOptions`
- `Session.declareAdvancedSubscriber()` — declare an advanced subscriber
  with optional `AdvancedSubscriberOptions`
- CLI example: `z_advanced_pub.dart` — advanced publisher with cache,
  publisher detection, and heartbeat; `-k`, `-p`, `-i`, `-e`, `-l` flags
- CLI example: `z_advanced_sub.dart` — advanced subscriber with history
  recovery, miss detection; `-k`, `-e`, `-l` flags
- 11 new C shim functions (144 → 155 total): `zd_advanced_publisher_sizeof`,
  `zd_declare_advanced_publisher`, `zd_advanced_publisher_put`,
  `zd_advanced_publisher_delete`, `zd_advanced_publisher_loan`,
  `zd_advanced_publisher_drop`, `zd_advanced_subscriber_sizeof`,
  `zd_declare_advanced_subscriber`,
  `zd_advanced_subscriber_declare_background_sample_miss_listener`,
  `zd_advanced_subscriber_loan`, `zd_advanced_subscriber_drop`
  (all guarded by `#if defined(Z_FEATURE_UNSTABLE_API)`)
- ~38 new integration tests (473 → ~511 total)

## 0.17.0

### Added
- `KeyExpr.intersects(other)` — returns true if this key expression intersects with another
- `KeyExpr.includes(other)` — returns true if this key expression includes (is a superset of) another
- `KeyExpr.equals(other)` — returns true if two key expressions are semantically equal
- CLI example: `z_storage.dart` — in-memory storage combining a subscriber (stores PUT/DELETE samples in a `Map`) and a queryable (replies with matching entries using `KeyExpr.intersects`)
- 3 new C shim functions (141 → 144 total): `zd_keyexpr_intersects`, `zd_keyexpr_includes`, `zd_keyexpr_equals`
- 18 new integration tests (455 → 473 total)

## 0.16.0

### Added
- `ZSerializer` class — multi-value serialization with
  arithmetic types (uint8–int64, float, double, bool),
  strings, bytes, and sequence length headers
- `ZDeserializer` class — type-safe deserialization with
  round-trip fidelity for all serialized types
- `ZBytesWriter` class — raw byte-level assembly via
  `writeAll()` (raw bytes) and `append()` (ZBytes, consumed)
- `ZBytes.fromInt()` / `toInt()`, `fromDouble()` / `toDouble()`,
  `fromBool()` / `toBool()` convenience methods
- `ZBytes.slices` getter — lazy iterable of internal byte slices
- CLI example: `z_bytes.dart` — serialization round-trip demo
  (no network, 10 PASS/FAIL sections)
- 49 new C shim functions (92 → 141 total)
- 61 new integration tests (394 → 455 total)

## 0.14.0

### Added
- CLI example: `z_pub_thr.dart` — heap-based tight-loop throughput
  publisher with CongestionControl.block and clone-in-loop pattern
- CLI example: `z_sub_thr.dart` — background subscriber counting
  messages per round, reports throughput in msg/s with summary on exit
- CLI example: `z_pub_shm_thr.dart` — SHM zero-copy tight-loop
  throughput publisher using allocate-once-clone-in-loop pattern
- 12 new integration tests (382 → 394 total): CLI argument validation,
  throughput reporting, SHM startup, cross-example integration

## 0.13.0

### Added
- CLI example: `z_ping_shm.dart` — SHM zero-copy latency benchmark
  using allocate-once-clone-in-loop pattern
- 10 new integration tests (372 → 382 total): SHM clone semantics
  (6 tests) and z_ping_shm CLI (4 tests)

### Changed
- SHM pool minimum size enforced at 65536 bytes for Talc allocator
  compatibility with small payloads


## 0.12.0

### Added
- `Session.declareBackgroundSubscriber()` returns `Stream<Sample>` — fire-and-forget
  subscriber that lives until session closes, no explicit close needed
- `ZBytes.toBytes()` — reads content as `Uint8List` (non-destructive, can be called
  multiple times)
- `ZBytes.clone()` — shallow ref-counted copy with independent lifetime
- CLI examples: `z_ping.dart` (latency measurement), `z_pong.dart` (echo responder)
- 4 new C shim functions (88 → 92 total): zd_declare_background_subscriber,
  zd_bytes_clone, zd_bytes_len, zd_bytes_to_buf
- 32 new integration tests (340 → 372 total)

### Changed
- `Session.declarePublisher()` now accepts `isExpress` parameter (default false)
  for low-latency batching control
- `zd_declare_publisher` C signature extended with 7th parameter `is_express`
  (sentinel -1 = default)

## 0.11.0

### Added
- `Session.declareLivelinessToken()` returns `LivelinessToken` — announces
  entity presence on the network; token disappearance triggers DELETE events
- `Session.declareLivelinessSubscriber()` returns `Subscriber` — observes
  token PUT (appearance) and DELETE (disappearance) events with optional
  `history` parameter to receive pre-existing alive tokens
- `Session.livelinessGet()` returns `Stream<Reply>` — discovers currently
  alive tokens with configurable timeout
- `LivelinessToken` class with `keyExpr` and `close()`
- 5 new C shim functions (83 → 88 total): zd_liveliness_token_sizeof,
  zd_liveliness_declare_token, zd_liveliness_token_drop,
  zd_liveliness_declare_subscriber, zd_liveliness_get
- CLI examples: `z_liveliness.dart`, `z_sub_liveliness.dart`,
  `z_get_liveliness.dart`
- 30 new integration tests (310 → 340 total)

## 0.10.0

### Added
- `Session.declareQuerier()` returns `Querier` — long-lived entity for
  repeated queries on the same key expression
- `Querier` class with `get()` (returns `Stream<Reply>`), `keyExpr`, `close()`,
  `hasMatchingQueryables()`, `matchingStatus` stream; declaration-time options
  (target, consolidation, timeout) fixed at creation, per-query options
  (payload, encoding) vary per `get()` call
- 6 new C shim functions (77 → 83 total): zd_querier_sizeof,
  zd_declare_querier, zd_querier_drop, zd_querier_get,
  zd_querier_declare_background_matching_listener,
  zd_querier_get_matching_status
- CLI example: `z_querier.dart`
- 28 new integration tests (282 → 310 total)

## 0.9.0

### Added
- `Session.declarePullSubscriber()` returns `PullSubscriber` with synchronous
  `tryRecv()` polling via ring buffer
- `PullSubscriber` class with `tryRecv()` (returns `Sample?`), `keyExpr`,
  `close()`, and configurable ring buffer `capacity` (lossy: drops oldest on
  overflow)
- 4 new C shim functions (73 → 77 total): zd_ring_handler_sample_sizeof,
  zd_declare_pull_subscriber, zd_pull_subscriber_try_recv,
  zd_ring_handler_sample_drop
- CLI example: `z_pull.dart` (interactive stdin polling)
- 20 new integration tests (262 → 282 total)

## 0.8.0

### Changed
- `Session.get()` payload parameter widened from `Uint8List?` to `ZBytes?` —
  accepts SHM-backed bytes for zero-copy query payloads
- `Query.replyBytes()` payload parameter widened from `Uint8List` to `ZBytes` —
  accepts SHM-backed bytes for zero-copy reply payloads
- `zd_get()` and `zd_query_reply()` C shim signatures updated: raw
  `uint8_t* + len` replaced with `z_owned_bytes_t*` (consumed)

### Added
- `ZBytes.isShmBacked` property — detects whether bytes are backed by
  shared memory (SHM feature-guarded, returns false on Android)
- 1 new C shim function `zd_bytes_is_shm()` (72 → 73 total)
- CLI examples: `z_get_shm.dart`, `z_queryable_shm.dart`
- 25 new integration tests (237 → 262 total)

## 0.7.0

### Added
- `Session.get()` returns `Stream<Reply>` with selector, parameters, payload,
  encoding, target, consolidation, and timeout options
- `Session.declareQueryable()` returns `Queryable` with `stream`, `keyExpr`,
  `close()`, and `complete` flag
- `Query` class with `reply()`, `replyBytes()`, `dispose()`, `keyExpr`,
  `parameters`, `payloadBytes` — supports multiple replies per query via
  clone-and-post pattern
- `Reply` tagged union with `isOk`, `ok` (Sample), `error` (ReplyError) accessors
- `ReplyError` class with `payloadBytes`, `payload`, `encoding` fields
- `QueryTarget` enum: bestMatching, all, allComplete
- `ConsolidationMode` enum: auto, none, monotonic, latest
- 10 new C shim functions (62 → 72 total): zd_get, zd_declare_queryable,
  zd_queryable_drop, zd_queryable_sizeof, zd_query_sizeof, zd_query_reply,
  zd_query_drop, zd_query_keyexpr, zd_query_parameters, zd_query_payload
- CLI examples: `z_get.dart`, `z_queryable.dart`
- 44 new integration tests (193 → 237 total)

## 0.6.2 (Unreleased)

### Fixed
- Inter-process SIGSEGV crash when two Dart processes connect via zenoh TCP
  - Root cause: `@Native` lazy loading via `NoActiveIsolateScope` causes tokio
    waker vtable dispatch failure on background threads
  - Fix: reverted from `@Native` ffi-native bindings to class-based
    `ZenohDartBindings(DynamicLibrary)` loaded eagerly via `DynamicLibrary.open()`
  - Removed wrong-fix `zd_promote_zenohc_global()` C shim function (62 shim
    functions, unchanged from Phase 5)

### Added
- 13 new tests (193 total): native lib pre-load (6), inter-process TCP
  connection (4), inter-process pub/sub data exchange (3)
- Test helpers: `interprocess_connect.dart`, `interprocess_pubsub.dart`

### Changed
- `bindings.dart` regenerated as class-based (was `@Native` ffi-native)
- `native_lib.dart`: `ensureInitialized()` now loads via `DynamicLibrary.open()`
  with path resolution from package root (`native/linux/x86_64/`)

## Experiment B2: CBuilder + @Native Annotations (2026-03-10)

### Added
- Experiment package `exp_hooks_cbuilder_native` testing CBuilder.library() compilation + @Native annotation loading
- CBuilder compiles vendored C shim from source, linking against prebuilt `libzenohc.so`
- `@DefaultAsset` + `@Native` bindings with CBuilder `assetName` alignment
- 10 automated tests (all pass)
- `lessons-learned.md` with full 2x2 matrix comparison and migration recommendation

### Results
- **POSITIVE**: CBuilder + @Native successfully compiles and loads without `LD_LIBRARY_PATH`
- Completes the 2x2 experiment matrix: @Native is the sole determinant of success
- CBuilder auto-sets RUNPATH=$ORIGIN (no patchelf), `native_toolchain_c` 0.17.5 stable
- Migration recommendation: start with prebuilt+@Native (A2), consider CBuilder for CI/CD

## Experiment B1: CBuilder + DynamicLibrary.open() (2026-03-10)

### Added
- Experiment package `exp_hooks_cbuilder_dlopen` testing CBuilder.library() compilation from source + DynamicLibrary.open() loading
- Build hook compiles minimal 2-function C shim via `native_toolchain_c` CBuilder, linking against prebuilt `libzenohc.so`
- Vendored C source (zenoh_dart_minimal), Dart API DL files, and zenoh-c headers (15 files total)
- 11 automated tests (6 pass, 5 skip with documented negative result)
- Control test proving CBuilder output works with explicit `LD_LIBRARY_PATH`
- `lessons-learned.md` with CBuilder-specific observations and A1/A2/B1 comparison

### Results
- **NEGATIVE** (expected): `DynamicLibrary.open()` cannot find CBuilder output, same as A1
- CBuilder compiles successfully (~1s cold, ~0.3s warm), auto-sets RUNPATH=$ORIGIN
- Confirms loading mechanism (not build strategy) is the independent variable
- `native_toolchain_c` 0.17.5 works reliably despite EXPERIMENTAL status

## Experiment A2: Prebuilt + @Native Annotations (2026-03-10)

### Added
- Experiment package `exp_hooks_prebuilt_native` testing Dart build hooks with prebuilt native libraries and `@Native` annotation loading
- Build hook (`hook/build.dart`) declaring two `CodeAsset` entries with `DynamicLoadingBundled()`
- `@DefaultAsset` library directive + `@Native` external function declarations (no `DynamicLibrary.open()`)
- RUNPATH patching via `patchelf --set-rpath '$ORIGIN'` for DT_NEEDED resolution
- 9 automated tests (all pass)
- `lessons-learned.md` with empirical results and A1 vs A2 comparison

### Results
- **POSITIVE**: `@Native` + `@DefaultAsset` successfully resolves hook-bundled assets without `LD_LIBRARY_PATH`
- DT_NEEDED dependency (`libzenohc.so`) resolves via co-located RUNPATH=`$ORIGIN`
- CodeAsset names must use bare relative paths (constructor auto-prefixes `package:<name>/`)
- Post-test SEGV during VM teardown is cosmetic (zenoh cleanup ordering)

## Experiment A1: Both-Prebuilt + DynamicLibrary.open() (2026-03-10)

### Added
- Experiment package `exp_hooks_prebuilt_dlopen` testing Dart build hooks with prebuilt native libraries and `DynamicLibrary.open()` loading
- Build hook (`hook/build.dart`) declaring two `CodeAsset` entries with `DynamicLoadingBundled()` for `libzenoh_dart.so` and `libzenohc.so`
- 7 automated tests (2 pass, 5 skip with documented reasons)
- `lessons-learned.md` with empirical results for all 6 verification criteria

### Results
- **NEGATIVE** (expected): `DynamicLibrary.open()` cannot find hook-bundled assets — OS linker (`ld.so`) does not read hook metadata
- Hook builds succeed and register metadata, but no files are copied to linker-accessible locations
- Confirms Experiment A2 (`@Native` annotations) is required for hook-based native library resolution

## 0.6.1 (Unreleased)

### Added
- `Sample.payloadBytes` field (`Uint8List`): exposes raw payload bytes alongside the existing `payload` String field, enabling binary data consumers (Protobuf, CBOR, images) without breaking the string API
- 7 new tests (185 total) covering payloadBytes construction, binary round-trip, delete samples, and multi-sample sequences
## 0.6.0 (Unreleased)

### Added
- `ZenohId` class: 16-byte identifier with hex formatting, equality, and hashCode
- `WhatAmI` enum: router, peer, client values mapping zenoh-c bitmask (1, 2, 4)
- `Hello` class: scouting result with zid, whatami, and locators fields
- `Session.zid`: returns the session's own `ZenohId`
- `Session.routersZid()`: returns connected router ZIDs via synchronous buffer collection
- `Session.peersZid()`: returns connected peer ZIDs via synchronous buffer collection
- `Zenoh.scout()`: discovers zenoh entities on the network via NativePort callback bridge
- C shim: 6 new `zd_info_*`/`zd_scout`/`zd_id_to_string`/`zd_whatami_to_view_string` functions (62 total)
- CLI example `z_info.dart`: prints session ZID, router ZIDs, and peer ZIDs with `-e`/`--connect`, `-l`/`--listen` flags
- CLI example `z_scout.dart`: discovers zenoh entities with `-e`/`--connect`, `-l`/`--listen` flags
- 30 new tests (178 total) covering ZenohId/WhatAmI value types, session info queries, scout discovery, and CLI examples
## 0.5.0 (Unreleased)

### Added
- `ShmProvider` class: POSIX shared memory provider with `alloc()`, `allocGcDefragBlocking()`, `available`, and `close()`
- `ShmMutBuffer` class: mutable SHM buffer with `data` pointer (zero-copy write), `length`, `toBytes()` (zero-copy conversion to ZBytes), and `dispose()`
- SHM-published data received transparently by standard subscribers via existing `Publisher.putBytes()`
- C shim: 13 `zd_shm_*` functions guarded with `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)`
- `src/CMakeLists.txt`: `-DZ_FEATURE_SHARED_MEMORY -DZ_FEATURE_UNSTABLE_API` compile definitions
- ffigen.yaml: 6 SHM opaque type mappings (`z_owned_shm_provider_t`, `z_loaned_shm_provider_t`, `z_moved_shm_provider_t`, `z_owned_shm_mut_t`, `z_loaned_shm_mut_t`, `z_moved_shm_mut_t`)
- CLI example `z_pub_shm.dart`: SHM publisher with `-k`/`--key`, `-p`/`--payload`, `--add-matching-listener`, `-e`/`--connect`, `-l`/`--listen` flags
- 28 new tests (148 total) covering SHM provider lifecycle, buffer allocation/properties, data pointer/toBytes, SHM pub/sub integration, and CLI
## 0.4.0 (Unreleased)

### Added
- `Publisher` class: declared publisher with `put()`, `putBytes()`, `deleteResource()`, `keyExpr`, `hasMatchingSubscribers()`, `matchingStatus` stream, and `close()`
- `Encoding` class: MIME type wrapper with 10 predefined constants (textPlain, applicationJson, etc.) and custom constructor
- `CongestionControl` enum: `block` and `drop` congestion control strategies
- `Priority` enum: 7 priority levels from `realTime` to `background`
- `Session.declarePublisher()`: declare a publisher with optional encoding, congestionControl, priority, and enableMatchingListener
- `Sample.encoding` field: nullable String for received sample encoding (non-breaking)
- C shim subscriber callback updated to extract and post encoding as 5th Dart_CObject array element
- C shim `zd_publisher_sizeof()`, `zd_declare_publisher()`, `zd_publisher_loan()`, `zd_publisher_drop()`, `zd_publisher_put()`, `zd_publisher_delete()`, `zd_publisher_keyexpr()`, `zd_publisher_declare_background_matching_listener()`, `zd_publisher_get_matching_status()`
- CLI example `z_pub.dart`: publishes in a loop with `-k`/`--key`, `-p`/`--payload`, `-a`/`--attach`, `-e`/`--connect`, `-l`/`--listen`, `--add-matching-listener` flags
- 40 new tests (120 total) covering publisher lifecycle, put/putBytes, delete, encoding, matching status, QoS options, pub/sub integration, and CLI

## 0.3.0 (Unreleased)

### Added
- `Subscriber` class: callback-based subscriber with `Stream<Sample>` delivery via NativePort bridge pattern
- `Sample` class: received data with `keyExpr`, `payload`, `kind`, `attachment` fields
- `SampleKind` enum: `put` and `delete` sample kinds
- `Session.declareSubscriber(keyExpr)`: declare a subscriber on a key expression, returns `Subscriber`
- C shim `zd_declare_subscriber()`: declares subscriber with NativePort callback bridge (Dart_CObject array posted via Dart_PostCObject_DL)
- C shim `zd_subscriber_drop()`: undeclares and drops subscriber
- C shim `zd_subscriber_sizeof()`: returns sizeof(z_owned_subscriber_t)
- CLI example `z_sub.dart`: subscribes to key expression with `-k`/`--key`, `-e`/`--connect`, `-l`/`--listen` flags
- `-e`/`--connect` and `-l`/`--listen` flags added to `z_put.dart` for explicit endpoint configuration
- 22 new tests (80 total) covering subscriber lifecycle, NativePort bridge delivery, stream close, multi-subscriber independence, and CLI

## 0.2.0 (Unreleased)

### Added
- `Session.put(keyExpr, value)`: one-shot string publish on a key expression
- `Session.putBytes(keyExpr, payload)`: one-shot ZBytes publish with payload consumption semantics
- `Session.deleteResource(keyExpr)`: one-shot delete on a key expression (fire-and-forget)
- `Session._ensureOpen()` guard: throws `StateError` on operations after `close()`
- `ZBytes.markConsumed()` and consumed-state guard matching the `Config` pattern
- `ZBytes.nativePtr` getter with disposed/consumed guards for FFI interop
- `KeyExpr.nativePtr` getter for FFI interop
- C shim `zd_put()`: forwards to `z_put()` with default options and `z_bytes_move()` payload consumption
- C shim `zd_delete()`: forwards to `z_delete()` with default options
- CLI example `z_put.dart`: opens session, puts data with `--key`/`--payload` options, closes session
- CLI example `z_delete.dart`: opens session, deletes key with `--key` option, closes session
- 17 new tests (56 total) covering put/putBytes/deleteResource operations and CLI examples

## 0.1.0 (Unreleased)

### Added
- Build system: CMakeLists.txt compiles C shim with Dart SDK headers and links against libzenohc.so via three-tier discovery (Android jniLibs, Linux prebuilt, developer fallback) with RPATH set to $ORIGIN
- C shim (`src/zenoh_dart.{h,c}`): 29 `zd_`-prefixed FFI functions wrapping zenoh-c v1.7.2 APIs for config, session, keyexpr, bytes, and string operations
- Dart SDK headers (`src/dart/`) compiled into libzenoh_dart.so for Dart Native API DL support
- ffigen configuration (`ffigen.yaml`) with zenoh-c include paths and opaque type mappings for `z_owned_*`, `z_loaned_*`, `z_view_*`, `z_moved_*` types
- Auto-generated FFI bindings (`bindings.dart`) via dart:ffi ffigen
- Native library loader (`native_lib.dart`) with automatic Dart API DL initialization on first load
- `Config` class: default config creation, `insertJson5()` for mutable config modification, `dispose()`, consumed-state tracking with `StateError` guards
- `Session` class: `open()` factory (with optional config), graceful `close()` (z_close then z_session_drop), config consumption marking
- `KeyExpr` class: construct from string expression, `value` getter (data+len extraction, no null-termination assumption), `dispose()` freeing dual native allocations (struct + C string)
- `ZBytes` class: `fromString()`, `fromUint8List()`, `toStr()` round-trip with proper owned-string lifecycle, `dispose()`
- `ZenohException` class with message and return code for zenoh-c error propagation
- Barrel export (`package/lib/zenoh.dart`) for Config, Session, KeyExpr, ZBytes, ZenohException
- Logging initialization via `zd_init_log()` wrapping `zc_init_log_from_env_or()`
- Double-drop/double-close safety on all owned types (gravestone-state no-op pattern)
- Idempotent `dispose()`/`close()` guarded by `_disposed`/`_closed` flags
- 33 integration tests across 5 test files validating the full Dart → FFI → C shim → zenoh-c stack

## 0.0.1 (Unreleased)

- Initial scaffold: Melos monorepo with pure Dart `zenoh` package
