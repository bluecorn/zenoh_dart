// Live leg for seed #9's collection-allocation failure arm.
//
// The zid enumeration collects into a shim-owned buffer that grows by
// `realloc` INSIDE canon's closure. That growth allocation's size is chosen by
// the network — one rung per connected peer — and the callback is `void` with
// no way to stop canon's enumeration, so the contract is: record the failure,
// let canon finish calling, have the wrapper release the partial buffer, and
// report. This harness drives that arm.
//
// Run as a SUBPROCESS under the extended injector:
//
//   ZD_FAIL_REALLOC_SIZE=32 LD_PRELOAD=./malloc_fail_injector.so \
//     dart run test/helpers/zid_alloc_fail_harness.dart
//
// ⚠️ THREE LINKED SESSIONS, NOT A PAIR, and that is what makes the cell reach
// the thing it exists to prove. With a pair the listener observes ONE id, the
// ladder runs a single rung — `realloc(NULL, 16)` — and failing it leaves
// `buf == NULL`, so "the wrapper released the partial buffer" degrades to a
// `free(NULL)` no-op: the cell would pass identically against a wrapper that
// freed nothing. With three sessions the listener observes TWO ids, the ladder
// is 0 -> 1 -> 2, and arming the SECOND rung (`realloc(buf, 32)`) fires the
// failure while a live 16-byte buffer exists and must be released.
//
// Markers, in order:
//   HARNESS_START        -- process got far enough to run
//   HARNESS_NOCONVERGE   -- the topology never reached two peers (a red leg
//                           that is NOT the arm under test; it says so)
//   HARNESS_ZIDS=<n>     -- peersZid() returned n ids
//   HARNESS_THREW=...    -- peersZid() threw, i.e. the shim reported the
//                           failed growth allocation rather than silently
//                           truncating or returning an empty list
//   HARNESS_DONE         -- survived to the end
//
// HARNESS_DONE is the point. Without the flag-and-report contract the shim
// would either write past a buffer it failed to grow or hand Dart a
// half-populated one; either way the process would not reach the end.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

const _port = 19543;
const _expectedPeers = 2;

Config _linked(String endpointKey) => Config()
  ..insertJson5('mode', '"peer"')
  ..insertJson5(endpointKey, '["tcp/127.0.0.1:$_port"]')
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false');

Future<void> main(List<String> args) async {
  stdout.writeln('HARNESS_START');

  final listener = await Session.open(config: _linked('listen/endpoints'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final c1 = await Session.open(config: _linked('connect/endpoints'));
  final c2 = await Session.open(config: _linked('connect/endpoints'));

  // Deadline-bounded convergence poll. Under injection the second growth rung
  // fails as soon as two peers exist, so a throw HERE is itself convergence —
  // the topology reached the state the observation needs. Either way the loop
  // ends; it never hangs.
  var converged = false;
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    try {
      if (listener.peersZid().length == _expectedPeers) {
        converged = true;
        break;
      }
    } on ZenohException {
      converged = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  if (!converged) {
    stdout.writeln('HARNESS_NOCONVERGE');
  } else {
    // The single observed call.
    try {
      stdout.writeln('HARNESS_ZIDS=${listener.peersZid().length}');
    } on ZenohException catch (e) {
      // Printing the TYPE rather than the message keeps the marker stable if
      // the message is ever reworded.
      stdout
        ..writeln('HARNESS_THREW=ZenohException')
        ..writeln('HARNESS_THREW_DETAIL=$e');
    }
  }

  c2.close();
  c1.close();
  listener.close();
  stdout.writeln('HARNESS_DONE');
}
