// Live-fire leg for the offloaded open's START-FAILURE arm.
//
// `zd_open_session_async`'s return means "did it START", never "did it
// succeed". A non-zero return means nothing ran and NO post is coming, so Dart
// must throw rather than await a completion that can never arrive. This harness
// makes that observable from outside the process.
//
// Run as a SUBPROCESS. Every cell here must be a bounded subprocess: a start
// failure that instead hung would hang the parent too, and no in-isolate
// deadline can fire against it.
//
// ⛔ SYNCHRONICITY IS THE POINT, so `Session.open` is called WITHOUT `await`
// inside the try. `open` is deliberately not an `async` body, so a start
// failure throws right at the call -- before any future exists. If the throw
// were asynchronous this try would not catch it and the marker would change.
//
// ⛔ IT MUST NOT CALL exit(). shim_alloc_counter.c reports from an
// __attribute__((destructor)); exiting early skips it and the leg would read
// `allocs=0` -- a zero indistinguishable from a clean run.
//
// Markers:
//   HARNESS_SYNC_THREW code=<rc>   a start failure, thrown synchronously
//   HARNESS_OPENED                 the open succeeded (no injection)
//   HARNESS_FUTURE_FAILED code=..  canon failed AFTER a successful start
//   HARNESS_DONE <n>               reached the end, so exit 0 is a real exit
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main(List<String> args) async {
  final iterations = args.isEmpty ? 1 : int.parse(args[0]);

  for (var i = 0; i < iterations; i++) {
    Future<Session>? pending;
    try {
      // NO await: a start failure must surface here, synchronously.
      pending = Session.open(
        config: Config()
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
    } on ZenohException catch (e) {
      stdout.writeln('HARNESS_SYNC_THREW code=${e.returnCode}');
      continue;
    }

    // The start succeeded, so exactly one post is contracted to arrive.
    try {
      final session = await pending;
      stdout.writeln('HARNESS_OPENED');
      session.close();
    } on ZenohException catch (e) {
      stdout.writeln('HARNESS_FUTURE_FAILED code=${e.returnCode}');
    }
  }

  stdout.writeln('HARNESS_DONE $iterations');
}
