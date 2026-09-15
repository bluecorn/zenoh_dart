import 'dart:async';
import 'dart:io';
import 'dart:math' show max;

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultSamples = 100;
const defaultWarmup = 1000;

/// Canon sizes the pool at exactly `<PAYLOAD_SIZE>` (z_ping_shm.c:74), which
/// can never be satisfied: a pool needs a constant per-allocation headroom
/// above what is allocated from it, so a pool sized to its own allocation is
/// always one allocation short. Measured by the committed sweep at
/// `development/research/probes-seed7-pool-floor-20260819/`.
///
/// The deviation is therefore forced, and it is `max(2N, 4096)` -- double the
/// payload, with canon's own 4096-byte example pool as the floor for small
/// ones. The previous `max(N, 65536)` rested on a measured-false claim that
/// pools below 64 KiB are rejected, and it stopped protecting anything at all
/// once the payload passed 64 KiB.
const shmPoolFloor = 4096;

const helpText =
    '''
    Usage: z_ping_shm [OPTIONS] <PAYLOAD_SIZE>

    Arguments:
        <PAYLOAD_SIZE> (required, number): Size of the payload to publish

    Options:
        -n, --samples <SAMPLES> (optional, int, default=$defaultSamples): The number of pings to be attempted
        -w, --warmup <WARMUP> (optional, int, default=$defaultWarmup): The warmup time in ms during which pings will be emitted but not measured
        --no-express (optional): Disable message batching.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('samples', abbr: 'n', defaultsTo: '$defaultSamples')
    ..addOption('warmup', abbr: 'w', defaultsTo: '$defaultWarmup')
    ..addFlag('no-express', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  final payloadSize = requirePositionalSize(results, '<PAYLOAD_SIZE>');

  final samples = parseIntArg(results.option('samples')!);
  final warmup = parseIntArg(results.option('warmup')!);
  final noExpress = results.flag('no-express');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  // canon: pool size == payload size, with no multiplier.
  final poolSize = max(payloadSize * 2, shmPoolFloor);
  print('Creating SHM Provider (pool size: $poolSize bytes)...');
  final provider = ShmProvider(size: poolSize);

  print("Declaring Publisher on 'test/ping'...");
  final publisher = session.declarePublisher(
    'test/ping',
    isExpress: !noExpress,
  );

  print("Declaring Background Subscriber on 'test/pong'...");
  final bgStream = session.declareBackgroundSubscriber('test/pong');

  var pongCompleter = Completer<void>();
  final streamSubscription = bgStream.listen((_) {
    if (!pongCompleter.isCompleted) pongCompleter.complete();
  });

  // Allocate SHM buffer once, fill with payload pattern
  print('Allocating SHM buffer ($payloadSize bytes)...');
  // ⛔ DELIBERATE DIVERGENCE, AND CANON'S CALL HERE IS NEITHER OF THE TWO.
  // canon uses the PLAIN, non-waiting entry (`z_shm_provider_alloc`,
  // z_ping_shm.c:78), which reports out-of-memory instead of waiting. This
  // example used `allocGcDefragBlocking` -- a divergence that predates this
  // note -- and now uses the async sibling, which keeps the
  // garbage-collect-then-defragment retry while never freezing the isolate.
  //
  // ▶ THE GROUND IS A DART-SIDE ASYMMETRY. `allocGcDefragBlocking` is
  // synchronous FFI: it blocks the ISOLATE, and on a request the pool can
  // never satisfy it never returns. Nothing on that event loop runs again --
  // no timer, no signal handler where one is installed. Canon installs none,
  // so SIGINT keeps its default disposition and still kills it while parked.
  //
  // ⚠️ EXPOSURE IS GRADED, and this file is at the low end: it
  // allocates once at startup, before the measured loop, so the window in
  // which the hazard can be reached is one call wide. `z_pub_shm` allocates
  // once per publish iteration. Narrow is not harmless: reached, it is still
  // a process nothing short of SIGKILL can end.
  //
  // The full hazard table stays on `allocGcDefragBlocking`'s own dartdoc,
  // where a caller meets it, and is not restated here.
  final result = await provider.allocGcDefragAsync(payloadSize);
  final ShmMutBuffer buffer;
  switch (result) {
    case AllocOk(buffer: final allocated):
      buffer = allocated;
    case AllocError(:final Enum kind):
    case LayoutError(:final Enum kind):
      print('Unexpected failure during SHM buffer allocation: $kind');
      publisher.close();
      provider.close();
      session.close();
      exit(canonFailureExit);
  }

  buffer.write(List<int>.generate(payloadSize, (i) => i % 10));

  // Convert to ZBytes once -- clone in the loop (zero-copy)
  final shmBytes = buffer.toBytes();

  // Warmup phase
  if (warmup > 0) {
    print('Warming up for ${warmup}ms...');
    final warmupStop = Stopwatch()..start();
    while (warmupStop.elapsedMilliseconds < warmup) {
      pongCompleter = Completer<void>();
      publisher.putBytes(shmBytes.clone());
      await pongCompleter.future;
    }
    warmupStop.stop();
  }

  // Measurement phase. canon (z_ping_shm.c:117-120) starts the clock BEFORE
  // the clone: here the ref-counted clone is the operation shared memory
  // exists to make cheap, so it belongs inside the measured window.
  final rtts = List<int>.filled(samples, 0);
  for (var i = 0; i < samples; i++) {
    pongCompleter = Completer<void>();
    final stopwatch = Stopwatch()..start();
    publisher.putBytes(shmBytes.clone());
    await pongCompleter.future;
    stopwatch.stop();
    rtts[i] = stopwatch.elapsedMicroseconds;
  }

  for (var i = 0; i < samples; i++) {
    print('$payloadSize bytes: seq=$i rtt=${rtts[i]}µs, lat=${rtts[i] ~/ 2}µs');
  }

  await streamSubscription.cancel();
  shmBytes.dispose();
  buffer.dispose();
  publisher.close();
  provider.close();
  session.close();
}
