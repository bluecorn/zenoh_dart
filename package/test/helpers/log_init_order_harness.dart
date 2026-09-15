// The child behind seed [D1] slice 7 — one logging-init ORDER per process.
//
// ⛔ ONE ORDER PER PROCESS IS THE WHOLE POINT, not a convenience. Canon's slot
// is claimed once, for the life of the process, by whichever init runs first.
// Two orderings in one process would not be two measurements; the second would
// be a no-op of the first, and would report that no-op as its result.
//
// Markers, so the parent can tell a refusal from a silence and either from a
// death:
//
//   ORDER_START <mode>
//   FIRST_OK <what>            the first init returned normally
//   SECOND_OK <what>           the second init returned normally (silent)
//   SECOND_THREW <message>     the second init refused
//   REC <severity> <json>      a record delivered to a sink
//   DRIVEN <phase>
//   ORDER_DONE
//
// Canon's own records go to STDOUT (measured — a stderr-only capture returned
// nothing at all and read as a clean negative), so the parent counts them by
// scanning stdout for canon's target names.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/log_record.dart';
import 'package:zenoh_dart/src/log_severity.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/zenoh.dart';

const _settle = Duration(milliseconds: 400);

/// Emits one `error` record on target `zenohc::config`, carrying [marker].
void driveConfigRecord(String marker) {
  final config = Config();
  try {
    config.insertJson5('connect/endpoints', '["tcp/1.2.3.4:7447" $marker]');
  } on ZenohException {
    // The record is the point, not the rc.
  } finally {
    config.dispose();
  }
}

/// Emits one `error` record on target `zenohc::session`, from a tokio thread.
Future<void> driveSessionRecord() async {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('listen/endpoints', '["bogusproto/127.0.0.1:19754"]');
  try {
    (await Session.open(config: config)).close();
  } on ZenohException {
    // Expected.
  }
}

void emitRecord(LogRecord record) {
  stdout.writeln(
    'REC ${record.severity.wireValue} ${jsonEncode(record.message)}',
  );
}

/// Installs a sink, reporting which way it went. Returns null when refused.
Stream<LogRecord>? installSink(String label) {
  try {
    final records = Zenoh.initLogWithSink(minSeverity: LogSeverity.error);
    stdout.writeln('${label}_OK sink');
    return records;
    // The subject of this harness IS a StateError; catching it is the
    // measurement, not a slip.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    stdout.writeln('${label}_THREW ${e.message}');
    return null;
  }
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'initlog-then-sink' : args[0];
  final marker = args.length > 1 ? args[1] : 'ZDS7';

  stdout.writeln('ORDER_START $mode');

  switch (mode) {
    // --- R14's four orderings ------------------------------------------
    case 'initlog-then-sink':
      Zenoh.initLog('error');
      stdout.writeln('FIRST_OK initlog');
      installSink('SECOND');

    case 'sink-then-sink':
      final first = installSink('FIRST');
      installSink('SECOND');
      // The first stream must still be live: a refused second install must
      // not have disturbed the one that owns the slot.
      first?.listen(emitRecord);
      driveConfigRecord(marker);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN first-still-live');

    case 'sink-then-initlog':
      final records = installSink('FIRST');
      Zenoh.initLog('debug');
      stdout.writeln('SECOND_OK initlog');
      records?.listen(emitRecord);
      driveConfigRecord(marker);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN sink-still-live');

    case 'initlog-then-initlog':
      Zenoh.initLog('warn');
      stdout.writeln('FIRST_OK initlog');
      Zenoh.initLog('info');
      stdout.writeln('SECOND_OK initlog');

    // --- First-wins on our own surface, both directions ----------------
    //
    // ⛔ BOTH DIRECTIONS, because one alone cannot separate "the first init
    // won" from "nothing was emitting". `off` first must yield zero records
    // and `error` first must yield some; total separation is the calibration.
    case 'off-then-error':
      Zenoh.initLog('off');
      Zenoh.initLog('error');
      driveConfigRecord(marker);
      await driveSessionRecord();
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN first-wins');

    case 'error-then-off':
      Zenoh.initLog('error');
      Zenoh.initLog('off');
      driveConfigRecord(marker);
      await driveSessionRecord();
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN first-wins');

    default:
      stdout.writeln('ORDER_UNKNOWN_MODE $mode');
  }

  stdout.writeln('ORDER_DONE');
}
