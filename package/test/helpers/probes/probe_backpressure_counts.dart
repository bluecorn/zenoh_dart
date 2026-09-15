// Probe (seed #6 slice 8): what do the fifo and ring channels ACTUALLY recover
// through overflow, at the same capacity and volume?
//
// `lessThan(volume)` on the ring is satisfied by zero, and zero would mean the
// cell measured discard-at-disconnect (already pinned at slice 5) rather than
// drop-oldest through overflow. This prints the counts so the assertion can be
// tightened to what is really happening.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19347"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19347"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  Future<List<String>> run(
    ChannelKind kind,
    int volume,
    int capacity,
    Duration pace,
  ) async {
    final key = 'probe/bp/${kind.name}/$volume/$capacity';
    final queryable = a.declareQueryable(key);
    queryable.stream.listen((q) {
      for (var i = 0; i < volume; i++) {
        q.reply(key, '$i');
      }
      q.dispose();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ch = b.pullGet(
      key,
      kind: kind,
      capacity: capacity,
      consolidation: ConsolidationMode.none,
      timeout: const Duration(seconds: 60),
    );
    final got = <String>[];
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var done = false;
    while (!done && DateTime.now().isBefore(deadline)) {
      switch (ch.tryRecv()) {
        case RecvData(:final value):
          got.add(value.ok.payload);
          await Future<void>.delayed(pace);
        case RecvDisconnected():
          done = true;
        case RecvEmpty():
          await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    ch.dispose();
    queryable.close();
    return got;
  }

  for (final kind in ChannelKind.values) {
    final got = await run(kind, 20, 2, const Duration(milliseconds: 20));
    stdout
      ..writeln(
        '${kind.name} vol=20 cap=2 pace=20ms '
        'recovered=${got.length} '
        'first=${got.isEmpty ? "-" : got.first} '
        'last=${got.isEmpty ? "-" : got.last}',
      )
      ..writeln('   values=${got.join(",")}');
  }

  b.close();
  a.close();
  stdout.writeln('PROBE_DONE');
}
