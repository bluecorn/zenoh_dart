import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/**';
const defaultSize = 3;
const defaultInterval = 5;

const helpText =
    '''
    Usage: z_pull [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The key expression to subscribe to
        -s, --size <SIZE> (optional, number, default='$defaultSize'): The size of the ring buffer
        -i, --interval <INTERVAL> (optional, number, default='$defaultInterval'): The interval for pulling the ringbuffer.
''';

/// ASCII 'q' -- the quit key canon's `getchar()` loop tests for.
const _quitChar = 0x71;

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('size', abbr: 's', defaultsTo: '$defaultSize')
    ..addOption('interval', abbr: 'i', defaultsTo: '$defaultInterval');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final size = parseIntArg(results.option('size')!);
  final interval = parseIntArg(results.option('interval')!);
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Subscriber on '$keyExpr'...");
  final pullSubscriber = session.declarePullSubscriber(keyExpr, capacity: size);

  print('Press <enter> to pull data...');

  // canon (z_pull.c:74-86): one `z_try_recv` per input character, so each
  // keypress pulls exactly one sample off the channel -- draining the whole
  // buffer per keypress would hide the on-demand, sample-at-a-time semantics
  // this example exists to demonstrate. On EOF canon idles at `interval`
  // seconds rather than exiting.
  //
  // The switch is EXHAUSTIVE with no `default` arm, which is the point of the
  // sealed result: canon's own loop shape distinguishes "nothing right now,
  // ask again" from "the channel is gone, stop", and against a nullable
  // return neither this example nor canon's could be written. The two
  // non-data arms are deliberately SILENT -- canon's z_pull.c prints nothing
  // for them either, and the interop harness asserts this example's stdout
  // byte-for-byte.
  var c = 0;
  var alive = true;
  while (c != _quitChar && alive) {
    c = stdin.readByteSync();
    if (c == -1) {
      sleep(Duration(seconds: interval));
      continue;
    }
    switch (pullSubscriber.tryRecv()) {
      case RecvData(:final value):
        final kindStr = value.kind == SampleKind.put ? 'PUT' : 'DELETE';
        print(
          ">> [Subscriber] Received $kindStr ('${value.keyExpr}': "
          "'${value.payload}')",
        );
      case RecvEmpty():
        // Alive, nothing buffered: canon backs off and asks again. Here the
        // next keypress is the backoff, so there is nothing to do.
        break;
      case RecvDisconnected():
        // Terminal. Leave the read loop WITHOUT printing -- the session is
        // gone, so there is nothing left to pull and nothing canon would say.
        alive = false;
    }
  }

  pullSubscriber.close();
  session.close();
}
