import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/**';

const helpText =
    '''
    Usage: z_sub [OPTIONS]

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

  print("Declaring Subscriber on '$keyExpr'...");
  final subscriber = session.declareSubscriber(keyExpr);

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  // Listen for samples and print them
  final streamSubscription = subscriber.stream.listen((sample) {
    final kindStr = sample.kind == SampleKind.put ? 'PUT' : 'DELETE';
    // canon appends ` (<attachment>)` when the sample carries one
    // (z_sub.c:39-46).
    final attachment = sample.attachment;
    final suffix = attachment != null ? ' ($attachment)' : '';
    print(
      ">> [Subscriber] Received $kindStr ('${sample.keyExpr}': "
      "'${sample.payload}')$suffix",
    );
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
  await streamSubscription.cancel();
  subscriber.close();
  session.close();
}
