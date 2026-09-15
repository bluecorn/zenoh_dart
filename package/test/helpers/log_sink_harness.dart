// The child process behind every log-sink cell in seed [D1].
//
// ⛔ WHY EVERY CELL SPAWNS ITS OWN PROCESS, AND WHY THAT IS NOT OPTIONAL.
// Canon's logging init is FIRST-WINS, PROCESS-GLOBAL AND SILENT: whichever
// init runs first owns logging for the life of the process, and every later
// call no-ops with no report. The Dart test suite runs as ONE OS process
// (measured: two suite files under one `dart test` both printed pid 1658387).
// So a second in-process cell installing a sink would silently receive
// nothing, and would report that as a result. Two cells would deterministically
// contradict each other with no way to tell which one ran first.
//
// ⛔ AND NO CELL IN THE SUITE PROCESS MAY INSTALL A SINK AT ALL — not even
// one. Doing so would claim the slot for every later cell in the run,
// including the three shipped `initLog` cells. `log_sink_test.dart` has a
// tripwire cell that scans for exactly that.
//
// Protocol. Every line is a marker, so a parent can tell SILENCE from DEATH:
// a child that produced no records is a different diagnosis from one that
// never reached its driver, and without the start markers the two are
// indistinguishable — a blind child reads as a clean negative.
//
//   SINK_START <mode>
//   SINK_INSTALLED <severity>       (absent when the install threw)
//   SINK_THREW <message>            (the exclusivity arm)
//   REC <severityIndex> <json>      (one per delivered record)
//   DRIVEN <phase>                  (a driver ran to completion)
//   SINK_DONE                       (reached the end of main)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/log_record.dart';
import 'package:zenoh_dart/src/log_severity.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/zenoh.dart';

/// How long a driver's records are given to arrive before the child moves on.
///
/// Records cross a native port and land on the event loop, so they are
/// necessarily asynchronous. ⚠️ This is a SETTLE, not a timing assertion:
/// every cell that reads it asserts on what arrived, never on how fast.
const _settle = Duration(milliseconds: 400);

/// A driver measured to emit at `error` on target `zenohc::config`: canon
/// rejects the value and logs the rejection before returning the rc.
///
/// [marker] rides canon's own text, so a record can be attributed to the call
/// that produced it rather than to "some record arrived".
void driveErrorRecord(String marker) {
  final config = Config();
  try {
    config.insertJson5('connect/endpoints', '["tcp/1.2.3.4:7447" $marker]');
  } on ZenohException {
    // Expected: the rc is not what this driver is for. The LOG RECORD is.
  } finally {
    config.dispose();
  }
}

/// A driver measured to emit at `info` and below: opening and closing a
/// session exercises canon's own startup logging.
///
/// ⛔ Chosen by MEASUREMENT, replacing a `warn`-based cell that would have
/// passed vacuously: ordinary session work emits TRACE 25 · DEBUG 15 · INFO 4
/// · **WARN 0** · ERROR 0 across 15 targets, so a ceiling test driven at
/// `warn` asserts nothing with nothing emitting at all.
Future<void> driveInfoRecords() async {
  final config = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final session = await Session.open(config: config);
  session.close();
}

void emitRecord(LogRecord record) {
  stdout.writeln(
    'REC ${record.severity.wireValue} ${jsonEncode(record.message)}',
  );
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'deliver' : args[0];
  final severity = args.length > 1
      ? LogSeverity.values.firstWhere((s) => s.name == args[1])
      : LogSeverity.error;
  final marker = args.length > 2 ? args[2] : 'ZDLOGMARK';

  stdout.writeln('SINK_START $mode');

  // The `late` mode is the only one that drives BEFORE installing, so it is
  // handled ahead of the install.
  if (mode == 'late') {
    driveErrorRecord('${marker}PRE');
    await Future<void>.delayed(_settle);
    stdout.writeln('DRIVEN pre-install');
  }

  Stream<LogRecord>? records;
  try {
    records = Zenoh.initLogWithSink(minSeverity: severity);
    stdout.writeln('SINK_INSTALLED ${severity.name}');
    // The exclusivity arm's whole subject IS a StateError, and reporting it
    // as a marker is what lets the parent distinguish "refused" from
    // "installed and silent" -- so catching it here is the point, not a slip.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    stdout.writeln('SINK_THREW ${e.message}');
  }

  // `nolisten` deliberately does not subscribe for its first phase, so the
  // broadcast stream has no listener and its records are discarded.
  // `nolisten` and `filtered` attach their own listeners below: the first
  // deliberately attaches none for its first phase, the second attaches a
  // filtering one whose output is the thing under test.
  if (mode != 'nolisten' && mode != 'filtered') {
    records?.listen(emitRecord);
  }

  switch (mode) {
    case 'deliver':
    case 'late':
      driveErrorRecord(marker);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN post-install');
    case 'workload':
      await driveInfoRecords();
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN workload');
    case 'multibyte':
      // A value canon rejects, carrying content outside ASCII. Canon echoes
      // the offending value into the record, so the bytes make the full
      // round trip: canon -> the borrowed pointer -> the post -> Dart.
      driveErrorRecord('日本語-Ω-$marker');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN multibyte');
    case 'exit':
      driveErrorRecord(marker);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN exit');
    case 'filtered':
      // ⛔ THE CELL THAT MAKES THE SINK A CONTROL RATHER THAN A CHANNEL. The
      // host drops records it does not want BEFORE they reach its own output.
      // The parent asserts what left this filter, never the raw stream --
      // asserting the raw stream would measure the leak again and call it
      // suppression.
      records
          ?.where((r) => !r.message.contains(marker))
          .listen((r) => stdout.writeln('KEPT ${r.severity.wireValue}'));
      driveErrorRecord(marker);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN filtered');
    case 'nolisten':
      driveErrorRecord('${marker}UNHEARD');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN unheard');
      records?.listen(emitRecord);
      driveErrorRecord('${marker}HEARD');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN heard');
    default:
      stdout.writeln('SINK_UNKNOWN_MODE $mode');
  }

  stdout.writeln('SINK_DONE');
}
