import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

/// Helper script for inter-process pub/sub tests.
///
/// Modes:
///   `--mode sub --port PORT`  Listen on port, subscribe, print received
///                             samples
///   `--mode pub --port PORT`  Connect to port, publish payload
///
/// Options:
///   `--key KEY`       Key expression (default: interprocess/test)
///   `--payload TEXT`  Payload to publish (default: hello)
///   `--count N`       Number of messages to send/receive (default: 1)
void main(List<String> args) async {
  final modeIdx = args.indexOf('--mode');
  final mode = (modeIdx != -1 && modeIdx + 1 < args.length)
      ? args[modeIdx + 1]
      : null;
  final portIdx = args.indexOf('--port');
  final port = (portIdx != -1 && portIdx + 1 < args.length)
      ? args[portIdx + 1]
      : null;
  final keyIdx = args.indexOf('--key');
  final key = (keyIdx != -1 && keyIdx + 1 < args.length)
      ? args[keyIdx + 1]
      : 'interprocess/test';
  final payloadIdx = args.indexOf('--payload');
  final payload = (payloadIdx != -1 && payloadIdx + 1 < args.length)
      ? args[payloadIdx + 1]
      : 'hello';
  final countIdx = args.indexOf('--count');
  final count = (countIdx != -1 && countIdx + 1 < args.length)
      ? int.parse(args[countIdx + 1])
      : 1;

  if (mode == null || port == null) {
    stderr.writeln(
      'Usage: interprocess_pubsub.dart --mode pub|sub --port PORT '
      '[--key KEY] [--payload PAYLOAD] [--count N]',
    );
    exit(1);
  }

  // Scouting fully off in both legs: with no discovery path available, delivery
  // can only have travelled the configured TCP endpoint. With multicast left on
  // these tests prove "delivered by some route", not "delivered by this one".
  final config = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');

  if (mode == 'sub') {
    config.insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]');
    final session = await Session.open(config: config);
    final subscriber = session.declareSubscriber(key);

    stdout.writeln('SUB_READY');

    var received = 0;
    await for (final sample in subscriber.stream) {
      stdout.writeln('RECEIVED:${sample.payload}');
      final bytes = sample.payloadBytes;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      stdout.writeln('BYTES:$hex');
      received++;
      if (received >= count) break;
    }

    subscriber.close();
    session.close();
    exit(0);
  } else if (mode == 'pub') {
    config.insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]');
    final session = await Session.open(config: config);

    // Wait until the link is actually up, not until a guessed second has
    // passed. A put fired before the link exists is dropped silently
    // (fire-and-forget), and with scouting off there is no second route to
    // rescue it — so this poll is what keeps the following puts deliverable.
    if (!await _awaitPeer(session)) {
      stderr.writeln('No peer appeared on tcp/127.0.0.1:$port');
      session.close();
      exit(1);
    }

    stdout.writeln('PUB_READY');

    for (var i = 0; i < count; i++) {
      final msg = count > 1 ? '$payload-$i' : payload;
      session.put(key, msg);
      stdout.writeln('SENT:$msg');
      if (i < count - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    // Allow messages to flush
    await Future<void>.delayed(const Duration(seconds: 1));
    session.close();
    exit(0);
  } else {
    stderr.writeln('Unknown mode: $mode (expected pub or sub)');
    exit(1);
  }
}

/// Polls [Session.peersZid] until a peer is visible, or the deadline passes.
Future<bool> _awaitPeer(
  Session session, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (session.peersZid().isNotEmpty) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}
