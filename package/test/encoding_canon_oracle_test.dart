// Criterion A's ORACLE: canon can carry what the criterion demands.
//
// WHY THIS FILE EXISTS. A cell that publishes through our binding and receives
// through our binding cannot tell "our send side truncates" apart from "canon
// cannot carry this value at all" — if both halves truncate at the first NUL
// they agree perfectly and prove nothing. If canon itself could not put an
// interior NUL (U+0000) inside an encoding's MIME string on the wire, then
// criterion A would be demanding something impossible and the whole seed would
// rest on a false premise. This file removes that doubt by measuring canon
// against canon: one process, two canon sessions, a real TCP wire between
// them, and our shim entirely out of the loop.
//
// WHO MEASURES AND WHO ASSERTS. The peer's `--selftest` mode opens both
// endpoints itself, publishes the subject and its control, and REPORTS what
// arrived — length and bytes. It asserts nothing. Every assertion lives here,
// in Dart, so a peer that reports nonsense fails a cell instead of passing
// itself.
//
// THE CONTROL IS NOT DECORATION. Without the NUL-free 24-byte control carried
// on the same run and the same path, a green would prove only that the peer
// works, not that it is length-faithful.
//
// HEX IS THE CARRIAGE. The received bytes cross the pipe as hex so that no
// control byte ever enters a pipe or a source file: a raw NUL in a tracked
// artifact turns the whole file binary to `grep`, which is the review
// instrument every station on this line depends on. The interior NUL is BUILT
// with `String.fromCharCode(0)`, never spelled.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'helpers/canon_peer.dart';

/// This group's endpoint. 19550/19551/19552 belong to the sibling groups.
const endpoint = 'tcp/127.0.0.1:19553';

/// The interior NUL, built rather than spelled.
final nul = String.fromCharCode(0);

/// The subject: 20 bytes with the NUL at index 10.
///
/// Byte-identical to the subject the receive-fidelity group drives, so the two
/// measurements are about the same value and differ only in who sends it.
final subjectMime = 'text/plain${nul}AFTER-NUL';

/// The control: 24 bytes, NUL-free, carrying canon's own `;` separator.
const controlMime = 'text/plain;charset=utf-8';

/// One `SELFTEST_RESULT` line, parsed.
class SelftestResult {
  const SelftestResult({
    required this.sentLen,
    required this.recvLen,
    required this.recvHex,
  });

  final int sentLen;
  final int recvLen;
  final String recvHex;

  /// The received byte at [index], decoded from the hex carriage.
  int byteAt(int index) =>
      int.parse(recvHex.substring(index * 2, index * 2 + 2), radix: 16);
}

/// Finds the peer's report for [label], failing red with its stdout quoted.
SelftestResult resultFor(List<String> lines, String label) {
  for (final line in lines) {
    if (!line.startsWith('SELFTEST_RESULT $label ')) continue;
    final fields = <String, String>{};
    for (final token in line.split(' ')) {
      final at = token.indexOf('=');
      if (at > 0) fields[token.substring(0, at)] = token.substring(at + 1);
    }
    final sent = fields['sent_len'];
    final recv = fields['recv_len'];
    final hex = fields['recv_hex'];
    if (sent == null || recv == null || hex == null) {
      fail('the peer reported a malformed result line: $line');
    }
    return SelftestResult(
      sentLen: int.parse(sent),
      recvLen: int.parse(recv),
      recvHex: hex,
    );
  }
  fail(
    'the canon peer never reported a result for "$label"\n'
    '--- peer stdout ---\n${lines.join('\n')}',
  );
}

/// A sentinel no real exit code can take: Dart reports 0..255, or the negated
/// signal number for a killed process.
const _neverExited = -1000;

/// Awaits [process] exiting within [timeout], failing red with [lines] quoted.
///
/// An unbounded wait here would freeze the serial suite, which is the single
/// sampling opportunity a close run represents.
Future<int> exitWithin(
  Process process,
  Duration timeout,
  List<String> lines,
) async {
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () => _neverExited,
  );
  if (code == _neverExited) {
    process.kill(ProcessSignal.sigkill);
    fail(
      'the canon peer did not exit within $timeout\n'
      '--- peer stdout ---\n${lines.join('\n')}',
    );
  }
  return code;
}

void main() {
  group('Canon-to-canon encoding oracle (TCP 19553)', () {
    late Directory tmp;
    late String peerPath;
    late Process happyProcess;
    late CanonPeer happy;
    late int happyExit;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('seed10_canon_oracle_');
      peerPath = await buildCanonPeer(
        'test/helpers/encoding_peer.c',
        tmp,
        'encoding_peer',
      );

      // Spawned directly rather than through `CanonPeer.start` because these
      // cells assert on the EXIT CODE too, and that needs the handle.
      // `--selftest` still prints PEER_READY, so the gate is the same one.
      happyProcess = await Process.start(peerPath, ['--selftest', endpoint]);
      happy = CanonPeer(happyProcess);
      await happy.waitForLine('PEER_READY');

      // Wait for the peer's OWN last line before the exit code: a process's
      // exit is signalled when it dies, not when the last bytes have been read
      // out of the pipe, so asserting on `lines` straight after `exitCode`
      // would race the drain.
      await happy.waitForLine(
        'SELFTEST_DONE',
        timeout: const Duration(seconds: 45),
      );
      happyExit = await exitWithin(
        happyProcess,
        const Duration(seconds: 10),
        happy.lines,
      );
    });

    tearDownAll(() async {
      await happy.kill();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('canon carries an interior-NUL MIME string over the wire', () {
      expect(
        happyExit,
        isZero,
        reason:
            'the canon-only run did not succeed\n'
            '--- peer stdout ---\n${happy.lines.join('\n')}',
      );

      final result = resultFor(happy.lines, 'nul');

      // The length is asserted alongside the bytes so a failure reports WHERE
      // it truncated rather than only that it did.
      expect(subjectMime.length, equals(20));
      expect(result.sentLen, equals(20));
      expect(result.recvLen, equals(20));
      expect(result.recvHex, equals(mimeSpec(subjectMime)));
      expect(result.byteAt(10), isZero);
    });

    test('the NUL-free control survives the same canon-only run', () {
      expect(
        happyExit,
        isZero,
        reason:
            'the canon-only run did not succeed\n'
            '--- peer stdout ---\n${happy.lines.join('\n')}',
      );

      final result = resultFor(happy.lines, 'ctl');

      expect(controlMime.length, equals(24));
      expect(result.sentLen, equals(24));
      expect(result.recvLen, equals(24));
      expect(result.recvHex, equals(mimeSpec(controlMime)));
    });

    test('the bounded wait diagnoses a dead wire instead of hanging', () async {
      // A real unreachable condition, not a mock: the publishing session opens
      // with NO listen endpoint, so nothing is bound at $endpoint for the
      // subscribing session to reach, and multicast and gossip are off on
      // both. No sample can arrive, and the peer must say so and exit.
      final process = await Process.start(
        peerPath,
        ['--selftest-unreachable', endpoint],
      );
      final peer = CanonPeer(process);
      addTearDown(peer.kill);

      await peer.waitForLine('PEER_READY');
      final timedOut = await peer.waitForLine(
        'SELFTEST_TIMEOUT',
        timeout: const Duration(seconds: 45),
      );

      // The diagnosis names which arm starved, how long it waited, and what
      // the last put answered — so a starved arm cannot silently blame the
      // wire for a send that never left.
      expect(timedOut, contains('nul'));
      expect(timedOut, contains('ms'));
      expect(timedOut, contains('rc='));

      // Waited for, not merely absent-checked: a process's exit is signalled
      // when it dies, not when the last bytes have been read out of the pipe,
      // so the verdict lines have to be observed before `lines` is judged.
      await peer.waitForLine(
        'SELFTEST_FAILED',
        timeout: const Duration(seconds: 10),
      );

      final code = await exitWithin(
        process,
        const Duration(seconds: 10),
        peer.lines,
      );
      expect(
        code,
        isNot(0),
        reason:
            'a starved run must exit non-zero\n'
            '--- peer stdout ---\n${peer.lines.join('\n')}',
      );
      expect(peer.lines, isNot(contains('SELFTEST_DONE')));
    });
  });
}
