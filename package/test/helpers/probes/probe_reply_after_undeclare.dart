// Probe (seed #6 slice 12, the plan gate's R-11 amendment): what does canon
// actually DO when a query is replied to after its queryable is undeclared, and
// when a held query is read and dropped after its hosting SESSION is closed?
//
// cpp documents the first as undefined behaviour. UB has no safe pin, so no
// suite cell drives it — this probe is an INSTRUMENT, run once, whose observed
// outcome CLASS decides a disposition:
//
//   benign (error rc / silent drop) -> the binding's documented
//       drain-and-reply-before-you-close contract stands as written;
//   crash / abort -> STOP and escalate: a reachable process crash from
//       safe-looking Dart gets a guard, not a doc line.
//
// Run as a SUBPROCESS under MALLOC_PERTURB_, so a use-after-free aborts loudly
// rather than reading plausible bytes, and so a crash cannot take the suite
// with it. Both arms print markers; ARMS_DONE means the process reached the
// end, so an exit code of 0 is a real exit rather than an early death.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  // ---- Arm 1: reply after the QUERYABLE is undeclared -----------------------
  {
    final a = await Session.open(
      config: Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19345"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final b = await Session.open(
      config: Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19345"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );
    await Future<void>.delayed(const Duration(seconds: 1));

    const key = 'probe/ub/undeclare';
    final held = <Query>[];
    final queryable = a.declareQueryable(key);
    queryable.stream.listen(held.add);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final getDone = b.get(key, timeout: const Duration(seconds: 2)).toList();
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('ARM1_QUERIES=${held.length}');

    queryable.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    for (final q in held) {
      try {
        q.reply(key, 'after-undeclare');
        stdout.writeln('ARM1_REPLY=returned-normally');
      } on ZenohException catch (e) {
        stdout.writeln('ARM1_REPLY=ZenohException code=${e.returnCode}');
      } on Object catch (e) {
        stdout.writeln('ARM1_REPLY=${e.runtimeType}');
      }
      q.dispose();
    }
    // AWAIT the get before closing anything. MEASURED: a get still in flight
    // when its session closes leaves its ReceivePort open, and an open port
    // pins the isolate -- the probe printed every marker and then never
    // exited (timeout-killed at 90 s). Whether a session close should cascade
    // into its in-flight gets is the entity-lifecycle question seed #11 owns;
    // this probe simply does not depend on the answer.
    await getDone.timeout(const Duration(seconds: 20));
    stdout.writeln('ARM1_DONE');
    b.close();
    a.close();
  }

  // ---- Arm 2: read + drop a held query after the SESSION is closed ----------
  {
    final a = await Session.open(
      config: Config()
        ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19344"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final b = await Session.open(
      config: Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19344"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );
    await Future<void>.delayed(const Duration(seconds: 1));

    const key = 'probe/ub/sessionclose';
    final held = <Query>[];
    final queryable = a.declareQueryable(key);
    queryable.stream.listen(held.add);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final getDone = b.get(key, timeout: const Duration(seconds: 2)).toList();
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('ARM2_QUERIES=${held.length}');

    // The hosting session goes first, with the query still held. Dropping it
    // afterwards sends ResponseFinal through a dead session -- the corner the
    // query channel's teardown walks.
    a.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    for (final q in held) {
      stdout.writeln(
        'ARM2_FIELDS keyExpr=${q.keyExpr} '
        'params="${q.parameters}" payload=${q.payloadBytes}',
      );
      q.dispose();
      stdout.writeln('ARM2_DISPOSED');
    }
    await getDone.timeout(const Duration(seconds: 20));
    // The queryable's own ReceivePort has to be closed too, and here it is
    // closed AFTER its session — which is part of what this arm walks:
    // dropping a queryable whose session is already gone. Leaving it open
    // pins the isolate and the process never exits (measured: every marker
    // printed, then a 90 s timeout kill).
    queryable.close();
    stdout.writeln('ARM2_DONE');
    b.close();
  }

  stdout.writeln('ARMS_DONE');
}
