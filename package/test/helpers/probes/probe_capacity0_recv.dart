// Probe (seed #6 slice 10): what does `recv()` do on a CAPACITY-0 reply
// channel, per kind, through our stack?
//
// Seed #5 measured the sample column: a capacity-0 fifo is a RENDEZVOUS -- full
// when empty -- so a delivery blocks waiting for a concurrent consumer, and the
// readiness signal a parked `recv()` waits on is only raised AFTER that
// delivery
// returns. The parked recv is the only consumer that could unblock it, so
// neither side moves. Whether the same holds for replies is unmeasured: the
// reply channel self-terminates at query completion, which the sample column
// has
// no analogue of.
//
// EVERY WAIT IS BOUNDED. A capacity-0 hang corner cannot be discriminated by an
// unbounded probe -- it just never returns.
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19346"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19346"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  Future<String> recvAt0(ChannelKind kind) async {
    final key = 'probe/cap0/${kind.name}';
    final queryable = a.declareQueryable(key);
    queryable.stream.listen((q) {
      q
        ..reply(key, 'answer')
        ..dispose();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ch = b.pullGet(
      key,
      kind: kind,
      capacity: 0,
      consolidation: ConsolidationMode.none,
      timeout: const Duration(seconds: 5),
    );
    String outcome;
    try {
      final r = await ch.recv().timeout(const Duration(seconds: 6));
      outcome = r.runtimeType.toString();
    } on TimeoutException {
      outcome = 'TIMED_OUT_UNRESOLVED';
    }
    // Drain before disposing: on a rendezvous a blocked delivery must be
    // released, or the freeze merely moves to teardown.
    var guard = 0;
    while (ch.tryRecv() is! RecvDisconnected && guard++ < 50) {}
    ch.dispose();
    queryable.close();
    return outcome;
  }

  Future<String> tryRecvAt0(ChannelKind kind) async {
    final key = 'probe/cap0try/${kind.name}';
    final queryable = a.declareQueryable(key);
    queryable.stream.listen((q) {
      q
        ..reply(key, 'answer')
        ..dispose();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ch = b.pullGet(
      key,
      kind: kind,
      capacity: 0,
      consolidation: ConsolidationMode.none,
      timeout: const Duration(seconds: 5),
    );
    var got = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    var done = false;
    while (!done && DateTime.now().isBefore(deadline)) {
      switch (ch.tryRecv()) {
        case RecvData():
          got++;
        case RecvDisconnected():
          done = true;
        case RecvEmpty():
          await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    ch.dispose();
    queryable.close();
    return 'recovered=$got terminal=$done';
  }

  for (final kind in ChannelKind.values) {
    stdout.writeln('recv    cap0 ${kind.name}: ${await recvAt0(kind)}');
  }
  for (final kind in ChannelKind.values) {
    stdout.writeln('tryRecv cap0 ${kind.name}: ${await tryRecvAt0(kind)}');
  }

  b.close();
  a.close();
  stdout.writeln('PROBE_DONE');
}
