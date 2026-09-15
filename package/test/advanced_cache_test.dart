// The advanced publisher cache's measured semantics, observed through our own
// stack rather than through a probe.
//
// This file exists because a documented sentinel was false: `cacheMaxSamples:
// 0` was called "unlimited" at four sites in `package/` while the shim's `> 0`
// guard quietly left canon's one-sample default in place. The cure removed the
// misreading; these cells pin what canon actually does, so the claim in the
// dartdoc is a measurement and not a second guess.
//
// Every cell drives two peer sessions over explicit TCP loopback with
// multicast and gossip off — the tests control their environment rather than
// inheriting the LAN — publishes BEFORE any subscriber exists, and then joins
// late with history recovery on. Counting what a late joiner recovers is the
// only way to observe a publisher-side cache bound at all.
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// How long the publisher's cache is given to settle before a subscriber
/// joins. This is settle time, not a race: nothing observable marks "the cache
/// is ready", and the recovery that follows IS polled.
const _cacheSettle = Duration(seconds: 2);

/// Bound on the wait for the FIRST recovered sample. A cell that sees nothing
/// within this window fails red; it never proceeds on a bare sleep.
const _firstSampleTimeout = Duration(seconds: 8);

/// After the first sample lands, how long stragglers are given before the
/// count is read. Recovery is a burst, so this is settle time again.
const _quiescence = Duration(seconds: 3);

/// The window a NEGATIVE cell observes. Deliberately the whole budget a
/// positive cell is allowed to consume, so "nothing arrived" is measured
/// against at least as long a window as every passing positive cell used.
const _negativeWindow = Duration(seconds: 11);

/// Publishes five samples through an advanced publisher configured with
/// [pubOptions], then joins late with history recovery and returns everything
/// recovered.
///
/// [expectAny] selects the wait discipline: `true` polls for the first arrival
/// under [_firstSampleTimeout] and fails red on timeout; `false` observes for
/// the full [_negativeWindow] and expects silence.
Future<List<String>> _recoverAfterFivePuts({
  required int port,
  required String key,
  required AdvancedPublisherOptions pubOptions,
  required bool expectAny,
}) async {
  final config1 = Config()
    ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false')
    ..insertJson5('timestamping/enabled', 'true');
  final session1 = await Session.open(config: config1);
  await Future<void>.delayed(const Duration(milliseconds: 400));

  final publisher = session1.declareAdvancedPublisher(key, options: pubOptions);
  for (var i = 1; i <= 5; i++) {
    publisher.put('cached_$i');
  }
  await Future<void>.delayed(_cacheSettle);

  final config2 = Config()
    ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final session2 = await Session.open(config: config2);
  await Future<void>.delayed(const Duration(seconds: 1));

  final subscriber = session2.declareAdvancedSubscriber(
    key,
    options: const AdvancedSubscriberOptions(
      history: true,
      detectLatePublishers: true,
    ),
  );

  final received = <String>[];
  final subscription = subscriber.stream.listen((s) => received.add(s.payload));

  try {
    if (expectAny) {
      final deadline = DateTime.now().add(_firstSampleTimeout);
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (received.isEmpty) {
        fail(
          'no sample recovered within $_firstSampleTimeout on port $port — '
          'the recovery pipeline itself is broken, so no count below this '
          'line would mean anything',
        );
      }
      await Future<void>.delayed(_quiescence);
    } else {
      await Future<void>.delayed(_negativeWindow);
    }
  } finally {
    await subscription.cancel();
    subscriber.close();
    publisher.close();
    session2.close();
    session1.close();
  }
  return received;
}

void main() {
  group(
    'AdvancedPublisher cache semantics (TCP 19400-19402)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('an explicit zero limit recovers exactly one sample', () async {
        final recovered = await _recoverAfterFivePuts(
          port: 19400,
          key: 'zenoh/dart/adv-cache/zero',
          pubOptions: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 0),
            publisherDetection: true,
            sampleMissDetection: true,
          ),
          expectAny: true,
        );
        // Canon's max_samples: 1 — no unlimited semantics anywhere. This is
        // the value-fidelity census's red leg (D-3), re-pinned through the
        // reworked surface instead of through a probe.
        expect(recovered, hasLength(1));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('an unspecified limit behaves identically to the explicit zero', () async {
        final recovered = await _recoverAfterFivePuts(
          port: 19401,
          key: 'zenoh/dart/adv-cache/unspecified',
          pubOptions: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(),
            publisherDetection: true,
            sampleMissDetection: true,
          ),
          expectAny: true,
        );
        // One, the canon default this binding now defers to — measurably the
        // same as an explicit zero, which is precisely why NEITHER may be
        // documented as unlimited.
        //
        // ⚠️ What this cell can and cannot separate. Canon's default is 1 and
        // an explicit 0 also yields 1, so "the shim left canon's default
        // untouched" and "the shim passed 0" are observationally identical:
        // there is no in-band discriminator, and no assertion here can invent
        // one. The distinction is verified STRUCTURALLY instead, at the shim's
        // `if (cache_max_samples >= 0)` assignment guard, which runs only when
        // the caller supplied a value. So this cell asserts the observable
        // EQUIVALENCE as equivalence, not as proof of deferral.
        expect(recovered, hasLength(1));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a real limit works through our stack', () async {
        final recovered = await _recoverAfterFivePuts(
          port: 19402,
          key: 'zenoh/dart/adv-cache/limit-ten',
          pubOptions: const AdvancedPublisherOptions(
            cache: AdvancedPublisherCacheOptions(maxSamples: 10),
            publisherDetection: true,
            sampleMissDetection: true,
          ),
          expectAny: true,
        );
        // All five. This is the control that gives the two cells above their
        // meaning: without it, "1 recovered" is equally consistent with a
        // broken recovery pipeline that delivers almost nothing.
        expect(recovered, hasLength(5));
        expect(
          recovered.toSet(),
          equals({'cached_1', 'cached_2', 'cached_3', 'cached_4', 'cached_5'}),
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('no cache means no recovery', () async {
        // Port 19400 reused: the sessions of the first cell are long closed by
        // the time this runs, and the suite is serial by rule.
        final recovered = await _recoverAfterFivePuts(
          port: 19400,
          key: 'zenoh/dart/adv-cache/absent',
          pubOptions: const AdvancedPublisherOptions(
            publisherDetection: true,
            sampleMissDetection: true,
          ),
          expectAny: false,
        );
        // The enable axis is observable, so "presence of the object means
        // enabled" is pinned rather than assumed. The observation window is
        // the entire budget a positive cell is allowed — 11s against the 8s
        // first-arrival bound plus 3s of quiescence — so this silence is
        // measured against at least as long a window as every green above.
        expect(recovered, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );
}
