import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultSamples = 10;
const defaultMessages = 1000000;

const helpText =
    '''
    Usage: z_sub_thr [OPTIONS]

    Options:
        -s, --samples <MESUREMENTS> (optional, number, default='$defaultSamples'): Number of throughput measurements.
        -n, --number <NUM_MESSAGES> (optional, number, default='$defaultMessages'): Number of messages in each throughput measurements.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('samples', abbr: 's', defaultsTo: '$defaultSamples')
    ..addOption('number', abbr: 'n', defaultsTo: '$defaultMessages');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final maxRounds = parseIntArg(results.option('samples')!);
  final messagesPerRound = parseIntArg(results.option('number')!);
  final config = buildConfig(results)
    ..insertJson5('transport/shared_memory/enabled', 'true');

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Background Subscriber on 'test/thr'...");
  final bgStream = session.declareBackgroundSubscriber('test/thr');

  var count = 0;
  var finishedRounds = 0;
  var started = false;
  late Stopwatch roundStopwatch;
  late Stopwatch totalStopwatch;

  final exitCompleter = Completer<void>();

  final subscription = bgStream.listen((_) {
    if (count == 0) {
      roundStopwatch = Stopwatch()..start();
      if (!started) {
        totalStopwatch = Stopwatch()..start();
        started = true;
      }
      count++;
    } else if (count < messagesPerRound) {
      count++;
    } else {
      finishedRounds++;
      roundStopwatch.stop();
      final elapsedMs = roundStopwatch.elapsedMicroseconds / 1000.0;
      final throughput = 1000.0 * messagesPerRound / elapsedMs;
      print('${throughput.toStringAsFixed(6)} msg/s');
      count = 0;
      if (finishedRounds > maxRounds) {
        if (!exitCompleter.isCompleted) exitCompleter.complete();
      }
    }
  });

  print('Press CTRL-C to quit...');
  await exitCompleter.future;

  await subscription.cancel();
  totalStopwatch.stop();

  final totalMessages = messagesPerRound * finishedRounds + count;
  final elapsedSeconds = totalStopwatch.elapsedMicroseconds / 1000000.0;
  final overallThroughput = totalMessages / elapsedSeconds;
  print(
    'sent $totalMessages messages over ${elapsedSeconds.toStringAsFixed(6)} seconds (${overallThroughput.toStringAsFixed(6)} msg/s)',
  );

  session.close();
  exit(0);
}
