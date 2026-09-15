import 'dart:async';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultSamples = 100;
const defaultWarmup = 1000;

const helpText =
    '''
    Usage: z_ping [OPTIONS] <PAYLOAD_SIZE>

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

  // Build payload
  final payload = Uint8List(payloadSize);
  for (var i = 0; i < payloadSize; i++) {
    payload[i] = i % 10;
  }

  // Warmup phase
  if (warmup > 0) {
    print('Warming up for ${warmup}ms...');
    final warmupStop = Stopwatch()..start();
    while (warmupStop.elapsedMilliseconds < warmup) {
      pongCompleter = Completer<void>();
      publisher.putBytes(ZBytes.fromUint8List(payload));
      await pongCompleter.future;
    }
    warmupStop.stop();
  }

  // Measurement phase
  final rtts = List<int>.filled(samples, 0);
  for (var i = 0; i < samples; i++) {
    pongCompleter = Completer<void>();
    // canon (z_ping.c:96-98) builds the payload BEFORE starting the clock, so
    // the native allocation and copy stay outside the measured window. Timing
    // them inflates every sample by a payload-size-dependent cost that no
    // other binding pays, which is exactly what breaks cross-binding
    // comparability. (z_ping_shm deliberately keeps its clone inside the
    // window -- there the clone is the operation under test.)
    final zbytes = ZBytes.fromUint8List(payload);
    final stopwatch = Stopwatch()..start();
    publisher.putBytes(zbytes);
    await pongCompleter.future;
    stopwatch.stop();
    rtts[i] = stopwatch.elapsedMicroseconds;
  }

  // canon prints the collected results after the loop, keeping stdout I/O out
  // from between measured pings.
  for (var i = 0; i < samples; i++) {
    print('$payloadSize bytes: seq=$i rtt=${rtts[i]}µs, lat=${rtts[i] ~/ 2}µs');
  }

  await streamSubscription.cancel();
  publisher.close();
  session.close();
}
