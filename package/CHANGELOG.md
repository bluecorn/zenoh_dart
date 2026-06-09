# Changelog

All notable changes to this project will be documented in this file.

## 0.19.0 — Binary I/O Pairs: Payload + Attachment Fidelity

Byte-faithful payload **and** attachment across every send/receive transport pair, proven end-to-end. First application of the data-fidelity parity check ("correct in ⟹ correct out").

- **Added: exact attachment bytes on receive** — `Sample.attachmentBytes` (`Uint8List?`) and `Query.attachmentBytes` (`Uint8List?`) expose the exact attachment bytes on every receive surface, alongside the lenient `attachment` String view
- **Added: attachment + encoding send options** on `Session.put`/`putBytes`, `Session.get`, `Querier.get`, `Query.reply`/`replyBytes`, and `AdvancedPublisher.put`/`putBytes`
- **Added: `Query.replyErr`/`replyErrBytes`** — send an error reply (payload + encoding), making `ReplyError.payloadBytes` round-trip end-to-end (carve-out: error replies carry no attachment, per the zenoh-c contract)
- **Fixed: binary attachment corruption** — arbitrary non-UTF-8 payloads and attachments now round-trip byte-exact on every pair (attachments were previously corrupted to U+FFFD on receive)
- **Fixed: use-after-move** — `Session.get`, `Querier.get`, and `Query.replyBytes` mark consumed `ZBytes` unconditionally (zenoh-c consumes the move regardless of return code); genuine pre-move early-returns correctly retain caller ownership
- **Fixed: empty vs absent** — present-but-empty is now distinguishable from absent for query payloads and pull-subscriber attachments
- Hardened native byte-reader and `z_encoding_from_str` return-code handling (no uninitialized tail on short reads; no silent encoding-default substitution)
- 1 new C shim function (155 → 156: `zd_query_reply_err`; `zd_put`/`zd_get`/`zd_querier_get`/`zd_query_reply`/`zd_advanced_publisher_put` widened with attachment + encoding); back-compatible (new params optional)
- ~46 new integration tests (525 → 571 total)

## 0.18.1 — Binary Payload Delivery Fix

- **Fixed: binary payload corruption on every receive surface** — invalid-UTF-8 payloads (protobuf, flatbuffers, raw binary) were silently corrupted in transit to Dart: samples and replies arrived with `payloadBytes` emptied, and query payloads arrived nulled. Affected subscriber (all variants), `Session.get` and `Querier.get` replies, queryable `Query.payloadBytes`, and `PullSubscriber.tryRecv()`
- Root cause: the C shim flattened payloads through `z_bytes_to_string` (UTF-8-validating); callbacks now extract via `z_bytes_to_slice` (byte-faithful, flattens fragmented payloads) and sync extractors use the `z_bytes_reader` pattern
- Binary attachments no longer corrupt the carrying sample; `attachment` arrives as a lossy display string
- `payload`/`attachment` strings now decode leniently (`allowMalformed: true`, U+FFFD for invalid sequences) — `payloadBytes` remains the exact ground truth; valid-UTF-8 behavior byte-identical
- Empty-payload owned-string leak in the query callback eliminated; latent memcpy UB in `zd_query_payload` removed
- CLI test portability: stale hardcoded dart interpreter path replaced with `Platform.resolvedExecutable` (22 files)
- 13 new integration tests (512 → 525 total); no new public API, no exported C signature changes (155 shim functions unchanged)

## 0.18.0 — Phase 18: Advanced Pub/Sub

- `AdvancedPublisher`: publisher with cache, publisher detection, and sample miss detection
- `AdvancedPublisherOptions`: cache size, publisher detection, miss detection, heartbeat mode/period
- `HeartbeatMode` enum: `none`, `periodic`, `sporadic`
- `AdvancedSubscriber`: subscriber with history recovery, late publisher detection, miss events
- `AdvancedSubscriberOptions`: history, late publisher detection, recovery, miss detection, subscriber detection, miss listener
- `MissEvent`: missed sample notification with source `ZenohId` and count
- `Session.declareAdvancedPublisher()`, `Session.declareAdvancedSubscriber()`
- **CLI examples**: `z_advanced_pub.dart`, `z_advanced_sub.dart`
- 11 new C shim functions (144 → 155 total), guarded by `Z_FEATURE_UNSTABLE_API`
- ~38 new integration tests (473 → 512 total)

## 0.17.0 — Phase 17: In-Memory Storage

- `KeyExpr.intersects(other)`: returns true if two key expressions share at least one key
- `KeyExpr.includes(other)`: returns true if this expression is a superset of another
- `KeyExpr.equals(other)`: returns true if two key expressions are semantically equal
- **CLI example**: `z_storage.dart` — in-memory storage combining a subscriber (stores PUT/DELETE samples in a `Map`) and a queryable (replies with matching entries using `KeyExpr.intersects`)
- 3 new C shim functions (141 → 144 total)
- 18 new integration tests (455 → 473 total)

## 0.16.0 — Phase 16: Bytes Serialization/Deserialization

- `ZSerializer`: streaming multi-value serialization (uint8–int64, float, double, bool, string, bytes, sequence length)
- `ZDeserializer`: type-safe deserialization with `isDone` state tracking
- `ZBytesWriter`: raw byte assembly via `writeAll()`, `append()` (consumed), and `finish()`
- `ZBytes.fromInt()` / `toInt()`, `fromDouble()` / `toDouble()`, `fromBool()` / `toBool()` convenience methods
- `ZBytes.slices` lazy iterable for fragmented payload access
- **CLI example**: `z_bytes.dart` — serialization round-trip demo (no network)
- 49 new C shim functions (92 → 141 total)
- 61 new integration tests (394 → 455 total)

## 0.15.0 — Phase 15: SHM Throughput (Subsumed)

- Subsumed by Phase 14 — `z_pub_shm_thr.dart` was delivered as part of the throughput benchmarks

## 0.14.0 — Phase 14: Throughput Benchmarks

- **Composition phase** — no new C shim functions or Dart API classes
- `z_pub_thr.dart`: heap-based tight-loop publisher with `CongestionControl.block` and clone-in-loop
- `z_sub_thr.dart`: background subscriber counting messages per round, reports throughput in `msg/s`
- `z_pub_shm_thr.dart`: SHM zero-copy tight-loop publisher using allocate-once-clone-in-loop pattern
- 92 C shim functions, 394 integration tests

## 0.13.0 — Phase 13: SHM Ping

- **Composition phase** — no new C shim functions or Dart API classes
- `z_ping_shm.dart`: SHM zero-copy latency benchmark using allocate-once-clone-in-loop pattern; reuses `z_pong.dart` unchanged (SHM-transparent)
- SHM pool minimum size enforced at 65536 bytes for Talc allocator compatibility
- 92 C shim functions, 382 integration tests

## 0.12.0 — Phase 12: Ping/Pong Latency Benchmark

- **Background subscriber**: `Session.declareBackgroundSubscriber()` returns `Stream<Sample>` (fire-and-forget, lives until session closes)
- **Publisher express mode**: `isExpress` parameter on `Session.declarePublisher()` disables batching for low-latency publish
- **ZBytes read operations**: `clone()` (shallow ref-counted copy), `toBytes()` (read content as `Uint8List`)
- **CLI examples**: `z_ping.dart` (latency measurement), `z_pong.dart` (echo responder)
- 92 C shim functions, 372 integration tests

## 0.11.0 — Phase 11: Liveliness

- **Liveliness token**: `Session.declareLivelinessToken()` announces entity presence
- **Liveliness subscriber**: `Session.declareLivelinessSubscriber()` with `history` option
- **Liveliness get**: `Session.livelinessGet()` queries alive tokens
- **CLI examples**: `z_liveliness.dart`, `z_sub_liveliness.dart`, `z_get_liveliness.dart`
- 88 C shim functions, 340 integration tests

## 0.10.0 — Phase 10: Declared Querier

- **Querier**: `Session.declareQuerier()` for repeated queries with `get()`, `matchingStatus`, `hasMatchingQueryables()`
- **CLI example**: `z_querier.dart`
- 83 C shim functions, 310 integration tests

## 0.9.0 — Phase 9: Pull Subscriber

- **PullSubscriber**: `Session.declarePullSubscriber()` with C-side ring buffer and synchronous `tryRecv()`
- Configurable `capacity` (lossy: drops oldest on overflow)
- **CLI example**: `z_pull.dart`
- 77 C shim functions, 282 integration tests

## 0.7.0 — Phase 7: SHM Get/Queryable

- `Session.get()` and `Query.replyBytes()` widened to accept `ZBytes` (SHM zero-copy)
- `ZBytes.isShmBacked` property detects SHM-backed bytes
- **CLI examples**: `z_get_shm.dart`, `z_queryable_shm.dart`
- 73 C shim functions, 262 integration tests

## 0.6.0 — Phase 6: Get/Queryable

- **Get**: `Session.get()` returns `Stream<Reply>`
- **Queryable**: `Session.declareQueryable()` returns `Queryable` delivering `Stream<Query>`
- `Query`, `Reply`, `ReplyError`, `QueryTarget`, `ConsolidationMode` types
- **CLI examples**: `z_get.dart`, `z_queryable.dart`
- 72 C shim functions, 237 integration tests

## 0.5.0 — Phase 5: Scout/Info

- `ZenohId`, `WhatAmI`, `Hello` classes
- `Session.zid`, `routersZid()`, `peersZid()`
- `Zenoh.scout()` network discovery
- **CLI examples**: `z_info.dart`, `z_scout.dart`
- 62 C shim functions, 185 integration tests

## 0.4.0 — Phase 4: SHM Provider

- `ShmProvider`, `ShmMutBuffer` with zero-copy alloc/write/publish
- SHM-published data received transparently by standard subscribers
- **CLI example**: `z_pub_shm.dart`
- 56 C shim functions, 148 integration tests

## 0.3.0 — Phase 3: Publisher

- `Publisher` with `put`/`putBytes`/`deleteResource`/`matchingStatus`
- `Encoding`, `CongestionControl`, `Priority` types
- **CLI example**: `z_pub.dart`
- 43 C shim functions, 120 integration tests

## 0.2.0 — Phase 2: Subscriber

- `Session.declareSubscriber()` returns `Subscriber` with `Stream<Sample>`
- NativePort callback bridge for async sample delivery
- **CLI example**: `z_sub.dart`
- 34 C shim functions, 80 integration tests

## 0.1.0 — Phase 1: Put/Delete

- `Session.put()`, `Session.putBytes()`, `Session.deleteResource()`
- **CLI examples**: `z_put.dart`, `z_delete.dart`
- 31 C shim functions, 56 integration tests

## 0.0.1 — Phase 0: Bootstrap

- `Zenoh`, `Config`, `Session`, `KeyExpr`, `ZBytes` core classes
- `DynamicLibrary.open()` loading with build hook distribution
- 29 C shim functions, 33 integration tests
