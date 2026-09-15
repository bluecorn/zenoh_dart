import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/**';

const helpText =
    '''
    Usage: z_advanced_sub [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to subscribe to
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring AdvancedSubscriber on '$keyExpr'...");
  final subscriber = session.declareAdvancedSubscriber(
    keyExpr,
    options: const AdvancedSubscriberOptions(
      history: true,
      detectLatePublishers: true,
      recovery: true,
      lastSampleMissDetection: true,
      // canon deliberately leaves periodic queries OFF and recovers from the
      // publisher's heartbeats instead (z_advanced_sub.c:72-73 -- the line is
      // present but commented out). Setting it here would demonstrate the
      // other recovery mode, and zenoh-c documents periodic queries as
      // useless when the publication period is at or below the query period,
      // which is exactly the paired z_advanced_pub's regime.
      subscriberDetection: true,
      enableMissListener: true,
    ),
  );

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  // Listen for samples and print them
  final streamSubscription = subscriber.stream.listen((sample) {
    final kindStr = sample.kind == SampleKind.put ? 'PUT' : 'DELETE';
    print(
      ">> [Subscriber] Received $kindStr ('${sample.keyExpr}': "
      "'${sample.payload}')",
    );
  });

  // Listen for miss events if available
  StreamSubscription<MissEvent>? missSubscription;
  if (subscriber.missEvents != null) {
    missSubscription = subscriber.missEvents!.listen((event) {
      print(
        '>> [Subscriber] Missed ${event.count} samples from '
        "'${event.sourceId.zid.toHexString()}' !!!",
      );
    });
  }

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
  await streamSubscription.cancel();
  await missSubscription?.cancel();
  subscriber.close();
  session.close();
}
