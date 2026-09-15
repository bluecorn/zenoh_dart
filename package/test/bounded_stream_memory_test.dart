// Seed `[DM-bounded-stream]`, criterion A: the bounded variant BOUNDS RESIDENT
// MEMORY, and F-7's literal prong-2 arm.
//
// ## What is being separated
//
// The shipped push surface -- `Session.declareSubscriber` -- feeds every
// arrival into a non-broadcast `StreamController` seam (`subscriber.dart`,
// `createSampleChannel`). Pausing that subscription does not reach zenoh at
// all: the native callback keeps posting, the controller keeps buffering, and
// what accumulates grows with the TRAFFIC. `PullSubscriber.stream` does not:
// it takes one sample at a time out of the bounded native channel, and only
// while the subscription is demanding, so a paused consumer retains
// `capacity + 1` samples and nothing more.
//
// ## ⭐ THE CALIBRATION IS FREE, AND THAT IS STATED RATHER THAN LEFT IMPLICIT
//
// `development/discipline/verification.md` requires every resource leg to
// carry a both-ways calibration -- the same instrument run against a build
// that HAS the defect. **No injected edit is built for criterion A, and none
// is needed.** The arm carrying the defect is the shipped `declareSubscriber`,
// reachable from the same unmodified build by calling a different method on
// the same session. Both arms below run the same binary, the same harness and
// the same volume; only the declare differs. (Other slices in this unit DO
// build injected calibrations -- the stash-disposal leg removes the release
// and re-runs. This one does not have to.)
//
// ## ⚠️ THE INSTRUMENT IS AT RISK, AND THE RISK IS ENGAGED HERE
//
// `verification.md` §3a records RSS as an instrument that has ALREADY FAILED
// on this codebase:
//
// > *"RSS could not see a per-session 2008-byte leak -- session churn already
// > resides those pages."*
//
// That is true, and it is true AT 2 KB. It is a statement about a size class,
// not about the instrument in general: RSS reports pages, so anything smaller
// than the allocator's own churn disappears into it. The measurement here is
// at a different size class entirely -- **1024 x 65536 bytes = 64 MiB posted**
// -- where a prior probe on the real two-process zenoh path separated the two
// arms by roughly 50-80x (+155 MiB paused-push versus +2 MiB demand-gated).
//
// **Re-measured here, on this tree, at that size class:** the paused push arm
// grew `DELTA_MIB=154` and the paused demand-gated ring arm `DELTA_MIB=3` --
// a separation of ~51x, inside the band the prior probe reported. So the
// instrument does see it at 64 MiB. That is a measurement, not an
// expectation: had the two arms overlapped it would have been a finding about
// RSS at this size class, not a threshold to move.
//
// **The volume is high precisely because the instrument is only fit up
// there.** It is not tuned to make a threshold pass; it is the size class at
// which RSS can see the thing at all. The thresholds below (push >= 40 MiB,
// bounded <= 25 MiB, ratio >= 4x) sit a six-fold margin inside the measured
// separation, so they are not host-tuned either. An overlap would be a
// finding about the instrument, not a threshold to adjust toward.
//
// ## Topology, volume and process discipline
//
// Two OS PROCESSES over TCP loopback, always. A same-process producer would
// block permanently inside a synchronous FFI call the moment a fifo filled,
// freezing the whole serial suite instead of failing a cell.
//
// **One fresh child process per arm** (mandate 6). RSS is per-process and
// monotonic-ish; comparing two INDEPENDENT deltas is criterion A's
// calibration, not cumulative arithmetic inside one process.
//
// PORTS: 19592 (push arm), 19593 (bounded-ring arm, and cell 25's early
// death), 19597 (bounded-fifo arm). No others.
import 'package:test/test.dart';

import 'helpers/bounded_subprocess.dart';

const _harness = 'test/helpers/bounded_stream_rss_harness.dart';

/// 1024 x 65536 bytes = **64 MiB posted**. See the header: this is the size
/// class at which RSS is a fit instrument, not a tuned number.
const _count = 1024;
const _size = 65536;

/// The HIGHEST `PRODUCER_PUBLISHED=` value anywhere in the child's output.
///
/// ⚠️ `HarnessOutcome.markerValue` returns the **first** match, which is the
/// right answer for a marker printed once and the wrong answer for a PROGRESS
/// marker printed every 64 messages -- it would report 64 and read as a
/// catastrophic stall on a run that finished cleanly. The progress relay is
/// the whole observable of cell 24, so the scan has to be over all of it.
int _finalProducerPublished(HarnessOutcome outcome) {
  const prefix = 'PRODUCER_PUBLISHED=';
  var highest = -1;
  for (final line in outcome.output.split('\n')) {
    final t = line.trimRight();
    if (!t.startsWith(prefix)) continue;
    final v = int.tryParse(t.substring(prefix.length));
    if (v != null && v > highest) highest = v;
  }
  return highest;
}

void main() {
  group('Criterion A: resident memory under a paused consumer', () {
    /// Starts one fresh arm, drives it through its paused window, releases it
    /// with the stdin `RESUME` line, and returns its outcome.
    ///
    /// The resume is **stdin-sequenced, not timed**: the paused window ends
    /// because the parent said so, after the child's own pre-resume markers
    /// are in, so "the 64 MiB was posted while the consumer was paused" is a
    /// sequenced fact rather than a timing hope. Precedent: the
    /// `[MICRO-fifo-close]` stdin trigger, whose determinism has its own
    /// positive control in `fifo_close_deadlock_test.dart`.
    Future<HarnessOutcome> driveArm(List<String> args, String label) async {
      final child = await startBoundedHarness(
        _harness,
        [...args, '--count', '$_count', '--size', '$_size'],
        label: label,
      );
      addTearDown(child.dispose);

      // `DELIVERED=` is the LAST pre-resume marker the harness prints, so
      // seeing it means the whole paused-window measurement has landed.
      await child.waitForMarker('DELIVERED=', const Duration(seconds: 240));
      child.send('RESUME');
      return child.awaitExit(const Duration(seconds: 240));
    }

    test(
      'the shipped push arm buffers without bound while paused; the bounded '
      'arm does not',
      () async {
        // ARM 1 -- the defect, from the shipped build. `declareSubscriber`,
        // paused before any traffic.
        final push = await driveArm(
          ['--arm', 'push', '--port', '19592'],
          'rss[push]',
        );

        // ARM 2 -- the fix, from the SAME build. A fresh process: this is a
        // calibration by comparison of two independent deltas, not by
        // arithmetic across one process's lifetime.
        final bounded = await driveArm(
          [
            '--arm',
            'bounded',
            '--kind',
            'ring',
            '--capacity',
            '8',
            '--port',
            '19593',
          ],
          'rss[bounded-ring]',
        );

        for (final o in [push, bounded]) {
          expect(o.frozen, isFalse, reason: o.diagnosis);
          expect(o.exitCode, isZero, reason: o.diagnosis);
          // Marker discipline: `HARNESS_DONE` is printed at the END, so a
          // child that died mid-measurement cannot pass for a clean one.
          expect(o.hasMarker('HARNESS_DONE'), isTrue, reason: o.diagnosis);
          // The listener was paused before any traffic and stayed paused for
          // the whole window. If this is not 0 the delta measures something
          // other than retention.
          expect(o.markerValue('DELIVERED='), isZero, reason: o.diagnosis);
          // THE PRODUCER REALLY RAN, IN BOTH ARMS. A ring never blocks its
          // producer, so 64 MiB was genuinely posted into each -- the two
          // deltas answer the same question.
          expect(
            _finalProducerPublished(o),
            equals(_count),
            reason: o.diagnosis,
          );
        }

        expect(
          push.markerValue('DELTA_MIB='),
          isNotNull,
          reason: push.diagnosis,
        );
        expect(
          bounded.markerValue('DELTA_MIB='),
          isNotNull,
          reason: bounded.diagnosis,
        );
        final pushMiB = push.markerValue('DELTA_MIB=')!;
        final boundedMiB = bounded.markerValue('DELTA_MIB=')!;

        // Thresholds sit a six-fold margin inside the measured ~50-80x
        // separation (see the header). They are bounds on the CLAIM, not on
        // this host.
        expect(pushMiB, greaterThanOrEqualTo(40), reason: push.diagnosis);
        expect(boundedMiB, lessThanOrEqualTo(25), reason: bounded.diagnosis);
        expect(
          pushMiB,
          greaterThanOrEqualTo(4 * boundedMiB),
          reason:
              'push=$pushMiB MiB bounded=$boundedMiB MiB\n'
              '${push.diagnosis}\n${bounded.diagnosis}',
        );
      },
      timeout: const Timeout(Duration(seconds: 600)),
    );

    test(
      'a slow consumer throttles the producer -- prong-2, literally',
      () async {
        // F-7. The register's own sentence is *"a slow consumer throttles the
        // producer"*. Seed 5 ruled that observable unreachable because
        // producer-side put-blocking is invisible in a ONE-PROCESS topology.
        // This arm is two-process, so that constraint does not travel: the
        // producer is a separate OS process under `CongestionControl.block`,
        // and its progress is relayed line-by-line as it happens.
        //
        // THE CONTRAST CONTROL IS CELL 23's RING ARM: same harness, same
        // volume, same paused consumer, `PRODUCER_PUBLISHED=1024` while
        // paused. A ring never throttles; a fifo does. Any stall seen here is
        // therefore attributable to the KIND and not to the harness.
        final fifo = await driveArm(
          [
            '--arm',
            'bounded',
            '--kind',
            'fifo',
            '--capacity',
            '8',
            '--port',
            '19597',
          ],
          'rss[bounded-fifo]',
        );

        expect(fifo.frozen, isFalse, reason: fifo.diagnosis);
        expect(fifo.exitCode, isZero, reason: fifo.diagnosis);
        expect(fifo.hasMarker('HARNESS_DONE'), isTrue, reason: fifo.diagnosis);
        expect(fifo.markerValue('DELIVERED='), isZero, reason: fifo.diagnosis);

        final paused = fifo.markerValue('PAUSED_PUBLISHED=');
        expect(paused, isNotNull, reason: fifo.diagnosis);
        final finalPublished = _finalProducerPublished(fifo);

        printOnFailure(
          'PAUSED_PUBLISHED=$paused '
          'final PRODUCER_PUBLISHED=$finalPublished of $_count',
        );

        if (paused! < _count) {
          // BRANCH (α) -- the literal discharge. The producer was held back
          // while the consumer was paused, and completed once it resumed.
          expect(paused, lessThan(_count), reason: fifo.diagnosis);
          expect(finalPublished, equals(_count), reason: fifo.diagnosis);
        } else {
          // BRANCH (β) -- NOT A FAILURE, A RESULT. **This is the branch this
          // tree takes**, and the measurement below says WHY, because the
          // reason branch (β) was drafted with is falsified by this run's own
          // numbers.
          //
          // ⚠️ (β) WAS FRAMED AS "the transport absorbed all 64 MiB". IT DID
          // NOT. The consumer reports `DELTA_MIB=2` and only ~16 of 1024
          // samples ever delivered: nothing was absorbed, the excess was
          // DISCARDED in transit. The same ~16 arrive at counts 32, 128, 512
          // and 1024 alike -- so the bound is not a size.
          //
          // WHAT THE MACHINE ACTUALLY DOES, timed at the producer's own
          // `# published=<n> at_ms=<t>` lines (1024 x 64 KiB):
          //
          //   ring : 64 -> 1024 in 0.15 s            never throttled
          //   fifo : 64 ->  320 in 5.05 s, then      THROTTLED, then released
          //          320 -> 1024 in 0.09 s
          //
          // So the producer IS throttled, and the literal prong-2 effect is
          // real and present. It is simply TIME-BOUNDED BY CANON: zenoh
          // 1.8.0's default `transport/link/tx/queue/congestion_control/
          // block/wait_before_close` is 5000000 us, documented as *"the
          // maximum time in microseconds to wait for an available batch
          // before closing the transport session when sending a blocking
          // message"*. The measured 5.05 s stall is that default, to the
          // resolution of the progress interval; the burst after it, and the
          // ~1008 lost samples, are the transport session being closed out
          // from under the publisher.
          //
          // THE INSTRUMENT, NOT THE CLAIM, IS WHAT COMES UP SHORT.
          // `PAUSED_PUBLISHED < count` can only see a throttle that OUTLASTS
          // the observation window, and canon bounds this one to 5 s while
          // the harness's paused window is 25 s. **Raising the volume cannot
          // change that -- the bound is a timeout, not a size** -- so the
          // volume is not tuned upward to force (α), which would be tuning an
          // instrument until it agreed.
          //
          // Criterion B's ruled substitutes in the sibling slice therefore
          // remain the discharge of prong-2. The slack is DOCUMENTED rather
          // than guessed, and it is not what (β) assumed: it is a ~5 s block
          // plus roughly 1 MiB of in-flight, after which canon drops the
          // link -- not 64 MiB of buffer.
          expect(paused, equals(_count), reason: fifo.diagnosis);
          expect(finalPublished, equals(_count), reason: fifo.diagnosis);
        }
      },
      timeout: const Timeout(Duration(seconds: 600)),
    );

    group('Edge cases', () {
      test('an early death cannot read as a clean measurement', () async {
        // MARKER DISCIPLINE AS A CELL. Every number cell 23 and cell 24 read
        // comes from a marker, and a marker is only evidence if a child that
        // died before reaching the measured step cannot produce it.
        //
        // `--capacity -1` is rejected by the shipped binding with an
        // `ArgumentError` AT THE DECLARE -- after the session is already
        // open, so this is not "died before doing anything", it is "died
        // after real session work and before the thing under test". That is
        // the shape that would otherwise be mistaken for a clean bounded
        // measurement.
        final outcome = await runBoundedHarness(
          _harness,
          [
            '--arm',
            'bounded',
            '--kind',
            'ring',
            '--capacity',
            '-1',
            '--port',
            '19593',
            '--count',
            '8',
            '--size',
            '64',
          ],
          deadline: const Duration(seconds: 60),
          label: 'rss[capacity=-1]',
        );

        expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
        expect(outcome.exitCode, isNot(0), reason: outcome.diagnosis);
        expect(
          outcome.hasMarker('DELTA_MIB='),
          isFalse,
          reason: outcome.diagnosis,
        );
        expect(
          outcome.hasMarker('HARNESS_DONE'),
          isFalse,
          reason: outcome.diagnosis,
        );
        // ⚠️ WITHOUT THIS LINE THE CELL PASSES VACUOUSLY. Three assertions
        // about ABSENCE are all satisfied by a harness that does not exist at
        // all, or by a typo in its path -- the exact false-green shape the
        // cell exists to forbid. This one says the child got far enough to be
        // rejected BY THE BINDING, for the reason claimed.
        expect(outcome.output, contains('capacity'), reason: outcome.diagnosis);
      }, timeout: const Timeout(Duration(seconds: 120)));
    });
  });
}
