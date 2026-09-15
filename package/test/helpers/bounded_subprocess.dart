// The OS-level bound every `close()`-under-overflow cell in this unit runs
// behind.
//
// WHY THIS EXISTS. The defect this unit fixes is an UNBOUNDED BLOCK INSIDE A
// SYNCHRONOUS FFI CALL. A naive in-process regression cell does not fail
// against it -- it parks the isolate's mutator thread, `package:test`'s
// `Timeout` timer never gets to run, and the whole serial suite freezes with
// no output. That is the most expensive possible failure here: it burns the
// one sampling opportunity a long run represents and reports nothing
// (`development/discipline/verification.md`, "An expensive run is ONE sampling
// opportunity").
//
// So the bound comes from a parent process whose event loop is healthy,
// applied to a child that is the one calling the deadlocking `close()`:
// `Process.start` + `exitCode` raced against a deadline + `kill(SIGKILL)`.
//
// ⚠️ `Process.run` IS NOT SUFFICIENT and is deliberately never used here. It
// only completes when the child exits, so against the very hang this unit is
// about it never returns and leaves an orphaned frozen child behind -- which is
// exactly the scenario under test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The marker prefixes [BoundedChild] tracks, most-recent-wins.
///
/// Kept as an explicit list rather than "the last line printed" so that a
/// diagnostic or a canon log line cannot be mistaken for progress through the
/// harness.
const _markerPrefixes = <String>[
  'HARNESS_READY',
  'PUBLISHED=',
  'AWAITING_CLOSE_CMD',
  'SESSION_CLOSED_MS=',
  'CLOSING_MS=',
  'CLOSE_RETURNED_MS=',
  'LINGER_DONE',
  'HARNESS_DONE',
  'ROUND=',
  'PERTURB_CLOSED',
  'PERTURB_DONE',
  'WINDOW_DONE',
  // Seed [DM-bounded-stream]. `hasMarker`/`markerValue` scan the raw output and
  // never needed this list, but `lastMarker` -- the thing that makes a FROZEN
  // child DIAGNOSABLE rather than just dead -- does. Without these, a resident
  // memory or fault-injection child that froze mid-run would report the last
  // marker of some earlier unit, which is worse than reporting none.
  //
  // 'RSS_' covers RSS_START_MIB= and RSS_END_MIB= in one prefix.
  'RSS_',
  'DELTA_MIB=',
  'DELIVERED=',
  // Seed [10a] slice 6 -- the retained-payload premature-free harness.
  'RETAIN_ROUND=',
  'RETAIN_PERTURB_DONE',
  'RETAIN_TIMEOUT',
  'RETAIN_NULL',
  'RETAIN_BADLEN',
  'RETAIN_CORRUPT',
  'PRODUCER_PUBLISHED=',
  // Not in the plan's list of eight, added deliberately: the resident-memory
  // harness prints it, and it is the marker that separates "the producer
  // stalled while paused" from "the child never got that far" -- the exact
  // diagnosis the eight exist to buy.
  'PAUSED_PUBLISHED=',
  'RESUMED_MS=',
  'INJECTOR_FIRED',
  'STREAM_ERROR=',
  'SAMPLE_OK',
  // Seed [OWN], slice 2. The double-close harness's markers. `lastMarker` is
  // what makes a FROZEN child diagnosable, and this harness is the one whose
  // pre-fix observable INCLUDED a silent hang -- so without these a freeze
  // would report the last marker of some earlier unit, which is worse than
  // reporting none. 'DC_' covers every marker the harness prints.
  'DC_',
  // Seed [OWN], slices 3+. The finalizer harness and the post-site hook
  // harness. Both can run for up to 120 rounds of allocation pressure, so a
  // child that stalls needs `lastMarker` to say WHERE it stalled -- "reached
  // FIN_READY and no further" is a different diagnosis from "never started".
  'FIN_',
  'HOOK_',
  // Seed [SHM] shared-memory-lifetime, slice 2. The two LEAKING arms run in a
  // child because their leak is permanent for the life of the process -- the
  // segment is refcounted by the chunks, so closing the provider does not take
  // it back -- and they must not spend the suite's RLIMIT_MEMLOCK budget for
  // the rest of the run. Each arm runs the full 120-round pressure cap, so a
  // child that stalls needs `lastMarker` to say WHERE: "reached
  // SHM_CHUNK_BASELINE and no further" is a different diagnosis from "never
  // started". 'SHM_' covers every marker that harness prints.
  'SHM_',
];

/// What a bounded harness run produced.
class HarnessOutcome {
  const HarnessOutcome({
    required this.frozen,
    required this.exitCode,
    required this.output,
    required this.lastMarker,
    required this.diagnosis,
  });

  /// True when the child had to be killed on the parent's deadline.
  ///
  /// This is the deadlock observable. It is not "the test failed" -- a cell
  /// asserting the *pre-fix* behaviour expects it to be true.
  final bool frozen;

  /// The child's exit code, or its negated signal number when killed.
  final int exitCode;

  /// stdout and stderr, interleaved in arrival order.
  final String output;

  /// The last harness marker seen before the child exited or was killed.
  ///
  /// This is what makes a freeze diagnosable: `CLOSING_MS=` as the last marker
  /// says the child reached the close and never came back out of it, which is
  /// a different failure from one that never linked its peers.
  final String? lastMarker;

  /// A one-line human-readable summary, suitable as an `expect` reason.
  final String diagnosis;

  bool hasMarker(String prefix) =>
      output.split('\n').any((l) => l.trimRight().startsWith(prefix));

  /// The integer value of a `NAME=<n>` marker, or null when absent.
  int? markerValue(String prefix) {
    for (final line in output.split('\n')) {
      final t = line.trimRight();
      if (t.startsWith(prefix)) return int.tryParse(t.substring(prefix.length));
    }
    return null;
  }

  /// The order in which the given marker prefixes appear, dropping absent ones.
  List<String> markerOrder(List<String> prefixes) {
    final seen = <String>[];
    for (final line in output.split('\n')) {
      final t = line.trimRight();
      for (final p in prefixes) {
        if (t.startsWith(p) && !seen.contains(p)) seen.add(p);
      }
    }
    return seen;
  }
}

/// A live child process with marker tracking and a stdin trigger.
class BoundedChild {
  BoundedChild._(this._process, this._label) {
    _pump(_process.stdout);
    _pump(_process.stderr);
  }

  final Process _process;
  final String _label;
  final StringBuffer _buffer = StringBuffer();
  String? _lastMarker;
  final _lines = StreamController<String>.broadcast();

  void _pump(Stream<List<int>> stream) {
    stream
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _buffer.writeln(line);
          for (final p in _markerPrefixes) {
            if (line.trimRight().startsWith(p)) {
              _lastMarker = line.trimRight();
              break;
            }
          }
          if (!_lines.isClosed) _lines.add(line);
        });
  }

  /// Waits for a line beginning with [prefix], bounded.
  ///
  /// Throws [StateError] with the captured output on timeout rather than
  /// hanging -- a marker that never arrives has to surface as a named failure
  /// carrying its evidence, not as a silent cost.
  Future<void> waitForMarker(String prefix, Duration within) async {
    if (_buffer.toString().split('\n').any((l) => l.startsWith(prefix))) return;
    try {
      await _lines.stream
          .firstWhere((l) => l.trimRight().startsWith(prefix))
          .timeout(within);
    } on TimeoutException {
      throw StateError(
        '$_label: timed out after ${within.inSeconds}s waiting for "$prefix"; '
        'last marker: ${_lastMarker ?? '(none)'}\n'
        '--- captured output ---\n'
        '${_buffer.isEmpty ? '(no output at all)' : _buffer}',
      );
    }
  }

  /// Writes one line to the child's stdin.
  void send(String line) {
    _process.stdin.writeln(line);
  }

  /// Awaits the child's exit against [deadline], killing it if it passes.
  ///
  /// The kill is SIGKILL, not SIGTERM: a process parked inside a synchronous
  /// FFI call is not running Dart code and will not service a signal handler.
  Future<HarnessOutcome> awaitExit(Duration deadline) async {
    var frozen = false;
    int code;
    try {
      code = await _process.exitCode.timeout(deadline);
    } on TimeoutException {
      frozen = true;
      _process.kill(ProcessSignal.sigkill);
      // Awaiting after the kill is what proves the child is actually gone:
      // `exitCode` completing means the process was reaped.
      code = await _process.exitCode.timeout(const Duration(seconds: 10));
    }
    await _lines.close();
    // A short grace so a line written just before exit is not lost to the
    // pump's own scheduling.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final out = _buffer.toString();
    final diagnosis = frozen
        ? 'FROZEN: $_label did not exit within ${deadline.inSeconds}s and was '
              'SIGKILLed; last marker: ${_lastMarker ?? '(none)'}\n'
              '--- captured output ---\n${out.isEmpty ? '(no output)' : out}'
        : '$_label exited $code; last marker: ${_lastMarker ?? '(none)'}\n'
              '--- captured output ---\n${out.isEmpty ? '(no output)' : out}';
    return HarnessOutcome(
      frozen: frozen,
      exitCode: code,
      output: out,
      lastMarker: _lastMarker,
      diagnosis: diagnosis,
    );
  }

  /// Best-effort kill, for `addTearDown`.
  Future<void> dispose() async {
    try {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on Object catch (_) {}
    if (!_lines.isClosed) await _lines.close();
  }
}

/// Starts a harness child and returns it live, for cells that need to drive it.
///
/// The caller owns the bound: pair this with [BoundedChild.awaitExit] and an
/// `addTearDown(child.dispose)`.
Future<BoundedChild> startBoundedHarness(
  String harnessPath,
  List<String> args, {
  Map<String, String>? environment,
  String? label,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', harnessPath, ...args],
    environment: environment,
  );
  return BoundedChild._(process, label ?? _labelFor(harnessPath, args));
}

/// Starts a harness child, awaits its exit against [deadline], and returns the
/// outcome. The shape every non-interactive cell in this unit uses.
Future<HarnessOutcome> runBoundedHarness(
  String harnessPath,
  List<String> args, {
  required Duration deadline,
  Map<String, String>? environment,
  String? label,
}) async {
  final child = await startBoundedHarness(
    harnessPath,
    args,
    environment: environment,
    label: label,
  );
  return child.awaitExit(deadline);
}

String _labelFor(String harnessPath, List<String> args) {
  String pick(String name, String fallback) {
    final i = args.indexOf('--$name');
    return (i == -1 || i + 1 >= args.length) ? fallback : args[i + 1];
  }

  final base = harnessPath.split('/').last;
  return '$base[column=${pick('column', '-')} kind=${pick('kind', '-')} '
      'capacity=${pick('capacity', '-')} count=${pick('count', '-')}]';
}
