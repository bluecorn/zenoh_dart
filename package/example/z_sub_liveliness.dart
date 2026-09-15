import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'group1/**';

const helpText =
    '''
    Usage: z_sub_liveliness [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression matching liveliness tokens to subscribe to
        --history (optional): Get historical liveliness tokens.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addFlag('history', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final history = results.flag('history');
  final config = buildConfig(results);

  // canon validates the full key expression before opening the session
  // (z_sub_liveliness.c:48-51).
  try {
    KeyExpr(keyExpr).dispose();
  } on ZenohException {
    print('$keyExpr is not a valid key expression');
    exit(canonFailureExit);
  }

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Liveliness Subscriber on '$keyExpr'...");
  final subscriber = session.declareLivelinessSubscriber(
    keyExpr,
    history: history,
  );

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  final streamSubscription = subscriber.stream.listen((sample) {
    switch (sample.kind) {
      case SampleKind.put:
        print(
          ">> [LivelinessSubscriber] New alive token ('${sample.keyExpr}')",
        );
      case SampleKind.delete:
        print(">> [LivelinessSubscriber] Dropped token ('${sample.keyExpr}')");
    }
  });

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
