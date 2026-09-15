// Probe (seed #6 slice 15): does a FULL fifo query channel stall the hosting
// session's inbound query delivery SESSION-WIDE?
//
// The claim under test: while the channel sits full, a co-hosted Stream-path
// queryable's canary goes unanswered, and answers again once the channel is
// drained. This probe varies the capacity and the wedge volume, because a first
// attempt at capacity 1 with four wedge getters did NOT reproduce it — and an
// assertion written against an unreproduced claim is worse than no assertion.
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final host = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19341"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final getter = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19341"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  const canaryKey = 'probe/stall/canary';
  final canary = host.declareQueryable(canaryKey);
  canary.stream.listen((q) {
    q
      ..reply(canaryKey, 'canary')
      ..dispose();
  });
  await Future<void>.delayed(const Duration(milliseconds: 300));

  Future<int> canaryReplies() async {
    final r = await getter
        .get(canaryKey, timeout: const Duration(seconds: 2))
        .toList()
        .timeout(const Duration(seconds: 10));
    return r.length;
  }

  stdout.writeln('baseline canary=${await canaryReplies()}');

  for (final cfg in [(1, 4), (1, 10), (2, 10), (1, 30), (0, 4)]) {
    final (capacity, volume) = cfg;
    final key = 'probe/stall/wedge/$capacity/$volume';
    final pull = host.declarePullQueryable(
      key,
      kind: ChannelKind.fifo,
      capacity: capacity,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final wedge = <Future<List<Reply>>>[];
    for (var i = 0; i < volume; i++) {
      wedge.add(
        getter.get(key, timeout: const Duration(seconds: 30)).toList(),
      );
    }
    await Future<void>.delayed(const Duration(seconds: 2));

    final during = await canaryReplies();

    var drained = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (drained < volume && DateTime.now().isBefore(deadline)) {
      final r = pull.tryRecv();
      if (r is RecvData<Query>) {
        drained++;
        r.value
          ..reply(key, 'ack')
          ..dispose();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    final after = await canaryReplies();
    for (final w in wedge) {
      await w.timeout(const Duration(seconds: 40));
    }
    pull.close();

    stdout.writeln(
      'cap=$capacity volume=$volume '
      'canaryDuringWedge=$during drained=$drained canaryAfter=$after',
    );
  }

  canary.close();
  getter.close();
  host.close();
  stdout.writeln('PROBE_DONE');
}
