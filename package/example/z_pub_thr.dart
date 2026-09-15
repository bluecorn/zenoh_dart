import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultPriority = 5; // Z_PRIORITY_DATA

const helpText =
    '''
    Usage: z_pub_thr [OPTIONS] <PAYLOAD_SIZE>

    Arguments:
        <PAYLOAD_SIZE> (required, number): Size of the payload to publish

    Options:
        -p, --priority <PRIORITY> (optional, number [1 - 7], default='$defaultPriority'): Priority for sending data
        --express (optional): Batch messages.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('priority', abbr: 'p', defaultsTo: '$defaultPriority')
    ..addFlag('express', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  final payloadSize = requirePositionalSize(results, '<PAYLOAD_SIZE>');

  final priority = parsePriority(results.option('priority')!);
  final express = results.flag('express');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Publisher on 'test/thr'...");
  final publisher = session.declarePublisher(
    'test/thr',
    congestionControl: CongestionControl.block,
    priority: priority,
    isExpress: express,
  );

  // Build payload
  final data = Uint8List(payloadSize);
  for (var i = 0; i < payloadSize; i++) {
    data[i] = i % 10;
  }
  final zbytes = ZBytes.fromUint8List(data);

  print('Press CTRL-C to quit...');
  while (true) {
    publisher.putBytes(zbytes.clone());
  }
}
