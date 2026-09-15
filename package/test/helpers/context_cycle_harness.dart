// Cycle harness for the shim-side context counting legs (seed #8, Slice 12).
//
// Runs N cycles of one declare/close pattern and exits. Meant to be spawned
// under `LD_PRELOAD=shim_alloc_counter.so ZD_COUNT_SIZE=8`, whose destructor
// prints the alloc/free totals for the tracked size class as the process ends.
//
// Two modes, because the two contexts have DIFFERENT lifetime owners:
//
//   matching  N x (declareAdvancedPublisher(enableMatchingListener: true)
//                  -> close())            -- one session, entity cycles
//   detect    N x (open session
//                  -> declareAdvancedSubscriber(detectPublishers: ...)
//                  -> close entity
//                  -> close session
//                  -> AWAIT THE SENTINEL)  -- session cycles
//
// The detect mode's unit is the SESSION and not the entity, measured: canon
// binds that listener to the session, so it survives the advanced subscriber's
// drop and an entity-cycle loop would read "N distinct blocks, none reclaimed"
// on CORRECT code.
//
// It also awaits the sentinel per cycle rather than trusting `close()` to
// return. The free happens inside `_zd_sample_drop_with_sentinel`, which canon
// invokes when it drops the background closure, and nothing measures that this
// has completed by the time `Session.close()` returns. Gating on the return
// would let the next cycle allocate before the previous block came back, and
// the counter would read high on correct code.
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh_unstable.dart';

Config _quietConfig() => Config()
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false')
  ..insertJson5('timestamping/enabled', 'true');

Future<void> matchingCycles(int n) async {
  final session = await Session.open(config: _quietConfig());
  for (var i = 0; i < n; i++) {
    final publisher = session.declareAdvancedPublisher(
      'zenoh/dart/cycle/matching/$i',
      options: const AdvancedPublisherOptions(enableMatchingListener: true),
    )..close();
    // close() drops the native publisher, which runs _zd_matching_drop.
    if (publisher.matchingStatus == null) {
      stdout.writeln('HARNESS_FATAL no matching stream');
      exit(2);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  session.close();
}

Future<void> detectCycles(int n) async {
  for (var i = 0; i < n; i++) {
    final session = await Session.open(config: _quietConfig());
    final subscriber = session.declareAdvancedSubscriber(
      'zenoh/dart/cycle/detect/$i',
      options: const AdvancedSubscriberOptions(
        detectPublishers: DetectPublishersOptions(),
      ),
    );
    var done = false;
    final sub = subscriber.detectedPublishers!.listen(
      (_) {},
      onDone: () => done = true,
    );
    subscriber.close();
    session.close();

    // THE SYNCHRONIZATION POINT. The sentinel is posted from the same drop
    // callback that frees the context, immediately before the free, so seeing
    // it bounds the wait to "canon has begun dropping the closure". A short
    // settle after it covers the free itself.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!done) {
      stdout.writeln('HARNESS_FATAL no sentinel on cycle $i');
      exit(3);
    }
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Demonstrates WHY the detect context's counting unit is the session.
///
/// One session, N entity cycles, and then the process exits with the session
/// still open. On CORRECT code this reads `outstanding = N`: canon binds the
/// detect listener to the session, so dropping the advanced subscriber does not
/// release it. An entity-cycle leak assertion would therefore fail on code that
/// is behaving exactly as canon documents.
Future<void> detectEntityCycles(int n) async {
  final session = await Session.open(config: _quietConfig());
  for (var i = 0; i < n; i++) {
    session
        .declareAdvancedSubscriber(
          'zenoh/dart/cycle/detect-entity/$i',
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        )
        .close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  // Deliberately NOT closing the session: that is the state being shown.
  // Returning normally rather than calling exit(), so the process unwinds and
  // the counter's destructor actually runs.
  stdout.writeln('HARNESS_DONE detect-entity $n');
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'matching' : args[0];
  final n = args.length > 1 ? int.parse(args[1]) : 20;

  switch (mode) {
    case 'matching':
      await matchingCycles(n);
    case 'detect':
      await detectCycles(n);
    case 'detect-entity':
      await detectEntityCycles(n);
    default:
      stdout.writeln('HARNESS_FATAL unknown mode $mode');
      exit(2);
  }
  stdout.writeln('HARNESS_DONE $mode $n');
}
