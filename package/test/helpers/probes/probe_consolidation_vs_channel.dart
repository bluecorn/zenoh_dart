// Probe (seed #6 slice 5): does the get's CONSOLIDATION mode decide whether a
// reply channel sees replies in flight, and whether multiple replies on one key
// survive at all?
//
// `ConsolidationMode.auto` is canon's own default and resolves to a
// consolidating mode, which both dedupes by key expression and withholds
// replies until the query completes. Neither is a channel property, and both
// would make a per-kind DRAIN cell measure consolidation instead.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19348"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19348"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  Future<int> drainCount(
    String key,
    ChannelKind kind,
    ConsolidationMode c, {
    required int replies,
    required bool hold,
  }) async {
    final queryable = a.declareQueryable(key);
    final held = <Query>[];
    queryable.stream.listen((q) {
      for (var i = 0; i < replies; i++) {
        q.reply(key, 'r$i');
      }
      if (hold) {
        held.add(q);
      } else {
        q.dispose();
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ch = b.pullGet(
      key,
      kind: kind,
      capacity: 8,
      consolidation: c,
      timeout: const Duration(seconds: 20),
    );
    if (!hold) await Future<void>.delayed(const Duration(seconds: 1));
    var n = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    var done = false;
    while (!done && DateTime.now().isBefore(deadline)) {
      switch (ch.tryRecv()) {
        case RecvData():
          n++;
        case RecvDisconnected():
          done = true;
        case RecvEmpty():
          await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    ch.dispose();
    for (final q in held) {
      q.dispose();
    }
    queryable.close();
    return n;
  }

  for (final c in [ConsolidationMode.auto, ConsolidationMode.none]) {
    final fifo = await drainCount(
      'probe/cons/${c.name}/fifo',
      ChannelKind.fifo,
      c,
      replies: 3,
      hold: false,
    );
    final ring = await drainCount(
      'probe/cons/${c.name}/ring',
      ChannelKind.ring,
      c,
      replies: 3,
      hold: false,
    );
    final inflight = await drainCount(
      'probe/cons/${c.name}/hold',
      ChannelKind.ring,
      c,
      replies: 1,
      hold: true,
    );
    stdout.writeln(
      'consolidation=${c.name} '
      'fifo_drained_after_completion=$fifo '
      'ring_drained_after_completion=$ring '
      'ring_inflight_delivered=$inflight',
    );
  }

  b.close();
  a.close();
  stdout.writeln('PROBE_DONE');
}
