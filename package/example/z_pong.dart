import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const helpText = '''
    Usage: z_pong [OPTIONS]

    Options:
        --no-express (optional): Disable message batching.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()..addFlag('no-express', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final noExpress = results.flag('no-express');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Publisher on 'test/pong'...");
  final publisher = session.declarePublisher(
    'test/pong',
    isExpress: !noExpress,
  );

  print("Declaring Background Subscriber on 'test/ping'...");
  final bgStream = session.declareBackgroundSubscriber(
    'test/ping',
    retainPayload: true,
  );

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  // Canon's callback clones the payload it was handed and publishes that
  // clone (`z_bytes_clone` then `z_publisher_put`, z_pong.c:12-17). This is
  // that, one for one: `retainPayload: true` gives every delivered sample an
  // owned handle on the payload -- a refcount clone of what the network
  // delivered, NOT a copy of the bytes -- and `putBytes` consumes it, so each
  // echo releases what it echoed. So the echo costs no copy, and it is
  // transparent to whatever backs the payload: this one pong answers a heap
  // ping and an SHM ping alike, exactly as canon's does.
  //
  // The `!` is the declaration above asserting itself, and canon's callback
  // does not test for a payload either. Failing here IS the diagnosis: a pong
  // that quietly stopped echoing would surface only as a ping that hangs.
  final streamSubscription = bgStream.listen((sample) {
    publisher.putBytes(sample.payloadZBytes!);
  });

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  await completer.future;

  await sigintSub.cancel();
  await sigtermSub.cancel();
  await streamSubscription.cancel();
  publisher.close();
  session.close();
}
