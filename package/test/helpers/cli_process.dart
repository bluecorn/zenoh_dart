import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The line every long-running zenoh example prints once startup is complete.
///
/// It is the last thing written before the example enters its main loop, so
/// its presence implies every earlier startup line has already been flushed.
/// That is what makes it a readiness *gate* rather than a guess at how long
/// boot takes.
///
/// `z_pull` is the one example that does not print it — it prompts for input
/// instead, so its tests wait on their own marker.
const cliReady = 'Press CTRL-C';

/// How long [waitForOutput] polls before failing.
///
/// Chosen from measurement, not intuition: reaching [cliReady] takes ~1.3 s on
/// an idle machine and ~5.4 s under heavy CPU contention (60 busy loops on 20
/// cores — the load that reproduces the fixed-sleep failures). 20 s is ~4x the
/// loaded case, and still fits inside `dart test`'s 30 s default timeout for
/// the files that do not override it.
const _defaultTimeout = Duration(seconds: 20);

/// Waits until [buffer] contains [marker], polling rather than sleeping.
///
/// CLI tests assert on what an example prints, not on how quickly it prints
/// it. A fixed sleep asserts the machine's speed instead: under load the
/// example can still be starting when the sleep expires, and the test reads a
/// short or empty buffer. Polling waits exactly as long as the process needs,
/// and returns as soon as the marker lands — so it is also faster than a fixed
/// sleep in the common case.
///
/// Fails with the captured output on timeout, so a marker that never arrives
/// (or one made stale by an example's wording change) surfaces as a named
/// failure with evidence, instead of silently costing the full timeout and then
/// failing somewhere less obvious.
Future<void> waitForOutput(
  StringBuffer buffer,
  String marker, {
  Duration timeout = _defaultTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (buffer.toString().contains(marker)) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    'Timed out after ${timeout.inSeconds}s waiting for "$marker".\n'
    '--- captured output ---\n'
    '${buffer.isEmpty ? '(no output at all)' : buffer}',
  );
}

/// Waits for a long-running example to finish starting up.
Future<void> waitForReady(
  StringBuffer buffer, {
  Duration timeout = _defaultTimeout,
}) => waitForOutput(buffer, cliReady, timeout: timeout);

/// Forcefully kills a process, escalating to SIGKILL if SIGTERM doesn't take.
///
/// Lives here rather than being copy-pasted into each CLI test file (it was, 18
/// times) so that the leak-safety rule below has one place to be stated.
///
/// **Pair every spawn with `addTearDown(() => forceKill(process))`.** The
/// dominant call shape — `await waitForOutput(...); await forceKill(process);`
/// — kills nothing when the wait fails, because [waitForOutput] fails by
/// throwing: the spawned example survives the suite. That is not just untidy.
/// A leaked `z_pong` stays subscribed to `test/ping`, and with multicast
/// scouting on it can answer a *later* test's pings from a different port — so
/// one test's failure can silently green another. Registering the kill as a
/// teardown makes it run on both paths.
Future<void> forceKill(Process process) async {
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
  } on Object catch (_) {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode
        .timeout(const Duration(seconds: 2))
        .catchError((_) => -1);
  }
}

/// Runs a one-shot example to completion, killing it if it overruns [timeout].
///
/// `Process.run(...).timeout(...)` looks equivalent and is not: it hands back
/// no handle, so a child that overruns is orphaned rather than killed. Same
/// observable behaviour otherwise — a `TimeoutException` still fails the test.
///
/// Waits on `exitCode` **and both output streams**, exactly as `Process.run`
/// does (`Future.wait([p.exitCode, stdout, stderr])` in the SDK's
/// `_runNonInteractiveProcess`). Awaiting only `exitCode` would be a race:
/// exit is signalled when the process dies, not when the last bytes have been
/// read out of the pipe, so a trailing line could be missing from a
/// [ProcessResult] these tests then assert on — a truncation that reads as a
/// failed assertion about the example rather than about the harness.
///
/// [decoder] defaults (when null) to the strict system decoder, which THROWS
/// on invalid UTF-8. That default is right for every ordinary example: their
/// output is text, and a FormatException there is a real defect worth
/// surfacing rather than smoothing over.
///
/// Track D's interop tests need the other behaviour. Canon's `z_put` echoes
/// its payload into its own startup banner with `printf("%s")`, so running it
/// with a deliberately non-UTF-8 payload puts raw bytes on stdout, and the
/// strict decoder throws while reading a process that is working perfectly.
/// Those callers pass a lenient decoder; nothing else does, so no existing
/// caller changes behaviour.
Future<ProcessResult> runToCompletion(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 30),
  Converter<List<int>, String>? decoder,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  // As Process.run does: a child blocked on stdin would otherwise never exit.
  await process.stdin.close();

  final out = StringBuffer();
  final err = StringBuffer();
  // `const SystemEncoding().decoder` cannot be a const default (the getter is
  // not const-evaluable), so the default is resolved here instead.
  final effective = decoder ?? const SystemEncoding().decoder;
  final outDone = process.stdout.transform(effective).forEach(out.write);
  final errDone = process.stderr.transform(effective).forEach(err.write);
  try {
    final results = await Future.wait<Object?>([
      process.exitCode,
      outDone,
      errDone,
    ]).timeout(timeout);
    return ProcessResult(
      process.pid,
      results[0]! as int,
      out.toString(),
      err.toString(),
    );
  } on TimeoutException {
    await forceKill(process);
    // Drain what the killed process left behind so the futures cannot complete
    // with an unhandled error after this call has already thrown.
    await outDone.catchError((_) {});
    await errDone.catchError((_) {});
    rethrow;
  }
}
