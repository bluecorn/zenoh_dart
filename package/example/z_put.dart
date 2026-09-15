import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-put';
const defaultValue = 'Put from Dart!';

const helpText =
    '''
    Usage: z_put [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to write to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultValue'): The value to write
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultValue);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final value = results.option('payload')!;
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Putting Data ('$keyExpr': '$value')...");
  session
    ..put(keyExpr, value)
    ..close();
}
