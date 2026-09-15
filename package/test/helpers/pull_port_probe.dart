// Live leg for seed #5: every PullSubscriber now owns a ReceivePort, and a
// port that outlives its subscriber keeps the isolate alive.
//
// Run as a SUBPROCESS. The failure mode is a HUNG PROCESS, not a red
// assertion, so the observable has to be whether this returns from main at
// all -- there is nothing an in-process expect() could look at.
//
// Markers:
//   PORT_PROBE_DONE  -- reached the end, so the exit below is a real exit and
//                       not an early crash that would also have "not hung"
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final session = await Session.open(
    config: Config()
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );

  // Both kinds: the port is owned per subscriber regardless of kind, and a
  // close() that released one but not the other would still hang here.
  for (final kind in ChannelKind.values) {
    for (var i = 0; i < 5; i++) {
      session.declarePullSubscriber(
          'zenoh/dart/own/pull/port',
          kind: kind,
          capacity: 2,
        )
        ..tryRecv()
        ..close();
    }
  }

  session.close();
  stdout.writeln('PORT_PROBE_DONE');
}
