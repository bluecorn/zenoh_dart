// Seed [10a] slice 10 — the retention-ON pull extractor under an injected
// allocation failure.
//
// WHY A SUBPROCESS. The LD_PRELOAD injector has to be in place before the
// process links, so it cannot be armed from inside a running test.
//
// WHAT IT DRIVES. A retention-enabled `PullSubscriber` receiving samples whose
// key expression, payload and encoding all have KNOWN, DISTINCT byte lengths,
// so the injector's exact-size arm picks out exactly ONE of the shim's four
// remote-length-driven mallocs. The sizes are PRINTED rather than only assumed
// by the driver: an exact size IS the instrument, and if one drifts the
// injector fires on nothing and the driver's positive control goes red.
//
// ⛔ WHICH MALLOC IS FAILED IS THE WHOLE EXPERIMENT. The retained clone is
// taken between the PAYLOAD malloc and the ENCODING malloc, so:
//
//   ZD_FAIL_MALLOC_SIZE=<key+1>       fails BEFORE the clone -- nothing was
//                                     ever claimed, and phase A must stay flat
//   ZD_FAIL_MALLOC_SIZE=<encoding+1>  fails AFTER  the clone
//
// WHAT IT MEASURES BESIDES THE THROW. A payload left claimed neither throws
// nor corrupts, so the throw alone says nothing about release. Phase A runs
// `_rounds` publish/pull cycles at a payload large enough that ONE retained
// payload per round is plainly visible in RSS, and reports the delta. Phase B
// is the POSITIVE CONTROL for that instrument: the same loop holding every
// retained handle instead of disposing it, so a run that cannot see a retained
// payload at all is distinguishable from one where nothing was retained.
// (Phase B needs successful receives, so it is empty under injection.)
//
// Markers:
//   SIZES key=<n> payload=<n> encoding=<n>   -- the injectable exact sizes
//   WARMUP=<outcome>                         -- delivery confirmed first
//   A_OUTCOMES data=<n> threw=<n> empty=<n> disconnected=<n>
//   A_THREW_CODES=<comma-separated distinct return codes>
//   A_RSS_DELTA_KB=<n>
//   B_HELD=<n> B_RSS_DELTA_KB=<n>
//   HARNESS_DONE                             -- reached the end, so an exit
//                                               code of 0 is a real exit
import 'dart:io';
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

const _rounds = 100;
const _port = 19738;

/// 15 bytes, so the shim's key-expression malloc asks for exactly 16 --
/// BEFORE the retained clone is taken.
const _key = 'zd/retain/alloc';

/// A custom MIME long enough that no other shim allocation shares its size.
/// The shim's encoding malloc asks for `len + 1`, and it runs AFTER the
/// retained clone is taken.
const _mime = 'application/x-zd-retain-alloc-probe';

/// 256 KiB. One retained payload per round is then ~26 MB over [_rounds],
/// which no allocator noise on this path comes near.
const _payloadBytes = 262144;

void _say(String s) => stdout.writeln(s);

/// Resident set size in KiB, straight from the kernel.
int _rssKb() {
  final line = File('/proc/self/status')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('VmRSS:'));
  return int.parse(line.split(RegExp(r'\s+'))[1]);
}

Future<void> main() async {
  // Two sessions over loopback TCP: the construction every other pull cell in
  // this package uses, so the sample genuinely crosses the wire.
  final subSession = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$_port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final pubSession = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$_port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  final payload = Uint8List(_payloadBytes);
  _say(
    'SIZES key=${_key.length + 1} payload=$_payloadBytes '
    'encoding=${_mime.length + 1}',
  );

  final pull = subSession.declarePullSubscriber(
    _key,
    kind: ChannelKind.fifo,
    capacity: 8,
    retainPayload: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));

  void publishOne() {
    final zb = ZBytes.fromUint8List(payload);
    pubSession.putBytes(_key, zb, encoding: const Encoding(_mime));
    // `putBytes` consumes it; disposing releases only the Dart-side wrapper,
    // and doing it here keeps it off the finalizer queue.
    zb.dispose();
  }

  final threwCodes = <int>{};

  /// One pull, rendered as a marker word, optionally keeping the retained
  /// handle alive in [hold]. A [ZenohException] is an OUTCOME here, not a
  /// failure: it is the thing under test.
  String pullOnce({List<ZBytes>? hold}) {
    try {
      final result = pull.tryRecv();
      if (result is RecvData<Sample>) {
        final retained = result.value.payloadZBytes;
        if (hold != null && retained != null) {
          hold.add(retained);
        } else {
          retained?.dispose();
        }
        return 'DATA';
      }
      if (result is RecvDisconnected<Sample>) return 'DISCONNECTED';
      return 'EMPTY';
    } on ZenohException catch (e) {
      threwCodes.add(e.returnCode);
      return 'THREW';
    }
  }

  /// Publishes and pulls once, bounded. Returns the outcome word, or 'NONE'
  /// if nothing at all arrived inside the deadline -- which the driver reads
  /// as a failure rather than as a quiet zero.
  Future<String> round({List<ZBytes>? hold}) async {
    publishOne();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final outcome = pullOnce(hold: hold);
      if (outcome != 'EMPTY') return outcome;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return 'NONE';
  }

  // WARM-UP. Bounded, and it is what establishes that delivery works at all --
  // without it a run where nothing ever arrived would report only zeros and a
  // flat RSS, which is what a passing run looks like.
  _say('WARMUP=${await round()}');

  // ---- PHASE A: the measurement. Every retained handle released. ----
  final counts = <String, int>{
    'DATA': 0,
    'THREW': 0,
    'EMPTY': 0,
    'DISCONNECTED': 0,
    'NONE': 0,
  };
  final aStart = _rssKb();
  for (var i = 0; i < _rounds; i++) {
    final outcome = await round();
    counts[outcome] = counts[outcome]! + 1;
  }
  final aDelta = _rssKb() - aStart;
  _say(
    'A_OUTCOMES data=${counts['DATA']} threw=${counts['THREW']} '
    'empty=${counts['EMPTY']} disconnected=${counts['DISCONNECTED']} '
    'none=${counts['NONE']}',
  );
  _say('A_THREW_CODES=${(threwCodes.toList()..sort()).join(',')}');
  _say('A_RSS_DELTA_KB=$aDelta');

  // ---- PHASE B: the positive control for the RSS instrument. ----
  // Identical loop, every retained handle HELD. Under injection nothing is
  // delivered, so this reports 0 held and the driver skips it.
  final held = <ZBytes>[];
  final bStart = _rssKb();
  for (var i = 0; i < _rounds; i++) {
    await round(hold: held);
  }
  final bDelta = _rssKb() - bStart;
  _say('B_HELD=${held.length} B_RSS_DELTA_KB=$bDelta');
  for (final zb in held) {
    zb.dispose();
  }

  pull.close();
  pubSession.close();
  subSession.close();
  _say('HARNESS_DONE');
  await stdout.flush();
  exit(0);
}
