import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-queryable';
const defaultPayload = 'Queryable from Dart!';

const helpText =
    '''
    Usage: z_queryable [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression matching queries to reply to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultPayload'): The value to reply to queries with
        --complete (optional): Indicates whether queryable is complete or not
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

  print("Declaring Queryable on '$keyExpr'...");
  final queryable = session.declareQueryable(keyExpr, complete: complete);

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  // Listen for queries and reply to them
  final streamSubscription = queryable.stream.listen((query) {
    // canon (z_queryable.c:41-53) prints the received query's payload when it
    // carries one, and the reply it is about to send.
    final queryPayload = query.payloadBytes;
    final received =
        '>> [Queryable ] Received Query '
        "'${query.keyExpr}?${query.parameters}'";
    if (queryPayload != null && queryPayload.isNotEmpty) {
      final value = utf8.decode(queryPayload, allowMalformed: true);
      print("$received with value '$value'");
    } else {
      print(received);
    }
    print(">> [Queryable ] Responding ('$keyExpr': '$payload')");
    query
      ..reply(keyExpr, payload)
      ..dispose();
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
  queryable.close();
  session.close();
}
