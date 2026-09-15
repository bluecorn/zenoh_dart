// Seed [OWN], slice 2 — the open-send-close-close sequence, as a bounded child.
//
// WHY A CHILD PROCESS AND NOT AN IN-PROCESS CELL. The defect this sequence
// reproduces is a use-after-free on a native handle, and its observable is NOT
// STABLE. Across seven recorded runs of the same probe on the same tree it has
// presented as: a Rust `PoisonError` panic then abort (x2), a SILENT HANG with
// no further output (x1), and a SIGSEGV inside `z_close` (x4 — three of them
// captured by CI at `development/research/probes-ci-own-20260828/`). Two of
// those three shapes kill or freeze the process running them, so an in-process
// cell cannot survive to report anything: a `package:test` `Timeout` timer
// never runs while the mutator is parked inside native code, and the whole
// serial suite freezes with no output.
//
// So the bound comes from the parent, per the house rule, and this file is the
// child. See `helpers/bounded_subprocess.dart` for the runner.
//
// ⛔ WHAT THIS HARNESS MUST NEVER ASSERT, AND WHY IT PRINTS MARKERS INSTEAD.
// Because the pre-fix observable has three signatures, no cell may name a
// signal, an exit code other than 0, or a stack frame (seed criterion A2). The
// harness therefore reports POSITIVE facts through markers — the spawn was
// refused, the original closed, the run finished — and the cell asserts those.
// A cell keyed to "it aborted" would have failed to reproduce a defect that
// reproduces three times out of three.
//
// ARMS
//   --arm session   a Session handed to a spawned isolate, then closed here
//   --arm shm       an ShmProvider in the same shape (SHM's own severe case)
//   --arm control   the CALIBRATION: a plainly sendable payload in the same
//                   shape. The child DOES run and DOES print. Without this arm
//                   "no child output appeared" is vacuous — it would read
//                   identically if this harness never managed to spawn anything
//                   at all.
import 'dart:io';
import 'dart:isolate';

import 'package:zenoh_dart/zenoh_unstable.dart';

Config _quiet() => Config()
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false');

/// Runs in the child isolate. Reaching this at all in the `session`/`shm` arms
/// would mean the marker failed.
void _child(List<Object> args) {
  stdout.writeln('DC_CHILD_RAN');
  final reply = args[1] as SendPort;
  if (args[0] is Session) {
    // The second owner: a copy that shares the parent's native address and
    // carries its own fresh `_closed = false`.
    (args[0] as Session).close();
    stdout.writeln('DC_CHILD_CLOSED_COPY');
  } else if (args[0] is ShmProvider) {
    (args[0] as ShmProvider).close();
    stdout.writeln('DC_CHILD_CLOSED_COPY');
  }
  reply.send('done');
}

Future<void> main(List<String> args) async {
  final i = args.indexOf('--arm');
  final arm = (i == -1 || i + 1 >= args.length) ? 'session' : args[i + 1];

  // ⚠️ A BARE NEWLINE FIRST, DELIBERATELY. The toolchain prints
  // "Running build hooks..." with NO trailing newline, so without this the
  // first marker is glued onto that line and every `startsWith` check in
  // `HarnessOutcome` misses it. Measured: `DC_READY` vanished from a run that
  // had emitted it. A marker that cannot be matched is worse than no marker --
  // it reads as a child that never got that far.
  stdout
    ..writeln()
    ..writeln('DC_READY arm=$arm');

  Object payload;
  void Function() releaseOriginal;
  switch (arm) {
    case 'shm':
      final provider = ShmProvider(size: 65536);
      payload = provider;
      releaseOriginal = provider.close;
    case 'control':
      payload = 'a plainly sendable payload';
      releaseOriginal = () {};
    case _:
      final session = await Session.open(config: _quiet());
      payload = session;
      releaseOriginal = session.close;
  }

  final rp = ReceivePort();
  var spawned = false;
  try {
    await Isolate.spawn(_child, <Object>[payload, rp.sendPort]);
    spawned = true;
    stdout.writeln('DC_SPAWN_ACCEPTED');
    // Only reached in the control arm once the marker is in place. Bounded, so
    // a control that silently fails to deliver surfaces as a marker that never
    // arrives rather than as a hang.
    await rp.first.timeout(const Duration(seconds: 10));
    // The pre-fix `session`/`shm` arms reached here too — and this is the line
    // after which the process died, three ways.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    stdout.writeln('DC_SPAWN_REJECTED=${e.toString().split('\n').first}');
  }
  rp.close();

  if (!spawned) {
    // There is exactly one owner, so this is an ordinary release.
    releaseOriginal();
    stdout.writeln('DC_CLOSED_ORIGINAL');
  }

  stdout.writeln('DC_DONE');
  await stdout.flush();
  exit(0);
}
