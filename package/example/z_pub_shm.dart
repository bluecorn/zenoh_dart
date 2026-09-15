import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-pub-shm';
const defaultValue = 'Pub from Dart!';

/// Canon's pool is 4096 and its per-iteration buffer `total_size / 4` = 1024
/// (z_pub_shm.c:70-71). Both are used here **exactly as canon writes them** --
/// this example carries no deviation at all.
///
/// It used to carry one, on a rationale that was measured false: the comment
/// here claimed that pools below 64 KiB are rejected, so the pool was clamped
/// to 65536 and the pool:buffer ratio came out at 64:1 instead of canon's
/// 4:1. There is no such limit. The measured construction floor is
/// three orders of magnitude smaller, and canon's own 4096 satisfies canon's
/// own 1024 -- driven, not argued, by the cells in
/// `package/test/shm_alloc_strategy_test.dart` and the committed sweep at
/// `development/research/probes-seed7-pool-floor-20260819/`.
///
/// ⚠️ These two numbers are also what keeps the publish loop's allocation
/// answerable at all: 1024 fits in 4096, every iteration. A request the pool
/// can never satisfy is accepted and never answered -- see the divergence
/// note at the allocation below before changing either of them.
const shmTotalSize = 4096; // canon's own, z_pub_shm.c:70
const shmBufOkSize = 1024; // canon's total_size / 4, z_pub_shm.c:71

const helpText =
    '''
    Usage: z_pub_shm [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to write to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultValue'): The value to write
        --add-matching-listener (optional): Add matching listener
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultValue)
    ..addFlag('add-matching-listener', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final value = results.option('payload')!;
  final addMatchingListener = results.flag('add-matching-listener');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Publisher on '$keyExpr'...");
  final publisher = session.declarePublisher(
    keyExpr,
    enableMatchingListener: addMatchingListener,
  );

  if (addMatchingListener) {
    publisher.matchingStatus!.listen((matching) {
      if (matching) {
        print('Publisher has matching subscribers.');
      } else {
        print('Publisher has NO MORE matching subscribers.');
      }
    });
  }

  print('Creating POSIX SHM Provider...');
  final provider = ShmProvider(size: shmTotalSize);

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  var shuttingDown = false;
  void shutdown() {
    // Reachable twice: once from an allocation failure, once from a signal
    // arriving afterwards. Every close() below is idempotent, but an example
    // people copy should not lean on three separate idempotence contracts.
    if (shuttingDown) return;
    shuttingDown = true;
    unawaited(sigintSub.cancel());
    unawaited(sigtermSub.cancel());
    publisher.close();
    // ⭐ This is also what ends a publish that is waiting on an allocation
    // the pool cannot answer: close() ANSWERS an outstanding async request
    // rather than abandoning it, and the loop below catches that answer.
    provider.close();
    session.close();
  }

  unawaited(completer.future.then((_) => shutdown()));

  var idx = 0;
  while (!shuttingDown) {
    // canon sleeps at the TOP of its loop (z_pub_shm.c:76-77), before the
    // allocation, and so does this.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (shuttingDown) break;

    // canon (z_pub_shm.c:76-95) allocates a fixed buffer every iteration,
    // sprintf's the message into its front, and publishes the WHOLE buffer --
    // residual bytes included. Sizing the allocation to the message instead
    // would demonstrate a different thing.
    //
    // ⛔ DELIBERATE DIVERGENCE FROM CANON, AND IT IS FORCED. Canon calls the
    // BLOCKING allocator here (z_pub_shm.c:80); this calls the async sibling.
    //
    // `allocGcDefragBlocking` is synchronous FFI, so it blocks the ISOLATE
    // and not merely a thread: no await point, no timeout, no cancellation.
    // On a request the pool can never satisfy it does not give up -- and a
    // size simply larger than the pool is enough to reach that. The releases
    // that could rescue it run on the very event loop it has frozen.
    //
    // ▶ THE GROUND IS A DART-SIDE ASYMMETRY, NOT TASTE.
    // Canon installs no signal handler, so SIGINT keeps its default
    // disposition and still kills the process while its allocation is parked.
    // This example installs one -- which is exactly what makes a frozen event
    // loop swallow Ctrl-C, so its own "Press CTRL-C to quit" would stop being
    // true. Faithfulness to canon's CALL would be infidelity to canon's
    // BEHAVIOUR.
    //
    // ⚠️ EXPOSURE IS GRADED, and this file is at the high end: it
    // allocates once per publish iteration, so every second is another chance
    // to reach the hazard. `z_pub_shm_thr` and `z_ping_shm` allocate once at
    // startup -- a much shorter window, and still an unkillable process if it
    // is reached.
    //
    // ⚠️ The async sibling does not make an impossible request possible: it
    // is accepted and never answered, exactly as before. What moves is WHO
    // waits -- canon holds the request, the event loop keeps turning, and the
    // signal handler above still runs. The full hazard table stays where a
    // caller meets it, on `allocGcDefragBlocking`'s own dartdoc, and is not
    // restated here. One request at a time per provider, which an awaited
    // loop satisfies by construction.
    final AllocResult result;
    try {
      result = await provider.allocGcDefragAsync(shmBufOkSize);
    } on ZenohException catch (error) {
      // Shutdown closed the provider while this request was outstanding.
      print('SHM allocation ended with the provider: ${error.message}');
      break;
    }

    final ShmMutBuffer buffer;
    switch (result) {
      case AllocOk(buffer: final allocated):
        buffer = allocated;
      case AllocError(:final Enum kind):
      case LayoutError(:final Enum kind):
        // canon breaks the publish loop here rather than warning and carrying
        // on: a run that never touched shared memory must not look healthy.
        // Unlike canon we can say WHICH outcome canon reported.
        print('Unexpected failure during SHM buffer allocation: $kind');
        shutdown();
        return;
    }

    final msg = '[${idx.toString().padLeft(4)}] $value';
    final encodedBytes = utf8.encode(msg);
    buffer.write(encodedBytes);
    print("Putting Data ('$keyExpr': '$msg')...");

    final zbytes = buffer.toBytes();
    publisher.putBytes(zbytes);
    zbytes.dispose();
    buffer.dispose();

    idx++;
  }
}
