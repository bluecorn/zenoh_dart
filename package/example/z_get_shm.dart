import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'common_args.dart';

const defaultSelector = 'demo/example/**';
const defaultTimeoutMs = 10000;

/// Canon sizes the pool at exactly the payload length (z_get_shm.c:65), and
/// **that can never work** -- at any size, on any host. A pool needs a constant
/// per-allocation headroom above what you intend to allocate from it, so a pool
/// sized to its own allocation is always one allocation short. Measured across
/// the range by the committed sweep at
/// `development/research/probes-seed7-pool-floor-20260819/`, which also
/// shows canon's own binaries failing this way.
///
/// So this example must deviate, and the deviation is `max(2N, 4096)`: double
/// the payload, with canon's own 4096-byte example pool as the floor for small
/// ones. The two branches overlap, so the rule has no gap at any size.
///
/// It used to read `max(N, 65536)`, on the measured-false claim that pools
/// below 64 KiB are rejected. That was not merely wrong; it was
/// wrong in the unsafe direction -- once the payload passes 64 KiB the clamp
/// stops applying and the pool is sized to the payload again, which by the
/// paragraph above cannot be satisfied. The corrected rule widens the working
/// range rather than narrowing it.
const shmPoolFloor = 4096;

const helpText =
    '''
    Usage: z_get_shm [OPTIONS]

    Options:
        -s, --selector <SELECTOR> (optional, string, default='$defaultSelector'): The selection of resources to query
        -p, --payload <PAYLOAD> (optional, string): An optional value to put in the query
        -t, --target <TARGET> (optional, BEST_MATCHING | ALL | ALL_COMPLETE): Query target
        -o, --timeout <TIMEOUT_MS> (optional, number, default = '$defaultTimeoutMs'): Query timeout in milliseconds
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('selector', abbr: 's', defaultsTo: defaultSelector)
    ..addOption('payload', abbr: 'p')
    ..addOption('target', abbr: 't', defaultsTo: 'BEST_MATCHING')
    ..addOption('timeout', abbr: 'o', defaultsTo: '$defaultTimeoutMs');
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final selector = results.option('selector')!;
  final value = results.option('payload') ?? 'Get from Dart SHM!';
  final target = parseQueryTarget(results.option('target')!);
  final timeoutMs = parseIntArg(results.option('timeout')!);
  final config = buildConfig(results);

  // canon (z_get_shm.c:41-55) splits the selector at '?' and validates the key
  // expression before opening the session.
  var keyExpr = selector;
  String? parameters;
  final qIndex = selector.indexOf('?');
  if (qIndex >= 0) {
    keyExpr = selector.substring(0, qIndex);
    parameters = selector.substring(qIndex + 1);
  }

  try {
    KeyExpr(keyExpr).dispose();
  } on ZenohException {
    print('$keyExpr is not a valid key expression');
    exit(255);
  }

  print('Opening session...');
  final session = await openSession(config);

  final encodedBytes = utf8.encode(value);

  print('Creating SHM Provider...');
  final provider = ShmProvider(
    size: max(encodedBytes.length * 2, shmPoolFloor),
  );

  // ⛔ DELIBERATE DIVERGENCE, AND CANON'S CALL HERE IS NEITHER OF THE TWO.
  // canon uses the PLAIN, non-waiting entry (`z_shm_provider_alloc`,
  // z_get_shm.c:70), which reports out-of-memory instead of waiting. This
  // example used `allocGcDefragBlocking` -- a divergence that predates this
  // note -- and now uses the async sibling, which keeps the
  // garbage-collect-then-defragment retry while never freezing the isolate.
  //
  // ▶ THE GROUND IS A DART-SIDE ASYMMETRY. `allocGcDefragBlocking` is
  // synchronous FFI: it blocks the ISOLATE, and on a request the pool can
  // never satisfy it never returns -- so a Dart program parked there answers
  // nothing, including a signal handler where it has one. Canon installs
  // none, and SIGINT still kills it while its allocation is parked.
  //
  // ⚠️ EXPOSURE IS GRADED: this file allocates once per query, so the window
  // is as wide as the work it does. `z_pub_shm_thr` and `z_ping_shm`
  // allocate once at startup, which is narrower and not harmless.
  //
  // The full hazard table stays on `allocGcDefragBlocking`'s own dartdoc,
  // where a caller meets it, and is not restated here.
  final result = await provider.allocGcDefragAsync(encodedBytes.length);
  final ShmMutBuffer buffer;
  switch (result) {
    case AllocOk(buffer: final allocated):
      buffer = allocated;
    case AllocError(:final Enum kind):
    case LayoutError(:final Enum kind):
      // canon aborts here rather than degrading to a payload-less query, which
      // would look like a successful SHM run while never touching shared
      // memory. Unlike canon we can say WHICH outcome canon reported.
      print('Unexpected failure during SHM buffer allocation: $kind');
      provider.close();
      session.close();
      exit(255);
  }

  buffer.write(encodedBytes);
  final shmBytes = buffer.toBytes();

  print("[SHM] Sending Query '$selector'...");

  final stream = session.get(
    keyExpr,
    parameters: parameters,
    payload: shmBytes,
    target: target,
    // canon's `-o 0` means "use the configured default query timeout"
    // (z_get_options_t.timeout_ms == 0), and this binding spells that
    // `timeout: null` -- it refuses a zero Duration precisely so the sentinel
    // cannot be passed as if it were a value. So the example TRANSLATES canon's
    // sentinel rather than forwarding it; forwarding it would turn a
    // canon-valid flag value into an uncaught ArgumentError.
    timeout: timeoutMs == 0 ? null : Duration(milliseconds: timeoutMs),
  );

  await for (final reply in stream) {
    if (reply.isOk) {
      print(">> Received ('${reply.ok.keyExpr}': '${reply.ok.payload}')");
    } else {
      print(">> Received (ERROR: '${reply.error.payload}')");
    }
  }

  shmBytes.dispose();
  buffer.dispose();
  provider.close();
  session.close();
}
