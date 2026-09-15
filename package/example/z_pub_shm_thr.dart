import 'dart:io';
import 'dart:math' show max;

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultSharedMemorySize = 32; // MB

/// A pool below the allocator's construction floor cannot be built at all, so
/// a small `-s` is clamped up to canon's own 4096-byte example pool size.
/// Canon has no floor (z_pub_shm_thr.c passes `MB * 1024 * 1024` straight
/// through); the banner below prints the clamped byte count rather than the
/// requested MB, so a clamped run says so.
///
/// This constant used to be 65536, on the claim that pools below 64 KiB are
/// rejected by the allocator. That is measured false: the floor is about
/// 62x smaller, and the corrected value is the conservative anchor canon's own
/// examples use. Measurement at
/// `development/research/probes-seed7-pool-floor-20260819/`.
const shmPoolFloor = 4096;

const helpText =
    '''
    Usage: z_pub_shm_thr [OPTIONS] <PAYLOAD_SIZE>

    Arguments:
        <PAYLOAD_SIZE> (required, number): Size of the payload to publish

    Options:
        -s, --shared-memory <SHARED_MEMORY_SIZE> (optional, number, default='$defaultSharedMemorySize'): shared memory size in MBytes.
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption(
      'shared-memory',
      abbr: 's',
      defaultsTo: '$defaultSharedMemorySize',
    );
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  final payloadSize = requirePositionalSize(results, '<PAYLOAD_SIZE>');

  final sharedMemorySizeMb = parseIntArg(results.option('shared-memory')!);
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  print("Declaring Publisher on 'test/thr'...");
  final publisher = session.declarePublisher(
    'test/thr',
    congestionControl: CongestionControl.block,
  );

  final poolSize = max(sharedMemorySizeMb * 1024 * 1024, shmPoolFloor);
  print('Creating POSIX SHM Provider ($poolSize bytes)...');
  final provider = ShmProvider(size: poolSize);

  print('Allocating single SHM buffer');
  // ⛔ DELIBERATE DIVERGENCE, AND CANON'S CALL HERE IS NEITHER OF THE TWO.
  // canon uses the PLAIN, non-waiting entry (`z_shm_provider_alloc`,
  // z_pub_shm_thr.c:61), which reports out-of-memory instead of waiting. This
  // example used `allocGcDefragBlocking` -- a divergence that predates this
  // note -- and now uses the async sibling, which keeps the
  // garbage-collect-then-defragment retry while never freezing the isolate.
  //
  // ▶ THE GROUND IS A DART-SIDE ASYMMETRY. `allocGcDefragBlocking` is
  // synchronous FFI: it blocks the ISOLATE, and on a request the pool can
  // never satisfy it never returns. A Dart program parked there cannot run a
  // signal handler either, where it has one -- canon installs none anywhere,
  // so SIGINT keeps its default disposition and still kills it while parked.
  //
  // ⚠️ EXPOSURE IS GRADED, and this file is at the low end: it
  // allocates once at startup, so the window in which the hazard can be
  // reached is one call wide. `z_pub_shm` allocates once per publish
  // iteration. The window being narrow is not the same as its being
  // harmless: reached, it is still a process nothing short of SIGKILL can
  // end.
  //
  // The full hazard table stays on `allocGcDefragBlocking`'s own dartdoc,
  // where a caller meets it, and is not restated here.
  final result = await provider.allocGcDefragAsync(payloadSize);
  final ShmMutBuffer buffer;
  switch (result) {
    case AllocOk(buffer: final allocated):
      buffer = allocated;
    case AllocError(:final Enum kind):
    case LayoutError(:final Enum kind):
      print('Unexpected failure during SHM buffer allocation: $kind');
      publisher.close();
      provider.close();
      session.close();
      exit(canonFailureExit);
  }

  // Fill with 1 (memset pattern, matching C reference)
  buffer.write(List<int>.filled(payloadSize, 1));

  // Convert to ZBytes once -- clone in the loop (zero-copy)
  final shmBytes = buffer.toBytes();

  print('Press CTRL-C to quit...');
  while (true) {
    publisher.putBytes(shmBytes.clone());
  }
}
