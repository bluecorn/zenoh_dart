import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

// canon's `z_scout.c` takes no arguments at all -- it does not include
// `parse_args.h`. The common block is offered here anyway (an addition, not a
// divergence in behaviour) so that pointing the scout at a specific transport
// or disabling multicast does not require editing the file.
const helpText = '''
    Usage: z_scout [OPTIONS]

    Options:
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser();
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final config = buildConfig(results);

  print('Scouting...');
  final hellos = await Zenoh.scout(config: config);

  hellos.forEach(print);

  // canon prints these from the closure's drop handler, after the scout ends.
  print('Dropping scout');
  if (hellos.isEmpty) {
    print('Did not find any zenoh process.');
  }
}
