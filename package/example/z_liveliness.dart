import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'group1/zenoh-dart';

const helpText =
    '''
    Usage: z_liveliness [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression for the liveliness token
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

  // canon validates the full key expression before opening the session
  // (z_liveliness.c:34-37); an emptiness check alone lets a syntactically
  // invalid expression through to a post-open throw.
  try {
    KeyExpr(keyExpr).dispose();
  } on ZenohException {
    print('$keyExpr is not a valid key expression');
    exit(canonFailureExit);
  }

  print('Opening session...');
  final session = await openSession(config);

  final token = session.declareLivelinessToken(keyExpr);
  print("Liveliness token declared on '$keyExpr'");
  print('Press CTRL-C to undeclare token and quit...');

  final completer = Completer<void>();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  await completer.future;

  await sigintSub.cancel();
  await sigtermSub.cancel();
  token.close();
  session.close();
}
