// Open/close cycle harness for the offloaded open's two heap blocks.
//
// Run as a SUBPROCESS under one of two instruments, which are NOT
// interchangeable and measure different defects:
//
//   LD_PRELOAD=shim_alloc_counter.so ZD_COUNT_SIZE=<n>   the LEAK arm
//   MALLOC_PERTURB_=165                                  the PREMATURE-FREE arm
//
// ⛔ Distinct-address counting -- the instrument the older legs in
// ffi_ownership_test.dart use -- cannot see a premature free AT ALL, and the
// counter cannot see a use-after-free. Using one for both is a false green.
//
// ⛔ IT MUST NOT CALL exit(). shim_alloc_counter.c reports from an
// __attribute__((destructor)); exiting early skips it and the run reports
// `allocs=0` -- a zero indistinguishable from a clean run.
//
// Markers:
//   HARNESS_CYCLES <n>  every cycle opened and closed
//   HARNESS_DONE        reached the end, so exit 0 is a real exit
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main(List<String> args) async {
  final cycles = args.isEmpty ? 200 : int.parse(args[0]);
  // `tee` replays the pull-channel tee-orphan cycle under the counter. Its own
  // cell in ffi_ownership_test.dart measures address REUSE, which the offloaded
  // open's arena churn suppressed to the point of non-discrimination; the
  // counter is immune to that and answers the leak question directly.
  final mode = args.length > 1 ? args[1] : 'open';

  if (mode == 'tee') {
    // Sessions hoisted, exactly as the cell does it: the producer must die
    // before the pull handle, and that ordering is the thing under test.
    final owners = [
      for (var i = 0; i < cycles; i++)
        await Session.open(
          config: Config()
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        ),
    ];
    for (final owner in owners) {
      final pull = owner.declarePullSubscriber(
        'zenoh/dart/own/pull/tee-orphan',
        capacity: 4,
      );
      owner.close();
      pull.close();
    }
    stdout
      ..writeln('HARNESS_CYCLES $cycles')
      ..writeln('HARNESS_DONE');
    return;
  }

  for (var i = 0; i < cycles; i++) {
    // Multicast and gossip both off: the fast path, ~1 ms, so 200 cycles stay
    // inside a test timeout. The block lifetimes under measurement are
    // identical on the fast and slow paths -- only the wait differs.
    final session = await Session.open(
      config: Config()
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false'),
    );
    session.close();
  }

  stdout
    ..writeln('HARNESS_CYCLES $cycles')
    ..writeln('HARNESS_DONE');
}
