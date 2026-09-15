// Live-fire leg for seed #6 slice 15: closing a pull queryable WHILE queries
// are still arriving, i.e. while a delivery may be executing inside the
// readiness tee on zenoh's own thread.
//
// Run as a SUBPROCESS under MALLOC_PERTURB_, because glibc reads it once at
// startup and because a premature free of the tee context would otherwise
// return plausible bytes and stay silent.
//
// Markers:
//   HARNESS_CLOSED -- every round's handle was closed mid-flight
//   HARNESS_DONE   -- reached the end, so exit 0 is a real exit
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final host = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19342"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final getter = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19342"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  const key = 'zenoh/dart/harness/query-close-race';
  final gets = <Future<List<Reply>>>[];

  for (var round = 0; round < 15; round++) {
    final pull = host.declarePullQueryable(
      key,
      kind: ChannelKind.ring,
      capacity: 2,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Getters still in flight when the handle lets go.
    for (var i = 0; i < 3; i++) {
      gets.add(
        getter.get(key, timeout: const Duration(seconds: 2)).toList(),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final taken = pull.tryRecv();
    if (taken is RecvData<Query>) taken.value.dispose();
    pull.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  stdout.writeln('HARNESS_CLOSED');

  // Let every getter run out, so nothing is left pinning the isolate.
  for (final g in gets) {
    await g.timeout(const Duration(seconds: 20));
  }

  getter.close();
  host.close();
  stdout.writeln('HARNESS_DONE');
}
