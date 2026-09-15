// The resident-memory harness for criterion A, and for F-7's literal prong-2
// arm.
//
// WHY A SUBPROCESS, AND WHY TWO OF THEM. Two independent reasons, and both are
// hard bounds rather than preferences.
//
//  1. RSS IS PER-PROCESS. Criterion A compares the resident growth of a paused
//     push consumer against that of a paused demand-gated one. Running both
//     arms in one process would measure their SUM, and the peak of the first
//     would sit in the second's baseline. So each arm is a fresh child, and
//     the comparison is of two independent deltas.
//  2. A FIFO IN OVERFLOW BLOCKS ITS PRODUCER INSIDE A SYNCHRONOUS FFI CALL.
//     Publishing into a full fifo from the same isolate that owns the
//     subscriber parks the mutator thread permanently: no timer runs, no
//     `Future.timeout` fires, and the whole serial suite freezes with no
//     output. The producer therefore has to be a SEPARATE OS PROCESS, which is
//     also what makes F-7's stall observable at all -- see below.
//
// F-7, THE LITERAL PRONG-2 OBSERVABLE. Seed 5 ruled producer-side put-blocking
// unobservable and replaced it with substitutes, and that ruling was correct
// FOR THE TOPOLOGY IT WAS MADE IN: one process, where the blocking callback
// runs on the subscriber's own native thread and the publisher only ever sees
// transport backpressure. Here the producer is a different OS process under
// `CongestionControl.block`, and its progress is RELAYED LINE BY LINE as it
// happens. A stall is only visible in the progress -- buffering the producer's
// output to the end would destroy the one observable this arm exists for.
//
// MARKER DISCIPLINE. Every marker below is printed ONLY AFTER the step it
// names has RETURNED. That is the discriminator -- position, not specificity
// (`development/discipline/verification.md` §3). A banner printed before the
// thing it describes is this project's canonical false green: a test once
// asserted `contains('SHM Provider')` against a line printed *before* the
// provider was constructed, and it passed while the provider died.
//
//   RSS_START_MIB=<n>      the arm is declared AND the subscription is paused
//   PRODUCER_PUBLISHED=<n> relayed from the producer child, every 64 messages
//   PAUSED_PUBLISHED=<n>   the highest PRODUCER_PUBLISHED seen while paused
//   RSS_END_MIB=<n>        the paused window has ended
//   DELTA_MIB=<n>          end - start
//   DELIVERED=<n>          what the paused listener received: must be 0
//   RESUMED_MS=<n>         resume + drain returned
//   HARNESS_DONE           reached the end, so exit 0 is a real exit
//
// THE RESUME IS STDIN-SEQUENCED, NOT TIMED. The paused window ends because the
// parent said so, after the pre-resume markers are in -- so "the 64 MiB was
// posted while the consumer was paused" is a sequenced fact rather than a
// timing hope. Precedent: `fifo_close_harness.dart`'s `--close-on stdin`.
//
// Argv:
//   --role consumer|producer   consumer is the default and owns the child
//   --arm push|bounded         consumer only: which surface to declare
//                              push    -> Session.declareSubscriber (the
//                                         shipped unbounded seam -- criterion
//                                         A's calibration arm, free, from this
//                                         same build)
//                              bounded -> Session.declarePullSubscriber(...)
//                                         .stream
//   --kind ring|fifo           bounded arm only
//   --capacity N               bounded arm only (a negative one is rejected by
//                              the shipped binding AT THE DECLARE, after the
//                              session is already open -- that early death is
//                              itself a cell)
//   --port P                   TCP loopback port; consumer listens, producer
//                              connects
//   --count N                  messages
//   --size N                   payload bytes per message
//   --paused-deadline-ms N     how long the paused window waits for the
//                              producer to finish before measuring anyway. A
//                              throttling fifo never finishes, so this bound
//                              is what turns the stall into a measurement
//                              rather than a hang.
//   --drain-deadline-ms N      bound on the post-resume drain
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

/// ASCII only. A non-ASCII key expression aborts the process at this canon
/// pin, which would present as a harness crash rather than as a result.
const _key = 'zenoh/dart/boundedstream/rss';

const _publishedPrefix = 'PRODUCER_PUBLISHED=';

/// Upper bound on the wait for resident memory to go flat at the end of the
/// paused window. A bound, not a sleep: it is spent only while RSS is still
/// moving.
const _rssSettleBudgetMs = 15000;

void _say(String line) {
  stdout.writeln(line);
}

String _arg(List<String> a, String name, String fallback) {
  final i = a.indexOf('--$name');
  return (i == -1 || i + 1 >= a.length) ? fallback : a[i + 1];
}

int _mib(int bytes) => bytes ~/ (1024 * 1024);

Config _config({int? listen, int? connect}) {
  final c = Config()
    ..insertJson5('mode', '"peer"')
    // Tests control their environment: without these the child would discover
    // whatever is on the LAN and the topology under test would not be the one
    // written down.
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

/// Polls until the peer has linked, bounded, failing loudly rather than
/// waiting forever -- an unbounded convergence wait here would turn a broken
/// topology into a hang that looks exactly like the stall under test.
Future<void> _awaitLink(Session session, Duration within) async {
  final sw = Stopwatch()..start();
  while (session.peersZid().isEmpty) {
    if (sw.elapsed > within) {
      stderr.writeln(
        'HARNESS_ERROR: peers never linked within '
        '${within.inSeconds}s',
      );
      exit(3);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main(List<String> argv) async {
  if (_arg(argv, 'role', 'consumer') == 'producer') {
    await _producer(argv);
  } else {
    await _consumer(argv);
  }
}

Future<void> _consumer(List<String> argv) async {
  final port = int.parse(_arg(argv, 'port', '19592'));
  final arm = _arg(argv, 'arm', 'push');
  final kindName = _arg(argv, 'kind', 'ring');
  final capacity = int.parse(_arg(argv, 'capacity', '8'));
  final count = int.parse(_arg(argv, 'count', '1024'));
  final size = int.parse(_arg(argv, 'size', '65536'));
  final pausedDeadlineMs = int.parse(_arg(argv, 'paused-deadline-ms', '25000'));
  final drainDeadlineMs = int.parse(_arg(argv, 'drain-deadline-ms', '150000'));

  final session = await Session.open(config: _config(listen: port));

  // THE ONLY DIFFERENCE BETWEEN THE TWO ARMS IS THIS DECLARE. Same binary,
  // same build, same harness, same volume -- which is what makes criterion A's
  // calibration free: the arm carrying the defect is the SHIPPED
  // `declareSubscriber`, not an injected edit.
  Subscriber? pushSub;
  PullSubscriber? pullSub;
  final Stream<Sample> source;
  if (arm == 'push') {
    pushSub = session.declareSubscriber(_key);
    source = pushSub.stream;
  } else {
    pullSub = session.declarePullSubscriber(
      _key,
      kind: kindName == 'fifo' ? ChannelKind.fifo : ChannelKind.ring,
      capacity: capacity,
    );
    source = pullSub.stream;
  }

  var delivered = 0;
  // PAUSED BEFORE ANY TRAFFIC, and the pause is CASCADED onto the `listen` so
  // that nothing whatsoever runs between attaching the listener and stopping
  // it. Two statements would leave a window in which the loop could deliver.
  final sub = source.listen((_) {
    delivered++;
  })..pause();

  final startRss = ProcessInfo.currentRss;
  _say('RSS_START_MIB=${_mib(startRss)}');

  // Spawns ITSELF in the producing role. The producer connects to the same
  // port; see the header for why it cannot be an isolate or a second session
  // in this process.
  final producer = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      Platform.script.toFilePath(),
      '--role',
      'producer',
      '--port',
      '$port',
      '--count',
      '$count',
      '--size',
      '$size',
    ],
  );

  var highestPublished = 0;
  void relay(Stream<List<int>> raw) {
    raw
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith(_publishedPrefix)) {
            final v = int.tryParse(line.substring(_publishedPrefix.length));
            if (v != null && v > highestPublished) highestPublished = v;
          }
          // CONTINUOUS, NOT BUFFERED TO THE END. F-7's observable is the stall,
          // and a stall exists only in the progress.
          stdout.writeln(line);
        });
  }

  relay(producer.stdout);
  relay(producer.stderr);

  var producerExited = false;
  try {
    await producer.exitCode.timeout(Duration(milliseconds: pausedDeadlineMs));
    producerExited = true;
  } on TimeoutException {
    // EXPECTED on a throttling fifo: the producer is parked inside `put`
    // waiting for a consumer that is deliberately paused. That is the
    // measurement, not an error.
  }

  // ⚠️ THE PRODUCER'S EXIT IS NOT THE END OF DELIVERY. Messages posted just
  // before it are still in flight over loopback, and the consumer builds a
  // `Sample` for each one as it lands. Measuring on the producer's exit would
  // therefore systematically UNDERSTATE the push arm -- the arm the claim is
  // about -- by whatever the transport still held. So the paused window ends
  // on an OBSERVABLE GOING FLAT, bounded and self-limiting, rather than on an
  // event that merely correlates with it. On an arm that retains nothing this
  // exits after the first three samples; on the push arm it waits out the
  // backlog.
  final settle = Stopwatch()..start();
  var previousRss = -1;
  var flatSamples = 0;
  while (settle.elapsedMilliseconds < _rssSettleBudgetMs) {
    final now = ProcessInfo.currentRss;
    if (now == previousRss) {
      flatSamples++;
      if (flatSamples >= 3) break;
    } else {
      flatSamples = 0;
    }
    previousRss = now;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  _say('PAUSED_PUBLISHED=$highestPublished');
  final endRss = ProcessInfo.currentRss;
  _say('RSS_END_MIB=${_mib(endRss)}');
  _say('DELTA_MIB=${_mib(endRss - startRss)}');
  // Must be 0: the subscription has been paused since before any traffic. If
  // it is not, the delta measures something other than retention.
  _say('DELIVERED=$delivered');

  // Parked on the command, not on a clock.
  await stdin
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .firstWhere((l) => l.trim() == 'RESUME');

  final resumeSw = Stopwatch()..start();
  sub.resume();

  if (!producerExited) {
    try {
      await producer.exitCode.timeout(Duration(milliseconds: drainDeadlineMs));
      producerExited = true;
    } on TimeoutException {
      stderr.writeln(
        'HARNESS_NOTE: producer still running after drain '
        'deadline',
      );
    }
  }

  // Quiesce on an OBSERVABLE -- the delivered count going flat -- rather than
  // on a fixed sleep. Bounded, so a channel that never drains fails as a
  // missing marker instead of as a hang.
  var previous = -1;
  var flatDeliveries = 0;
  final quiesce = Stopwatch()..start();
  while (quiesce.elapsedMilliseconds < drainDeadlineMs) {
    if (delivered == previous) {
      // TWO consecutive flat samples, not one: a single flat reading is also
      // what a 250 ms gap in an ongoing delivery looks like, and `# drained`
      // would then understate on exactly the arm whose delivery is slowest.
      flatDeliveries++;
      if (flatDeliveries >= 2) break;
    } else {
      flatDeliveries = 0;
    }
    previous = delivered;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  _say('RESUMED_MS=${resumeSw.elapsedMilliseconds}');
  // Informational, deliberately NOT a tracked marker prefix: the paused-window
  // `DELIVERED=` must stay the single occurrence a parent reads.
  _say('# drained=$delivered of $count');

  await sub.cancel();
  pushSub?.close();
  pullSub?.close();
  session.close();

  _say('HARNESS_DONE');
  // Explicit: zenoh's native threads can outlive main() and keep the isolate
  // alive, which would read to the parent as a hang.
  exit(0);
}

Future<void> _producer(List<String> argv) async {
  final port = int.parse(_arg(argv, 'port', '19592'));
  final count = int.parse(_arg(argv, 'count', '1024'));
  final size = int.parse(_arg(argv, 'size', '65536'));

  final session = await Session.open(config: _config(connect: port));
  await _awaitLink(session, const Duration(seconds: 30));
  // Declared settle time, not a poll target: the link is up, and this is the
  // window in which the peer's subscriber declaration propagates. Publishing
  // into a peer that has not yet been told about the subscriber would simply
  // drop, which would understate both arms equally but for no good reason.
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final publisher = session.declarePublisher(
    _key,
    congestionControl: CongestionControl.block,
  );

  // BUILT ONCE, OUTSIDE THE LOOP. `size` ASCII characters is `size` bytes.
  final payload = 'x' * size;

  final sw = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    publisher.put(payload);
    if ((i + 1) % 64 == 0) {
      _say('$_publishedPrefix${i + 1}');
      // Informational, deliberately NOT a tracked marker prefix. It is what
      // makes a THROTTLE legible rather than merely inferable: a fifo holds
      // the producer back for a bounded interval and then bursts, and the
      // count alone cannot tell that from a producer that simply ran. The
      // elapsed time can. Measured shape on this tree, 1024 x 64 KiB:
      // ring 64->1024 in 0.15 s; fifo 64->320 in 5.05 s, then 320->1024 in
      // 0.09 s.
      _say('# published=${i + 1} at_ms=${sw.elapsedMilliseconds}');
      // ⚠️ FLUSHED, AND THIS IS LOAD-BEARING. The loop is synchronous FFI with
      // no yield point of its own, so without an explicit flush the progress
      // could still be sitting in this process's sink when `put` parks on a
      // full fifo -- and the parent would see a stall at 0 instead of at the
      // message where it actually happened. The whole of F-7 is that number.
      await stdout.flush();
    }
  }
  _say('$_publishedPrefix$count');
  _say('# published=$count at_ms=${sw.elapsedMilliseconds}');
  await stdout.flush();

  publisher.close();
  session.close();
  exit(0);
}
