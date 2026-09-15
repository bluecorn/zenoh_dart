import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-put';

const helpText =
    '''
    Usage: z_delete [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to write to
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

  print("Deleting resources matching '$keyExpr'...");
  session
    ..deleteResource(keyExpr)
    ..close();
}
