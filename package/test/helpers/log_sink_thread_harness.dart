// The child behind seed [D1] slice 6 — where records come FROM.
//
// ⛔ THE INSTRUMENT IS THE PROTOCOL, and that is the whole design problem
// here. Every assertion in slice 6 is made across a process boundary, so a
// child that died before its driver and a child that ran and received nothing
// look identical from the parent: both produce no records. The second is a
// result; the first is a broken instrument reporting a clean negative.
//
// So every phase prints a marker, and the parent asserts the markers BEFORE it
// asserts anything about records.
//
//   THREAD_START
//   THREAD_INSTALLED
//   DRIVEN <phase>                 (a driver ran to completion)
//   REC <severity> <json message>  (one per delivered record)
//   THREAD_DONE
//
// ⛔ Spawned, never in-process: canon's logging slot is process-global and
// first-wins, and the suite is one OS process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/log_record.dart';
import 'package:zenoh_dart/src/log_severity.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/zenoh.dart';

const _settle = Duration(milliseconds: 600);

/// Emits on the CALLING thread: canon rejects the value and logs the
/// rejection inside the same synchronous call, on target `zenohc::config`.
void driveCallingThread(String marker) {
  final config = Config();
  try {
    config.insertJson5('connect/endpoints', '["tcp/1.2.3.4:7447" $marker]');
  } on ZenohException {
    // The rc is not what this driver is for; the log record is.
  } finally {
    config.dispose();
  }
}

/// Emits on a TOKIO thread: the open runs on zenoh's own runtime, and its
/// failure is logged from there rather than from the caller.
///
/// ⭐ This is the driver that makes slice 6 more than a restatement of slice
/// 5. `Session.open` is offloaded onto a shim-owned worker and canon's
/// runtime threads, so a delivery mechanism that only worked when the emitter
/// happened to be the Dart thread would pass every slice-5 cell and fail
/// here.
///
/// ⚠️ THE ATTRIBUTION TOKEN IS THE PORT, NOT A STRING WE CHOSE, and that is
/// forced rather than preferred. Canon's open-failure records render a
/// DIAGNOSIS and echo nothing of the config -- measured over nine drivers in
/// slice 3 -- so there is no field to plant a marker in. A TLS listener with
/// unusable key material fails with "Cannot create a new TLS listener on
/// `127.0.0.1:<port>`", which puts a caller-chosen number inside canon's own
/// text. That is what lets a cell say "THIS record came from THAT call"
/// rather than "a record arrived".
///
/// Ports come from this unit's reserved 19743-19762 block.
Future<void> driveTokioThread(int port) async {
  final config = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5(
      'listen/endpoints',
      '["tls/127.0.0.1:$port#listen_private_key_base64=not-base64'
          '&listen_certificate_base64=bm90LWEtY2VydA=="]',
    );
  try {
    (await Session.open(config: config)).close();
  } on ZenohException {
    // Expected. The record is the point.
  }
}

void emitRecord(LogRecord record) {
  stdout.writeln(
    'REC ${record.severity.wireValue} ${jsonEncode(record.message)}',
  );
}

/// One concurrent driver, run inside its own isolate.
///
/// ⚠️ Nothing zenoh-owned crosses the isolate boundary — each isolate builds
/// and discards its own `Config`. What crosses is a `String` marker in and
/// nothing out; the records themselves travel over the shim's native port to
/// whichever isolate installed the sink.
Future<void> concurrentDriver(String marker) async {
  driveCallingThread(marker);
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'tokio' : args[0];
  final marker = args.length > 1 ? args[1] : 'ZDTHREAD';
  final port = args.length > 2 ? int.parse(args[2]) : 19751;

  stdout.writeln('THREAD_START');

  Stream<LogRecord>? records;
  records = Zenoh.initLogWithSink(minSeverity: LogSeverity.error);
  stdout.writeln('THREAD_INSTALLED');

  if (mode != 'nolisten') {
    records.listen(emitRecord);
  }

  switch (mode) {
    case 'tokio':
      await driveTokioThread(port);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN tokio');

    case 'both':
      driveCallingThread('${marker}CALLING');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN calling');
      await driveTokioThread(port);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN tokio');

    case 'concurrent':
      // Eight isolates, each with its own marker, all emitting into the one
      // process-global sink at once. Canon's own header says the callback is
      // "not guaranteed not to be called concurrently"; this is that.
      const count = 8;
      await Future.wait([
        for (var i = 0; i < count; i++)
          Isolate.run(() => concurrentDriver('$marker-$i')),
      ]);
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN concurrent $count');

    case 'nolisten':
      driveCallingThread('${marker}UNHEARD');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN unheard');
      records.listen(emitRecord);
      driveCallingThread('${marker}HEARD');
      await Future<void>.delayed(_settle);
      stdout.writeln('DRIVEN heard');

    default:
      stdout.writeln('THREAD_UNKNOWN_MODE $mode');
  }

  stdout.writeln('THREAD_DONE');
}
