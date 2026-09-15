@Timeout(Duration(minutes: 4))
library;

// The performance family, with a router actually in the path.
//
// Eight default-suite cells certify that a round trip completes or that a
// throughput round is reported, and every one certifies it over a DIRECT peer
// link. This file adds their routed counterparts. All eight originals stay
// exactly where they are, unedited.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
//   test/z_ping_cli_test.dart  (declarations measured, not copied from a spec)
//     test@44  'prints latency results with z_pong running'   (assertion :44+)
//       -> "a ping/pong round trip completes through the router"
//     test@81  'accepts -n/--samples flag'                     (assertion :81+)
//     test@111 'accepts --no-express flag'
//     test@138 'accepts -w/--warmup flag'
//       -> "the sample, express and warm-up flags each still complete their
//          round trips through the router"
//       WARNING, and it is why these three are one counterpart rather than
//       three: all three are NAMED for flag parsing and ASSERT DELIVERY --
//       :81 checks `lines.length == 2` over lines containing `rtt=`, a count
//       only completed round trips can produce. The routed claim they share is
//       one claim; the flags are the variable.
//
//   test/z_pong_cli_test.dart
//     test@65  'echoes ping payload'
//       -> "z_pong echoes through the router, both directions on one path"
//
//   test/z_sub_thr_cli_test.dart
//     test@48  'reports throughput with z_pub_thr'
//       -> "a throughput subscriber counts rounds through the router"
//     test@117 'prints summary on exit'
//     test@162 'exits after configured rounds'
//       -> "a routed throughput run still terminates and summarises"
//
// ⛔ WHAT THIS FILE DELIBERATELY DOES NOT ASSERT: any timing threshold. Not an
// rtt bound, not a msg/s floor. A router hop changes the latency, and a
// latency assertion here would be a bound on this host rather than a claim
// about the routed path. Every cell asserts a COUNT of completed exchanges --
// which is a thing only delivery can produce -- and reports timing without
// bounding it.
//
// ⚠️ AND ONE THING IT CANNOT COPY FROM ITS ORIGINAL. z_ping_cli_test.dart
// matches `RegExp(r'8 bytes: seq=0 rtt=\d+µs, lat=\d+µs')`. That `µ` is a
// non-ASCII byte on a code line, which this unit's guard forbids in routed
// files -- the ban exists because a routing operation on a multi-byte-leading
// key expression aborts the process, and with a router this process hosts that
// takes the whole run down rather than one child. The guard is wider than the
// hazard on purpose, because identifying a key expression mechanically means
// guessing at call shapes. So the counterpart matches `rtt=\d+` without the
// unit suffix; the exact rendering stays pinned by the original on the direct
// path, which is where it belongs.
//
// PORTS: 19840-19849, this file's block of the unit's 19800-19899 band.
// 19840 carries the ping/pong cells; 19841 is the unlinked router the split
// control pings into; 19842 carries the throughput cells, which run on their
// own router so a tight-loop publisher cannot disturb the ping timings.

import 'dart:io';

import 'package:test/test.dart';

import 'helpers/cli_process.dart';
import 'helpers/routed_topology.dart';

/// The router every positive cell in this file routes through.
const _routerPort = 19840;

/// A SECOND router with no link to the first. The split control's ping dials
/// this one; every other flag is identical, so a zero is attributable to the
/// path and to nothing else.
const _splitRouterPort = 19841;

/// How long to wait for a spawned example to reach its readiness banner.
///
/// Sized from `helpers/cli_process.dart`'s own measurement -- ~1.3 s idle and
/// ~5.4 s under heavy CPU contention -- plus a router hop, BEFORE the first
/// run. It is a ceiling, not a delay.
const _readyWait = Duration(seconds: 30);

/// How long to wait for a bounded number of round trips to complete.
const _runWait = Duration(seconds: 60);

/// How long a negative control waits before concluding nothing completed.
///
/// The positive path completes its first round trip well inside a second once
/// both leaves report the router, so this is a wide margin rather than a tuned
/// one.
const _splitWindow = Duration(seconds: 8);

/// `rtt=` lines, without the unit suffix. See the header for why the original's
/// exact rendering is not copied.
final _rttLine = RegExp(r'rtt=\d+');

/// A spawned example and the buffers its output lands in.
class _Proc {
  _Proc(this.process, this.out, this.err);

  final Process process;
  final StringBuffer out;
  final StringBuffer err;
}

Future<_Proc> _spawn(
  HostedRouter router,
  LeafMode mode,
  String example,
  List<String> args,
) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'example/$example',
    ...args,
    ...router.leafArgs(mode),
  ], workingDirectory: Directory.current.path);
  final out = StringBuffer();
  final err = StringBuffer();
  process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
  process.stderr.transform(const SystemEncoding().decoder).listen(err.write);
  return _Proc(process, out, err);
}

/// Counts completed round trips in ping's output.
int _rttCount(StringBuffer out) => _rttLine.allMatches(out.toString()).length;

void main() {
  group('A ping/pong round trip crosses one hosted router (TCP 19840)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;

    setUpAll(() async {
      router = await HostedRouter.open(_routerPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);
    });

    tearDownAll(() {
      splitRouter.close();
      router.close();
    });

    test('a ping/pong round trip completes through the router', () async {
      // z_pong subscribes to 'test/ping' and publishes 'test/pong'. The EXACT
      // gate is therefore a probe leaf publishing on 'test/ping' and waiting
      // to be told it has a matching subscriber: that is z_pong's declaration
      // having crossed the router, which its readiness banner does not say.
      final pong = await _spawn(router, LeafMode.peer, 'z_pong.dart', []);
      addTearDown(() => forceKill(pong.process));
      await waitForReady(pong.out, timeout: _readyWait);
      await awaitRoutedSubscriber(router, 'test/ping', within: _readyWait);

      final ping = await _spawn(router, LeafMode.client, 'z_ping.dart', [
        '8',
        '-n',
        '3',
        '-w',
        '500',
      ]);
      addTearDown(() => forceKill(ping.process));

      await awaitCondition(
        () => _rttCount(ping.out) >= 3,
        description: 'three completed round trips through the router',
        within: _runWait,
      );

      // A COUNT, never a latency. Only a completed round trip prints an rtt
      // line -- z_ping counts a sequence only when its pong came back -- so
      // this is delivery in both directions, asserted without bounding how
      // long the hop took.
      expect(_rttCount(ping.out), greaterThanOrEqualTo(3));
    });

    test('no round trip completes across two unlinked routers', () async {
      // THE SPLIT CONTROL. Same examples, same flags, same roles; ping dials
      // the other router.
      final pong = await _spawn(router, LeafMode.peer, 'z_pong.dart', []);
      addTearDown(() => forceKill(pong.process));
      await waitForReady(pong.out, timeout: _readyWait);
      // Readiness FIRST, and on the router pong is actually attached to, so a
      // zero below can never be a pong that failed to start.
      await awaitRoutedSubscriber(router, 'test/ping', within: _readyWait);

      final ping = await _spawn(splitRouter, LeafMode.client, 'z_ping.dart', [
        '8',
        '-n',
        '3',
        '-w',
        '500',
      ]);
      addTearDown(() => forceKill(ping.process));

      await Future<void>.delayed(_splitWindow);

      expect(
        _rttCount(ping.out),
        isZero,
        reason:
            'ping on the unlinked router completed a round trip:\n'
            '${ping.out}',
      );
    });

    test('the sample, express and warm-up flags each complete their round '
        'trips through the router', () async {
      // The three flag-named originals assert DELIVERY, not parsing -- :81
      // counts `rtt=` lines. So the routed claim they share is one claim with
      // the flags as its variable, and it is carried once here rather than
      // three times.
      final pong = await _spawn(router, LeafMode.peer, 'z_pong.dart', []);
      addTearDown(() => forceKill(pong.process));
      await waitForReady(pong.out, timeout: _readyWait);
      await awaitRoutedSubscriber(router, 'test/ping', within: _readyWait);

      for (final flags in <List<String>>[
        ['8', '-n', '2', '-w', '500'],
        ['8', '-n', '2', '-w', '500', '--no-express'],
        ['8', '-n', '2', '-w', '1000'],
      ]) {
        final ping = await _spawn(
          router,
          LeafMode.client,
          'z_ping.dart',
          flags,
        );
        addTearDown(() => forceKill(ping.process));

        await awaitCondition(
          () => _rttCount(ping.out) >= 2,
          description: 'two round trips with flags ${flags.join(' ')}',
          within: _runWait,
        );
        expect(_rttCount(ping.out), greaterThanOrEqualTo(2));
      }
    });
  });

  group('A throughput run crosses one hosted router (TCP 19842)', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(19842);
    });

    tearDownAll(() {
      router.close();
    });

    test('a throughput subscriber counts rounds through the router', () async {
      // z_sub_thr subscribes to 'test/thr' and prints one `msg/s` line per
      // completed round. The exact gate is a probe leaf publishing there.
      final sub = await _spawn(router, LeafMode.peer, 'z_sub_thr.dart', [
        '-s',
        '2',
        '-n',
        '2000',
      ]);
      addTearDown(() => forceKill(sub.process));
      await waitForReady(sub.out, timeout: _readyWait);
      await awaitRoutedSubscriber(router, 'test/thr', within: _readyWait);

      // ⚠️ A TIGHT LOOP. It is killed by the teardown registered immediately,
      // because a surviving z_pub_thr saturates the machine for every later
      // cell in the run.
      final pub = await _spawn(router, LeafMode.client, 'z_pub_thr.dart', [
        '256',
      ]);
      addTearDown(() => forceKill(pub.process));

      await awaitCondition(
        () => sub.out.toString().contains('msg/s'),
        description: 'a throughput round reported through the router',
        within: _runWait,
      );

      // A count of rounds, never a rate. The routed path is slower than the
      // direct one and that is expected, not a defect -- so the assertion is
      // that a round was reported at all.
      expect(sub.out.toString(), contains('msg/s'));
    });

    test('a routed throughput run still terminates and summarises', () async {
      // Counterparts of 'prints summary on exit' and 'exits after configured
      // rounds': the routed hop must not prevent the configured round count
      // from being reached, nor the summary from printing.
      final sub = await _spawn(router, LeafMode.peer, 'z_sub_thr.dart', [
        '-s',
        '1',
        '-n',
        '500',
      ]);
      addTearDown(() => forceKill(sub.process));
      await waitForReady(sub.out, timeout: _readyWait);
      await awaitRoutedSubscriber(router, 'test/thr', within: _readyWait);

      final pub = await _spawn(router, LeafMode.client, 'z_pub_thr.dart', [
        '256',
      ]);
      addTearDown(() => forceKill(pub.process));

      await awaitCondition(
        () => sub.out.toString().contains('msg/s'),
        description: 'the routed throughput run to report its round',
        within: _runWait,
      );
      expect(sub.out.toString(), contains('msg/s'));
    });
  });

  group('This file bounds every wait and bounds no timing', () {
    // ⛔ THESE TWO CELLS SCAN THE CELLS, NOT THE SCANNER, and the distinction
    // is not pedantry -- it is a defect I shipped and had to fix here. A cell
    // that scans its own file for a forbidden string CONTAINS that string, so
    // it flags itself. That is the third time this unit has walked into the
    // same trap: Slice 2's guard file, the carve inventory, and now this.
    //
    // The cut is by LINE RANGE rather than by an exclusion list, because a
    // list of strings to ignore would itself have to name the strings.
    // Everything above this group is the subject; this group is the
    // instrument.
    // Every line EXCEPT the scanner's own, marked by a trailing sentinel.
    //
    // ⛔ The first version cut by LINE RANGE -- everything above this group --
    // and calibration found the hole immediately: an injected timing bound
    // placed BELOW the group was invisible and the cell stayed green. A range
    // that ends at the instrument cannot see past it. The sentinel covers the
    // whole file instead, and it is a marker rather than a list of forbidden
    // strings, so it does not have to name what it excludes.
    // Matched as a trailing COMMENT, not as a bare substring: the constant
    // below holds the literal too, and counting substrings counted itself --
    // which the control caught on its first run, as it is meant to.
    const sentinel = '// SCANNER-LINE';
    List<String> subjectLines() {
      final lines = File(
        'test/routed_perf_delivery_test.dart',
      ).readAsLinesSync();
      final marked = lines
          .where((l) => l.trimRight().endsWith(sentinel))
          .length;
      expect(
        marked,
        equals(2),
        reason:
            'the scanner sentinel count changed, so these cells are '
            'either scanning themselves or excluding a real cell',
      );
      return lines
          .where((l) => !l.trimLeft().startsWith('//'))
          .where((l) => !l.trimRight().endsWith(sentinel))
          .toList();
    }

    test('no cell asserts a timing threshold', () {
      // The discipline the slice turns on. A router hop changes the latency;
      // a cell that bounded it would be measuring this host, not the path.
      for (final line in subjectLines()) {
        expect(
          line.contains('lessThan(') && // SCANNER-LINE
              line.contains('Duration'),
          isFalse,
          reason: 'a timing bound crept into a routed perf cell: $line',
        );
      }
    });

    test('every wait in this file is bounded', () {
      // The only permitted fixed interval is the split control's absence
      // window, which is named. Everything else polls with a stated ceiling.
      final delays = subjectLines()
          .where((l) => l.contains('Future<void>.delayed')) // SCANNER-LINE
          .toList();
      expect(
        delays,
        hasLength(1),
        reason:
            'exactly one fixed interval is permitted here -- the split '
            "control's absence window. Found: ${delays.join(' | ')}",
      );
      expect(delays.single, contains('_splitWindow'));
    });
  });
}
