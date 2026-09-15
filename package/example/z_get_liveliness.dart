import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'group1/**';
const defaultTimeoutMs = 10000;

const helpText =
    '''
    Usage: z_get_liveliness [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to query
        -o, --timeout <TIMEOUT_MS> (optional, number, default = '$defaultTimeoutMs'): Query timeout in milliseconds
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('timeout', abbr: 'o', defaultsTo: '$defaultTimeoutMs');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final timeoutMs = parseIntArg(results.option('timeout')!);
  final config = buildConfig(results);

  // Validate key expression before opening session (matches C reference).
  try {
    KeyExpr(keyExpr).dispose();
  } on ZenohException {
    print('$keyExpr is not a valid key expression');
    exit(canonFailureExit);
  }

  print('Opening session...');
  final session = await openSession(config);

  print("Sending liveliness query '$keyExpr'...");

  try {
    final stream = session.livelinessGet(
      keyExpr,
      timeout: Duration(milliseconds: timeoutMs),
    );

    await for (final reply in stream) {
      if (reply.isOk) {
        print(">> Alive token ('${reply.ok.keyExpr}')");
      } else {
        print('Received an error');
      }
    }
  } on ZenohException catch (e) {
    stderr.writeln('Error: $e');
    session.close();
    exit(canonFailureExit);
  }

  session.close();
}
