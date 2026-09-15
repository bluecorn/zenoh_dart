import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const helpText = '''
    Usage: z_info [OPTIONS]

    Options:
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser();
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  final ownId = session.zid;
  print('own id: ${ownId.toHexString()}');

  // canon's `print_zid` closure emits each id unindented.
  print('routers ids:');
  for (final routerId in session.routersZid()) {
    print(routerId.toHexString());
  }

  print('peers ids:');
  for (final peerId in session.peersZid()) {
    print(peerId.toHexString());
  }

  // canon additionally prints `transports:` and `links:` sections under
  // Z_FEATURE_UNSTABLE_API (z_info.c:188-238) and then runs until Ctrl-C on
  // transport/link event listeners. `z_info_transports`, `z_info_links` and
  // the event listeners have no Dart binding yet: an API-surface gap, tracked
  // separately, not something this example can close.

  session.close();
}
