// AdvancedSubscriber.detectedPublishers — the observe half of a knob this
// binding already let consumers turn on.
//
// Our own shipped example sets `publisherDetection: true` and nothing in the
// binding could observe the result: we bound the transmitter and not the
// receiver. Canon backs detection with liveliness tokens, so what arrives is
// an ordinary Sample — PUT when a matching advanced publisher appears, DELETE
// when it goes away.
//
// Every networked cell uses two peer sessions over explicit TCP loopback with
// multicast and gossip off, and every wait is bounded and polled.
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

// The zid-rendering contract lives in ONE place in this tree, and this is it.
// Copying the pattern here instead would make a second boundary for a fact
// that has already bitten twice.
import 'helpers/canon_zid.dart';

Config _listenConfig(int port) => Config()
  ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false')
  ..insertJson5('timestamping/enabled', 'true');

Config _connectConfig(int port) => Config()
  ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false')
  ..insertJson5('timestamping/enabled', 'true');

/// The bound on every POSITIVE detect observation. A cell that sees nothing
/// within this window fails red rather than hanging the serial suite.
const detectTimeout = Duration(seconds: 10);

/// The window every NEGATIVE control observes. Deliberately >= [detectTimeout],
/// so a measured absence is measured against at least as long a window as the
/// positive cell it isolates.
const negativeWindow = Duration(seconds: 10);

/// Polls [samples] until it is non-empty or [detectTimeout] elapses.
Future<void> awaitFirst(List<Sample> samples, {String? what}) async {
  final deadline = DateTime.now().add(detectTimeout);
  while (samples.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (samples.isEmpty) {
    fail('no ${what ?? 'detect event'} within $detectTimeout');
  }
}

void main() {
  group(
    'AdvancedSubscriber.detectedPublishers (TCP 19406-19407)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('the stream is null when the option is absent', () async {
        final session = await Session.open(config: _listenConfig(19406));
        addTearDown(session.close);
        final subscriber = session.declareAdvancedSubscriber(
          'zenoh/dart/detect/off',
        );
        addTearDown(subscriber.close);
        expect(subscriber.detectedPublishers, isNull);
      });

      test(
        'a publisher declared after the detect stream produces a PUT',
        () async {
          final session1 = await Session.open(config: _listenConfig(19407));
          addTearDown(session1.close);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final session2 = await Session.open(config: _connectConfig(19407));
          addTearDown(session2.close);
          await Future<void>.delayed(const Duration(seconds: 1));

          const key = 'zenoh/dart/detect/appear';

          // The detect stream is live FIRST, so the ordering is deterministic
          // and nothing here depends on history recovery.
          final subscriber = session2.declareAdvancedSubscriber(
            key,
            options: const AdvancedSubscriberOptions(
              detectPublishers: DetectPublishersOptions(),
            ),
          );
          addTearDown(subscriber.close);

          final detected = <Sample>[];
          final sub = subscriber.detectedPublishers!.listen(detected.add);
          addTearDown(sub.cancel);

          await Future<void>.delayed(const Duration(milliseconds: 500));

          final publisher = session1.declareAdvancedPublisher(
            key,
            options: const AdvancedPublisherOptions(publisherDetection: true),
          );
          addTearDown(publisher.close);

          await awaitFirst(detected, what: 'appearance event');
          expect(detected.first.kind, equals(SampleKind.put));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('the token key expression shape, with its configuration pinned', () async {
        final session1 = await Session.open(config: _listenConfig(19407));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19407));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/shape';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // ⚠️ THE CONFIGURATION IS LOAD-BEARING and is therefore stated in the
        // cell rather than assumed universal. Two segments of the token vary:
        //   * the fifth is the numeric entity id when sample-miss-detection is
        //     ON and the literal `uhlc` when it is off — the class default is
        //     off, which is what this publisher uses;
        //   * the trailing slot carries an announced detection metadata key
        //     expression, and is `_` when none is announced (this binding does
        //     not bind the metadata fields at all).
        final publisher = session1.declareAdvancedPublisher(
          key,
          options: const AdvancedPublisherOptions(
            publisherDetection: true,
            // Explicit although it IS the default: this cell's assertion is
            // only true for this configuration, so the configuration is
            // spelled out rather than inherited.
            // ignore: avoid_redundant_argument_values
            sampleMissDetection: false,
          ),
        );
        addTearDown(publisher.close);

        await awaitFirst(detected, what: 'appearance event');

        final segments = detected.first.keyExpr.split('/');
        expect(segments.length, equals(key.split('/').length + 5));
        expect(segments[key.split('/').length], equals('@adv'));
        expect(segments[key.split('/').length + 1], equals('pub'));

        // ⚠️ THE ZID SEGMENT IS NOT FIXED-WIDTH, and asserting that it is
        // costs a red roughly once in sixteen runs. This cell first said
        // `[0-9a-f]{32}`, passed, and went red on a re-run;
        // test/helpers/probes/probe_detect_token_zid_width.dart then measured
        // 3 short segments in 40 fresh sessions. Canon renders a zid
        // leading-zero-STRIPPED — zenoh's own definition, "Leading 0s are not
        // valid" — so the width assertion was about the sample, not about
        // canon. Exactly the divergence interop/canon.dart already models for
        // z_id_to_string, showing up at a second site.
        //
        // REPAIRED at seed #9: the comparison is now DIRECT.
        //
        // This cell used to read the token's zid through canonZidToOurHex,
        // because our renderer disagreed with canon on two axes. It does not
        // any more -- toHexString() renders canon's own form -- so the
        // normalizer is gone and the two strings are compared as they are.
        // That is strictly stronger: the transform that stood between them
        // could have hidden a disagreement in either direction.
        //
        // The pattern check stays. It asserts canon's OWN contract (1-32
        // digits, no leading zero), which this seed did not change, and it is
        // what keeps the width off the assertion -- a `{32}` here passed, then
        // went red on a re-run, and probe_detect_token_zid_width.dart measured
        // 3 short segments in 40 fresh sessions.
        final tokenZid = segments[segments.length - 3];
        expect(tokenZid, matches(canonZidPattern));
        expect(tokenZid, equals(session1.zid.toHexString()));

        // The two configuration-dependent segments, and the configuration
        // that makes each of them what it is.
        expect(segments[segments.length - 2], equals('uhlc'));
        expect(segments.last, equals('_'));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('nothing to detect is quiescent, not an error', () async {
        final session = await Session.open(config: _listenConfig(19406));
        addTearDown(session.close);

        final subscriber = session.declareAdvancedSubscriber(
          'zenoh/dart/detect/quiet',
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        Object? error;
        final sub = subscriber.detectedPublishers!.listen(
          detected.add,
          onError: (Object e) => error = e,
        );
        addTearDown(sub.cancel);

        await Future<void>.delayed(negativeWindow);
        expect(detected, isEmpty);
        expect(error, isNull);
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );

  // --- Seed #8 Slice 7: disappearance, and the controls that isolate it ----
  //
  // The negative controls are where a false green would hide: a detect stream
  // that fired on ANY publisher would satisfy the appearance cells above while
  // proving nothing about canon's actual constraint. Each negative observes
  // for `negativeWindow`, which is the whole budget `detectTimeout` allows a
  // positive cell — so an absence here is measured against at least as long a
  // window as every green above used.
  group(
    'AdvancedSubscriber detection controls (TCP 19408-19409)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('closing the publisher delivers a DELETE-kind Sample', () async {
        final session1 = await Session.open(config: _listenConfig(19408));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19408));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/disappear';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final publisher = session1.declareAdvancedPublisher(
          key,
          options: const AdvancedPublisherOptions(publisherDetection: true),
        );

        await awaitFirst(detected, what: 'appearance event');
        expect(detected.first.kind, equals(SampleKind.put));
        final token = detected.first.keyExpr;

        publisher.close();

        final deadline = DateTime.now().add(detectTimeout);
        Sample? gone;
        while (gone == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final s in detected) {
            if (s.kind == SampleKind.delete) gone = s;
          }
        }
        expect(gone, isNotNull, reason: 'no DELETE within $detectTimeout');
        // The token is asserted too, not just the kind: a stray unrelated
        // DELETE from anywhere else could otherwise satisfy this cell.
        expect(gone!.keyExpr, equals(token));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('an advanced publisher with detection off produces no event', () async {
        final session1 = await Session.open(config: _listenConfig(19409));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19409));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/knob-off';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // THE ISOLATING CONTROL: an ADVANCED publisher on the SAME key
        // expression, varying only the one knob canon's sentence is about.
        // The plain-publisher leg below is a second, coarser control -- it
        // varies the class as well, so on its own it could not tell "detection
        // needs the knob" from "detection needs an advanced publisher".
        final publisher = session1.declareAdvancedPublisher(
          key,
          // Explicit although it IS the class default: the knob being off is
          // the entire content of this control, so it is spelled out rather
          // than inherited.
          // ignore: avoid_redundant_argument_values
          options: const AdvancedPublisherOptions(publisherDetection: false),
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(negativeWindow);
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a plain publisher produces no event', () async {
        final session1 = await Session.open(config: _listenConfig(19409));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19409));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/plain';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final publisher = session1.declarePublisher(key);
        addTearDown(publisher.close);

        await Future<void>.delayed(negativeWindow);
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a non-matching advanced publisher produces no event', () async {
        final session1 = await Session.open(config: _listenConfig(19408));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19408));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        final subscriber = session2.declareAdvancedSubscriber(
          'zenoh/dart/detect/scope/a/**',
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Detection is key-expression-scoped, not session-scoped: this
        // publisher shares the session topology and nothing else.
        final publisher = session1.declareAdvancedPublisher(
          'zenoh/dart/detect/scope/b/x',
          options: const AdvancedPublisherOptions(publisherDetection: true),
        );
        addTearDown(publisher.close);

        await Future<void>.delayed(negativeWindow);
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );

  // --- Seed #8 Slice 8: the detect stream's history option ----------------
  //
  // Three CONV-2 states, all three pinned: unspecified (NULL options, canon
  // decides), explicit true, explicit false. The unspecified and explicit-false
  // cells are shown to AGREE here rather than assumed to — that agreement is
  // the observable proof that `null` defers to canon and does not quietly
  // substitute a Dart-chosen value.
  group(
    'AdvancedSubscriber detection history (TCP 19410-19411)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      /// Declares a detection-enabled advanced publisher, lets it settle, and
      /// only then declares a detect stream with [history]. Returns everything
      /// the stream saw within the window the caller's discipline allows.
      Future<List<Sample>> observePreExisting({
        required int port,
        required String key,
        required DetectPublishersOptions options,
        required bool expectAny,
      }) async {
        final session1 = await Session.open(config: _listenConfig(port));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(port));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        final publisher = session1.declareAdvancedPublisher(
          key,
          options: const AdvancedPublisherOptions(publisherDetection: true),
        );
        addTearDown(publisher.close);

        // The publisher is live and settled BEFORE the detect stream exists,
        // which is the whole point: only history recovers what is already up.
        await Future<void>.delayed(const Duration(seconds: 2));

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: AdvancedSubscriberOptions(detectPublishers: options),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        if (expectAny) {
          await awaitFirst(detected, what: 'historical appearance event');
        } else {
          await Future<void>.delayed(negativeWindow);
        }
        return detected;
      }

      test('a pre-existing publisher is invisible without history', () async {
        final detected = await observePreExisting(
          port: 19410,
          key: 'zenoh/dart/detect/hist/unspecified',
          options: const DetectPublishersOptions(),
          expectAny: false,
        );
        // history unspecified -> NULL options -> canon's default, false.
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test(
        'a pre-existing publisher is visible with history enabled',
        () async {
          final detected = await observePreExisting(
            port: 19411,
            key: 'zenoh/dart/detect/hist/on',
            options: const DetectPublishersOptions(history: true),
            expectAny: true,
          );
          expect(detected.first.kind, equals(SampleKind.put));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('explicit false is indistinguishable from unspecified', () async {
        final detected = await observePreExisting(
          port: 19410,
          key: 'zenoh/dart/detect/hist/off',
          options: const DetectPublishersOptions(history: false),
          expectAny: false,
        );
        // Same window as the unspecified cell above, and the same result --
        // so "canon decides" and "the binding says false" are SHOWN to agree
        // rather than assumed to.
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('history does not suppress live detection', () async {
        final session1 = await Session.open(config: _listenConfig(19411));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19411));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/hist/live';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(history: true),
          ),
        );
        addTearDown(subscriber.close);

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Nothing pre-existed, so this PUT can only be the live one:
        // enabling history ADDS the past, it does not replace the present.
        final publisher = session1.declareAdvancedPublisher(
          key,
          options: const AdvancedPublisherOptions(publisherDetection: true),
        );
        addTearDown(publisher.close);

        await awaitFirst(detected, what: 'live appearance event');
        expect(detected.first.kind, equals(SampleKind.put));
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );

  // --- Seed #8 Slice 9: lifecycle coherence for both new streams ----------
  //
  // This class ends up carrying THREE streams with TWO terminal contracts, and
  // the split is canon's, not ours: the detect listener is owned by the
  // session, while `stream` and `missEvents` ride this entity. Coherence is a
  // property of the object a consumer holds, so both contracts are pinned here
  // and both are documented on the class.
  group(
    'AdvancedSubscriber stream lifecycles (TCP 19412)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      test('the detect stream completes when the subscriber closes', () async {
        final session = await Session.open(config: _listenConfig(19412));
        addTearDown(session.close);

        final subscriber = session.declareAdvancedSubscriber(
          'zenoh/dart/detect/life/entity',
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );

        var done = false;
        final sub = subscriber.detectedPublishers!.listen(
          (_) {},
          onDone: () => done = true,
        );
        addTearDown(sub.cancel);

        // The pre-state, or the completion below proves nothing: a stream that
        // was ALREADY complete when the listener attached fires onDone at once
        // and passes this cell without close() having done anything.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(done, isFalse, reason: 'the stream must be live before close');

        subscriber.close();

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!done && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // The Dart-side port and controller close, exactly as missEvents does.
        expect(done, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('the detect stream completes when the session closes with the '
          'entity still open', () async {
        final session = await Session.open(config: _listenConfig(19412));

        final subscriber = session.declareAdvancedSubscriber(
          'zenoh/dart/detect/life/session',
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(subscriber.close);

        var done = false;
        final sub = subscriber.detectedPublishers!.listen(
          (_) {},
          onDone: () => done = true,
        );
        addTearDown(sub.cancel);

        // The pre-state, for the same reason as the entity-close cell above.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(done, isFalse, reason: 'the stream must be live before close');

        // Deliberately NOT closing the subscriber first: this is the leg where
        // the native listener outlives the entity and canon drops it itself.
        session.close();

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!done && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // Canon drops the background closure at session close, which runs
        // _zd_sample_drop_with_sentinel; that posts the null sentinel
        // createSampleChannel() already consumes to complete the stream.
        //
        // ⚠️ A red here is a MEASURED FINDING, not a timing problem. It would
        // mean no sentinel reached us, and the answer would be to narrow the
        // documented contract to entity-close only and report it — never to
        // widen this timeout until it goes green.
        expect(done, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('a publisher declared after the subscriber closed is harmless', () async {
        final session1 = await Session.open(config: _listenConfig(19412));
        addTearDown(session1.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final session2 = await Session.open(config: _connectConfig(19412));
        addTearDown(session2.close);
        await Future<void>.delayed(const Duration(seconds: 1));

        const key = 'zenoh/dart/detect/life/after-close';

        final subscriber = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );

        final detected = <Sample>[];
        final sub = subscriber.detectedPublishers!.listen(detected.add);
        addTearDown(sub.cancel);

        // THE POSITIVE CONTROL, and without it this cell proves nothing. An
        // empty `detected` is equally consistent with no detect event having
        // been produced at all -- a topology hiccup would satisfy the
        // assertion below while saying nothing about posting to a closed port.
        // This sibling stays OPEN on the same session and key expression, so
        // it establishes that an event really existed at this instant.
        final witness = session2.declareAdvancedSubscriber(
          key,
          options: const AdvancedSubscriberOptions(
            detectPublishers: DetectPublishersOptions(),
          ),
        );
        addTearDown(witness.close);
        final witnessed = <Sample>[];
        final witnessSub = witness.detectedPublishers!.listen(witnessed.add);
        addTearDown(witnessSub.cancel);

        // The native listener is SESSION-scoped, so it is still alive here --
        // only the Dart port it posts to is gone.
        subscriber.close();
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final publisher = session1.declareAdvancedPublisher(
          key,
          options: const AdvancedPublisherOptions(publisherDetection: true),
        );
        addTearDown(publisher.close);

        await awaitFirst(witnessed, what: 'appearance event on the witness');

        await Future<void>.delayed(const Duration(seconds: 2));

        // Posts to a closed port are dropped by the shipped bridge design
        // ("copies only -- nothing to reclaim"). Now attributable: the witness
        // received the event, the closed stream did not, and the process is
        // still running.
        expect(detected, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test(
        'closing the subscriber after the session is closed is safe',
        () async {
          final session = await Session.open(config: _listenConfig(19412));

          final subscriber = session.declareAdvancedSubscriber(
            'zenoh/dart/detect/life/reverse',
            options: const AdvancedSubscriberOptions(
              detectPublishers: DetectPublishersOptions(),
            ),
          );

          session.close();

          // Pins the teardown ordering the session-close cell creates, rather
          // than leaving it to a tearDown block nobody asserts on.
          expect(subscriber.close, returnsNormally);
          expect(subscriber.close, returnsNormally);
        },
      );
    },
  );
}
