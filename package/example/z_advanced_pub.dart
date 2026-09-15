import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-pub';
const defaultValue = 'Pub from Dart!';
const defaultHistory = 1;

const helpText =
    '''
    Usage: z_advanced_pub [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to write to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultValue'): The value to write
        -i, --history <HISTORY_SIZE> (optional, string, default=$defaultHistory): The number of publications to keep in cache
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultValue)
    ..addOption('history', abbr: 'i', defaultsTo: '$defaultHistory');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final value = results.option('payload')!;
  final history = parseIntArg(results.option('history')!);
  final config = buildConfig(results)
    ..insertJson5('timestamping/enabled', 'true');

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring AdvancedPublisher on '$keyExpr'...");
  final publisher = session.declareAdvancedPublisher(
    keyExpr,
    options: AdvancedPublisherOptions(
      cache: AdvancedPublisherCacheOptions(maxSamples: history),
      publisherDetection: true,
      sampleMissDetection: true,
      heartbeatMode: HeartbeatMode.periodic,
      heartbeatPeriodMs: 500,
    ),
  );

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  var idx = 0;
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final payload = '[${idx.toString().padLeft(4)}] $value';
    print("Put Data ('$keyExpr': '$payload')...");
    publisher.put(payload);
    idx++;
  });

  await completer.future;

  timer.cancel();
  await sigintSub.cancel();
  await sigtermSub.cancel();
  publisher.close();
  session.close();
}
