// Slice 6 / S-4: closing a full fifo WHILE DELIVERIES ARE STILL ARRIVING.
//
// WHAT THE COUNTED LEGS CANNOT SEE. `ffi_ownership_test.dart`'s counted legs
// see a LEAK -- a release that stopped happening. They cannot see a PREMATURE
// free: a block freed too early is still freed, so its address is reusable and
// the count reads perfectly clean. The discriminator for that class is
// POISONING, and it has to be a subprocess because glibc reads MALLOC_PERTURB_
// once at startup.
//
// WHY THE DELIVERIES MUST STILL BE ARRIVING. `_zd_pull_tee_on_call` LOANS and
// CALLS `tee->inner`. A tee block freed early and poisoned is only caught if
// something still reaches it -- so a quiescent close would leave the poisoned
// bytes untouched and pass. The pump keeps canon's delivery path live across
// the close, which is the only configuration in which a premature free yields
// a wild call rather than a plausible read.
//
// This is the leg the CA2 probe explicitly did NOT discharge (its README: "No
// MALLOC_PERTURB_ ... a silent use-after-free on a freed-but-untouched block
// would not fault here").
//
// Markers:
//   ROUND=<i>        one completed {declare, pump, close} round
//   PERTURB_CLOSED   the last round's close returned
//   PERTURB_DONE     reached the end, so exit 0 is a real exit
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

const _port = 19581;
const _key = 'zenoh/dart/fifoclose/perturb';
const _rounds = 15;

Config _config({int? listen, int? connect}) {
  final c = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (listen != null) {
    c.insertJson5('listen/endpoints', '["tcp/127.0.0.1:$listen"]');
  }
  if (connect != null) {
    c.insertJson5('connect/endpoints', '["tcp/127.0.0.1:$connect"]');
  }
  return c;
}

Future<void> main() async {
  final consumer = await Session.open(config: _config(listen: _port));
  final producer = await Session.open(config: _config(connect: _port));

  final link = Stopwatch()..start();
  while (consumer.peersZid().isEmpty) {
    if (link.elapsed > const Duration(seconds: 20)) {
      stderr.writeln('HARNESS_ERROR: peers never linked');
      exit(3);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  for (var round = 0; round < _rounds; round++) {
    final pull = consumer.declarePullSubscriber(
      _key,
      kind: ChannelKind.fifo,
      capacity: 2,
    );

    // TWO SESSIONS, always. A same-session pump would block inside put #N+1
    // and freeze before the close was ever reached -- the producer-side form
    // of the same failure mode, which would test nothing here.
    var pumping = true;
    final pump = () async {
      var i = 0;
      while (pumping) {
        producer.put(_key, 'x${i++}');
        // Paced, not a tight loop: the volume stays far under the loopback
        // and queue slack, so the transport cannot freeze and become the
        // thing being measured.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }();

    // Let the capacity-2 channel fill and a delivery park, with the pump still
    // running so deliveries are genuinely in flight across the close below.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // NOTHING IS DRAINED. The close happens with the channel full and canon's
    // delivery path live.
    pull.close();

    pumping = false;
    await pump;
    stdout.writeln('ROUND=$round');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  stdout.writeln('PERTURB_CLOSED');

  producer.close();
  consumer.close();
  stdout.writeln('PERTURB_DONE');
  exit(0);
}
