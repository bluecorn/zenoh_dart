// The bounded demonstration harness for the fifo-close deadlock micro-round.
//
// WHY A SUBPROCESS AT ALL. `PullSubscriber.close()` / `PullQueryable.close()`
// reach `zd_subscriber_drop` / `zd_queryable_drop`, which are SYNCHRONOUS FFI
// calls. When they block they park the isolate's mutator thread, so
// `package:test`'s own `Timeout` timer and any `Future.timeout` live in an
// event loop that never runs again. An in-process bound is mechanically
// unsatisfiable there: the cell does not fail, it freezes the whole serial
// suite with no output. The bound therefore has to come from OUTSIDE the
// isolate, which means a child process and an OS-level kill from a parent
// whose own event loop is healthy. See `bounded_subprocess.dart`.
//
// MARKER DISCIPLINE. Every marker below is printed ONLY AFTER the step it
// names has returned. That is the discriminator -- position, not specificity
// (`development/discipline/verification.md` §3): a banner printed *before* the
// thing under test matches just as well while the thing under test dies.
// `CLOSE_RETURNED_MS=` in particular is written on the line after `close()`
// returns and nowhere else, so its presence cannot be produced by anything
// short of a returning close.
//
//   HARNESS_READY        peers linked (selfcontained) / listening (listener)
//   PUBLISHED=<n>        the driver finished: n puts (sub) or n gets (qbl)
//   AWAITING_CLOSE_CMD   parked on stdin, not on a timer
//   SESSION_CLOSED_MS=<n>  --mode session-first only: the consumer session
//                          close returned
//   CLOSING_MS=<n>       printed IMMEDIATELY BEFORE the close call
//   CLOSE_RETURNED_MS=<n>  printed IMMEDIATELY AFTER close() returns
//   HARNESS_DONE         reached the end, so exit 0 is a real exit
//
// Argv:
//   --column sub|qbl          which pull column
//   --kind fifo|ring          channel kind
//   --capacity N              channel capacity (N may be 0 or negative; a
//                             negative one is rejected by the shipped binding
//                             and that rejection is itself a cell)
//   --count N                 messages to drive (puts for sub, gets for qbl)
//   --port P                  TCP loopback port
//   --mode handle|session-first   what gets closed first
//   --role selfcontained|listener what this process owns
//   --close-on settle|stdin   what triggers the close
//   --settle-ms N             settle time around the driver
//   --linger-ms N             hold the session OPEN for N ms after close()
//                             returns, before tearing it down. THE
//                             DISCRIMINATOR for slice 4: without it the child
//                             exits ~20 ms after close(), and a prompt getter
//                             completion cannot be attributed to the close
//                             rather than to the session teardown that
//                             immediately follows it.
//   --hang-forever            TEST-ONLY: never close; park forever after
//                             printing CLOSING_MS=. The positive control that
//                             proves the parent's bound can actually fire.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

// ⚠️ STARTED EXPLICITLY IN main(), not here. A top-level field in Dart is
// initialized LAZILY, on first access -- and the first access is inside
// `CLOSING_MS=$_ms` itself, so an `..start()` cascade here makes the stopwatch
// begin at the moment it is read and every CLOSING_MS= marker reports 0.
// Measured: it did exactly that on this unit's first RED run. A broken
// instrument that produces a number is worse than none, because numbers get
// believed.
final _t0 = Stopwatch();

int get _ms => _t0.elapsedMilliseconds;

void _say(String line) {
  stdout.writeln(line);
}

String _arg(List<String> a, String name, String fallback) {
  final i = a.indexOf('--$name');
  return (i == -1 || i + 1 >= a.length) ? fallback : a[i + 1];
}

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

/// Polls until the two peers have linked, bounded, failing loudly rather than
/// waiting forever -- an unbounded convergence wait here would turn a broken
/// topology into a hang that looks exactly like the defect under test.
Future<void> _awaitLink(Session consumer, Duration within) async {
  final sw = Stopwatch()..start();
  while (consumer.peersZid().isEmpty) {
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
  _t0.start();
  final column = _arg(argv, 'column', 'sub');
  final kindName = _arg(argv, 'kind', 'ring');
  final capacity = int.parse(_arg(argv, 'capacity', '2'));
  final count = int.parse(_arg(argv, 'count', '20'));
  final port = int.parse(_arg(argv, 'port', '19580'));
  final mode = _arg(argv, 'mode', 'handle');
  final role = _arg(argv, 'role', 'selfcontained');
  final closeOn = _arg(argv, 'close-on', 'settle');
  final settleMs = int.parse(_arg(argv, 'settle-ms', '800'));
  final lingerMs = int.parse(_arg(argv, 'linger-ms', '0'));
  final hangForever = argv.contains('--hang-forever');

  final kind = kindName == 'fifo' ? ChannelKind.fifo : ChannelKind.ring;
  // ASCII only. A non-ASCII key expression aborts the process at this canon
  // pin, which would present as a harness crash rather than as a result.
  final key = 'zenoh/dart/fifoclose/$column';

  final consumer = await Session.open(config: _config(listen: port));
  Session? producer;
  if (role == 'selfcontained') {
    producer = await Session.open(config: _config(connect: port));
    await _awaitLink(consumer, const Duration(seconds: 20));
  }

  // Declared AFTER the link so the handle exists for the whole traffic window.
  // In listener role there is no link to wait for -- the parent is the peer,
  // and it connects after seeing HARNESS_READY.
  final pullSub = column == 'sub'
      ? consumer.declarePullSubscriber(key, kind: kind, capacity: capacity)
      : null;
  final pullQbl = column == 'qbl'
      ? consumer.declarePullQueryable(key, kind: kind, capacity: capacity)
      : null;

  _say('HARNESS_READY');

  // The getter futures this process owns, if any. Only selfcontained qbl runs
  // gets here; in listener role the PARENT owns every getter.
  final inFlight = <Future<void>>[];

  if (role == 'selfcontained') {
    await Future<void>.delayed(Duration(milliseconds: settleMs));
    if (column == 'sub') {
      for (var i = 0; i < count; i++) {
        producer!.put(key, 'x$i');
      }
    } else {
      for (var i = 0; i < count; i++) {
        inFlight.add(
          producer!
              .get(
                key,
                timeout: const Duration(seconds: 4),
                consolidation: ConsolidationMode.none,
              )
              .drain<void>(),
        );
      }
    }
    _say('PUBLISHED=$count');
    // Settle time, not a race: the puts/gets have returned, and this is the
    // window in which canon's delivery thread fills the channel and parks a
    // send. There is no observable to poll for -- the parked delivery is
    // precisely the thing that produces no signal.
    await Future<void>.delayed(Duration(milliseconds: settleMs));
  } else {
    _say('PUBLISHED=0');
  }

  if (closeOn == 'stdin') {
    _say('AWAITING_CLOSE_CMD');
    // Parked on the command, not on a clock. This is what makes "the queries
    // were in flight when the close happened" a sequenced fact rather than a
    // timing hope.
    await stdin
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.trim() == 'CLOSE');
  }

  if (mode == 'session-first') {
    final sw = Stopwatch()..start();
    consumer.close();
    _say('SESSION_CLOSED_MS=${sw.elapsedMilliseconds}');
  }

  _say('CLOSING_MS=$_ms');

  if (hangForever) {
    // TEST-ONLY positive control. Nothing below this line ever runs, so a
    // parent that reports this child as "not frozen" has a broken bound.
    await Completer<void>().future;
  }

  final closeSw = Stopwatch()..start();
  if (column == 'sub') {
    pullSub!.close();
  } else {
    pullQbl!.close();
  }
  _say('CLOSE_RETURNED_MS=${closeSw.elapsedMilliseconds}');

  // HOLD THE SESSION OPEN. Everything the getters could observe from here on
  // is attributable to the close alone, because the transport, the session and
  // the peer are all still up. Tearing down immediately would confound the two.
  if (lingerMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: lingerMs));
    _say('LINGER_DONE');
  }

  producer?.close();
  if (mode != 'session-first') consumer.close();

  // Let anything this process fired run out, bounded, so nothing is left
  // pinning the isolate at exit.
  for (final f in inFlight) {
    try {
      await f.timeout(const Duration(seconds: 20));
    } on Object catch (_) {}
  }

  _say('HARNESS_DONE');
  // Explicit: zenoh's native threads can outlive main() and keep the isolate
  // alive, which would read to the parent as a hang.
  exit(0);
}
