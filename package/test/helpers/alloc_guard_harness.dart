// Live leg for the fix-round's group E (unchecked malloc on remote-length
// driven paths). Run as a SUBPROCESS under an address-space limit:
//
//   bash -c 'ulimit -v <kb>; dart run test/helpers/alloc_guard_harness.dart <bytes>'
//
// It publishes a payload of <bytes> to its own pull subscriber and then calls
// tryRecv(). The shim's `*out_payload = malloc(payload_byte_len)` is sized by
// the publisher, so under RLIMIT_AS -- with room for zenoh's copy but not a
// second one -- it returns NULL and the guard added by group E must take the
// early-return branch.
//
// Markers, in order:
//   HARNESS_START      -- process got far enough to run
//   HARNESS_ALLOC_OK   -- the test payload itself was buildable
//   HARNESS_RECV=<n>   -- tryRecv() delivered a sample of n bytes
//   HARNESS_THREW=...  -- tryRecv() threw, i.e. the guard's early return
//                         reached Dart as a call failure
//   HARNESS_DONE       -- survived to the end
//
// HARNESS_DONE is the point: without the guard the shim memcpy's through NULL
// and the process dies, so a missing marker is the red leg. A process that
// died early for an unrelated reason cannot pass for the wrong reason either,
// because the earlier markers are missing too.
//
// SEED #5 CHANGED WHAT THE GUARDED PATH PRINTS. It used to print
// `HARNESS_RECV=null`, because tryRecv() returned `null` for an allocation
// failure exactly as it did for an empty buffer -- an out-of-memory presenting
// to the caller as "nothing available". The guard's early return now surfaces
// as a thrown ZenohException (convention S3: canon's channel STATES are
// variants, a call failure is an exception), so the guarded path prints
// HARNESS_THREW and the unguarded control prints HARNESS_RECV=<n> and never
// HARNESS_THREW. That contrast is the instrument: a marker that fired either
// way would pass the leg while proving nothing.
import 'dart:io';
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main(List<String> args) async {
  final payloadBytes = int.parse(args[0]);
  stdout.writeln('HARNESS_START');

  final session = await Session.open(
    config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
  );

  final pull = session.declarePullSubscriber(
    'zenoh/dart/allocguard',
    capacity: 2,
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final payload = Uint8List(payloadBytes)..fillRange(0, payloadBytes, 0x5a);
  stdout.writeln('HARNESS_ALLOC_OK');

  session.putBytes('zenoh/dart/allocguard', ZBytes.fromUint8List(payload));
  await Future<void>.delayed(const Duration(milliseconds: 800));

  try {
    switch (pull.tryRecv()) {
      case RecvData(:final value):
        stdout.writeln('HARNESS_RECV=${value.payloadBytes.length}');
      case RecvEmpty():
        stdout.writeln('HARNESS_RECV=empty');
      case RecvDisconnected():
        stdout.writeln('HARNESS_RECV=disconnected');
    }
  } on ZenohException catch (e) {
    // The injected leg. Printing the TYPE rather than the message keeps the
    // marker stable if the message is ever reworded.
    stdout
      ..writeln('HARNESS_THREW=ZenohException')
      ..writeln('HARNESS_THREW_DETAIL=$e');
  }

  pull.close();
  session.close();
  stdout.writeln('HARNESS_DONE');
}
