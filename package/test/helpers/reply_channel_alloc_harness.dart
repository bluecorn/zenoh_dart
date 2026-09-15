// Live-fire leg for seed #6: `zd_get_channel`'s own allocation failure.
//
// Run as a SUBPROCESS under the LD_PRELOAD injector, whose threshold is set low
// enough to catch the tee context (a few dozen bytes). The injector only fails
// mallocs whose CALLER is libzenoh_dart.so, so canon's allocator is untouched
// and the only NULL in the process is the one under test.
//
// Markers:
//   HARNESS_THREW=ZenohException code=<rc>  -- the guard converted the NULL
//   HARNESS_OK                              -- pullGet succeeded (no injection)
//   HARNESS_DONE                            -- reached the end, so an exit code
//                                              of 0 is a real exit
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final session = await Session.open(
    config: Config()
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );

  try {
    final replies = session.pullGet(
      'zenoh/dart/harness/alloc',
      kind: ChannelKind.fifo,
      capacity: 4,
    );
    stdout.writeln('HARNESS_OK');
    replies.dispose();
  } on ZenohException catch (e) {
    stdout.writeln('HARNESS_THREW=ZenohException code=${e.returnCode}');
  }

  session.close();
  stdout.writeln('HARNESS_DONE');
}
