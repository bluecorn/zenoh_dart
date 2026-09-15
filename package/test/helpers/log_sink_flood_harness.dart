// The child behind seed [D1] slice 9 — what a log flood costs, and who pays.
//
// ⛔ THE QUESTION IS NOT "IS IT FAST". It is: does a host's sink, or a host's
// slow listener, back-pressure ZENOH'S OWN RUNTIME THREADS? Canon calls the
// sink synchronously on the emitting thread, so a post that blocked would hold
// a tokio worker for as long as the host took. The seed's own words aim here:
// "a logging sink that deadlocks or reenters is worse than none."
//
// ⛔ AND THE TIMED REGION IS THE DRIVING LOOP ALONE. Timing the whole process
// would fold in the drain and the settle, which are the HOST's cost and are
// not what this measures. `DRIVE_MS` covers exactly the loop that makes zenoh
// emit.
//
// Markers:
//   FLOOD_START <mode>
//   HOOK_RC=<n>                 the delay hook's install code (hooked arms)
//   FLOOD_INSTALLED <severity>
//   RSS_START_MIB=<n> / RSS_END_MIB=<n> / RSS_PEAK_MIB=<n>
//   DRIVE_MS=<n>                the driving loop, alone
//   RECORDS=<n>                 records the listener actually received
//   HOOK_POSTS=<n> HOOK_DELAYED=<n>
//   DRIVEN <phase>
//   FLOOD_DONE
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/log_severity.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/zenoh.dart';

/// The delay hook's exported surface.
class _DelayHook {
  _DelayHook(DynamicLibrary lib)
    : install = lib.lookupFunction<Int Function(), int Function()>(
        'zdd_install',
      ),
      uninstall = lib.lookupFunction<Void Function(), void Function()>(
        'zdd_uninstall',
      ),
      setDelayUs = lib.lookupFunction<Void Function(Int), void Function(int)>(
        'zdd_set_delay_us',
      ),
      posts = lib.lookupFunction<Int Function(), int Function()>('zdd_posts'),
      delayed = lib.lookupFunction<Int Function(), int Function()>(
        'zdd_delayed_posts',
      );

  final int Function() install;
  final void Function() uninstall;
  final void Function(int) setDelayUs;
  final int Function() posts;
  final int Function() delayed;
}

/// Records the listener has received so far. File-scope because the drain
/// helper below has to observe it.
int received = 0;

/// Drains to QUIESCENCE and returns the peak RSS observed while doing it.
///
/// ⛔ QUIESCENCE, NOT A FIXED TIME, and that is what makes an RSS reading mean
/// anything. A fixed drain samples mid-backlog and reports BACKLOG AS A LEAK
/// -- the two look identical at one instant and are opposite conclusions.
/// Quiescence is "no new record for ten consecutive samples", after which the
/// queue is empty by observation rather than by hope.
Future<int> drainToQuiescence(int peakSoFar) async {
  var peak = peakSoFar;
  var lastSeen = -1;
  var quiet = 0;
  for (var i = 0; i < 4000 && quiet < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final now = rssMib();
    if (now > peak) peak = now;
    if (received == lastSeen) {
      quiet++;
    } else {
      quiet = 0;
      lastSeen = received;
    }
  }
  stdout.writeln('DRAIN_QUIET=$quiet');
  return peak;
}

/// One record-producing call. Canon rejects the value and logs at `error`.
void driveOnce(int i) {
  final config = Config();
  try {
    config.insertJson5('connect/endpoints', '["tcp/1.2.3.4:7447" ZDF$i]');
  } on ZenohException {
    // The record is the point.
  } finally {
    config.dispose();
  }
}

int rssMib() => ProcessInfo.currentRss ~/ (1024 * 1024);

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'flood' : args[0];
  final rounds = args.length > 1 ? int.parse(args[1]) : 4000;
  final hookPath = args.length > 2 && args[2].isNotEmpty ? args[2] : null;
  final delayUs = args.length > 3 ? int.parse(args[3]) : 0;

  stdout.writeln('FLOOD_START $mode');

  // The hook goes in BEFORE the sink, so every post this run makes goes
  // through it. `ensureInitialized` first: the hook resolves the slot inside
  // the already-loaded libzenoh_dart.so.
  _DelayHook? hook;
  if (hookPath != null) {
    ensureInitialized();
    hook = _DelayHook(DynamicLibrary.open(hookPath));
    final rc = hook.install();
    stdout.writeln('HOOK_RC=$rc');
    if (rc != 0) {
      stdout.writeln('FLOOD_DONE');
      return;
    }
    hook.setDelayUs(delayUs);
  }

  if (mode != 'control') {
    final records = Zenoh.initLogWithSink(minSeverity: LogSeverity.trace);
    stdout.writeln('FLOOD_INSTALLED trace');
    if (!mode.startsWith('nolisten')) {
      records.listen((_) => received++);
    }
  }

  final startRss = rssMib();
  stdout.writeln('RSS_START_MIB=$startRss');
  var peakRss = startRss;

  final sw = Stopwatch()..start();
  switch (mode) {
    case 'starved':
    case 'starved-twice':
      // ⛔ THE MODE WHERE MEMORY ACTUALLY GROWS, and the one earlier revisions
      // missed: both of their cells drove an event loop that was free to
      // drain between turns, so the port queue never accumulated. Here the
      // isolate does heavy SYNCHRONOUS work with no await at all, so every
      // record posted during it sits in the VM's port queue.
      for (var i = 0; i < rounds; i++) {
        driveOnce(i);
        if (i % 500 == 0) {
          final now = rssMib();
          if (now > peakRss) peakRss = now;
        }
      }
    case 'nolisten-draining':
      // ⛔ A DRAINING LOOP, and the contrast with `starved` is the whole
      // point. Here the isolate yields every 200 calls, so the port queue is
      // emptied as it fills and never gets deep. The growth this reports is
      // therefore the STEADY-STATE cost of a flood nobody is listening to --
      // a different question from `starved`, which measures the cost of a
      // backlog. Reporting either as the other would be wrong in both
      // directions.
      for (var i = 0; i < rounds; i++) {
        driveOnce(i);
        if (i % 200 == 0) {
          await Future<void>.delayed(Duration.zero);
          final now = rssMib();
          if (now > peakRss) peakRss = now;
        }
      }
    default:
      for (var i = 0; i < rounds; i++) {
        driveOnce(i);
      }
  }
  sw.stop();
  stdout.writeln('DRIVE_MS=${sw.elapsedMilliseconds}');

  // ⛔ `exit-hot` returns from main WITH RECORDS STILL IN FLIGHT, deliberately
  // skipping the drain. That is the adjacent edge the raw-port decision names:
  // the shim's closure posting against a VM already in teardown. A clean exit
  // here is the assertion; there is nothing to collect.
  if (mode == 'exit-hot') {
    stdout
      ..writeln('DRIVEN exit-hot')
      ..writeln('FLOOD_DONE');
    return;
  }

  // The drain is deliberately OUTSIDE the timed region: it is the host's
  // cost, not zenoh's, and folding it in would measure the wrong party.
  peakRss = await drainToQuiescence(peakRss);

  // ⛔ THE LEAK-VS-BACKLOG DISCRIMINATOR, and without it the RSS numbers above
  // decide nothing. RSS is a HIGH-WATER mark: a runtime that allocated, freed
  // and did not return the pages to the OS reads exactly like one that leaked.
  // So round two floods the SAME process again after quiescence. If the second
  // round's growth is a fraction of the first's, the first round's memory was
  // reclaimed and REUSED -- backlog. If it grows again by the same amount,
  // nothing was reclaimed, and that is a leak that would force a shim-side
  // bound.
  if (mode == 'starved-twice') {
    final afterFirst = rssMib();
    stdout.writeln('RSS_AFTER_ROUND1_MIB=$afterFirst');
    for (var i = 0; i < rounds; i++) {
      driveOnce(i);
    }
    peakRss = await drainToQuiescence(peakRss);
    stdout.writeln('RSS_AFTER_ROUND2_MIB=${rssMib()}');
  }

  stdout
    ..writeln('RSS_END_MIB=${rssMib()}')
    ..writeln('RSS_PEAK_MIB=$peakRss')
    ..writeln('RECORDS=$received');
  if (hook != null) {
    stdout
      ..writeln('HOOK_POSTS=${hook.posts()}')
      ..writeln('HOOK_DELAYED=${hook.delayed()}');
    // Restore before exit so teardown is not measured through the wrapper.
    hook.uninstall();
  }
  stdout
    ..writeln('DRIVEN $mode')
    ..writeln('FLOOD_DONE');
}
