// Live-fire leg for seed #6: disposing a reply channel WHILE replies are still
// arriving, i.e. while a delivery may be executing inside the readiness tee on
// zenoh's own thread.
//
// This is the one place the reply column's lifetime differs from the sample
// column's: there is no entity drop to serialise against, so the tee context
// has two owners and a reference count. A premature free would be a
// use-after-free on a block that still looks plausible — which is exactly the
// class MALLOC_PERTURB_ turns from a silent read into a loud abort. Run as a
// SUBPROCESS, because glibc reads MALLOC_PERTURB_ once at startup.
//
// Markers:
//   HARNESS_DISPOSED  -- the handle was released mid-flight
//   HARNESS_DONE      -- reached the end, so an exit code of 0 is a real exit
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final replierSession = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19367"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final getterSession = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19367"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  const key = 'zenoh/dart/harness/dispose-race';
  final held = <Query>[];
  final queryable = replierSession.declareQueryable(key);
  queryable.stream.listen((query) async {
    // Keep producing across the dispose, and hold the query open so the
    // closure is still alive when the Dart handle lets go.
    for (var i = 0; i < 200; i++) {
      query.reply(key, 'r$i');
      if (i % 20 == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    held.add(query);
  });
  await Future<void>.delayed(const Duration(milliseconds: 300));

  for (var round = 0; round < 20; round++) {
    getterSession.pullGet(
        key,
        kind: ChannelKind.ring,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 30),
      )
      // Take a couple, then let go while the replier is still producing.
      ..tryRecv()
      ..tryRecv()
      ..dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  stdout.writeln('HARNESS_DISPOSED');

  // Let the queries complete so canon drops its closures with the Dart handles
  // already gone — the other ordering.
  for (final q in held) {
    q.dispose();
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  queryable.close();
  getterSession.close();
  replierSession.close();
  stdout.writeln('HARNESS_DONE');
}
