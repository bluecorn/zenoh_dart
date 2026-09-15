// The drive loop's fault contract, driven under an LD_PRELOAD allocation
// injector.
//
// WHAT IS UNDER TEST. `PullSubscriber.stream`'s drive loop consumes the
// handle's own `recv()`, which can THROW rather than return a result. The two
// throw classes have opposite contracts and the loop must render each as canon
// does:
//
//   ZenohException -> canon calls it a CALL failure, not a channel state. The
//                     channel is alive, so the loop forwards the error and
//                     KEEPS PULLING.
//   StateError     -> the handle is closed or contended. Nothing is left to
//                     pull, so the stream terminates.
//
// ⚠️ THE INJECTOR'S REACH, stated because it IS the instrument's fitness. The
// only threshold-crossing shim `malloc` on this path is the pull's payload
// copy in `zd_pull_subscriber_try_recv` (`src/zenoh_dart.c:3413`), whose NULL
// branch returns -1 and surfaces as `ZenohException`. Verified rather than
// assumed: `zd_put`, `zd_publisher_put`, `zd_declare_publisher`,
// `zd_open_session`, `zd_declare_pull_subscriber` and `zd_bytes_from_slice`
// contain ZERO allocation sites, so nothing on the PUBLISH path can be hit and
// the failure that lands is the one under test.
//
// ⚠️ WHICH PROCESS CARRIES THE PRELOAD: this one, and it is both producer and
// consumer for exactly that reason. `LD_PRELOAD` must be in place before the
// process links, so the consumer cannot be a child spawned later; and because
// the publish path allocates nothing in our shim, hosting the producer here
// costs nothing. The channel is a RING, so a same-process producer can never
// be held by a full channel.
//
// Markers (stdout unless noted):
//   HARNESS_READY          the two sessions are linked
//   SAMPLE_OK len=<n>      the stream delivered a sample
//   STREAM_ERROR=<type>    the stream emitted an error event
//   STREAM_DONE            the stream completed
//   HARNESS_OK             the scripted sequence finished without dying
//   HARNESS_DONE           reached the end, so exit 0 is a real exit
//   INJECTOR_FIRED size=   printed by the injector itself, on STDERR
import 'dart:io';
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

const _port = 19596;
const _key = 'zenoh/dart/harness/bstream/fault';

/// Bigger than the injector's threshold, so its payload copy is the allocation
/// that fails. Small enough to stay far inside loopback slack.
const int _bigBytes = 512 * 1024;

/// Below the threshold, so this one is delivered normally even under
/// injection — which is what shows the stream SURVIVED the error above it.
const String _smallPayload = 'small';

Config _config({int? listen, int? connect}) => Config()
  ..insertJson5('mode', '"peer"')
  ..insertJson5(
    listen != null ? 'listen/endpoints' : 'connect/endpoints',
    '["tcp/127.0.0.1:${listen ?? connect}"]',
  )
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false');

Future<void> main() async {
  final subSession = await Session.open(config: _config(listen: _port));
  final pubSession = await Session.open(config: _config(connect: _port));

  final link = Stopwatch()..start();
  while (subSession.peersZid().isEmpty) {
    if (link.elapsed > const Duration(seconds: 20)) {
      stdout.writeln('HARNESS_FAILED reason=never-linked');
      exit(2);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  stdout.writeln('HARNESS_READY');

  final pull = subSession.declarePullSubscriber(_key, capacity: 8);
  final sub = pull.stream.listen(
    (s) => stdout.writeln('SAMPLE_OK len=${s.payloadBytes.length}'),
    onError: (Object e) => stdout.writeln('STREAM_ERROR=${e.runtimeType}'),
    onDone: () => stdout.writeln('STREAM_DONE'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 400));

  // The oversized sample FIRST: under injection its payload copy is the malloc
  // that returns NULL, and the loop should forward a ZenohException without
  // stopping.
  pubSession.putBytes(_key, ZBytes.fromUint8List(Uint8List(_bigBytes)));
  await Future<void>.delayed(const Duration(seconds: 2));

  // Then a small one. Its arrival is the whole point: it can only be delivered
  // by a loop that kept pulling after the error.
  pubSession.put(_key, _smallPayload);
  await Future<void>.delayed(const Duration(seconds: 2));

  stdout.writeln('HARNESS_OK');
  await sub.cancel();
  pull.close();
  pubSession.close();
  subSession.close();
  stdout.writeln('HARNESS_DONE');
  exit(0);
}
