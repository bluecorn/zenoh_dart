// A queryable in ITS OWN PROCESS that answers each query twice, with a gap.
//
// Why a subprocess. The re-arm-on-spurious-wake rule can only be driven by an
// interleaved `tryRecv()` that takes an arriving value BEFORE the readiness
// ping is processed — and the only way to guarantee that ordering from Dart is
// a synchronous busy-poll with no `await` in it, so the event loop never runs
// and the port message is never delivered. That starves every in-process
// replier too, because a queryable's stream callback is itself an event-loop
// task: the test would busy-wait forever for a reply its own starvation is
// preventing. Seed #5's equivalent cell had a *synchronous* producer
// (`Session.put` is a plain FFI call) and needed none of this; the reply column
// has no synchronous producer, so the producer moves out of the isolate.
//
// Usage: paced_replier.dart <port> <keyexpr> <gapMs>
// Prints `PACER_READY` once the queryable is declared, then runs until killed.
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final key = args[1];
  final gapMs = int.parse(args[2]);

  final session = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );

  final held = <Query>[];
  final queryable = session.declareQueryable(key);
  queryable.stream.listen((query) async {
    query.reply(key, 'first');
    await Future<void>.delayed(Duration(milliseconds: gapMs));
    query.reply(key, 'second');
    // Held open, so the channel stays connected and the second reply is a
    // genuine later ARRIVAL rather than a drain of a completed query.
    held.add(query);
  });

  stdout.writeln('PACER_READY');
  // Never returns; the test kills the process.
  await Completer<void>().future;
}
