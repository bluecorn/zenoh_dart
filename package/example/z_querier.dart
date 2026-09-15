import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultSelector = 'demo/example/**';
const defaultTimeoutMs = 10000;

const helpText =
    '''
    Usage: z_querier [OPTIONS]

    Options:
        -s, --selector <SELECTOR> (optional, string, default='$defaultSelector'): The selection of resources to query
        -p, --payload <PAYLOAD> (optional, string): An optional value to put in the query
        -t, --target <TARGET> (optional, BEST_MATCHING | ALL | ALL_COMPLETE): Query target
        -o, --timeout <TIMEOUT_MS> (optional, number, default = '$defaultTimeoutMs'): Query timeout in milliseconds
        --add-matching-listener (optional): Add matching listener
''';

void _printReply(Reply reply) {
  if (reply.isOk) {
    print(">> Received ('${reply.ok.keyExpr}': '${reply.ok.payload}')");
  } else {
    print(">> Received (ERROR: '${reply.error.payload}')");
  }
}

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('selector', abbr: 's', defaultsTo: defaultSelector)
    ..addOption('payload', abbr: 'p')
    ..addOption('target', abbr: 't', defaultsTo: 'BEST_MATCHING')
    ..addOption('timeout', abbr: 'o', defaultsTo: '$defaultTimeoutMs')
    ..addFlag('add-matching-listener', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final selector = results.option('selector')!;
  final payloadStr = results.option('payload');
  final target = parseQueryTarget(results.option('target')!);
  final timeoutMs = parseIntArg(results.option('timeout')!);
  final addMatchingListener = results.flag('add-matching-listener');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  // Split selector at '?' into key expression and parameters
  var keyExpr = selector;
  String? parameters;
  final qIndex = selector.indexOf('?');
  if (qIndex >= 0) {
    keyExpr = selector.substring(0, qIndex);
    parameters = selector.substring(qIndex + 1);
  }

  print("Declaring Querier on '$keyExpr'...");
  final querier = session.declareQuerier(
    keyExpr,
    target: target,
    // canon's `-o 0` means "use the configured default query timeout"
    // (z_get_options_t.timeout_ms == 0), and this binding spells that
    // `timeout: null` -- it refuses a zero Duration precisely so the sentinel
    // cannot be passed as if it were a value. So the example TRANSLATES canon's
    // sentinel rather than forwarding it; forwarding it would turn a
    // canon-valid flag value into an uncaught ArgumentError.
    timeout: timeoutMs == 0 ? null : Duration(milliseconds: timeoutMs),
    enableMatchingListener: addMatchingListener,
  );

  if (addMatchingListener) {
    querier.matchingStatus!.listen((matching) {
      if (matching) {
        print('Querier has matching queryables.');
      } else {
        print('Querier has NO MORE matching queryables.');
      }
    });
  }

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  // canon (z_querier.c:92-132) is strictly serial: sleep, issue one query,
  // drain its replies to completion, then advance the index. A fixed-rate
  // timer instead lets queries overlap whenever a drain outlasts the interval
  // -- roughly ten in flight at the default timeout with no responder -- and
  // makes the printed sequence numbers repeat.
  var idx = 0;
  while (!completer.isCompleted) {
    await Future.any([
      Future<void>.delayed(const Duration(seconds: 1)),
      completer.future,
    ]);
    if (completer.isCompleted) break;

    final buf = '[${idx.toString().padLeft(4)}] ${payloadStr ?? ''}';
    print("Querying '$selector' with payload '$buf'...");

    final zbytes = payloadStr != null ? ZBytes.fromString(buf) : null;
    final stream = querier.get(payload: zbytes, parameters: parameters);

    final replySub = stream.listen(_printReply);
    await Future.any([replySub.asFuture<void>(), completer.future]);
    await replySub.cancel();

    idx++;
  }

  await sigintSub.cancel();
  await sigtermSub.cancel();
  querier.close();
  session.close();
}
