import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-queryable';
const defaultPayload = 'Queryable from Dart SHM!';

/// Canon's pool here is 4096 (z_queryable_shm.c:113), used exactly.
///
/// This constant used to be 65536, on the measured-false claim that pools
/// below 64 KiB are rejected. They are not: canon's own 4096
/// satisfies a reply payload of this size with room to spare, which the cells
/// in `package/test/shm_alloc_strategy_test.dart` drive directly and the
/// committed sweep at `development/research/probes-seed7-pool-floor-20260819/`
/// measures across the range.
const shmPoolSize = 4096; // canon's own, z_queryable_shm.c:113

const helpText =
    '''
    Usage: z_queryable_shm [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression matching queries to reply to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultPayload'): The value to reply to queries with
        --complete (optional, flag to indicate whether queryable is complete or not)
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultPayload)
    ..addFlag('complete', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final payload = results.option('payload')!;
  final complete = results.flag('complete');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print('Creating POSIX SHM Provider...');
  final provider = ShmProvider(size: shmPoolSize);

  print("Declaring Queryable on '$keyExpr'...");
  final queryable = session.declareQueryable(keyExpr, complete: complete);

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  Future<void> handleQuery(Query query) async {
    // canon (z_queryable_shm.c:46-58) tags the received payload `[SHM]` or
    // `[RAW]` from `z_bytes_as_loaned_shm`, and `Query.payloadZBytes` is what
    // makes the same two-state tag reachable here: it hands back the retained
    // `ZBytes` that `isShmBacked` reads, with no opt-in flag. (Canon's
    // three-state RAW/UNKNOWN/SHM(MUT|IMMUT) rendering is `z_sub_shm.c`'s and
    // is deliberately out of scope.)
    //
    // The handle is OURS to release: `query.dispose()` below does not take it.
    final queryPayload = query.payloadZBytes;
    final received =
        '>> [Queryable ] Received Query '
        "'${query.keyExpr}?${query.parameters}'";
    if (queryPayload == null) {
      print(received);
    } else {
      final payloadBytes = queryPayload.toBytes();
      if (payloadBytes.isEmpty) {
        print(received);
      } else {
        // Tagged before the text is read, as canon does.
        final backing = queryPayload.isShmBacked ? 'SHM' : 'RAW';
        final value = utf8.decode(payloadBytes, allowMalformed: true);
        print("$received with value '$value' [$backing]");
      }
      queryPayload.dispose();
    }

    print('Allocating Shared Memory Buffer...');
    final encodedBytes = utf8.encode(payload);
    // ⛔ DELIBERATE DIVERGENCE FROM CANON, AND IT IS FORCED. Canon calls the
    // BLOCKING allocator here (z_queryable_shm.c:67); this calls the async
    // sibling.
    //
    // `allocGcDefragBlocking` is synchronous FFI, so it blocks the ISOLATE
    // and not merely a thread: no await point, no timeout, no cancellation.
    // On a request the pool can never satisfy it never returns -- and a reply
    // payload simply larger than the pool is enough to reach that, which is a
    // `-p` away here.
    //
    // ▶ THE GROUND IS A DART-SIDE ASYMMETRY, NOT TASTE. Canon installs no
    // signal handler, so SIGINT keeps its default disposition and kills it
    // even mid-allocation. This example installs one, and it lives on the
    // event loop the blocking call would freeze -- so the process would stop
    // answering Ctrl-C entirely. Faithfulness to canon's CALL would be
    // infidelity to canon's BEHAVIOUR.
    //
    // ⚠️ EXPOSURE IS GRADED, and this file is at the high end: it
    // allocates once per query, on input a peer chooses the timing of.
    // `z_pub_shm_thr` and `z_ping_shm` allocate once at startup -- a narrower
    // window, and not a harmless one.
    //
    // The async sibling does not make an impossible request possible; what
    // moves is WHO waits. The full hazard table stays on
    // `allocGcDefragBlocking`'s own dartdoc and is not restated here.
    final AllocResult result;
    try {
      result = await provider.allocGcDefragAsync(encodedBytes.length);
    } on ZenohException catch (error) {
      // Shutdown closed the provider while this request was outstanding, and
      // close() ANSWERS it rather than abandoning it. There is nothing left
      // to reply with, and the queryable is going away.
      print('SHM allocation ended with the provider: ${error.message}');
      query.dispose();
      return;
    }

    switch (result) {
      case AllocOk(:final buffer):
        buffer.write(encodedBytes);
        print(">> [Queryable] Responding ('$keyExpr': '$payload')...");
        final zbytes = buffer.toBytes();
        query.replyBytes(keyExpr, zbytes);
        zbytes.dispose();
        buffer.dispose();
      case AllocError():
      case LayoutError():
        // canon aborts instead; degrading keeps the demo answering, and the
        // warning is what the paired CLI test asserts the absence of.
        print('Warning: SHM buffer allocation failed, replying with raw bytes');
        query.reply(keyExpr, payload);
    }

    query.dispose();
  }

  // ⛔ ONE IN-FLIGHT ALLOCATION PER PROVIDER, so the queries are served ONE AT
  // A TIME: a second `allocGcDefragAsync` while one is pending throws. Queries
  // arrive at a rate this example does not control, so the subscription is
  // paused for the duration of each handler -- `StreamSubscription.pause`
  // takes exactly that resume signal, and queries arriving meanwhile are
  // buffered rather than dropped.
  late final StreamSubscription<Query> streamSubscription;
  streamSubscription = queryable.stream.listen((query) {
    streamSubscription.pause(handleQuery(query));
  });

  // Handle SIGINT and SIGTERM for clean shutdown
  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  await completer.future;

  await sigintSub.cancel();
  await sigtermSub.cancel();
  // ⭐ THE PROVIDER GOES FIRST, and the order is the whole of it: a handler
  // parked on an allocation the pool cannot answer is woken by this close(),
  // which answers its request rather than abandoning it. Closing the
  // queryable or the session first would leave that handler waiting on
  // something nothing will ever complete.
  provider.close();
  // ...and it is given a turn to finish, because it holds a Query and
  // disposing that is its job.
  await Future<void>.delayed(Duration.zero);
  await streamSubscription.cancel();
  queryable.close();
  session.close();
}
