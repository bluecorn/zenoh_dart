import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

/// Helper script for inter-process connection tests.
///
/// Modes:
///   `--listen --port PORT`   Listen on `tcp/127.0.0.1:PORT`, print LISTENING
///   `--connect --port PORT`  Connect to `tcp/127.0.0.1:PORT`, print CONNECTED
///
/// In both modes, waits `--duration SECONDS` (default 5) then exits cleanly.
///
/// `CONNECTED` is a *link* marker, not an open marker. `Session.open()` returns
/// as soon as the session exists — whether or not the configured endpoint was
/// ever reached — so printing on its return certifies nothing: run this helper
/// with `--connect --port 1` (nothing listening) and it still printed
/// `CONNECTED` and exited 0. The tests that gate on this marker exist to guard
/// the v0.6.2 tokio-waker crash, and that crash needs two *connected*
/// processes; a marker satisfiable by a failed connect vacates the guard.
///
/// So the connect leg polls `peersZid()` until the peer appears, and exits
/// non-zero if it never does. Scouting is fully disabled (multicast *and*
/// gossip) in both legs, which is what makes the poll decisive: with no
/// discovery path available, a non-empty peer list can only mean the configured
/// TCP endpoint came up.
void main(List<String> args) async {
  final portIdx = args.indexOf('--port');
  if (portIdx == -1 || portIdx + 1 >= args.length) {
    stderr.writeln(
      'Usage: interprocess_connect.dart --listen|--connect --port <port> '
      '[--duration <seconds>]',
    );
    exit(1);
  }
  final port = args[portIdx + 1];

  final durationIdx = args.indexOf('--duration');
  final duration = (durationIdx != -1 && durationIdx + 1 < args.length)
      ? int.parse(args[durationIdx + 1])
      : 5;

  final isListen = args.contains('--listen');
  final isConnect = args.contains('--connect');

  if (!isListen && !isConnect) {
    stderr.writeln('Must specify --listen or --connect');
    exit(1);
  }

  final config = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');

  if (isListen) {
    config.insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]');
  } else {
    config.insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]');
  }

  final session = await Session.open(config: config);

  if (isListen) {
    // Bind failure throws out of `Session.open`, so reaching this line already
    // means the socket is up — no further evidence needed.
    stdout.writeln('LISTENING');
  } else {
    if (!await _awaitPeer(session)) {
      stderr.writeln('No peer appeared on tcp/127.0.0.1:$port');
      session.close();
      exit(1);
    }
    stdout.writeln('CONNECTED');
  }

  await Future<void>.delayed(Duration(seconds: duration));
  session.close();
  exit(0);
}

/// Polls [Session.peersZid] until a peer is visible, or the deadline passes.
///
/// Polling rather than sleeping: link establishment is a "wait until X has
/// happened" condition, and `peersZid()` is its own probe.
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
