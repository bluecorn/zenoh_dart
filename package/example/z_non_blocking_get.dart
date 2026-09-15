import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultSelector = 'demo/example/**';
const defaultTimeoutMs = 10000;

const helpText =
    '''
    Usage: z_non_blocking_get [OPTIONS]

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

  // canon (z_non_blocking_get.c:38-44) splits the selector at '?' into a key
  // expression and a parameter string, then validates the key expression before
  // opening the session. '?' is not legal inside a key expression.
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
    exit(canonFailureExit);
  }

  print('Opening session...');
  final session = await openSession(config);

  print("Sending Query '$selector'...");

  // canon uses `z_fifo_channel_reply_new(&closure, &handler, 16)` and hands the
  // closure to `z_get`. Here that is one call: the channel mode of the get.
  final replies = session.pullGet(
    keyExpr,
    kind: ChannelKind.fifo,
    capacity: 16,
    parameters: parameters,
    payload: payloadStr != null ? ZBytes.fromString(payloadStr) : null,
    target: target,
    // canon's `-o 0` means "use the configured default query timeout"; this
    // binding spells that `timeout: null` and refuses a zero Duration, so the
    // example translates the sentinel rather than forwarding it.
    timeout: timeoutMs == 0 ? null : Duration(milliseconds: timeoutMs),
  );

  // canon's own loop shape: `while (try_recv(...) != Z_CHANNEL_DISCONNECTED)`,
  // sleeping 50 ms whenever the buffer is momentarily empty. The exit condition
  // is the DISCONNECTED arm — not a timer, and not a reply count — which is
  // exactly what the three-way discriminant exists to make expressible.
  //
  // No `default` arm: the switch is exhaustive over the sealed family, so a
  // future variant would be a compile error rather than a silent fall-through.
  loop:
  while (true) {
    switch (replies.tryRecv()) {
      case RecvData(:final value):
        if (value.isOk) {
          print(">> Received ('${value.ok.keyExpr}': '${value.ok.payload}')");
        } else {
          print('Received an error');
        }
      case RecvEmpty():
        await Future<void>.delayed(const Duration(milliseconds: 50));
      case RecvDisconnected():
        break loop;
    }
  }

  replies.dispose();
  session.close();
}
