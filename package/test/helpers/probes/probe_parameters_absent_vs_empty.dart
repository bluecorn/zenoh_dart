// Probe (seed #6 slice 3): what does the RECEIVE side report for absent
// parameters versus present-but-empty parameters?
//
// Canon documents NULL = "none" on the send side; nothing anywhere measures
// what a queryable then reads. The payload path -- which DOES draw an
// absent/empty distinction -- runs beside it as the discriminating control, so
// an indistinguishable result here is a real finding rather than harness
// blindness.
import 'dart:async';

import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19349"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19349"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));

  const key = 'probe/params/absent-vs-empty';
  final seen = <String, Query>{};
  var n = 0;
  final queryable = a.declareQueryable(key);
  queryable.stream.listen((q) {
    final tag = 'q${n++}';
    stdout.writeln(
      '$tag parameters=${q.parameters.runtimeType} '
      'len=${q.parameters.length} value=${q.parameters.codeUnits} '
      'payloadBytes=${q.payloadBytes} '
      'attachmentBytes=${q.attachmentBytes}',
    );
    seen[tag] = q;
    q
      ..reply(key, 'ack')
      ..dispose();
  });
  await Future<void>.delayed(const Duration(milliseconds: 300));

  stdout.writeln('--- q0: parameters OMITTED, payload OMITTED ---');
  await b.get(key).toList();
  stdout.writeln('--- q1: parameters: "", payload present-but-empty ---');
  await b.get(key, parameters: '', payload: ZBytes.fromString('')).toList();
  stdout.writeln('--- q2: parameters: "x=1", payload "p" ---');
  await b.get(key, parameters: 'x=1', payload: ZBytes.fromString('p')).toList();

  await Future<void>.delayed(const Duration(milliseconds: 300));
  queryable.close();
  b.close();
  a.close();
  stdout.writeln('PROBE_DONE');
}
