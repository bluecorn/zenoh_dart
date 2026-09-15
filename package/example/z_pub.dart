import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/zenoh-dart-pub';
const defaultValue = 'Pub from Dart!';

const helpText =
    '''
    Usage: z_pub [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to write to
        -p, --payload <PAYLOAD> (optional, string, default='$defaultValue'): The value to write
        -a, --attach <ATTACHMENT> (optional, string, default=NULL): The attachment to add to each put
        --add-matching-listener (optional): Add matching listener
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultValue)
    ..addOption('attach', abbr: 'a')
    ..addFlag('add-matching-listener', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final value = results.option('payload')!;
  final attachStr = results.option('attach');
  final addMatchingListener = results.flag('add-matching-listener');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Publisher on '$keyExpr'...");
  final publisher = session.declarePublisher(
    keyExpr,
    enableMatchingListener: addMatchingListener,
  );

  if (addMatchingListener) {
    publisher.matchingStatus!.listen((matching) {
      if (matching) {
        print('Publisher has matching subscribers.');
      } else {
        print('Publisher has NO MORE matching subscribers.');
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

  var idx = 0;
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    // canon: sprintf(buf, "[%4d] %s", idx, args.value)
    final payload = '[${idx.toString().padLeft(4)}] $value';
    print("Putting Data ('$keyExpr': '$payload')...");
    publisher.put(
      payload,
      // canon sets text/plain on every put (z_pub.c:87-90).
      encoding: Encoding.textPlain,
      attachment: attachStr != null ? ZBytes.fromString(attachStr) : null,
    );
    idx++;
  });

  await completer.future;

  timer.cancel();
  await sigintSub.cancel();
  await sigtermSub.cancel();
  publisher.close();
  session.close();
}
