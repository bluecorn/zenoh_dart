// Probe (seed #6 slice 13): capacity 0 on a QUERY channel, per kind, under
// polling.
//
// The reply column's capacity-0 semantics were measured at slice 10; the query
// column's are a different question, because the blocked party is different. On
// a two-session route the getter is never the one blocked, so a rendezvous here
// meets the hosting session's RX thread rather than a caller.
//
// Every wait is bounded.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final host = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19343"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final getter = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19343"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  for (final kind in ChannelKind.values) {
    final key = 'probe/qcap0/${kind.name}';
    final pull = host.declarePullQueryable(key, kind: kind, capacity: 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final getDone = getter
        .get(key, timeout: const Duration(seconds: 3))
        .toList();

    var recovered = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final r = pull.tryRecv();
      if (r is RecvData<Query>) {
        recovered++;
        r.value
          ..reply(key, 'ack')
          ..dispose();
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final replies = await getDone.timeout(const Duration(seconds: 15));
    stdout.writeln(
      'qcap0 ${kind.name}: recovered=$recovered '
      'getterReplies=${replies.length}',
    );

    // Drain before closing, so a rendezvous does not move the freeze here.
    var guard = 0;
    while (pull.tryRecv() is RecvData<Query> && guard++ < 20) {}
    pull.close();
  }

  getter.close();
  host.close();
  stdout.writeln('PROBE_DONE');
}
