import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultSelector = 'demo/example/**';
const defaultTimeoutMs = 10000;

const helpText =
    '''
    Usage: z_get [OPTIONS]

    Options:
        -s, --selector <SELECTOR> (optional, string, default='$defaultSelector'): The selection of resources to query
        -p, --payload <PAYLOAD> (optional, string): An optional value to put in the query
        -t, --target <TARGET> (optional, BEST_MATCHING | ALL | ALL_COMPLETE): Query target
        -o, --timeout <TIMEOUT_MS> (optional, number, default = '$defaultTimeoutMs'): Query timeout in milliseconds
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('selector', abbr: 's', defaultsTo: defaultSelector)
    ..addOption('payload', abbr: 'p')
    ..addOption('target', abbr: 't', defaultsTo: 'BEST_MATCHING')
    ..addOption('timeout', abbr: 'o', defaultsTo: '$defaultTimeoutMs');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final selector = results.option('selector')!;
  final payloadStr = results.option('payload');
  final target = parseQueryTarget(results.option('target')!);
  final timeoutMs = parseIntArg(results.option('timeout')!);
  final config = buildConfig(results);

  // canon (z_get.c:38-51) splits the selector at '?' into a key expression and
  // a parameter string, then validates the key expression before opening the
  // session. '?' is not legal inside a key expression, so passing the whole
  // selector through would reject every parameterised query.
  var keyExpr = selector;
  String? parameters;
  final qIndex = selector.indexOf('?');
  if (qIndex >= 0) {
    keyExpr = selector.substring(0, qIndex);
    parameters = selector.substring(qIndex + 1);
  }

  try {
    KeyExpr(keyExpr).dispose();
  } on ZenohException {
    print('$keyExpr is not a valid key expression');
    exit(255);
  }

  print('Opening session...');
  final session = await openSession(config);

  print("Sending Query '$selector'...");

  final zbytes = payloadStr != null ? ZBytes.fromString(payloadStr) : null;

  final stream = session.get(
    keyExpr,
    parameters: parameters,
    payload: zbytes,
    target: target,
    // canon's `-o 0` means "use the configured default query timeout"
    // (z_get_options_t.timeout_ms == 0), and this binding spells that
    // `timeout: null` -- it refuses a zero Duration precisely so the sentinel
    // cannot be passed as if it were a value. So the example TRANSLATES canon's
    // sentinel rather than forwarding it; forwarding it would turn a
    // canon-valid flag value into an uncaught ArgumentError.
    timeout: timeoutMs == 0 ? null : Duration(milliseconds: timeoutMs),
  );

  await for (final reply in stream) {
    if (reply.isOk) {
      print(">> Received ('${reply.ok.keyExpr}': '${reply.ok.payload}')");
    } else {
      print(">> Received (ERROR: '${reply.error.payload}')");
    }
  }

  session.close();
}
