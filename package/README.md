# zenoh

Pure Dart FFI bindings for the [Zenoh](https://zenoh.io/) pub/sub/query protocol.

## Features

- Peer-to-peer and routed communication via zenoh
- Publish/subscribe with key expressions
- Query/reply (get/queryable) request-response pattern
- Pull subscriber with ring buffer (lossy, latest-value semantics)
- Declared querier for repeated queries with matching status
- Liveliness tokens for presence detection and subscriber notifications
- Background subscriber (fire-and-forget, lives until session closes)
- Ping/pong latency benchmarking with express publisher mode (heap and SHM)
- Throughput benchmarking (heap tight-loop and SHM zero-copy)
- Cross-language typed serialization/deserialization (ZSerializer, ZDeserializer)
- Raw byte assembly (ZBytesWriter) and fragmented slice iteration
- Byte-exact binary payload delivery (protobuf/flatbuffers/CDR-safe) via `payloadBytes`
- Advanced pub/sub: publisher cache, history recovery, sample miss detection with heartbeats
- Key expression matching (`intersects`/`includes`/`equals`) for storage-style routing
- Shared memory (SHM) zero-copy for publish, get, and reply (Linux)
- Network scouting and session info
- Build hooks for seamless native library distribution

## Getting Started

```dart
import 'package:zenoh/zenoh.dart';

void main() async {
  final session = Session.open();

  // Publish
  session.put('demo/hello', 'Hello from Dart!');

  // Subscribe
  final subscriber = session.declareSubscriber('demo/**');
  subscriber.stream.listen((sample) {
    print('${sample.keyExpr}: ${sample.payload}');
  });

  // Declare a publisher
  final publisher = session.declarePublisher('demo/counter');
  publisher.put('value');

  // Query/reply
  final replies = session.get('demo/**');
  await for (final reply in replies) {
    if (reply.isOk) print('${reply.ok.keyExpr}: ${reply.ok.payload}');
  }

  // Clean up
  subscriber.close();
  publisher.close();
  session.close();
}
```

Binary payloads round-trip byte-exact: publish with `putBytes(key, ZBytes.fromUint8List(bytes))` and read `sample.payloadBytes` on receive (`sample.payload` is a lenient display string — invalid UTF-8 renders as U+FFFD).

## API

| Class | Description |
|-------|-------------|
| `Zenoh` | Static utilities: `initLog()`, `scout()` |
| `Config` | Session configuration with JSON5 insertion |
| `Session` | Open/close sessions; put, subscribe, publish, get, queryable, pull subscribe, querier, liveliness, background subscribe, advanced publish/subscribe |
| `KeyExpr` | Key expression creation and validation; `intersects()`/`includes()`/`equals()` matching |
| `ZBytes` | Binary payload container; `clone()`, `toBytes()`, `fromInt()`/`toInt()`, `fromDouble()`/`toDouble()`, `fromBool()`/`toBool()`, `slices` (fragment iteration), `isShmBacked` |
| `ZSerializer` | Streaming serializer for multi-value payloads (uint8–int64, float, double, bool, string, bytes, sequence length) |
| `ZDeserializer` | Type-safe streaming deserializer with `isDone` state tracking |
| `ZBytesWriter` | Raw byte assembler via `writeAll()`, `append()` (consumed), `finish()` |
| `LivelinessToken` | Announces entity presence; intersecting subscribers notified on declare/close |
| `Publisher` | Declared publisher with put/delete/matching status/express mode |
| `AdvancedPublisher` | Publisher with cache, publisher detection, and sample miss detection |
| `AdvancedPublisherOptions` | Cache size, publisher detection, miss detection, heartbeat mode/period |
| `HeartbeatMode` | Enum: `none`, `periodic`, `sporadic` |
| `Subscriber` | Callback-based subscriber delivering `Stream<Sample>` |
| `AdvancedSubscriber` | Subscriber with history recovery, late publisher detection, and miss events |
| `AdvancedSubscriberOptions` | History, recovery, miss detection, subscriber detection, miss listener |
| `MissEvent` | Missed-sample notification with source `ZenohId` and count |
| `PullSubscriber` | Ring-buffer-backed pull subscriber with `tryRecv()` (lossy) |
| `Querier` | Declared querier for repeated queries with matching status |
| `Query` | Received query with reply/replyBytes/dispose |
| `Queryable` | Callback-based queryable delivering `Stream<Query>` |
| `Reply` | Tagged union: `isOk`, `ok` (Sample), `error` (ReplyError) |
| `ReplyError` | Error reply with payload and encoding |
| `QueryTarget` | Enum: `bestMatching`, `all`, `allComplete` |
| `ConsolidationMode` | Enum: `auto`, `none`, `monotonic`, `latest` |
| `Sample` | Received data with key, payload (lenient display string), payloadBytes (exact), kind, encoding, attachment |
| `SampleKind` | Enum: `put`, `delete` |
| `Encoding` | MIME type wrapper with predefined constants |
| `CongestionControl` | Enum: `block`, `drop` |
| `Priority` | 7 priority levels from `realTime` to `background` |
| `ShmProvider` | POSIX shared memory provider for zero-copy |
| `ShmMutBuffer` | Mutable SHM buffer |
| `ZenohId` | 16-byte session identifier |
| `WhatAmI` | Enum: `router`, `peer`, `client` |
| `Hello` | Scouting result with ZID, type, and locators |
| `ZenohException` | Error type for zenoh operations |

## CLI Examples

All examples live in [`example/`](example/) and support `-e`/`--connect` and `-l`/`--listen` flags for endpoint configuration.

| Example | Description |
|---|---|
| [`z_put.dart`](example/z_put.dart) | Put data on a key expression |
| [`z_delete.dart`](example/z_delete.dart) | Delete a key expression |
| [`z_sub.dart`](example/z_sub.dart) | Subscribe to a key expression (runs until Ctrl-C) |
| [`z_pub.dart`](example/z_pub.dart) | Publish in a loop (runs until Ctrl-C) |
| [`z_pub_shm.dart`](example/z_pub_shm.dart) | Publish via shared memory (runs until Ctrl-C) |
| [`z_info.dart`](example/z_info.dart) | Print session ZID and connected router/peer ZIDs |
| [`z_scout.dart`](example/z_scout.dart) | Discover zenoh entities on the network |
| [`z_get.dart`](example/z_get.dart) | Send a query and receive replies |
| [`z_queryable.dart`](example/z_queryable.dart) | Declare a queryable that replies to queries |
| [`z_get_shm.dart`](example/z_get_shm.dart) | Send a query with SHM payload |
| [`z_queryable_shm.dart`](example/z_queryable_shm.dart) | Queryable that replies with SHM payloads |
| [`z_pull.dart`](example/z_pull.dart) | Pull subscriber with ring buffer (interactive polling) |
| [`z_querier.dart`](example/z_querier.dart) | Declared querier for repeated queries (runs until Ctrl-C) |
| [`z_liveliness.dart`](example/z_liveliness.dart) | Declare a liveliness token (announces presence, runs until Ctrl-C) |
| [`z_sub_liveliness.dart`](example/z_sub_liveliness.dart) | Subscribe to liveliness changes (runs until Ctrl-C) |
| [`z_get_liveliness.dart`](example/z_get_liveliness.dart) | Query currently alive liveliness tokens |
| [`z_pong.dart`](example/z_pong.dart) | Pong responder (echoes ping payload, runs until Ctrl-C) |
| [`z_ping.dart`](example/z_ping.dart) | Measure round-trip latency (requires z_pong running) |
| [`z_ping_shm.dart`](example/z_ping_shm.dart) | Measure round-trip latency with SHM zero-copy (requires z_pong running) |
| [`z_pub_thr.dart`](example/z_pub_thr.dart) | Tight-loop throughput publisher (heap, requires z_sub_thr) |
| [`z_sub_thr.dart`](example/z_sub_thr.dart) | Background subscriber counting throughput (reports msg/s) |
| [`z_pub_shm_thr.dart`](example/z_pub_shm_thr.dart) | Tight-loop SHM throughput publisher (requires z_sub_thr) |
| [`z_bytes.dart`](example/z_bytes.dart) | Serialization round-trip demo (no network) |
| [`z_storage.dart`](example/z_storage.dart) | In-memory storage: subscriber stores PUT/DELETE, queryable replies with matching entries |
| [`z_advanced_pub.dart`](example/z_advanced_pub.dart) | Advanced publisher with cache, publisher detection, and heartbeat |
| [`z_advanced_sub.dart`](example/z_advanced_sub.dart) | Advanced subscriber with history recovery, miss detection, and miss listener |

```bash
# Quick start examples
dart run example/z_put.dart -k demo/example/test -p 'Hello from Dart!'
dart run example/z_sub.dart -k 'demo/example/**'
dart run example/z_get.dart -s 'demo/example/**'
dart run example/z_queryable.dart -k demo/example/zenoh-dart-queryable
dart run example/z_querier.dart -s 'demo/example/**'
dart run example/z_pull.dart -k 'demo/example/**'
dart run example/z_liveliness.dart -k group1/zenoh-dart
dart run example/z_sub_liveliness.dart -k 'group1/**' --history
dart run example/z_pong.dart
dart run example/z_ping.dart 64 -n 100 -w 1000
dart run example/z_ping_shm.dart 64 -n 100 -w 1000
dart run example/z_pub_thr.dart 8192 --express
dart run example/z_sub_thr.dart -s 10 -n 100000
dart run example/z_pub_shm_thr.dart 8192
dart run example/z_bytes.dart
```

## Platform Support

| Platform | Architecture | Status |
|----------|-------------|--------|
| Linux | x86_64 | Supported |
| Android | arm64-v8a, x86_64 | Supported |

## License

Apache 2.0 — see [LICENSE](LICENSE).
