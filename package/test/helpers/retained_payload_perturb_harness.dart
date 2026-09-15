// Seed [10a] slice 6 — the premature-free harness for a RETAINED PAYLOAD.
//
// WHY A SUBPROCESS. `MALLOC_PERTURB_` is read once by glibc at process start,
// so it cannot be set from inside a running test. And the failure class here is
// a SILENT read of freed memory: a use-after-free on a freed-but-untouched
// block returns plausible bytes and the suite stays green. Poisoning turns that
// silent read into a loud abort — but only in a process that started with the
// variable set.
//
// WHAT THIS DRIVES, and the position of the read is the whole point. Each round
// receives a sample with retention on and then READS the retained handle at a
// point where a premature free would ALREADY have happened — the injected
// defect drops the clone inside the delivery callback, immediately after the
// post, so by the time Dart parses the message and reads the handle the bytes
// are gone. A read taken before that point would pass on both trees and prove
// nothing.
//
// THE CONTENT IS VERIFIED, not just the call. A use-after-free that happens to
// return readable bytes must still fail, so every round asserts the payload
// byte-for-byte against what was published, including an interior NUL.
//
// ⚠️ `MALLOC_PERTURB_` INDUCES NO ALLOCATION FAILURE — it poisons freed bytes
// and malloc still succeeds, so every `if (!ptr)` branch stays unreachable and
// a leg that only checked those would read green before AND after a fix.
//
// Markers: RETAIN_ROUND=<n> per completed round, RETAIN_PERTURB_DONE at the
// end. The end marker is asserted SEPARATELY from the exit code, because a
// process that died early would otherwise satisfy an exit-code check for the
// wrong reason.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

const _rounds = 12;
const _port = 19733;

/// Bytes with an interior NUL and invalid UTF-8, so a corrupted read cannot
/// pass as a plausible string.
final _expected = Uint8List.fromList([
  0x5A,
  0x00,
  0xFF,
  0x41,
  0x00,
  0xC0,
  0x7E,
  0x00,
  0x80,
]);

void _say(String s) {
  stdout.writeln(s);
}

Future<void> main() async {
  final listenConfig = Config()
    ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$_port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final subSession = await Session.open(config: listenConfig);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final connectConfig = Config()
    ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$_port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final pubSession = await Session.open(config: connectConfig);
  await Future<void>.delayed(const Duration(seconds: 1));

  _say('HARNESS_READY');

  const key = 'retain/perturb';
  final subscriber = subSession.declareSubscriber(key, retainPayload: true);
  final inbox = <Sample>[];
  final sub = subscriber.stream.listen(inbox.add);

  for (var round = 0; round < _rounds; round++) {
    inbox.clear();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (inbox.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        _say('RETAIN_TIMEOUT round=$round');
        await sub.cancel();
        subscriber.close();
        pubSession.close();
        subSession.close();
        exit(2);
      }
      pubSession.putBytes(key, ZBytes.fromUint8List(_expected));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    final retained = inbox.first.payloadZBytes;
    if (retained == null) {
      _say('RETAIN_NULL round=$round');
      await sub.cancel();
      subscriber.close();
      pubSession.close();
      subSession.close();
      exit(3);
    }

    // Let the callback's frame go, and let any deferred release run, so the
    // read below is unambiguously AFTER the point a premature free occurs.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final got = retained.toBytes();
    if (got.length != _expected.length) {
      _say('RETAIN_BADLEN round=$round len=${got.length}');
      exit(4);
    }
    for (var i = 0; i < _expected.length; i++) {
      if (got[i] != _expected[i]) {
        _say(
          'RETAIN_CORRUPT round=$round at=$i '
          'got=${got[i]} want=${_expected[i]}',
        );
        exit(5);
      }
    }
    retained.dispose();
    _say('RETAIN_ROUND=$round');
  }

  await sub.cancel();
  subscriber.close();
  pubSession.close();
  subSession.close();
  _say('RETAIN_PERTURB_DONE');
  await stdout.flush();
  exit(0);
}
