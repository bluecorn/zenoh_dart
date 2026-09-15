// Slice 4 / Test 14: nothing is orphaned when queries arrive inside the
// reorder's window.
//
// After the reorder, canon's closure is still live between the handler drop
// and the undeclare's return, so a query can be pushed into a DROPPED receiver
// in that window. Where it goes is a correctness question. This harness drives
// the window hard and repeatedly under MALLOC_PERTURB_, so a query freed twice
// or read after free in there FAULTS instead of returning plausible bytes and
// passing silently.
//
// Fully self-contained: it owns both sessions, because no parent-side
// measurement is needed here. That is deliberately NOT the split topology
// Tests 12-13 use -- those need the parent to measure getters in a healthy
// isolate; this one only needs the rounds to happen.
//
// Markers:
//   ROUND=<i>     one completed {declare, fire, close} round
//   WINDOW_DONE   reached the end, so exit 0 is a real exit
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

const _port = 19583;
const _key = 'zenoh/dart/fifoclose/window-perturb';
const _rounds = 8;
const _gettersPerRound = 5;

Config _config({int? listen, int? connect}) {
  final c = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (listen != null) {
    c.insertJson5('listen/endpoints', '["tcp/127.0.0.1:$listen"]');
  }
  if (connect != null) {
    c.insertJson5('connect/endpoints', '["tcp/127.0.0.1:$connect"]');
  }
  return c;
}

Future<void> main() async {
  final host = await Session.open(config: _config(listen: _port));
  final getter = await Session.open(config: _config(connect: _port));

  final link = Stopwatch()..start();
  while (host.peersZid().isEmpty) {
    if (link.elapsed > const Duration(seconds: 20)) {
      stderr.writeln('HARNESS_ERROR: peers never linked');
      exit(3);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  final outstanding = <Future<void>>[];

  for (var round = 0; round < _rounds; round++) {
    final qbl = host.declarePullQueryable(
      _key,
      kind: ChannelKind.fifo,
      capacity: 2,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Five getters into a capacity-2 channel: the channel fills, a delivery
    // parks, and the remainder are still arriving when the close starts --
    // which is the only configuration in which the window is actually
    // occupied.
    for (var i = 0; i < _gettersPerRound; i++) {
      outstanding.add(
        getter
            .get(
              _key,
              timeout: const Duration(seconds: 2),
              consolidation: ConsolidationMode.none,
            )
            .drain<void>(),
      );
    }
    // Settle, not a race: the queries have to reach the channel and fill it
    // before the close, and there is no observable for "a delivery is now
    // parked" -- being parked is precisely the state that emits nothing.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // No tryRecv anywhere: every query is left undelivered, so the handler
    // drop and the still-live closure both meet a populated channel.
    qbl.close();
    stdout.writeln('ROUND=$round');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  // Let every getter run out, bounded, so nothing pins the isolate at exit.
  for (final g in outstanding) {
    try {
      await g.timeout(const Duration(seconds: 20));
    } on Object catch (_) {}
  }

  getter.close();
  host.close();
  stdout.writeln('WINDOW_DONE');
  exit(0);
}
