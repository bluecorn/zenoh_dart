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
    Usage: z_queryable_with_channels [OPTIONS]

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

  print("Declaring Queryable on '$keyExpr'...");
  // canon uses `z_fifo_channel_query_new(&closure, &handler, 16)` and hands the
  // closure to `z_declare_queryable`. Here that is one call.
  final queryable = session.declarePullQueryable(
    keyExpr,
    kind: ChannelKind.fifo,
    capacity: 16,
    complete: complete,
  );

  print('Press CTRL-C to quit...');

  // canon's loop is `while (z_recv(z_loan(handler), &oquery) == Z_OK)`: a
  // BLOCKING receive that ends when the channel disconnects. Ours is the async
  // `recv()`, which is the same contract without parking a thread — and the
  // switch is exhaustive with no `default`, so the terminal arm is the loop's
  // exit rather than a condition someone has to remember to write.
  final done = Completer<void>();
  unawaited(() async {
    loop:
    while (true) {
      switch (await queryable.recv()) {
        case RecvData(:final value):
          final queryPayload = value.payloadBytes;
          final received =
              '>> [Queryable ] Received Query '
              "'${value.keyExpr}?${value.parameters}'";
          if (queryPayload != null && queryPayload.isNotEmpty) {
            final v = utf8.decode(queryPayload, allowMalformed: true);
            print("$received with value '$v'");
          } else {
            print(received);
          }
          print(">> [Queryable ] Responding ('$keyExpr': '$payload')");
          value
            ..reply(keyExpr, payload)
            ..dispose();
        case RecvEmpty():
          // Contractually unreachable: `recv()` waits rather than reporting an
          // empty buffer. The arm exists because the result type is shared with
          // `tryRecv`, and writing it out keeps the switch exhaustive without a
          // `default` that would also swallow a future variant.
          continue loop;
        case RecvDisconnected():
          break loop;
      }
    }
    if (!done.isCompleted) done.complete();
  }());

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });

  await done.future;

  await sigintSub.cancel();
  await sigtermSub.cancel();
  // Drain before you close: queries still buffered are released with the
  // channel, and a query already taken must be replied to before this.
  queryable.close();
  session.close();
}
